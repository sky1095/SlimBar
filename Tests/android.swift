// Android backend: parsing must not fabricate devices, state, or memory.
let adbFixture = """
List of devices attached
emulator-5554\tdevice
emulator-5556\toffline
emulator-5558\tunauthorized
FA6BM0300000\tdevice

"""
let attached = AndroidBackend.parseAdbDevices(adbFixture)
require(attached.count == 3, "only emulator serials are tracked")
require(attached[0].serial == "emulator-5554" && attached[0].state == "device", "ready emulator keeps its state")
require(attached[1].state == "offline", "offline emulator is not reported ready")
require(!attached.contains(where: { $0.serial == "FA6BM0300000" }), "physical devices are not managed")
require(AndroidBackend.parseAdbDevices("List of devices attached\n\n").isEmpty, "empty adb output is no emulator, not a guess")
require(AndroidBackend.parseAvdName("Pixel_9\r\n") == "Pixel_9", "CRLF console output trims to the AVD name")
require(AndroidBackend.parseAvdName("\n") == nil, "empty avd name is not a device")
require(AndroidBackend.parseAvdName("") == nil, "missing avd name is not a device")
require(AndroidBackend.parseAvdName("Pixel_9\r\nOK\r\n") == "Pixel_9", "trailing console OK is not the name")
require(AndroidBackend.parseAvdName("KO: authentication required\r\n") == nil, "console error is not an AVD name")
require(AndroidBackend.parseAvdName("Android Console: type 'help'\r\nOK\r\nPixel_9\r\nOK\r\n") == "Pixel_9", "console banner is skipped")
require(AndroidBackend.parseAvdList("INFO    | Storing crashdata in: /tmp/x.db, detection is enabled for process: 42\nPixel_9\nPixel_9_Pro\n") == ["Pixel_9", "Pixel_9_Pro"], "emulator log lines are not AVDs")
require(AndroidBackend.isEmulatorProcess("/sdk/qemu-system-aarch64 -avd Pixel_9_Pro -port 5556", avdName: "Pixel_9_Pro"), "qemu process matches its own AVD")
require(!AndroidBackend.isEmulatorProcess("/sdk/qemu-system-aarch64 -avd Pixel_9_Pro -port 5556", avdName: "Pixel_9"), "AVD name prefix does not claim a neighbour's process")

// A console reply naming no known AVD must not hide the running one.
let unknownConsoleResponses = ["-list-avds": "Pixel_9\n",
                               "devices": "List of devices attached\nemulator-5554\tdevice\n",
                               "-s emulator-5554 emu avd name": "Stale_Name\r\nOK\r\n",
                               "-s emulator-5554 shell getprop ro.boot.qemu.avd_name": "Pixel_9\n",
                               "-s emulator-5554 shell getprop sys.boot_completed": "1\n"]
let unknownConsoleBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb",
                                           commandRunner: { _, arguments in
                                               guard let reply = unknownConsoleResponses[arguments.joined(separator: " ")] else { throw Failure(message: "unexpected") }
                                               return Data(reply.utf8)
                                           },
                                           spawner: { _, _ in },
                                           processLister: { "" })
require((try? unknownConsoleBackend.devices())?.first?.booted == true, "unknown console name falls back to the guest property and reports Booted")

// Console mapping with a guest-property fallback for unreachable consoles.
let consoleFailingRunner: (String, [String]) throws -> Data = { _, arguments in
    let key = arguments.joined(separator: " ")
    if key.hasSuffix("emu avd name") { throw Failure(message: "console unreachable") }
    if key.hasSuffix("getprop ro.boot.qemu.avd_name") { return Data("Pixel_9\r\n".utf8) }
    throw Failure(message: "Unexpected android command: \(key)")
}
let consoleFailingBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb",
                                           commandRunner: consoleFailingRunner,
                                           spawner: { _, _ in },
                                           processLister: { "" })
require(consoleFailingBackend.avdName(forSerial: "emulator-5554") == "Pixel_9", "guest property backs up an unreachable console")
let consoleEmptyRunner: (String, [String]) throws -> Data = { _, arguments in
    let key = arguments.joined(separator: " ")
    if key.hasSuffix("emu avd name") { return Data("\n".utf8) }
    if key.contains("getprop") { return Data("\n".utf8) }
    throw Failure(message: "Unexpected android command: \(key)")
}
let consoleEmptyBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb",
                                         commandRunner: consoleEmptyRunner,
                                         spawner: { _, _ in },
                                         processLister: { "" })
