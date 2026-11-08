#!/usr/bin/env python3
"""Run one tvOS test executable on a paired Apple TV and exit with its exit code.

runtime/CMakeLists.txt installs this as CMAKE_CROSSCOMPILING_EMULATOR when the tvOS build has
MKW_TVOS_TEST_DEVICE and MKW_TVOS_TEST_TEAM, so `ctest --test-dir build-tvos` runs the tests on the
TV. ctest appends the test executable (inside the .app bundle CMake makes for tvOS) and its arguments:

    run_on_device.py --device UDID --team TEAMID [--bundle-id ID] [--min-os 26.0] [--keep] -- APP/EXE [ARGS...]

For each run it copies the bundle, fills in the Info.plist keys tvOS requires, embeds a tvOS team
provisioning profile from Xcode's profile folder that covers the bundle ID and the device, signs it
with a development identity named in that profile, installs it, launches it with the console
attached, and uninstalls it again (--keep leaves it installed). Tests run one at a time: they share
one bundle ID, so do not use ctest -j with this runner.
"""
import argparse
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # python3 -I leaves the script's folder off sys.path
import tvos_signing  # noqa: E402

INFRA_FAILURE = 125  # what ctest sees when the runner itself could not run the test


def fail(message):
    print(f"run_on_device: {message}", file=sys.stderr)
    sys.exit(INFRA_FAILURE)


def stage_bundle(executable, bundle_id, min_os, work):
    exe = Path(executable).resolve()
    if not exe.is_file():
        fail(f"no such test executable: {exe}")
    source = exe.parent if exe.parent.suffix == ".app" else None
    name = exe.name
    app = work / f"{name}.app"
    if source:
        shutil.copytree(source, app, symlinks=True)
    else:
        app.mkdir(parents=True)
        shutil.copy2(exe, app / name)
    info_path = app / "Info.plist"
    info = {}
    if info_path.exists():
        with open(info_path, "rb") as f:
            info = plistlib.load(f)
    # Empty strings from CMake's default bundle template are not valid on a device.
    info = {k: v for k, v in info.items() if v != ""}
    info.update({
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": name,
        "CFBundleName": name[:15],
        "CFBundleDisplayName": name,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "CFBundleSupportedPlatforms": ["AppleTVOS"],
        "DTPlatformName": "appletvos",
        "MinimumOSVersion": min_os,
        "UIDeviceFamily": [3],
    })
    with open(info_path, "wb") as f:
        plistlib.dump(info, f)
    return app


def devicectl(*args, capture=True):
    return subprocess.run(["xcrun", "devicectl", *args], capture_output=capture, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", required=True, help="Apple TV UDID (xcrun devicectl list devices)")
    parser.add_argument("--team", required=True, help="Apple Developer team ID")
    parser.add_argument("--bundle-id", default=None, help="default: org.wiicompiled.tvtest.<team>")
    parser.add_argument("--min-os", default="26.0")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--keep", action="store_true", help="leave the test app installed")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        fail("no test executable given")
    bundle_id = args.bundle_id or f"org.wiicompiled.tvtest.{args.team.lower()}"

    found = tvos_signing.find_profile(args.team, bundle_id, args.device)
    if not found:
        fail(f"no tvOS provisioning profile of team {args.team} covers {bundle_id} on {args.device}; "
             "build any tvOS app for this team in Xcode once (or run Launcher/tvos/probe/run-probe.sh) "
             "so Xcode downloads a team profile")
    profile_path, profile = found
    with tempfile.TemporaryDirectory(prefix="mkw-tvtest-") as tmp:
        work = Path(tmp)
        app = stage_bundle(command[0], bundle_id, args.min_os, work)
        try:
            tvos_signing.sign_bundle(app, profile_path, profile, args.team, bundle_id, work=work)
        except tvos_signing.SigningError as error:
            fail(str(error))
        install = devicectl("device", "install", "app", "--device", args.device, str(app))
        if install.returncode != 0:
            fail(f"install failed: {(install.stderr or install.stdout).strip()}")
        try:
            launch = subprocess.run(
                ["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                 "--terminate-existing", "--console", "--timeout", str(args.timeout), bundle_id, *command[1:]],
                capture_output=True, text=True)
        finally:
            if not args.keep:
                devicectl("device", "uninstall", "app", "--device", args.device, bundle_id)
    # devicectl says "exit code 0" for a plain (non-UIKit) app however it ended, even after
    # return 3 or abort(), so its verdict is never used. The test's own entry point
    # (runtime/tests/tvos_test_entry.c) prints MKW-TVOS-TEST-EXIT=<status>, or
    # MKW-TVOS-TEST-SIGNAL=<n> on a crash; only an explicit EXIT=0 passes.
    output = (launch.stdout + launch.stderr).replace("\r", "")
    status = None
    for line in output.splitlines():
        exit_match = re.fullmatch(r"MKW-TVOS-TEST-EXIT=(-?\d+)", line.strip())
        signal_match = re.fullmatch(r"MKW-TVOS-TEST-SIGNAL=(\d+)", line.strip())
        if exit_match:
            status = int(exit_match.group(1)) & 0xFF
        elif signal_match:
            status = 128 + int(signal_match.group(1))
        elif not line.startswith(("Launched application with", "Waiting for the application to terminate",
                                  "The app terminated with the exit code")):
            print(line)
    if status is None:
        fail("the test ended without reporting a result (no MKW-TVOS-TEST-EXIT line): it crashed before its "
             "entry point ran, was killed, or was not linked with runtime/tests/tvos_test_entry.c")
    sys.exit(status)


if __name__ == "__main__":
    main()
