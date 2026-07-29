# iOSCopy roothide adaptation

## Baseline

- Imported archive SHA256: `333f9f7f15c439f139aa062a45d4d22c0cfe4e2d78078eef3319ce8a43fd53f1`
- Import commit: `5563481f1a1768f308f7cad98d078d9a624c0bb2`
- Working branch: `feat/roothide-adaptation`
- Source version: `1.8.0`
- Existing package scheme: `rootless`
- Existing deployment target: iOS 15.0
- Existing binary architectures: arm64 + arm64e

## Hypothesis

The runtime source is mostly relocatable already because `rootless.h` resolves jailbreak paths through libroot. Native roothide support requires a separate package scheme, real shared preference paths for sandboxed app processes, removal of fixed `/var/jb` comparisons, a roothide-compatible OCR daemon launch path, and a pinned arm64e cloud build.

## Success criteria

- One source tree builds rootless (`iphoneos-arm64`) and roothide (`iphoneos-arm64e`) packages.
- Main tweak, InputBridge, PastedBridge, preference bundle, and OCR worker contain arm64 + arm64e.
- roothide binaries are built on macOS 14 with Xcode 15.4 and the system iPhoneOS 17.5 SDK.
- Cloud logs contain no `incompatible arm64e` warning.
- roothide package metadata, paths, dylib install names, signatures, minimum OS, and SDK are verified after extraction.
- No fixed `/var/jb` runtime path remains in roothide launch configuration or source path comparisons.
- libSandy still grants access to the real `/var/mobile/Library/Preferences` coordination files used by app processes.

## Independent failure signals

- Any package component is missing arm64 or arm64e.
- Build logs contain `incompatible arm64e`.
- OCR daemon resolves to `/var/jb` on roothide or cannot execute the installed worker.
- InputBridge cannot load libSandy or cannot read/write shared coordination files.
- Package architecture is not `iphoneos-arm64e` for roothide.
- A binary has an unexpected install name, unsigned slice, minimum OS, or SDK.

## Evidence plan

1. Record baseline rootless build result.
2. Audit all path, package, launchd, dependency, and architecture references.
3. Implement dual-scheme build and scheme-aware launch assets.
4. Run source/static validation and local compile smoke checks.
5. Run pinned cloud rootless + roothide builds.
6. Scan logs and extract/inspect both packages before delivery.

## Progress

- [x] Imported source into a git repository and locked the baseline.
- [x] Confirmed partial libroot/roothide runtime support already exists.
- [x] Confirmed original local build currently fails at link time on `___isOSVersionAtLeast`; this is a baseline/toolchain issue, not introduced by the adaptation.
- [x] Implement dual-scheme build configuration.
- [x] Implement scheme-aware OCR launch configuration.
- [x] Remove fixed rootless-only runtime comparisons.
- [ ] Add pinned cloud build and package verification.
- [ ] Complete final evidence bundle.

## Build hook fix (2026-07-30)

- **Problem**: `after-stage` hook ran before Theos applied `THEOS_PACKAGE_INSTALL_PREFIX` (/var/jb for rootless). Script looked for files at `$STAGING_DIR/var/jb/Library/...` but they were at `$STAGING_DIR/Library/...`.
- **Fix**: Moved hook to `before-package`. Script now uses `$STAGING_DIR/Library/...` without install prefix.
- **Verification**: Both rootless (arm64) and roothide (arm64e) packages build and verify locally.
  - Rootless: worker=`/var/jb/usr/local/bin/iOSCopyOCRWorker`, libSandy with `/var/jb/var/mobile/...` paths
  - Roothide: worker=`/usr/local/bin/iOSCopyOCRWorker` (logical, patched by pkg mgr), libSandy with `/rootfs/var/mobile/...` paths

## Resume hint

Continue on `feat/roothide-adaptation` next step: pinned cloud build (GitHub Actions with macos-14, Xcode 15.4, SDK 17.5).
