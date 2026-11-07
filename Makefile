export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export DEBUG = 0

TWEAK_NAME = CCMaterialGrid
CCMaterialGrid_FILES = Tweak.x
CCMaterialGrid_CFLAGS = -fobjc-arc -Wno-unused-function
CCMaterialGrid_FRAMEWORKS = UIKit AVKit UniformTypeIdentifiers
CCMaterialGrid_LDFLAGS = -lsubstrate -Wl,-no_fixup_chains

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/tweak.mk
