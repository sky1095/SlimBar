# Contributing to SlimBar

Thanks for helping make simulator workflows simpler.

1. Fork the repository and create a focused branch.
2. On Apple Silicon with macOS 26 and full Xcode installed, run `./build.sh`. The build downloads and verifies the pinned SimSlim backend automatically.
3. Run `SIMSLIM_CLI="$PWD/build/SlimBar.app/Contents/Resources/simslim" Tests/run.sh`.
4. For UI changes, check menu tracking, direct device clicks, submenus, keyboard navigation, light/dark appearance, and VoiceOver.
5. Open a pull request explaining the problem, the behavior change, and how you checked it. Include screenshots for visible changes.

Keep changes small. SlimBar uses native AppKit and a bundled SimSlim executable; a new framework is rarely necessary. Preserve exact-device targeting, profile verification, and clear warnings before service changes.

## Optional live integration test

`Tests/integration.sh --run-disposable-profile-cycle` creates and deletes its own empty iPhone Air on the iOS 26.5 runtime. It applies all profiles and reboots that disposable simulator. Install the matching runtime first. Do not substitute a simulator containing work you need to keep.

## Reporting problems

Include macOS/Xcode versions, simulator runtime, SlimBar version, steps to reproduce, and the message from **Show Last Error**. Remove personal paths and device identifiers from logs if you do not want to share them. File SlimBar UI/build issues here; issues with SimSlim itself belong in the upstream project linked in the README.

## Documentation images

Run `docs/render-previews.sh` to regenerate the native-component preview and profile guide. Preview values are illustrative. Keep the README captions clear that these are rendered documentation images, not captured desktop screenshots.
