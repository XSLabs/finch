#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Build and compare generated CoreFoundation/Foundation behavior cases."""
from __future__ import annotations

import argparse
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
    out = BUILD / "bin" / framework
    out.parent.mkdir(parents=True, exist_ok=True)
    compiler = run_checked(["xcrun", "--sdk", "macosx", "-f", "clang"]).stdout.strip()
    command = [compiler, "-arch", "arm64e", "-mmacosx-version-min=26.0", "-O2", "-fblocks",
               "-Wno-deprecated-declarations", "-Wno-deprecated-implementations", "-o", str(out), str(source),
               "-framework", framework]
    run_checked(command)
    run_checked(["codesign", "--force", "--sign", "-", "--identifier", f"org.finch.difftest.{framework}", str(out)])
    return out


def child_environment(finch: bool) -> dict[str, str]:
    env = dict(os.environ)
    for name in tuple(env):
        if name.startswith("DYLD_"):
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


def invoke(binary: Path, item: str, *, finch: bool, timeout: float) -> dict:
    env = child_environment(finch)
    try:
        result = subprocess.run([str(binary), item], cwd=ROOT, env=env, stdout=subprocess.PIPE,
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


def first_difference(apple: list[str], finch: list[str]) -> dict | None:
    limit = max(len(apple), len(finch))
    for index in range(limit):
        left = apple[index] if index < len(apple) else None
        right = finch[index] if index < len(finch) else None
        if left != right:
            sample = left if left is not None else right
            case = sample.split("\t", 1)[0] if sample is not None else str(index)
            return {"case": case, "apple": left, "finch": right}
    return None


def run_framework(framework: str, timeout: float, rules: list[dict]) -> dict:
    generator = load_generator()
    metadata = generator.generate(framework, BUILD / "generated")
    binary = build_program(framework, Path(metadata["source"]))
    tested = {item["name"]: item["category"] for item in metadata["tested_items"]}
    items = {name: {"status": "not-exercised"} for name in metadata["sdk_items"]}

    print(f"{framework}: {len(metadata['sdk_items'])} SDK items; exercising {len(tested)}", flush=True)
    for item, category in tested.items():
        apple = invoke(binary, item, finch=False, timeout=timeout)
        finch = invoke(binary, item, finch=True, timeout=timeout)
        apple_lines, apple_masks = masked(apple["stdout"], framework, item, rules)
        finch_lines, finch_masks = masked(finch["stdout"], framework, item, rules)
        if apple["timed_out"] or finch["timed_out"] or apple["returncode"] != 0 or finch["returncode"] != 0:
            status = "crashes"
            difference = {
                "apple_exit": apple["returncode"], "finch_exit": finch["returncode"],
                "apple_timed_out": apple["timed_out"], "finch_timed_out": finch["timed_out"],
                "apple_stderr": apple["stderr"][:2000], "finch_stderr": finch["stderr"][:2000],
            }
        else:
            difference = first_difference(apple_lines, finch_lines)
            status = "differs" if difference else "verified"
        record = {
            "status": status,
            "category": category,
            "examples": {"apple": len(apple["stdout"]), "finch": len(finch["stdout"])},
        }
        if difference:
            record["first_difference"] = difference
        masks = sorted(set(apple_masks + finch_masks))
        if masks:
            record["masks"] = masks
        items[item] = record
        print(f"  {status:14} {item}", flush=True)

    counts = {status: sum(1 for entry in items.values() if entry["status"] == status)
              for status in ("verified", "differs", "crashes", "not-exercised")}
    exercised = counts["verified"] + counts["differs"] + counts["crashes"]
    coverage = len(tested) / len(items) * 100 if items else 0.0
    verified_percent = counts["verified"] / exercised * 100 if exercised else 0.0
    result = {
        "schema_version": 1,
        "framework": framework,
        "sdk": run_checked(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).stdout.strip(),
        "seed": metadata["seed"],
        "input_count": metadata["input_count"],
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
    args = parser.parse_args()
    invalid = sorted(set(args.framework) - {"CoreFoundation", "Foundation"})
    if invalid:
        parser.error(f"unknown framework: {', '.join(invalid)}")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    masks_path = ROOT / "tools" / "difftest" / "masks.json"
    rules = json.loads(masks_path.read_text()) if masks_path.exists() else []
    RESULTS.mkdir(parents=True, exist_ok=True)
    try:
        for framework in args.framework or ("CoreFoundation", "Foundation"):
            result = run_framework(framework, args.timeout, rules)
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
