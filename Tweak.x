// SideClock v0.5.1
// Settings live in the Settings app (Settings > SideClock) and apply live.
// Left bar (top):  clock
// Right bar (top): cell signal + Wi-Fi, battery underneath
// SpringBoard reads signal bars + your settings and shares them with apps.

#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import <notify.h>
#import <objc/runtime.h>

static const CGFloat kVideoAspect = 16.0 / 9.0;   // assumed video shape for bar width

#define SC_SIGNAL_NAME   "com.zoj26.sideclock.signal"
#define SC_SETTINGS_NAME "com.zoj26.sideclock.settings"
#define SC_PREFS_DOMAIN  CFSTR("com.zoj26.sideclock")
#define SC_PREFS_CHANGED CFSTR("com.zoj26.sideclock/prefs")

// Settings — these are just starting values; the Settings app overrides them live.
static BOOL    gEnabled = YES, gStacked = YES, gShowClock = YES, gShowSignal = YES, gShowBattery = YES, gDebugOn = NO;
static CGFloat gClockSize = 17.0, gIconSize = 14.0, gPctSize = 13.0, gTop = 38.0, gOpacity = 0.92;
static uint64_t gLastSettings = 0;

static BOOL gIsSpringBoard = NO;
static int  gSigToken = 0, gSetToken = 0;
static BOOL gSigOK = NO, gSetOK = NO;

// Bars seen by status bar views in this process (-1 = unknown)
static NSInteger gHookCell = -1, gHookWifi = -1;
// Bars read directly from SpringBoard's managers (-1 = unknown)
static NSInteger gPollCell = -1, gPollWifi = -1;

static id SCTryKey(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

// ================= SpringBoard side =================

static void SCPublishSignal(void) {
    if (!gSigOK) return;
    NSInteger cell = gHookCell >= 0 ? gHookCell : gPollCell;
    NSInteger wifi = gHookWifi >= 0 ? gHookWifi : gPollWifi;
    uint64_t src = (gHookCell >= 0 ? 1 : 0) | (gHookWifi >= 0 ? 2 : 0) |
                   (gPollCell >= 0 ? 4 : 0) | (gPollWifi >= 0 ? 8 : 0);
    uint64_t c = cell < 0 ? 0xFF : (uint64_t)(cell & 0xFF);
    uint64_t w = wifi < 0 ? 0xFF : (uint64_t)(wifi & 0xFF);
    notify_set_state(gSigToken, (1ULL << 63) | c | (w << 8) | (src << 16));
}

static double SCPref(NSString *key, double def) {
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, SC_PREFS_DOMAIN));
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def;
}

static uint64_t SCByte(double v, double lo, double hi) {
    if (v < lo) v = lo;
    if (v > hi) v = hi;
    return (uint64_t)llround(v);
}

// Packs all settings into one number that apps can read.
static void SCPublishSettings(void) {
    if (!gSetOK) return;
    CFPreferencesAppSynchronize(SC_PREFS_DOMAIN);
    uint64_t s = (1ULL << 63);
    s |= SCByte(SCPref(@"clockSize", 17), 8, 60);
    s |= SCByte(SCPref(@"iconSize", 14), 6, 40) << 8;
    s |= SCByte(SCPref(@"pctSize", 13), 6, 40) << 16;
    s |= SCByte(SCPref(@"topOffset", 38), 0, 255) << 24;
    s |= SCByte(SCPref(@"opacity", 0.92) * 100.0, 5, 100) << 32;
    if (SCPref(@"stacked", 1) != 0)     s |= 1ULL << 40;
    if (SCPref(@"showClock", 1) != 0)   s |= 1ULL << 41;
    if (SCPref(@"showSignal", 1) != 0)  s |= 1ULL << 42;
    if (SCPref(@"showBattery", 1) != 0) s |= 1ULL << 43;
    if (SCPref(@"debug", 0) != 0)       s |= 1ULL << 44;
    if (SCPref(@"enabled", 1) != 0)     s |= 1ULL << 45;
    notify_set_state(gSetToken, s);
}

static void SCPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef userInfo) {
    SCPublishSettings();
}

static void SCPollSpringBoard(void) {
    id wifiMgr = SCTryKey((id)objc_getClass("SBWiFiManager"), @"sharedInstance");
    id w = SCTryKey(wifiMgr, @"signalStrengthBars");
    gPollWifi = w ? [w integerValue] : -1;

    id tel = SCTryKey((id)objc_getClass("SBTelephonyManager"), @"sharedTelephonyManager");
    id c = SCTryKey(tel, @"signalStrengthBars");
    if (!c) {
        for (NSString *k in @[ @"_primarySubscriptionInfo", @"primarySubscriptionInfo", @"_primarySlotSubscriptionInfo" ]) {
            c = SCTryKey(SCTryKey(tel, k), @"signalStrengthBars");
            if (c) break;
        }
    }
    gPollCell = c ? [c integerValue] : -1;
}

// Status bar signal views get told how many bars to light up. We listen in.
static void SCRecordBars(id view, NSInteger n) {
    NSString *cls = NSStringFromClass([view class]).lowercaseString;
    if ([cls containsString:@"cellular"])  gHookCell = n;
    else if ([cls containsString:@"wifi"]) gHookWifi = n;
    else return;
    if (gIsSpringBoard) SCPublishSignal();
}

%group SignalHooks
%hook _UIStatusBarSignalView
- (void)setNumberOfActiveBars:(NSInteger)n {
    %orig;
    SCRecordBars(self, n);
}
%end
%end

// ================= App side (the overlay) =================

@interface SCPassthroughWindow : UIWindow
@end
@implementation SCPassthroughWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

static SCPassthroughWindow *gWindow;
static UILabel *gClock, *gPct, *gDebug;
static UIImageView *gCell, *gWifi, *gBattery;
static NSDateFormatter *gFormatter;
static nw_path_monitor_t gPathMonitor;   // knows if we're on Wi-Fi
static volatile BOOL gOnWifi = NO;

static UIColor *SCWhite(void) { return [UIColor colorWithWhite:1.0 alpha:gOpacity]; }

static void SCShadow(UIView *v) {
    v.layer.shadowColor = UIColor.blackColor.CGColor;
    v.layer.shadowOpacity = 0.5;
    v.layer.shadowRadius = 2.0;
    v.layer.shadowOffset = CGSizeZero;
}

static UIImageView *SCIcon(void) {
    UIImageView *iv = [UIImageView new];
    iv.contentMode = UIViewContentModeCenter;
    iv.tintColor = SCWhite();
    SCShadow(iv);
    return iv;
}

static UILabel *SCLabel(CGFloat size) {
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:size weight:UIFontWeightSemibold];
    l.textColor = SCWhite();
    l.textAlignment = NSTextAlignmentCenter;
    SCShadow(l);
    return l;
}

static UIImage *SCSymbol(NSString *name, double value) {
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:gIconSize weight:UIImageSymbolWeightSemibold];
    if (value >= 0) return [UIImage systemImageNamed:name variableValue:value withConfiguration:cfg];
    return [UIImage systemImageNamed:name withConfiguration:cfg];
}

static UIWindowScene *SCActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene