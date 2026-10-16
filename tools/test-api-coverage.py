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
DIFFTEST_SCRIPT = Path(__file__).with_name("difftest") / "run.py"
difftest_spec = importlib.util.spec_from_file_location("difftest_run", DIFFTEST_SCRIPT)
difftest = importlib.util.module_from_spec(difftest_spec)
difftest_spec.loader.exec_module(difftest)
API_AUDIT_SCRIPT = Path(__file__).with_name("c-api-audit.py")
api_audit_spec = importlib.util.spec_from_file_location("c_api_audit", API_AUDIT_SCRIPT)
api_audit = importlib.util.module_from_spec(api_audit_spec)
api_audit_spec.loader.exec_module(api_audit)
CONSTANT_RESULTS_SCRIPT = Path(__file__).with_name("constants") / "record-results.py"
constant_results_spec = importlib.util.spec_from_file_location("constant_results", CONSTANT_RESULTS_SCRIPT)
constant_results = importlib.util.module_from_spec(constant_results_spec)
constant_results_spec.loader.exec_module(constant_results)


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
                "framework": "Foundation", "verified": ["objc-class:NSObject", "c:_NSLog"],
                "results": [{"id": "c:_NSLogResult", "passed": True}],
                "items": {
                    "objc-class-property:NSString:lowercaseString": {"status": "verified"},
                    "c:_NSLog": {"status": "differs"},
                },
            }))
            with patch.object(coverage, "ROOT", root):
                results = coverage.verification_results()
        self.assertEqual(results["Foundation"], {
            "objc-class:NSObject", "c:_NSLogResult", "objc-class-property:NSString:lowercaseString",
        })

    def test_difftest_names_map_to_coverage_item_ids(self):
        self.assertEqual(difftest.api_item_id("CFStringCreateWithBytes"), "c:_CFStringCreateWithBytes")
        self.assertEqual(difftest.api_item_id("NSString -commonPrefixWithString:options:"),
                         "objc-class-method:NSString:-commonPrefixWithString:options:")
        self.assertEqual(difftest.api_item_id("NSPasteboard +pasteboardWithName:"),
                         "objc-class-method:NSPasteboard:+pasteboardWithName:")
        self.assertEqual(difftest.api_item_id(
            "NSString -lowercaseString",
            {"NSString -lowercaseString": "objc-class-property:NSString:lowercaseString"}, set()),
            "objc-class-property:NSString:lowercaseString")
        self.assertIsNone(difftest.api_item_id("NSDate -timeIntervalSinceReferenceDate", {}, set()))
        self.assertIsNone(difftest.api_item_id("Foundation.NSObject.description"))

    def test_difftest_merge_preserves_other_items_and_replaces_old_status(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "Foundation.json"
            path.write_text(json.dumps({
                "framework": "Foundation",
                "verified": ["c:_keep", "c:_CFStringCreateWithBytes"],
                "items": {
                    "c:_keep": {"status": "verified"},
                    "c:_CFStringCreateWithBytes": {"status": "verified"},
                    "CFStringCreateWithBytes": {"status": "verified"},
                },
            }))
            difftest.write_results({
                "framework": "Foundation", "summary": {"verified": 1},
                "items": {
                    "CFStringCreateWithBytes": {"status": "differs"},
                    "NSString -commonPrefixWithString:options:": {"status": "verified"},
                },
            }, path)
            document = json.loads(path.read_text())
        self.assertEqual(document["items"]["c:_keep"], {"status": "verified"})
        self.assertEqual(document["items"]["c:_CFStringCreateWithBytes"]["status"], "differs")
        self.assertEqual(document["items"]["objc-class-method:NSString:-commonPrefixWithString:options:"]["status"], "verified")
        self.assertNotIn("CFStringCreateWithBytes", document["items"])
        self.assertEqual(document["verified"], ["c:_keep", "objc-class-method:NSString:-commonPrefixWithString:options:"])

    def test_difftest_merge_removes_old_method_id_for_a_property_accessor(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "Foundation.json"
            old_id = "objc-class-method:NSString:-lowercaseString"
            property_id = "objc-class-property:NSString:lowercaseString"
            path.write_text(json.dumps({"framework": "Foundation", "verified": [old_id],
                                        "items": {old_id: {"status": "verified"}}}))
            difftest.write_results({"framework": "Foundation", "items": {
                "NSString -lowercaseString": {"status": "verified"},
            }}, path, method_ids=set(), property_accessors={
                "NSString -lowercaseString": property_id,
            })
            document = json.loads(path.read_text())
        self.assertNotIn(old_id, document["items"])
        self.assertEqual(document["items"][property_id]["status"], "verified")
        self.assertEqual(document["verified"], [property_id])

    def test_generator_skips_availability_macros_obsoleted_in_current_sdk(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "Example.h"
            source = '''#define OBSOLETE(introduced,deprecated,removed) \\
    __attribute__((availability(macos,introduced=introduced,deprecated=deprecated,obsoleted=removed,message="Use the replacement.")))
int oldCall OBSOLETE(10.8,14.0,15.0);
int futureCall OBSOLETE(10.8,14.0,30.0);
'''
            path.write_text(source)

            def declaration(name):
                invocation = source.index("OBSOLETE(", source.index(name))
                spelling = source.index("availability(")
                return {"inner": [{"kind": "AvailabilityAttr", "range": {"begin": {
                    "spellingLoc": {"file": str(path), "offset": spelling},
                    "expansionLoc": {"file": str(path), "offset": invocation},
                }}}]}

            with patch.object(api_audit, "macos_sdk_version", return_value="26.4"):
                self.assertTrue(api_audit.unavailable_on_macos(declaration("oldCall"), {}, True))
                self.assertFalse(api_audit.unavailable_on_macos(declaration("futureCall"), {}, True))

    def test_constant_merge_replaces_an_old_verified_status(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            inventory_path = root / "inventory.json"
            inventory_path.write_text(json.dumps({
                "sdk_version": "26.4",
                "frameworks": [{"id": "Foundation", "constants": [
                    {"symbol": "_OLD", "testable": True},
                    {"symbol": "_NEW", "testable": True},
                ]}],
            }))
            results_dir = root / "compat-results"
            results_dir.mkdir()
            result_path = results_dir / "Foundation.json"
            result_path.write_text(json.dumps({
                "framework": "Foundation", "verified": ["c:_OLD", "c:_KEEP"],
                "items": {
                    "c:_OLD": {"status": "verified", "verified": True},
                    "c:_KEEP": {"status": "verified", "verified": True},
                },
            }))
            apple_path, finch_path = root / "apple.txt", root / "finch.txt"
            apple_path.write_text("header\nFoundation\tOLD\t1\nFoundation\tNEW\t2\n")
            finch_path.write_text("header\nFoundation\tOLD\t0\nFoundation\tNEW\t2\n")
            with (patch.object(constant_results, "INVENTORY", inventory_path),
                  patch.object(constant_results, "RESULTS", results_dir),
                  patch.object(constant_results.sys, "argv", ["record-results.py", str(apple_path), str(finch_path)])):
                self.assertEqual(constant_results.main(), 0)
            document = json.loads(result_path.read_text())
        self.assertEqual(document["items"]["c:_OLD"]["status"], "differs")
        self.assertEqual(document["items"]["c:_KEEP"]["status"], "verified")
        self.assertEqual(document["items"]["c:_NEW"]["status"], "verified")
        self.assertEqual(document["verified"], ["c:_KEEP", "c:_NEW"])


if __name__ == "__main__":
    unittest.main()
