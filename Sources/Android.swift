import Foundation

// Android support. The iOS backend talks to the bundled simslim binary; the
// Android backend talks to the user's own SDK for listing, booting, and state
// (emulator + adb) and to the bundled avdslim binary for service profiles —
// the simslim-inspired counterpart for AVDs (https://github.com/kdbhalala/avdslim).
// avdslim has no machine-readable output, so device state and memory come from
// adb and the host process table; avdslim is used only for on/off profile
// changes, where its exit code is the signal. Compatibility checks stay
// iOS-only: avdslim doctor is human-readable and not parsed.
struct AndroidUnavailable: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AndroidDevice {
    let avdName: String
    let apiLevel: String?
    let abi: String?
    let state: String
    let serial: String?
    let memory: MemoryReading?
    let memoryError: String?
    var booted: Bool { state == "Booted" }
    // Stable identity for menus and preferences. The adb serial changes
    // across launches; the AVD name does not.
    var identity: String { "android:\(avdName)" }
    var subtitle: String {
        var parts: [String] = []
        if let apiLevel { parts.append("API \(apiLevel)") }
        if let abi { parts.append(abi) }
        return parts.joined(separator: " · ")
    }
}

extension AndroidDevice {
    var memoryText: String {
        guard booted else { return "" }
        guard let memory, memory.bytes >= 0, memoryError == nil else { return "RAM unavailable" }
        return ByteCountFormatter.string(fromByteCount: memory.bytes, countStyle: .memory)
    }
    var memoryDetail: String {
        guard booted else { return "RAM: boot device to measure" }
        guard let memory, memoryError == nil else { return "RAM unavailable" }
        return "RAM: \(memoryText) · \(memory.processes) processes"
    }
}

enum AndroidLaunchMode: String, CaseIterable {
    case quick, cold, wipe
    var title: String {
        switch self {
        case .quick: return "Quick Boot"
        case .cold: return "Cold Boot"
        case .wipe: return "Wipe Data & Boot"
        }
    }
    var detail: String {
        switch self {
        case .quick: return "Normal launch. Loads the saved Quick Boot snapshot when one exists."
        case .cold: return "Full guest boot without loading the snapshot (emulator -no-snapshot-load). Slower to boot; useful when snapshot state is stale. Nothing is deleted."
        case .wipe: return "Deletes user data and boots factory-fresh (emulator -wipe-data). Installed apps, accounts, and settings on this AVD are destroyed."
        }
    }
    var flags: [String] {
        switch self {
        case .quick: return []
        case .cold: return ["-no-snapshot-load"]
        case .wipe: return ["-wipe-data"]
        }
    }
}

struct AndroidLaunchChoice {
    let avdName: String
    let mode: AndroidLaunchMode
}

// Service profiles via avdslim, mirroring SlimProfile on iOS: Stock restores
// everything avdslim manages, the other two slim with increasing appetite.
// Flags are avdslim's documented presets, not invented savings claims.
enum AndroidProfile: String, CaseIterable {
    case stock, everyday, minimal
    var title: String {
        switch self {
        case .stock: return "Stock"
        case .everyday: return "Everyday Development"
        case .minimal: return "Minimal Testing"
        }
    }
    var detail: String {
        switch self {
        case .stock: return "Re-enables every package avdslim disabled and restores each changed setting to its previous value (avdslim off)."
        case .everyday: return "Standard slim (avdslim on): silences non-essential background daemons, caps background churn, and trims caches. FCM push, Auth, WebView, and localhost networking stay active."
        case .minimal: return "Aggressive slim without animations (avdslim on --aggressive --no-anim): additionally disables the Play Store self-updater and sets all animation scales to zero. Use for basic UI tests."
        }
    }
    var arguments: [String] {
        switch self {
        case .stock: return ["off"]
        case .everyday: return ["on"]
        case .minimal: return ["on", "--aggressive", "--no-anim"]
        }
    }
}

struct AndroidProfileChoice {
    let avdName: String
    let profile: AndroidProfile
}

