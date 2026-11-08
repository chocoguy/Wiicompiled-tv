# WiiCompiled → tvOS (Apple TV 4K) porting plan

## Context

WiiCompiled is a static recompilation of Mario Kart Wii. The translator (.NET) turns PPC into C++. The C++ runtime then builds on aurora (GX → Dawn/WebGPU → Metal) and SDL3. Today it builds for macOS arm64/x86_64, Windows and Linux. The goal is a playable Apple TV build.

**Decisions made:**
- Target: Apple TV 4K 3rd gen (A15) only, tvOS 26+.
- The base game ships first. Retro Rewind and online come later.
- Signing uses a **paid** developer account.

The TVPort fork of nxnative (`/Users/chocoguy/Documents/Code/TVPort`, MIT) already solved several tvOS limits on the same hardware. This plan reuses those solutions wherever they apply. The Mac stays the build machine: translation and compilation run there, cross-compiled to `arm64-apple-tvos`, as TVPort does.

### What the scan found

**Hard blockers in the current code (checked against the installed AppleTVOS27.2 SDK):**

| Blocker | Where | Fix |
|---|---|---|
| `mach/mach_vm.h` has `#error mach_vm.h unsupported` on tvOS | `runtime/src/guest_flat_memory_macos.cpp:4,85-152` | Use `vm_allocate`/`vm_remap` from `<mach/vm_map.h>`. These exist in the tvOS SDK. |
| Fixed 4 GiB guest base at 512 GiB, baked into translated code | `runtime/include/guest_abi/flat_memory.h:17-22` | Use 448 GiB (`0x70_0000_0000`) on tvOS. M0 measured it as the only slot that fits: `max_address` is 454 GiB, or 512 GiB with the extended-VA entitlement, and 63–448 GiB is the GPU carveout. |
| `-mcpu=native` for AArch64 | `runtime/cmake/RuntimeLibrary.cmake:17-21` | Cross-compiling on an M-series Mac would emit instructions the A15 lacks. Use `-mcpu=apple-a15`. TVPort `project_tv.yml:69` does the same. |
| Platform detection treats any `APPLE`+arm64 as macOS | `runtime/CMakeLists.txt:30-35` | Add `MKW_PLATFORM_TVOS`. |
| IOKit is linked (`find_library ... REQUIRED`), but tvOS has no IOKit | `runtime/cmake/PublicProducts.cmake:33-36,194-199` | Skip it on tvOS. TVPort strips it the same way in `build_ipa.sh:78`. |
| `posix_spawn` is `__TVOS_PROHIBITED` | `runtime/src/steam_input_layout.cpp:344-374` | Exclude the file on tvOS. |
| The CoreAudio HAL `AudioObject*` process list is macOS-only | `runtime/src/external_audio_macos.cpp` | Replace it (see M4). |
| `main()` runs directly with `SDL_MAIN_HANDLED`. tvOS needs UIKit's run loop and, with this SDK, a scene lifecycle. | `runtime/src/main.cpp:1587`, `RuntimeLibrary.cmake` | Use SDL_main/`SDL_RunApp` on tvOS (M3). |
| The data directory is `~/Library/Application Support`. TVPort found that tvOS 27.2 refuses writes to Documents and won't create Application Support. | `runtime/src/platform/host_platform.cpp:67-84` | Use `Library/Caches` plus a persistence layer (M5). |
| Dawn has no prebuilt tvOS package | `aurora-main/cmake/AuroraDawnProvider.cmake:95` | Source build (M1). Dawn's source handles tvOS, and SDL3 3.4.10 is ready (M0). |

**Already fine on tvOS:**
- No JIT. The translated C++ is static.
- The fiber switch in `co_switch.S` follows the Darwin AArch64 ABI and is x18-safe.
- `sigaction` is allowed. WiiCompiled doesn't call `sigaltstack`, which tvOS prohibits (TVPort `crash.c:187`).
- Guest RAM is tiny (24 MB MEM1 + 64 MB MEM2). TVPort's file-backed guest memory isn't needed to stay under the ~2.1 GB jetsam limit.
- BSD sockets and mbedTLS work. MetalFX, GameController, CoreHaptics and AVFAudio are all in the tvOS SDK.
- 16 KiB host pages already force checked access on Apple Silicon (`flat_memory.h:48-55`).

