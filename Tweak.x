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
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static void SCUpdateFormatter(void) {
    // Follow the phone's 12h / 24h setting.
    NSString *pattern = [NSDateFormatter dateFormatFromTemplate:@"j" options:0 locale:NSLocale.currentLocale];
    BOOL twelveHour = [pattern containsString:@"a"];
    NSString *hours = twelveHour ? @"hh" : @"HH";
    if (!gFormatter) gFormatter = [NSDateFormatter new];
    gFormatter.dateFormat = [hours stringByAppendingString:(gStacked ? @"\nmm" : @":mm")];
}

// Returns YES if the settings changed since last time.
static BOOL SCReadSettings(void) {
    if (!gSetOK) return NO;
    uint64_t s = 0;
    if (notify_get_state(gSetToken, &s) != NOTIFY_STATUS_OK || !(s >> 63) || s == gLastSettings) return NO;
    gLastSettings = s;
    gClockSize   = (CGFloat)(s & 0xFF);
    gIconSize    = (CGFloat)((s >> 8) & 0xFF);
    gPctSize     = (CGFloat)((s >> 16) & 0xFF);
    gTop         = (CGFloat)((s >> 24) & 0xFF);
    gOpacity     = (CGFloat)((s >> 32) & 0xFF) / 100.0;
    gStacked     = (s >> 40) & 1;
    gShowClock   = (s >> 41) & 1;
    gShowSignal  = (s >> 42) & 1;
    gShowBattery = (s >> 43) & 1;
    gDebugOn     = (s >> 44) & 1;
    gEnabled     = (s >> 45) & 1;
    return YES;
}

static BOOL SCReadSignal(NSInteger *cell, NSInteger *wifi, uint64_t *src) {
    if (!gSigOK) return NO;
    uint64_t s = 0;
    if (notify_get_state(gSigToken, &s) != NOTIFY_STATUS_OK || !(s >> 63)) return NO;
    uint64_t c = s & 0xFF, w = (s >> 8) & 0xFF;
    *cell = (c == 0xFF) ? -1 : (NSInteger)c;
    *wifi = (w == 0xFF) ? -1 : (NSInteger)w;
    *src  = (s >> 16) & 0xFF;
    return YES;
}

static void SCBuildWindow(UIWindowScene *scene) {
    gWindow.hidden = YES;
    gWindow = [[SCPassthroughWindow alloc] initWithWindowScene:scene];
    gWindow.windowLevel = UIWindowLevelStatusBar + 100;
    gWindow.backgroundColor = UIColor.clearColor;
    gWindow.userInteractionEnabled = NO;

    gClock = SCLabel(gClockSize);
    gClock.numberOfLines = 2;
    [gWindow addSubview:gClock];

    gCell = SCIcon();    [gWindow addSubview:gCell];
    gWifi = SCIcon();    [gWindow addSubview:gWifi];
    gBattery = SCIcon(); [gWindow addSubview:gBattery];
    gPct = SCLabel(gPctSize); [gWindow addSubview:gPct];

    gDebug = SCLabel(8.0);
    gDebug.numberOfLines = 3;
    [gWindow addSubview:gDebug];
}

// Lays out a row of views centered on (cx, cy) with a small gap between them.
static void SCRow(NSArray<UIView *> *views, CGFloat cx, CGFloat cy) {
    CGFloat gap = 4.0, total = 0;
    NSMutableArray *shown = [NSMutableArray array];
    for (UIView *v in views) {
        if (v.hidden) continue;
        [v sizeToFit];
        [shown addObject:v];
        total += v.bounds.size.width;
    }
    if (shown.count == 0) return;
    total += gap * (shown.count - 1);
    CGFloat x = cx - total / 2.0;
    for (UIView *v in shown) {
        CGFloat w = v.bounds.size.width;
        v.center = CGPointMake(x + w / 2.0, cy);
        x += w + gap;
    }
}

static void SCUpdateBattery(void) {
    UIDevice *dev = UIDevice.currentDevice;
    float level = dev.batteryLevel;   // 0.0 – 1.0, or -1 if unknown
    if (!gShowBattery || level < 0) { gBattery.hidden = YES; gPct.hidden = YES; return; }
    gBattery.hidden = NO; gPct.hidden = NO;

    BOOL charging = dev.batteryState == UIDeviceBatteryStateCharging || dev.batteryState == UIDeviceBatteryStateFull;
    int pct = (int)lroundf(level * 100);

    NSString *name;
    if (charging)        name = @"battery.100.bolt";
    else if (pct >= 88)  name = @"battery.100";
    else if (pct >= 63)  name = @"battery.75";
    else if (pct >= 38)  name = @"battery.50";
    else if (pct >= 13)  name = @"battery.25";
    else                 name = @"battery.0";
    gBattery.image = SCSymbol(name, -1);

    UIColor *tint = SCWhite();   // same colours iOS uses
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) tint = UIColor.systemYellowColor;
    else if (charging)                                    tint = UIColor.systemGreenColor;
    else if (pct <= 20)                                   tint = UIColor.systemRedColor;
    gBattery.tintColor = tint;

    gPct.text = [NSString stringWithFormat:@"%d%%", pct];
}

