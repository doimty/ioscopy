include $(THEOS)/makefiles/common.mk

DEBUG_LOG ?= 0
IOSCOPY_FORCE_REAL_PREFERENCES_PATH ?= 0

TWEAK_NAME = iOSCopyPastedBridge

iOSCopyPastedBridge_FILES = PastedBridge.xm \
	../Manager/PBInputBridge.m \
	../Manager/PBInputBridgeSpringBoardCapture.m \
	../Manager/PBInputBridgeSpringBoardReadAuth.m

ifeq ($(DEBUG_LOG),1)
iOSCopyPastedBridge_FILES += \
	../Shared/PBDiagnosticLogger.m \
	../Manager/PBInputBridgeDiagnostics.m
endif

# 适配新系统时，可临时加入 PastedBridgeRuntimeProbe.xm 生成 pasted runtime 探针输出。
iOSCopyPastedBridge_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DDEBUG_LOG=$(DEBUG_LOG) -DIOSCOPY_FORCE_REAL_PREFERENCES_PATH=$(IOSCOPY_FORCE_REAL_PREFERENCES_PATH)
ifeq ($(IOSCOPY_FORCE_REAL_PREFERENCES_PATH),1)
iOSCopyPastedBridge_CFLAGS += -Wno-macro-redefined
endif
iOSCopyPastedBridge_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
