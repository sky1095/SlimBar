// Analytics: one event per install or update, nothing from keyless builds.
require(Analytics.launchEvent(lastVersion: nil, current: "1.0.2", launchedBefore: false) == .installed, "first launch is an install")
require(Analytics.launchEvent(lastVersion: nil, current: "1.0.2", launchedBefore: true) == .updated(from: "unknown"), "pre-analytics user counts as an update, not an install")
require(Analytics.launchEvent(lastVersion: "1.0.2", current: "1.0.3", launchedBefore: true) == .updated(from: "1.0.2"), "version change is an update from the stored version")
require(Analytics.launchEvent(lastVersion: "1.0.2", current: "1.0.2", launchedBefore: true) == nil, "same version sends nothing")
let updatePayload = Analytics.payload(.updated(from: "1.0.1"), key: "phc_test", id: "abc", version: "1.0.2", osVersion: "26.0.0")
let updateProperties = updatePayload["properties"] as? [String: Any]
require(updatePayload["event"] as? String == "app_updated" && updateProperties?["previous_version"] as? String == "1.0.1", "update payload names both versions")
require(Set(updateProperties?.keys.map { $0 } ?? []) == ["app_version", "previous_version", "$os", "$os_version", "$process_person_profile"], "payload carries nothing beyond versions")
require(Analytics.payload(.installed, key: "k", id: "i", version: "1", osVersion: "26").keys.sorted() == ["api_key", "distinct_id", "event", "properties"], "install payload shape")
let analyticsDefaults = UserDefaults(suiteName: "slimbar-analytics-test")!
analyticsDefaults.removePersistentDomain(forName: "slimbar-analytics-test")
let optedOut = Analytics(key: "k", host: URL(string: "https://invalid.example")!, defaults: analyticsDefaults)
require(optedOut.enabled, "sharing defaults to on")
optedOut.enabled = false
optedOut.recordLaunch(version: "9.9")
require(analyticsDefaults.string(forKey: Analytics.versionKey) == "9.9" && analyticsDefaults.string(forKey: Analytics.idKey) == nil, "opted-out launch records the version without an ID or request")
analyticsDefaults.removePersistentDomain(forName: "slimbar-analytics-test")
print("PASS: analytics checks completed")

// Error reports carry fixed labels only, never text from the message.
func errorLabels(_ message: String) -> [String: String] {
    Analytics.errorProperties(message).mapValues { "\($0)" }
}
require(errorLabels("adb -s emulator-5554 shell getprop exited 1\nerror: device 'Pixel_9' not found\n") == ["error_category": "command_failed", "tool": "adb", "exit_code": "1"], "command failure keeps tool and exit code, drops serial and stderr")
require(errorLabels("ps exited 2\n\n") == ["error_category": "command_failed", "tool": "ps", "exit_code": "2"], "argument-less command failure is recognised")
require(errorLabels("simslim on --json ABC exited 3\nthe device is missing, timed out within 5s") ["error_category"] == "command_failed", "stderr phrases cannot reclassify a command failure")
require(errorLabels("emulator -list-avds timed out after 20s") == ["error_category": "timeout", "tool": "emulator"], "timeout is recognised")
require(errorLabels("Pixel_9 did not appear in adb devices within 30s. Check the emulator window or run: /Users/me/sdk/emulator -avd Pixel_9") == ["error_category": "timeout"], "AVD name and path never become a label")
require(errorLabels("avdslim is missing. Reinstall SlimBar or set AVDSLIM_CLI to its executable.") == ["error_category": "backend_missing", "tool": "avdslim"], "missing backend is recognised")
require(errorLabels("Applied profile does not match simulator state.")["error_category"] == "verification_failed", "verification failure is recognised")
require(errorLabels("My iPhone is not running.") == ["error_category": "device_not_running"], "device name is not a tool")
require(errorLabels("Something unexpected at /Users/me/secret") == ["error_category": "other"], "unknown text becomes other, not a fragment")
let errorDefaults = UserDefaults(suiteName: "slimbar-analytics-errors")!
errorDefaults.removePersistentDomain(forName: "slimbar-analytics-errors")
let quiet = Analytics(key: "k", host: URL(string: "https://invalid.example")!, defaults: errorDefaults)
quiet.enabled = false
quiet.recordError(action: "refresh", platform: "ios", message: "simslim list exited 1")
require(errorDefaults.string(forKey: Analytics.idKey) == nil, "opted-out errors are not sent")
errorDefaults.removePersistentDomain(forName: "slimbar-analytics-errors")
print("PASS: analytics error checks completed")
