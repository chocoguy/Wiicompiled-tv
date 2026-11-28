# Releasing

A release is a git tag (`v2.0.0`) and a GitHub release on `chocoguy/Wiicompiled-tv` with one file, **`WiiCompiledInstaller.zip`**: WiiCompiled Installer, signed with a Developer ID and notarized.

Players' installers see the new tag on GitHub, build the game from it on their Mac, and reinstall it on every Apple TV it's on.

**The major version is the installer's.** The installer doesn't update itself:
- **`N.0.0` is a new installer.** The script builds, signs and notarizes it. Installers of an earlier major version show an alert that a new installer is available, link to the release, and stop updating the game until the player uses the new one (Reinstall still works, so free-account installs can be renewed).
- **`N.x.y` is a game update.** No new installer: the script attaches `vN.0.0`'s zip again, unchanged, so the latest release always has the installer to download. Installers of major `N` update the game to it.

An installer builds only the releases of its own major version. Everything it makes is in `~/Library/Application Support/WiiCompiled Installer`, not in the app, so replacing the app with a new download changes nothing else.

**From Sparkle (1.x) to 2.0.0:** the 1.x installers updated themselves with Sparkle; 2.x installers don't. The first release with the new installer is `2.0.0`. The 1.x installers read `port.json`'s `minAppVersion` (`2.0.0`), stop before building it and ask to update, but their Check for Updates… finds nothing: players download the new installer by hand. `v1.0.0` has no `WiiCompiledInstaller.zip`, so there are no more 1.x releases.

`tools/release.sh` does all of it on your Mac. Nothing signs or publishes in CI: upstream's packaging workflows (`.github/workflows/package.yml`) skip themselves outside `patchzyy/Wiicompiled`.

## One-time setup

This uses the same signing setup as Frontline Rewritten, so on a Mac that already releases Frontline there is nothing new to make. Check each one:

1. **Developer ID certificate** for team `USLHQ524FW`:
   ```sh
   security find-identity -v -p codesigning
   ```
   It has to list `Developer ID Application: … (USLHQ524FW)`. The script picks that team's identity even when the keychain holds others. If it's missing: Xcode → Settings → Accounts, team `USLHQ524FW`, Manage Certificates… → + → **Developer ID Application** (only the Account Holder can make one).
2. **Notarization credentials** under the profile `frontline-notary`:
   ```sh
   xcrun notarytool history --keychain-profile frontline-notary
   ```
   If that fails, store them again (it asks for an app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords):
   ```sh
   xcrun notarytool store-credentials frontline-notary --apple-id <your Apple ID> --team-id USLHQ524FW
   ```
The certificate and the notarization profile are needed only for a new major version (`N.0.0`).

3. **GitHub CLI**, signed in to an account that can publish to `chocoguy/Wiicompiled-tv`:
   ```sh
   gh auth status
   ```

## Each release

From a clean `main` that's pushed, with `aurora-main`'s commit pushed to the fork's `wiicompiled-tvos` branch:

```sh
tools/release.sh 2.0.0
```

It does this, in order:
1. Checks the above, that `main` equals `origin/main`, and that `aurora-main`'s commit is on `origin/wiicompiled-tvos`. For a game update (`2.1.0`), checks `v2.0.0` on GitHub has the installer.
2. Opens your editor for the release notes (Markdown), or takes `--notes <file>`.
3. Sets `port.json`'s `version` (and `minAppVersion` to `N.0.0`, for the Sparkle-era 1.x installers), commits "Release 2.0.0", and tags `v2.0.0`.
4. **New major version only:** builds WiiCompiled Installer (Release) from scratch, stamped 2.0.0 (build number 20000), signs it (hardened runtime, timestamp), notarizes the zip, staples the app, checks it with `spctl`, and zips it again into `build/dist/2.0.0/`.
   **Game update:** downloads `vN.0.0`'s `WiiCompiledInstaller.zip` into `build/dist/<version>/` instead.
5. Asks before pushing, then pushes `main` and the tag, and creates the GitHub release with the zip.

If you answer no at the push, the commit and tag stay local. The script prints how to undo them.

**Options:**
- **Release candidates:** `tools/release.sh 2.0.0-rc1 --prerelease`. GitHub marks it a pre-release, so players don't see it: their installers skip pre-releases. To test one, turn on pre-releases in your installer:
  ```sh
  defaults write com.vanillacoffeesoft.WiiCompiledInstaller includePrereleases -bool YES
  ```
- **A release that needs a new installer:** give it the next major version (`3.0.0`).
- **Dry run:** `--dry-run` runs the checks (reporting, not stopping) and builds an ad hoc installer into `build/dist`. It signs, notarizes, commits, tags and pushes nothing.

## Versions
- Tags are `v` plus a semantic version. The fork starts at `v1.0.0`, above upstream's `v0.x` tags, which the fork also carries.
- `port.json`'s `version` is the release. The installer's version is the `N.0.0` release it was built for. `Launcher/Directory.Build.props` keeps upstream's version, for upstream's Windows and Linux setup.
- In the Apple TV app and the installer:
  - `CFBundleShortVersionString` is the version's numeric part.
  - `CFBundleVersion` is `major×10000 + minor×100 + patch`.
  - `WiiCompiledVersion` (the full version, `-rc1` included) and `WiiCompiledCommit` are in Info.plist.
- `tools/tvos/port` stamps the Apple TV app through `Launcher/tvos/package_app.py --version --commit`.