require(consoleEmptyBackend.avdName(forSerial: "emulator-5554") == nil, "empty console and empty properties are not a name")

let config = AndroidBackend.parseConfigIni("# comment\nabi.type=arm64-v8a\nimage.sysdir.1=system-images;android-34;google_apis;arm64-v8a\nbroken-line\n")
require(config["abi.type"] == "arm64-v8a", "config values are read")
require(AndroidBackend.apiLevel(fromImageSysDir: config["image.sysdir.1"]) == "34", "API level parses from the system image path")
require(AndroidBackend.apiLevel(fromImageSysDir: nil) == nil, "missing image path is unknown, not zero")
require(AndroidBackend.apiLevel(fromImageSysDir: "system-images;android-V;google_apis;arm64-v8a") == "V", "preview codenames pass through")
require(AndroidBackend.apiLevel(fromImageSysDir: "no-api-here") == nil, "unparseable image path is unknown")

require(AndroidLaunchMode.quick.flags.isEmpty, "quick boot adds no flags")
require(AndroidLaunchMode.cold.flags == ["-no-snapshot-load"], "cold boot is exactly -no-snapshot-load")
require(AndroidLaunchMode.wipe.flags == ["-wipe-data"], "wipe boot is exactly -wipe-data")
require(AndroidLaunchMode.wipe.detail.contains("destroyed"), "wipe mode names its destructiveness")
require(AndroidLaunchMode.allCases.count == 3, "all three boot options are exposed")

require(AndroidProfile.stock.arguments == ["off"], "stock restores via avdslim off")
require(AndroidProfile.everyday.arguments == ["on"], "everyday slims via plain avdslim on")
require(AndroidProfile.minimal.arguments == ["on", "--aggressive", "--no-anim"], "minimal slims aggressively without animations")
require(AndroidProfile.stock.detail.contains("avdslim off"), "stock names its backend command")
require(AndroidProfile.allCases.count == 3, "all three android profiles are exposed")

func androidStubRunner(responses: [String: String]) -> (String, [String]) throws -> Data {
    { _, arguments in
        let key = arguments.joined(separator: " ")
        guard let body = responses[key] else { throw Failure(message: "Unexpected android command: \(key)") }
        return Data(body.utf8)
    }
}
// Shared stub fixtures live before their first use: top-level code runs in
// order, and reading a later `let` is a crash, not nil.
let bootedResponses = ["-list-avds": "Pixel_9\n",
                       "devices": "List of devices attached\nemulator-5554\tdevice\n",
                       "-s emulator-5554 emu avd name": "Pixel_9\r\nOK\r\n",
                       "-s emulator-5554 shell getprop sys.boot_completed": "1\n"]

var slimCalls: [[String]] = []
let slimRunner: (String, [String]) throws -> Data = { executable, arguments in
    if executable == "/fake/avdslim" {
        slimCalls.append(arguments)
        if arguments.first == "off" { throw Failure(message: "avdslim off Pixel_9 exited 1\nsimulated failure") }
        return Data()
    }
    let key = arguments.joined(separator: " ")
    guard let body = bootedResponses[key] else { throw Failure(message: "Unexpected android command: \(key)") }
    return Data(body.utf8)
}
let slimBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb", avdslim: "/fake/avdslim",
                                 commandRunner: slimRunner,
                                 spawner: { _, _ in throw Failure(message: "must not relaunch a booted AVD") },
                                 processLister: { psFixture })
try! slimBackend.apply(.minimal, to: "Pixel_9")
require(slimCalls == [["on", "--aggressive", "--no-anim", "Pixel_9"]], "minimal applies exact avdslim flags to the named AVD without relaunching")
do {
    try slimBackend.apply(.stock, to: "Pixel_9")
    require(false, "failed restore propagates")
} catch {
    require(error.localizedDescription.contains("exited 1"), "backend failure output reaches the status row")
}
let noSlimmer = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb", avdslim: nil,
                               commandRunner: androidStubRunner(responses: bootedResponses),
                               spawner: { _, _ in },
                               processLister: { psFixture })
