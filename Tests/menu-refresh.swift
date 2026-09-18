// Regression: a currently displayed menu must receive the new device state.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
delegate.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
func snapshot(_ state: String) -> [Device] {
    let json = """
    [{"udid":"test-device","name":"Test iPhone","state":"\(state)","osVersion":"26.5","set":"default"}]
    """
    return try! JSONDecoder().decode([Device].self, from: Data(json.utf8))
}
func require(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}
delegate.devices = snapshot("Booted")
delegate.render()
let displayedMenu = delegate.item.menu!
let displayedRow = displayedMenu.items.first { $0.title == "Test iPhone" }!
require(displayedRow.image?.accessibilityDescription == "Running", "booted row has running dot")
// Simulate the menu-open callback without initiating a backend request.
delegate.busy = true
delegate.menuWillOpen(displayedMenu)
delegate.busy = false
delegate.devices = snapshot("Shutdown")
delegate.render()
require(delegate.item.menu === displayedMenu, "refresh retains displayed menu")
require(displayedRow.toolTip == "Shutdown", "visible row receives shutdown state")
require(displayedRow.image?.accessibilityDescription == "Stopped", "visible dot switches to stopped")
let shutdown = displayedRow.submenu!.items.first { $0.title == "Shut Down" }!
require(!shutdown.isEnabled, "shutdown action is disabled for stopped device")
require(displayedRow.isEnabled, "stopped device remains clickable to boot")

require(!displayedMenu.items.contains { $0.title == "Device Actions" }, "no duplicate device actions list")
require(displayedRow.view is DeviceMenuRowView, "device name has direct-click row")
require(displayedRow.submenu?.items.contains { $0.title == "Copy UDID" } == true, "device actions are attached to device row")
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
let view = displayedRow.view!
window.contentView!.addSubview(view)
let inside = window.convertToScreen(view.convert(NSRect(x: 50, y: 10, width: 1, height: 1), to: nil)).origin
require(delegate.deviceRow(at: inside, in: displayedMenu) === displayedRow, "name click resolves to correct device")
require(delegate.deviceRow(at: NSPoint(x: inside.x + 500, y: inside.y), in: displayedMenu) == nil, "adjacent submenu clicks do not launch device")

// Show Last Error is gone: a failure has to be readable on the status row itself.
require(!displayedMenu.items.contains { $0.title.hasPrefix("Show Last Error") }, "no separate error menu item")
delegate.lastError = "simslim boot exited 1\nsecond line of backend output"
delegate.message = errorSummary(delegate.lastError!)
delegate.render()
let statusRow = displayedMenu.items.first { $0.tag == 101 }!
require(statusRow.title == "simslim boot exited 1", "status row shows the failure summary")
require(statusRow.toolTip == delegate.lastError, "full backend output stays readable on the status row")
require(errorSummary(String(repeating: "x", count: 100)).count == 64, "a long failure is truncated to fit a menu row")
require(errorSummary(" \n ") == "Action failed", "empty backend output still names the failure")
delegate.lastError = nil

// Over-the-air updates are offered, but never from a build that cannot verify them.
let updateRow = displayedMenu.items.first { $0.tag == 107 }!
require(updateRow.title == "Check for Updates…", "menu offers an update check")
require(UpdateController.configured() == nil, "updates stay off without a feed URL and public key")
require(delegate.updates == nil && !updateRow.isEnabled, "an unsigned build cannot check for updates")

if let monitor = delegate.clickMonitor { NSEvent.removeMonitor(monitor) }
