# Roothide build and packaging

## Supported schemes

The source tree supports two package schemes:

- `rootless`: package architecture `iphoneos-arm64`, staged under `/var/jb`
- `roothide`: package architecture `iphoneos-arm64e`, staged at the logical jailbreak root

Both builds contain arm64 and arm64e slices and target iOS 15.0 or newer.

## Runtime paths

Runtime jailbreak paths must be resolved through libroot (`rootless.h`, `JBROOT_PATH_*`, or helpers in `Shared/PBPathUtilities.h`). Do not compare against a fixed `/var/jb` path. Roothide uses a randomized `.jbroot-*` directory.

App-process coordination files intentionally use the real `/var/mobile/Library/Preferences` directory on roothide. During roothide staging, the libSandy profile adds matching `/rootfs/var/mobile/Library/Preferences` extension paths, following the native roothide libSandy convention. Rootless retains `/var/jb/var/mobile/Library/Preferences` extensions.

Database, media, OCR, and universal-inbox paths are all derived from the cached `PBIOSCopyDataDirectoryPath()` resolver. This keeps every process on the same runtime-resolved jbroot path.

## OCR LaunchDaemon

The source plist stores the logical worker path:

```text
/usr/local/bin/iOSCopyOCRWorker
```

For rootless packaging, `scripts/patch-staged-launchd.sh` changes the staged plist to `/var/jb/usr/local/bin/iOSCopyOCRWorker`. For roothide, the logical path is left intact; the roothide package manager patches it to the active randomized jbroot during installation. The same staging script converts rootless libSandy extension paths to the roothide `/rootfs` form.

Maintainer scripts probe `/Library/LaunchDaemons` first for native roothide and `/var/jb/Library/LaunchDaemons` second for rootless.

## Reproducible cloud build

The GitHub Actions workflow pins:

- runner: `macos-14`
- Xcode: 15.4 (`15F31d`)
- Apple clang: Xcode 15.4 toolchain
- roothide Theos: `88506b2c22e9e07dd4ed055f23c9e398a117a2c7`
- Theos SDK repository: `0222fd5413cf4b9af096f37b4621afa2688572f7`
- roothide SDK: Xcode system iPhoneOS 17.5
- rootless SDK: Theos iPhoneOS 16.5

The roothide build uses the system 17.5 SDK and only adds the iPhoneOS 16.5 private-framework directory for the Preferences link stub.

## Verification

The workflow rejects packages when:

- the build log contains `incompatible arm64e`
- package architecture does not match the selected scheme
- any expected binary is missing arm64 or arm64e
- code signatures, minimum OS, or SDK load commands are wrong
- roothide tweak install names do not use `@loader_path/.jbroot/`
- the roothide launch plist or a shipped binary contains a fixed `/var/jb` path
- the libSandy profile does not grant the real preferences path

Run package verification on macOS with:

```bash
scripts/verify-package.sh roothide 17.5 packages/<package>.deb
scripts/verify-package.sh rootless 16.5 packages/<package>.deb
```

Do not deliver a locally built roothide package. Local Linux/Theos builds may use an incompatible arm64e ABI compiler. Deliver only the pinned macOS cloud artifact after its log and package checks pass.
