include $(THEOS)/makefiles/common.mk

DEBUG_LOG ?= 0
IOSCOPY_FORCE_REAL_PREFERENCES_PATH ?= 0

TOOL_NAME = iOSCopyOCRWorker

iOSCopyOCRWorker_FILES = main.m \
	../Shared/PBLocalization.m \
	../Manager/PBImageOCRIndexer.m \
	../Manager/PBStorageManager.m \
	../Model/PBClipboardItem.m

ifeq ($(DEBUG_LOG),1)
iOSCopyOCRWorker_FILES += \
	../Shared/PBDiagnosticLogger.m
endif

iOSCopyOCRWorker_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -DDEBUG_LOG=$(DEBUG_LOG) -DIOSCOPY_FORCE_REAL_PREFERENCES_PATH=$(IOSCOPY_FORCE_REAL_PREFERENCES_PATH)
ifeq ($(IOSCOPY_FORCE_REAL_PREFERENCES_PATH),1)
iOSCopyOCRWorker_CFLAGS += -Wno-macro-redefined -Wno-ambiguous-macro
endif
iOSCopyOCRWorker_FRAMEWORKS = Foundation CoreGraphics ImageIO Vision
iOSCopyOCRWorker_LIBRARIES = sqlite3
iOSCopyOCRWorker_CODESIGN_FLAGS = -Sentitlements.plist
iOSCopyOCRWorker_INSTALL_PATH = /usr/local/bin
ifeq ($(IOSCOPY_FORCE_REAL_PREFERENCES_PATH),1)
iOSCopyOCRWorker_LDFLAGS += -Wl,-undefined,dynamic_lookup
endif

include $(THEOS_MAKE_PATH)/tool.mk

