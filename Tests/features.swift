// Memory and service checks must not fabricate healthy/zero values.
let memoryJSON = """
[{"udid":"test-device","name":"Test iPhone","state":"Booted","osVersion":"26.5","set":"default","memory":{"bytes":1073741824,"processes":84}}]
"""
let measured = try! JSONDecoder().decode([Device].self, from: Data(memoryJSON.utf8))[0]
require(measured.memoryText.contains("GB"), "RAM is formatted from backend bytes")
require(snapshot("Booted")[0].memoryText == "RAM unavailable", "missing memory is unavailable, not zero")
require(snapshot("Shutdown")[0].memoryText.isEmpty, "stopped devices do not display stale RAM")
let negativeReport = """
{"udid":"test-device","ok":false,"features":[{"id":"push","name":"Push","ok":false,"disabled":["com.apple.apsd"]},{"id":"storekit","name":"StoreKit","ok":true},{"id":"universal-links","name":"Links","ok":true}]}
"""
let negative = CommandResult(data: Data(negativeReport.utf8), errorText: "", status: 1)
let report = try! IOSBackend.decodeCompatibility(negative, udid: "test-device")
require(!report.ok && report.features[0].disabled == ["com.apple.apsd"], "exit 1 with valid findings is displayed as incompatible")
func rejects(_ result: CommandResult, _ label: String) {
    do { _ = try IOSBackend.decodeCompatibility(result, udid: "test-device"); require(false, label) }
    catch { require(true, label) }
}
rejects(CommandResult(data: Data("not JSON".utf8), errorText: "not booted", status: 1), "command failure cannot masquerade as a compatibility result")
rejects(CommandResult(data: negative.data, errorText: "", status: 0), "contradictory exit code and report are rejected")
rejects(CommandResult(data: Data(negativeReport.replacingOccurrences(of: "test-device", with: "other-device").utf8), errorText: "", status: 1), "another device's report is rejected")
let separateStreams = try! IOSBackend.runResult("/bin/sh", ["-c", "printf '{\"ok\":true}'; printf 'diagnostic warning' >&2"])
require(String(decoding: separateStreams.data, as: UTF8.self) == "{\"ok\":true}" && separateStreams.errorText == "diagnostic warning", "stderr cannot corrupt JSON output")
require(!SlimProfile.everyday.supports("18.3") && SlimProfile.everyday.supports("18.5") && SlimProfile.stock.supports("17.0"), "unsupported persistent slimming is disabled while Stock remains available")
require(SlimProfile.everyday.flags.contains("--keep") && SlimProfile.essentialLabels.contains("com.apple.passd"), "everyday profile keeps shared StoreKit services explicitly")
delegate.devices = [measured]
delegate.compatibilityResults[measured.udid] = CheckedCompatibility(report: report, date: Date())
require(delegate.compatibilityText(measured, index: 0).contains("services disabled"), "broken push appears in device menu")
delegate.compatibilityResults[measured.udid] = CheckedCompatibility(report: report, date: Date(timeIntervalSinceNow: -61))
require(delegate.compatibilityText(measured, index: 0).contains("not checked"), "expired checks cannot look current")
delegate.compatibilityResults[measured.udid] = CheckedCompatibility(report: report, date: Date())
delegate.acceptDevices(snapshot("Shutdown"))
require(delegate.compatibilityResults[measured.udid] == nil, "shutdown invalidates cached compatibility")
delegate.devices = [measured]
delegate.render()
require(displayedRow.submenu!.items.first(where: { $0.tag == 103 })!.title.contains("GB"), "live memory updates in the retained menu")
let profileMenu = displayedRow.submenu!.items.first { $0.title == "Apply Profile" }!.submenu!
require(profileMenu.items.count == 3, "all three profiles are exposed on the device row")
print("PASS: all menu and feature checks completed")
