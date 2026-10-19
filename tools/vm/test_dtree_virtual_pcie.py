#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Focused checks for the optional Finch virtual PCIe ADT patch."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import struct
import sys
import unittest


SCRIPT = Path(__file__).with_name("dtree-virtual-pcie.py")
SPEC = importlib.util.spec_from_file_location("dtree_virtual_pcie", SCRIPT)
pcie = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pcie
SPEC.loader.exec_module(pcie)


def make_prop(name: bytes, value: bytes) -> pcie.Property:
    return pcie.Property(name, len(value), value)


def make_node(name: bytes, properties: list[pcie.Property] | None = None,
              children: list[pcie.Node] | None = None) -> pcie.Node:
    props = [make_prop(b"name", name + b"\0")] + (properties or [])
    return pcie.Node(name, props, children or [], b"\0" * 8)


def make_tree(occupied_irq: int | None = None,
              overlap_physical: bool = False,
              existing_pcie: bool = False) -> bytes:
    base_range = pcie.encode_arm_io_range(
        pcie.ARM_IO_CHILD_BASE, pcie.ARM_IO_PHYSICAL_BASE, pcie.ARM_IO_RANGE_SIZE
    )
    ranges_value = base_range
    if overlap_physical:
        ranges_value += pcie.encode_arm_io_range(
            0x400000000, pcie.ECAM_PHYSICAL_BASE, 0x1000
        )

    # Keep a nonzero byte after the property name's NUL and set the length flag.
    # The rewriter must retain both while growing this property's value.
    ranges_name_field = b"ranges\0" + b"\xA5" * 25
    ranges_raw_length = pcie.LENGTH_FLAGS_MASK | len(ranges_value)
    ranges_record = (ranges_name_field + struct.pack("<I", ranges_raw_length) +
                     ranges_value)
    ranges_prop = pcie.Property(
        b"ranges", ranges_raw_length, ranges_value, ranges_record, ranges_value
    )
    vendor_value = b"xyz"
    vendor_raw = (b"vendor-data\0".ljust(32, b"\0") +
                  struct.pack("<I", pcie.LENGTH_FLAGS_MASK | len(vendor_value)) +
                  vendor_value + b"\xA5")
    vendor_prop = pcie.Property(
        b"vendor-data", pcie.LENGTH_FLAGS_MASK | len(vendor_value),
        vendor_value, vendor_raw, vendor_value
    )

    cpu = make_node(b"cpu0", [
        make_prop(b"clock-frequency", struct.pack("<I", pcie.TIMEBASE_HZ)),
        make_prop(b"timebase-frequency", struct.pack("<I", pcie.TIMEBASE_HZ)),
    ])
    cpus = make_node(b"cpus", children=[cpu])
    aic = make_node(b"aic", [make_prop(b"AAPL,phandle", struct.pack("<I", pcie.AIC_PHANDLE))])
    arm_children = [aic]
    if occupied_irq is not None:
        arm_children.append(make_node(b"qemuport0", [
            make_prop(b"interrupt-parent", struct.pack("<I", pcie.AIC_PHANDLE)),
            make_prop(b"interrupts", struct.pack("<I", occupied_irq)),
        ]))
    if existing_pcie:
        arm_children.append(make_node(b"pcie"))
    arm_io = make_node(b"arm-io", [
        make_prop(b"#address-cells", struct.pack("<I", 2)),
        make_prop(b"#size-cells", struct.pack("<I", 2)),
        ranges_prop,
        vendor_prop,
    ], arm_children)
    root = make_node(b"device-tree", [
        make_prop(b"#address-cells", struct.pack("<I", 2)),
        make_prop(b"#size-cells", struct.pack("<I", 2)),
    ], [cpus, arm_io])
    return root.encode()


def nodes_by_path(root: pcie.Node) -> dict[tuple[bytes, ...], pcie.Node]:
    result = {}

    def visit(node: pcie.Node, path: tuple[bytes, ...]) -> None:
        result[path] = node
        for child in node.children:
            visit(child, path + (child.name,))

    visit(root, (root.name,))
    return result


class VirtualPcieDTreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = make_tree()

    def test_adds_only_the_empty_bridge_and_expected_ranges(self) -> None:
        original = pcie.parse_tree(self.source)
        result = pcie.add_virtual_pcie(self.source)
        root = pcie.parse_tree(result)
        arm_io = root.child(b"arm-io")
        bridge = arm_io.child(b"pcie")

        self.assertEqual(arm_io.children[-1].name, b"pcie")
        self.assertEqual([prop.name for prop in bridge.properties], [
            b"name", b"compatible", b"device_type", b"reg", b"#address-cells",
            b"#size-cells", b"interrupt-parent", b"device-interrupt-parent",
            b"interrupt-base", b"ranges",
        ])
        self.assertEqual(bridge.require_property(b"compatible").value, b"pcie,vmapple1\0")
        self.assertEqual(bridge.require_property(b"device_type").value, b"pci\0")
        self.assertEqual(bridge.require_property(b"reg").value,
                         struct.pack("<QQ", pcie.ECAM_CHILD_BASE, pcie.ECAM_SIZE))
        self.assertEqual(pcie.read_u32(bridge, b"#address-cells"), 3)
        self.assertEqual(pcie.read_u32(bridge, b"#size-cells"), 2)
        self.assertEqual(pcie.read_u32(bridge, b"interrupt-parent"), pcie.AIC_PHANDLE)
        self.assertEqual(pcie.read_u32(bridge, b"device-interrupt-parent"), pcie.AIC_PHANDLE)
        self.assertEqual(pcie.read_u32(bridge, b"interrupt-base"), pcie.INTERRUPT_BASE)
        self.assertIsNone(bridge.get_property(b"msi-frame-index"))
        self.assertEqual(bridge.children, [])

        ranges = pcie.ranges_entries(arm_io.require_property(b"ranges").value)
        self.assertEqual(ranges[-2:], [
            (pcie.ECAM_CHILD_BASE, pcie.ECAM_PHYSICAL_BASE, pcie.ECAM_SIZE),
            (pcie.MMIO_CHILD_BASE, pcie.MMIO_PHYSICAL_BASE, pcie.MMIO_SIZE),
        ])
        self.assertEqual(len(arm_io.children), len(original.child(b"arm-io").children) + 1)

    def test_keeps_existing_raw_properties_and_order(self) -> None:
        original = pcie.parse_tree(self.source)
        result = pcie.parse_tree(pcie.add_virtual_pcie(self.source))
        old_nodes = nodes_by_path(original)
        new_nodes = nodes_by_path(result)

        for path, old_node in old_nodes.items():
            new_node = new_nodes[path]
            self.assertEqual([prop.name for prop in old_node.properties],
                             [prop.name for prop in new_node.properties], path)
            for old_prop, new_prop in zip(old_node.properties, new_node.properties):
                if path == (b"device-tree", b"arm-io") and old_prop.name == b"ranges":
                    self.assertEqual(new_prop.raw_record[:32], old_prop.raw_record[:32])
                    self.assertEqual(
                        new_prop.raw_length & pcie.LENGTH_FLAGS_MASK,
                        old_prop.raw_length & pcie.LENGTH_FLAGS_MASK,
                    )
                else:
                    self.assertEqual(new_prop.raw_record, old_prop.raw_record, (path, old_prop.name))

        self.assertEqual(new_nodes[(b"device-tree", b"arm-io")].children[:-1],
                         old_nodes[(b"device-tree", b"arm-io")].children)

    def test_rejects_used_aic_line(self) -> None:
        with self.assertRaisesRegex(pcie.DTreeError, "already in use"):
            pcie.add_virtual_pcie(make_tree(occupied_irq=pcie.INTERRUPT_BASE + 1))

    def test_rejects_existing_pcie_node(self) -> None:
        with self.assertRaisesRegex(pcie.DTreeError, "already exists"):
            pcie.add_virtual_pcie(make_tree(existing_pcie=True))

    def test_rejects_overlapping_physical_range(self) -> None:
        with self.assertRaisesRegex(pcie.DTreeError, "physical range overlaps"):
            pcie.add_virtual_pcie(make_tree(overlap_physical=True))

    def test_rejects_same_input_and_output_path(self) -> None:
        self.assertTrue(pcie.same_file(Path(__file__), Path(__file__).resolve()))


if __name__ == "__main__":
    unittest.main()