static void SCUpdateSignal(void) {
    NSInteger cell = -1, wifi = -1;
    uint64_t src = 0;
    BOOL shared = SCReadSignal(&cell, &wifi, &src);
    NSInteger sbCell = cell, sbWifi = wifi;

    if (cell < 0) cell = gHookCell;   // fall back to this app's own status bar, if it has one
    if (wifi < 0) wifi = gHookWifi;

    if (!gOnWifi)      wifi = -1;     // only show Wi-Fi when actually connected to Wi-Fi
    else if (wifi < 0) wifi = 3;      // connected but no bar count: show full

    gCell.hidden = (!gShowSignal || cell < 0);
    if (!gCell.hidden) gCell.image = SCSymbol(@"cellularbars", MIN(cell, 4) / 4.0);

    gWifi.hidden = (!gShowSignal || wifi < 0);
    if (!gWifi.hidden) gWifi.image = SCSymbol(@"wifi", MIN(wifi, 3) / 3.0);

    gDebug.hidden = !gDebugOn;
    if (gDebugOn) {
        gDebug.text = [NSString stringWithFormat:@"sb:%@ c%ld w%ld\napp:c%ld w%ld net:%@",
                       shared ? [NSString stringWithFormat:@"%llx", src] : @"none",
                       (long)sbCell, (long)sbWifi, (long)gHookCell, (long)gHookWifi,
                       gOnWifi ? @"wifi" : @"cell"];
    }
}

static void SCRefresh(void) {
    if (SCReadSettings()) {          // settings changed: rebuild with the new look
        SCUpdateFormatter();
        gWindow.hidden = YES;
        gWindow = nil;
    }

    UIWindowScene *scene = SCActiveScene();
    if (!gEnabled || !scene || !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) {
        gWindow.hidden = YES;
        return;
    }
    if (!gWindow || gWindow.windowScene != scene) SCBuildWindow(scene);

    CGRect bounds = scene.coordinateSpace.bounds;
    gWindow.frame = bounds;
    CGFloat W = bounds.size.width, H = bounds.size.height;
    CGFloat barWidth = (W - H * kVideoAspect) / 2.0;   // width of each side bar

    gClock.hidden = !gShowClock;
    gClock.text = [gFormatter stringFromDate:[NSDate date]];
    CGSize clockSize = [gClock sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];   // measure fresh every time
    gClock.bounds = CGRectMake(0, 0, ceil(clockSize.width) + 2.0, ceil(clockSize.height));
    CGFloat needed = gShowClock ? gClock.bounds.size.width + 8.0 : 40.0;
    if (barWidth < needed) {         // no room, don't cover the video
        gWindow.hidden = YES;
        return;
    }

    // Left bar: clock, centered in the bar
    CGFloat clockCY = gStacked ? gTop + 5.0 : gTop;
    gClock.center = CGPointMake(barWidth / 2.0, clockCY);

    // Right bar: signal row on top, battery row below (or just one, centered, if the other is off)
    SCUpdateSignal();
    SCUpdateBattery();
    CGFloat rightCX = W - barWidth / 2.0;
    BOOL sigShown = !gCell.hidden || !gWifi.hidden;
    BOOL batShown = !gBattery.hidden;
    if (sigShown && batShown) {
        SCRow(@[gCell, gWifi], rightCX, gTop - 11.0);
        SCRow(@[gPct, gBattery], rightCX, gTop + 11.0);
    } else {
        SCRow(@[gCell, gWifi], rightCX, gTop);
        SCRow(@[gPct, gBattery], rightCX, gTop);
    }

    if (gDebugOn) gDebug.frame = CGRectMake(W - barWidth, gTop + 24.0, barWidth, 40.0);

    gWindow.hidden = NO;
}

static void SCStartApp(void) {
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;

    gPathMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(gPathMonitor, dispatch_get_main_queue());
    nw_path_monitor_set_update_handler(gPathMonitor, ^(nw_path_t path) {
        gOnWifi = nw_path_get_status(path) == nw_path_status_satisfied &&
                  nw_path_uses_interface_type(path, nw_interface_type_wifi);
    });
    nw_path_monitor_start(gPathMonitor);

    SCReadSettings();
    SCUpdateFormatter();

    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        SCRefresh();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    SCRefresh();
}

static void SCStartSpringBoard(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SCPrefsChanged,
                                    SC_PREFS_CHANGED, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    SCPublishSettings();

    NSTimer *timer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        SCPollSpringBoard();
        SCPublishSignal();
        SCPublishSettings();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

%ctor {
    gIsSpringBoard = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    gSigOK = (notify_register_check(SC_SIGNAL_NAME, &gSigToken) == NOTIFY_STATUS_OK);
    gSetOK = (notify_register_check(SC_SETTINGS_NAME, &gSetToken) == NOTIFY_STATUS_OK);

    // Only hook if the class and method really exist on this iOS version.
    Class sig = objc_getClass("_UIStatusBarSignalView");
    if (sig && class_getInstanceMethod(sig, @selector(setNumberOfActiveBars:))) {
        %init(SignalHooks);
    }

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        if (gIsSpringBoard) SCStartSpringBoard();
        else                SCStartApp();
    }];
}