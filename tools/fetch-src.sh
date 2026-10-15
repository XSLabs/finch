#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Clone the open-source projects pinned in userland/projects.txt and
# userland/third-party-projects.txt into build/src/<project>. Re-running is
# cheap: existing checkouts at the right tag are left alone.
#   tools/fetch-src.sh            # all projects
#   tools/fetch-src.sh file_cmds  # just one
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${FINCH_ROOT}/build/src"
mkdir -p "${SRC}"

fetch() {
    local name="$1" tag="$2" url="$3"
    local dir="${SRC}/${name}"
    if [[ -d "${dir}" ]]; then
        local have
        have=$(git -C "${dir}" describe --tags --exact-match 2>/dev/null || echo none)
        [[ "${have}" == "${tag}" ]] && return
        echo "${name}: have ${have}, want ${tag}; re-cloning"
        rm -rf "${dir}"
    fi
    echo "fetching ${tag}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${tag}" \
        "${url}" "${dir}"
}

while read -r name tag; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    if [[ $# -gt 0 && " $* " != *" ${name} "* ]]; then continue; fi
    fetch "${name}" "${tag}" "https://github.com/apple-oss-distributions/${name}.git"
done < "${FINCH_ROOT}/userland/projects.txt"

if [[ -f "${FINCH_ROOT}/userland/third-party-projects.txt" ]]; then
    while read -r name tag url; do
        [[ -z "${name}" || "${name}" == \#* ]] && continue
        if [[ $# -gt 0 && " $* " != *" ${name} "* ]]; then continue; fi
        fetch "${name}" "${tag}" "${url}"
    done < "${FINCH_ROOT}/userland/third-party-projects.txt"
fi