**Won't port:**
- Real Wii Remotes: tvOS has no classic-Bluetooth HID access.
- The WUP-028 GameCube adapter: no USB on Apple TV.
- Discord presence and Steam Input.
- Window size and position settings.

**TVPort solutions to reuse** (MIT, compatible with GPLv3; credit in `THIRD-PARTY-NOTICES.md`):
- `dm/ios/project_tv.yml`: xcodegen tvOS app target and Info.plist keys (`GCSupportsControllerUserInteraction`, scene manifest, device family 3).
- `dm/ios/Sources/front_ios.m:62-83,135-161`: `GCEventViewController` with `controllerUserInteractionEnabled = NO`, plus a window-level `UIPressTypeMenu` recognizer so Back/B stays in the game.
- `dm/ios/SourcesTV/TVSaves.m`: LZFSE-packed saves in `NSUserDefaults` (900 KB budget, larger saves spill to `Library/Preferences`), restored automatically when the folder is empty, copied on resign-active.
- `dm/ios/tools/tv_icon.swift`: layered tvOS icon and Top Shelf images from any image.
- `dm/host/hle_svc.c:23-40` (`guest_block`): an unlinked file in `Caches` mapped `MAP_SHARED`. Here it's the fallback way to alias guest RAM mirrors.
- `tvport/backend.py`: `devicectl` install, the launch dance (terminate, wait, launch), log and Jetsam report pull-back, and Mac-side save backups.
- Thermal-state watch (`front_ios.m` power watch) and the `DM_MEMSTAT`-style footprint logging.

---

## Milestones

### M0: Feasibility probes and dependency audit
**Done 2026-11-06.** Results and decisions are in [tvos-m0-findings.md](tvos-m0-findings.md); the probe is [`Launcher/tvos/probe`](../Launcher/tvos/probe/README.md).

1. Run `git submodule update --init --recursive`. In aurora, check:
   - which Dawn provider is used (prebuilt packages are probably macOS/Win/Linux only, so expect to build Dawn from source for `appletvos`);
   - the SDL3 version, and whether its UIKit backend supports the scene lifecycle that the tvOS 27 SDK requires (TVPort `project_tv.yml:45` notes "UIKit stops an app ... that has no scene lifecycle");
   - the ImGui SDL3 backend;
   - the MetalFX path;
   - how CMPR textures are uploaded when the `texture-compression-bc` feature is missing (the A15 has no BC).
2. Build a throwaway tvOS probe app (signed with the paid team) that:
   - tries `vm_allocate(VM_FLAGS_FIXED)` for 4 GiB at candidate 4 GiB-aligned bases (keep them 4 GiB-aligned so the base stays a single `movz`). Start at the current 512 GiB, then try lower bases outside the 64–448 GiB GPU carveout;
   - with the base allocated, tests `vm_remap` aliasing, then the `MAP_SHARED` file alias;
   - dumps the VA layout via `vm_region`;
   - retries the allocation with the `com.apple.developer.kernel.extended-virtual-addressing` entitlement. It's documented for iOS; check whether tvOS provisioning accepts it;
   - checks which directories are writable;
   - reports `MTLDevice` family and BC support, and whether MetalFX spatial upscaling is supported.
3. **Output:** a short decision record: the tvOS guest base, the aliasing API, and whether Dawn needs a source build.
   - Fallback if no fixed base is reliable: make `MKW_FLAT_GUEST_BASE` a load from a global on tvOS. That's a translator/header change, so measure its cost.

### M1: tvOS cross-compile of the runtime (no game code yet)
**Done 2026-11-06.** Every runtime source and library builds as tvOS arm64 (`platform TVOS`, `minos 26.0`, `-mcpu=apple-a15`), and the macOS CI targets and tests still pass.

