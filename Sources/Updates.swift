import AppKit
import Sparkle

// Over-the-air updates. The appcast and the archives it points at live on the
// project's GitHub releases. SlimBar ships ad-hoc signed rather than Developer
// ID signed, so Sparkle's EdDSA signature is the only thing standing between a
// download and the user's Applications folder: a build without a public key
// leaves updating switched off instead of accepting unverified archives.
final class UpdateController: NSObject {
    private let controller: SPUStandardUpdaterController
    var canCheck: Bool { controller.updater.canCheckForUpdates }

    static func configured(in bundle: Bundle = .main) -> UpdateController? {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https",
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return UpdateController()
    }

    private override init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }

    // A menu bar app owns no windows, so Sparkle's panels need explicit activation.
    func check() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
