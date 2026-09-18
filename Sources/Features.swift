import Foundation

struct MemoryReading: Decodable {
    let bytes: Int64
    let processes: Int
}

extension Device {
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

enum SlimProfile: String, CaseIterable {
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
        case .stock: return "Restores all simslim-managed services. This may increase memory use."
        case .everyday: return "Keeps store, web, iCloud, contacts/calendar/mail, and photo services. Explicitly keeps the services checked for push notifications, StoreKit, and universal links. Other categories, including Siri, widgets, Health and HomeKit, are disabled. This is not a guarantee that every app feature will work."
        case .minimal: return "Disables all services managed by simslim. Push notifications, StoreKit, universal links, iCloud, Photos, and other features may stop working. Use for basic UI tests that do not need these services."
        }
    }
    // Keep labels explicitly: some belong to more than one category.
    static let essentialLabels = ["com.apple.apsd", "com.apple.storekitd", "com.apple.itunesstored", "com.apple.amsaccountsd", "com.apple.amsengagementd", "com.apple.amsondevicestoraged", "com.apple.passd", "com.apple.financed", "com.apple.swcd"]
    var flags: [String] {
        self == .everyday ? ["--except", "store,web,icloud,pim,photos", "--keep", Self.essentialLabels.joined(separator: ",")] : []
    }
    func applyArguments(_ udid: String) -> [String] { [self == .stock ? "off" : "on", udid] + flags }
    func supports(_ version: String) -> Bool {
        self == .stock || version.compare("18.5", options: .numeric) != .orderedAscending
    }
}

struct ProfileChoice {
    let udid: String
    let profile: SlimProfile
}

struct FeatureCheck: Decodable {
    let id: String
    let name: String
    let ok: Bool
    let disabled: [String]?
}

struct CompatibilityReport: Decodable {
    let udid: String
    let ok: Bool
    let features: [FeatureCheck]
    static let required = ["push", "storekit", "universal-links"]
    static let titles = ["Push notifications", "StoreKit", "Universal links"]
}

struct CheckedCompatibility {
    let report: CompatibilityReport
    let date: Date
}

struct CommandResult {
    let data: Data
    let errorText: String
    let status: Int32
}

extension IOSBackend {
    // Separate stderr so diagnostic warnings cannot corrupt machine-readable JSON.
    // A file avoids a second pipe filling up while stdout is drained.
    static func runResult(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("slimbar-\(UUID().uuidString).stderr")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(message: "Could not create command diagnostics file")
        }
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorData = try Data(contentsOf: errorURL)
        return CommandResult(data: data, errorText: String(decoding: errorData, as: UTF8.self), status: process.terminationStatus)
    }
    static func decodeCompatibility(_ result: CommandResult, udid: String) throws -> CompatibilityReport {
        // Exit 1 with a valid negative report is an expected compatibility result.
        guard result.status == 0 || result.status == 1,
              let report = try? JSONDecoder().decode(CompatibilityReport.self, from: result.data),
              report.udid == udid,
              Set(report.features.map(\.id)) == Set(CompatibilityReport.required),
              report.features.count == CompatibilityReport.required.count,
              report.ok == report.features.allSatisfy(\.ok),
              (result.status == 0) == report.ok else {
            throw Failure(message: "Could not read compatibility results (exit \(result.status)).\n\(result.errorText)\n\(String(decoding: result.data, as: UTF8.self))")
        }
        return report
    }
    func compatibility(_ udid: String) throws -> CompatibilityReport {
        let result = try Self.runResult(executable, ["doctor", "--json", "--requires", CompatibilityReport.required.joined(separator: ","), udid])
        return try Self.decodeCompatibility(result, udid: udid)
    }
    func applyAndOpen(_ profile: SlimProfile, device: Device, onVerified: () -> Void = {}) throws {
        try apply(profile, to: device.udid)
        onVerified()
        try bootAndOpen(device)
    }
    func apply(_ profile: SlimProfile, to udid: String) throws {
        _ = try execute(profile.applyArguments(udid))
        if profile == .stock {
            struct Status: Decodable { let managedDisabled: Int; let booted: Bool }
            let status = try JSONDecoder().decode(Status.self, from: execute(["status", "--json", udid]))
            guard status.booted && status.managedDisabled == 0 else { throw Failure(message: "Stock restore could not be verified.") }
        } else {
            // This checks both missing disables AND extra disables after switching profiles.
            struct Verification: Decodable { let ok: Bool; let udid: String }
            let result = try execute(["verify", "--json", udid] + profile.flags)
            let report = try JSONDecoder().decode(Verification.self, from: result)
            guard report.ok && report.udid == udid else { throw Failure(message: "Applied profile does not match simulator state.") }
        }
    }
}
