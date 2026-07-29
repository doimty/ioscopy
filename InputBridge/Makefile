include $(THEOS)/makefiles/common.mk

DEBUG_LOG ?= 0
IOSCOPY_FORCE_REAL_PREFERENCES_PATH ?= 0

TWEAK_NAME = iOSCopyInputBridge

iOSCopyInputBridge_FILES = InputBridge.xm \
	../Manager/PBInputBridge.m \
	../Manager/PBInputBridgeAppExecutor.m \
	../Manager/PBInputBridgeImagePasteboard.m \
	../Manager/PBInputBridgeSourceState.m \
	../Manager/PBInputBridgePasteState.m \
	../Manager/PBInputBridgeSpringBoardCapture.m

ifeq ($(DEBUG_LOG),1)
iOSCopyInputBridge_FILES += \
	../Shared/PBDiagnosticLogger.m \
	../Manager/PBInputBridgeDiagnostics.m
endif

iOSCopyInputBridge_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DDEBUG_LOG=$(DEBUG_LOG) -DIOSCOPY_FORCE_REAL_PREFERENCES_PATH=$(IOSCOPY_FORCE_REAL_PREFERENCES_PATH) -DIOSCOPY_INPUTBRIDGE_TWEAK=1
iOSCopyInputBridge_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
