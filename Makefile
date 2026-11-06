TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SideClock
SideClock_FILES = Tweak.x
SideClock_CFLAGS = -fobjc-arc
SideClock_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk