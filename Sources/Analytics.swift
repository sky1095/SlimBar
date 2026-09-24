import Foundation

// Anonymous install/update counts and error reports. app_installed and
// app_updated are sent at most once per version; app_error when an operation
// fails. Payloads carry a random ID, the versions, the macOS version, and for
// errors only fixed labels (action, platform, category, tool, exit code): the
// error text itself never leaves the Mac, since it can hold device names,
// AVD names, UDIDs, and paths. A build without PostHogAPIKey in its Info.plist
// (every source build) sends nothing, and the menu toggle turns it all off.
enum LaunchEvent: Equatable {
    case installed
    case updated(from: String)
}

final class Analytics {
    static let enabledKey = "analyticsEnabled"
    static let versionKey = "analyticsLastVersion"
    static let idKey = "analyticsID"
    // A failure that repeats on every 3-second refresh must not become a
    // stream of events: each distinct error is sent once per launch, and a
    // launch sends at most a handful.
    static let maxErrorsPerLaunch = 10
    static let tools: Set<String> = ["simslim", "avdslim", "adb", "emulator", "xcrun", "open", "ps"]
    private var sentErrors: Set<String> = []
    private let lock = NSLock()
    let defaults: UserDefaults
    let key: String
    let host: URL

    static func configured(in bundle: Bundle = .main, defaults: UserDefaults = .standard) -> Analytics? {
        guard let key = bundle.object(forInfoDictionaryKey: "PostHogAPIKey") as? String, !key.isEmpty,
              let host = (bundle.object(forInfoDictionaryKey: "PostHogHost") as? String).flatMap(URL.init(string:)),
              host.scheme == "https" else { return nil }
        return Analytics(key: key, host: host, defaults: defaults)
    }

    init(key: String, host: URL, defaults: UserDefaults) {
        self.key = key
        self.host = host
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    // Users of versions before analytics have no stored version, but Sparkle
    // has already marked them as launched, so they count as updates, not installs.
    static func launchEvent(lastVersion: String?, current: String, launchedBefore: Bool) -> LaunchEvent? {
        if let lastVersion { return lastVersion == current ? nil : .updated(from: lastVersion) }
        return launchedBefore ? .updated(from: "unknown") : .installed
    }

    static func payload(_ event: LaunchEvent, key: String, id: String, version: String, osVersion: String) -> [String: Any] {
        switch event {
        case .installed:
            return payload("app_installed", [:], key: key, id: id, version: version, osVersion: osVersion)
        case .updated(let from):
            return payload("app_updated", ["previous_version": from], key: key, id: id, version: version, osVersion: osVersion)
        }
    }

    static func payload(_ name: String, _ extra: [String: Any], key: String, id: String, version: String, osVersion: String) -> [String: Any] {
        let properties: [String: Any] = ["app_version": version, "$os": "macOS", "$os_version": osVersion,
                                         "$process_person_profile": false].merging(extra) { current, _ in current }
        return ["api_key": key, "event": name, "distinct_id": id, "properties": properties]
    }

    // Reduces an error message to fixed labels. Anything not recognized is
    // "other", never a fragment of the message.
    static func errorProperties(_ message: String) -> [String: Any] {
        let lower = message.lowercased()
        let category: String
        // Command failures come first: their stderr is free text that could
        // otherwise match the phrases below.
        if message.range(of: #"^\S+ (.* )?exited -?\d+"#, options: .regularExpression) != nil { category = "command_failed" }
        else if lower.contains("timed out") || lower.contains(" within ") { category = "timeout" }
        else if lower.contains("is missing") { category = "backend_missing" }
        else if lower.contains("could not read compatibility") { category = "unreadable_output" }
        else if lower.contains("could not be verified") || lower.contains("does not match") || lower.contains("could not be confirmed")
                    || lower.contains("no longer boot-complete") || lower.contains("still listed") { category = "verification_failed" }
        else if lower.contains("is not running") || lower.contains("did not appear") { category = "device_not_running" }
        else { category = "other" }
        var properties: [String: Any] = ["error_category": category]
        if let tool = message.split(separator: " ").first.map(String.init), tools.contains(tool) {
            properties["tool"] = tool
        }
        if category == "command_failed", let range = message.range(of: #"exited -?\d+"#, options: .regularExpression),
           let code = Int(message[range].dropFirst("exited ".count)) {
            properties["exit_code"] = code
        }
        return properties
    }

    // action and platform are fixed labels chosen by the caller, e.g.
    // "apply_profile" and "android", never text derived from the device.
    func recordError(action: String, platform: String, message: String) {
        guard enabled else { return }
        var properties = Self.errorProperties(message)
        properties["action"] = action
        properties["platform"] = platform
        let signature = [action, platform, properties["error_category"], properties["tool"], properties["exit_code"]]
            .map { $0.map { "\($0)" } ?? "" }.joined(separator: "|")
        lock.lock()
        let fresh = sentErrors.count < Self.maxErrorsPerLaunch && sentErrors.insert(signature).inserted
        lock.unlock()
        guard fresh else { return }
        send("app_error", properties)
    }

    private func send(_ name: String, _ properties: [String: Any], version: String? = nil, onSuccess: (() -> Void)? = nil) {
        let version = version ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let id = defaults.string(forKey: Self.idKey) ?? UUID().uuidString
        defaults.set(id, forKey: Self.idKey)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = Self.payload(name, properties, key: key, id: id, version: version,
                                osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        var request = URLRequest(url: host.appendingPathComponent("i/v0/e/"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return }
            onSuccess?()
        }.resume()
    }

    // Must run before Sparkle starts: it sets SUHasLaunchedBefore on its first run.
    func recordLaunch(version: String) {
        guard let event = Self.launchEvent(lastVersion: defaults.string(forKey: Self.versionKey), current: version,
                                           launchedBefore: defaults.bool(forKey: "SUHasLaunchedBefore")) else { return }
        // An opted-out launch still records the version, so opting back in
        // later does not report a stale install or update.
        guard enabled else { defaults.set(version, forKey: Self.versionKey); return }
        let (name, properties): (String, [String: Any])
        switch event {
        case .installed: (name, properties) = ("app_installed", [:])
        case .updated(let from): (name, properties) = ("app_updated", ["previous_version": from])
        }
        // The version is stored only once PostHog accepts the event, so an
        // offline launch retries on the next one.
        send(name, properties, version: version) { [defaults] in defaults.set(version, forKey: Self.versionKey) }
    }
}
