#!/usr/bin/env python3
"""Turn the CMake-built tvOS WiiCompiled.app into an app that installs on an Apple TV.

    package_app.py --app build-tvos/WiiCompiled.app --out build-tvos/package --team TEAMID
                   [--device UDID] [--bundle-id ID] [--data bundle|caches] [--assets Assets]

The CMake build already put the executable and the runtime's assets (dsp_coef.bin, wii_bootstrap,
initial_pipeline_cache.db, cacert.pem) in the bundle root. This copies the bundle and then:
  - writes Info.plist from Launcher/tvos/Info.plist (bundle ID, versions, SDK keys);
  - builds the layered Apple TV icon and Top Shelf images from runtime/resources/WiiCompiled.icns
    (tv_icon.swift, then actool) and merges actool's icon keys into Info.plist;
  - with --data bundle (the default), clones Assets/DATA into the bundle, which tvOS never purges;
    with --data caches, leaves it out for build-tvos.command to push into Library/Caches once;
  - signs it with a profile that covers the bundle ID (its own App ID or a wildcard), first having
    Xcode create one (Launcher/tvos/provision) when none has been downloaded yet. The app needs no
    special entitlements: the guest space claims its slot before UIKit starts (M6), so it no longer
    asks for extended virtual addressing.
Prints the packaged app's path on its last line.
"""
import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # python3 -I leaves the script's folder off sys.path
import tvos_signing  # noqa: E402

REPO = HERE.parent.parent


def fail(message):
    print(f"package_app: {message}", file=sys.stderr)
    sys.exit(1)


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        fail(f"{' '.join(str(a) for a in args[:3])} failed:\n{(result.stderr or result.stdout).strip()[-3000:]}")
    return result.stdout


def clone_tree(source, destination):
    # APFS clones: the 2.5 GB of game data costs no extra disk and copies in seconds.
    run(["cp", "-cR", str(source), str(destination)])


def sdk_value(flag):
    return run(["xcrun", "--sdk", "appletvos", flag]).strip()


def minimum_os(executable):
    out = run(["xcrun", "vtool", "-show-build", str(executable)])
    match = re.search(r"minos\s+([0-9.]+)", out)
    return match.group(1) if match else "26.0"


def app_version():
    props = REPO / "Launcher" / "Directory.Build.props"
    if props.exists():
        match = re.search(r"<Version>([^<]+)</Version>", props.read_text())
        if match:
            return re.sub(r"[^0-9.].*$", "", match.group(1)) or "0.1.0"
    return "0.1.0"


def write_info_plist(app, bundle_id, work):
    with open(HERE / "Info.plist", "rb") as f:
        info = plistlib.load(f)
    version = app_version()
    info.update({
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        # Monotonic, so a reinstall always counts as an update.
        "CFBundleVersion": run(["date", "+%Y%m%d.%H%M%S"]).strip(),
        "MinimumOSVersion": minimum_os(app / info["CFBundleExecutable"]),
        "DTPlatformName": "appletvos",
        "DTPlatformVersion": sdk_value("--show-sdk-version"),
        "DTSDKName": "appletvos" + sdk_value("--show-sdk-version"),
        "DTSDKBuild": sdk_value("--show-sdk-build-version"),
    })
    icon_keys = build_icon(app, info["MinimumOSVersion"], work)
    info.update(icon_keys)
    with open(app / "Info.plist", "wb") as f:
        plistlib.dump(info, f)


def build_icon(app, min_os, work):
    source = REPO / "runtime" / "resources" / "WiiCompiled.icns"
    png = work / "icon.png"
    run(["sips", "-s", "format", "png", str(source), "--out", str(png)])
    catalog = work / "Assets.xcassets"
    run(["xcrun", "swift", str(HERE / "tv_icon.swift"), str(png), str(catalog)])
    partial = work / "icon-info.plist"
    run(["xcrun", "actool", str(catalog), "--compile", str(app), "--platform", "appletvos",
         "--minimum-deployment-target", min_os, "--target-device", "tv", "--app-icon", "AppIcon",
         "--output-partial-info-plist", str(partial), "--output-format", "human-readable-text"])
    with open(partial, "rb") as f:
        return plistlib.load(f)


def ensure_profile(team, bundle_id, device, work):
    found = tvos_signing.find_profile(team, bundle_id, device)
    if found:
        return found
    print(f"package_app: asking Xcode for a provisioning profile for {bundle_id}")
    build = work / "provision"
    build.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, DEVELOPMENT_TEAM=team, PROVISION_BUNDLE_ID=bundle_id,
               PROVISION_ENTITLEMENTS=str(HERE / "WiiCompiled.entitlements"), PROVISION_BUILD_DIR=str(build))
    run(["xcodegen", "generate", "--quiet", "--spec", str(HERE / "provision" / "project.yml"),
         "--project-root", str(HERE / "provision"), "--project", str(build)], env=env)
    run(["xcodebuild", "-project", str(build / "WiiCompiledProvisioning.xcodeproj"), "-scheme", "WiiCompiledProvisioning",
         "-configuration", "Release", "-destination", "generic/platform=tvOS", "-derivedDataPath", str(build / "dd"),
         "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "build"], env=env)
    found = tvos_signing.find_profile(team, bundle_id, device)
    if not found:
        fail(f"Xcode made no profile for {bundle_id}; sign in to the team under Xcode > Settings > Accounts "
             "and pair the Apple TV with Xcode")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the CMake-built WiiCompiled.app")
    parser.add_argument("--out", required=True, help="folder that receives the packaged WiiCompiled.app")
    parser.add_argument("--team", required=True)
    parser.add_argument("--device", default="", help="Apple TV UDID the profile must include")
    parser.add_argument("--bundle-id", default=None, help="default: org.wiicompiled.WiiCompiled.<team>")
    parser.add_argument("--data", choices=("bundle", "caches"), default="bundle")
    parser.add_argument("--assets", default=str(REPO / "Assets"))
    args = parser.parse_args()
    source = Path(args.app).resolve()
    if not (source / "WiiCompiled").is_file():
        fail(f"{source} has no WiiCompiled executable; build the WiiCompiled target for tvOS first")
    bundle_id = args.bundle_id or f"org.wiicompiled.WiiCompiled.{args.team.lower()}"
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    app = out / "WiiCompiled.app"
    if app.exists():
        shutil.rmtree(app)
    clone_tree(source, app)
    for stale in ("embedded.mobileprovision", "_CodeSignature", "DATA"):
        target = app / stale
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()

    with tempfile.TemporaryDirectory(prefix="mkw-tvpackage-") as tmp:
        # Resolved: /var is a symlink to /private/var, which breaks xcodegen's relative paths.
        work = Path(tmp).resolve()
        write_info_plist(app, bundle_id, work)
        if args.data == "bundle":
            data = Path(args.assets) / "DATA"
            if not (data / "sys" / "fst.bin").is_file():
                fail(f"no extracted game data at {data}; run the build with --game first")
            clone_tree(data, app / "DATA")
        profile_path, profile = ensure_profile(args.team, bundle_id, args.device, work)
        try:
            tvos_signing.sign_bundle(app, profile_path, profile, args.team, bundle_id, work=work)
        except tvos_signing.SigningError as error:
            fail(str(error))
    print(f"package_app: signed {bundle_id} with {profile.get('Name')}")
    print(app)


if __name__ == "__main__":
    main()
