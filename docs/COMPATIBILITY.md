# Finch compatibility coverage

SDK baseline: macOS SDK 26.4 (arm64e).

This report compares public C declarations and SDK export lists, Objective-C classes, methods and properties, and Swift declarations from the SDK interfaces. It follows public TAPI re-exports, checks C symbols and Swift API declarations against Finch's built Swift modules where they exist, and checks Swift symbols otherwise. It asks Finch's loaded classes whether they answer the listed selectors. These checks show API presence; they do not prove matching behavior. Public framework bundles, including nested subframeworks, and public dylib stubs under usr/lib, including its subfolders, are included. PrivateFrameworks and underscore-named framework bundles are excluded.

Behavior-verified counts come from item IDs in build/compat-results/*.json. Generated comparisons and constant checks merge their item records into the same framework file. Records with status verified (or the older verified/passed flags) count; a later result replaces the status for that item ID. The full name-by-name report is kept in build/api-coverage.json.

Overall: **28.2%** (153,450 of 543,220 API items across 843 parsed frameworks or dylibs).

6 frameworks or dylibs had a parse or load issue and are left out of the overall percentage. 141 parsed successfully but had no public macOS API items.

| Framework or dylib | API items | Present | Missing | Coverage | Behavior verified | Status |
|---|---:|---:|---:|---:|---:|---|
| Accelerate | 13,547 | 53 | 13,494 | 0.4% | 0/13547 | complete |
| Accelerate/vecLib | 12,956 | 0 | 12,956 | 0.0% | 0/12956 | complete |
| Accelerate/vecLib/libBNNS | 269 | 0 | 269 | 0.0% | 0/269 | complete |
| Accelerate/vecLib/libLinearAlgebra | 42 | 0 | 42 | 0.0% | 0/42 | complete |
| Accelerate/vecLib/libQuadrature | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| Accelerate/vecLib/libSparse | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| Accelerate/vecLib/libSparseBLAS | 127 | 0 | 127 | 0.0% | 0/127 | complete |
| Accelerate/vecLib/libvDSP | 469 | 0 | 469 | 0.0% | 0/469 | complete |
| Accelerate/vecLib/libvMisc | 582 | 0 | 582 | 0.0% | 0/582 | complete |
| Accelerate/vImage | 591 | 0 | 591 | 0.0% | 0/591 | complete |
| Accessibility | 318 | 301 | 17 | 94.7% | 14/318 | complete |
| Accounts | 70 | 41 | 29 | 58.6% | 16/70 | complete |
| ACIPCBTLib | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| ActivityKit | 11 | 0 | 11 | 0.0% | 0/11 | complete |
| AddressBook | 975 | 0 | 975 | 0.0% | 0/975 | complete |
| AdServices | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| AdSupport | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| AppIntents | 4,043 | 995 | 3,048 | 24.6% | 0/4043 | complete |
| AppKit | 18,585 | 16,434 | 2,151 | 88.4% | 3578/18585 | complete |
| AppleConvergedTransport | 14 | 0 | 14 | 0.0% | 0/14 | complete |
| AppleScriptKit | 96 | 0 | 96 | 0.0% | 0/96 | complete |
| AppleScriptObjC | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| ApplicationServices | 6,898 | 5,695 | 1,203 | 82.6% | 0/6898 | complete |
| ApplicationServices/ATS | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| ApplicationServices/ATSUI | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| ApplicationServices/ColorSync | 205 | 205 | 0 | 100.0% | 0/205 | complete |
| ApplicationServices/ColorSyncLegacy | 120 | 0 | 120 | 0.0% | 0/120 | complete |
| ApplicationServices/CoreGraphics | 1,176 | 868 | 308 | 73.8% | 0/1176 | complete |
| ApplicationServices/CoreText | 382 | 374 | 8 | 97.9% | 0/382 | complete |
| ApplicationServices/HIServices | 198 | 102 | 96 | 51.5% | 25/198 | complete |
| ApplicationServices/ImageIO | 808 | 808 | 0 | 100.0% | 0/808 | complete |
| ApplicationServices/PrintCore | 150 | 119 | 31 | 79.3% | 0/150 | complete |
| ApplicationServices/QD | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| ApplicationServices/SpeechSynthesis | 119 | 0 | 119 | 0.0% | 0/119 | complete |
| AppTrackingTransparency | 6 | 0 | 6 | 0.0% | 0/6 | complete |
| ARKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| AudioAccessoryKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| AudioToolbox | 374 | 317 | 57 | 84.8% | 0/374 | complete |
| AudioUnit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| AudioVideoBridging | 627 | 0 | 627 | 0.0% | 0/627 | complete |
| AuthenticationServices | 1,223 | 463 | 760 | 37.9% | 33/1223 | complete |
| AutomaticAssessmentConfiguration | 38 | 0 | 38 | 0.0% | 0/38 | complete |
| AutomaticAssessmentConfiguration/AACClient | 3 | 0 | 3 | incomplete | 0/3 | incomplete |
| AutomaticAssessmentConfiguration/AACDependencies | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| Automator | 187 | 0 | 187 | 0.0% | 0/187 | complete |
| AVFAudio | 670 | 605 | 65 | 90.3% | 107/670 | complete |
| AVFoundation | 2,681 | 2,173 | 508 | 81.1% | 0/2681 | complete |
| AVFoundation/AVFAudio | 670 | 605 | 65 | 90.3% | 0/670 | complete |
| AVKit | 136 | 66 | 70 | 48.5% | 0/136 | complete |
| AVRouting | 47 | 0 | 47 | 0.0% | 0/47 | complete |
| BackgroundAssets | 1,174 | 0 | 1,174 | 0.0% | 0/1174 | complete |
| BackgroundTasks | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| BrowserEngineCore | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| BrowserEngineKit | 334 | 0 | 334 | 0.0% | 0/334 | complete |
| BusinessChat | 9 | 0 | 9 | 0.0% | 0/9 | complete |
| CalendarStore | 129 | 0 | 129 | 0.0% | 0/129 | complete |
| CallKit | 99 | 0 | 99 | 0.0% | 0/99 | complete |
| Carbon | 7,367 | 5,864 | 1,503 | 79.6% | 0/7367 | complete |
| Carbon/CommonPanels | 43 | 0 | 43 | 0.0% | 0/43 | complete |
| Carbon/Help | 6 | 0 | 6 | 0.0% | 0/6 | complete |
| Carbon/HIToolbox | 261 | 100 | 161 | 38.3% | 44/261 | complete |
| Carbon/ImageCapture | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| Carbon/Ink | 22 | 0 | 22 | 0.0% | 0/22 | complete |
| Carbon/OpenScripting | 69 | 69 | 0 | 100.0% | 0/69 | complete |
| Carbon/SecurityHI | 26 | 0 | 26 | 0.0% | 0/26 | complete |
| Carbon/SpeechRecognition | 42 | 0 | 42 | 0.0% | 0/42 | complete |
| CarKey | 102 | 0 | 102 | 0.0% | 0/102 | complete |
| CFNetwork | 268 | 254 | 14 | 94.8% | 148/268 | complete |
| Charts | 840 | 0 | 840 | 0.0% | 0/840 | complete |
| Cinematic | 284 | 0 | 284 | 0.0% | 0/284 | complete |
| ClassKit | 176 | 0 | 176 | 0.0% | 0/176 | complete |
| ClassKitUI | 20 | 0 | 20 | 0.0% | 0/20 | complete |
| CloudKit | 1,208 | 509 | 699 | 42.1% | 0/1208 | complete |
| Cocoa | 19,543 | 17,031 | 2,512 | 87.1% | 0/19543 | complete |
| Collaboration | 48 | 0 | 48 | 0.0% | 0/48 | complete |
| ColorSync | 205 | 205 | 0 | 100.0% | 150/205 | complete |
| Combine | 1,299 | 1,291 | 8 | 99.4% | 0/1299 | complete |
| CompositorServices | 115 | 0 | 115 | 0.0% | 0/115 | complete |
| Contacts | 830 | 554 | 276 | 66.7% | 383/830 | complete |
| ContactsUI | 62 | 8 | 54 | incomplete | 0/62 | incomplete |
| CoreAudio | 67 | 30 | 37 | 44.8% | 0/67 | complete |
| CoreAudioKit | 54 | 0 | 54 | 0.0% | 0/54 | complete |
| CoreAudioTypes | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| CoreBluetooth | 225 | 136 | 89 | 60.4% | 0/225 | complete |
| CoreData | 959 | 671 | 288 | 70.0% | 156/959 | complete |
| CoreDisplay | 495 | 0 | 495 | 0.0% | 0/495 | complete |
| CoreFoundation | 1,614 | 1,596 | 18 | 98.9% | 803/1614 | complete |
| CoreGraphics | 1,176 | 868 | 308 | 73.8% | 538/1176 | complete |
| CoreHaptics | 127 | 0 | 127 | 0.0% | 0/127 | complete |
| CoreHID | 3,214 | 0 | 3,214 | 0.0% | 0/3214 | complete |
| CoreImage | 1,899 | 1,399 | 500 | 73.7% | 479/1899 | complete |
| CoreLocation | 259 | 130 | 129 | 50.2% | 3/259 | complete |
| CoreMedia | 739 | 717 | 22 | 97.0% | 490/739 | complete |
| CoreMediaIO | 168 | 0 | 168 | 0.0% | 0/168 | complete |
| CoreMIDI | 319 | 241 | 78 | 75.5% | 67/319 | complete |
| CoreMIDIServer | 319 | 0 | 319 | 0.0% | 0/319 | complete |
| CoreML | 900 | 0 | 900 | 0.0% | 0/900 | complete |
| CoreMotion | 222 | 0 | 222 | 0.0% | 0/222 | complete |
| CoreServices | 3,740 | 3,222 | 518 | 86.1% | 157/3740 | complete |
| CoreServices/AE | 136 | 100 | 36 | 73.5% | 4/136 | complete |
| CoreServices/CarbonCore | 847 | 675 | 172 | 79.7% | 11/847 | complete |
| CoreServices/DictionaryServices | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| CoreServices/FSEvents | 22 | 22 | 0 | 100.0% | 0/22 | complete |
| CoreServices/LaunchServices | 295 | 229 | 66 | 77.6% | 163/295 | complete |
| CoreServices/Metadata | 269 | 219 | 50 | 81.4% | 211/269 | complete |
| CoreServices/OSServices | 166 | 90 | 76 | 54.2% | 33/166 | complete |
| CoreServices/SearchKit | 79 | 0 | 79 | 0.0% | 0/79 | complete |
| CoreServices/SharedFileList | 42 | 37 | 5 | 88.1% | 15/42 | complete |
| CoreSpotlight | 455 | 321 | 134 | 70.5% | 208/455 | complete |
| CoreTelephony | 264 | 0 | 264 | 0.0% | 0/264 | complete |
| CoreText | 382 | 374 | 8 | 97.9% | 194/382 | complete |
| CoreTransferable | 93 | 82 | 11 | 88.2% | 1/93 | complete |
| CoreVideo | 548 | 302 | 246 | 55.1% | 227/548 | complete |
| CoreWLAN | 174 | 104 | 70 | 59.8% | 11/174 | complete |
| CreateML | 1,798 | 0 | 1,798 | 0.0% | 0/1798 | complete |
| CreateMLComponents | 2,258 | 0 | 2,258 | 0.0% | 0/2258 | complete |
| CryptoKit | 727 | 673 | 54 | 92.6% | 0/727 | complete |
| CryptoTokenKit | 221 | 154 | 67 | 69.7% | 0/221 | complete |
| DataDetection | 123 | 0 | 123 | 0.0% | 0/123 | complete |
| DeclaredAgeRange | 50 | 0 | 50 | 0.0% | 0/50 | complete |
| DeveloperToolsSupport | 56 | 56 | 0 | 100.0% | 0/56 | complete |
| DeviceActivity | 10 | 0 | 10 | 0.0% | 0/10 | complete |
| DeviceCheck | 14 | 0 | 14 | 0.0% | 0/14 | complete |
| DeviceDiscoveryExtension | 51 | 0 | 51 | 0.0% | 0/51 | complete |
| DirectoryService | 96 | 0 | 96 | 0.0% | 0/96 | complete |
| DiscRecording | 1,267 | 0 | 1,267 | 0.0% | 0/1267 | complete |
| DiscRecordingUI | 81 | 0 | 81 | 0.0% | 0/81 | complete |
| DiskArbitration | 85 | 85 | 0 | 100.0% | 46/85 | complete |
| DockKit | 217 | 0 | 217 | 0.0% | 0/217 | complete |
| DriverKit | 161 | 0 | 161 | 0.0% | 0/161 | complete |
| DVDPlayback | 114 | 0 | 114 | 0.0% | 0/114 | complete |
| EventKit | 351 | 0 | 351 | 0.0% | 0/351 | complete |
| ExceptionHandling | 14 | 0 | 14 | 0.0% | 0/14 | complete |
| ExecutionPolicy | 8 | 0 | 8 | 0.0% | 0/8 | complete |
| ExtensionFoundation | 111 | 0 | 111 | 0.0% | 0/111 | complete |
| ExtensionKit | 151 | 0 | 151 | 0.0% | 0/151 | complete |
| ExternalAccessory | 47 | 0 | 47 | 0.0% | 0/47 | complete |
| FamilyControls | 14 | 0 | 14 | 0.0% | 0/14 | complete |
| FileProvider | 394 | 0 | 394 | 0.0% | 0/394 | complete |
| FileProviderUI | 13 | 0 | 13 | 0.0% | 0/13 | complete |
| FinanceKit | 45 | 0 | 45 | 0.0% | 0/45 | complete |
| FinanceKitUI | 11 | 0 | 11 | 0.0% | 0/11 | complete |
| FinderSync | 25 | 0 | 25 | 0.0% | 0/25 | complete |
| ForceFeedback | 20 | 0 | 20 | 0.0% | 0/20 | complete |
| Foundation | 13,636 | 12,048 | 1,588 | 88.4% | 2495/13636 | complete |
| FoundationModels | 442 | 0 | 442 | 0.0% | 0/442 | complete |
| FSKit | 317 | 0 | 317 | 0.0% | 0/317 | complete |
| GameController | 907 | 545 | 362 | 60.1% | 0/907 | complete |
| GameKit | 4,585 | 0 | 4,585 | 0.0% | 0/4585 | complete |
| GameplayKit | 448 | 0 | 448 | 0.0% | 0/448 | complete |
| GameSave | 51 | 0 | 51 | 0.0% | 0/51 | complete |
| GeoToolbox | 24 | 0 | 24 | 0.0% | 0/24 | complete |
| GLKit | 183 | 0 | 183 | 0.0% | 0/183 | complete |
| GLUT | 127 | 0 | 127 | 0.0% | 0/127 | complete |
| GroupActivities | 196 | 0 | 196 | 0.0% | 0/196 | complete |
| GSS | 82 | 48 | 34 | 58.5% | 0/82 | complete |
| HealthKit | 1,770 | 0 | 1,770 | 0.0% | 0/1770 | complete |
| Hypervisor | 89 | 0 | 89 | 0.0% | 0/89 | complete |
| i18n/libBIG5 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libDECHanyu | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libDECKanji | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libEUC | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libEUCTW | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libGBK2K | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libHZ | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libiconv_none | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libiconv_std | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libISO2022 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libJOHAB | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libmapper_646 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libmapper_none | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libmapper_parallel | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libmapper_serial | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libmapper_std | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libmapper_zone | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libMSKanji | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libUES | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libUTF1632 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libUTF7 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libUTF8 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libUTF8MAC | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libVIQR | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| i18n/libZW | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| ICADevices | 216 | 193 | 23 | 89.4% | 146/216 | complete |
| IdentityDocumentServices | 56 | 0 | 56 | 0.0% | 0/56 | complete |
| IdentityDocumentServicesUI | 11 | 0 | 11 | 0.0% | 0/11 | complete |
| IdentityLookup | 41 | 0 | 41 | 0.0% | 0/41 | complete |
| ImageCaptureCore | 233 | 183 | 50 | 78.5% | 51/233 | complete |
| ImageIO | 808 | 808 | 0 | 100.0% | 781/808 | complete |
| ImagePlayground | 105 | 0 | 105 | 0.0% | 0/105 | complete |
| ImmersiveMediaSupport | 310 | 0 | 310 | 0.0% | 0/310 | complete |
| InputMethodKit | 289 | 0 | 289 | 0.0% | 0/289 | complete |
| InstallerPlugins | 59 | 0 | 59 | 0.0% | 0/59 | complete |
| InstantMessage | 101 | 0 | 101 | 0.0% | 0/101 | complete |
| Intents | 1,065 | 545 | 520 | 51.2% | 0/1065 | complete |
| IntentsUI | 32 | 0 | 32 | 0.0% | 0/32 | complete |
| introspection/libdispatch | 321 | 0 | 321 | 0.0% | 0/321 | complete |
| introspection/libsystem_pthread | 152 | 0 | 152 | 0.0% | 0/152 | complete |
| IOBluetooth | 826 | 364 | 462 | 44.1% | 61/826 | complete |
| IOBluetoothUI | 108 | 92 | 16 | 85.2% | 0/108 | complete |
| IOKit | 392 | 227 | 165 | 57.9% | 2/392 | complete |
| IOSurface | 125 | 120 | 5 | 96.0% | 33/125 | complete |
| IOUSBHost | 204 | 0 | 204 | 0.0% | 0/204 | complete |
| iTunesLibrary | 221 | 0 | 221 | 0.0% | 0/221 | complete |
| JavaNativeFoundation | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| JavaRuntimeSupport | 81 | 0 | 81 | 0.0% | 0/81 | complete |
| JavaScriptCore | 224 | 0 | 224 | 0.0% | 0/224 | complete |
| Kerberos | 418 | 0 | 418 | 0.0% | 0/418 | complete |
| Kernel | 1 | 0 | 1 | incomplete | 0/1 | incomplete |
| KernelManagement | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| LatentSemanticMapping | 30 | 0 | 30 | 0.0% | 0/30 | complete |
| LDAP | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libAccessibility | 343 | 0 | 343 | 0.0% | 0/343 | complete |
| libAccessibilityBaseImplementations | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libAccountPolicyTranslation | 58 | 0 | 58 | 0.0% | 0/58 | complete |
| libAHTRestore | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libAmber | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libamsupport | 493 | 0 | 493 | 0.0% | 0/493 | complete |
| libapp_launch_measurement | 22 | 0 | 22 | 0.0% | 0/22 | complete |
| libapple_nghttp2 | 182 | 0 | 182 | 0.0% | 0/182 | complete |
| libAppleArchive | 232 | 0 | 232 | 0.0% | 0/232 | complete |
| libAppleEXR | 65 | 0 | 65 | 0.0% | 0/65 | complete |
| libAppleSSE | 16 | 0 | 16 | 0.0% | 0/16 | complete |
| libAppleSSEExt | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libAppletTranslationLibrary | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| libapr-1 | 510 | 0 | 510 | 0.0% | 0/510 | complete |
| libapr-1.0 | 510 | 0 | 510 | 0.0% | 0/510 | complete |
| libaprutil-1 | 292 | 0 | 292 | 0.0% | 0/292 | complete |
| libaprutil-1.0 | 292 | 0 | 292 | 0.0% | 0/292 | complete |
| libarchive | 425 | 0 | 425 | 0.0% | 0/425 | complete |
| libarchive.2 | 425 | 0 | 425 | 0.0% | 0/425 | complete |
| libATCommandStudioDynamic | 6 | 0 | 6 | 0.0% | 0/6 | complete |
| libate | 19 | 0 | 19 | 0.0% | 0/19 | complete |
| libAudioDSPCore | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libAudioIssueDetector | 39 | 0 | 39 | 0.0% | 0/39 | complete |
| libAudioStatistics | 71 | 0 | 71 | 0.0% | 0/71 | complete |
| libAudioToolboxUtility | 29 | 0 | 29 | 0.0% | 0/29 | complete |
| libauditd | 18 | 0 | 18 | 0.0% | 0/18 | complete |
| libauditd.0 | 18 | 0 | 18 | 0.0% | 0/18 | complete |
| libauthinstall | 753 | 0 | 753 | 0.0% | 0/753 | complete |
| libaxis | 298 | 0 | 298 | 0.0% | 0/298 | complete |
| libAXSafeCategoryBundle | 5 | 0 | 5 | 0.0% | 0/5 | complete |
| libAXSpeechManager | 6 | 0 | 6 | 0.0% | 0/6 | complete |
| libBacktraceRecording | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libBASupport | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| libblas | 1,464 | 0 | 1,464 | 0.0% | 0/1464 | complete |
| libBootCacheLib | 7 | 0 | 7 | 0.0% | 0/7 | complete |
| libbootpolicy | 105 | 0 | 105 | 0.0% | 0/105 | complete |
| libboringssl | 447 | 0 | 447 | 0.0% | 0/447 | complete |
| libBSDPClient | 11 | 0 | 11 | 0.0% | 0/11 | complete |
| libBSDPClient.A | 11 | 0 | 11 | 0.0% | 0/11 | complete |
| libbsm | 180 | 180 | 0 | 100.0% | 0/180 | complete |
| libbsm.0 | 180 | 180 | 0 | 100.0% | 0/180 | complete |
| libbz2 | 24 | 24 | 0 | 100.0% | 0/24 | complete |
| libbz2.1.0 | 24 | 24 | 0 | 100.0% | 0/24 | complete |
| libbz2.1.0.8 | 24 | 24 | 0 | 100.0% | 0/24 | complete |
| libc | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libc++ | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libc++.1 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libc++abi | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libcache | 34 | 34 | 0 | 100.0% | 0/34 | complete |
| libcblas | 1,464 | 0 | 1,464 | 0.0% | 0/1464 | complete |
| libchannel | 32 | 0 | 32 | 0.0% | 0/32 | complete |
| libcharset | 2 | 2 | 0 | 100.0% | 0/2 | complete |
| libcharset.1 | 2 | 2 | 0 | 100.0% | 0/2 | complete |
| libCheckFix | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libChineseTokenizer | 8 | 0 | 8 | 0.0% | 0/8 | complete |
| libclapack | 9,998 | 0 | 9,998 | 0.0% | 0/9998 | complete |
| libcmark-gfm | 223 | 0 | 223 | 0.0% | 0/223 | complete |
| libcmph | 32 | 0 | 32 | 0.0% | 0/32 | complete |
| libcodedirectory | 39 | 0 | 39 | 0.0% | 0/39 | complete |
| libcom_err | 776 | 0 | 776 | 0.0% | 0/776 | complete |
| libcommonCrypto | 245 | 245 | 0 | 100.0% | 0/245 | complete |
| libcompiler_rt | 6 | 6 | 0 | 100.0% | 0/6 | complete |
| libcompression | 54 | 7 | 47 | 13.0% | 0/54 | complete |
| libcopyfile | 11 | 11 | 0 | 100.0% | 0/11 | complete |
| libcorecrypto | 1,092 | 1,092 | 0 | 100.0% | 0/1092 | complete |
| libcorecrypto_noasm | 1,073 | 0 | 1,073 | 0.0% | 0/1073 | complete |
| libcorecrypto_trace | 1,092 | 0 | 1,092 | 0.0% | 0/1092 | complete |
| libCoreEntitlements | 62 | 0 | 62 | 0.0% | 0/62 | complete |
| libCoreEntitlements_V2 | 53 | 0 | 53 | 0.0% | 0/53 | complete |
| libCoreRepairState | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libcoreroutine | 1,631 | 0 | 1,631 | 0.0% | 0/1631 | complete |
| libCoreStorage | 68 | 0 | 68 | 0.0% | 0/68 | complete |
| libcoretls | 143 | 0 | 143 | 0.0% | 0/143 | complete |
| libcoretls_cfhelpers | 6 | 0 | 6 | 0.0% | 0/6 | complete |
| libCRFSuite | 152 | 0 | 152 | 0.0% | 0/152 | complete |
| libCRFSuite0.12 | 152 | 0 | 152 | 0.0% | 0/152 | complete |
| libcryptex | 161 | 0 | 161 | 0.0% | 0/161 | complete |
| libcryptex_core | 147 | 0 | 147 | 0.0% | 0/147 | complete |
| libcryptex_interface | 68 | 0 | 68 | 0.0% | 0/68 | complete |
| libcryptex_trampoline | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libcsfde | 75 | 0 | 75 | 0.0% | 0/75 | complete |
| libCTGreenTeaLogger | 9 | 0 | 9 | 0.0% | 0/9 | complete |
| libcupolicy | 10 | 0 | 10 | 0.0% | 0/10 | complete |
| libcups | 451 | 0 | 451 | 0.0% | 0/451 | complete |
| libcups.2 | 451 | 0 | 451 | 0.0% | 0/451 | complete |
| libcupsimage | 12 | 0 | 12 | 0.0% | 0/12 | complete |
| libcupsimage.2 | 12 | 0 | 12 | 0.0% | 0/12 | complete |
| libcurl | 93 | 0 | 93 | 0.0% | 0/93 | complete |
| libcurl.3 | 93 | 0 | 93 | 0.0% | 0/93 | complete |
| libcurl.4 | 93 | 0 | 93 | 0.0% | 0/93 | complete |
| libcurses | 764 | 764 | 0 | 100.0% | 0/764 | complete |
| libdbm | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libdes425 | 776 | 0 | 776 | 0.0% | 0/776 | complete |
| libDHCPServer | 18 | 0 | 18 | 0.0% | 0/18 | complete |
| libDHCPServer.A | 18 | 0 | 18 | 0.0% | 0/18 | complete |
| libDiagnosticMessagesClient | 12 | 12 | 0 | 100.0% | 0/12 | complete |
| libDiskUnlock | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libdispatch | 312 | 312 | 0 | 100.0% | 0/312 | complete |
| libDisplayWarpSupport | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libdl | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libdns_services | 99 | 0 | 99 | 0.0% | 0/99 | complete |
| libdpfu | 14 | 0 | 14 | 0.0% | 0/14 | complete |
| libdscsym | 10 | 0 | 10 | 0.0% | 0/10 | complete |
| libdtrace | 93 | 0 | 93 | 0.0% | 0/93 | complete |
| libdyld | 121 | 121 | 0 | 100.0% | 0/121 | complete |
| libeasyperf | 55 | 0 | 55 | 0.0% | 0/55 | complete |
| libedit | 145 | 145 | 0 | 100.0% | 0/145 | complete |
| libedit.2 | 145 | 145 | 0 | 100.0% | 0/145 | complete |
| libedit.3 | 145 | 145 | 0 | 100.0% | 0/145 | complete |
| libedit.3.0 | 145 | 145 | 0 | 100.0% | 0/145 | complete |
| libemptyRecovery | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libEndpointSecurity | 62 | 0 | 62 | 0.0% | 0/62 | complete |
| libEndpointSecuritySystem | 43 | 2 | 41 | 4.7% | 0/43 | complete |
| libenergytrace | 8 | 0 | 8 | 0.0% | 0/8 | complete |
| libexpat | 71 | 0 | 71 | 0.0% | 0/71 | complete |
| libexpat.1 | 71 | 0 | 71 | 0.0% | 0/71 | complete |
| libexslt | 17 | 0 | 17 | 0.0% | 0/17 | complete |
| libexslt.0 | 17 | 0 | 17 | 0.0% | 0/17 | complete |
| libextension | 2,916 | 2,585 | 331 | 88.6% | 0/2916 | complete |
| libf77lapack | 9,998 | 0 | 9,998 | 0.0% | 0/9998 | complete |
| libfakelink | 12 | 0 | 12 | 0.0% | 0/12 | complete |
| libFDR | 293 | 0 | 293 | 0.0% | 0/293 | complete |
| libFDR_osx | 293 | 0 | 293 | 0.0% | 0/293 | complete |
| libFDRDecode | 58 | 0 | 58 | 0.0% | 0/58 | complete |
| libffi | 39 | 0 | 39 | 0.0% | 0/39 | complete |
| libffi-trampolines | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libform | 81 | 0 | 81 | 0.0% | 0/81 | complete |
| libform.5.4 | 81 | 0 | 81 | 0.0% | 0/81 | complete |
| libFosl_dynamic | 54 | 0 | 54 | 0.0% | 0/54 | complete |
| libgcc_s.1 | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libgermantok | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libgmalloc | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libgssapi_krb5 | 776 | 0 | 776 | 0.0% | 0/776 | complete |
| libheimdal-asn1 | 124 | 0 | 124 | 0.0% | 0/124 | complete |
| libheimdalasn1 | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| libhunspell-1.2 | 31 | 0 | 31 | 0.0% | 0/31 | complete |
| libhunspell-1.2.0 | 31 | 0 | 31 | 0.0% | 0/31 | complete |
| libhunspell-1.2.0.0.0 | 31 | 0 | 31 | 0.0% | 0/31 | complete |
| libhvf | 12 | 0 | 12 | 0.0% | 0/12 | complete |
| libhwtrace | 193 | 0 | 193 | 0.0% | 0/193 | complete |
| libIASAuthReboot | 15 | 0 | 15 | 0.0% | 0/15 | complete |
| libIASUnifiedProgress | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| libiconv | 10 | 10 | 0 | 100.0% | 0/10 | complete |
| libiconv.2 | 10 | 10 | 0 | 100.0% | 0/10 | complete |
| libicucore | 1,748 | 1,748 | 0 | 100.0% | 0/1748 | complete |
| libicucore.A | 1,748 | 1,748 | 0 | 100.0% | 0/1748 | complete |
| libimage4 | 77 | 0 | 77 | 0.0% | 0/77 | complete |
| libimg4 | 77 | 0 | 77 | 0.0% | 0/77 | complete |
| libInFieldCollection | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| libinfo | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libInterpreterSecurity | 8 | 0 | 8 | 0.0% | 0/8 | complete |
| libIOAccessoryManager | 127 | 0 | 127 | 0.0% | 0/127 | complete |
| libiodbc | 154 | 0 | 154 | 0.0% | 0/154 | complete |
| libiodbc.2 | 154 | 0 | 154 | 0.0% | 0/154 | complete |
| libiodbc.2.1.18 | 154 | 0 | 154 | 0.0% | 0/154 | complete |
| libiodbcinst | 52 | 0 | 52 | 0.0% | 0/52 | complete |
| libiodbcinst.2 | 52 | 0 | 52 | 0.0% | 0/52 | complete |
| libiodbcinst.2.1.18 | 52 | 0 | 52 | 0.0% | 0/52 | complete |
| libIOGTrace | 9 | 0 | 9 | 0.0% | 0/9 | complete |
| libIOReport | 62 | 0 | 62 | 0.0% | 0/62 | complete |
| libipconfig | 33 | 0 | 33 | 0.0% | 0/33 | complete |
| libipsec | 5 | 0 | 5 | 0.0% | 0/5 | complete |
| libipsec.A | 5 | 0 | 5 | 0.0% | 0/5 | complete |
| libk5crypto | 776 | 0 | 776 | 0.0% | 0/776 | complete |
| libKernelCollectionBuilder | 14 | 0 | 14 | 0.0% | 0/14 | complete |
| libkeymgr | 2 | 2 | 0 | 100.0% | 0/2 | complete |
| libkrb4 | 776 | 0 | 776 | 0.0% | 0/776 | complete |
| libkrb5 | 776 | 0 | 776 | 0.0% | 0/776 | complete |
| libkrb524 | 776 | 0 | 776 | 0.0% | 0/776 | complete |
| libkrb5support | 776 | 0 | 776 | 0.0% | 0/776 | complete |
| libktrace | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libkxld | 13 | 0 | 13 | 0.0% | 0/13 | complete |
| liblangid | 14 | 0 | 14 | 0.0% | 0/14 | complete |
| liblapack | 9,998 | 0 | 9,998 | 0.0% | 0/9998 | complete |
| liblaunch | 83 | 0 | 83 | 0.0% | 0/83 | complete |
| libLaunchServicesSupport | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| liblber | 294 | 0 | 294 | 0.0% | 0/294 | complete |
| libldap | 294 | 0 | 294 | 0.0% | 0/294 | complete |
| libldap_r | 294 | 0 | 294 | 0.0% | 0/294 | complete |
| libLeaksAtExit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libLogRedirect | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| liblzma | 107 | 107 | 0 | 100.0% | 0/107 | complete |
| liblzma.5 | 107 | 107 | 0 | 100.0% | 0/107 | complete |
| libm | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libmacho | 90 | 90 | 0 | 100.0% | 0/90 | complete |
| libMainThreadChecker | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libManagedConfigurationFiles | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libmarisa | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libMatch | 13 | 0 | 13 | 0.0% | 0/13 | complete |
| libMatch.1 | 13 | 0 | 13 | 0.0% | 0/13 | complete |
| libmathCommon | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libmathCommon.A | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libmd | 51 | 51 | 0 | 100.0% | 0/51 | complete |
| libmdns | 218 | 0 | 218 | 0.0% | 0/218 | complete |
| libmecab | 82 | 0 | 82 | 0.0% | 0/82 | complete |
| libmecabra | 281 | 0 | 281 | 0.0% | 0/281 | complete |
| libMemoryResourceException | 21 | 0 | 21 | 0.0% | 0/21 | complete |
| libmenu | 64 | 0 | 64 | 0.0% | 0/64 | complete |
| libmenu.5.4 | 64 | 0 | 64 | 0.0% | 0/64 | complete |
| libmis | 154 | 0 | 154 | 0.0% | 0/154 | complete |
| libMobileGestalt | 1,111 | 12 | 1,099 | 1.1% | 0/1111 | complete |
| libmorphun | 118 | 0 | 118 | 0.0% | 0/118 | complete |
| libmrc | 55 | 0 | 55 | 0.0% | 0/55 | complete |
| libMTLHud | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libmx | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libmx.A | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libncurses | 764 | 764 | 0 | 100.0% | 0/764 | complete |
| libncurses.5 | 764 | 764 | 0 | 100.0% | 0/764 | complete |
| libncurses.5.4 | 764 | 764 | 0 | 100.0% | 0/764 | complete |
| libnetquality | 23 | 0 | 23 | 0.0% | 0/23 | complete |
| libnetsnmp | 1,013 | 0 | 1,013 | 0.0% | 0/1013 | complete |
| libnetsnmp.25 | 1,013 | 0 | 1,013 | 0.0% | 0/1013 | complete |
| libnetsnmpagent | 629 | 0 | 629 | 0.0% | 0/629 | complete |
| libnetsnmpagent.25 | 629 | 0 | 629 | 0.0% | 0/629 | complete |
| libnetsnmphelpers | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libnetsnmphelpers.25 | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libnetsnmpmibs | 806 | 0 | 806 | 0.0% | 0/806 | complete |
| libnetsnmpmibs.25 | 806 | 0 | 806 | 0.0% | 0/806 | complete |
| libnetsnmptrapd | 40 | 0 | 40 | 0.0% | 0/40 | complete |
| libnetsnmptrapd.25 | 40 | 0 | 40 | 0.0% | 0/40 | complete |
| libnetwork | 4,649 | 11 | 4,638 | 0.2% | 0/4649 | complete |
| libnetworkextension | 97 | 0 | 97 | 0.0% | 0/97 | complete |
| libNFC_Comet | 231 | 0 | 231 | 0.0% | 0/231 | complete |
| libNFC_HAL | 135 | 0 | 135 | 0.0% | 0/135 | complete |
| libnfrestore | 18 | 0 | 18 | 0.0% | 0/18 | complete |
| libnfshared | 121 | 0 | 121 | 0.0% | 0/121 | complete |
| libnfstorage | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| libnwswifttls | 5 | 0 | 5 | 0.0% | 0/5 | complete |
| libobjc | 381 | 381 | 0 | 100.0% | 0/381 | complete |
| libobjc.A | 381 | 381 | 0 | 100.0% | 0/381 | complete |
| libodaccesstoken | 36 | 0 | 36 | 0.0% | 0/36 | complete |
| libodfde | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libodmodule | 590 | 0 | 590 | 0.0% | 0/590 | complete |
| libpam | 47 | 47 | 0 | 100.0% | 0/47 | complete |
| libpam.1 | 28 | 28 | 0 | 100.0% | 0/28 | complete |
| libpam.2 | 47 | 47 | 0 | 100.0% | 0/47 | complete |
| libpanel | 15 | 0 | 15 | 0.0% | 0/15 | complete |
| libpanel.5.4 | 15 | 0 | 15 | 0.0% | 0/15 | complete |
| libParallelCompression | 75 | 0 | 75 | 0.0% | 0/75 | complete |
| libpartition2_dynamic | 33 | 0 | 33 | 0.0% | 0/33 | complete |
| libpcap | 200 | 0 | 200 | 0.0% | 0/200 | complete |
| libpcap.A | 200 | 0 | 200 | 0.0% | 0/200 | complete |
| libpcre | 31 | 0 | 31 | 0.0% | 0/31 | complete |
| libpcre.0 | 31 | 0 | 31 | 0.0% | 0/31 | complete |
| libpcre2-8 | 73 | 0 | 73 | 0.0% | 0/73 | complete |
| libpcre2-8.0 | 73 | 0 | 73 | 0.0% | 0/73 | complete |
| libpcre2-posix | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libpcre2-posix.3 | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libpcreposix | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libpcreposix.0 | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libperfcheck | 55 | 0 | 55 | 0.0% | 0/55 | complete |
| libpmenergy | 7 | 0 | 7 | 0.0% | 0/7 | complete |
| libpmsample | 22 | 0 | 22 | 0.0% | 0/22 | complete |
| libPN548_API | 115 | 0 | 115 | 0.0% | 0/115 | complete |
| libpoll | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libPPM | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| libPPMDataModel | 6 | 0 | 6 | 0.0% | 0/6 | complete |
| libprequelite | 10 | 0 | 10 | 0.0% | 0/10 | complete |
| libproc | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libpthread | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libQMIParserDynamic | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libquarantine | 32 | 32 | 0 | 100.0% | 0/32 | complete |
| libquic | 8 | 0 | 8 | 0.0% | 0/8 | complete |
| libquit | 9 | 0 | 9 | 0.0% | 0/9 | complete |
| libramrod | 598 | 0 | 598 | 0.0% | 0/598 | complete |
| librdma | 0 | 0 | 0 | incomplete | 0/0 | incomplete |
| libreadline | 145 | 145 | 0 | 100.0% | 0/145 | complete |
| librealtime_safety | 7 | 0 | 7 | 0.0% | 0/7 | complete |
| libremovefile | 7 | 7 | 0 | 100.0% | 0/7 | complete |
| libresolv | 147 | 147 | 0 | 100.0% | 0/147 | complete |
| libresolv.9 | 147 | 147 | 0 | 100.0% | 0/147 | complete |
| libReverseProxyDevice | 6 | 0 | 6 | 0.0% | 0/6 | complete |
| libRPAC | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| librpcsvc | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libruby | 948 | 0 | 948 | 0.0% | 0/948 | complete |
| libruby.2.6 | 948 | 0 | 948 | 0.0% | 0/948 | complete |
| libsandbox | 27 | 7 | 20 | 25.9% | 0/27 | complete |
| libsandbox.1 | 27 | 7 | 20 | 25.9% | 0/27 | complete |
| libsasl2 | 66 | 0 | 66 | 0.0% | 0/66 | complete |
| libsasl2.2 | 66 | 0 | 66 | 0.0% | 0/66 | complete |
| libsasl2.2.0.1 | 66 | 0 | 66 | 0.0% | 0/66 | complete |
| libsasl2.2.0.15 | 66 | 0 | 66 | 0.0% | 0/66 | complete |
| libsasl2.2.0.21 | 66 | 0 | 66 | 0.0% | 0/66 | complete |
| libsasl2.2.0.22 | 66 | 0 | 66 | 0.0% | 0/66 | complete |
| libsbuf | 29 | 29 | 0 | 100.0% | 0/29 | complete |
| libSCLM | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libScreenReader | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libSecureMAHelper | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libskit | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libSLAMDynamic | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| libSMC | 139 | 0 | 139 | 0.0% | 0/139 | complete |
| libSoftwareUpdateSSO | 15 | 0 | 15 | 0.0% | 0/15 | complete |
| libSpatial | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libspindump | 24 | 0 | 24 | 0.0% | 0/24 | complete |
| libsqlite3 | 356 | 339 | 17 | 95.2% | 0/356 | complete |
| libsqlite3.0 | 356 | 339 | 17 | 95.2% | 0/356 | complete |
| libsysdiagnose | 21 | 0 | 21 | 0.0% | 0/21 | complete |
| libsysmon | 31 | 31 | 0 | 100.0% | 0/31 | complete |
| libSystem | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libSystem.B | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| libsystem_asl | 205 | 205 | 0 | 100.0% | 0/205 | complete |
| libsystem_blocks | 1 | 1 | 0 | 100.0% | 0/1 | complete |
| libsystem_c | 1,036 | 1,036 | 0 | 100.0% | 0/1036 | complete |
| libsystem_collections | 57 | 57 | 0 | 100.0% | 0/57 | complete |
| libsystem_configuration | 29 | 29 | 0 | 100.0% | 0/29 | complete |
| libsystem_containermanager | 383 | 383 | 0 | 100.0% | 0/383 | complete |
| libsystem_coreservices | 6 | 6 | 0 | 100.0% | 0/6 | complete |
| libsystem_darwin | 73 | 73 | 0 | 100.0% | 0/73 | complete |
| libsystem_darwindirectory | 3 | 3 | 0 | 100.0% | 0/3 | complete |
| libsystem_dnssd | 61 | 61 | 0 | 100.0% | 0/61 | complete |
| libsystem_eligibility | 16 | 16 | 0 | 100.0% | 0/16 | complete |
| libsystem_featureflags | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libsystem_info | 416 | 416 | 0 | 100.0% | 0/416 | complete |
| libsystem_kernel | 1,221 | 1,221 | 0 | 100.0% | 0/1221 | complete |
| libsystem_m | 270 | 270 | 0 | 100.0% | 0/270 | complete |
| libsystem_malloc | 110 | 110 | 0 | 100.0% | 0/110 | complete |
| libsystem_networkextension | 180 | 180 | 0 | 100.0% | 0/180 | complete |
| libsystem_notify | 22 | 22 | 0 | 100.0% | 0/22 | complete |
| libsystem_platform | 101 | 101 | 0 | 100.0% | 0/101 | complete |
| libsystem_pthread | 152 | 152 | 0 | 100.0% | 0/152 | complete |
| libsystem_sandbox | 161 | 161 | 0 | 100.0% | 0/161 | complete |
| libsystem_sanitizers | 5 | 5 | 0 | 100.0% | 0/5 | complete |
| libsystem_secinit | 4 | 4 | 0 | 100.0% | 0/4 | complete |
| libsystem_symptoms | 7 | 7 | 0 | 100.0% | 0/7 | complete |
| libsystem_trace | 105 | 105 | 0 | 100.0% | 0/105 | complete |
| libsystem_trial | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libsystemstats | 67 | 0 | 67 | 0.0% | 0/67 | complete |
| libtailspin | 214 | 0 | 214 | 0.0% | 0/214 | complete |
| libtcl | 812 | 0 | 812 | 0.0% | 0/812 | complete |
| libtcl8.5 | 812 | 0 | 812 | 0.0% | 0/812 | complete |
| libTelephonyCapabilities | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| libTelephonyDebugDynamic | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| libTelephonyIOKitDynamic | 25 | 0 | 25 | 0.0% | 0/25 | complete |
| libTelephonyUtilDynamic | 73 | 0 | 73 | 0.0% | 0/73 | complete |
| libtermcap | 764 | 764 | 0 | 100.0% | 0/764 | complete |
| libThaiTokenizer | 7 | 0 | 7 | 0.0% | 0/7 | complete |
| libtidy | 297 | 0 | 297 | 0.0% | 0/297 | complete |
| libtidy.A | 297 | 0 | 297 | 0.0% | 0/297 | complete |
| libtk | 585 | 0 | 585 | 0.0% | 0/585 | complete |
| libtk8.5 | 585 | 0 | 585 | 0.0% | 0/585 | complete |
| libTLE | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libtzupdate | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libunc | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| libUniversalAccess | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| libunwind | 16 | 16 | 0 | 100.0% | 0/16 | complete |
| libUSBCfwflasher | 9 | 0 | 9 | 0.0% | 0/9 | complete |
| libusrtcp | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libutil | 21 | 21 | 0 | 100.0% | 0/21 | complete |
| libutil1.0 | 21 | 21 | 0 | 100.0% | 0/21 | complete |
| libxar | 205 | 0 | 205 | 0.0% | 0/205 | complete |
| libxar.1 | 205 | 0 | 205 | 0.0% | 0/205 | complete |
| libXARSigner | 9 | 0 | 9 | 0.0% | 0/9 | complete |
| libxcselect | 12 | 0 | 12 | 0.0% | 0/12 | complete |
| libxml2 | 1,653 | 1,653 | 0 | 100.0% | 0/1653 | complete |
| libxml2.2 | 1,653 | 1,653 | 0 | 100.0% | 0/1653 | complete |
| libxo | 128 | 128 | 0 | 100.0% | 0/128 | complete |
| libxpc | 673 | 0 | 673 | 0.0% | 0/673 | complete |
| libxpc_datastores | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| libXplugin | 56 | 0 | 56 | 0.0% | 0/56 | complete |
| libXplugin.1 | 56 | 0 | 56 | 0.0% | 0/56 | complete |
| libxslt | 251 | 0 | 251 | 0.0% | 0/251 | complete |
| libxslt.1 | 251 | 0 | 251 | 0.0% | 0/251 | complete |
| libz | 81 | 81 | 0 | 100.0% | 0/81 | complete |
| libz.1 | 81 | 81 | 0 | 100.0% | 0/81 | complete |
| libz.1.1.3 | 81 | 81 | 0 | 100.0% | 0/81 | complete |
| libz.1.2.11 | 81 | 81 | 0 | 100.0% | 0/81 | complete |
| libz.1.2.12 | 81 | 81 | 0 | 100.0% | 0/81 | complete |
| libz.1.2.5 | 81 | 81 | 0 | 100.0% | 0/81 | complete |
| libz.1.2.8 | 81 | 81 | 0 | 100.0% | 0/81 | complete |
| LightweightCodeRequirements | 238 | 0 | 238 | 0.0% | 0/238 | complete |
| LinkPresentation | 150 | 19 | 131 | 12.7% | 1/150 | complete |
| LiveCommunicationKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| LocalAuthentication | 127 | 70 | 57 | 55.1% | 2/127 | complete |
| LocalAuthentication/DaemonUtils | 26 | 0 | 26 | 0.0% | 0/26 | complete |
| LocalAuthentication/MechanismBase | 21 | 0 | 21 | 0.0% | 0/21 | complete |
| LocalAuthentication/ModuleBase | 9 | 0 | 9 | 0.0% | 0/9 | complete |
| LocalAuthentication/SharedUtils | 22 | 0 | 22 | 0.0% | 0/22 | complete |
| LocalAuthenticationEmbeddedUI | 9 | 0 | 9 | 0.0% | 0/9 | complete |
| log/liblog_AppStoreDaemon | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| log/liblog_coreacc | 17 | 0 | 17 | 0.0% | 0/17 | complete |
| log/liblog_geo | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| log/liblog_location | 6 | 0 | 6 | 0.0% | 0/6 | complete |
| log/liblog_mdns | 40 | 0 | 40 | 0.0% | 0/40 | complete |
| log/liblog_mdnsresponder | 37 | 0 | 37 | 0.0% | 0/37 | complete |
| log/liblog_network | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| log/liblog_odtypes | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| log/liblog_signpost | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| log/liblog_signpost.description | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| log/liblog_signpost.telemetry | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| log/liblog_sonic | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| log/liblog_srp | 37 | 0 | 37 | 0.0% | 0/37 | complete |
| log/liblog_SystemConfiguration | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| MailKit | 135 | 0 | 135 | 0.0% | 0/135 | complete |
| ManagedAppDistribution | 93 | 0 | 93 | 0.0% | 0/93 | complete |
| ManagedSettings | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| MapKit | 782 | 0 | 782 | 0.0% | 0/782 | complete |
| Matter | 18,058 | 0 | 18,058 | 0.0% | 0/18058 | complete |
| MatterSupport | 138 | 0 | 138 | 0.0% | 0/138 | complete |
| MediaAccessibility | 53 | 41 | 12 | 77.4% | 0/53 | complete |
| MediaExtension | 210 | 0 | 210 | 0.0% | 0/210 | complete |
| MediaLibrary | 187 | 0 | 187 | 0.0% | 0/187 | complete |
| MediaPlayer | 635 | 275 | 360 | 43.3% | 0/635 | complete |
| MediaToolbox | 30 | 0 | 30 | 0.0% | 0/30 | complete |
| Message | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| Metal | 1,901 | 848 | 1,053 | 44.6% | 376/1901 | complete |
| MetalFX | 232 | 0 | 232 | 0.0% | 0/232 | complete |
| MetalKit | 99 | 84 | 15 | 84.8% | 17/99 | complete |
| MetalPerformancePrimitives | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| MetalPerformanceShaders | 2,675 | 0 | 2,675 | 0.0% | 0/2675 | complete |
| MetalPerformanceShaders/MPSBenchmarkLoop | 7 | 0 | 7 | 0.0% | 0/7 | complete |
| MetalPerformanceShaders/MPSCore | 255 | 0 | 255 | 0.0% | 0/255 | complete |
| MetalPerformanceShaders/MPSFunctions | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| MetalPerformanceShaders/MPSHost | 28 | 0 | 28 | 0.0% | 0/28 | complete |
| MetalPerformanceShaders/MPSImage | 256 | 0 | 256 | 0.0% | 0/256 | complete |
| MetalPerformanceShaders/MPSMatrix | 106 | 0 | 106 | 0.0% | 0/106 | complete |
| MetalPerformanceShaders/MPSNDArray | 340 | 0 | 340 | 0.0% | 0/340 | complete |
| MetalPerformanceShaders/MPSNeuralNetwork | 1,541 | 0 | 1,541 | 0.0% | 0/1541 | complete |
| MetalPerformanceShaders/MPSRayIntersector | 136 | 0 | 136 | 0.0% | 0/136 | complete |
| MetalPerformanceShadersGraph | 653 | 0 | 653 | 0.0% | 0/653 | complete |
| MetricKit | 189 | 0 | 189 | 0.0% | 0/189 | complete |
| MLCompute | 573 | 0 | 573 | 0.0% | 0/573 | complete |
| ModelIO | 680 | 0 | 680 | 0.0% | 0/680 | complete |
| MultipeerConnectivity | 74 | 0 | 74 | 0.0% | 0/74 | complete |
| MusicKit | 1,370 | 0 | 1,370 | 0.0% | 0/1370 | complete |
| NaturalLanguage | 247 | 0 | 247 | 0.0% | 0/247 | complete |
| NearbyInteraction | 73 | 0 | 73 | 0.0% | 0/73 | complete |
| NetFS | 5 | 0 | 5 | 0.0% | 0/5 | complete |
| Network | 1,921 | 633 | 1,288 | 33.0% | 4/1921 | complete |
| NetworkExtension | 5,292 | 0 | 5,292 | 0.0% | 0/5292 | complete |
| NotificationCenter | 38 | 0 | 38 | 0.0% | 0/38 | complete |
| OpenAL | 98 | 0 | 98 | 0.0% | 0/98 | complete |
| OpenCL | 142 | 0 | 142 | 0.0% | 0/142 | complete |
| OpenDirectory | 629 | 573 | 56 | 91.1% | 395/629 | complete |
| OpenDirectory/CFOpenDirectory | 463 | 401 | 62 | 86.6% | 387/463 | complete |
| OpenGL | 1,408 | 1,179 | 229 | 83.7% | 0/1408 | complete |
| OpenGL/libGL | 1,278 | 1,104 | 174 | 86.4% | 0/1278 | complete |
| OpenGL/libGLU | 80 | 24 | 56 | 30.0% | 0/80 | complete |
| OSAKit | 170 | 99 | 71 | 58.2% | 19/170 | complete |
| OSLog | 20 | 0 | 20 | 0.0% | 0/20 | complete |
| PaperKit | 160 | 0 | 160 | 0.0% | 0/160 | complete |
| ParavirtualizedGraphics | 64 | 0 | 64 | 0.0% | 0/64 | complete |
| PassKit | 424 | 0 | 424 | 0.0% | 0/424 | complete |
| PCSC | 62 | 0 | 62 | 0.0% | 0/62 | complete |
| PDFKit | 562 | 371 | 191 | 66.0% | 0/562 | complete |
| PencilKit | 286 | 0 | 286 | 0.0% | 0/286 | complete |
| PermissionKit | 109 | 0 | 109 | 0.0% | 0/109 | complete |
| PHASE | 360 | 0 | 360 | 0.0% | 0/360 | complete |
| Photos | 613 | 0 | 613 | 0.0% | 0/613 | complete |
| PhotosUI | 268 | 0 | 268 | 0.0% | 0/268 | complete |
| PreferencePanes | 50 | 0 | 50 | 0.0% | 0/50 | complete |
| ProximityReaderStub | 2 | 0 | 2 | 0.0% | 0/2 | complete |
| PushKit | 21 | 0 | 21 | 0.0% | 0/21 | complete |
| PushToTalk | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| QTKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| Quartz | 5,322 | 3,130 | 2,192 | 58.8% | 0/5322 | complete |
| Quartz/ImageKit | 378 | 290 | 88 | 76.7% | 86/378 | complete |
| Quartz/PDFKit | 562 | 371 | 191 | 66.0% | 0/562 | complete |
| Quartz/QuartzComposer | 747 | 0 | 747 | 0.0% | 0/747 | complete |
| Quartz/QuartzFilters | 33 | 29 | 4 | 87.9% | 8/33 | complete |
| Quartz/QuickLookUI | 189 | 63 | 126 | 33.3% | 0/189 | complete |
| QuartzCore | 3,413 | 2,291 | 1,122 | 67.1% | 728/3413 | complete |
| QuickLook | 74 | 19 | 55 | 25.7% | 18/74 | complete |
| QuickLookThumbnailing | 60 | 26 | 34 | 43.3% | 1/60 | complete |
| QuickLookUI | 189 | 63 | 126 | 33.3% | 0/189 | complete |
| RealityFoundation | 4,295 | 0 | 4,295 | 0.0% | 0/4295 | complete |
| RealityKit | 4,501 | 0 | 4,501 | 0.0% | 0/4501 | complete |
| RelevanceKit | 46 | 0 | 46 | 0.0% | 0/46 | complete |
| ReplayKit | 105 | 0 | 105 | 0.0% | 0/105 | complete |
| Ruby | 948 | 0 | 948 | 0.0% | 0/948 | complete |
| SafariServices | 77 | 0 | 77 | 0.0% | 0/77 | complete |
| SafetyKit | 32 | 0 | 32 | 0.0% | 0/32 | complete |
| SceneKit | 1,093 | 0 | 1,093 | 0.0% | 0/1093 | complete |
| ScreenCaptureKit | 212 | 150 | 62 | 70.8% | 10/212 | complete |
| ScreenSaver | 35 | 0 | 35 | 0.0% | 0/35 | complete |
| ScreenTime | 26 | 0 | 26 | 0.0% | 0/26 | complete |
| ScriptingBridge | 37 | 0 | 37 | 0.0% | 0/37 | complete |
| Security | 1,858 | 1,555 | 303 | 83.7% | 1171/1858 | complete |
| SecurityFoundation | 1,890 | 1,567 | 323 | 82.9% | 0/1890 | complete |
| SecurityInterface | 2,022 | 1,672 | 350 | 82.7% | 4/2022 | complete |
| SecurityUI | 13 | 0 | 13 | 0.0% | 0/13 | complete |
| SensitiveContentAnalysis | 28 | 0 | 28 | 0.0% | 0/28 | complete |
| SensorKit | 15 | 0 | 15 | 0.0% | 0/15 | complete |
| ServiceManagement | 21 | 21 | 0 | 100.0% | 6/21 | complete |
| SharedWithYou | 154 | 0 | 154 | 0.0% | 0/154 | complete |
| SharedWithYouCore | 71 | 0 | 71 | 0.0% | 0/71 | complete |
| ShazamKit | 185 | 0 | 185 | 0.0% | 0/185 | complete |
| Social | 78 | 0 | 78 | 0.0% | 0/78 | complete |
| SoundAnalysis | 103 | 0 | 103 | 0.0% | 0/103 | complete |
| Speech | 503 | 0 | 503 | 0.0% | 0/503 | complete |
| SpriteKit | 812 | 0 | 812 | 0.0% | 0/812 | complete |
| ssh-keychain | 5 | 0 | 5 | 0.0% | 0/5 | complete |
| StickerFoundation | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| StickerKit | 14 | 0 | 14 | 0.0% | 0/14 | complete |
| StoreKit | 823 | 107 | 716 | 13.0% | 15/823 | complete |
| swift/libswift_Builtin_float | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_Concurrency | 112 | 112 | 0 | 100.0% | 0/112 | complete |
| swift/libswift_DarwinFoundation1 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_DarwinFoundation2 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_DarwinFoundation3 | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_errno | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_math | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_RegexParser | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_signal | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_stdio | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_StringProcessing | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_time | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswift_Volatile | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftAccelerate | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftAppKit | 18,585 | 16,365 | 2,220 | 88.1% | 0/18585 | complete |
| swift/libswiftAppleArchive | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftARKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftAVFoundation | 671 | 605 | 66 | 90.2% | 0/671 | complete |
| swift/libswiftCallKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCloudKit | 997 | 114 | 883 | 11.4% | 0/997 | complete |
| swift/libswiftCompatibilitySpan | 461 | 461 | 0 | 100.0% | 0/461 | complete |
| swift/libswiftCompression | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftContacts | 830 | 0 | 830 | 0.0% | 0/830 | complete |
| swift/libswiftCore | 461 | 461 | 0 | 100.0% | 0/461 | complete |
| swift/libswiftCoreAudio | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCoreData | 959 | 0 | 959 | 0.0% | 0/959 | complete |
| swift/libswiftCoreFoundation | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCoreGraphics | 1,176 | 871 | 305 | 74.1% | 0/1176 | complete |
| swift/libswiftCoreImage | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCoreLocation | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCoreMedia | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCoreMediaIO | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCoreMIDI | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCoreML | 900 | 0 | 900 | 0.0% | 0/900 | complete |
| swift/libswiftCreateML | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftCryptoTokenKit | 221 | 0 | 221 | 0.0% | 0/221 | complete |
| swift/libswiftDarwin | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftDataDetection | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftDemangle | 5 | 0 | 5 | 0.0% | 0/5 | complete |
| swift/libswiftDispatch | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftDistributed | 2 | 2 | 0 | 100.0% | 0/2 | complete |
| swift/libswiftExtensionFoundation | 111 | 0 | 111 | 0.0% | 0/111 | complete |
| swift/libswiftExtensionKit | 151 | 0 | 151 | 0.0% | 0/151 | complete |
| swift/libswiftFileProvider | 394 | 0 | 394 | 0.0% | 0/394 | complete |
| swift/libswiftFoundation | 2,916 | 2,589 | 327 | 88.8% | 0/2916 | complete |
| swift/libswiftGameplayKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftGLKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftHealthKit | 1,770 | 0 | 1,770 | 0.0% | 0/1770 | complete |
| swift/libswiftIdentityLookup | 27 | 0 | 27 | 0.0% | 0/27 | complete |
| swift/libswiftIntents | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftIOKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftMapKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftMetal | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftMetalKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftMetricKit | 42 | 0 | 42 | 0.0% | 0/42 | complete |
| swift/libswiftMLCompute | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftModelIO | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftNaturalLanguage | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftNearbyInteraction | 73 | 0 | 73 | 0.0% | 0/73 | complete |
| swift/libswiftNetwork | 4,649 | 11 | 4,638 | 0.2% | 0/4649 | complete |
| swift/libswiftObjectiveC | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftObservation | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftOpenCL | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftos | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftOSLog | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftPassKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftPencilKit | 153 | 0 | 153 | 0.0% | 0/153 | complete |
| swift/libswiftPhotos | 613 | 0 | 613 | 0.0% | 0/613 | complete |
| swift/libswiftPhotosUI | 268 | 0 | 268 | 0.0% | 0/268 | complete |
| swift/libswiftQuartzCore | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftQuickLookUI | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftRegexBuilder | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftRemoteMirror | 49 | 0 | 49 | 0.0% | 0/49 | complete |
| swift/libswiftRuntime | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftSafariServices | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftSceneKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftShazamKit | 134 | 0 | 134 | 0.0% | 0/134 | complete |
| swift/libswiftsimd | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftSoundAnalysis | 103 | 0 | 103 | 0.0% | 0/103 | complete |
| swift/libswiftSoundAnalysis_Private | 103 | 0 | 103 | 0.0% | 0/103 | complete |
| swift/libswiftSpatial | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftSpeech | 503 | 0 | 503 | 0.0% | 0/503 | complete |
| swift/libswiftSpriteKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftSwiftOnoneSupport | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftSynchronization | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftsys_time | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftSystem | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftSystem_Foundation | 2,916 | 0 | 2,916 | 0.0% | 0/2916 | complete |
| swift/libswiftUniformTypeIdentifiers | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftunistd | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftVideoToolbox | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| swift/libswiftVirtualization | 111 | 0 | 111 | 0.0% | 0/111 | complete |
| swift/libswiftVision | 2,674 | 0 | 2,674 | 0.0% | 0/2674 | complete |
| swift/libswiftXPC | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| SwiftData | 630 | 240 | 390 | 38.1% | 0/630 | complete |
| SwiftUI | 8,816 | 5,087 | 3,729 | 57.7% | 0/8816 | complete |
| SwiftUICore | 3,803 | 2,370 | 1,433 | incomplete | 0/3803 | incomplete |
| Symbols | 276 | 0 | 276 | 0.0% | 0/276 | complete |
| SyncServices | 280 | 0 | 280 | 0.0% | 0/280 | complete |
| System | 7,267 | 2 | 7,265 | 0.0% | 0/7267 | complete |
| SystemConfiguration | 467 | 467 | 0 | 100.0% | 300/467 | complete |
| SystemExtensions | 38 | 0 | 38 | 0.0% | 0/38 | complete |
| TabularData | 815 | 0 | 815 | 0.0% | 0/815 | complete |
| Tcl | 587 | 0 | 587 | 0.0% | 0/587 | complete |
| TelephonyMessagingKit | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| ThreadNetwork | 23 | 0 | 23 | 0.0% | 0/23 | complete |
| TipKit | 311 | 294 | 17 | 94.5% | 0/311 | complete |
| Tk | 0 | 0 | 0 | incomplete | 0/0 | incomplete |
| Translation | 85 | 0 | 85 | 0.0% | 0/85 | complete |
| TWAIN | 1 | 0 | 1 | 0.0% | 0/1 | complete |
| UniformTypeIdentifiers | 178 | 178 | 0 | 100.0% | 166/178 | complete |
| updaters/libAce3Updater | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| updaters/libAppleTconUARPUpdater | 12 | 0 | 12 | 0.0% | 0/12 | complete |
| updaters/libAppleTCONUpdater | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| updaters/libAppleTypeCRetimerUpdater | 10 | 0 | 10 | 0.0% | 0/10 | complete |
| updaters/libCentauriUpdater | 4 | 0 | 4 | 0.0% | 0/4 | complete |
| updaters/libPFXUpdater | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| updaters/libPS190Updater | 3 | 0 | 3 | 0.0% | 0/3 | complete |
| updaters/libSEUpdater | 8 | 0 | 8 | 0.0% | 0/8 | complete |
| updaters/libT200Updater | 98 | 0 | 98 | 0.0% | 0/98 | complete |
| usd/libAlembic | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| usd/libHalf | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| usd/libIex | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| usd/libImath | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| usd/libOSD | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| usd/libtbb | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| usd/libusd_ms | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| UserNotifications | 144 | 118 | 26 | 81.9% | 7/144 | complete |
| UserNotificationsUI | 12 | 0 | 12 | 0.0% | 0/12 | complete |
| vecLib | 12,956 | 0 | 12,956 | 0.0% | 0/12956 | complete |
| VideoDecodeAcceleration | 8 | 0 | 8 | 0.0% | 0/8 | complete |
| VideoSubscriberAccount | 214 | 0 | 214 | 0.0% | 0/214 | complete |
| VideoToolbox | 578 | 504 | 74 | 87.2% | 323/578 | complete |
| Virtualization | 402 | 0 | 402 | 0.0% | 0/402 | complete |
| Vision | 2,674 | 0 | 2,674 | 0.0% | 0/2674 | complete |
| VisionKit | 116 | 0 | 116 | 0.0% | 0/116 | complete |
| vmnet | 55 | 0 | 55 | 0.0% | 0/55 | complete |
| WeatherKit | 623 | 0 | 623 | 0.0% | 0/623 | complete |
| WebKit | 2,908 | 0 | 2,908 | 0.0% | 0/2908 | complete |
| WebKit/WebKitLegacy | 271 | 0 | 271 | 0.0% | 0/271 | complete |
| WidgetKit | 272 | 99 | 173 | 36.4% | 0/272 | complete |
| WiFiAware | 0 | 0 | 0 | 0.0% | 0/0 | empty |
| WorkoutKit | 240 | 0 | 240 | 0.0% | 0/240 | complete |

## Finch images not built

These SDK frameworks or dylibs have no Finch image. The size column is the number of API items found for that image.

| Framework or dylib | API items missing |
|---|---:|
| Matter | 18,058 |
| Accelerate/vecLib | 12,956 |
| vecLib | 12,956 |
| libclapack | 9,998 |
| libf77lapack | 9,998 |
| liblapack | 9,998 |
| NetworkExtension | 5,292 |
| GameKit | 4,585 |
| RealityKit | 4,501 |
| RealityFoundation | 4,295 |
| CoreHID | 3,214 |
| swift/libswiftSystem_Foundation | 2,916 |
| WebKit | 2,908 |
| MetalPerformanceShaders | 2,675 |
| swift/libswiftVision | 2,674 |
| Vision | 2,674 |
| CreateMLComponents | 2,258 |
| CreateML | 1,798 |
| HealthKit | 1,770 |
| swift/libswiftHealthKit | 1,770 |
| libcoreroutine | 1,631 |
| MetalPerformanceShaders/MPSNeuralNetwork | 1,541 |
| libblas | 1,464 |
| libcblas | 1,464 |
| MusicKit | 1,370 |
| DiscRecording | 1,267 |
| BackgroundAssets | 1,174 |
| SceneKit | 1,093 |
| libcorecrypto_trace | 1,092 |
| libcorecrypto_noasm | 1,073 |
| libnetsnmp | 1,013 |
| libnetsnmp.25 | 1,013 |
| AddressBook | 975 |
| swift/libswiftCoreData | 959 |
| libruby | 948 |
| libruby.2.6 | 948 |
| Ruby | 948 |
| CoreML | 900 |
| swift/libswiftCoreML | 900 |
| Charts | 840 |
| swift/libswiftContacts | 830 |
| TabularData | 815 |
| libtcl | 812 |
| libtcl8.5 | 812 |
| SpriteKit | 812 |
| libnetsnmpmibs | 806 |
| libnetsnmpmibs.25 | 806 |
| MapKit | 782 |
| libcom_err | 776 |
| libdes425 | 776 |
| libgssapi_krb5 | 776 |
| libk5crypto | 776 |
| libkrb4 | 776 |
| libkrb5 | 776 |
| libkrb524 | 776 |
| libkrb5support | 776 |
| libauthinstall | 753 |
| Quartz/QuartzComposer | 747 |
| ModelIO | 680 |
| libxpc | 673 |
| MetalPerformanceShadersGraph | 653 |
| libnetsnmpagent | 629 |
| libnetsnmpagent.25 | 629 |
| AudioVideoBridging | 627 |
| WeatherKit | 623 |
| Photos | 613 |
| swift/libswiftPhotos | 613 |
| libramrod | 598 |
| Accelerate/vImage | 591 |
| libodmodule | 590 |
| Tcl | 587 |
| libtk | 585 |
| libtk8.5 | 585 |
| Accelerate/vecLib/libvMisc | 582 |
| MLCompute | 573 |
| libapr-1 | 510 |
| libapr-1.0 | 510 |
| Speech | 503 |
| swift/libswiftSpeech | 503 |
| CoreDisplay | 495 |
| libamsupport | 493 |
| Accelerate/vecLib/libvDSP | 469 |
| libcups | 451 |
| libcups.2 | 451 |
| GameplayKit | 448 |
| libboringssl | 447 |
| FoundationModels | 442 |
| libarchive | 425 |
| libarchive.2 | 425 |
| PassKit | 424 |
| Kerberos | 418 |
| Virtualization | 402 |
| FileProvider | 394 |
| swift/libswiftFileProvider | 394 |
| PHASE | 360 |
| EventKit | 351 |
| libAccessibility | 343 |
| MetalPerformanceShaders/MPSNDArray | 340 |
| BrowserEngineKit | 334 |
| introspection/libdispatch | 321 |
| CoreMIDIServer | 319 |
| FSKit | 317 |
| ImmersiveMediaSupport | 310 |
| libaxis | 298 |
| libtidy | 297 |
| libtidy.A | 297 |
| liblber | 294 |
| libldap | 294 |
| libldap_r | 294 |
| libFDR | 293 |
| libFDR_osx | 293 |
| libaprutil-1 | 292 |
| libaprutil-1.0 | 292 |
| InputMethodKit | 289 |
| PencilKit | 286 |
| Cinematic | 284 |
| libmecabra | 281 |
| SyncServices | 280 |
| Symbols | 276 |
| WebKit/WebKitLegacy | 271 |
| Accelerate/vecLib/libBNNS | 269 |
| PhotosUI | 268 |
| swift/libswiftPhotosUI | 268 |
| CoreTelephony | 264 |
| MetalPerformanceShaders/MPSImage | 256 |
| MetalPerformanceShaders/MPSCore | 255 |
| libxslt | 251 |
| libxslt.1 | 251 |
| NaturalLanguage | 247 |
| WorkoutKit | 240 |
| LightweightCodeRequirements | 238 |
| libAppleArchive | 232 |
| MetalFX | 232 |
| libNFC_Comet | 231 |
| JavaScriptCore | 224 |
| libcmark-gfm | 223 |
| CoreMotion | 222 |
| iTunesLibrary | 221 |
| swift/libswiftCryptoTokenKit | 221 |
| libmdns | 218 |
| DockKit | 217 |
| libtailspin | 214 |
| VideoSubscriberAccount | 214 |
| MediaExtension | 210 |
| libxar | 205 |
| libxar.1 | 205 |
| IOUSBHost | 204 |
| libpcap | 200 |
| libpcap.A | 200 |
| GroupActivities | 196 |
| libhwtrace | 193 |
| MetricKit | 189 |
| Automator | 187 |
| MediaLibrary | 187 |
| ShazamKit | 185 |
| GLKit | 183 |
| libapple_nghttp2 | 182 |
| ClassKit | 176 |
| CoreMediaIO | 168 |
| DriverKit | 161 |
| libcryptex | 161 |
| PaperKit | 160 |
| libiodbc | 154 |
| libiodbc.2 | 154 |
| libiodbc.2.1.18 | 154 |
| libmis | 154 |
| SharedWithYou | 154 |
| swift/libswiftPencilKit | 153 |
| introspection/libsystem_pthread | 152 |
| libCRFSuite | 152 |
| libCRFSuite0.12 | 152 |
| ExtensionKit | 151 |
| swift/libswiftExtensionKit | 151 |
| libcryptex_core | 147 |
| libcoretls | 143 |
| OpenCL | 142 |
| libSMC | 139 |
| MatterSupport | 138 |
| MetalPerformanceShaders/MPSRayIntersector | 136 |
| libNFC_HAL | 135 |
| MailKit | 135 |
| swift/libswiftShazamKit | 134 |
| CalendarStore | 129 |
| Accelerate/vecLib/libSparseBLAS | 127 |
| CoreHaptics | 127 |
| GLUT | 127 |
| libIOAccessoryManager | 127 |
| libheimdal-asn1 | 124 |
| DataDetection | 123 |
| libnfshared | 121 |
| ApplicationServices/ColorSyncLegacy | 120 |
| ApplicationServices/SpeechSynthesis | 119 |
| libmorphun | 118 |
| VisionKit | 116 |
| CompositorServices | 115 |
| libPN548_API | 115 |
| DVDPlayback | 114 |
| ExtensionFoundation | 111 |
| swift/libswiftExtensionFoundation | 111 |
| swift/libswiftVirtualization | 111 |
| PermissionKit | 109 |
| MetalPerformanceShaders/MPSMatrix | 106 |
| ImagePlayground | 105 |
| libbootpolicy | 105 |
| ReplayKit | 105 |
| SoundAnalysis | 103 |
| swift/libswiftSoundAnalysis | 103 |
| swift/libswiftSoundAnalysis_Private | 103 |
| CarKey | 102 |
| InstantMessage | 101 |
| CallKit | 99 |
| libdns_services | 99 |
| OpenAL | 98 |
| updaters/libT200Updater | 98 |
| libnetworkextension | 97 |
| AppleScriptKit | 96 |
| DirectoryService | 96 |
| libcurl | 93 |
| libcurl.3 | 93 |
| libcurl.4 | 93 |
| libdtrace | 93 |
| ManagedAppDistribution | 93 |
| Hypervisor | 89 |
| Translation | 85 |
| liblaunch | 83 |
| libmecab | 82 |
| DiscRecordingUI | 81 |
| JavaRuntimeSupport | 81 |
| libform | 81 |
| libform.5.4 | 81 |
| CoreServices/SearchKit | 79 |
| Social | 78 |
| libimage4 | 77 |
| libimg4 | 77 |
| SafariServices | 77 |
| libcsfde | 75 |
| libParallelCompression | 75 |
| MultipeerConnectivity | 74 |
| libpcre2-8 | 73 |
| libpcre2-8.0 | 73 |
| libTelephonyUtilDynamic | 73 |
| NearbyInteraction | 73 |
| swift/libswiftNearbyInteraction | 73 |
| libAudioStatistics | 71 |
| libexpat | 71 |
| libexpat.1 | 71 |
| SharedWithYouCore | 71 |
| libCoreStorage | 68 |
| libcryptex_interface | 68 |
| libsystemstats | 67 |
| libsasl2 | 66 |
| libsasl2.2 | 66 |
| libsasl2.2.0.1 | 66 |
| libsasl2.2.0.15 | 66 |
| libsasl2.2.0.21 | 66 |
| libsasl2.2.0.22 | 66 |
| libAppleEXR | 65 |
| libmenu | 64 |
| libmenu.5.4 | 64 |
| ParavirtualizedGraphics | 64 |
| libCoreEntitlements | 62 |
| libEndpointSecurity | 62 |
| libIOReport | 62 |
| PCSC | 62 |
| InstallerPlugins | 59 |
| libAccountPolicyTranslation | 58 |
| libFDRDecode | 58 |
| IdentityDocumentServices | 56 |
| libXplugin | 56 |
| libXplugin.1 | 56 |
| libeasyperf | 55 |
| libmrc | 55 |
| libperfcheck | 55 |
| vmnet | 55 |
| CoreAudioKit | 54 |
| libFosl_dynamic | 54 |
| libCoreEntitlements_V2 | 53 |
| libiodbcinst | 52 |
| libiodbcinst.2 | 52 |
| libiodbcinst.2.1.18 | 52 |
| DeviceDiscoveryExtension | 51 |
| GameSave | 51 |
| DeclaredAgeRange | 50 |
| PreferencePanes | 50 |
| swift/libswiftRemoteMirror | 49 |
| Collaboration | 48 |
| AVRouting | 47 |
| ExternalAccessory | 47 |
| RelevanceKit | 46 |
| FinanceKit | 45 |
| Carbon/CommonPanels | 43 |
| Accelerate/vecLib/libLinearAlgebra | 42 |
| Carbon/SpeechRecognition | 42 |
| swift/libswiftMetricKit | 42 |
| IdentityLookup | 41 |
| libnetsnmptrapd | 40 |
| libnetsnmptrapd.25 | 40 |
| log/liblog_mdns | 40 |
| libAudioIssueDetector | 39 |
| libcodedirectory | 39 |
| libffi | 39 |
| AutomaticAssessmentConfiguration | 38 |
| NotificationCenter | 38 |
| SystemExtensions | 38 |
| log/liblog_mdnsresponder | 37 |
| log/liblog_srp | 37 |
| ScriptingBridge | 37 |
| libodaccesstoken | 36 |
| ScreenSaver | 35 |
| libipconfig | 33 |
| libpartition2_dynamic | 33 |
| IntentsUI | 32 |
| libchannel | 32 |
| libcmph | 32 |
| SafetyKit | 32 |
| libhunspell-1.2 | 31 |
| libhunspell-1.2.0 | 31 |
| libhunspell-1.2.0.0.0 | 31 |
| libpcre | 31 |
| libpcre.0 | 31 |
| LatentSemanticMapping | 30 |
| MediaToolbox | 30 |
| libAudioToolboxUtility | 29 |
| MetalPerformanceShaders/MPSHost | 28 |
| SensitiveContentAnalysis | 28 |
| swift/libswiftIdentityLookup | 27 |
| Carbon/SecurityHI | 26 |
| LocalAuthentication/DaemonUtils | 26 |
| ScreenTime | 26 |
| FinderSync | 25 |
| libTelephonyIOKitDynamic | 25 |
| GeoToolbox | 24 |
| libspindump | 24 |
| libnetquality | 23 |
| ThreadNetwork | 23 |
| Carbon/Ink | 22 |
| libapp_launch_measurement | 22 |
| libpmsample | 22 |
| LocalAuthentication/SharedUtils | 22 |
| libMemoryResourceException | 21 |
| libsysdiagnose | 21 |
| LocalAuthentication/MechanismBase | 21 |
| PushKit | 21 |
| ClassKitUI | 20 |
| ForceFeedback | 20 |
| OSLog | 20 |
| libate | 19 |
| libauditd | 18 |
| libauditd.0 | 18 |
| libDHCPServer | 18 |
| libDHCPServer.A | 18 |
| libnfrestore | 18 |
| libexslt | 17 |
| libexslt.0 | 17 |
| log/liblog_coreacc | 17 |
| libAppleSSE | 16 |
| libIASAuthReboot | 15 |
| libpanel | 15 |
| libpanel.5.4 | 15 |
| libSoftwareUpdateSSO | 15 |
| SensorKit | 15 |
| AppleConvergedTransport | 14 |
| DeviceCheck | 14 |
| ExceptionHandling | 14 |
| FamilyControls | 14 |
| libdpfu | 14 |
| libKernelCollectionBuilder | 14 |
| liblangid | 14 |
| StickerKit | 14 |
| FileProviderUI | 13 |
| libkxld | 13 |
| libMatch | 13 |
| libMatch.1 | 13 |
| SecurityUI | 13 |
| libcupsimage | 12 |
| libcupsimage.2 | 12 |
| libfakelink | 12 |
| libhvf | 12 |
| libxcselect | 12 |
| updaters/libAppleTconUARPUpdater | 12 |
| UserNotificationsUI | 12 |
| ActivityKit | 11 |
| FinanceKitUI | 11 |
| IdentityDocumentServicesUI | 11 |
| libBSDPClient | 11 |
| libBSDPClient.A | 11 |
| DeviceActivity | 10 |
| libcupolicy | 10 |
| libdscsym | 10 |
| libprequelite | 10 |
| updaters/libAppleTypeCRetimerUpdater | 10 |
| BusinessChat | 9 |
| libCTGreenTeaLogger | 9 |
| libIOGTrace | 9 |
| libquit | 9 |
| libUSBCfwflasher | 9 |
| libXARSigner | 9 |
| LocalAuthentication/ModuleBase | 9 |
| LocalAuthenticationEmbeddedUI | 9 |
| ExecutionPolicy | 8 |
| libChineseTokenizer | 8 |
| libenergytrace | 8 |
| libInterpreterSecurity | 8 |
| libquic | 8 |
| updaters/libSEUpdater | 8 |
| VideoDecodeAcceleration | 8 |
| libBootCacheLib | 7 |
| libpmenergy | 7 |
| librealtime_safety | 7 |
| libThaiTokenizer | 7 |
| MetalPerformanceShaders/MPSBenchmarkLoop | 7 |
| AppTrackingTransparency | 6 |
| Carbon/Help | 6 |
| libATCommandStudioDynamic | 6 |
| libAXSpeechManager | 6 |
| libcoretls_cfhelpers | 6 |
| libPPMDataModel | 6 |
| libReverseProxyDevice | 6 |
| log/liblog_location | 6 |
| libAXSafeCategoryBundle | 5 |
| libipsec | 5 |
| libipsec.A | 5 |
| libnwswifttls | 5 |
| NetFS | 5 |
| ssh-keychain | 5 |
| swift/libswiftDemangle | 5 |
| Accelerate/vecLib/libSparse | 4 |
| AdServices | 4 |
| KernelManagement | 4 |
| libAHTRestore | 4 |
| libcryptex_trampoline | 4 |
| libDiskUnlock | 4 |
| libodfde | 4 |
| libpcre2-posix | 4 |
| libpcre2-posix.3 | 4 |
| libpcreposix | 4 |
| libpcreposix.0 | 4 |
| libSCLM | 4 |
| libTLE | 4 |
| libusrtcp | 4 |
| libxpc_datastores | 4 |
| log/liblog_AppStoreDaemon | 4 |
| updaters/libCentauriUpdater | 4 |
| AdSupport | 3 |
| AutomaticAssessmentConfiguration/AACClient | 3 |
| BrowserEngineCore | 3 |
| libAppletTranslationLibrary | 3 |
| libBASupport | 3 |
| libInFieldCollection | 3 |
| libnfstorage | 3 |
| libSLAMDynamic | 3 |
| libTelephonyDebugDynamic | 3 |
| updaters/libAce3Updater | 3 |
| updaters/libAppleTCONUpdater | 3 |
| updaters/libPFXUpdater | 3 |
| updaters/libPS190Updater | 3 |
| AutomaticAssessmentConfiguration/AACDependencies | 2 |
| CoreServices/DictionaryServices | 2 |
| libheimdalasn1 | 2 |
| libIASUnifiedProgress | 2 |
| libPPM | 2 |
| libunc | 2 |
| log/liblog_geo | 2 |
| log/liblog_SystemConfiguration | 2 |
| Message | 2 |
| MetalPerformanceShaders/MPSFunctions | 2 |
| ProximityReaderStub | 2 |
| Accelerate/vecLib/libQuadrature | 1 |
| AppleScriptObjC | 1 |
| Kernel | 1 |
| libAmber | 1 |
| libCoreRepairState | 1 |
| libemptyRecovery | 1 |
| libffi-trampolines | 1 |
| libgermantok | 1 |
| libManagedConfigurationFiles | 1 |
| libnetsnmphelpers | 1 |
| libnetsnmphelpers.25 | 1 |
| libSecureMAHelper | 1 |
| libskit | 1 |
| libtzupdate | 1 |
| libUniversalAccess | 1 |
| log/liblog_network | 1 |
| log/liblog_odtypes | 1 |
| TWAIN | 1 |

## App impact

Priority score is missing API items multiplied by the number of apps app-sweep.py finds blocked by that framework.

| Framework or dylib | Missing API items | Apps blocked | Score |
|---|---:|---:|---:|
| SwiftUI | 3,729 | 25 | 93,225 |
| WebKit | 2,908 | 32 | 93,056 |
| AppKit | 2,151 | 26 | 55,926 |
| AppIntents | 3,048 | 15 | 45,720 |
| Vision | 2,674 | 13 | 34,762 |
| MetalPerformanceShaders | 2,675 | 7 | 18,725 |
| ApplicationServices | 1,203 | 15 | 18,045 |
| Carbon | 1,503 | 12 | 18,036 |
| Foundation | 1,588 | 11 | 17,468 |
| AVFoundation | 508 | 25 | 12,700 |
| QuartzCore | 1,122 | 10 | 11,220 |
| Quartz | 2,192 | 5 | 10,960 |
| MetalPerformanceShaders/MPSNeuralNetwork | 1,541 | 7 | 10,787 |
| CoreML | 900 | 11 | 9,900 |
| RealityKit | 4,501 | 2 | 9,002 |
