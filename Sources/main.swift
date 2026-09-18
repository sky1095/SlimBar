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
        _ = try commandRunner("/usr/bin/open", ["-a", developer + "/Applications/Simulator.app", "--args", "-CurrentDeviceUDID", device.udid])
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
        item.button?.toolTip = "SlimBar — iOS simulators via simslim"
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
        add("SlimBar · iOS Simulators", to: menu)
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
        menu.addItem(.separator())
        add("Refresh", to: menu, action: #selector(refresh), enabled: !busy)
        let update = add("Check for Updates…", to: menu, action: #selector(checkForUpdates), enabled: updates?.canCheck == true)
        update.tag = 107
        update.toolTip = updates == nil ? "This build was made without an update signing key." : nil
        add("Quit SlimBar", to: menu, action: #selector(quit), enabled: !busy)
        item.menu = menu

    }
    func perform(_ label: String, completion: ((Bool) -> Void)? = nil, operation: @escaping (IOSBackend) throws -> Void) {
        guard !busy else { return }
        busy = true
        message = label
        lastError = nil
        render()
        queue.async {
            var found: [Device]?
            var errorMessage: String?
            do {
                let backend = try IOSBackend()
                try operation(backend)
            } catch { errorMessage = error.localizedDescription }
            do { found = try IOSBackend().devices() }
            catch { if errorMessage == nil { errorMessage = error.localizedDescription } }
            RunLoop.main.perform(inModes: [.common]) {
                self.busy = false
                if let found { self.acceptDevices(found) } else { self.statusKnown = false }
                self.lastError = errorMessage
                self.message = errorMessage.map(errorSummary) ?? "\(self.devices.count) devices · \(self.devices.filter(\.booted).count) running"
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
            RunLoop.main.perform(inModes: [.common]) {
                self.refreshing = false
                // A mutation owns the next authoritative snapshot.
                guard !self.busy else { return }
                switch result {
                case .success(let found):
                    self.acceptDevices(found)
                    self.message = "\(found.count) devices · \(found.filter(\.booted).count) running"
                case .failure(let error):
                    self.statusKnown = false
                    self.lastError = error.localizedDescription
                    self.message = errorSummary(error.localizedDescription)
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
    @objc func checkForUpdates() { updates?.check() }
    @objc func quit() { NSApp.terminate(nil) }
}

// Application entry point. The test harnesses compile everything above this line.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
