# MapsRecentre — auto-recentre the Google Maps camera after you pan away in navigation.
#
# Build: export THEOS=~/theos && make clean && make package
#
# Target: iPhone 14 Pro Max (A16, arm64e) on iOS 16.3.1, Dopamine/Roothide.
# ARCHS MUST include arm64e — ElleKit silently skips arm64-only dylibs on A12+.
# THEOS_PACKAGE_SCHEME = rootless produces the iphoneos-arm64 deb Patcher wants.

TARGET = iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = maps

TWEAK_NAME = MapsRecentre

MapsRecentre_FILES = Tweak.x
MapsRecentre_CFLAGS = -fobjc-arc
MapsRecentre_FRAMEWORKS = UIKit AVFoundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
