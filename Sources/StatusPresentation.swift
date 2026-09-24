import AppKit

func menuBarDeviceImage(running: Bool, busy: Bool) -> NSImage {
    let size = NSSize(width: busy ? 42 : 22, height: 22)
    let image = NSImage(size: size, flipped: false) { _ in
        let phone = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)!
        phone.draw(in: NSRect(x: 2, y: 0, width: 18, height: 22))
        if running {
            NSColor.systemGreen.setFill()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        }
        return true
    }
    image.isTemplate = !running
    image.accessibilityDescription = running ? "Simulator running" : "No simulator running"
    return image
}

// Backend failures arrive as multi-line command output. The status row shows the
// first line so a failure is visible at a glance; the row's tooltip keeps the
// full text for a bug report.
func errorSummary(_ error: String) -> String {
    let line = (error.split(separator: "\n").first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { return "Action failed" }
    return line.count > 64 ? line.prefix(63) + "…" : line
}

extension AppDelegate {
    func updateMenuBarStatus() {
        guard let button = item.button else { return }
        let running = (statusKnown || androidAvailable) && (devices.contains(where: \.booted) || androidDevices.contains(where: \.booted))
        item.length = busy ? 54 : 30
        button.title = ""
        button.image = menuBarDeviceImage(running: running, busy: busy)
        button.toolTip = busy ? message : !statusKnown && !androidAvailable ? "Simulator status unavailable" : running ? "SlimBar — running" : "SlimBar — none running"
        if progressIndicator == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.isDisplayedWhenStopped = false
            spinner.usesThreadedAnimation = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.widthAnchor.constraint(equalToConstant: 14),
                spinner.heightAnchor.constraint(equalToConstant: 14),
                spinner.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            progressIndicator = spinner
        }
        if busy {
            progressIndicator?.isHidden = false
            progressIndicator?.startAnimation(nil)
        } else {
            progressIndicator?.stopAnimation(nil)
            progressIndicator?.isHidden = true
        }
    }
}
