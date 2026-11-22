# WiiCompiled Installer: status

WiiCompiled Installer is the signed Mac app players download. It builds the Apple TV app from their own Mario Kart Wii disc at a GitHub release tag of `chocoguy/Wiicompiled-tv`, installs it on their Apple TVs, and updates it. It is modeled on Frontline Rewritten's installer and follows the same playbook. The pieces:

| Piece | Where |
|---|---|
| The installer app | `apps/installer/` (SwiftUI and Sparkle 2.10.1; presets in `apps/installer/CMakePresets.json`) |
| Its logic tests | `tests/installertest/` |
| The build engine | `tools/tvos/port` (Python standard library; `port.json` names it) |
| Version stamping | `port.json`, `Launcher/tvos/package_app.py --version --commit` |
| The Apple TV icons | `Launcher/tvos/Assets.xcassets` (layered icon, Top Shelf, launch screen) |
| Releasing | `tools/release.sh`, `docs/release.md` |

## Milestones

| | Milestone | State |
|---|---|---|
| R0 | `main` consistent: the tvOS work committed, `aurora-main` at the fork's `8ab5549` | Done |
| R1 | Upstream's packaging workflows skip the fork | Done |
| R2 | Version stamping (`port.json` 1.0.0; `CFBundleVersion` major×10000+minor×100+patch; `WiiCompiledVersion`, `WiiCompiledCommit`) | Done |
| R3 | Apple TV icons, Top Shelf and launch screen from the supplied asset catalog; `tv_icon.swift` removed | Done; checked with `actool`/`assetutil` |
| R4 | `tools/tvos/port` with the JSON events; `build-tvos.command` wraps it | Done; built from a disc into a signed app from a folder with spaces |
| R5 | The installer: Setup (Xcode, tvOS, Python, five pinned tool downloads, Apple ID), Game, Updates, Activity | Done; built ad hoc, logic tests pass; **window never opened** |
| R6 | `tools/release.sh` and `docs/release.md` with Frontline's signing setup | Done; `--dry-run` only |
| R7 | README: Install, Controls, For Developers | Done |

Nothing has been signed with the Developer ID, notarized, installed on an Apple TV or published by an agent.

## Differences from Frontline's installer

- **Apple TV only.** The `Platform` enum has the one case; there is no Mac install, Undo Mac Update or iPhone target.
- **A free Apple ID is allowed.** Setup accepts a free team and says its installs open for 7 days; the Game screen shows each install's expiry. Frontline requires a paid team.
- **More tools.** Besides CMake, the installer downloads Ninja, nodtool, XcodeGen and the .NET 8 SDK, each pinned and checksum-checked (`Tool` in `Sources/Source.swift`).
- **The disc stays in the source checkout.** The engine extracts into the checkout's `Assets/` and translates into `generated/`, both git-ignored, so they survive `checkout --force` to a new tag. `--work-dir` holds the build and the packaged app.
- **One build for every Apple TV.** The first Apple TV is passed to `build` so the profile lists it; with a free team, each Apple TV has to be registered with it (pairing in Xcode does this).

## Your test checklist

You do these; agents don't sign, install or publish.

1. **One-time setup check** (docs/release.md): the Developer ID for `USLHQ524FW`, the `frontline-notary` profile, the Sparkle private key in the keychain (`generate_keys -p` prints `zXdaNL5/…`), and `gh auth status`.
2. **Push `main`.** The release script requires `main` to equal `origin/main`:
   ```sh
   git push origin main
   ```
3. **A release candidate:**
   ```sh
   tools/release.sh 1.0.0-rc1 --prerelease
   ```
   On a second macOS user account, download the zip from the release, open the installer, and check there is no Gatekeeper warning. Turn on pre-releases there:
   ```sh
   defaults write com.vanillacoffeesoft.WiiCompiledInstaller includePrereleases -bool YES
   ```
4. **A fresh setup:** follow Setup (each Download button, then Check Again), choose the disc, and Install on an Apple TV. On the TV, check:
   - the icon (with its parallax), the Top Shelf image, and the orange launch screen
   - a race with a controller
   - that the View/Back button opens the settings
   - that the Game screen shows the version and an expiry date
5. **A game update:** release `1.0.1-rc1 --prerelease`. With a second Apple TV off (or unplugged), press Update All. Check it's marked pending, then switch it on and press Finish the Update.
6. **An installer update:** this needs a full, non-prerelease release, since Sparkle's `latest/download` skips pre-releases. Release `1.0.0` (step 8) first, then later `1.0.1 --min-app 1.0.1`. Check that the 1.0.0 installer offers the update (Check for Updates…) and refuses to build 1.0.1 before it's updated.
7. **Rollback:** Updates → Install Another Version… → the earlier tag.
8. **Publish:**
   ```sh
   tools/release.sh 1.0.0
   ```
