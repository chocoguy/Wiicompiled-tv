#!/bin/bash
# Builds, installs and runs the WiiCompiled tvOS feasibility probe on a paired Apple TV, then saves its report.
#   Launcher/tvos/probe/run-probe.sh --team TEAMID --device UDID [--variant plain|xva] [--bundle-id ID] [--out DIR]
#   Launcher/tvos/probe/run-probe.sh --host        (address-space checks only, on this Mac)
# --variant xva adds the extended-virtual-addressing entitlement (XVA.entitlements).
# The default bundle ID is org.wiicompiled.tvprobe.<team ID>, registered under that team by automatic signing.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
team=${DEVELOPMENT_TEAM:-}
device=""
variant=plain
bundle=""
out="$here/build"
host=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team) team=$2; shift 2 ;;
        --device) device=$2; shift 2 ;;
        --variant) variant=$2; shift 2 ;;
        --bundle-id) bundle=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --host) host=1; shift ;;
        -h | --help) sed -n 2,6p "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
mkdir -p "$out"

if [[ $host == 1 ]]; then
    clang -O1 -Wall -Wextra -o "$out/probe-host" "$here/Sources/probe_vm.c" "$here/host/host_main.c"
    "$out/probe-host" "$out" | sed 's/^PROBE //' | tee "$out/report-host.txt"
    exit 0
fi

[[ -n $team && -n $device ]] || { echo "--team and --device are required (see: xcrun devicectl list devices)" >&2; exit 2; }
case $variant in
    plain) entitlements="" ;;
    xva) entitlements="$here/XVA.entitlements" ;;
    *) echo "--variant must be plain or xva" >&2; exit 2 ;;
esac
team_lower=$(printf '%s' "$team" | tr '[:upper:]' '[:lower:]')
bundle=${bundle:-org.wiicompiled.tvprobe.$team_lower}
build="$out/$variant"
mkdir -p "$build"

export DEVELOPMENT_TEAM="$team" PROBE_BUNDLE_ID="$bundle" PROBE_ENTITLEMENTS="$entitlements" \
    PROBE_VARIANT="$variant" PROBE_BUILD_DIR="$build"
echo "== xcodegen ($variant, $bundle)"
xcodegen generate --quiet --spec "$here/project.yml" --project "$build"

echo "== xcodebuild (log: $build/xcodebuild.log)"
if ! xcodebuild -project "$build/TVProbe.xcodeproj" -scheme TVProbe -configuration Release \
    -destination 'generic/platform=tvOS' -derivedDataPath "$build/dd" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >"$build/xcodebuild.log" 2>&1; then
    grep -E "error:|warning: .*entitlement|Provisioning|requires a provisioning" "$build/xcodebuild.log" | sort -u | head -20 >&2
    echo "xcodebuild failed; see $build/xcodebuild.log" >&2
    exit 1
fi
app="$build/dd/Build/Products/Release-appletvos/TVProbe.app"
codesign -d --entitlements - "$app" 2>/dev/null | grep -A1 -E "extended-virtual|team-identifier" || true

echo "== install on $device"
xcrun devicectl device install app --device "$device" "$app" >"$build/install.log" 2>&1 || { cat "$build/install.log" >&2; exit 1; }

echo "== launch (console: $out/console-$variant.txt)"
xcrun devicectl device process launch --device "$device" --terminate-existing --console --timeout 300 \
    -e '{"PROBE_EXIT":"1"}' "$bundle" >"$out/console-$variant.txt" 2>&1 || true
grep '^PROBE ' "$out/console-$variant.txt" | sed 's/^PROBE //' >"$out/report-$variant.txt" || true

# The app also writes its report into its own caches; fetch it in case the console missed lines.
xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle" \
    --source Library/Caches/tvprobe-report.txt --destination "$out/device-report-$variant.txt" >/dev/null 2>&1 || true

if [[ -s "$out/report-$variant.txt" ]]; then
    echo "== report: $out/report-$variant.txt"
elif [[ -s "$out/device-report-$variant.txt" ]]; then
    echo "== report (copied from the device): $out/device-report-$variant.txt"
else
    echo "no report captured; see $out/console-$variant.txt" >&2
    exit 1
fi
