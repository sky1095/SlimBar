// App status follows all simulators, including while the menu stays open.
delegate.busy = false
delegate.acceptDevices(snapshot("Shutdown"))
delegate.render()
require(delegate.item.button!.image!.isTemplate, "idle menu bar icon uses neutral system color")
require(delegate.progressIndicator?.isHidden == true, "spinner is hidden when idle")
delegate.acceptDevices(snapshot("Booted"))
delegate.render()
require(!delegate.item.button!.image!.isTemplate, "booted simulator gets a full-color icon")
let bitmap = NSBitmapImageRep(data: delegate.item.button!.image!.tiffRepresentation!)!
var greenPixel = false
for x in 0..<bitmap.pixelsWide {
    for y in 0..<bitmap.pixelsHigh {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5,
           color.greenComponent > color.redComponent + 0.1 && color.greenComponent > color.blueComponent + 0.1 { greenPixel = true }
    }
}
require(greenPixel, "running icon actually renders green pixels")
delegate.busy = true
delegate.message = "Applying Everyday Development…"
delegate.render()
require(delegate.progressIndicator?.isHidden == false && delegate.progressIndicator?.isIndeterminate == true, "busy state displays an indeterminate spinner")
require(delegate.progressIndicator?.usesThreadedAnimation == true, "spinner animates independently during menu tracking")
require(delegate.item.button?.title == "" && delegate.item.length == 54, "spinner replaces static ellipsis with reserved space")
delegate.busy = false
delegate.render()
require(delegate.progressIndicator?.isHidden == true && delegate.item.length == 30, "completion removes spinner and restores compact width")
delegate.statusKnown = false
delegate.render()
require(delegate.item.button!.image!.isTemplate, "failed status refresh cannot leave a misleading green icon")

var calls: [(String, [String])] = []
let fakeBackend = try! IOSBackend(commandRunner: { executable, arguments in
    calls.append((executable, arguments))
    if arguments.first == "verify" { return Data("{\"ok\":true,\"udid\":\"test-device\"}".utf8) }
    if executable == "/usr/bin/xcode-select" { return Data("/Applications/Xcode.app/Contents/Developer\n".utf8) }
    return Data()
})
try! fakeBackend.applyAndOpen(.everyday, device: snapshot("Shutdown")[0])
require(calls.map { $0.1.first! } == ["on", "verify", "boot", "-p", "-a"], "slimming verifies, boots, then opens Simulator in order")
require(calls.last!.1.suffix(2) == ["-CurrentDeviceUDID", "test-device"], "auto-open targets the slimmed device")
var openedAfterFailure = false
let failingBackend = try! IOSBackend(commandRunner: { executable, arguments in
    if executable == "/usr/bin/open" { openedAfterFailure = true }
    if arguments.first == "on" { throw Failure(message: "Simulated slimming failure") }
    return Data()
})
do { try failingBackend.applyAndOpen(.minimal, device: snapshot("Shutdown")[0]); require(false, "slimming failure propagates") }
catch { require(!openedAfterFailure, "failed slimming does not open Simulator as if it succeeded") }
print("PASS: all status presentation checks completed")
