#!/usr/bin/env python3
"""Check data-image arguments without starting QEMU or attaching host disks."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]


class DataImageArguments(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="finch-run-data-")
        self.root = Path(self.temp.name)
        vm = self.root / "tools/vm"
        vm.mkdir(parents=True)
        for name in ("run.sh", "dtree-timebase.py", "dtree-virtual-pcie.py"):
            shutil.copy2(SOURCE / "tools/vm" / name, vm / name)
        firmware = self.root / "third_party/darwin-vm/firmware"
        firmware.mkdir(parents=True)
        shutil.copy2(SOURCE / "third_party/darwin-vm/firmware/dtree", firmware / "dtree")
        for name in ("ramdisk.dmg", "ramdisk.tc", "bootkc"):
            (firmware / name).write_bytes(b"fixture")
        qemu = self.root / "third_party/darwin-vm/qemu-sptm/build/qemu-system-aarch64"
        qemu.parent.mkdir(parents=True)
        qemu.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                        "open(os.environ['FINCH_ARGV_OUTPUT'], 'w').write(json.dumps(sys.argv[1:]))\n")
        qemu.chmod(0o755)
        self.output = self.root / "argv.json"
        self.env = {k: v for k, v in os.environ.items() if k not in (
            "FINCH_DATA_IMAGE", "FINCH_BOOTKC", "FINCH_INIT", "RAMDISK", "KC", "TC",
            "DEBUG", "GDB", "QEMUPORT", "BOOT_ARGS_EXTRA")}
        self.env["FINCH_ARGV_OUTPUT"] = str(self.output)
        self.source_tree = (firmware / "dtree").read_bytes()

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, image=None):
        env = dict(self.env)
        if image is not None:
            env["FINCH_DATA_IMAGE"] = str(image)
        result = subprocess.run(["bash", str(self.root / "tools/vm/run.sh")],
                                env=env, capture_output=True, text=True)
        self.assertEqual((self.root / "third_party/darwin-vm/firmware/dtree").read_bytes(),
                         self.source_tree)
        return result

    def test_default_has_no_disk_or_bridge(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.output.read_text())
        self.assertEqual(args[args.index("-M") + 1], "darwin")
        self.assertNotIn("-drive", args)
        self.assertNotIn("-device", args)

    def test_existing_image_enables_bridge_and_escapes_commas(self):
        image = self.root / "data ,if=ide.raw"
        image.write_bytes(b"disposable image")
        result = self.run_script(image)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.output.read_text())
        self.assertEqual(args[args.index("-M") + 1], "darwin,finch-pcie=on")
        self.assertEqual(args[args.index("-drive") + 1],
                         "file=" + str(image).replace(",", ",,") + ",if=none,format=raw,id=finchdata")
        self.assertEqual(args[args.index("-device") + 1],
                         "virtio-blk-pci,drive=finchdata,disable-legacy=on")
        self.assertTrue(args[args.index("-dtree") + 1].endswith("/dtree-pcie"))
        self.assertEqual(image.read_bytes(), b"disposable image")

    def test_bad_images_never_launch_or_create_data(self):
        empty = self.root / "empty.raw"
        empty.touch()
        target = self.root / "target.raw"
        target.write_bytes(b"target")
        link = self.root / "linked.raw"
        link.symlink_to(target)
        missing = self.root / "missing.raw"
        for path in (empty, link, missing, self.root, "/dev/null", "relative.raw"):
            with self.subTest(path=str(path)):
                result = self.run_script(path)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())
                self.assertFalse(missing.exists())
                self.assertEqual(target.read_bytes(), b"target")


if __name__ == "__main__":
    unittest.main()
