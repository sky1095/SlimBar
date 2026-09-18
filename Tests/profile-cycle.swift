// Explicit integration test: creates its own empty simulator and deletes only that device.
guard CommandLine.arguments.contains("--run-disposable-profile-cycle") else {
    print("Pass --run-disposable-profile-cycle to create a disposable iOS 26.5 simulator, apply all profiles, and clean it up.")
    exit(0)
}
func progress(_ text: String) { print(text); fflush(stdout) }
do {
    let backend = try IOSBackend()
    let name = "SlimBar Profile Test " + UUID().uuidString.prefix(8)
    let output = try IOSBackend.run("/usr/bin/xcrun", ["simctl", "create", name, "com.apple.CoreSimulator.SimDeviceType.iPhone-Air", "com.apple.CoreSimulator.SimRuntime.iOS-26-5"])
    let udid = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard UUID(uuidString: udid) != nil else { throw Failure(message: "Invalid created simulator UDID") }
    progress("Created disposable device: \(udid)")
    defer {
        _ = try? backend.execute(["shutdown", "--json", udid])
        do {
            _ = try IOSBackend.run("/usr/bin/xcrun", ["simctl", "delete", udid])
            progress("CLEANUP: deleted disposable test simulator \(udid)")
        } catch { progress("CLEANUP FAILED: \(udid): \(error.localizedDescription)") }
    }
    for profile in [SlimProfile.stock, .minimal, .everyday, .stock] {
        progress("Applying and verifying: \(profile.title)")
        try backend.apply(profile, to: udid)
        let report = try backend.compatibility(udid)
        guard report.ok == (profile != .minimal) else { throw Failure(message: "Unexpected compatibility for \(profile.title)") }
        guard let device = try backend.devices().first(where: { $0.udid == udid }), device.booted, device.memory != nil else { throw Failure(message: "Missing booted state or RAM reading") }
        progress("PASS: \(profile.title), verified profile; \(device.memoryText); \(report.features.map { "\($0.id)=\($0.ok)" }.joined(separator: ", "))")
    }
} catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
