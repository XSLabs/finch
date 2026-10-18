#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Compare CoreData write-and-reopen results from Apple and the Finch VM."""
from __future__ import annotations

import difflib
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HOST_TEST = ROOT / "build/userland/finch-coredata-test"
HOST_MODEL = ROOT / "build/userland/CoreDataTest.momd"
GUEST_TEST = "/usr/local/bin/finch-coredata-test"
GUEST_MODEL = "/usr/local/share/finch/CoreDataTest.momd"
LOCK = ROOT / "tools/vm/with-vm-lock.sh"
SMOKE = ROOT / "tools/vm/smoke.exp"
HOST_TIMEOUT = 240
VM_TIMEOUT = 1200


def shell_quote(value: str | Path) -> str:
    return shlex.quote(str(value))


def behavior_output(output: str, label: str) -> list[str]:
    """Drop the line that names the loaded CoreData library and keep the results."""
    lines = output.replace("\r", "").splitlines()
    if not lines or not lines[0].startswith("CoreData: "):
        raise RuntimeError(f"{label} did not print its CoreData library name")
    rows = lines[1:]
    if not rows or any(not row for row in rows):
        raise RuntimeError(f"{label} printed no complete store results")
    return rows


def marked_output(console: str, begin: str, end: str) -> str:
    """Read output between guest markers, ignoring the command echoed by the shell."""
    start_marker = console.rfind(begin)
    if start_marker < 0:
        raise RuntimeError(f"VM did not print the output marker {begin}")
    start = start_marker + len(begin)
    while start < len(console) and console[start] in "\r\n":
        start += 1
    finish = console.find(end, start)
    if finish < 0:
        raise RuntimeError(f"VM did not print the output marker {end}")
    return console[start:finish].replace("\r", "").strip("\n")


def require_same_output(label: str, expected: list[str], actual: list[str]) -> None:
    if expected == actual:
        return
    diff = "".join(difflib.unified_diff(
        [line + "\n" for line in expected], [line + "\n" for line in actual],
        fromfile="Apple", tofile="Finch VM",
    ))
    raise RuntimeError(f"{label} differs:\n{diff}")


def run_host(binary: Path, mode: str, store: Path, model: Path,
             output_path: Path, error_path: Path) -> list[str]:
    try:
        with output_path.open("w", encoding="utf-8") as output, error_path.open("w", encoding="utf-8") as error:
            result = subprocess.run([str(binary), mode, str(store), str(model)], cwd=ROOT,
                                    stdout=output, stderr=error, env=apple_environment(),
                                    timeout=HOST_TIMEOUT, check=False)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Apple CoreData {mode} timed out after {HOST_TIMEOUT} seconds") from error
    if result.returncode:
        detail = error_path.read_text(encoding="utf-8", errors="replace").strip()
        raise RuntimeError(f"Apple CoreData {mode} failed (exit {result.returncode}): {detail}")
    return behavior_output(output_path.read_text(encoding="utf-8", errors="replace"),
                           f"Apple CoreData {mode}")


def apple_environment() -> dict[str, str]:
    """Keep the reference run on Apple's installed frameworks."""
    env = dict(os.environ)
    for name in tuple(env):
        if name.startswith(("DYLD_", "FINCH_")):
            env.pop(name, None)
    env.pop("CFFIXED_USER_HOME", None)
    return env