To configure and build:

```bash
cmake -S runtime -B build-tvos -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvos -DCMAKE_OSX_ARCHITECTURES=arm64 -DMKW_BUILD_PRODUCTS=OFF
```

```bash
cmake --build build-tvos --target all aurora_core aurora_gx aurora_pad aurora_si aurora_vi aurora_mtx webgpu_dawn
```

What came up while building:
- Dawn's default `DAWN_BUILD_PROTOBUF` needs a host `protoc` when cross-compiling. It only backs Tint's IR binary format, so it's off on tvOS.
- `aurora-main/lib/webgpu/metalfx.mm` includes `<IOSurface/IOSurface.h>`, which iOS and tvOS don't ship. It now uses `<IOSurface/IOSurfaceRef.h>` there. This change belongs in the aurora fork.
- The first configure fetches Dawn's dependencies with `git` (a few minutes). The build is about 1,650 steps and took about 3.5 minutes on a 10-core Mac.
- The M2 memory items (shared Darwin `vm_*` file, 448 GiB tvOS base) landed here, because tvOS doesn't compile without them. Running them on the device is still M2's job.

Planned work:
- In `runtime/CMakeLists.txt`, detect `MKW_PLATFORM_TVOS` from `CMAKE_SYSTEM_NAME=tvOS`, with arm64 and deployment target 26.0. Split macOS and tvOS, and add `MKW_PLATFORM_APPLE` for the shared pieces:
  - `co_switch.S` (currently gated at lines 276-284 on `MKW_PLATFORM_MACOS_ARM64`);
  - Metal backend selection (`DAWN_ENABLE_METAL`, lines 165-169).
- In `RuntimeLibrary.cmake`, use `-mcpu=apple-a15` on tvOS. Drop the macOS-only CoreAudio and IOKit framework lookups for tvOS.
- Source list for tvOS:
  - exclude `steam_input_layout.cpp`, `external_audio_macos.cpp`, `wiimote_platform_*.cpp` and `discord_presence.cpp`, each behind a stub with the same interface (follow the existing `#if` stubs);
  - replace `guest_flat_memory_macos.cpp` with a shared Darwin file (M2).
- Build Dawn and SDL3 for `appletvos`. SDL3 supports tvOS upstream. Dawn's iOS Metal paths sit behind `TARGET_OS_IPHONE`, which tvOS also defines, so expect small patches for APIs tvOS lacks. Keep the patches in the aurora fork.
- Add a `mkw_tvos_native_compile` OBJECT target modeled on `mkw_macos_native_compile` (`CMakeLists.txt:415-437`).
- **Exit:** `cmake -G Ninja -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvos ...` builds the runtime, aurora, Dawn, SDL3, mbedTLS, Crypto++, pugixml and toml11.

### M2: Guest memory and host core
**Done 2026-11-06.** All 12 runtime tests pass on the Apple TV (A15, tvOS 27.2) through `ctest`. They cover the guest space at 448 GiB, the fiber switch, platform paths, config, NAND and input logic, and the main-thread stack.

To run them, configure the tvOS build with the TV and the signing team, then run `ctest` as usual:

```bash
cmake -S runtime -B build-tvos -DMKW_TVOS_TEST_DEVICE=<UDID> -DMKW_TVOS_TEST_TEAM=<TEAM_ID>
```

```bash
cmake --build build-tvos && ctest --test-dir build-tvos
```

- **How it works:**
  - `Launcher/tvos/run_on_device.py` is `CMAKE_CROSSCOMPILING_EMULATOR`. For each test it fills in the `.app` bundle's `Info.plist`, signs it with a tvOS team profile, installs it, runs it and uninstalls it, in about 2 s.
  - Tests must run one at a time, because they share one bundle ID.
- **devicectl can't be trusted for exit codes:** it reports "exit code 0" for these plain apps even after `return 3` or `abort()`.
  - Each tvOS test is linked with an entry point (`runtime/tests/tvos_test_entry.c`, via `-e`) that prints `MKW-TVOS-TEST-EXIT=<status>`, or `MKW-TVOS-TEST-SIGNAL=<n>` on a crash.
  - The runner passes a test only on `EXIT=0`, and returns 125 when a test reported nothing. All three failure modes were checked on the TV.
