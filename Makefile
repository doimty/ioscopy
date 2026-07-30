export ARCHS = arm64 arm64e

THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
export TARGET = iphone:clang:17.5:15.0
IOSCOPY_FORCE_REAL_PREFERENCES_PATH ?= 1
IOSCOPY_SUPPRESS_MACRO_REDEFINED ?= 1
else
export TARGET = iphone:clang:16.5:15.0
IOSCOPY_FORCE_REAL_PREFERENCES_PATH ?= 0
IOSCOPY_SUPPRESS_MACRO_REDEFINED ?= 0
endif
export IOSCOPY_FORCE_REAL_PREFERENCES_PATH

DEBUG_LOG ?= 0
export DEBUG_LOG

IOSCOPY_PRIVATE_FRAMEWORKS_DIR ?=
export IOSCOPY_PRIVATE_FRAMEWORKS_DIR

INSTALL_TARGET_PROCESSES = SpringBoard pasted

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = iOSCopy

iOSCopy_FILES = Tweak.xm \
	Shared/PBLocalization.m \
	Manager/PBInputBridge.m \
	Manager/PBInputBridgeRequestClient.m \
	Manager/PBInputBridgeSourceState.m \
	Manager/PBInputBridgePasteState.m \
	Manager/PBInputBridgeOutgoingSuppression.m \
	Manager/PBInputBridgeSpringBoardCapture.m \
	Manager/PBInputBridgeSpringBoardReadAuth.m \
	Manager/PBInputBridgeUniversalInbox.m \
	Manager/PBInputBridgeImagePasteboard.m \
	Manager/PBClipboardManager.m \
	Manager/PBStorageManager.m \
	$(wildcard Model/*.m) \
	UI/PBAppIconProvider.m \
	UI/PBMainViewController.m \
	UI/PBSnippetCollectionCell.m

ifeq ($(DEBUG_LOG),1)
iOSCopy_FILES += \
	Shared/PBDiagnosticLogger.m \
	Manager/PBInputBridgeDiagnostics.m
endif

iOSCopy_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DDEBUG_LOG=$(DEBUG_LOG) -DIOSCOPY_FORCE_REAL_PREFERENCES_PATH=$(IOSCOPY_FORCE_REAL_PREFERENCES_PATH)
ifeq ($(IOSCOPY_SUPPRESS_MACRO_REDEFINED),1)
iOSCopy_CFLAGS += -Wno-macro-redefined -Wno-ambiguous-macro
endif
iOSCopy_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO
iOSCopy_PRIVATE_FRAMEWORKS =
iOSCopy_LIBRARIES = sqlite3
ifeq ($(IOSCOPY_SUPPRESS_MACRO_REDEFINED),1)
iOSCopy_LDFLAGS += -Wl,-undefined,dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Preferences InputBridge PastedBridge OCRWorker
include $(THEOS_MAKE_PATH)/aggregate.mk

before-package::
	$(ECHO_NOTHING)IOSCOPY_PACKAGE_SCHEME="$(THEOS_PACKAGE_SCHEME)" \
		IOSCOPY_STAGING_DIR="$(THEOS_STAGING_DIR)" \
		IOSCOPY_INSTALL_PREFIX="$(THEOS_PACKAGE_INSTALL_PREFIX)" \
		bash "$(THEOS_PROJECT_DIR)/scripts/patch-staged-launchd.sh"$(ECHO_END)
