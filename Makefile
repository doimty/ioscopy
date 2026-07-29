export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0

export THEOS_PACKAGE_SCHEME = rootless

IOSCOPY_FORCE_REAL_PREFERENCES_PATH ?= 0
export IOSCOPY_FORCE_REAL_PREFERENCES_PATH

DEBUG_LOG ?= 0
export DEBUG_LOG

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
iOSCopy_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO
iOSCopy_PRIVATE_FRAMEWORKS =
iOSCopy_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Preferences InputBridge PastedBridge OCRWorker
include $(THEOS_MAKE_PATH)/aggregate.mk
