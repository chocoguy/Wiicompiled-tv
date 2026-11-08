"""Signing helpers shared by the tvOS scripts (run_on_device.py, package_app.py).

A tvOS bundle installs on a device only when it carries a provisioning profile that covers its
bundle ID and the device, and is signed with a development certificate that profile lists. These
helpers find both among what Xcode has already downloaded (or created with automatic signing), and
sign with exactly the entitlements the caller asks for, which the profile must grant.
"""
import datetime
import hashlib
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

PROFILE_DIRS = [
    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    Path.home() / "Library/MobileDevice/Provisioning Profiles",
]


class SigningError(Exception):
    pass


def decode_profile(path):
    out = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
    if out.returncode != 0:
        return None
    try:
        return plistlib.loads(out.stdout)
    except Exception:
        return None


def _grants(profile, entitlements):
    granted = profile.get("Entitlements", {})
    for key, value in entitlements.items():
        if key in ("application-identifier", "com.apple.developer.team-identifier", "get-task-allow"):
            continue
        if granted.get(key) != value:
            return False
    return True


def find_profile(team, bundle_id, device, entitlements=None, exact_only=False):
    """The newest valid tvOS profile of `team` covering `bundle_id` and `device` that grants
    `entitlements`. An exact App ID beats a wildcard. Returns (path, profile) or None."""
    now = datetime.datetime.now(datetime.timezone.utc)
    best = None
    for folder in PROFILE_DIRS:
        if not folder.is_dir():
            continue
        for path in folder.iterdir():
            if path.suffix != ".mobileprovision":
                continue
            p = decode_profile(path)
            if not p or "tvOS" not in p.get("Platform", []) or team not in p.get("TeamIdentifier", []):
                continue
            expires = p.get("ExpirationDate")
            if expires and expires.replace(tzinfo=datetime.timezone.utc) < now:
                continue
            if device and not p.get("ProvisionsAllDevices") and device not in p.get("ProvisionedDevices", []):
                continue
            app_id = p.get("Entitlements", {}).get("application-identifier", "")
            if app_id == f"{team}.{bundle_id}":
                rank = 2
            elif not exact_only and app_id.endswith(".*") and f"{team}.{bundle_id}".startswith(app_id[:-1]):
                rank = 1
            else:
                continue
            if entitlements and not _grants(p, entitlements):
                continue
            key = (rank, p.get("CreationDate") or datetime.datetime.min)
            if best is None or key > best[0]:
                best = (key, path, p)
    return (best[1], best[2]) if best else None


def find_identity(profile):
    """The SHA-1 of a valid codesigning identity whose certificate the profile lists."""
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                         capture_output=True, text=True).stdout
    for sha1 in re.findall(r"\)\s+([0-9A-F]{40})\s+\"", out):
        if sha1 in allowed:
            return sha1
    raise SigningError("no valid codesigning identity in the keychain matches the provisioning profile's certificates")


def sign_bundle(app, profile_path, profile, team, bundle_id, extra_entitlements=None, work=None):
    """Embed the profile and sign `app` (nested code first) with the base entitlements plus extras."""
    app = Path(app)
    shutil.copy2(profile_path, app / "embedded.mobileprovision")
    entitlements = {
        "application-identifier": f"{team}.{bundle_id}",
        "com.apple.developer.team-identifier": team,
        "get-task-allow": bool(profile.get("Entitlements", {}).get("get-task-allow", True)),
    }
    entitlements.update(extra_entitlements or {})
    ent_path = Path(work or app.parent) / f"{app.stem}.entitlements.plist"
    with open(ent_path, "wb") as f:
        plistlib.dump(entitlements, f)
    identity = find_identity(profile)
    for nested in sorted(app.rglob("*")):
        if nested.suffix in (".dylib", ".framework") and nested.exists():
            _codesign(["--force", "--sign", identity, "--timestamp=none", str(nested)])
    _codesign(["--force", "--sign", identity, "--entitlements", str(ent_path), "--timestamp=none",
               "--generate-entitlement-der", str(app)])
    return entitlements


def _codesign(args):
    result = subprocess.run(["codesign", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise SigningError(f"codesign failed: {result.stderr.strip()}")
