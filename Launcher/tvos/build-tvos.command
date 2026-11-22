#!/usr/bin/env bash
# Build WiiCompiled for an Apple TV and install it: extract -> translate -> cross-compile -> package
# and sign -> install -> (push the game data) -> (launch). See docs/tvos-porting-plan.md, M3.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd "$script_dir/../.." && pwd)
fail() { printf 'build-tvos.command: error: %s\n' "$*" >&2; exit 1; }
step() { printf 'MKWCBUILD:STEP:%s %s\n' "$1" "$2"; }

usage() {
    cat <<'EOF'
Usage: Launcher/tvos/build-tvos.command --team TEAM_ID --device UDID [options]

  --team TEAM_ID              Apple Developer team that signs the app (a free team's installs expire after 7 days) (Xcode > Settings > Accounts)
  --device UDID               Paired Apple TV in developer mode (xcrun devicectl list devices)
  --game IMAGE --nodtool PATH Extract and verify a clean disc image into Assets/ first
  --data bundle|caches        Where the 2.5 GB of game data goes (default: bundle)
                                bundle: inside the app; tvOS never purges it, every install sends it
                                caches: pushed once into Library/Caches/WiiCompiled/DATA; reinstalls
                                        send only the code, but tvOS may purge it (rerun to resend)
  --bundle-id ID              Default: org.wiicompiled.WiiCompiled.<team ID, lower case>
  --build-dir DIR             Default: build-tvos
  --no-install                Stop after packaging (build-dir/package/WiiCompiled.app)
  --launch                    Launch after installing, with the console attached, then fetch the logs
  --parallel N                Pin translation and build parallelism
EOF
}

team=""; device=""; game=""; nodtool=""; data=bundle; bundle_id=""; build_dir="$workspace/build-tvos"
install=1; launch=0; parallel=0
while (($#)); do
    case "$1" in
        --team) team=${2:-}; shift 2 ;;
        --device) device=${2:-}; shift 2 ;;
        --game) game=${2:-}; shift 2 ;;
        --nodtool) nodtool=${2:-}; shift 2 ;;
        --data) data=${2:-}; shift 2 ;;
        --bundle-id) bundle_id=${2:-}; shift 2 ;;
        --build-dir) build_dir=${2:-}; shift 2 ;;
        --no-install) install=0; shift ;;
        --launch) launch=1; shift ;;
        --parallel) parallel=${2:-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown option: $1" ;;
    esac
done
[[ -n "$team" ]] || fail '--team is required'
(( install == 0 )) || [[ -n "$device" ]] || fail '--device is required (or pass --no-install)'
case "$data" in bundle|caches) ;; *) fail '--data must be bundle or caches' ;; esac
bundle_id=${bundle_id:-org.wiicompiled.WiiCompiled.$(printf '%s' "$team" | tr '[:upper:]' '[:lower:]')}
for tool in cmake ninja xcodegen python3 xcrun; do command -v "$tool" >/dev/null || fail "required tool not found: $tool"; done
xcrun --sdk appletvos --show-sdk-path >/dev/null 2>&1 || fail 'the tvOS SDK is missing (Xcode > Settings > Components)'

# 1-2. Extract and translate with the macOS driver: the translated C++ is the same for every host.
# The translator targets .NET 8; with only a newer runtime installed, let it roll forward.
if ! dotnet --list-runtimes 2>/dev/null | grep -q '^Microsoft.NETCore.App 8\.'; then export DOTNET_ROLL_FORWARD=Major; fi
translate=("$workspace/Launcher/local-build-macos.command" --translate-only --profile base)
[[ -n "$game" ]] && translate+=(--game "$game" --nodtool "$nodtool")
(( parallel > 0 )) && translate+=(--parallel "$parallel")
"${translate[@]}"

# 3. Cross-compile. Translated shards are the memory-hungry compiles: cap them at half the RAM in GiB.
cpu=$(sysctl -n hw.ncpu); mem_gib=$(( $(sysctl -n hw.memsize) / 1073741824 ))
jobs=$(( parallel > 0 ? parallel : cpu )); translated_jobs=$(( jobs < mem_gib / 2 ? jobs : mem_gib / 2 ))
(( translated_jobs < 1 )) && translated_jobs=1
step configure-tvos 'Configuring the tvOS build'
cmake -S "$workspace/runtime" -B "$build_dir" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT=appletvos -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DMKW_BUILD_PRODUCTS=ON -DMKW_TRANSLATED_COMPILE_JOBS="$translated_jobs" >/dev/null
step compile-tvos 'Compiling WiiCompiled for tvOS'
cmake --build "$build_dir" --target WiiCompiled --parallel "$jobs"

# 4. Info.plist, icon, game data (bundle mode), provisioning and signature.
step package 'Packaging and signing the Apple TV app'
app=$(python3 -I "$script_dir/package_app.py" --app "$build_dir/WiiCompiled.app" --out "$build_dir/package" \
    --team "$team" --device "$device" --bundle-id "$bundle_id" --data "$data" --assets "$workspace/Assets" | tail -n 1)
[[ -d "$app" ]] || fail 'packaging did not produce an app'
if (( install == 0 )); then printf 'MKWCBUILD:OUTPUT=%s\n' "$app"; exit 0; fi

container=(--device "$device" --domain-type appDataContainer --domain-identifier "$bundle_id")
step install "Installing $bundle_id on the Apple TV"
xcrun devicectl device install app --device "$device" "$app" >/dev/null

# 5. Caches mode: send the data only when the TV's copy is missing or from another disc image.
if [[ "$data" == caches ]]; then
    manifest="$workspace/Assets/.data-manifest"
    [[ -f "$manifest" ]] || fail "no $manifest; run with --game first"
    remote_manifest=$(mktemp -t mkw-tv-manifest)
    if xcrun devicectl device copy from "${container[@]}" --source Library/Caches/WiiCompiled/DATA.manifest \
            --destination "$remote_manifest" >/dev/null 2>&1 && cmp -s "$manifest" "$remote_manifest"; then
        step data 'Game data already on the Apple TV'
    else
        step data 'Sending the game data to the Apple TV (2.5 GB, once)'
        xcrun devicectl device copy to "${container[@]}" --source "$workspace/Assets/DATA" \
            --destination Library/Caches/WiiCompiled/DATA >/dev/null
        xcrun devicectl device copy to "${container[@]}" --source "$manifest" \
            --destination Library/Caches/WiiCompiled/DATA.manifest >/dev/null
    fi
    rm -f "$remote_manifest"
fi

# 6-7. Launch with the console attached; afterwards fetch the runtime's logs.
if (( launch )); then
    step launch 'Launching (the console stays attached until the app exits; the TV button leaves it)'
    xcrun devicectl device process launch --device "$device" --terminate-existing --console "$bundle_id" || true
    logs="$build_dir/device-logs"
    rm -rf "$logs"; mkdir -p "$logs"
    xcrun devicectl device copy from "${container[@]}" --source Library/Caches/WiiCompiled/Logs \
        --destination "$logs" >/dev/null 2>&1 && step logs "Runtime logs copied to $logs"
fi
printf 'MKWCBUILD:OUTPUT=%s\n' "$app"
