// Documentation artwork: real native components with illustrative fixture data.
// Does not capture or interact with the user's desktop.
let app = NSApplication.shared
app.appearance = NSAppearance(named: .aqua)
let menu = NSMenu()
let previewDelegate = AppDelegate()
let fixtures = """
[{"udid":"preview-1","name":"iPhone Air","state":"Booted","osVersion":"26.5","set":"default","memory":{"bytes":1073741824,"processes":84}},
 {"udid":"preview-2","name":"iPhone 17 Pro","state":"Shutdown","osVersion":"26.5","set":"default"},
 {"udid":"preview-3","name":"iPhone 16","state":"Shutdown","osVersion":"26.5","set":"default"}]
"""
let devices = try JSONDecoder().decode([Device].self, from: Data(fixtures.utf8))
var rowImages: [NSImage] = []
for device in devices {
    let row = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
    row.representedObject = device
    row.image = previewDelegate.statusDot(booted: device.booted)
    row.isEnabled = true
    let view = DeviceMenuRowView()
    row.view = view
    menu.addItem(row)
    let image = NSImage(size: view.bounds.size, flipped: false) { _ in
        view.draw(row: row)
        return true
    }
    rowImages.append(image)
}
func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ ink: Int = 0x14221F) {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 400), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color(ink), .paragraphStyle: paragraph])
}
func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: Int, _ radius: CGFloat = 20) {
    color(fill).setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
}
func export(_ filename: String, _ size: NSSize, draw: @escaping () -> Void) throws {
    let image = NSImage(size: size, flipped: true) { _ in draw(); return true }
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/images/" + filename))
}
try export("slimbar-preview.png", NSSize(width: 1200, height: 620)) {
    box(0, 0, 1200, 620, 0xEDF5F1, 0)
    box(42, 40, 132, 34, 0xD6E9DF, 17)
    text("NATIVE macOS", 57, 47, 120, 13, .semibold, 0x286146)
    text("SlimBar", 48, 115, 570, 70, .bold)
    text("Your simulators.\nOne menu bar away.", 50, 214, 590, 37, .medium)
    text("Launch devices. See live RAM.\nChoose a resource profile.", 52, 338, 510, 22, .regular, 0x53695F)
    text("Powered by SimSlim", 52, 514, 480, 19, .semibold, 0x286146)
    box(696, 129, 452, 349, 0xFFFFFF)
    menuBarDeviceImage(running: true, busy: false).draw(in: NSRect(x: 1096, y: 84, width: 22, height: 22))
    text("SlimBar · iOS Simulators", 724, 154, 390, 16, .semibold)
    text("3 devices · 1 running", 724, 184, 390, 13, .regular, 0x64756E)
    box(720, 218, 404, 1, 0xE7ECE9, 0)
    text("iOS 26.5", 733, 236, 380, 12, .semibold, 0x64756E)
    for (index, image) in rowImages.enumerated() {
        image.draw(in: NSRect(x: 725, y: 264 + index * 34, width: 390, height: 26))
    }
    box(720, 374, 404, 1, 0xE7ECE9, 0)
    text("Click to open · Hover for actions", 733, 399, 380, 14, .regular, 0x53695F)
    text("NATIVE COMPONENT PREVIEW · ILLUSTRATIVE DATA", 697, 507, 465, 11, .medium, 0x64756E)
}
try export("profiles.png", NSSize(width: 1200, height: 610)) {
    box(0, 0, 1200, 610, 0x14221F, 0)
    text("A profile for the task at hand.", 48, 44, 1100, 38, .semibold, 0xF2F8F4)
    text("Explicit choices. Verified changes. Restore with Stock.", 50, 103, 1100, 19, .regular, 0xAFC5B8)
    let summaries = ["Restore all SimSlim-managed services. A familiar baseline for your simulator.", "Keep store, web, iCloud, contacts, calendar, mail and Photos services. Slim other categories.", "Disable all SimSlim-managed services for basic UI testing. App features may stop working."]
    for (index, profile) in SlimProfile.allCases.enumerated() {
        let x = CGFloat(48 + index * 376)
        box(x, 178, 352, 306, 0x23382F)
        text(String(format: "%02d", index + 1), x + 24, 200, 280, 16, .medium, 0x92C7A5)
        text(profile.title, x + 24, 244, 295, 26, .semibold, 0xF2F8F4)
        text(summaries[index], x + 24, 326, 297, 18, .regular, 0xC4D5CB)
    }
    text("PROFILE REFERENCE · Service checks do not replace testing your app.", 50, 533, 1100, 15, .medium, 0xAFC5B8)
}
print("Rendered documentation previews")
