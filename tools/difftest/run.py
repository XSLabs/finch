#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Build and compare generated CoreFoundation, Foundation and AppKit behavior cases."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build" / "difftest"
RESULTS = ROOT / "build" / "compat-results"
ROOT_LIB = ROOT / "build" / "root" / "System" / "Library"


def load_generator():
    path = ROOT / "tools" / "difftest" / "generate.py"
    spec = importlib.util.spec_from_file_location("finch_difftest_generate", path)
    if not spec or not spec.loader:
        raise RuntimeError(f"cannot load generator: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def run_checked(command: list[str], *, cwd: Path = ROOT) -> subprocess.CompletedProcess:
    result = subprocess.run(command, cwd=cwd, text=True, encoding="utf-8", errors="replace",
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        message = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}\n{message}")
    return result


def build_program(framework: str, source: Path) -> Path:
    compiler = run_checked(["xcrun", "--sdk", "macosx", "-f", "clang"]).stdout.strip()
    sdk = run_checked(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).stdout.strip()
    dependencies = {
        "Foundation": ["CoreFoundation"],
        "AppKit": ["CoreFoundation"],
        "CoreGraphics": ["CoreFoundation"],
        "CoreText": ["CoreFoundation", "CoreGraphics"],
        "ImageIO": ["CoreFoundation", "CoreGraphics"],
        "Security": ["CoreFoundation"],
        "CoreVideo": ["CoreFoundation", "CoreGraphics", "IOSurface"],
        "CoreMedia": ["CoreFoundation", "CoreVideo"],
        "CoreServices": ["CoreFoundation"],
    }.get(framework, [])
    extra_frameworks = [part for dependency in dependencies for part in ("-framework", dependency)]
    build_key = hashlib.sha256(
        source.read_bytes() + framework.encode() + sdk.encode() + b"arm64e-macosx26.0-O2-fblocks"
    ).hexdigest()[:20]
    out = BUILD / "bin" / f"{framework}-{build_key}"
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.is_file():
        return out
    command = [compiler, "-arch", "arm64e", "-mmacosx-version-min=26.0", "-O2", "-fblocks",
               "-Wno-deprecated-declarations", "-Wno-deprecated-implementations", "-o", str(out), str(source),
               "-framework", framework, *extra_frameworks]
    run_checked(command)
    run_checked(["codesign", "--force", "--sign", "-", "--identifier", f"org.finch.difftest.{framework}", str(out)])
    return out


def child_environment(finch: bool) -> dict[str, str]:
    env = dict(os.environ)
    for name in tuple(env):
        if name.startswith("DYLD_"):
            env.pop(name, None)
        if name.startswith("FINCH_"):
            env.pop(name, None)
    if not finch:
        return env
    framework_paths = [
        str(ROOT_LIB / "Frameworks"), str(ROOT_LIB / "PrivateFrameworks"),
        str(ROOT_LIB / "Frameworks" / "Quartz.framework" / "Frameworks"),
        str(ROOT_LIB / "Frameworks" / "CoreServices.framework" / "Versions/A/Frameworks"),
        str(ROOT_LIB / "Frameworks" / "ApplicationServices.framework" / "Versions/A/Frameworks"),
        str(ROOT_LIB / "Frameworks" / "Carbon.framework" / "Versions/A/Frameworks"),
    ]
    env["DYLD_FRAMEWORK_PATH"] = ":".join(path for path in framework_paths if Path(path).exists())
    swift_libs = ROOT / "build" / "root" / "usr" / "lib" / "swift"
    env["DYLD_LIBRARY_PATH"] = str(swift_libs) if swift_libs.exists() else ""
    env["FINCH_THEME"] = "Classic"
    env["FINCH_FILTER_DIRS"] = str(ROOT_LIB / "Filters")
    env["FINCH_FONT_DIRS"] = str(ROOT_LIB / "Fonts")
    return env


def invoke(binary: Path, item: str, item_metadata: str, *, finch: bool, timeout: float) -> dict:
    env = child_environment(finch)
    try:
        result = subprocess.run([str(binary), item, item_metadata], cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, check=False)
        return {
            "returncode": result.returncode,
            "stdout": result.stdout.decode("utf-8", "replace").splitlines(),
            "stderr": result.stderr.decode("utf-8", "replace").strip(),
            "timed_out": False,
        }
    except subprocess.TimeoutExpired as error:
        return {
            "returncode": None,
            "stdout": (error.stdout or b"").decode("utf-8", "replace").splitlines(),
            "stderr": (error.stderr or b"").decode("utf-8", "replace").strip(),
            "timed_out": True,
        }


def masked(lines: list[str], framework: str, item: str, rules: list[dict]) -> tuple[list[str], list[str]]:
    applied = []
    result = list(lines)
    for rule in rules:
        if rule.get("framework") not in (None, framework) or rule.get("item") != item:
            continue
        pattern, replacement = rule["pattern"], rule.get("replacement", "<MACHINE>")
        result = [re.sub(pattern, replacement, line) for line in result]
        applied.append(rule.get("reason", pattern))
    return result, applied


def _decode_appkit_value(line: str) -> str:
    fields = line.split("\t")
    if len(fields) < 2:
        return line
    decoded = [fields[0]]
    for field in fields[1:]:
        try:
            value = bytes.fromhex(field).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            value = field
        decoded.append(value)
    return "\t".join(decoded)


def _appkit_pixels_within_tolerance(apple: str, finch: str) -> bool:
    apple = _decode_appkit_value(apple)
    finch = _decode_appkit_value(finch)
    patterns = (
        (re.compile(r"(bitmap:\d+x\d+:\d+:8:)([0-9a-fA-F]*)"), "bytes"),
        (re.compile(r"(pixel-data:)([0-9a-fA-F]*)"), "bytes"),
        (re.compile(r"(pixels:)(\d+(?:,\d+)+)"), "numbers"),
    )

    def normalize(value: str) -> tuple[str, list[tuple[str, list[int]]]]:
        found: list[tuple[str, list[int]]] = []
        for pattern, kind in patterns:
            def replace(match: re.Match[str]) -> str:
                raw = match.group(2)
                try:
                    components = list(bytes.fromhex(raw)) if kind == "bytes" else [int(part) for part in raw.split(",")]
                except ValueError:
                    return match.group(0)
                found.append((kind, components))
                return match.group(1) + f"<pixels:{len(components)}:{len(found)}>"
            value = pattern.sub(replace, value)
        return value, found

    left, left_pixels = normalize(apple)
    right, right_pixels = normalize(finch)
    if not left_pixels or len(left_pixels) != len(right_pixels) or left != right:
        return False
    for (left_kind, left_values), (right_kind, right_values) in zip(left_pixels, right_pixels):
        if left_kind != right_kind or len(left_values) != len(right_values):
            return False
        if any(abs(a - b) > 1 for a, b in zip(left_values, right_values)):
            return False
    return True


def _appkit_geometry_within_tolerance(apple: str, finch: str) -> bool:
    apple = _decode_appkit_value(apple)
    finch = _decode_appkit_value(finch)
    pattern = re.compile(r"\b(point|size|rect|edge-insets|transform):((-?\d+(?:\.\d+)?)(?:,-?\d+(?:\.\d+)?)+)")

    def normalize(value: str) -> tuple[str, list[list[float]]]:
        values: list[list[float]] = []
        def replace(match: re.Match[str]) -> str:
            numbers = [float(part) for part in match.group(2).split(",")]
            values.append(numbers)
            return match.group(1) + f"<geometry:{len(numbers)}:{len(values)}>"
        return pattern.sub(replace, value), values

    left, left_values = normalize(apple)
    right, right_values = normalize(finch)
    if not left_values or len(left_values) != len(right_values) or left != right:
        return False
    for a_values, b_values in zip(left_values, right_values):
        if len(a_values) != len(b_values) or any(abs(a - b) > 0.01 for a, b in zip(a_values, b_values)):
            return False
    return True


def first_difference(apple: list[str], finch: list[str], framework: str = "", *, pixel_tolerance: int = 0) -> dict | None:
    limit = max(len(apple), len(finch))
    for index in range(limit):
        left = apple[index] if index < len(apple) else None
        right = finch[index] if index < len(finch) else None
        same = left == right
        if not same and framework == "AppKit" and left is not None and right is not None:
            same = _appkit_pixels_within_tolerance(left, right) or _appkit_geometry_within_tolerance(left, right)
        if not same and pixel_tolerance and left is not None and right is not None:
            left_parts, right_parts = left.split("\t"), right.split("\t")
            if len(left_parts) == 2 and len(right_parts) == 2 and left_parts[0] == right_parts[0]:
                try:
                    left_values = [int(value) for value in left_parts[1].split(",")]
                    right_values = [int(value) for value in right_parts[1].split(",")]
                except ValueError:
                    pass
                else:
                    if len(left_values) == len(right_values) and all(
                            abs(a - b) <= pixel_tolerance for a, b in zip(left_values, right_values)):
                        same = True
        if not same:
            sample = left if left is not None else right
            case = sample.split("\t", 1)[0] if sample is not None else str(index)
            return {"case": case, "apple": left, "finch": right}
    return None


def skip_reason_category(reason: str) -> str:
    if reason.startswith("side-effect category:"):
        return reason.split(":", 1)[1].strip()
    if "does not export this C symbol" in reason:
        return "missing Finch C exports"
    if "inline function" in reason:
        return "SDK inline functions"
    if reason.startswith("Swift interface"):
        return "Swift interface members"
    if "callback" in reason.lower() or "block" in reason.lower() or "variadic" in reason.lower():
        return "callbacks and variadic calls"
    if "signature" in reason.lower():
        return "missing SDK call signature"
    if "archive context" in reason.lower():
        return "archive context needed"
    if "receiver" in reason.lower():
        return "instance receiver"
    return "no safe typed input"


def run_framework(framework: str, timeout: float, rules: list[dict], jobs: int) -> dict:
    generator = load_generator()
    metadata = generator.generate(framework, BUILD / "generated")
    binary = build_program(framework, Path(metadata["source"]))
    type_details = json.loads(Path(metadata["type_metadata"]).read_text())
    objc_details = type_details.get("objc", {})
    tested = {}
    for entry in metadata["tested_items"]:
        item = dict(entry)
        if entry["name"] in objc_details:
            item["invocation_metadata"] = json.dumps(objc_details[entry["name"]], ensure_ascii=True, separators=(",", ":"))
        else:
            item["invocation_metadata"] = "{}"
        tested[entry["name"]] = item
    items = {
        name: {"status": "not-exercised", "reason": metadata["unexercised_items"].get(name, "no safe typed input")}
        for name in metadata["sdk_items"]
    }

    print(f"{framework}: {len(metadata['sdk_items'])} SDK items; comparing {len(tested)} typed cases with {jobs} workers", flush=True)

    def compare(name: str, item: dict) -> tuple[str, dict]:
        apple = invoke(binary, name, item["invocation_metadata"], finch=False, timeout=timeout)
        finch = invoke(binary, name, item["invocation_metadata"], finch=True, timeout=timeout)
        apple_lines, apple_masks = masked(apple["stdout"], framework, name, rules)
        finch_lines, finch_masks = masked(finch["stdout"], framework, name, rules)
        missing_font_cases = {
            line.split("\t", 1)[0]
            for line in apple_lines + finch_lines
            if "font-unavailable" in line
        }
        if missing_font_cases:
            apple_lines = [line for line in apple_lines if line.split("\t", 1)[0] not in missing_font_cases]
            finch_lines = [line for line in finch_lines if line.split("\t", 1)[0] not in missing_font_cases]
        if apple["timed_out"] or finch["timed_out"] or apple["returncode"] != 0 or finch["returncode"] != 0:
            status = "crashes"
            difference = {
                "apple_exit": apple["returncode"], "finch_exit": finch["returncode"],
                "apple_timed_out": apple["timed_out"], "finch_timed_out": finch["timed_out"],
                "apple_stderr": apple["stderr"][:2000], "finch_stderr": finch["stderr"][:2000],
            }
        elif missing_font_cases and not apple_lines and not finch_lines:
            status = "not-exercised"
            difference = None
            reason = "the requested font was unavailable on at least one runtime for every case"
        elif ((apple_lines and all("not-exercised:" in line or "no-method-signature" in line for line in apple_lines)) or
              (finch_lines and all("not-exercised:" in line or "no-method-signature" in line for line in finch_lines))):
            status = "not-exercised"
            difference = None
            reason = "at least one runtime had no safe receiver, input, or callable method signature"
        else:
            tolerance = 1 if item.get("comparison") == "pixel-channel-tolerance-1" else 0
            difference = first_difference(apple_lines, finch_lines, framework, pixel_tolerance=tolerance)
            status = "differs" if difference else "verified"
        record = {
            "status": status,
            "category": item["category"],
            "examples": {"apple": len(apple["stdout"]), "finch": len(finch["stdout"])},
        }
        if status == "not-exercised":
            record["reason"] = locals().get("reason", "no safe typed input could be built")
        if missing_font_cases:
            record["font_unavailable_cases"] = len(missing_font_cases)
        if item.get("comparison"):
            record["comparison"] = item["comparison"]
        if difference:
            record["first_difference"] = difference
        masks = sorted(set(apple_masks + finch_masks))
        if masks:
            record["masks"] = masks
        return name, record

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(compare, name, item): name for name, item in tested.items()}
        completed = 0
        for future in as_completed(futures):
            name, record = future.result()
            items[name] = record
            completed += 1
            if completed % 100 == 0 or completed == len(futures):
                print(f"  {framework}: {completed}/{len(futures)} items compared", flush=True)

    counts = {status: sum(1 for entry in items.values() if entry["status"] == status)
              for status in ("verified", "differs", "crashes", "not-exercised")}
    exercised = counts["verified"] + counts["differs"] + counts["crashes"]
    coverage = exercised / len(items) * 100 if items else 0.0
    verified_percent = counts["verified"] / exercised * 100 if exercised else 0.0
    skipped_categories = {}
    for name, record in items.items():
        if record["status"] == "not-exercised":
            category = skip_reason_category(record.get("reason", "no safe typed input"))
            skipped_categories[category] = skipped_categories.get(category, 0) + 1
    result = {
        "schema_version": 1,
        "framework": framework,
        "sdk": run_checked(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).stdout.strip(),
        "seed": metadata["seed"],
        "input_count": metadata["input_count"],
        "compared_candidates": len(tested),
        "max_cases_per_item": 8,
        "skipped_categories": dict(sorted(skipped_categories.items())),
        "summary": {
            "api_items": len(items), "exercised": exercised, "coverage_percent": round(coverage, 2),
            "verified": counts["verified"], "differs": counts["differs"], "crashes": counts["crashes"],
            "not_exercised": counts["not-exercised"], "verified_percent": round(verified_percent, 2),
        },
        "items": items,
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("framework", nargs="*", metavar="FRAMEWORK",
                        help="frameworks to compare (default: CoreFoundation and Foundation)")
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds allowed for each API item on each side")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1), help="API processes to compare in parallel")
    args = parser.parse_args()
    supported = {"CoreFoundation", "Foundation", "CoreGraphics", "CoreText", "ImageIO", "AppKit",
                 "Security", "CoreVideo", "CoreMedia", "CoreServices"}
    invalid = sorted(set(args.framework) - supported)
    if invalid:
        parser.error(f"unknown framework: {', '.join(invalid)}")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.jobs <= 0:
        parser.error("--jobs must be positive")
    masks_path = ROOT / "tools" / "difftest" / "masks.json"
    rules = json.loads(masks_path.read_text()) if masks_path.exists() else []
    RESULTS.mkdir(parents=True, exist_ok=True)
    try:
        for framework in args.framework or ("CoreFoundation", "Foundation"):
            result = run_framework(framework, args.timeout, rules, args.jobs)
            target = RESULTS / f"{framework}.json"
            temporary = target.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
            temporary.replace(target)
            print(f"{framework}: {result['summary']}")
    except (OSError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"difftest failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
