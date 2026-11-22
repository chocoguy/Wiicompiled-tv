# WiiCompiled → tvOS (Apple TV 4K) porting plan

## Context

WiiCompiled is a static recompilation of Mario Kart Wii. The translator (.NET) turns PPC into C++. The C++ runtime then builds on aurora (GX → Dawn/WebGPU → Metal) and SDL3. Today it builds for macOS arm64/x86_64, Windows and Linux. The goal is a playable Apple TV build.

**Decisions made:**
- Target: Apple TV 4K 3rd gen (A15) only, tvOS 26+.
- The base game ships first. Retro Rewind and online come later.
- Signing uses a **paid** developer account.

The TVPort fork of nxnative (MIT) already solved several tvOS limits on the same hardware. This plan reuses those solutions wherever they apply. The Mac stays the build machine: translation and compilation run there, cross-compiled to `arm64-apple-tvos`, as TVPort does.

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
- signs with a profile that covers the bundle ID. On first use it makes Xcode create one through `Launcher/tvos/provision`. Builds before M6 also needed the extended-virtual-addressing entitlement; see M6.

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
  - an explicit AVKit link (from M0). The `com.apple.developer.kernel.extended-virtual-addressing` entitlement was used until M6, which removed it;
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
**In progress 2026-11-08.** Code done, and the background/resume cycle was verified on the TV. Controller play, the Back button and the controller-driven overlay still need a hands-on test with a controller.

- **Background and resume, verified on the TV:**
  - SDL 3.4 sends `SDL_EVENT_WINDOW_MINIMIZED` when the app leaves the screen, and aurora then blocks the game loop in `SDL_WaitEvent`, so the guest stops by itself.
  - Opening another app and coming back resumed the title sequence: aurora recreated the surface, and audio dropped a few stale blocks.
  - tvOS can still end a backgrounded app when the foreground app needs memory (about 1 GB here). Saving progress against that is M5.
- **Back button:** SDL's tvOS view controller is a `GCEventViewController`, and controller UI events stay off by default (`SDL_HINT_APPLE_TV_CONTROLLER_UI_EVENTS`). SDL's view also swallows remote presses, so neither a controller's B nor the Siri Remote's Back should leave the game. Still to confirm by hand.
- **Siri Remote:** SDL maps the touch surface to the left stick, the click to A, Play/Pause to X and Back to B.
- **Settings overlay on tvOS** (`settings_overlay.cpp`, `MKW_OVERLAY_TVOS`):
  - a controller's Back/View button opens and closes it (the game never uses that button);
  - ImGui gamepad navigation is on only while it's open, with focus on the menu bar;
  - Escape/Back never opens a quit prompt, and there's no quit item;
  - Wii Remote pairing and the display-mode setting are hidden;
  - the hints name the controller button instead of F10.
  - With only a Siri Remote there is no way to open it yet.
