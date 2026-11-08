# tvOS feasibility probe

This is a small tvOS app that tests what the WiiCompiled runtime needs from an Apple TV before the real port is built. Findings and decisions are in [docs/tvos-m0-findings.md](../../../docs/tvos-m0-findings.md).

It checks:
- the address space: a fixed 4 GiB guest reservation at candidate bases, the 8 Wii memory views aliased with `vm_remap` and with a `MAP_SHARED` file, and the task's VM bounds;
- Metal working while the guest space is held, plus GPU feature families and MetalFX support;
- which folders can be written, and `NSUserDefaults`;
- `SIGSEGV`/`SIGBUS` delivery and recovery;
- CPU features, stack sizes and display info.

## Run it

You need Xcode 27.x with the tvOS platform, `xcodegen` (`brew install xcodegen`), a paid or free Apple ID signed in to Xcode, and an Apple TV in developer mode paired with Xcode.

Find the Apple TV's identifier:

```bash
xcrun devicectl list devices
```

Run the probe on the TV:

```bash
Launcher/tvos/probe/run-probe.sh --team <TEAM_ID> --device <UDID>
```

Run it with the extended-virtual-addressing entitlement:

```bash
Launcher/tvos/probe/run-probe.sh --team <TEAM_ID> --device <UDID> --variant xva
```

Run only the address-space checks on this Mac:

```bash
Launcher/tvos/probe/run-probe.sh --host
```

- Reports go to `Launcher/tvos/probe/build/report-<variant>.txt`, and the full console to `console-<variant>.txt`.
- The app also writes `Library/Caches/tvprobe-report.txt` on the TV, which the script copies back.
- The default bundle ID is `org.wiicompiled.tvprobe.<team ID>`.
- Reports from earlier runs are kept in [`results/`](results).
