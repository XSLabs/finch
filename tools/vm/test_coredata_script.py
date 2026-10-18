#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Small local checks for the CoreData VM runner's output handling."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("test-coredata.py")
spec = importlib.util.spec_from_file_location("coredata_vm_test", SCRIPT)
coredata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coredata)


class CoreDataVMRunnerTests(unittest.TestCase):
    def test_guest_console_carriage_returns_do_not_add_empty_rows(self):
        token = "console-test"
        markers = coredata.guest_command(token)[3]
        rows = "CoreData: /System/Library/Frameworks/CoreData.framework\r\r\ncount=2\r\r\nbravo|9|Ada"
        console = (f"{markers[0]}\r\r\n{rows}\r\r\n{markers[1]}\r\r\n"
                   f"{markers[2]}\r\r\n{rows}\r\r\n{markers[3]}\r\r\n")
        result = coredata.subprocess.CompletedProcess([], 0, console.encode())
        with patch.object(coredata.subprocess, "run", return_value=result) as run:
            write, read = coredata.run_guest(token)
        self.assertEqual(write, ["count=2", "bravo|9|Ada"])
        self.assertEqual(read, write)
        self.assertNotIn("text", run.call_args.kwargs)

    def test_host_timeout_is_reported_clearly(self):
        with tempfile.TemporaryDirectory(prefix="coredata-host-timeout-") as folder:
            root = Path(folder)
            with patch.object(
                coredata.subprocess, "run",
                side_effect=coredata.subprocess.TimeoutExpired(["host-test"], coredata.HOST_TIMEOUT),
            ) as run:
                with self.assertRaisesRegex(
                    RuntimeError,
                    f"Apple CoreData write timed out after {coredata.HOST_TIMEOUT} seconds",
                ):
                    coredata.run_host(
                        root / "test", "write", root / "store", root / "model",
                        root / "output", root / "error",
                    )
            self.assertEqual(run.call_args.kwargs["timeout"], coredata.HOST_TIMEOUT)

    def test_vm_timeout_is_reported_clearly(self):
        with patch.object(
            coredata.subprocess, "run",
            side_effect=coredata.subprocess.TimeoutExpired(["vm-test"], coredata.VM_TIMEOUT),
        ) as run:
            with self.assertRaisesRegex(
                RuntimeError,
                f"Finch VM CoreData write/read timed out after {coredata.VM_TIMEOUT} seconds",
            ):
                coredata.run_guest("timeout-test")
        self.assertEqual(run.call_args.kwargs["timeout"], coredata.VM_TIMEOUT)

    def test_behavior_output_drops_only_the_framework_banner(self):
        output = "CoreData: /System/Library/Frameworks/CoreData.framework\ncount=2\nbravo|9|Ada\n"
        self.assertEqual(coredata.behavior_output(output, "test"), ["count=2", "bravo|9|Ada"])

    def test_behavior_output_requires_results_after_the_banner(self):
        with self.assertRaisesRegex(RuntimeError, "no complete store results"):
            coredata.behavior_output("CoreData: Apple\n", "test")
        with self.assertRaisesRegex(RuntimeError, "library name"):
            coredata.behavior_output("count=2\n", "test")

    def test_guest_output_markers_skip_the_echoed_command(self):
        begin, end = "FINCH_CORE_DATA_abc_WRITE_BEGIN", "FINCH_CORE_DATA_abc_WRITE_END"
        console = (
            f"# printf '{begin}' '{end}'\r\n"
            f"{begin}\r\nCoreData: /System/Library/Frameworks/CoreData.framework\r\n"
            f"count=2\r\nbravo|9|Ada\r\n{end}\r\n"
        )
        output = coredata.marked_output(console, begin, end)
        self.assertEqual(coredata.behavior_output(output, "guest"), ["count=2", "bravo|9|Ada"])

    def test_output_mismatch_has_a_readable_diff(self):
        with self.assertRaisesRegex(RuntimeError, "CoreData reopen differs"):
            coredata.require_same_output("CoreData reopen", ["count=2"], ["count=1"])


if __name__ == "__main__":
    unittest.main()
