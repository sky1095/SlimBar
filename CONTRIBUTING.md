# Contributing to SlimBar

Thanks for helping make simulator workflows simpler.

1. Fork the repository and create a focused branch.
2. On Apple Silicon with macOS 26 and full Xcode installed, run `./build.sh`. The build downloads and verifies the pinned SimSlim backend automatically.
3. Run `SIMSLIM_CLI="$PWD/build/SlimBar.app/Contents/Resources/simslim" Tests/run.sh`.
4. For UI changes, check menu tracking, direct device clicks, submenus, keyboard navigation, light/dark appearance, and VoiceOver.
5. Open a pull request explaining the problem, the behavior change, and how you checked it. Include screenshots for visible changes.

Keep changes small. SlimBar uses native AppKit, a bundled SimSlim executable, and Sparkle for updates; a further framework is rarely necessary. Preserve exact-device targeting, profile verification, and clear warnings before service changes.

## Optional live integration test

`Tests/integration.sh --run-disposable-profile-cycle` creates and deletes its own empty iPhone Air on the iOS 26.5 runtime. It applies all profiles and reboots that disposable simulator. Install the matching runtime first. Do not substitute a simulator containing work you need to keep.

## Reporting problems

Include macOS/Xcode versions, simulator runtime, SlimBar version, steps to reproduce, and the failure text from the menu status row (hover it for the full backend output). Remove personal paths and device identifiers from logs if you do not want to share them. File SlimBar UI/build issues here; issues with SimSlim itself belong in the upstream project linked in the README.

## Cutting a release

Releases are Developer ID signed, notarized, and stapled, and updates are additionally signed with an EdDSA key. Two one-time setup steps, on the maintainer's machine:

```sh
./build.sh                                 # fetches the pinned Sparkle release
build/vendor/Sparkle-*/bin/generate_keys   # stores the update key in your login keychain
xcrun notarytool store-credentials         # stores your Apple ID notarization credentials
```

Paste the public key printed by `generate_keys` into `SUPublicEDKey` in `Info.plist` and commit it — that half is public, and builds without it ship with updating disabled. Give the notary profile a name you will reuse.

Then bump `CFBundleShortVersionString` and `CFBundleVersion`, and run:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  NOTARY_PROFILE="your-profile-name" ./release.sh
```

That builds the app with the hardened runtime, notarizes and staples it, writes the Sparkle zip into `build/release/`, builds a signed and notarized DMG into `build/dmg/`, verifies both with `spctl`, and regenerates `appcast.xml`. Upload the four files it lists to the GitHub release.

Two things the layout depends on: the DMG is built outside `build/release/` because `generate_appcast` rejects a zip and a DMG of the same version in one directory, and previously released zips should stay in `build/release/` so the regenerated feed keeps its history. The app reads the feed from `releases/latest/download/appcast.xml`, so `appcast.xml` must be attached to every release.

## App icon

`icon/make-icon.sh` regenerates `icon/SlimBar.icns` from `icon/render-icon.swift`, and `build.sh` copies that file into the bundle before signing. The icon is drawn in code rather than stored as flat artwork so every slot in the iconset is rendered at its own pixel size instead of resampled from one master. The 16pt slot deliberately uses a filled silhouette: a proportional outline is a fraction of a pixel wide there and collapses into a smear. Commit the regenerated `.icns` along with any change to the renderer.

## Documentation images

Run `docs/render-previews.sh` to regenerate the native-component preview and profile guide. Preview values are illustrative. Keep the README captions clear that these are rendered documentation images, not captured desktop screenshots.
