# Releasing

A release is a git tag (`v1.0.0`) and a GitHub release on `chocoguy/Wiicompiled-tv` with two files:
- **`WiiCompiledInstaller-<version>.zip`:** WiiCompiled Installer, signed with a Developer ID and notarized.
- **`appcast.xml`:** Sparkle's feed. Installers read it from `releases/latest/download/appcast.xml` to update themselves.

Players' installers see the new tag on GitHub, build the game from it on their Mac, and reinstall it on every Apple TV it's on.

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
3. **Sparkle's signing key:** the same key pair as Frontline Installer.
   - The public key is already in `apps/installer/sparkle-public-key.txt` (`zXdaNL5/ThT4IrxiYLM28IufQy6TRClWWwbO3oQaZh4=`).
   - The private key is in your login keychain ("Private key for signing Sparkle updates"). `generate_appcast` finds it there. To check, after building the installer once:
     ```sh
     build/installer-xcode/_deps/sparkle-src/bin/generate_keys -p
     ```
     It has to print the same public key. **Keep the backup** (`generate_keys -x <file>`): without the private key, installers already out there can't take updates, for this app and for Frontline.
4. **GitHub CLI**, signed in to an account that can publish to `chocoguy/Wiicompiled-tv`:
   ```sh
   gh auth status
   ```

## Each release

From a clean `main` that's pushed, with `aurora-main`'s commit pushed to the fork's `wiicompiled-tvos` branch:

```sh
tools/release.sh 1.0.0
```

It does this, in order:
1. Checks the above, that `main` equals `origin/main`, and that `aurora-main`'s commit is on `origin/wiicompiled-tvos`.
2. Opens your editor for the release notes (Markdown), or takes `--notes <file>`.
3. Sets `port.json`'s `version`, commits "Release 1.0.0", and tags `v1.0.0`.
4. Builds WiiCompiled Installer (Release), stamped 1.0.0 (build number 10000), with Sparkle's public key.
5. Signs Sparkle's parts inside-out, then the app (hardened runtime, timestamp).
6. Notarizes the zip, staples the app, checks it with `spctl`, and zips it again into `build/dist/1.0.0/`.
7. Makes `appcast.xml` with Sparkle's `generate_appcast` (signed with your key, release notes embedded).
8. Asks before pushing, then pushes `main` and the tag, and creates the GitHub release with both files.

If you answer no at the push, the commit and tag stay local. The script prints how to undo them.

**Options:**
- **Release candidates:** `tools/release.sh 1.0.0-rc1 --prerelease`. GitHub marks it a pre-release, so players don't see it: their installers skip pre-releases, and `latest/download` skips them for Sparkle. To test one, turn on pre-releases in your installer:
  ```sh
  defaults write com.vanillacoffeesoft.WiiCompiledInstaller includePrereleases -bool YES
  ```
- **A release that needs a newer installer:** `--min-app 1.1.0` sets `port.json`'s `minAppVersion`. Older installers then stop before building it and ask to update themselves first.
- **Dry run:** `--dry-run` runs the checks (reporting, not stopping) and builds an ad hoc installer into `build/dist`. It signs, notarizes, commits, tags and pushes nothing.

## Versions
- Tags are `v` plus a semantic version. The fork starts at `v1.0.0`, above upstream's `v0.x` tags, which the fork also carries.
- `port.json`'s `version` is the release. `Launcher/Directory.Build.props` keeps upstream's version, for upstream's Windows and Linux setup.
- In the Apple TV app and the installer:
  - `CFBundleShortVersionString` is the version's numeric part.
  - `CFBundleVersion` is `major×10000 + minor×100 + patch`.
  - `WiiCompiledVersion` (the full version, `-rc1` included) and `WiiCompiledCommit` are in Info.plist.
- `tools/tvos/port` stamps the Apple TV app through `Launcher/tvos/package_app.py --version --commit`.
