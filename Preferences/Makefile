include $(THEOS)/makefiles/common.mk

IOSCOPY_FORCE_REAL_PREFERENCES_PATH ?= 0

BUNDLE_NAME = iOSCopyPrefs
iOSCopyPrefs_BUNDLE_EXTENSION = bundle
iOSCopyPrefs_INSTALL_PATH = /Library/PreferenceBundles

iOSCopyPrefs_FILES = PBRootListController.m ../Shared/PBLocalization.m
iOSCopyPrefs_RESOURCE_FILES = Resources/icon.png \
	Resources/icon@2x.png \
	Resources/icon@3x.png \
	Resources/icon@4x.png
iOSCopyPrefs_FRAMEWORKS = UIKit
iOSCopyPrefs_PRIVATE_FRAMEWORKS = Preferences
iOSCopyPrefs_CFLAGS = -fobjc-arc -DIOSCOPY_FORCE_REAL_PREFERENCES_PATH=$(IOSCOPY_FORCE_REAL_PREFERENCES_PATH)
ifeq ($(IOSCOPY_FORCE_REAL_PREFERENCES_PATH),1)
iOSCopyPrefs_CFLAGS += -Wno-macro-redefined -Wno-ambiguous-macro
endif
ifeq ($(IOSCOPY_FORCE_REAL_PREFERENCES_PATH),1)
iOSCopyPrefs_LDFLAGS += -Wl,-undefined,dynamic_lookup
endif
ifneq ($(strip $(IOSCOPY_PRIVATE_FRAMEWORKS_DIR)),)
iOSCopyPrefs_LDFLAGS += -F$(IOSCOPY_PRIVATE_FRAMEWORKS_DIR)
endif

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/iOSCopy.plist$(ECHO_END)
