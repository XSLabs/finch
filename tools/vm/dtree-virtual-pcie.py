#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Add Finch's empty virtual PCIe root to a corrected M4 ADT.

Usage: tools/vm/dtree-virtual-pcie.py TIMEBASE_CORRECTED_ADT OUTPUT_ADT

The source is never edited. Existing ADT property records are copied as raw
bytes so their order and length flags stay intact.
"""

from __future__ import annotations

from dataclasses import dataclass
import argparse
import os
from pathlib import Path
import struct


TIMEBASE_HZ = 24_000_000
LENGTH_MASK = 0x7FFFFFFF
LENGTH_FLAGS_MASK = 0x80000000

ARM_IO_CHILD_BASE = 0
ARM_IO_PHYSICAL_BASE = 0x200000000
ARM_IO_RANGE_SIZE = 0x3A0000000

ECAM_CHILD_BASE = 0x3A0000000
ECAM_PHYSICAL_BASE = 0x40000000
ECAM_SIZE = 0x10000000

MMIO_CHILD_BASE = 0x3B0000000
MMIO_PHYSICAL_BASE = 0x50000000
MMIO_SIZE = 0x1FFF0000

AIC_PHANDLE = 0xBA
INTERRUPT_BASE = 0x20
INTERRUPT_COUNT = 16


class DTreeError(ValueError):
    """The input tree is malformed or does not match the expected M4 layout."""


@dataclass
class Property:
    name: bytes
    raw_length: int
    value: bytes
    raw_record: bytes | None = None
    original_value: bytes | None = None

    def encode(self) -> bytes:
        if self.raw_record is not None and self.value == self.original_value:
            return self.raw_record

        if len(self.value) > LENGTH_MASK:
            raise DTreeError(f"property {self.name!r} is too large")
        pad_len = (-len(self.value)) & 3
        if self.raw_record is not None:
            old_pad = self.raw_record[36 + len(self.original_value or b"") :]
            if len(old_pad) != pad_len:
                raise DTreeError(
                    f"changing property {self.name!r} would change its padding size"
                )
            padding = old_pad
            flags = self.raw_length & LENGTH_FLAGS_MASK
        else:
            padding = b"\0" * pad_len
            flags = 0

        if self.raw_record is not None:
            name_field = self.raw_record[:32]
        else:
            name_field = self.name[:32].ljust(32, b"\0")
        return (name_field + struct.pack("<I", flags | len(self.value)) +
                self.value + padding)


@dataclass
class Node:
    name: bytes
    properties: list[Property]
    children: list["Node"]
    raw_header: bytes

    def get_property(self, name: bytes) -> Property | None:
        matches = [prop for prop in self.properties if prop.name == name]
        if len(matches) > 1:
            raise DTreeError(f"node {self.name!r} has duplicate {name!r} properties")
        return matches[0] if matches else None

    def require_property(self, name: bytes) -> Property:
        prop = self.get_property(name)
        if prop is None:
            raise DTreeError(f"node {self.name!r} is missing {name.decode(errors='replace')}")
        return prop

    def child(self, name: bytes) -> "Node":
        matches = [node for node in self.children if node.name == name]
        if len(matches) != 1:
            raise DTreeError(
                f"expected one {name.decode(errors='replace')} node below "
                f"{self.name.decode(errors='replace')}, found {len(matches)}"
            )
        return matches[0]

    def walk(self):
        yield self
        for child in self.children:
            yield from child.walk()

    def encode(self) -> bytes:
        header = bytearray(self.raw_header)
        struct.pack_into("<II", header, 0, len(self.properties), len(self.children))
        return (bytes(header) + b"".join(prop.encode() for prop in self.properties) +
                b"".join(child.encode() for child in self.children))


def parse_node(data: bytes, offset: int = 0) -> tuple[Node, int]:
    if offset + 8 > len(data):
        raise DTreeError("truncated ADT node header")
    header = data[offset:offset + 8]
    property_count, child_count = struct.unpack("<II", header)
    offset += 8
    properties = []
    node_name = None

    for _ in range(property_count):
        start = offset
        if offset + 36 > len(data):
            raise DTreeError("truncated ADT property header")
        name_field = data[offset:offset + 32]
        prop_name = name_field.split(b"\0", 1)[0]
        raw_length = struct.unpack_from("<I", data, offset + 32)[0]
        value_length = raw_length & LENGTH_MASK
        value_start = offset + 36
        value_end = value_start + value_length
        record_end = value_start + ((value_length + 3) & ~3)
        if record_end > len(data):
            raise DTreeError(f"truncated ADT property {prop_name!r}")
        value = data[value_start:value_end]
        properties.append(Property(
            name=prop_name,
            raw_length=raw_length,
            value=value,
            raw_record=data[start:record_end],
            original_value=value,
        ))
        offset = record_end
        if prop_name == b"name":
            node_name = value.split(b"\0", 1)[0]

    if node_name is None:
        raise DTreeError("ADT node is missing its name property")

    node = Node(node_name, properties, [], header)
    for _ in range(child_count):
        child, offset = parse_node(data, offset)
        node.children.append(child)
    return node, offset


def parse_tree(data: bytes) -> Node:
    root, end = parse_node(data)
    if end != len(data):
        raise DTreeError(f"ADT has {len(data) - end} trailing bytes")
    if root.name != b"device-tree":
        raise DTreeError(f"unexpected ADT root node {root.name!r}")
    return root


def read_u32(node: Node, name: bytes) -> int:
    value = node.require_property(name).value
    if len(value) != 4:
        raise DTreeError(f"{node.name!r}/{name!r} must be 4 bytes")
    return struct.unpack("<I", value)[0]


def read_u64(node: Node, name: bytes) -> int:
    value = node.require_property(name).value
    if len(value) != 8:
        raise DTreeError(f"{node.name!r}/{name!r} must be 8 bytes")
    return struct.unpack("<Q", value)[0]


def u32_pair_to_u64(low: int, high: int) -> int:
    return low | (high << 32)


def u64_to_cells(value: int) -> tuple[int, int]:
    return value & 0xFFFFFFFF, value >> 32


def ranges_entries(value: bytes) -> list[tuple[int, int, int]]:
    if len(value) % 24:
        raise DTreeError("arm-io/ranges does not contain whole six-cell entries")
    entries = []
    for offset in range(0, len(value), 24):
        child_low, child_high, parent_low, parent_high, size_low, size_high = \
            struct.unpack_from("<6I", value, offset)
        entries.append((u32_pair_to_u64(child_low, child_high),
                        u32_pair_to_u64(parent_low, parent_high),
                        u32_pair_to_u64(size_low, size_high)))
    return entries


def intervals_overlap(base_a: int, size_a: int, base_b: int, size_b: int) -> bool:
    return base_a < base_b + size_b and base_b < base_a + size_a


def encode_arm_io_range(child: int, physical: int, size: int) -> bytes:
    return struct.pack("<6I", *u64_to_cells(child), *u64_to_cells(physical),
                       *u64_to_cells(size))


def encode_pcie_node() -> Node:
    pci_ranges = (struct.pack("<I", 0x02000000) +
                  struct.pack("<Q", MMIO_PHYSICAL_BASE) +
                  struct.pack("<Q", MMIO_CHILD_BASE) +
                  struct.pack("<Q", MMIO_SIZE))
    values = [
        (b"name", b"pcie\0"),
        (b"compatible", b"pcie,vmapple1\0"),
        (b"device_type", b"pci\0"),
        (b"reg", struct.pack("<QQ", ECAM_CHILD_BASE, ECAM_SIZE)),
        (b"#address-cells", struct.pack("<I", 3)),
        (b"#size-cells", struct.pack("<I", 2)),
        (b"interrupt-parent", struct.pack("<I", AIC_PHANDLE)),
        (b"device-interrupt-parent", struct.pack("<I", AIC_PHANDLE)),
        (b"interrupt-base", struct.pack("<I", INTERRUPT_BASE)),
        (b"ranges", pci_ranges),
    ]
    properties = [Property(name, len(value), value) for name, value in values]
    return Node(b"pcie", properties, [], b"\0" * 8)


def validate_input(root: Node) -> tuple[Node, Property, list[tuple[int, int, int]]]:
    cpu = root.child(b"cpus").child(b"cpu0")
    for name in (b"clock-frequency", b"timebase-frequency"):
        if read_u32(cpu, name) != TIMEBASE_HZ:
            raise DTreeError(f"cpus/cpu0/{name.decode()} is not timebase-corrected")

    if read_u32(root, b"#address-cells") != 2:
        raise DTreeError("device-tree must use two address cells for arm-io parent addresses")

    arm_io = root.child(b"arm-io")
    if read_u32(arm_io, b"#address-cells") != 2 or \
            read_u32(arm_io, b"#size-cells") != 2:
        raise DTreeError("arm-io must use two address cells and two size cells")

    ranges_prop = arm_io.require_property(b"ranges")
    entries = ranges_entries(ranges_prop.value)
    expected = (ARM_IO_CHILD_BASE, ARM_IO_PHYSICAL_BASE, ARM_IO_RANGE_SIZE)
    if entries.count(expected) != 1:
        raise DTreeError("arm-io/ranges does not have the expected M4 base mapping")

    aic = arm_io.child(b"aic")
    if read_u32(aic, b"AAPL,phandle") != AIC_PHANDLE:
        raise DTreeError("arm-io/aic does not have AAPL,phandle 0xba")

    irq_end = INTERRUPT_BASE + INTERRUPT_COUNT
    for node in root.walk():
        parents = (node.get_property(b"interrupt-parent"),
                   node.get_property(b"device-interrupt-parent"))
        direct_aic = any(parent is not None and parent.value ==
                         struct.pack("<I", AIC_PHANDLE) for parent in parents)
        if not direct_aic:
            continue
        interrupts = node.get_property(b"interrupts")
        if interrupts is None:
            continue
        if len(interrupts.value) % 4:
            raise DTreeError(f"{node.name!r}/interrupts is not a list of 32-bit AIC lines")
        for (irq,) in struct.iter_unpack("<I", interrupts.value):
            if INTERRUPT_BASE <= irq < irq_end:
                raise DTreeError(f"AIC line 0x{irq:x} is already in use")

    if any(child.name == b"pcie" for child in arm_io.children):
        raise DTreeError("arm-io/pcie already exists")

    new_ranges = [
        (ECAM_CHILD_BASE, ECAM_PHYSICAL_BASE, ECAM_SIZE),
        (MMIO_CHILD_BASE, MMIO_PHYSICAL_BASE, MMIO_SIZE),
    ]
    for index, (child_base, physical_base, size) in enumerate(new_ranges):
        for old_child, old_physical, old_size in entries:
            if intervals_overlap(child_base, size, old_child, old_size):
                raise DTreeError("new PCI child address range overlaps arm-io/ranges")
            if intervals_overlap(physical_base, size, old_physical, old_size):
                raise DTreeError("new PCI physical range overlaps arm-io/ranges")
        for other_child, other_physical, other_size in new_ranges[:index]:
            if intervals_overlap(child_base, size, other_child, other_size):
                raise DTreeError("new PCI child address ranges overlap")
            if intervals_overlap(physical_base, size, other_physical, other_size):
                raise DTreeError("new PCI physical ranges overlap")

    return arm_io, ranges_prop, entries


def add_virtual_pcie(data: bytes) -> bytes:
    root = parse_tree(data)
    arm_io, ranges_prop, _ = validate_input(root)
    ranges_prop.value += (
        encode_arm_io_range(ECAM_CHILD_BASE, ECAM_PHYSICAL_BASE, ECAM_SIZE) +
        encode_arm_io_range(MMIO_CHILD_BASE, MMIO_PHYSICAL_BASE, MMIO_SIZE)
    )
    arm_io.children.append(encode_pcie_node())
    result = root.encode()
    parse_tree(result)
    return result


def same_file(source: Path, output: Path) -> bool:
    if source.resolve() == output.resolve():
        return True
    try:
        return os.path.samefile(source, output)
    except FileNotFoundError:
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="timebase-corrected M4 ADT")
    parser.add_argument("output", type=Path, help="separate patched ADT path")
    args = parser.parse_args()

    try:
        if same_file(args.input, args.output):
            raise DTreeError("input and output must be different files")
        result = add_virtual_pcie(args.input.read_bytes())
        args.output.write_bytes(result)
    except (DTreeError, OSError) as error:
        parser.exit(2, f"{parser.prog}: error: {error}\n")


if __name__ == "__main__":
    main()
