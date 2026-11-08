# tvOS port, M0: findings and decisions

This is the first milestone of [the porting plan](tvos-porting-plan.md): an on-device probe and an audit of aurora's dependencies.

- **Device:** Apple TV 4K (3rd generation), `AppleTV14,1`, A15, tvOS 27.2 (24K122).
- **Toolchain:** Xcode 27.2, AppleTVOS27.2 SDK.
- **Probe:** [`Launcher/tvos/probe`](../Launcher/tvos/probe/README.md).
- **Raw reports:** [`Launcher/tvos/probe/results`](../Launcher/tvos/probe/results).

## Decisions

| Question | Decision | Evidence |
|---|---|---|
| tvOS guest base | `kFixedFlatGuestBase = 0x0000'0070'0000'0000` (448 GiB) | It's the only 4 GiB-aligned slot a tvOS app can reserve. It loads with a single `movz #0x70, lsl #32`. |
| Extended Virtual Addressing | Ship with `com.apple.developer.kernel.extended-virtual-addressing` | tvOS provisioning accepted it for team `USLHQ524FW`. It raises `max_address` from 454 GiB to 512 GiB, so the free space above 448 GiB grows from 6 GiB to 64 GiB. |
| Aliasing API | `vm_allocate` + `vm_remap` from `<mach/vm_map.h>` in one shared Darwin file (M2) | All 8 Wii views mapped in 0.04 ms. The mirror, atomics and zero-fill checks pass at 448 GiB. |
| Aliasing fallback | Keep one unlinked file in `Library/Caches`, mapped `MAP_SHARED \| MAP_FIXED` (TVPort's `guest_block`) | Also passes at 448 GiB (0.3–0.45 ms). It's not needed now. |
| Dawn | Source build (`AURORA_DAWN_PROVIDER=vendor`) of `encounter/dawn@1155e0ed` for `appletvos` | aurora's prebuilt list has `ios-arm64` but no tvOS package, and an iOS-built archive can't link into a tvOS binary. Dawn's source does handle tvOS (see below). |
| SDL3 | Vendored 3.4.10 as is | It has the UIScene lifecycle and the tvOS controller hints, so no custom SceneDelegate should be needed (confirm in M3). |
| CPU flag | `-mcpu=apple-a15` | The A15 lacks SME, SME2, CSSC, HBC, AFP, RPRES and WFxT. `-mcpu=native` on an M4-class Mac could emit SME. |

## Address space (the main risk, now settled)

What a tvOS app's address space looks like, from `task_info(TASK_VM_INFO)` and `vm_region_recurse_64`:

| Range | What's there |
|---|---|
| 0–4 GiB | `__PAGEZERO` (not usable) |
| 4–6 GiB | The app image, heaps and stacks. Metal's shared buffers' CPU mappings land here too. |
| 6–63 GiB | The shared-cache region (`VM_MEMORY_SHARED_PMAP` submaps, up to `0xFC0000000`) |
| 63–448 GiB | One `VM_MEMORY_GUARD` reservation: the GPU carveout. Metal GPU addresses start at 84 GiB (`0x1500000000`). |
| 448–454 GiB | **Free** (without the entitlement, `max_address = 0x7180000000`) |
| 448–512 GiB | **Free** (with the entitlement, `max_address = 0x8000000000`) |

**Fixed 4 GiB reservation results:**
- **512 GiB** (today's Apple Silicon base) fails with `invalid address`: it's past `max_address` with or without the entitlement.
- **448 GiB** succeeds before UIKit starts, at `didFinishLaunching`, and again after Metal has started.
- **Every other candidate fails:** each 4 GiB step from 4 to 60 GiB, plus 64, 128, 256, 1024, 2048, 4096 and 8184 GiB.

The largest reservation anywhere is 4 GiB without the entitlement, and it lands at 448 GiB. With the entitlement it's 64 GiB.

448 GiB is `MACH_VM_NANO_BASE_ADDRESS`. Nano malloc wasn't active: no `VM_MEMORY_MALLOC_NANO` region existed in any phase.

**The risk that remains:** something could reserve that space before the guest does. Without the entitlement, any reservation larger than the low free space lands at 448 GiB. Two things protect against that:
- the runtime already maps the guest in `SystemBridge::Initialize` (`runtime/src/main.cpp:1381`), before `aurora_initialize` (`main.cpp:1473`). Keep that order on tvOS;
- the extended-VA entitlement leaves 60 GiB of room above the guest space.

M3 must confirm the slot is still free in the real app, with SDL3 and Dawn linked.

With the 448 GiB guest space held, Metal worked normally:
- it created a device, 32 × 32 MiB shared buffers and a 4096² mipmapped texture;
- a GPU blit filled 1 GiB and was verified;
- no buffer landed inside the guest space.

The Mac run (`--host`) passes everything at 512 GiB, and its 448 GiB slot is free too. So one base could serve both platforms later, but macOS doesn't need to change.

## Hardware and OS facts for later milestones

**Memory**
- 3,975 MiB physical. The app starts with about 2,097 MiB of jetsam headroom (`limit_bytes_remaining`, `os_proc_available_memory`).
- 1 GiB of Metal shared buffers counts in full toward that limit (headroom fell to 1,060 MiB). M6 should budget for Dawn's allocations at high internal resolutions.

**Stacks:** the main thread has 1,008 KiB and a default secondary pthread 512 KiB (macOS's main thread: 8 MiB). Guest fibers bring their own 1 MiB stacks (`fiber_manager.cpp:264`). M2 must check how deep host init goes on the main thread.

**GPU**
- Families Apple1–8, Common1–3, Metal3 and Metal4. No BC.
- `recommendedMaxWorkingSetSize` 2,731 MiB, `maxBufferLength` 2,048 MiB, argument buffers tier 1.
- MetalFX supports both spatial and temporal upscaling. The API needs tvOS 27.1, and aurora already weak-links MetalFX.

**Storage**

| Location | Writable? |
|---|---|
| `Library/Caches`, `Library/Preferences`, `tmp` | Yes |
| `Documents` | No: writes are refused |
| `Library/Application Support` | No: can't be created |
| `Library` itself | No |

Writing and reading back a 512 KiB `NSUserDefaults` blob works. This matches TVPort's findings and confirms the M5 persistence approach.

**Signals:** an access to a `PROT_NONE` page raises `SIGBUS` (signal 10) with the right `si_addr`, and `siglongjmp` recovery works. The runtime's handler already registers both `SIGSEGV` and `SIGBUS` (`main.cpp:1220-1228`).

**Display**
- The output is 3840×2160 at scale 2.0, with `maximumFramesPerSecond` 60.
- `AVDisplayManager` reported matching off (the TV's Match Frame Rate setting).
- `UIWindow.avDisplayManager` comes from an AVKit category. With no AVKit symbol referenced, autolinking drops AVKit and the selector fails at run time. **M4 must link AVKit explicitly.**

**Install and logs:** automatic signing with `-allowProvisioningUpdates` works from the command line. `devicectl device process launch --console` relays stderr, and `devicectl device copy from --domain-type appDataContainer` pulls files from `Library/Caches`. That's the M3 log pull-back.

## Dependency audit (aurora `33067e3`)

**Dawn** (`encounter/dawn@1155e0ed`, `AURORA_DAWN_VERSION v20260807.225922`)
- `src/utils/platform.h` defines `DAWN_PLATFORM_IS_TVOS` alongside `IS_IOS`.
- IOKit is used only under `DAWN_PLATFORM_IS(MACOS)` (`PhysicalDeviceMTL.mm:45-49`).
- `PhysicalDeviceMTL.mm:396-405` leaves `haveStoreAndMSAAResolve = false` on tvOS, so Dawn turns on `EmulateStoreAndMSAAResolve` even though the A15 supports it. That's a candidate patch for the aurora fork (M1/M6).

**SDL 3.4.10**
- `SDL_uikitappdelegate.m` implements the scene delegate: connect, `sceneDidBecomeActive`, `sceneWillResignActive`, `sceneWillEnterForeground`, `sceneDidEnterBackground`.
- `SDL_HINT_APPLE_TV_CONTROLLER_UI_EVENTS` and `SDL_HINT_TV_REMOTE_AS_JOYSTICK` are both available.
- SDL's view controller already toggles `controllerUserInteractionEnabled`.

**aurora**
- **Textures:** CMPR is always decoded to RGBA8 on the CPU (`lib/gfx/texture_convert.cpp:632`), so the A15's missing BC support doesn't affect game textures. Only `GX_TF_BC1_PC` replacement textures fall back to RGBA8 decode (`texture_convert.hpp:19`).
- **Haptics and rumble:** `cmake/aurora_core.cmake:55` uses CMake's `IOS` variable, which is false for tvOS, so `lib/device_ios.mm` (CoreHaptics) isn't built. `lib/device.cpp:201` stubs rumble out on tvOS. Rumble therefore needs work in M4.
- **Window:** `lib/window.cpp:570` already creates a fullscreen window on tvOS.
- **MetalFX:** `lib/webgpu/metalfx.mm` needs IOSurface (present in the tvOS SDK) and Dawn's `SharedTextureMemoryIOSurface` feature, which M1 must check once Dawn builds.
- **ImGui:** `lib/imgui.cpp` uses `imgui_impl_sdl3` and `imgui_impl_wgpu`. Gamepad navigation isn't enabled anywhere; that's M4.

## What this changes in the plan

- **M2:** add `#elif defined(__aarch64__) && defined(__APPLE__) && TARGET_OS_TV` → `0x0000'0070'0000'0000` before the macOS branch in `runtime/include/guest_abi/flat_memory.h`, and use `vm_allocate`/`vm_remap`.
- **M3:**
  - add `XVA.entitlements`' key to the app target;
  - link AVKit explicitly;
  - log `max_address` and the guest base at startup so a failed reservation is obvious.
- **M1:** build Dawn from source, and patch the tvOS `EmulateStoreAndMSAAResolve` default in the aurora fork.
- **M4:**
  - enable aurora's CoreHaptics path for tvOS;
  - enable ImGui gamepad navigation;
  - remember that display-criteria matching is the user's setting.
