#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Record matching constant rows for tools/api-coverage.py."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INVENTORY = ROOT / "build/constants/inventory.json"
RESULTS = ROOT / "build/compat-results"


def rows(path: Path) -> dict[tuple[str, str], str]:
    result = {}
    for line in path.read_text(errors="replace").splitlines()[1:]:
        pieces = line.split("\t", 2)
        if len(pieces) == 3:
            result[(pieces[0], pieces[1])] = pieces[2]
    return result


def filename(framework: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", framework) + ".json"


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: record-results.py APPLE_OUTPUT FINCH_OUTPUT", file=sys.stderr)
        return 2
    try:
        inventory = json.loads(INVENTORY.read_text())
        apple = rows(Path(sys.argv[1]))
        finch = rows(Path(sys.argv[2]))
    except (OSError, json.JSONDecodeError) as error:
        print(f"could not read constant comparison output: {error}", file=sys.stderr)
        return 2

    statuses = {}
    for framework in inventory["frameworks"]:
        identifier = framework["id"]
        items = {}
        for constant in framework["constants"]:
            if not constant.get("testable"):
                continue
            key = (identifier, constant["symbol"][1:])
            left, right = apple.get(key), finch.get(key)
            item_id = "c:" + constant["symbol"]
            verified = left is not None and right is not None and left == right
            item = {"status": "verified" if verified else "differs", "verified": verified}
            if not verified:
                item["apple"] = left
                item["finch"] = right
            items[item_id] = item
        if items:
            statuses[identifier] = items

    # The coverage inventory includes APIs inherited through public umbrella
    # frameworks. Mark the same C item there when its child value matched.
    by_id = {framework["id"]: framework for framework in inventory["frameworks"]}
    for owner in inventory["frameworks"]:
        pending = list(owner.get("reexports", []))
        seen = set()
        while pending:
            child = pending.pop()
            if child in seen:
                continue
            seen.add(child)
            pending.extend(by_id.get(child, {}).get("reexports", []))
            for item_id, item in statuses.get(child, {}).items():
                statuses.setdefault(owner["id"], {}).setdefault(item_id, item)

    RESULTS.mkdir(parents=True, exist_ok=True)
    verified_total = 0
    differs_total = 0
    for identifier, items in statuses.items():
        path = RESULTS / filename(identifier)
        try:
            document = json.loads(path.read_text()) if path.is_file() else {}
        except json.JSONDecodeError:
            document = {}
        merged = document.get("items", {})
        if not isinstance(merged, dict):
            merged = {}
        merged.update(items)
        verified_ids = {item_id for item_id, item in items.items() if item.get("verified") is True}
        verified = {value for value in document.get("verified", []) if isinstance(value, str)}
        verified.update(verified_ids)
        verified.difference_update(item_id for item_id, item in items.items()
                                   if item.get("verified") is not True)
        document.update({
            "schema_version": max(1, int(document.get("schema_version", 1))),
            "framework": identifier,
            "sdk": inventory["sdk_version"],
            "items": merged,
            "verified": sorted(verified),
        })
        path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
        verified_total += sum(item.get("verified", False) for item in items.values())
        differs_total += sum(not item.get("verified", False) for item in items.values())
    print(f"constant results: {verified_total} verified, {differs_total} differ")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