- **Main-thread stack:** the guest's boot thread runs on the host main thread (`main.cpp`, `InvokeIndirectCpu`). By default tvOS gives that thread 1,008 KiB, against 8 MiB on macOS.
  - tvOS honors `-stack_size`: `mkw_tvos_main_stack_tests` links with 8 MiB and recursed through 7 MiB. The same test fails without the flag.
  - The products link with `-stack_size` (`MKW_TVOS_MAIN_STACK_SIZE`, default `0x800000`, in `PublicProducts.cmake`). M3 must carry it to whatever links the app.
- **Paths:**
  - The tvOS data directory is `Library/Caches/<app>` (`host_platform.cpp`).
  - Bundled assets resolve beside the executable, which is the flat `.app` root on tvOS.
  - Portable mode is off on tvOS, because the bundle is read-only.

Planned work:
- Rewrite `guest_flat_memory_macos.cpp` as `guest_flat_memory_darwin.cpp`, with `mach_vm_allocate`/`mach_vm_remap`/`mach_vm_deallocate` → `vm_allocate`/`vm_remap`/`vm_deallocate`. These are 64-bit on arm64.
  - Use it for macOS too, so the existing `mkw_macos_guest_flat_memory_tests` keep covering it.
  - Fallback per M0: TVPort's `guest_block` file with `MAP_SHARED|MAP_FIXED` aliases.
- In `flat_memory.h`, add a `__aarch64__ && TARGET_OS_TV` branch with the 448 GiB base M0 measured (`0x0000'0070'0000'0000`). 512 GiB stays out of reach even with the extended-VA entitlement.
- Route platform paths through `host_platform.cpp`:
  - `ApplicationDataDirectory` → `Library/Caches/WiiCompiled`;
  - `ExecutableDirectory` → the bundle's resource path, which holds `dsp_coef.bin`, `wii_bootstrap/`, `initial_pipeline_cache.db` and `cacert.pem` (`PublicProducts.cmake:249-293` copies these today);
  - check `network_ssl.cpp:624` for the CA bundle lookup.
- Check the main-thread stack: tvOS's is far smaller than macOS's 8 MB. Guest code runs on 1 MB fibers (`fiber_manager.cpp:264`). If host init recurses deeply, move only the non-UI host work off the main thread, as TVPort's `main.m` `boot_thread` does.
- **Exit:** the host-context and flat-memory tests pass on the device, through a small test-runner app or an XCTest host.

### M3: App shell, packaging, signing and install (boots to the title screen)
**Done 2026-11-06.** Mario Kart Wii (PAL `RMCP01`) runs on the Apple TV 4K (A15, tvOS 27.2) on Metal. It boots, warms up its shaders, passes the strap scenes and plays the title movie at 59.9 fps in 4K. That was confirmed with `devicectl device capture screenshot` and the console log, from a clean install that has its game data only inside the app bundle.

One command does everything:

```bash
Launcher/tvos/build-tvos.command --team <TEAM_ID> --device <UDID> --game <image> --nodtool <nodtool> [--data bundle|caches] [--launch]
```

| Step | What happens | Time measured |
|---|---|---|
| 1. Translate | `Launcher/local-build-macos.command --translate-only` (new flag): the macOS translation, unchanged. Its output is the same for every host. | About 1 min for 29,637 functions |
| 2. Build | CMake builds `build-tvos` with `MKW_BUILD_PRODUCTS=ON` | First build of the game about 2 min once Dawn and SDL3 exist |
| 3. Package | `package_app.py` (below) | Seconds |
| 4. Install | `devicectl` | 52 s for the 2.6 GB bundle on a clean install |

