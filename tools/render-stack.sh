#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Render docs/STACK.md's Mermaid diagrams to build/stack/stack-<n>.svg, which
# fails on a syntax error, or when a node has no legend colour (class) or a
# class names a node that isn't there. Uses mermaid-cli (npx) and a headless Chrome it
# fetches into build/stack/chrome on first use.
#
#   tools/render-stack.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${FINCH_ROOT}/build/stack"
CHROME_VERSION=131.0.6778.85
MERMAID_CLI=@mermaid-js/mermaid-cli@11.4.2
mkdir -p "${OUT}"
# Every node coloured by the legend: a ::: class, or a `class` line naming it.
python3 - "${FINCH_ROOT}/docs/STACK.md" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
bad = []
for n, block in enumerate(text.split("```mermaid")[1:], 1):
    block = block.split("```")[0]
    classed = set()
    for names in re.findall(r"^\s*class (\S+) \w+", block, re.M):
        classed |= set(names.split(","))
    nodes = set()
    for node, styled in re.findall(r"(?:^|[\s>|])(\w+)\[\"[^\"]*\"\](:::\w+)?", block, re.M):
        nodes.add(node)
        if styled:
            classed.add(node)
    bad += [f"diagram {n}: node {x} has no colour" for x in sorted(nodes - classed)]
    bad += [f"diagram {n}: class names missing node {x}" for x in sorted(classed - nodes)]
if bad:
    sys.exit("\n".join(bad))
PY
chrome="$(find "${OUT}/chrome" -name chrome-headless-shell -type f -perm +111 2>/dev/null | head -1 || true)"
if [[ -z "${chrome}" ]]; then
    echo "==> fetching chrome-headless-shell ${CHROME_VERSION}"
    npx -y @puppeteer/browsers@2.6.1 install "chrome-headless-shell@${CHROME_VERSION}" \
        --path "${OUT}/chrome" > /dev/null 2>&1 || true
    zip="$(find "${OUT}/chrome" -name '*.zip' | head -1)"
    [[ -n "${zip}" ]] && unzip -q -o "${zip}" -d "${OUT}/chrome/x"
    chrome="$(find "${OUT}/chrome" -name chrome-headless-shell -type f -perm +111 | head -1)"
fi
printf '{"executablePath":"%s","args":["--no-sandbox"]}\n' "${chrome}" > "${OUT}/puppeteer.json"
rm -f "${OUT}"/stack-*.mmd
awk -v d="${OUT}" '/^```mermaid/{f=1;n++;next} /^```/{f=0} f{print > (d "/stack-" n ".mmd")}' \
    "${FINCH_ROOT}/docs/STACK.md"
for m in "${OUT}"/stack-*.mmd; do
    npx -y "${MERMAID_CLI}" -q -p "${OUT}/puppeteer.json" -i "$m" -o "${m%.mmd}.svg" -b white
    echo "rendered ${m%.mmd}.svg"
done
