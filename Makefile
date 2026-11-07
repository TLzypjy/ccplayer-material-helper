export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export DEBUG = 0

TWEAK_NAME = CCMaterialImporter
CCMaterialImporter_FILES = Tweak.x
CCMaterialImporter_CFLAGS = -fobjc-arc -Wno-unused-function
CCMaterialImporter_FRAMEWORKS = UIKit AVKit UniformTypeIdentifiers
CCMaterialImporter_LDFLAGS = -lsubstrate

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/tweak.mk