do {
    try noSlimmer.apply(.everyday, to: "Pixel_9")
    require(false, "profiles require avdslim")
} catch {
    require(error.localizedDescription.contains("avdslim is missing"), "missing avdslim names the remedy, not a guess")
}

var bootThenSlimDevicesCalls = 0
var bootSpawns: [[String]] = []
let bootSlimRunner: (String, [String]) throws -> Data = { executable, arguments in
    if executable == "/fake/avdslim" { return Data() }
    let key = arguments.joined(separator: " ")
    if key == "devices" {
        bootThenSlimDevicesCalls += 1
        // Absent for list + launch polls, present once the boot lands it.
        if bootThenSlimDevicesCalls < 3 { return Data("List of devices attached\n\n".utf8) }
        return Data("List of devices attached\nemulator-5554\tdevice\n".utf8)
    }
    guard let body = bootedResponses[key] else { throw Failure(message: "Unexpected android command: \(key)") }
    return Data(body.utf8)
}
let bootSlimBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb", avdslim: "/fake/avdslim",
                                     commandRunner: bootSlimRunner,
                                     spawner: { executable, arguments in bootSpawns.append([executable] + arguments) },
                                     processLister: { psFixture })
try! bootSlimBackend.apply(.everyday, to: "Pixel_9")
require(bootSpawns == [["/fake/emulator", "-avd", "Pixel_9"]], "profile apply boots a stopped AVD with defaults before slimming")

let psFixture = "12345 2000000 /Users/test/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Pixel_9\n"
let direct = AndroidBackend.matchEmulatorMemory(psOutput: psFixture, avdNames: ["Pixel_9"], runningNames: ["Pixel_9"])
require(direct["Pixel_9"]?.bytes == 2000000 * 1024 && direct["Pixel_9"]?.processes == 1, "qemu RSS attributes to the matching AVD")
let ambiguous = AndroidBackend.matchEmulatorMemory(psOutput: "1 1000 /a/qemu-system-aarch64\n2 2000 /b/qemu-system-aarch64\n", avdNames: ["Pixel_9"], runningNames: ["Pixel_9"])
require(ambiguous["Pixel_9"] == nil, "ambiguous emulator processes are unavailable, not guessed")
let fallback = AndroidBackend.matchEmulatorMemory(psOutput: "7 500 /x/qemu-system-x86_64 -verbose\n", avdNames: ["Pixel_9"], runningNames: ["Pixel_9"])
require(fallback["Pixel_9"]?.bytes == 500 * 1024, "one process and one running AVD attributes unambiguously")
let multiAvd = AndroidBackend.matchEmulatorMemory(psOutput: "7 500 /x/qemu-system-x86_64\n", avdNames: ["Pixel_9"], runningNames: ["Pixel_9", "Pixel_8"])
require(multiAvd["Pixel_9"] == nil, "single process with two running AVDs stays unattributed")

let bootedBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb",
                                   commandRunner: androidStubRunner(responses: bootedResponses),
                                   spawner: { _, _ in },
                                   processLister: { psFixture })
let bootedAndroid = try! bootedBackend.devices()
require(bootedAndroid.count == 1 && bootedAndroid[0].booted && bootedAndroid[0].serial == "emulator-5554", "adb-visible, boot-complete AVD is Booted with its serial")
require(bootedAndroid[0].memoryText.contains("GB"), "booted AVD formats host RSS as RAM")
require(bootedAndroid[0].identity == "android:Pixel_9", "AVD identity is stable across serial changes")

var bootingResponses = bootedResponses
bootingResponses["-s emulator-5554 shell getprop sys.boot_completed"] = "\n"
let bootingBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb",
                                    commandRunner: androidStubRunner(responses: bootingResponses),
                                    spawner: { _, _ in },
                                    processLister: { psFixture })
let bootingAndroid = try! bootingBackend.devices()
require(!bootingAndroid[0].booted && bootingAndroid[0].state == "Booting", "adb-visible but not boot-complete is Booting, never Booted")
require(bootingAndroid[0].memoryText.isEmpty, "booting AVD shows no stale RAM")

var stoppedResponses = bootedResponses
stoppedResponses["devices"] = "List of devices attached\n\n"
let stoppedBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb",
                                    commandRunner: androidStubRunner(responses: stoppedResponses),
                                    spawner: { _, _ in },
                                    processLister: { "" })