- **Display:** `TvosPlatform::RequestDisplayRefreshRate` (`src/platform/tvos/tvos_platform.mm`) asks the TV for 60 Hz through `AVDisplayManager`. The TV only switches when Match Frame Rate is on; on this TV it is off, and the log says so.
- **Music ducking:** on tvOS it polls `AVAudioSession.secondaryAudioShouldBeSilencedHint`.
- **Build:** tvOS enables OBJC and OBJCXX before aurora and SDL are added, since enabling them later breaks SDL's `.m` flags. Products link AVKit explicitly.
- **Left for later:**
  - friend-code text entry (needed for online play, M7);
  - opening the overlay from the Siri Remote;
  - checking controller rumble and motion (SDL's GameController haptics and sensors) by hand.
- **Watch for M6:** memory went from 927 to 997 MiB over one background/resume cycle.

Planned work:
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
**Done 2026-11-08** (local persistence; the iCloud and per-profile extras below are still open). Saves and settings survive tvOS purging `Library/Caches`. Verified on the Apple TV with a real save from a finished race.

- **How it works** (`src/platform/tvos/tvos_persistence.mm`, the same approach as TVPort's `TVSaves.m`):
  - Every user-data file is kept as an LZFSE-packed copy in `NSUserDefaults`. `DATA/`, `Cache/` and `Logs/` are skipped because they can be regenerated.
  - Files that would push past a 900 KB budget go to `Library/Preferences/WiiCompiled-persist/` instead, because `NSUserDefaults` aborts the app near 1 MB.
  - At launch, before anything reads user data, any file missing from the cache is written back. A file still present is never overwritten.
  - Files that have no copy yet (saves from older builds, bootstrap files) are kept at launch.
- **When copies are made:**
  - after the NAND layer has flushed, closed and (for `NANDSafeOpen`) atomically committed a file, through `NandPersistence::FileWritten` in `nand_async.cpp` (`CommitAndCloseFd`) and `nand_fs.cpp` (`CloseFd`). A copy can therefore never catch a half-written save. The file is read at once and packed on a background queue;
  - `Config.toml`, `imgui.ini`, `gamecontrollerdb.txt` and the NAND marker are checked every 30 s;
  - everything is flushed on `SDL_EVENT_WILL_ENTER_BACKGROUND` and `SDL_EVENT_TERMINATING`.
- **Sizes:** a NAND with one finished race is 3.1 MB and packs to about 20 KB in all; `rksys.dat` goes from 2.8 MB to 2 KB.
- **Verified:**
  - `mkw_tvos_persistence_tests` runs on the Apple TV through `ctest` (10 checks): purge, restore byte for byte, spilling, ignored paths, and that newer files are never overwritten.
  - End to end on the TV: the first launch kept 20 files, including the existing `rksys.dat`. A launch with `MKW_TVOS_SIMULATE_CACHE_PURGE=1` (a development aid that wipes the user data first, since `devicectl` cannot delete container files) restored all 20. The runtime loaded the restored `Config.toml`, and `rksys.dat` hashed identically before and after.
  - Opening another app logged the flush before the game stopped presenting.
- **Limits:**
  - Deleting the app deletes these copies too. Mac-side backups (TVPort's `devicectl` backup loop) or iCloud are the answer to that.
  - A NAND file the game deletes can come back after a purge. Mario Kart Wii doesn't delete its save, but deletes aren't tracked.

Planned work:
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

### M6: Performance, textures and thermals
**Main slowdown fixed 2026-11-08.** The race intro, countdown and start ran at **31 fps** on the A15. They now hold **60 fps** for the whole race, including more than a minute at thermal state *serious*. The game runs at full speed (race clock = wall clock).

**How it was measured, with no controller:**
- `Config.toml` `expr_1_buttons_a = "timer(1.2) > 0.5"` pulses A. That clicks through the default menus into a Grand Prix at Luigi Circuit and keeps the kart moving. Remove it afterwards.
- `MKW_PERF_STATS=1` now logs, per 240 frames: `t=` seconds since launch, the presented fps, frame p95/max, the game thread's busy time, and its blocked time split into *stalled* (waiting on the GX worker, GPU or audio) and *pacing sleep* (60 Hz headroom) (`perf_stats.cpp`, `WaitScope(WaitKind)`).
- Instruments Time Profiler from the command line:

  ```bash
  xcrun xctrace record --template 'Time Profiler' --device <UDID> --time-limit 120s --env MKW_PERF_STATS=1 --launch -- <bundle ID>
  ```

  Then `xctrace export ... table[@schema="time-profile"]`. Attaching to a running app found no process. The same trace has `device-thermal-state-intervals`.
- The `[tvos] memory` line (every 15 s) now includes the thermal state.

**What was wrong:**
- **Serialized handoffs.** The game thread stalled about 19 ms a frame waiting on the render chain (game thread → GX worker → aurora FIFO processor → render worker → GPU). No thread was saturated, but about two-thirds of the GX worker's and FIFO processor's CPU went on waking each other:
  1. **GX worker** (`gx_worker.cpp`): while the game thread waited for a tail position, the worker broadcast `g_tailCv` after every record. That woke the game thread to recheck and contend for the mutex: about 3.1 s in `__psynch_cvbroad` and 1.9 s in contended unlocks per 33 s. **Fix:** the producer stores the tail it waits for (`g_producerWaitTarget`), and the worker notifies only on reaching it.
  2. **Aurora FIFO processor** (`aurora-main/lib/gx/fifo.cpp`, aurora fork branch `wiicompiled-tvos`): `std::atomic::wait` in libc++ polls for up to 64 µs, reading `steady_clock::now()` in a loop, before it blocks. That was about 5 s of clock reads per 33 s. **Fix:** a 2,048-iteration `yield` spin without clock reads, then a condition variable. `wake_worker` locks and notifies only while the worker sleeps (Dekker pairing on `sWorkerSleeping`).
  3. `CpuRelax()` was a no-op on ARM. It now emits `yield`.
- **`GXGetVtxDesc` drained the render queue.** `nw4r::ef::DrawStrategyImpl::SetupGP` (0x8003CB60, particle effects) queries `GXGetVtxDesc` and `GXGetVtxAttrFmt` before every effect draw, and each query drained the whole GX worker queue: about 50% of the game thread's samples. **Fix** (`gx_vertex.cpp`): a game-thread copy of the vertex descriptor and formats.
  - The setters update the copy before they defer.
  - `GXCallDisplayList` marks it stale.
  - A vertex-layout CP load arriving through the gather pipe turns it off for good.
  - `MKW_GX_VTX_SHADOW_VERIFY=1` checks every answer against the worker's state: 786,432 checks, 0 mismatches through boot, menus and a race.

**Result, same 33 s intro window:**

| Thread | Before (31 fps) | After (60 fps) |
|---|---|---|
| Game thread | 13.7 s | 8.2 s |
| GX worker and audio | 16.8 s | 5.5 s |
| FIFO processor | 11.4 s | 2.9 s |
| Render worker | 2.2 s | 2.2 s |

That's about 4.7× less CPU per frame. In the race the game thread is busy 3–5 ms a frame, with 2–12 ms of pacing sleep spare. Memory steady at about 940 MiB.

**Target device change (2026-11-21).** The A15 Apple TV is retired as the target. Testing moves to the Apple TV 4K 4th generation (`AppleTV18,1`, tvOS 27.2.1, 5 cores, SME/SME2, 8 GB RAM, still a 2,097 MB app limit). The M0 probe on it (`Launcher/tvos/probe/results/2026-11-21-AppleTV18,1-tvOS27.2.1-plain.txt`) shows the same address-space layout as the A15: the app's space ends at 454 GiB, and 448 GiB is the only free 4 GiB-aligned slot. The build still uses `-mcpu=apple-a15`, which runs on the newer chip. All 13 runtime tests pass on it.

**MetalFX upscaling on (2026-11-21).** The game renders at 1x (about 940×528) and the TV outputs 4K, so without MetalFX a bilinear filter stretches the image about 4×. MetalFX spatial upscaling is now on by default on tvOS (`settings_overlay.cpp`; `[video] metalfx_spatial_upscaling = false` turns it off). Changes in the aurora fork:
- `metalfx.mm`: availability checks name tvOS 27.1, the first tvOS with the MetalFX API.
- `metalfx.mm`, tvOS only: no `waitUntilScheduled` after committing the MetalFX command buffer. It blocked the render thread about 3.2 ms a frame (max 4.4) until the GPU had finished the scene. Whenever frame pacing drifted against the display, that dropped the game to 30 fps for a second or two, about every 18 s. Ordering is still enforced on the GPU: Dawn's next submission waits for the MetalFX shared event before reading the output. macOS keeps the wait.
- `aurora.cpp`, tvOS only: the upscale is capped at 2× per axis (939×528 → 1877×1056), and the present pass's linear sampler stretches the rest to 4K. Spatial upscaling is designed for up to 2×; going straight to 4K cost about 10 ms of GPU a frame against about 2.2 ms now.
- `aurora.cpp`: without frame interpolation, two slots instead of four. A slot that already has the right size is reused instead of rebuilt; Mario Kart Wii's menus alternate between 939×528 and 892×456.

Measured on the 4th-gen Apple TV, 4-minute autopilot sessions (`MKW_PERF_STATS`, 60 windows of 240 frames each):

| Setup | Mean fps | Windows < 58 fps | Footprint | MetalFX GPU / frame |
|---|---|---|---|---|
| MetalFX off | 59.9 | 0 | 953 MiB | none |
| MetalFX to 4K (first try) | 57.9 | 13 | 1,131 MiB | ~10 ms |
| Same, no CPU wait | 58.4 | 12 | 1,138 MiB | ~10 ms |
| **2× cap (shipped)** | **59.9** | **1** (loading) | **975 MiB** | **2.2 ms** |

**No extended-virtual-addressing entitlement (2026-11-21).** The app signs with no special capabilities, so any profile that covers the bundle ID works, wildcard ones included (`package_app.py`, `WiiCompiled.entitlements`).
- The entitlement only moved the end of the address space from 454 to 512 GiB. It never gave the guest a different base. Its job was to leave room above the guest, so that big allocations made before the guest was mapped landed somewhere else. The probe shows that after Metal starts, its allocations take the 448 GiB slot.
- Now a static constructor in `guest_flat_memory_darwin.cpp` (tvOS only) claims the 4 GiB slot before `main`, UIKit, Metal or Dawn run, and `GuestFlat::Initialize` adopts it.
- The `[tvos] memory` line now reports free address space and its largest gap. `MKW_TVOS_VM_DUMP=1` adds the largest regions and the space per memory tag every minute.
- Free address space in play: about 2.8–2.9 GB normally. After the shader cache is lost (a fresh install or a cache purge), compiling every pipeline from scratch leaves malloc's small zone holding about 1.4 GB, and free space settles at about 1.6 GB. It doesn't grow after that, and the next launch is back to 2.9 GB.

**Persistence bug found on the way.** `settings_overlay.cpp`'s globals read `Config.toml` during static initialization, before `main` restored the kept copies. After a real cache purge, `EnsureConfigFile` would have written a default `Config.toml`, and the restore would then have skipped the kept one. Now `RuntimeConfigFile::LoadConfigFile` calls `TvosPersistence::RestoreMissingFilesOnce()` first (`MKW_TVOS_PERSISTENCE`, defined for the app's runtime and product targets on tvOS). `MKW_TVOS_SIMULATE_CACHE_PURGE` moved there too, so the simulation now follows the same order as a real purge. On the device, 21 files came back before the config was first read.

**Not done yet:**
- These changes also run on macOS, Windows and Linux. macOS builds and passes its tests, but the game hasn't been played there with them. The MetalFX slot reuse is shared code; the 2× cap and the dropped wait are tvOS only.
- A thermal fallback (lower the resolution at *serious*) isn't needed at 1x; revisit for higher internal resolutions. The 4th-gen TV reported *serious* and *critical* after about 30 minutes of back-to-back test runs and still held 60 fps.
- Tune `-mcpu` for the 4th-gen chip, if the A15 baseline measurably costs anything.
- Why memory is about 950 MiB.

Planned work:
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
