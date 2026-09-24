import AppKit

struct Device: Decodable {
    let udid: String
    let name: String
    let state: String
    let osVersion: String
    let set: String
    let managedDisabled: Int?
    let statusError: String?
    let memory: MemoryReading?
    let memoryError: String?
    var booted: Bool { state == "Booted" }
}

struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// The only platform-specific backend. Android can later use a separate adapter.
struct IOSBackend {
    let executable: String
    let commandRunner: (String, [String]) throws -> Data
    init(commandRunner: @escaping (String, [String]) throws -> Data = IOSBackend.run) throws {
        self.commandRunner = commandRunner
        let candidates = [ProcessInfo.processInfo.environment["SIMSLIM_CLI"],
                          Bundle.main.path(forResource: "simslim", ofType: nil),
                          "/opt/homebrew/bin/simslim", "/usr/local/bin/simslim"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure(message: "simslim is missing. Install with: brew install mobai-app/tap/simslim")
        }
        executable = path
    }
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let result = try runResult(executable, arguments)
        guard result.status == 0 else {
            throw Failure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " ")) exited \(result.status)\n\(result.errorText)\n\(String(decoding: result.data, as: UTF8.self))")
        }
        return result.data
    }
    func execute(_ args: [String]) throws -> Data { try commandRunner(executable, args) }
    func devices() throws -> [Device] {
        let data = try execute(["list", "--json"])
        // Do not expose Xcode parallel-test clones in the interactive launcher.
        return try JSONDecoder().decode([Device].self, from: data).filter { $0.set == "default" }
    }
    func boot(_ device: Device) throws {
        _ = try execute(["boot", "--json", device.udid])
    }
    func bootAndOpen(_ device: Device) throws {
        try boot(device)
        try openSimulator(device)
    }
    func openSimulator(_ device: Device) throws {
        let directory = try commandRunner("/usr/bin/xcode-select", ["-p"])
        let developer = String(decoding: directory, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = developer + "/Applications/Simulator.app"
        if FileManager.default.fileExists(atPath: legacy) {
            _ = try commandRunner("/usr/bin/open", ["-a", legacy, "--args", "-CurrentDeviceUDID", device.udid])
            return
        }
        let url = "devices://device/open?id=\(device.udid)"
        let deviceHub = URL(fileURLWithPath: developer).deletingLastPathComponent().appendingPathComponent("Applications/DeviceHub.app").path
        if FileManager.default.fileExists(atPath: deviceHub) {
            _ = try commandRunner("/usr/bin/open", ["-a", deviceHub, url])
        } else {
            _ = try commandRunner("/usr/bin/open", [url])
        }
    }
}