let stoppedAndroid = try! stoppedBackend.devices()
require(!stoppedAndroid[0].booted && stoppedAndroid[0].state == "Shutdown" && stoppedAndroid[0].serial == nil, "adb-absent AVD is Shutdown without a serial")

var launched: [[String]] = []
let launchingBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb",
                                      commandRunner: androidStubRunner(responses: bootedResponses),
                                      spawner: { executable, arguments in launched.append([executable] + arguments) },
                                      processLister: { psFixture })
try! launchingBackend.launch(avdName: "Pixel_9", mode: .cold)
require(launched == [["/fake/emulator", "-avd", "Pixel_9", "-no-snapshot-load"]], "cold boot launches detached with exactly its flags")

var killCalls = 0
let killingRunner: (String, [String]) throws -> Data = { _, arguments in
    let key = arguments.joined(separator: " ")
    if key.hasSuffix("emu kill") { killCalls += 1; return Data() }
    if key == "devices" { return Data("List of devices attached\n\n".utf8) }
    throw Failure(message: "Unexpected android command: \(key)")
}
let killingBackend = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb",
                                    commandRunner: killingRunner,
                                    spawner: { _, _ in },
                                    processLister: { "" })
try! killingBackend.shutdown(serial: "emulator-5554")
require(killCalls == 1, "shutdown kills the exact serial and verifies it leaves adb")

do {
    _ = try AndroidBackend.configured(environment: ["PATH": "/nonexistent-slimbar-xyz"], searchFixedRoots: false)
    require(false, "missing SDK throws instead of half-configuring")
} catch is AndroidUnavailable {
    require(true, "missing SDK throws AndroidUnavailable")
}

delegate.menuIsOpen = false
delegate.androidAvailable = true
delegate.androidDevices = bootedAndroid
delegate.render()
let androidMenu = delegate.item.menu!
require(androidMenu.items.contains { $0.title == "Android" }, "Android section renders when the SDK is present")
var androidRow = androidMenu.items.first { $0.title == "Pixel_9" }!
require(androidRow.image?.accessibilityDescription == "Running", "booted AVD has a running dot")
require(androidRow.view is DeviceMenuRowView, "AVD name has the direct-click row")
require(androidRow.submenu?.items.contains { $0.title == "Boot Options" } == true, "AVD submenu offers boot options alongside service profiles")
require(androidRow.submenu?.items.contains { $0.title == "Copy AVD Name" } == true, "AVD submenu copies its stable name")
let androidProfileMenu = androidRow.submenu!.items.first { $0.title == "Apply Profile" }!.submenu!
require(androidProfileMenu.items.count == 3, "all three android profiles are exposed on the AVD row")
require(androidProfileMenu.items.allSatisfy { !$0.isEnabled }, "profiles stay disabled without avdslim")
require(delegate.lastAndroidProfileText("Pixel_9") == "Profile: not applied by SlimBar", "fresh AVD claims no profile")
let androidShutdown = androidRow.submenu!.items.first { $0.title == "Shut Down" }!
require(androidShutdown.isEnabled, "shutdown is enabled for a booted AVD")
require(androidRow.isEnabled, "booted AVD row stays enabled so its submenu is usable")
delegate.androidDevices = stoppedAndroid
delegate.render()
androidRow = delegate.item.menu!.items.first { $0.title == "Pixel_9" }!
require(androidRow.image?.accessibilityDescription == "Stopped", "visible AVD dot follows shutdown")
require(!androidRow.submenu!.items.first(where: { $0.title == "Shut Down" })!.isEnabled, "shutdown disables for a stopped AVD")
delegate.menuIsOpen = true
delegate.androidDevices = bootedAndroid
delegate.render()
require(androidRow.title == "Pixel_9", "retained AVD row keeps its name, not the submenu Boot label")
require(androidRow.image?.accessibilityDescription == "Running", "retained AVD dot follows boot")
delegate.menuIsOpen = false
delegate.androidDevices = stoppedAndroid
delegate.render()
require(delegate.lastAndroidProfileText("Pixel_9") == "Profile: not applied by SlimBar", "stopped AVD still claims no profile")
delegate.androidAvailable = false
delegate.androidDevices = []
delegate.render()
require(!delegate.item.menu!.items.contains { $0.title == "Android" }, "Android section hides without an SDK")
require(delegate.statusMessage() == "\(delegate.devices.count) devices · \(delegate.devices.filter(\.booted).count) running", "iOS-only message format is unchanged")
delegate.androidAvailable = true
delegate.androidDevices = bootedAndroid
require(delegate.statusMessage().contains("1 Android"), "combined message counts the Android fleet")
delegate.androidAvailable = false
delegate.androidDevices = []
delegate.render()
print("PASS: all android backend checks completed")

// Menu bar icon follows Android the same way it follows iOS.
delegate.statusKnown = true
delegate.devices = snapshot("Shutdown")
delegate.androidAvailable = true
delegate.androidDevices = bootedAndroid
delegate.render()
require(!delegate.item.button!.image!.isTemplate, "booted AVD turns the menu bar icon full-color")
delegate.statusKnown = false
delegate.render()
require(!delegate.item.button!.image!.isTemplate, "booted AVD keeps the icon green without Xcode status")
delegate.androidAvailable = false
delegate.androidDevices = []
delegate.render()
require(delegate.item.button!.image!.isTemplate, "no running emulator returns the icon to neutral")
print("PASS: android menu bar status checks completed")

// A hung command is killed and reported, not waited on forever.
let hungStart = Date()
let hung = Result { try IOSBackend.runResult("/bin/sleep", ["30"], timeout: 1) }
require(Date().timeIntervalSince(hungStart) < 10, "timed-out command returns promptly")
if case .failure(let error) = hung { require(error.localizedDescription.contains("timed out"), "timeout is reported as a timeout") } else { require(false, "timeout is reported as a timeout") }
require((try? IOSBackend.runResult("/bin/echo", ["ok"], timeout: 5))?.status == 0, "fast command is unaffected by its timeout")

// AVD home: listed from .ini files, config found through path=.
let avdHomeFixture = FileManager.default.temporaryDirectory.appendingPathComponent("slimbar-avd-\(UUID().uuidString)")
let elsewhere = avdHomeFixture.appendingPathComponent("external/Pixel_9.avd")
try! FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
try! "path=\(elsewhere.path)\n".write(to: avdHomeFixture.appendingPathComponent("Pixel_9.ini"), atomically: true, encoding: .utf8)
try! "image.sysdir.1=system-images;android-35;google_apis;arm64-v8a\n".write(to: elsewhere.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
try! "".write(to: avdHomeFixture.appendingPathComponent("not an avd.ini"), atomically: true, encoding: .utf8)
require(AndroidBackend.avdNames(inHome: avdHomeFixture.path) == ["Pixel_9"], "AVDs are listed from the AVD home's .ini files")
require(AndroidBackend.config(for: "Pixel_9", home: avdHomeFixture.path)["image.sysdir.1"]?.contains("android-35") == true, "config follows the .ini path to an AVD stored elsewhere")
let homeListed = AndroidBackend(emulator: "/fake/emulator", adb: "/fake/adb", avdHome: avdHomeFixture.path,
                                commandRunner: { _, arguments in
                                    if arguments == ["-list-avds"] { throw Failure(message: "emulator must not be spawned") }
                                    return Data("List of devices attached\n\n".utf8)
                                },
                                spawner: { _, _ in }, processLister: { "" })
require((try? homeListed.devices())?.first?.apiLevel == "35", "refresh reads the AVD home without spawning the emulator")
require(AndroidBackend.avdHome(environment: ["ANDROID_AVD_HOME": "/x/avd", "ANDROID_USER_HOME": "/y"]) == "/x/avd", "ANDROID_AVD_HOME wins")
require(AndroidBackend.avdHome(environment: ["ANDROID_USER_HOME": "/y"]) == "/y/avd", "ANDROID_USER_HOME/avd is honoured")
try? FileManager.default.removeItem(at: avdHomeFixture)

require(AndroidBackend.isHeadless("/sdk/qemu-system-aarch64 -avd Pixel_9 -qt-hide-window -grpc-use-token"), "Studio-embedded emulator is windowless")
require(!AndroidBackend.isHeadless("/sdk/qemu-system-aarch64 -avd Pixel_9"), "standalone emulator has a window")
print("PASS: android robustness checks completed")
