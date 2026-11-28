# WiiCompiled

![Logo](https://mangogravy.com/wiicompiled-small.jpg)

This is a fork of patchzyy'z [Wiicompiled](https://github.com/patchzyy/Wiicompiled) all credit goes to him.

This is a native tvOS port of Mario Kart Wii, made with static recompilation.

There's no emulator in the loop, no interpreter, no JIT, no PowerPC
anywhere at runtime.

> [!IMPORTANT]
> There is no Nintendo code, no assets and no game data anywhere in this project or its releases.
> You need your own legally dumped copy of the PAL, NTSC-U, or NTSC-J version of the game. Setup only ships the
> toolchain, the translation runs on your machine against your disc image, and nothing ever gets
> uploaded.

## Requirements

- An Apple Silicon Mac
- macOS 27
- XCode 27
- An Apple TV 4K (3rd gen or newer) with tvOS 27, paired with Xcode (**Xcode → Window → Devices and Simulators**).
- An Apple ID signed in to Xcode (**Xcode → Settings → Accounts**). A free one works, but its installs open for 7 days; then reinstall to renew. A paid Apple Developer account lasts a year.
- Gamepad


## Install

Use **WiiCompiled Installer**. It's a Mac app that takes your own Mario Kart Wii disc image, builds the game from it, and installs it on your Apple TV. It also keeps the game up to date.

1. **Download WiiCompiled Installer** from the [latest release](https://github.com/chocoguy/Wiicompiled-tv/releases/latest), unzip it, and drag it to ***Applications folder.*** It's signed and notarized.
2. Have you dragged it to the ***Applications Folder?***
3. **Install Xcode 27** from the App Store and open it once. Xcode builds the game; you won't need to use it yourself.
4. **Open WiiCompiled Installer and follow Setup.** It checks what this Mac needs and fixes what it can:
   - it downloads the build tools (CMake, Ninja, nodtool, XcodeGen and the .NET SDK) into its own folder;
   - it installs Xcode's tvOS support if it's missing.
5. **Choose your disc:** a disc image of your own copy of Mario Kart Wii, PAL (`RMCP01`), NTSC-U (`RMCE01`) or NTSC-J (`RMCJ01`), as ISO, WBFS, CISO, RVZ, WIA or GCZ. You can drop it on the window.
6. **On Game, choose Install on an Apple TV…** and pick yours. It has to be paired with Xcode (on the Apple TV: Settings → Remotes and Devices → Remote App and Devices; then Xcode → Window → Devices and Simulators), switched on and awake.

The first build downloads the source and takes about half an hour; later ones are quicker. **Activity** shows what it's doing. The installer never opens the game for you: find WiiCompiled on the Apple TV's Home screen.

**Updates:** when a new version is released, **Updates** shows it with its notes. **Update All** builds it once and installs it on every Apple TV you installed it on. An Apple TV that's off is finished later with **Finish the Update**. When a release needs a new installer, it says so and links to it: download it from the [latest release](https://github.com/chocoguy/Wiicompiled-tv/releases/latest) and replace the old one. Until then, game updates wait, but **Reinstall** still works (a free Apple ID's install has to be renewed every 7 days).

**Before an install expires:** the game stops opening when its signing profile expires: after 7 days with a free Apple ID, or a year with a paid Apple Developer membership. The Game screen shows when each Apple TV's copy stops working; press **Reinstall** before then. Your saves are kept.

Everything the installer downloads and builds stays in one folder, `~/Library/Application Support/WiiCompiled Installer`, never inside the app, so replacing the app with a new download changes nothing. **Setup → Storage** shows its size, opens it in Finder, frees up space (removes the compiled game, which the next install compiles again) or removes everything (the game stays on your Apple TVs). It runs `tools/tvos/port`, which also works from the Terminal (see [For Developers](#for-developers)).

Saves and settings stay on the Apple TV, in the app's caches, with a copy in its settings that brings them back if tvOS clears the caches. Deleting the app deletes them.

## Controls

### Gamepad

Any controller the Apple TV supports works: Xbox, PlayStation (DualShock 4, DualSense), Nintendo Switch Pro, and MFi controllers. It reaches the game as a GameCube controller:

| Controller | GameCube |
|---|---|
| Left stick | Control Stick |
| Right stick | C-Stick |
| A / Cross | A |
| B / Circle (on Xbox controllers: X) | B |
| X / Square (on Xbox controllers: B) | X |
| Y / Triangle | Y |
| Left trigger / right trigger | L / R |
| Right bumper | Z |
| D-pad | +Control Pad |
| Menu / Options | START |

Rumble works on controllers that have it.

### Settings

Press the controller's **View / Back / Create** button (the game never uses it) to open the settings, and again to close them. Move around with the D-pad, choose with A, and go back with B. In the settings you can:
- change the internal resolution, and turn MetalFX upscaling and the FPS counter on or off
- assign controllers to the four ports, and remap every button
- turn vibration on or off, and set the volume

Changes are saved straight away and kept between launches.

### Siri Remote

The Siri Remote works in the menus and for a quick race: its touch surface is the Control Stick, a click is A, Play/Pause is X and Back is B. It can't open the settings; use a controller for that.

The TV button leaves the game. Back never quits it.

## For Developers

If you just want to play, use the installer above. Everything below is for building from the Terminal and working on the port.

**What you need,** besides the [requirements](#requirements):
- Xcode 27 with tvOS support (Xcode → Settings → Components)
- CMake 3.25 or later, Ninja and XcodeGen: `brew install cmake ninja xcodegen`
- The .NET 8 SDK or later, for the translator: `brew install --cask dotnet-sdk`
- [nodtool](https://github.com/encounter/nod/releases) (`nodtool-macos-arm64`), on your `PATH` or named by `WIICOMPILED_NODTOOL`

**Get the source,** with the `aurora-main` submodule ([chocoguy/aurora-tvos](https://github.com/chocoguy/aurora-tvos), branch `wiicompiled-tvos`):

```sh
git clone --recursive https://github.com/chocoguy/Wiicompiled-tv.git
```

**Build and install with `tools/tvos/port`,** the same build engine the installer runs:

```sh
tools/tvos/port check --disc <your disc image>
```

```sh
tools/tvos/port build --disc <your disc image> --device <Apple TV>
```

```sh
tools/tvos/port install --device <Apple TV>
```

- `check` lists what's missing on this Mac, and whether the disc is a supported release.
- `build` extracts and verifies the disc into `Assets/`, translates it into `generated/` (both git-ignored, and done once per disc), cross-compiles the runtime for tvOS, and packages and signs `build/port/package/WiiCompiled.app`. `--team` picks the signing team; by default it's the one signed in to Xcode.
- `install` puts it on the Apple TV (`xcrun devicectl list devices` lists their identifiers). `installed` reads back the version there; `clean` removes the build and the prepared disc.
- Add `--json` for one JSON event per line, which is what the installer reads.

`Launcher/tvos/build-tvos.command` wraps the same steps with developer extras: `--data caches` (sends the game data to the Apple TV once instead of inside every install), `--launch` with the console attached, and the runtime's logs afterwards.

**Tests:**

```sh
cmake -S runtime -B build-macos-tests -G Ninja -DMKW_BUILD_PRODUCTS=OFF -DAURORA_SDL3_PROVIDER=vendor && cmake --build build-macos-tests && ctest --test-dir build-macos-tests --output-on-failure
```

```sh
dotnet test translator/Translator.sln
```

```sh
cd apps/installer && cmake --preset installer-ninja && cmake --build --preset installertest && ../../build/installer-ninja/installertest/wiicompiled_installertest
```

The tvOS runtime tests run on a paired Apple TV: configure the tvOS build with `-DMKW_TVOS_TEST_DEVICE=<device> -DMKW_TVOS_TEST_TEAM=<team>`, then `ctest --test-dir build-tvos` (without `-j`).

**The installer** is in `apps/installer` (SwiftUI). Build it with `cd apps/installer && cmake --preset installer-xcode && cmake --build --preset installer`; a local build is signed ad hoc. Releases are made with `tools/release.sh`: see [docs/release.md](docs/release.md).

**More:** [docs/tvos-porting-plan.md](docs/tvos-porting-plan.md) covers how the port works and what's left; [docs/building-macos.md](docs/building-macos.md) covers upstream's native macOS build.


## Credits
- **inkwreck** - making the logo
- **[aurora](https://github.com/encounter/aurora)** - the GX rendering/windowing backend this
  project's whole graphics layer sits on. MIT licensed.
- **[Dawn](https://dawn.googlesource.com/dawn)** - Google's WebGPU implementation, powering
  aurora's Direct3D, Vulkan and OpenGL backends.
- **[Dolphin Emulator](https://github.com/dolphin-emu/dolphin)** - an invaluable reference for Wii
  hardware behavior during development, plus the source of the free DSP coefficient ROM and the
  unmodified default WiiConnect24 bootstrap tree bundled with the runtime.
- **[Retro Rewind](https://wiki.tockdom.com/wiki/Retro_Rewind)** by ZPL and team - the mod
  distribution this project supports.
- **[Wheel Wizard](https://github.com/TeamWheelWizard/WheelWizard)** - the mod manager this
  project integrates with as a launch backend.
- Everyone in the static recompilation community.

Bundled third-party components and their licenses live in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

Original game © Nintendo

Shoutouts to patchzyy and Claude 


