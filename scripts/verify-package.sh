#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s <rootless|roothide> <expected-sdk> <package.deb>\n' "$0" >&2
  exit 2
fi

scheme="$1"
expected_sdk="$2"
deb="$3"

case "$scheme" in
  rootless)
    expected_arch="iphoneos-arm64"
    package_prefix="/var/jb"
    expected_worker_path="/var/jb/usr/local/bin/iOSCopyOCRWorker"
    ;;
  roothide)
    expected_arch="iphoneos-arm64e"
    package_prefix=""
    expected_worker_path="/usr/local/bin/iOSCopyOCRWorker"
    ;;
  *)
    printf 'error: unsupported package scheme: %s\n' "$scheme" >&2
    exit 2
    ;;
esac

[[ -s "$deb" ]] || { printf 'error: package is missing or empty: %s\n' "$deb" >&2; exit 1; }
[[ "$(dpkg-deb -f "$deb" Package)" == "com.newbie.ioscopy" ]]
[[ "$(dpkg-deb -f "$deb" Architecture)" == "$expected_arch" ]]

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
root="$workdir/root"
control="$workdir/control"
dpkg-deb -x "$deb" "$root"
dpkg-deb -e "$deb" "$control"

relative_binaries=(
  "/Library/MobileSubstrate/DynamicLibraries/iOSCopy.dylib"
  "/Library/MobileSubstrate/DynamicLibraries/iOSCopyInputBridge.dylib"
  "/Library/MobileSubstrate/DynamicLibraries/iOSCopyPastedBridge.dylib"
  "/Library/PreferenceBundles/iOSCopyPrefs.bundle/iOSCopyPrefs"
  "/usr/local/bin/iOSCopyOCRWorker"
)

for relative in "${relative_binaries[@]}"; do
  binary="$root$package_prefix$relative"
  [[ -s "$binary" ]] || { printf 'error: expected binary missing: %s\n' "$binary" >&2; exit 1; }
  lipo "$binary" -verify_arch arm64 arm64e

  load_commands="$workdir/$(basename "$relative").load-commands"
  otool -l "$binary" > "$load_commands"
  grep -q 'LC_CODE_SIGNATURE' "$load_commands"
  [[ "$(awk '$1 == "minos" { print $2 }' "$load_commands" | sort -u)" == "15.0" ]]
  [[ "$(awk '$1 == "sdk" { print $2 }' "$load_commands" | sort -u)" == "$expected_sdk" ]]
done

for dylib in \
  "$root$package_prefix/Library/MobileSubstrate/DynamicLibraries/iOSCopy.dylib" \
  "$root$package_prefix/Library/MobileSubstrate/DynamicLibraries/iOSCopyInputBridge.dylib" \
  "$root$package_prefix/Library/MobileSubstrate/DynamicLibraries/iOSCopyPastedBridge.dylib"; do
  install_names="$workdir/$(basename "$dylib").install-names"
  otool -D "$dylib" > "$install_names"
  if [[ "$scheme" == "roothide" ]]; then
    grep -q '@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/' "$install_names"
  fi
done

launchd_plist="$root$package_prefix/Library/LaunchDaemons/com.ssdsl.ioscopy.ocrd.plist"
[[ -s "$launchd_plist" ]]
python3 - "$launchd_plist" "$expected_worker_path" <<'PY'
import plistlib
import sys

path, expected_worker = sys.argv[1:]
with open(path, "rb") as handle:
    payload = plistlib.load(handle)
arguments = payload.get("ProgramArguments")
if not isinstance(arguments, list) or not arguments or arguments[0] != expected_worker:
    raise SystemExit(
        f"unexpected OCR worker path: {arguments!r}; expected first argument {expected_worker!r}"
    )
PY

libsandy_profile="$root$package_prefix/Library/libSandy/iOSCopyInputBridge.plist"
[[ -s "$libsandy_profile" ]]
grep -q '/var/mobile/Library/Preferences/com.ssdsl.ioscopy.plist' "$libsandy_profile"
if [[ "$scheme" == "roothide" ]]; then
  grep -q '/rootfs/var/mobile/Library/Preferences/com.ssdsl.ioscopy.plist' "$libsandy_profile"
  ! grep -q '/var/jb/' "$libsandy_profile"
  ! grep -q '/var/jb/' "$launchd_plist"
  for relative in "${relative_binaries[@]}"; do
    ! strings "$root$package_prefix$relative" | grep -q '/var/jb/'
  done
else
  grep -q '/var/jb/var/mobile/Library/Preferences/com.ssdsl.ioscopy.plist' "$libsandy_profile"
fi

for script in "$control/preinst" "$control/postinst" "$control/prerm" "$control/postrm"; do
  [[ ! -f "$script" ]] || sh -n "$script"
done

printf 'verified %s package: %s\n' "$scheme" "$deb"