What `package_app.py` does:
- writes `Info.plist` from `Launcher/tvos/Info.plist`, including SDL's `SDLUIKitSceneDelegate` scene manifest and the game controller keys;
- builds the layered icon and Top Shelf images from `WiiCompiled.icns` (TVPort's `tv_icon.swift`, then `actool`);
- clones `Assets/DATA` into the bundle;
- signs with an explicit-App-ID profile that grants extended virtual addressing. On first use it makes Xcode create that profile through `Launcher/tvos/provision`.

Pieces that made it work:
- **Entry point:** on tvOS, `main` lives in `src/platform/tvos/tvos_main.cpp` (outside the unity build) and includes `SDL_main.h`, so SDL 3.4.10 owns `UIApplicationMain` and the scene lifecycle. No custom SceneDelegate was needed.
- **Game data:** with no `Config.toml` entry, `ResolvedDvdRoot()` on tvOS uses `<app>/DATA`, or else `Library/Caches/WiiCompiled/DATA` (where `--data caches` pushes it once).
- **Data modes:** bundle mode is the default and survives tvOS cache purges. Caches mode is for development: reinstalls send only the 127 MB app.
- **What CMake already handled:** it builds tvOS executables as `.app` bundles, and the post-build copies put `dsp_coef.bin`, `wii_bootstrap`, `initial_pipeline_cache.db` and `cacert.pem` beside the executable. The runtime finds them there, and seeded its pipeline cache from the bundled copy.
- **Debugging:**
  - `devicectl device process launch --console` shows the runtime's transcript live;
  - `devicectl device copy from ... Library/Caches/WiiCompiled/Logs` fetches its log files (build-tvos.command `--launch` does both);
  - `devicectl device capture screenshot` grabs the TV screen in 4K.
- **The first-run NAND "FAILED to open" lines** (`RFL_DB.dat`, `wc24dl.vff`) are the same first-boot misses as on a new desktop install.
- **On-screen hints:** the "Press F10" hint and the settings overlay are still desktop-only (M4).
- **Memory:** the tvOS entry point logs `[tvos] memory: footprint / peak / headroom` every 15 s. On the title screen the footprint is about 900 MiB of the ~2,097 MiB limit, which is high for a Wii game; M6 should look at the 4K drawable and render targets.
- **Background kills:** when another app takes the TV, aurora logs `Surface present failed` / `window not presentable`, the game keeps running in the background, and tvOS kills it (SIGKILL, no report). That happened twice on 2026-11-06 when another game was opened on the same TV. M4's lifecycle work (pause the guest, audio and GPU on background) is what lets the app be suspended instead.

Planned work:
- On tvOS, drop `SDL_MAIN_HANDLED` and enter through `SDL_main`/`SDL_RunApp` so UIKit owns the run loop. Make sure SDL provides the scene lifecycle; if it doesn't, add a SceneDelegate modeled on TVPort's.
- Add `Launcher/tvos/project_tv.yml` (xcodegen), copied from TVPort's `project_tv.yml`:
  - links the CMake-built static and object libraries (`mkw_base_shared`, registrations, the runtime, aurora, Dawn, SDL3);
  - links with `-Wl,-stack_size,0x800000` (from M2), because the guest's boot thread runs on the main thread;
  - tvOS 26.0, `TARGETED_DEVICE_FAMILY=3`, automatic signing with the paid team;
  - Info.plist keys for game controllers and the scene manifest;
  - the `com.apple.developer.kernel.extended-virtual-addressing` entitlement and an explicit AVKit link (both from M0);
  - resources: bootstrap, DSP ROM, pipeline DB, CA bundle;
  - icon and Top Shelf from `runtime/resources/WiiCompiled.icns` (converted with `sips`), run through TVPort's `tv_icon.swift`.
- Game data: by default, bundle the extracted DVD root (`files/` + `sys/`) inside the .app. It's read-only, and tvOS never purges it. A dev flag instead pushes it once into `Library/Caches` via `devicectl` with an identity check, which makes reinstalls fast. That's TVPort's `DM_COPY_ROMFS=NO` and `stage_resources.sh` pattern.
- Add `Launcher/macos/build-tvos.command`:
  - reuses the translate and shard steps from `local-build-macos.command` (the translator output is host-neutral apart from the base address and CPU flags);
  - configures the tvOS CMake build, then runs xcodegen and `xcodebuild -allowProvisioningUpdates`;
  - installs and launches with `xcrun devicectl` (the TVPort `backend.py` sequence);
  - pulls `Caches/WiiCompiled/Logs` back afterwards.
- **Exit:** the app installs from the Mac, aurora comes up on Metal, and the strap and title screens render on the TV.

### M4: Input, UI and lifecycle (playable)
- **Controllers:** use SDL3's GameController-backed gamepads (Xbox, DualSense, Switch Pro, MFi) with the existing GC-pad bindings.
- **Back button:**
  - set `SDL_HINT_APPLE_TV_CONTROLLER_UI_EVENTS=0` next to `Wiimote::ConfigureSdlHints` (`main.cpp:1469`);
  - if Back/B still exits to Home, port TVPort's `GCEventViewController` and `UIPressTypeMenu` recognizer.
- **Siri Remote:** `SDL_HINT_TV_REMOTE_AS_JOYSTICK` for menu navigation.
- **Settings overlay** (`settings_overlay.cpp`, ImGui):
  - open it with a controller chord instead of F10;
  - enable `ImGuiConfigFlags_NavEnableGamepad`;
  - hide desktop-only sections (Wii Remote pairing, GC adapter, window, Steam, Discord, `GCPadNew.ini` file import).
- **Text entry:** `friend_code_keyboard.cpp` expects a physical keyboard. Use `SDL_StartTextInput` (tvOS keyboard) or an ImGui numeric pad instead.
- **Background and foreground** (`SDL_EVENT_WILL_ENTER_BACKGROUND` / `DID_ENTER_FOREGROUND`):
  - on background, pause guest scheduling and audio, stop submitting GPU work (tvOS kills apps that render in the background), and flush NAND writes and persistence (M5);
  - resume both on foreground.
- **Display:**
  - request the game's refresh rate with `AVDisplayManager.preferredDisplayCriteria` (Match Frame Rate);
  - default the resolution multiplier to the output size;
  - turn frame interpolation off by default, since Apple TV outputs at most 60 Hz.
- **Audio:**
  - set the SDL3 audio session's `AVAudioSession` category;
  - replace music ducking with `secondaryAudioShouldBeSilencedHint` and `AVAudioSessionSilenceSecondaryAudioHintNotification` in `music_attenuation.cpp`'s `__APPLE__` branch.
- **Rumble and motion:** SDL3 rumble through GCController haptics, and shake-to-trick through controller motion via SDL sensors.
- **Exit:** finish a Grand Prix with a controller, Back stays in the game, and Home → resume works.

### M5: Persistence (saves and settings survive purges and reinstalls)
- Port `TVSaves.m` into the runtime. It persists:
  - the NAND save data (`rksys.dat` under `NAND/`, see `nand_path.h:58`);
  - `Config.toml`;
  - `gamecontrollerdb.txt` (`controller_mapping_wizard.cpp:80`);
  - SYSCONF and NAND settings.
- Store from a hook where NAND file writes close (`runtime/src/hle/storage`) and on resign-active. Restore at boot when the `Caches` copies are missing. The pipeline cache and logs stay in `Caches` because the game can rebuild them.
- Paid-account extras:
  - **iCloud sync** of the packed saves through CloudKit's private database. The iCloud key-value store's 1 MB total is too small for saves with ghosts.
  - **Optional User Management** (`runs-as-current-user`) for per-Apple-TV-profile saves, which removes the need for TVPort's "Who's playing?" picker.
- **Optional:** Mac-side backups through `devicectl` (TVPort's automatic backup loop).
- **Exit:** wiping `Library/Caches` or reinstalling keeps licenses, ghosts and settings.

### M6: Performance, textures and thermals on the A15
- Profile GPU frame time at 1×, 2×, 3× and 4.5× internal resolution. Enable aurora's MetalFX spatial path on tvOS (`settings_overlay.cpp:1243` `metalFxSupported`).
- Textures: confirm CMPR decodes without BC hardware. If the CPU decode stutters, use TVPort's GPU-kernel BC1 decode (`nvn_bcdec.c`, `nvn_mtl.m` no-BC path) as the reference.
- Shader stutter:
  - ship `initial_pipeline_cache.db`;
  - optionally copy the device's learned pipeline cache back to the Mac and re-bundle it, like TVPort's `tvport-shaders.tsv`.
- Thermals: watch `NSProcessInfoThermalStateDidChangeNotification`. At serious, step the resolution down or turn off interpolation and MetalFX. The Apple TV has no fan, and TVPort saw throttling within 20–40 s under heavy load.
- Memory: log footprint against the ~2,097 MB jetsam limit. Pull Jetsam reports the way TVPort's Last Run does.
- **Exit:** a 30-minute session at the default resolution holds 60 fps with no jetsam kill and no sustained serious thermal state.

### M7: Retro Rewind and online
- Build the `RetroRewind` product (`PublicProducts.cmake:318-335`) through the same tvOS pipeline. Bundle the `RetroRewind6` files, and persist Retro Rewind saves through M5.
- Online play through Retro-WFC: test sockets, mbedTLS with the bundled `cacert.pem`, and friend-code entry from M4.
- **Exit:** Retro Rewind boots, and an online race works.

### M8: CI, docs and tooling
- Add a tvOS compile-audit job (`mkw_tvos_native_compile`) beside `macos_substrate` in `.github/workflows/build.yml:73-115`.
- Write `docs/building-tvos.md`, add a README platform badge and limits, and add notices for the TVPort-derived code.
- Later: a "Build for Apple TV" option in WiiCompiled Setup and Wheel Wizard, or a TVPort-style Mac app. Builds stay local per user; translated binaries are never shared.

---

## Critical files
- **Build:**
  - `runtime/CMakeLists.txt`
  - `runtime/cmake/RuntimeLibrary.cmake`
  - `runtime/cmake/PublicProducts.cmake`
  - `runtime/cmake/HostLibraries.cmake`
  - aurora fork (Dawn and SDL3 for tvOS)
- **Memory:**
  - `runtime/include/guest_abi/flat_memory.h`
  - `runtime/src/guest_flat_memory_macos.cpp` → `guest_flat_memory_darwin.cpp`
- **Platform:**
  - `runtime/src/platform/host_platform.cpp`
  - `runtime/src/main.cpp` (entry point, hints, lifecycle)
  - `runtime/src/music_attenuation.cpp`
- **UI and input:**
  - `runtime/src/settings_overlay.cpp`
  - `runtime/src/friend_code_keyboard.cpp`
- **New:**
  - `Launcher/tvos/project_tv.yml`
  - tvOS app-shell sources: SceneDelegate if needed, saves glue, display criteria
  - `Launcher/macos/build-tvos.command`
  - `docs/building-tvos.md`

## Verification
- **M0:** the probe app's on-device report shows a working 4 GiB fixed base with remap aliasing.
- **M1:** clean tvOS configure and build of `mkw_tvos_native_compile`, plus the existing macOS CI targets still pass, including `mkw_macos_guest_flat_memory_tests` on the shared Darwin memory file.
- **M2:** the context and flat-memory tests pass on the Apple TV.
- **M3:** `build-tvos.command --game <iso>` produces a signed .app, `devicectl` installs and launches it, and the pulled `console.log` shows aurora on Metal and the title screen.
- **M4–M7:** manual play checklists on the TV:
  - a Grand Prix and Time Trial with ghost save/load;
  - Back, Home and resume;
  - reinstall and `Caches` wipe, then check saves;
  - a 30-minute thermal run while logging footprint and frame time;
  - Retro Rewind online.
- **Physics regression:** replay a known-good ghost on tvOS and compare it with Dolphin and macOS. The project's own accuracy check is matching ghosts; a different `-mcpu` or a floating-point flag change must not desync.
