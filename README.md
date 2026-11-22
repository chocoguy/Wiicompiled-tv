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

## Controls


## For Developers


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


