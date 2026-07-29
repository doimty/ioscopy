#!/usr/bin/env bash
set -euo pipefail

: "${IOSCOPY_PACKAGE_SCHEME:?IOSCOPY_PACKAGE_SCHEME is required}"
: "${IOSCOPY_STAGING_DIR:?IOSCOPY_STAGING_DIR is required}"

# Theos applies THEOS_PACKAGE_INSTALL_PREFIX as a directory move during
# internal-package. At before-package time, layout/ has been rsynced into
# staging dir but the prefix directory does not exist yet. All paths below
# are relative to the staging dir root, without the install prefix.
install_prefix="${IOSCOPY_INSTALL_PREFIX:-}"
plist="${IOSCOPY_STAGING_DIR}/Library/LaunchDaemons/com.ssdsl.ioscopy.ocrd.plist"
libsandy_profile="${IOSCOPY_STAGING_DIR}/Library/libSandy/iOSCopyInputBridge.plist"

for staged_file in "$plist" "$libsandy_profile"; do
  if [[ ! -f "$staged_file" ]]; then
    printf 'error: staged package file not found: %s\n' "$staged_file" >&2
    exit 1
  fi
done

case "$IOSCOPY_PACKAGE_SCHEME" in
  roothide)
    worker_path="/usr/local/bin/iOSCopyOCRWorker"
    ;;
  rootless)
    worker_path="/var/jb/usr/local/bin/iOSCopyOCRWorker"
    ;;
  *)
    printf 'error: unsupported package scheme: %s\n' "$IOSCOPY_PACKAGE_SCHEME" >&2
    exit 1
    ;;
esac

python3 - "$plist" "$worker_path" "$libsandy_profile" "$IOSCOPY_PACKAGE_SCHEME" <<'PY'
import plistlib
import sys

plist_path, worker_path, profile_path, scheme = sys.argv[1:]
with open(plist_path, "rb") as handle:
    payload = plistlib.load(handle)

arguments = payload.get("ProgramArguments")
if not isinstance(arguments, list) or not arguments:
    raise SystemExit(f"error: ProgramArguments missing from {plist_path}")
arguments[0] = worker_path

with open(plist_path, "wb") as handle:
    plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)

with open(profile_path, "rb") as handle:
    profile = plistlib.load(handle)

extensions = profile.get("Extensions")
if not isinstance(extensions, list):
    raise SystemExit(f"error: Extensions missing from {profile_path}")

if scheme == "roothide":
    rootless_prefix = "/var/jb/var/mobile/Library/Preferences/"
    roothide_prefix = "/rootfs/var/mobile/Library/Preferences/"
    for extension in extensions:
        path = extension.get("path") if isinstance(extension, dict) else None
        if isinstance(path, str) and path.startswith(rootless_prefix):
            extension["path"] = roothide_prefix + path[len(rootless_prefix):]

with open(profile_path, "wb") as handle:
    plistlib.dump(profile, handle, fmt=plistlib.FMT_XML, sort_keys=False)
PY
