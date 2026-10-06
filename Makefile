TARGET := iphone:clang:16.2:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Music SpringBoard MediaRemoteUI
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TwentyOne TwentyOneScrobbler TwentyOneLockScreen TwentyOneSpotify

TwentyOne_FILES = Tweak.x \
	TJHomeTab.x \
	TJGlobals.m \
	TJPrefsStore.m \
	TJLastFmShared.m \
	TJColorAndLabels.m \
	TJScrollListsRowTint.m \
	TJAlbumPainting.m \
	TJNowPlayingOverlay.m \
	TJModelUtils.m \
	TJMotionArtworkResolver.m \
	TJNowPlayingImmersive.m \
	TJScrobbleStateClient.m \
	TJLastFmBadgeView.m
TwentyOne_FRAMEWORKS = UIKit CoreImage CoreGraphics QuartzCore AVFoundation Security MediaPlayer
TwentyOne_CFLAGS = -fobjc-arc -Wno-arc-performSelector-leaks -Wno-deprecated-declarations

TwentyOneScrobbler_FILES = TJScrobbler.m \
	TJLastFmManager.m \
	TJLastFmShared.m \
	TJPrefsStore.m \
	TJLockClock.x
TwentyOneScrobbler_FRAMEWORKS = CoreGraphics UIKit QuartzCore
TwentyOneScrobbler_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

TwentyOneLockScreen_FILES = TJLockScreenMotion.x \
	TJMotionArtworkResolver.m \
	TJModelUtils.m \
	TJPrefsStore.m \
	TJCanvasShare.m
TwentyOneLockScreen_FRAMEWORKS = UIKit AVFoundation QuartzCore CoreGraphics
TwentyOneLockScreen_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

TwentyOneSpotify_FILES = TJSpotifyCanvas.x \
	TJCanvasShare.m
TwentyOneSpotify_FRAMEWORKS = Foundation
TwentyOneSpotify_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

BUNDLE_NAME = TwentyOnePrefs

TwentyOnePrefs_FILES = TwentyOnePrefs/TwentyOnePrefsListController.m \
	TJPrefsStore.m \
	TJLastFmShared.m
TwentyOnePrefs_RESOURCE_DIRS = TwentyOnePrefs/Resources
TwentyOnePrefs_INSTALL_PATH = /Library/PreferenceBundles
TwentyOnePrefs_PRINCIPAL_CLASS = TwentyOnePrefsListController
TwentyOnePrefs_FRAMEWORKS = SafariServices UIKit CoreGraphics
TwentyOnePrefs_PRIVATE_FRAMEWORKS = Preferences
TwentyOnePrefs_CFLAGS = -fobjc-arc -Wno-undeclared-selector -Wno-deprecated-declarations

include $(THEOS)/makefiles/tweak.mk
include $(THEOS)/makefiles/bundle.mk