struct AndroidBackend {
    let emulator: String
    let adb: String
    // Optional: listing, booting, and shutdown use the SDK directly, so they
    // work without it. Only Apply Profile needs avdslim.
    let avdslim: String?
    // Where AVD definitions live. When set, AVDs are listed from its .ini
    // files instead of spawning `emulator -list-avds` on every refresh.
    let avdHome: String?
    let commandRunner: (String, [String]) throws -> Data
    let spawner: (String, [String]) throws -> Void
    let processLister: () throws -> String

    init(emulator: String, adb: String, avdslim: String? = nil, avdHome: String? = nil,
         commandRunner: @escaping (String, [String]) throws -> Data = AndroidBackend.run,
         spawner: @escaping (String, [String]) throws -> Void = AndroidBackend.spawn,
         processLister: @escaping () throws -> String = AndroidBackend.hostProcesses) {
        self.emulator = emulator
        self.adb = adb
        self.avdslim = avdslim
        self.avdHome = avdHome
        self.commandRunner = commandRunner
        self.spawner = spawner
        self.processLister = processLister
    }

    // SDK roots in preference order. ANDROID_HOME and ANDROID_SDK_ROOT are
    // the documented environment variables; the rest are conventional
    // install locations. PATH entries are searched last.
    static func searchRoots(environment: [String: String]) -> [String] {
        var roots = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }
        roots += [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path,
                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Android/Sdk").path,
                  "/opt/android-sdk", "/usr/local/share/android-sdk"]
        return roots
    }

    static func locate(tool: String, relativePath: String, environment: [String: String], searchFixedRoots: Bool = true) -> String? {
        let roots = (searchFixedRoots ? searchRoots(environment: environment) : []) +
            (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for root in roots {
            let direct = (root as NSString).appendingPathComponent(relativePath)
            if FileManager.default.isExecutableFile(atPath: direct) { return direct }
            let onPath = (root as NSString).appendingPathComponent(tool)
            if onPath != direct, FileManager.default.isExecutableFile(atPath: onPath) { return onPath }
        }
        return nil
    }

    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment,
                           commandRunner: @escaping (String, [String]) throws -> Data = AndroidBackend.run,
                           spawner: @escaping (String, [String]) throws -> Void = AndroidBackend.spawn,
                           processLister: @escaping () throws -> String = AndroidBackend.hostProcesses,
                           searchFixedRoots: Bool = true) throws -> AndroidBackend {
        guard let emulator = locate(tool: "emulator", relativePath: "emulator/emulator", environment: environment, searchFixedRoots: searchFixedRoots) else {
            throw AndroidUnavailable(message: "Android SDK not found. Install Android Studio or the command-line tools so emulator is available.")
        }
        guard let adb = locate(tool: "adb", relativePath: "platform-tools/adb", environment: environment, searchFixedRoots: searchFixedRoots) else {
            throw AndroidUnavailable(message: "adb not found. Install the Android platform-tools package.")
        }
        // Profiles degrade gracefully without avdslim: AVDSLIM_CLI override,
        // then the bundled backend, then conventional Homebrew paths.
        let avdslimCandidates = [environment["AVDSLIM_CLI"],
                                 Bundle.main.path(forResource: "avdslim", ofType: nil),
                                 "/opt/homebrew/bin/avdslim", "/usr/local/bin/avdslim"].compactMap { $0 }
        let avdslim = avdslimCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        return AndroidBackend(emulator: emulator, adb: adb, avdslim: avdslim, avdHome: avdHome(environment: environment),
                              commandRunner: commandRunner, spawner: spawner, processLister: processLister)
    }

    // The emulator's own lookup order: ANDROID_AVD_HOME, then
    // ANDROID_USER_HOME/avd, then the legacy ANDROID_SDK_HOME/.android/avd,
    // then ~/.android/avd.
    static func avdHome(environment: [String: String]) -> String {
        if let home = environment["ANDROID_AVD_HOME"], !home.isEmpty { return home }
        if let home = environment["ANDROID_USER_HOME"], !home.isEmpty { return (home as NSString).appendingPathComponent("avd") }
        if let home = environment["ANDROID_SDK_HOME"], !home.isEmpty { return (home as NSString).appendingPathComponent(".android/avd") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd").path
    }

    // Reuse the stderr-separated runner: adb/emulator diagnostics must not
    // corrupt parsed stdout either.
    // Profiles can take minutes; every other adb/emulator query answers in
    // seconds or is stuck.
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let timeout: TimeInterval = URL(fileURLWithPath: executable).lastPathComponent == "avdslim" ? 600 : 20
        let result = try IOSBackend.runResult(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            throw Failure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " ")) exited \(result.status)\n\(result.errorText)\n\(String(decoding: result.data, as: UTF8.self))")
        }
        return result.data
    }

    // The emulator outlives its launcher: start it detached and never wait.
    static func spawn(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func hostProcesses() throws -> String {
        let result = try IOSBackend.runResult("/bin/ps", ["-ax", "-o", "pid=,rss=,command="], timeout: 10)
        guard result.status == 0 else { throw Failure(message: "ps exited \(result.status)\n\(result.errorText)") }
        return String(decoding: result.data, as: UTF8.self)
    }

    // AVD names are limited to letters, digits, '.', '_' and '-'. Anything
    // else in tool output is a banner, log line, or console reply.
    static func isAvdName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0)
        }
    }

    // Recent emulator builds print "INFO | Storing crashdata…" on stdout
    // alongside the list; only lines that are valid AVD names count.
    static func parseAvdList(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter(isAvdName)
    }

    // Each AVD is registered by <name>.ini in the AVD home; this is what
    // `emulator -list-avds` reads, without a process spawn per refresh.
    static func avdNames(inHome home: String) -> [String]? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: home) else { return nil }
        return files.filter { $0.hasSuffix(".ini") }.map { String($0.dropLast(4)) }.filter(isAvdName).sorted()
    }

    func listAVDs() throws -> [String] {
        if let avdHome, let names = Self.avdNames(inHome: avdHome), !names.isEmpty { return names }
        return Self.parseAvdList(String(decoding: try commandRunner(emulator, ["-list-avds"]), as: UTF8.self))
    }

    // Parses `adb devices`. Only emulator serials are managed; physical
    // devices and unparseable lines are ignored, never fabricated.
    static func parseAdbDevices(_ output: String) -> [(serial: String, state: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, fields[0].hasPrefix("emulator-") else { return nil }
            return (fields[0], fields[1])
        }
    }

    func attachedEmulators() throws -> [(serial: String, state: String)] {
        Self.parseAdbDevices(String(decoding: try commandRunner(adb, ["devices"]), as: UTF8.self))
    }

    // `adb -s <serial> emu avd name` prints the AVD name followed by "OK".
    // Console output uses CRLF and can carry an auth banner or a "KO:"
    // error instead; only a line that is a valid AVD name counts.
    static func parseAvdName(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { isAvdName($0) && $0 != "OK" }
    }

    // `known` restricts the answer to AVDs this machine has: a console reply
    // that names nothing known falls through to the guest properties
    // instead of hiding the running AVD behind a bogus name.
    func avdName(forSerial serial: String, known: Set<String>? = nil) -> String? {
        func accept(_ name: String?) -> String? {
            guard let name, known?.contains(name) ?? true else { return nil }
            return name
        }
        if let data = try? commandRunner(adb, ["-s", serial, "emu", "avd", "name"]),
           let name = accept(Self.parseAvdName(String(decoding: data, as: UTF8.self))) {
            return name
        }
        // Console unreachable (auth, early boot, older emulator): the guest
        // itself knows its AVD name and needs only adb shell. First
        // matching property wins; anything else is not a name.
        for prop in ["ro.boot.qemu.avd_name", "persist.sys.avd_name"] {
            if let data = try? commandRunner(adb, ["-s", serial, "shell", "getprop", prop]) {
                let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, let name = accept(value) { return name }
            }
        }
        return nil
    }

    // adb answering at all is not booted; only sys.boot_completed == 1 is.
    func bootCompleted(serial: String) -> Bool {
        guard let data = try? commandRunner(adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"]) else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // Minimal config.ini reader: comments skipped, first '=' wins.
    static func parseConfigIni(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    // image.sysdir.1 looks like "system-images;android-34;google_apis;arm64-v8a".
    static func apiLevel(fromImageSysDir value: String?) -> String? {
        guard let value else { return nil }
        for part in value.split(separator: ";") where part.hasPrefix("android-") {
            let level = part.dropFirst("android-".count)
            if !level.isEmpty { return String(level) }
        }
        return nil
    }

    // <name>.ini's path= points at the AVD's content directory, which may
    // live outside the AVD home; <name>.avd beside it is the default.
    static func config(for avdName: String, home: String) -> [String: String] {
        let pointer = parseConfigIni((try? String(contentsOfFile: (home as NSString).appendingPathComponent("\(avdName).ini"), encoding: .utf8)) ?? "")
        let directories = [pointer["path"], (home as NSString).appendingPathComponent("\(avdName).avd")].compactMap { $0 }
        for directory in directories {
            if let text = try? String(contentsOfFile: (directory as NSString).appendingPathComponent("config.ini"), encoding: .utf8) {
                return parseConfigIni(text)
            }
        }
        return [:]
    }

    struct PsEntry {
        let pid: Int32
        let rssKB: Int64
        let command: String
    }

    static func parsePs(_ output: String) -> [PsEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> PsEntry? in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let rss = Int64(parts[1]) else { return nil }
            return PsEntry(pid: pid, rssKB: rss, command: String(parts[2]))
        }
    }

    // The emulator runs qemu-system-* with "-avd <name>" (or "@<name>").
    // Match the whole token: a substring match would hand Pixel_9_Pro's
    // process to Pixel_9.
    static func isEmulatorProcess(_ command: String, avdName: String) -> Bool {
        guard command.contains("qemu-system-") else { return false }
        let tokens = command.split(separator: " ").map(String.init)
        if tokens.contains("@" + avdName) { return true }
        return zip(tokens, tokens.dropFirst()).contains { $0 == "-avd" && $1 == avdName }
    }

    // Android Studio runs the emulator inside its Running Devices panel with
    // -qt-hide-window; -no-window is fully headless. Neither has a window.
    static func isHeadless(_ command: String) -> Bool {
        let tokens = command.split(separator: " ")
        return tokens.contains("-qt-hide-window") || tokens.contains("-no-window")
    }

    // Attribute host memory to AVDs by qemu command line. The emulator
    // launches qemu-system-* with the AVD name on its command line; when
    // that match is absent, attribute only in the unambiguous case of one
    // emulator process and one running AVD. Anything else is unavailable,
    // never zero or a guess.
    static func matchEmulatorMemory(psOutput: String, avdNames: [String], runningNames: [String]) -> [String: MemoryReading] {
        let qemu = parsePs(psOutput).filter { $0.command.contains("qemu-system-") }
        var result: [String: MemoryReading] = [:]
        for name in avdNames {
            let direct = qemu.filter { isEmulatorProcess($0.command, avdName: name) }
            if !direct.isEmpty {
                result[name] = MemoryReading(bytes: direct.reduce(0) { $0 + $1.rssKB } * 1024, processes: direct.count)
            }
        }
        if qemu.count == 1, runningNames.count == 1, result[runningNames[0]] == nil {
            result[runningNames[0]] = MemoryReading(bytes: qemu[0].rssKB * 1024, processes: 1)
        }
        return result
    }

    func devices() throws -> [AndroidDevice] {
        let names = try listAVDs()
        let attached = (try? attachedEmulators()) ?? []
        var serialByAvd: [String: String] = [:]
        let known = Set(names)
        for entry in attached {
            if let avd = avdName(forSerial: entry.serial, known: known) { serialByAvd[avd] = entry.serial }
        }
        let runningNames = serialByAvd.keys.sorted()
        let memoryByAvd = (try? Self.matchEmulatorMemory(psOutput: processLister(), avdNames: names, runningNames: runningNames)) ?? [:]
        return names.map { name in
            let config = Self.config(for: name, home: avdHome ?? Self.avdHome(environment: ProcessInfo.processInfo.environment))
            let serial = serialByAvd[name]
            let ready = serial.map { bootCompleted(serial: $0) } ?? false
            let state: String
            if ready {
                state = "Booted"
            } else if serial != nil {
                // Visible to adb but not boot-complete: still launching,
                // offline, or unauthorized. Never reported as booted.
                state = "Booting"
            } else {
                state = "Shutdown"
            }
            let bootedMemory = state == "Booted" ? memoryByAvd[name] : nil
            return AndroidDevice(avdName: name,
                                 apiLevel: Self.apiLevel(fromImageSysDir: config["image.sysdir.1"]),
                                 abi: config["abi.type"],
                                 state: state,
                                 serial: serial,
                                 memory: bootedMemory,
                                 memoryError: state == "Booted" && bootedMemory == nil ? "No unambiguous emulator process match" : nil)
        }
    }

    func serial(forAvd name: String) throws -> String? {
        for entry in try attachedEmulators() {
            if avdName(forSerial: entry.serial, known: [name]) == name { return entry.serial }
        }
        return nil
    }

    // Launch is verified by the AVD registering with adb, not by the
    // launcher's exit code: the launcher always exits immediately.
    func launch(avdName: String, mode: AndroidLaunchMode) throws {
        try spawner(emulator, ["-avd", avdName] + mode.flags)
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            if (try? serial(forAvd: avdName)) != nil { return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw Failure(message: "\(avdName) did not appear in adb devices within 30s. Check the emulator window or run: \(emulator) -avd \(avdName)")
    }

    // `emu kill` drops the console connection, so adb may report an error
    // on success. The post-condition — the serial leaving adb devices — is
    // what counts.
    func shutdown(serial: String) throws {
        _ = try? commandRunner(adb, ["-s", serial, "emu", "kill"])
        let deadline = Date(timeIntervalSinceNow: 15)
        while Date() < deadline {
            let attached = (try? attachedEmulators()) ?? []
            if !attached.contains(where: { $0.serial == serial }) { return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw Failure(message: "\(serial) is still listed by adb devices after kill.")
    }

    // adb answering is not booted; sys.boot_completed == 1 is. Slimming a
    // half-booted guest fails or half-applies, so profiles wait for it.
    func waitForBoot(serial: String, timeout: TimeInterval = 120) throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if bootCompleted(serial: serial) { return }
            Thread.sleep(forTimeInterval: 2)
        }
        throw Failure(message: "\(serial) did not finish booting within \(Int(timeout))s. Try again once the emulator is up.")
    }

    // Apply a service profile, booting the AVD first when needed — the iOS
    // flow boots before slimming too. Verification is coarser than iOS:
    // avdslim has no machine-readable verify, so success is exit 0 plus the
    // device still booted with a readable footprint afterward.
    func apply(_ profile: AndroidProfile, to avdName: String) throws {
        guard let avdslim else {
            throw Failure(message: "avdslim is missing. Reinstall SlimBar or set AVDSLIM_CLI to its executable.")
        }
        var runningSerial = try serial(forAvd: avdName)
        if runningSerial == nil {
            try launch(avdName: avdName, mode: .quick)
            runningSerial = try serial(forAvd: avdName)
        }
        guard let runningSerial else { throw Failure(message: "\(avdName) did not appear in adb devices.") }
        try waitForBoot(serial: runningSerial)
        // avdslim addresses the running emulator by index, serial, or AVD
        // name; the name is passed explicitly so a neighbour is never hit.
        // commandRunner enforces a zero exit (AndroidBackend.run) and carries
        // the full backend output on failure.
        _ = try commandRunner(avdslim, profile.arguments + [avdName])
        guard bootCompleted(serial: runningSerial) else { throw Failure(message: "Profile applied but \(avdName) is no longer boot-complete. Check the emulator window.") }
        guard try devices().first(where: { $0.avdName == avdName })?.booted == true else {
            throw Failure(message: "Profile applied but \(avdName) state could not be confirmed afterward.")
        }
    }
}
