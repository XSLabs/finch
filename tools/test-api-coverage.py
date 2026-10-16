#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Small parser checks for tools/api-coverage.py; no Apple SDK is needed."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("api-coverage.py")
spec = importlib.util.spec_from_file_location("api_coverage", SCRIPT)
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class CoverageParsers(unittest.TestCase):
    def test_tbd_exports_are_limited_to_arm64e_macos(self):
        text = """--- !tapi-tbd
tbd-version: 4
targets: [ x86_64-macos, arm64e-macos ]
install-name: '/usr/lib/libExample.dylib'
exports:
  - targets: [ x86_64-macos ]
    symbols: [ _x86Only ]
  - targets: [ arm64e-macos ]
    symbols: [ _publicCall, '_$sExampleSwift' ]
    objc-classes: [ ExampleObject ]
reexported-libraries:
  - targets: [ arm64e-macos ]
    libraries: [ '/System/Library/Frameworks/Parent.framework/Versions/A/Frameworks/Child.framework/Versions/A/Child' ]
"""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "libExample.tbd"
            path.write_text(text)
            exports = coverage.tbd_exports(path)
        self.assertEqual(exports["install_name"], "/usr/lib/libExample.dylib")
        self.assertEqual(exports["symbols"], ["_$sExampleSwift", "_publicCall"])
        self.assertEqual(exports["classes"], ["ExampleObject"])
        self.assertEqual(exports["libraries"], [
            "/System/Library/Frameworks/Parent.framework/Versions/A/Frameworks/Child.framework/Versions/A/Child"])

    def test_nested_frameworks_and_reexports_are_inventoried(self):
        with tempfile.TemporaryDirectory() as folder:
            sdk = Path(folder)
            frameworks = sdk / "System/Library/Frameworks"
            parent = frameworks / "Parent.framework/Versions/A"
            child = parent / "Frameworks/Child.framework/Versions/A"
            parent.mkdir(parents=True)
            child.mkdir(parents=True)
            (parent / "Parent.tbd").write_text("""--- !tapi-tbd
tbd-version: 4
targets: [ arm64e-macos ]
install-name: '/System/Library/Frameworks/Parent.framework/Versions/A/Parent'
reexported-libraries:
  - targets: [ arm64e-macos ]
    libraries: [ '/System/Library/Frameworks/Parent.framework/Versions/A/Frameworks/Child.framework/Versions/A/Child' ]
""")
            (child / "Child.tbd").write_text("""--- !tapi-tbd
tbd-version: 4
targets: [ arm64e-macos ]
install-name: '/System/Library/Frameworks/Parent.framework/Versions/A/Frameworks/Child.framework/Versions/A/Child'
exports:
  - targets: [ arm64e-macos ]
    symbols: [ _childCall ]
""")
            specs = coverage.framework_specs(sdk)
            coverage.resolve_reexports(specs, sdk)
        by_id = {item["id"]: item for item in specs}
        self.assertIn("Parent/Child", by_id)
        self.assertEqual(by_id["Parent"]["reexport_ids"], ["Parent/Child"])

    def test_reexported_framework_dylib_and_usr_lib_subfolder_are_inventoried(self):
        with tempfile.TemporaryDirectory() as folder:
            sdk = Path(folder)
            parent = sdk / "System/Library/Frameworks/Parent.framework/Versions/A"
            libraries = parent / "Libraries"
            libraries.mkdir(parents=True)
            (parent / "Parent.tbd").write_text("""--- !tapi-tbd
tbd-version: 4
targets: [ arm64e-macos ]
install-name: '/System/Library/Frameworks/Parent.framework/Versions/A/Parent'
reexported-libraries:
  - targets: [ arm64e-macos ]
    libraries: [ '/System/Library/Frameworks/Parent.framework/Versions/A/Libraries/libChild.dylib' ]
""")
            (libraries / "libChild.tbd").write_text("""--- !tapi-tbd
tbd-version: 4
targets: [ arm64e-macos ]
install-name: '/System/Library/Frameworks/Parent.framework/Versions/A/Libraries/libChild.dylib'
exports:
  - targets: [ arm64e-macos ]
    symbols: [ _childCall ]
""")
            rdma = sdk / "usr/lib/rdma"
            rdma.mkdir(parents=True)
            (rdma / "libibverbs.tbd").write_text("""--- !tapi-tbd
tbd-version: 4
targets: [ arm64e-macos ]
install-name: '/usr/lib/rdma/libibverbs.dylib'
exports:
  - targets: [ arm64e-macos ]
    symbols: [ _ibv_open_device ]
""")
            specs = coverage.framework_specs(sdk)
            coverage.resolve_reexports(specs, sdk)

        by_id = {item["id"]: item for item in specs}
        self.assertEqual(by_id["Parent"]["reexport_ids"], ["Parent/libChild"])
        self.assertEqual(by_id["Parent/libChild"]["kind"], "dylib")
        self.assertIn("rdma/libibverbs", by_id)

    def test_reexported_apis_join_the_parent_manifest(self):
        item = {"id": "c:_childCall", "kind": "C symbol", "name": "childCall",
                "check": {"type": "symbol", "symbol": "_childCall"}}
        specs = {
            "Parent": {"id": "Parent", "reexport_ids": ["Parent/Child"]},
            "Parent/Child": {"id": "Parent/Child", "reexport_ids": []},
        }
        manifests = {
            "Parent": ([], [], ["TAPI export list"]),
            "Parent/Child": ([item], [], ["TAPI export list"]),
        }
        items, errors, sources = coverage.merged_sdk_manifest(
            "Parent", specs, manifests, {})
        self.assertEqual(errors, [])
        self.assertIn("public APIs re-exported from Parent/Child", sources)
        self.assertEqual(items[0]["id"], "c:_childCall")
        self.assertTrue(items[0]["reexported"])
        self.assertEqual(items[0]["origin_framework"], "Parent/Child")

    def test_spi_and_unavailable_declarations_are_excluded(self):
        self.assertTrue(coverage.unavailable_on_macos("API_UNAVAILABLE(macos)"))
        self.assertTrue(coverage.unavailable_on_macos("API_DEPRECATED(\"gone\", macos(10.0, unavailable))"))
        self.assertTrue(coverage.unavailable_on_macos("NS_UNAVAILABLE"))
        self.assertFalse(coverage.unavailable_on_macos("API_UNAVAILABLE(ios)"))
        self.assertTrue(coverage.is_spi("API_SPI_AVAILABLE(macos(14.0))"))
        regions = coverage.unavailable_regions("start\nAPI_UNAVAILABLE_BEGIN(macos)\nitem\nAPI_UNAVAILABLE_END\nend")
        self.assertTrue(coverage.in_unavailable_region(35, regions))
        self.assertFalse(coverage.in_unavailable_region(0, regions))

    def test_objc_headers_yield_classes_methods_and_properties(self):
        header = """@interface ExampleThing : NSObject
- (void)run:(id)value with:(id)other;
- (void)old API_UNAVAILABLE(macos);
API_UNAVAILABLE_BEGIN(macos)
- (void)macOnly;
API_UNAVAILABLE_END
 - (void)never NS_UNAVAILABLE;
@property (readonly, getter=displayName) NSString *name;
@end
@protocol ExampleDelegate <NSObject>
- (void)finish;
@property (readonly) id result;
@end
@interface HiddenThing API_UNAVAILABLE(macos) : NSObject
- (void)hiddenMethod;
@end
@interface SPIThing API_SPI_AVAILABLE(macos(14.0)) : NSObject
- (void)spiMethod;
@end
"""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Headers").mkdir()
            (root / "Headers/Example.h").write_text(header)
            items, files, excluded_classes = coverage.objc_items(root)
        by_id = {item["id"]: item for item in items}
        self.assertEqual(len(files), 1)
        self.assertIn("objc-class:ExampleThing", by_id)
        self.assertIn("objc-class-method:ExampleThing:-run:with:", by_id)
        self.assertIn("objc-class-property:ExampleThing:name", by_id)
        self.assertIn("objc-protocol:ExampleDelegate", by_id)
        self.assertIn("objc-protocol-method:ExampleDelegate:-finish", by_id)
        self.assertIn("objc-protocol-property:ExampleDelegate:result", by_id)
        self.assertNotIn("objc-class-method:ExampleThing:-old", by_id)
        self.assertNotIn("objc-class-method:ExampleThing:-macOnly", by_id)
        self.assertNotIn("objc-class-method:ExampleThing:-never", by_id)
        self.assertEqual(by_id["objc-class-property:ExampleThing:name"]["check"]["getter"], "-displayName")
        self.assertNotIn("objc-class:HiddenThing", by_id)
        self.assertNotIn("objc-class-method:HiddenThing:-hiddenMethod", by_id)
        self.assertNotIn("objc-class:SPIThing", by_id)
        self.assertNotIn("objc-class-method:SPIThing:-spiMethod", by_id)
        self.assertEqual(excluded_classes, {"HiddenThing", "SPIThing"})

    def test_swift_api_items_skip_spi_and_internal_names(self):
        root = {"children": [
            {"declKind": "Func", "name": "send", "printedName": "send()", "usr": "s:Example.send",
             "mangledName": "$sExample4sendyyF", "moduleName": "Example"},
            {"declKind": "Func", "name": "hidden", "usr": "s:Example.hidden", "mangledName": "$sExample6hiddenyyF",
             "moduleName": "Example", "declAttributes": ["SPI"]},
            {"declKind": "Func", "name": "_helper", "usr": "s:Example._helper", "mangledName": "$sExample7_helperyyF",
             "moduleName": "Example"},
            {"declKind": "Func", "name": "other", "usr": "s:Other.other", "mangledName": "$sOther5otheryyF",
             "moduleName": "Other"},
        ]}
        items = coverage.swift_nodes(root, "Example")
        self.assertEqual([item["check"]["usr"] for item in items], ["s:Example.send"])
        self.assertTrue(coverage.swift_symbol_present(items[0]["check"], {"_$sExample4sendyyF"}))
        type_check = {"kind": "Struct", "mangled": "$sExample5ThingV", "accessors": []}
        self.assertTrue(coverage.swift_symbol_present(type_check, {"_$sExample5ThingVMa"}))

    def test_swift_symbols_cover_constructor_and_enum_case_abi_names(self):
        constructor = {"kind": "Constructor", "mangled": "$sExample5ThingV3rawACSi_tKc"}
        enum_case = {"kind": "EnumElement", "mangled": "$sExample5StateO4readyyA2CmF"}
        protocol_method = {"kind": "Func", "protocol_req": True,
                           "mangled": "$sExample8ProviderP4readyyyF"}
        self.assertTrue(coverage.swift_symbol_present(
            constructor, {"_$sExample5ThingV3rawACSi_tKC"}))
        self.assertTrue(coverage.swift_symbol_present(
            enum_case, {"_$sExample5StateO4readyyA2CmFWC"}))
        self.assertTrue(coverage.swift_symbol_present(
            protocol_method, {"_$sExample8ProviderP4readyyyFTq"}))

    def test_swift_module_api_checks_symbols_when_the_declaration_has_one(self):
        usrs = {"s:Example.send"}
        function = {"usr": "s:Example.send", "kind": "Func",
                    "mangled": "$sExample4sendyyF", "accessors": []}
        alias = {"usr": "s:Example.Element", "kind": "TypeAlias",
                 "mangled": "", "accessors": []}
        self.assertFalse(coverage.swift_module_item_present(function, usrs, set()))
        self.assertTrue(coverage.swift_module_item_present(
            function, usrs, {"_$sExample4sendyyF"}))
        self.assertTrue(coverage.swift_module_item_present(
            alias, {"s:Example.Element"}, set()))

    def test_behavior_results_set_item_ids(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result_dir = root / "build/compat-results"
            result_dir.mkdir(parents=True)
            (result_dir / "foundation.json").write_text(json.dumps({
                "framework": "Foundation", "verified": ["objc-class:NSObject"],
                "results": [{"id": "c:_NSLog", "passed": True}],
            }))
            with patch.object(coverage, "ROOT", root):
                results = coverage.verification_results()
        self.assertEqual(results["Foundation"], {"objc-class:NSObject", "c:_NSLog"})


if __name__ == "__main__":
    unittest.main()