// Native submenus own click handling. A custom row supplies a public view
// rectangle so the local click monitor can distinguish name clicks from
// clicks in the adjacent submenu, while AppKit still handles hover tracking.
final class DeviceMenuRowView: NSView {
    init() { super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 26)) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard let row = enclosingMenuItem else { return }
        draw(row: row)
    }
    func draw(row: NSMenuItem) {
        let highlighted = row.isHighlighted
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        row.image?.draw(in: NSRect(x: 13, y: 7, width: 12, height: 12))
        let color: NSColor = !row.isEnabled ? .disabledControlTextColor : highlighted ? .selectedMenuItemTextColor : .labelColor
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textHeight = ceil(("Ag" as NSString).size(withAttributes: attributes).height)
        let textY = floor((bounds.height - textHeight) / 2)
        (row.title as NSString).draw(in: NSRect(x: 33, y: textY, width: bounds.width - 175, height: textHeight), withAttributes: attributes)
        if let device = row.representedObject as? Device {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            (device.memoryText as NSString).draw(in: NSRect(x: bounds.width - 142, y: textY, width: 112, height: textHeight), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        } else if let android = row.representedObject as? AndroidDevice {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            (android.memoryText as NSString).draw(in: NSRect(x: bounds.width - 142, y: textY, width: 112, height: textHeight), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        ("›" as NSString).draw(in: NSRect(x: bounds.width - 20, y: textY, width: 12, height: textHeight), withAttributes: attributes)
    }
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        return window.convertToScreen(convert(bounds, to: nil)).contains(point)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var devices: [Device] = []
    var androidDevices: [AndroidDevice] = []
    var androidAvailable = false
    var androidHasSlimmer = false
    var androidError: String?
    var busy = false
    var statusKnown = true
    var progressIndicator: NSProgressIndicator?
    var refreshing = false
    var menuIsOpen = false
    var refreshTimer: Timer?
    var clickMonitor: Any?
    var message = "Loading simulators…"
    var lastError: String?
    var updates: UpdateController?
    var compatibilityResults: [String: CheckedCompatibility] = [:]
    var lastProfiles: [String: String] = UserDefaults.standard.dictionary(forKey: "lastAppliedProfiles") as? [String: String] ?? [:]
    let queue = DispatchQueue(label: "SlimBar.backend", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "SlimBar")
        item.button?.toolTip = "SlimBar — iOS and Android simulators"
        updates = UpdateController.configured()
        render()
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self, let root = self.item.menu,
                      let row = self.deviceRow(at: NSEvent.mouseLocation, in: root), row.isEnabled else { return event }
                // Close tracking before starting the normal boot/open action.
                root.cancelTracking()
                self.launchDevice(row)
                self.launchAndroidDevice(row)
                return nil
            }
        }
        refresh()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        // Reorder/add/remove rows only after tracking ends.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self, !self.menuIsOpen else { return }
            self.render()
        }
    }
    func deviceRow(at point: NSPoint, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { ($0.view as? DeviceMenuRowView)?.containsScreenPoint(point) == true }
    }
    func menu(_ menu: NSMenu, willHighlight highlightedItem: NSMenuItem?) {
        for row in menu.items { row.view?.needsDisplay = true }
    }
    @discardableResult
    func add(_ title: String, to menu: NSMenu, action: Selector? = nil, payload: Any? = nil, enabled: Bool = true) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        row.representedObject = payload
        row.isEnabled = enabled && action != nil
        menu.addItem(row)
        return row
    }
    func statusDot(booted: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { _ in
            (booted ? NSColor.systemGreen : NSColor.secondaryLabelColor).setFill()
            let circle = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 8, height: 8))
            circle.fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = booted ? "Running" : "Stopped"
        return image
    }
    // Mutate existing rows during tracking: replacing the status item's menu
    // leaves the old, still-visible menu showing a stale green dot.
    func updateVisibleRows(_ menu: NSMenu) {
        for row in menu.items {
            if row.tag == 101 { row.title = message; row.toolTip = lastError }
            if let choice = row.representedObject as? ProfileChoice {
                row.isEnabled = !busy && devices.first(where: { $0.udid == choice.udid }).map { choice.profile.supports($0.osVersion) } == true
            }
            if let choice = row.representedObject as? AndroidLaunchChoice {
                row.isEnabled = !busy && androidDevices.contains(where: { $0.avdName == choice.avdName && !$0.booted })
            }
            if let choice = row.representedObject as? AndroidProfileChoice {
                row.isEnabled = !busy && androidHasSlimmer && androidDevices.contains(where: { $0.avdName == choice.avdName })
                if !androidHasSlimmer { row.toolTip = "avdslim is missing. Reinstall SlimBar or set AVDSLIM_CLI." }
            }
            if let previous = row.representedObject as? Device {
                guard let current = devices.first(where: { $0.udid == previous.udid }) else {
                    row.isEnabled = false
                    row.image = statusDot(booted: false)
                    row.toolTip = "Device unavailable"
                    continue
                }
                row.representedObject = current
                if row.view is DeviceMenuRowView {
                    row.image = statusDot(booted: current.booted)
                    row.toolTip = current.state
                }
                if row.tag == 103 { row.title = current.memoryDetail; row.toolTip = current.memoryError }
                if row.tag == 104 { row.title = lastProfileText(current.udid) }
                if row.tag == 105 { row.title = compatibilityTimestamp(current) }
                if (200...202).contains(row.tag) { row.title = compatibilityText(current, index: row.tag - 200) }
                if row.tag == 102 {
                    row.title = current.state + (current.managedDisabled.map { " · \($0) services disabled" } ?? "")
                }
                if row.action == #selector(launchDevice(_:)) {
                    if row.toolTip == nil { row.title = current.booted ? "Open Simulator" : "Boot & Open" }
                    row.isEnabled = !busy
                } else if row.action == #selector(shutdownDevice(_:)) {
                    row.isEnabled = !busy && current.booted
                } else if row.action == #selector(checkCompatibility(_:)) {
                    row.isEnabled = !busy && current.booted
                }
            }
            if let previous = row.representedObject as? AndroidDevice {
                guard let current = androidDevices.first(where: { $0.avdName == previous.avdName }) else {
                    row.isEnabled = false
                    row.image = statusDot(booted: false)
                    row.toolTip = "Device unavailable"
                    continue
                }
                row.representedObject = current
                if row.view is DeviceMenuRowView {
                    row.image = statusDot(booted: current.booted)
                    row.toolTip = current.state + (current.serial.map { " · \($0)" } ?? "")
                }
                if row.tag == 302 {
                    row.title = current.state + (current.serial.map { " · \($0)" } ?? "") + (current.subtitle.isEmpty ? "" : " · \(current.subtitle)")
                }
                if row.tag == 303 { row.title = current.memoryDetail; row.toolTip = current.memoryError }
                if row.tag == 304 { row.title = lastAndroidProfileText(current.avdName) }
                if row.action == #selector(launchAndroidDevice(_:)) {
                    if row.view is DeviceMenuRowView {
                        row.isEnabled = !busy
                    } else {
                        row.title = current.booted ? "Open" : "Boot"
                        row.isEnabled = !busy
                    }
                } else if row.action == #selector(shutdownAndroidDevice(_:)) {
                    row.isEnabled = !busy && current.booted
                } else if row.action == #selector(copyAndroidSerial(_:)) {
                    row.isEnabled = current.serial != nil
                } else if row.action == #selector(copyAdbCommand(_:)) {
                    row.isEnabled = current.serial != nil
                } else if row.action == #selector(screenshotAndroidDevice(_:)) {
                    row.isEnabled = !busy && current.booted
                }
            }
            if row.action == #selector(refresh) || row.action == #selector(quit) { row.isEnabled = !busy }
            if row.tag == 107 { row.isEnabled = updates?.canCheck == true }
            row.view?.needsDisplay = true
            if let submenu = row.submenu { updateVisibleRows(submenu) }
        }
    }
    func render() {
        updateMenuBarStatus()
        if menuIsOpen, let menu = item.menu {
            updateVisibleRows(menu)
            return
        }
        let menu = item.menu ?? NSMenu()
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.delegate = self
        add("SlimBar · Simulators", to: menu)
        let status = add(message, to: menu)
        status.tag = 101
        status.toolTip = lastError
        menu.addItem(.separator())
        let groups = Dictionary(grouping: devices, by: \.osVersion)
        for version in groups.keys.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
            add("iOS \(version)", to: menu)
            for device in groups[version]!.sorted(by: { ($0.booted ? 0 : 1, $0.name) < ($1.booted ? 0 : 1, $1.name) }) {
                let launchRow = add(device.name, to: menu, action: #selector(launchDevice(_:)), payload: device, enabled: !busy)
                launchRow.image = statusDot(booted: device.booted)
                launchRow.toolTip = device.state
                launchRow.view = DeviceMenuRowView()
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                let slim = device.managedDisabled.map { " · \($0) services disabled" } ?? ""
                add(device.state + slim, to: submenu, payload: device).tag = 102
                add(device.memoryDetail, to: submenu, payload: device).tag = 103
                if let error = device.statusError { add("Status unavailable: \(error)", to: submenu) }
                add(device.booted ? "Open Simulator" : "Boot & Open", to: submenu, action: #selector(launchDevice(_:)), payload: device, enabled: !busy)
                add("Shut Down", to: submenu, action: #selector(shutdownDevice(_:)), payload: device, enabled: !busy && device.booted)
                submenu.addItem(.separator())
                add(lastProfileText(device.udid), to: submenu, payload: device).tag = 104
                let profiles = NSMenu()
                profiles.autoenablesItems = false
                for profile in SlimProfile.allCases {
                    add(profile.title + "…", to: profiles, action: #selector(applyProfile(_:)), payload: ProfileChoice(udid: device.udid, profile: profile), enabled: !busy && profile.supports(device.osVersion))
                }
                let profileRow = NSMenuItem(title: "Apply Profile", action: nil, keyEquivalent: "")
                profileRow.submenu = profiles
                submenu.addItem(profileRow)
                submenu.addItem(.separator())
                add(compatibilityTimestamp(device), to: submenu, payload: device).tag = 105
                for index in CompatibilityReport.required.indices {
                    add(compatibilityText(device, index: index), to: submenu, payload: device).tag = 200 + index
                }
                add("Check Compatibility Now", to: submenu, action: #selector(checkCompatibility(_:)), payload: device, enabled: !busy && device.booted)
                submenu.addItem(.separator())
                add("Copy UDID", to: submenu, action: #selector(copyUDID(_:)), payload: device)
                launchRow.submenu = submenu
            }
        }
        if devices.isEmpty && !busy { add("No devices found. Add an iOS runtime in Xcode.", to: menu) }
        if androidAvailable || !androidDevices.isEmpty {
            menu.addItem(.separator())
            let androidHeader = add("Android", to: menu)
            androidHeader.toolTip = androidError
            if let androidError, androidDevices.isEmpty {
                let failure = add(errorSummary(androidError), to: menu)
                failure.toolTip = androidError
            }
            let androidGroups = Dictionary(grouping: androidDevices, by: { $0.apiLevel.map { "Android API \($0)" } ?? "Android (API unknown)" })
            for version in androidGroups.keys.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                add(version, to: menu)
                for device in androidGroups[version]!.sorted(by: { ($0.booted ? 0 : 1, $0.avdName) < ($1.booted ? 0 : 1, $1.avdName) }) {
                    // The launch row stays enabled even when booted: AppKit
                    // disables a submenu whose parent is disabled at attach
                    // time, which would grey out Shut Down and Copy on a
                    // running AVD. Clicking a booted row brings its emulator
                    // window to front; clicking a stopped row boots it.
                    let launchRow = add(device.avdName, to: menu, action: #selector(launchAndroidDevice(_:)), payload: device, enabled: !busy)
                    launchRow.image = statusDot(booted: device.booted)
                    launchRow.toolTip = device.state + (device.serial.map { " · \($0)" } ?? "")
                    launchRow.view = DeviceMenuRowView()
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    let detail = device.state + (device.serial.map { " · \($0)" } ?? "") + (device.subtitle.isEmpty ? "" : " · \(device.subtitle)")
                    add(detail, to: submenu, payload: device).tag = 302
                    add(device.memoryDetail, to: submenu, payload: device).tag = 303
                    if let error = device.memoryError { add("RAM unavailable: \(error)", to: submenu) }
                    add(device.booted ? "Open" : "Boot", to: submenu, action: #selector(launchAndroidDevice(_:)), payload: device, enabled: !busy)
                    add("Shut Down", to: submenu, action: #selector(shutdownAndroidDevice(_:)), payload: device, enabled: !busy && device.booted)
                    submenu.addItem(.separator())
                    add(lastAndroidProfileText(device.avdName), to: submenu, payload: device).tag = 304
                    let androidProfiles = NSMenu()
                    androidProfiles.autoenablesItems = false
                    for profile in AndroidProfile.allCases {
                        let row = add(profile.title + "…", to: androidProfiles, action: #selector(applyAndroidProfile(_:)), payload: AndroidProfileChoice(avdName: device.avdName, profile: profile), enabled: !busy && androidHasSlimmer)
                        if !androidHasSlimmer { row.toolTip = "avdslim is missing. Reinstall SlimBar or set AVDSLIM_CLI." }
                    }
                    let androidProfileRow = NSMenuItem(title: "Apply Profile", action: nil, keyEquivalent: "")
                    androidProfileRow.submenu = androidProfiles
                    submenu.addItem(androidProfileRow)
                    submenu.addItem(.separator())
                    let launches = NSMenu()
                    launches.autoenablesItems = false
                    for mode in AndroidLaunchMode.allCases {
                        let row = add(mode.title + "…", to: launches, action: #selector(launchAndroidWithMode(_:)), payload: AndroidLaunchChoice(avdName: device.avdName, mode: mode), enabled: !busy && !device.booted)
                        row.toolTip = mode.detail
                    }
                    let launchOptions = NSMenuItem(title: "Boot Options", action: nil, keyEquivalent: "")
                    launchOptions.submenu = launches
                    submenu.addItem(launchOptions)
                    submenu.addItem(.separator())
                    add("Screenshot", to: submenu, action: #selector(screenshotAndroidDevice(_:)), payload: device, enabled: !busy && device.booted)
                    submenu.addItem(.separator())
                    add("Copy AVD Name", to: submenu, action: #selector(copyAVDName(_:)), payload: device)
                    add("Copy Serial", to: submenu, action: #selector(copyAndroidSerial(_:)), payload: device, enabled: device.serial != nil)
                    add("Copy ADB Command", to: submenu, action: #selector(copyAdbCommand(_:)), payload: device, enabled: device.serial != nil)
                    launchRow.submenu = submenu
                }
            }
            if androidDevices.isEmpty && !busy && androidError == nil {
                add("No Android AVDs. Create one in Android Studio's Device Manager.", to: menu)
            }
        }
        menu.addItem(.separator())
        add("Refresh", to: menu, action: #selector(refresh), enabled: !busy)
        let update = add("Check for Updates…", to: menu, action: #selector(checkForUpdates), enabled: updates?.canCheck == true)
        update.tag = 107
        update.toolTip = updates == nil ? "This build was made without an update signing key." : nil
        add("Quit SlimBar", to: menu, action: #selector(quit), enabled: !busy)
        item.menu = menu

    }
    func statusMessage() -> String {
        let running = devices.filter(\.booted).count + androidDevices.filter(\.booted).count
        guard androidAvailable else { return "\(devices.count) devices · \(devices.filter(\.booted).count) running" }
        return "\(devices.count) iOS · \(androidDevices.count) Android · \(running) running"
    }
    func perform(_ label: String, completion: ((Bool) -> Void)? = nil, operation: @escaping (IOSBackend) throws -> Void) {
        guard !busy else { return }
        busy = true
        message = label
        lastError = nil
        render()
        queue.async {
            var found: [Device]?
            var androidFound: [AndroidDevice]?
            var androidSlimmer = false
            var errorMessage: String?
            do {
                let backend = try IOSBackend()
                try operation(backend)
            } catch { errorMessage = error.localizedDescription }
            do { found = try IOSBackend().devices() }
            catch { if errorMessage == nil { errorMessage = error.localizedDescription } }
            // Opportunistic Android refresh so the section does not go stale
            // while an iOS operation owns the authoritative snapshot.
            if let backend = try? AndroidBackend.configured() {
                androidSlimmer = backend.avdslim != nil
                androidFound = try? backend.devices()
            }
            RunLoop.main.perform(inModes: [.common]) {
                self.busy = false
                if let found { self.acceptDevices(found) } else { self.statusKnown = false }
                if let androidFound {
                    self.androidAvailable = true
                    self.androidHasSlimmer = androidSlimmer
                    self.androidError = nil
                    self.androidDevices = androidFound
                }
                self.lastError = errorMessage
                self.message = errorMessage.map(errorSummary) ?? self.statusMessage()
                completion?(errorMessage == nil)
                self.render()
            }
        }
    }
    func performAndroid(_ label: String, avdName: String? = nil, profile: AndroidProfile? = nil, completion: ((Bool) -> Void)? = nil, operation: @escaping (AndroidBackend) throws -> Void) {
        guard !busy else { return }
        busy = true
        message = label
        lastError = nil
        render()
        queue.async {
            var androidFound: [AndroidDevice]?
            var errorMessage: String?
            var androidSlimmer = false
            do {
                let backend = try AndroidBackend.configured()
                androidSlimmer = backend.avdslim != nil
                try operation(backend)
                androidFound = try backend.devices()
            } catch { errorMessage = error.localizedDescription }
            do {
                if androidFound == nil {
                    let backend = try AndroidBackend.configured()
                    androidSlimmer = backend.avdslim != nil
                    androidFound = try backend.devices()
                }
            } catch {
                if errorMessage == nil { errorMessage = error.localizedDescription }
            }
            RunLoop.main.perform(inModes: [.common]) {
                self.busy = false
                self.androidHasSlimmer = androidSlimmer
                if let androidFound {
                    self.androidAvailable = true
                    self.androidError = nil
                    self.androidDevices = androidFound
                }
                self.lastError = errorMessage
                self.message = errorMessage.map(errorSummary) ?? self.statusMessage()
                if errorMessage == nil, let avdName, let profile {
                    self.lastProfiles["android:\(avdName)"] = profile.rawValue
                    UserDefaults.standard.set(self.lastProfiles, forKey: "lastAppliedProfiles")
                }
                completion?(errorMessage == nil)
                self.render()
            }
        }
    }
    @objc func refresh() {
        guard !busy && !refreshing else { return }
        refreshing = true
        queue.async {
            let result = Result { try IOSBackend().devices() }
            var androidSlimmer = false
            let androidResult = Result { () -> [AndroidDevice] in
                let backend = try AndroidBackend.configured()
                androidSlimmer = backend.avdslim != nil
                return try backend.devices()
            }
            RunLoop.main.perform(inModes: [.common]) {
                self.refreshing = false
                // A mutation owns the next authoritative snapshot.
                guard !self.busy else { return }
                switch result {
                case .success(let found):
                    self.acceptDevices(found)
                case .failure(let error):
                    self.statusKnown = false
                    self.lastError = error.localizedDescription
                }
                switch androidResult {
                case .success(let found):
                    self.androidAvailable = true
                    self.androidHasSlimmer = androidSlimmer
                    self.androidError = nil
                    self.androidDevices = found
                case .failure(let error as AndroidUnavailable):
                    // No SDK: hide the section silently instead of failing
                    // the whole refresh for iOS-only users.
                    _ = error
                    self.androidAvailable = false
                    self.androidHasSlimmer = false
                    self.androidError = nil
                    self.androidDevices = []
                case .failure(let error):
                    self.androidAvailable = true
                    self.androidError = error.localizedDescription
                }
                switch result {
                case .success:
                    self.message = self.statusMessage()
                case .failure:
                    self.message = errorSummary(self.lastError ?? "")
                    if self.androidAvailable {
                        self.message += " · \(self.androidDevices.count) Android"
                    }
                }
                self.render()
            }
        }
    }
    @objc func launchDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Device else { return }
        perform("Opening \(device.name)…") { backend in
            // Boot is idempotent; checking current state in the backend avoids a stale-menu race.
            try backend.bootAndOpen(device)
        }
    }
    @objc func shutdownDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Device else { return }
        perform("Shutting down \(device.name)…") { _ = try $0.execute(["shutdown", "--json", device.udid]) }
    }
    func lastAndroidProfileText(_ avdName: String) -> String {
        guard let raw = lastProfiles["android:\(avdName)"], let profile = AndroidProfile(rawValue: raw) else { return "Profile: not applied by SlimBar" }
        return "Last applied: " + profile.title
    }
    func launchAndroid(avdName: String, mode: AndroidLaunchMode) {
        performAndroid(mode == .quick ? "Launching \(avdName)…" : "\(mode.title) \(avdName)…") {
            try $0.launch(avdName: avdName, mode: mode)
        }
    }
    @objc func launchAndroidDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AndroidDevice else { return }
        if device.booted {
            activateAndroidEmulator(device.avdName)
        } else {
            launchAndroid(avdName: device.avdName, mode: .quick)
        }
    }
    func activateAndroidEmulator(_ avdName: String) {
        queue.async {
            guard let psOutput = try? AndroidBackend.hostProcesses() else { return }
            let entries = AndroidBackend.parsePs(psOutput)
            let direct = entries.filter { AndroidBackend.isEmulatorProcess($0.command, avdName: avdName) }
            let all = entries.filter { $0.command.contains("qemu-system-") }
            guard let process = direct.first ?? (all.count == 1 ? all[0] : nil) else { return }
            RunLoop.main.perform(inModes: [.common]) {
                // A windowless emulator is shown in Android Studio's Running
                // Devices panel, so bring Studio forward instead.
                if AndroidBackend.isHeadless(process.command) {
                    let studio = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.hasPrefix("com.google.android.studio") == true }
                    if let studio {
                        studio.activate()
                    } else {
                        self.message = "\(avdName) runs without a window"
                        self.render()
                    }
                    return
                }
                NSRunningApplication(processIdentifier: process.pid)?.activate()
            }
        }
    }
    @objc func launchAndroidWithMode(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AndroidLaunchChoice else { return }
        switch choice.mode {
        case .quick:
            break
        case .cold:
            guard confirm("Cold-boot \(choice.avdName)?", choice.mode.detail) else { return }
        case .wipe:
            guard confirm("Wipe \(choice.avdName) and boot factory-fresh?",
                          choice.mode.detail + "\n\nThis cannot be undone.") else { return }
        }
        launchAndroid(avdName: choice.avdName, mode: choice.mode)
    }
    @objc func applyAndroidProfile(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? AndroidProfileChoice,
              let device = androidDevices.first(where: { $0.avdName == choice.avdName }),
              confirm("Apply \(choice.profile.title) to \(device.avdName)?", choice.profile.detail + "\n\nThe selected AVD will boot if it is not running. Slimming applies to the running guest; the emulator window stays open. These profiles change guest services, not your app — test your own app's workflows before relying on one.") else { return }
        let name = choice.avdName
        let profile = choice.profile
        performAndroid("Applying \(profile.title)…", avdName: name, profile: profile) {
            try $0.apply(profile, to: name)
        }
    }
    @objc func shutdownAndroidDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AndroidDevice else { return }
        let name = device.avdName
        performAndroid("Shutting down \(name)…") { backend in
            // Resolve the serial in the backend: the menu's copy can be
            // stale if the emulator restarted since the last refresh.
            guard let serial = try backend.serial(forAvd: name) else {
                throw Failure(message: "\(name) is not running.")
            }
            try backend.shutdown(serial: serial)
        }
    }
    func confirm(_ title: String, _ detail: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Continue")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func acceptDevices(_ found: [Device]) {
        statusKnown = true
        for device in found {
            let previous = devices.first { $0.udid == device.udid }
            if !device.booted || previous?.state != device.state || previous?.managedDisabled != device.managedDisabled {
                compatibilityResults.removeValue(forKey: device.udid)
            }
        }
        compatibilityResults = compatibilityResults.filter { entry in found.contains { $0.udid == entry.key } }
        devices = found
    }
    func lastProfileText(_ udid: String) -> String {
        guard let raw = lastProfiles[udid], let profile = SlimProfile(rawValue: raw) else { return "Profile: not applied by SlimBar" }
        return "Last applied: " + profile.title
    }
    func compatibilityTimestamp(_ device: Device) -> String {
        guard device.booted else { return "Compatibility: boot device to check" }
        guard let checked = compatibilityResults[device.udid] else { return "Compatibility: not checked" }
        let time = DateFormatter.localizedString(from: checked.date, dateStyle: .none, timeStyle: .short)
        return "Services checked at " + time + (Date().timeIntervalSince(checked.date) > 60 ? " · recheck recommended" : "")
    }
    func compatibilityText(_ device: Device, index: Int) -> String {
        let title = CompatibilityReport.titles[index]
        guard device.booted, let checked = compatibilityResults[device.udid], Date().timeIntervalSince(checked.date) <= 60,
              let feature = checked.report.features.first(where: { $0.id == CompatibilityReport.required[index] }) else { return "— " + title + ": not checked" }
        return (feature.ok ? "✓ " : "⚠ ") + title + (feature.ok ? ": services enabled" : ": services disabled")
    }
    @objc func checkCompatibility(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Device, device.booted else { return }
        compatibilityResults.removeValue(forKey: device.udid)
        var report: CompatibilityReport?
        perform("Checking \(device.name)…", completion: { _ in
            if let report, self.devices.contains(where: { $0.udid == device.udid && $0.booted }) {
                self.compatibilityResults[device.udid] = CheckedCompatibility(report: report, date: Date())
            }
        }) { report = try $0.compatibility(device.udid) }
    }
    @objc func applyProfile(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ProfileChoice,
              let device = devices.first(where: { $0.udid == choice.udid }), choice.profile.supports(device.osVersion),
              confirm("Apply \(choice.profile.title) to \(device.name)?", choice.profile.detail + "\n\nThe selected device will boot and may reboot. The Simulator window opens automatically after the profile is applied. Profile verification and service compatibility checks run afterward. These checks inspect disabled services; they do not test your app end to end.") else { return }
        compatibilityResults.removeValue(forKey: device.udid)
        var verified = false
        var report: CompatibilityReport?
        perform("Applying \(choice.profile.title)…", completion: { _ in
            if verified {
                self.lastProfiles[device.udid] = choice.profile.rawValue
                UserDefaults.standard.set(self.lastProfiles, forKey: "lastAppliedProfiles")
            }
            if let report, self.devices.contains(where: { $0.udid == device.udid && $0.booted }) {
                self.compatibilityResults[device.udid] = CheckedCompatibility(report: report, date: Date())
            }
        }) { backend in
            try backend.applyAndOpen(choice.profile, device: device) { verified = true }
            report = try backend.compatibility(device.udid)
        }
    }
    @objc func copyUDID(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Device else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(device.udid, forType: .string)
    }
    @objc func copyAVDName(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AndroidDevice else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(device.avdName, forType: .string)
    }
    @objc func copyAndroidSerial(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AndroidDevice, let serial = device.serial else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serial, forType: .string)
    }
    @objc func copyAdbCommand(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AndroidDevice, let serial = device.serial else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("adb -s \(serial)", forType: .string)
    }
    @objc func screenshotAndroidDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AndroidDevice, device.booted else { return }
        let name = device.avdName
        var saved: URL?
        // Reveal in Finder from the main-thread completion, not the worker.
        performAndroid("Capturing screenshot…", completion: { ok in
            if ok, let saved { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
        }) { backend in
            guard let serial = try backend.serial(forAvd: name) else {
                throw Failure(message: "\(name) is not running.")
            }
            let data = try backend.commandRunner(backend.adb, ["-s", serial, "exec-out", "screencap", "-p"])
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let file = desktop.appendingPathComponent("\(name)-\(timestamp).png")
            try data.write(to: file)
            saved = file
        }
    }
    @objc func checkForUpdates() { updates?.check() }
    @objc func quit() { NSApp.terminate(nil) }
}

// Application entry point. The test harnesses compile everything above this line.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