def guest_command(token: str) -> tuple[str, str, str, tuple[str, str, str, str]]:
    guest_dir = f"/tmp/finch-coredata-{token}"
    store = f"{guest_dir}/guest.sqlite"
    write_out, read_out = f"{guest_dir}/write.out", f"{guest_dir}/read.out"
    write_err, read_err = f"{guest_dir}/write.err", f"{guest_dir}/read.err"
    begin_write, end_write = f"FINCH_CORE_DATA_{token}_WRITE_BEGIN", f"FINCH_CORE_DATA_{token}_WRITE_END"
    begin_read, end_read = f"FINCH_CORE_DATA_{token}_READ_BEGIN", f"FINCH_CORE_DATA_{token}_READ_END"

    command = " && ".join((
        f"rm -rf {shell_quote(guest_dir)}",
        f"mkdir -m 700 -p {shell_quote(guest_dir)}",
        f"{GUEST_TEST} write {shell_quote(store)} {GUEST_MODEL} > {shell_quote(write_out)} 2> {shell_quote(write_err)}",
        f"{GUEST_TEST} read {shell_quote(store)} {GUEST_MODEL} > {shell_quote(read_out)} 2> {shell_quote(read_err)}",
        "cat /dev/null",
        f"printf '%s\\n' {shell_quote(begin_write)}",
        f"cat {shell_quote(write_out)}",
        f"printf '%s\\n' {shell_quote(end_write)}",
        f"printf '%s\\n' {shell_quote(begin_read)}",
        f"cat {shell_quote(read_out)}",
        f"printf '%s\\n' {shell_quote(end_read)}",
    ))
    errors = f"cat {shell_quote(write_err)} {shell_quote(read_err)} 2>/dev/null || true"
    cleanup = f"rm -rf {shell_quote(guest_dir)}"
    return command, errors, cleanup, (begin_write, end_write, begin_read, end_read)


def run_guest(token: str) -> tuple[list[str], list[str]]:
    command, errors, cleanup, markers = guest_command(token)
    try:
        result = subprocess.run(
            [str(LOCK), "expect", str(SMOKE),
             "export FINCH_THEME=Classic FINCH_TEST_TICK=1", command, errors, cleanup],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=VM_TIMEOUT, check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Finch VM CoreData write/read timed out after {VM_TIMEOUT} seconds") from error
    # Keep the console's CR-CR-LF intact until parsing. Text mode turns each
    # carriage return into a new line and invents empty result rows.
    console = result.stdout.decode("utf-8", errors="replace")
    with tempfile.NamedTemporaryFile(prefix="finch-coredata-vm-", suffix=".log", mode="w", delete=False) as log:
        log.write(console)
        print(f"CoreData VM log: {log.name}", flush=True)
    if result.returncode:
        raise RuntimeError(f"Finch VM CoreData write/read failed (exit {result.returncode}):\n{console[-5000:]}")
    begin_write, end_write, begin_read, end_read = markers
    write = behavior_output(marked_output(console, begin_write, end_write), "Finch VM CoreData write")
    read = behavior_output(marked_output(console, begin_read, end_read), "Finch VM CoreData read")
    return write, read


def main() -> int:
    if not HOST_TEST.is_file() or not os.access(HOST_TEST, os.X_OK):
        raise RuntimeError(f"host CoreData test is not built: {HOST_TEST} (run make -C userland/tests)")
    if not HOST_MODEL.is_dir():
        raise RuntimeError(f"host CoreData model is not built: {HOST_MODEL} (run make -C userland/tests)")

    with tempfile.TemporaryDirectory(prefix="finch-coredata-apple-") as folder:
        private = Path(folder)
        store = private / "apple.sqlite"
        apple_write = run_host(HOST_TEST, "write", store, HOST_MODEL,
                               private / "apple-write.out", private / "apple-write.err")
        apple_read = run_host(HOST_TEST, "read", store, HOST_MODEL,
                              private / "apple-read.out", private / "apple-read.err")

        finch_write, finch_read = run_guest(secrets.token_hex(8))
        require_same_output("Apple reopen", apple_write, apple_read)
        require_same_output("Finch VM reopen", finch_write, finch_read)
        require_same_output("CoreData write results", apple_write, finch_write)
        require_same_output("CoreData reopen results", apple_read, finch_read)

    print("CoreData VM test passed: Apple and Finch each wrote and reopened matching records.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        print(f"coredata-vm-test: {error}", file=sys.stderr)
        sys.exit(1)
