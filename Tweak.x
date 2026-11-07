// SideClock v0.4
// Left bar (top):  clock
// Right bar (top): cell signal + Wi-Fi, battery underneath
// Signal bars are read inside SpringBoard and shared with apps.
// Only shows in landscape. Touches pass straight through.

#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import <notify.h>
#import <objc/runtime.h>

// ---- Settings (edit these to tweak the look) ----
static const BOOL    kStackedClock = YES;   // YES = hours above minutes, NO = one line with ":"
static const BOOL    kDebug        = YES;   // YES = tiny diagnostic text under the battery
static const CGFloat kClockSize    = 17.0;  // clock text size
static const CGFloat kIconSize     = 14.0;  // signal / battery icon size
static const CGFloat kPctSize      = 13.0;  // battery % text size
static const CGFloat kTopCenter    = 38.0;  // how far down from the top edge things sit
static const CGFloat kOpacity      = 0.92;  // 0 = invisible, 1 = solid white
static const CGFloat kVideoAspect  = 16.0 / 9.0; // assumed video shape for bar width
// --------------------------------------------------

#define SC_NOTIFY_NAME "com.zoj26.sideclock.signal"

static BOOL gIsSpringBoard = NO;
static int gToken = 0;
static BOOL gTokenOK = NO;

// Bars seen by status bar views in this process (-1 = unknown)
static NSInteger gHookCell = -1, gHookWifi = -1;
// Bars read directly from SpringBoard's managers (-1 = unknown)
static NSInteger gPollCell = -1, gPollWifi = -1;

static id SCTryKey(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

// ================= SpringBoard side =================

static void SCPublish(void) {
    if (!gTokenOK) return;
    NSInteger cell = gHookCell >= 0 ? gHookCell : gPollCell;
    NSInteger wifi = gHookWifi >= 0 ? gHookWifi : gPollWifi;
    uint64_t src = (gHookCell >= 0 ? 1 : 0) | (gHookWifi >= 0 ? 2 : 0) |
                   (gPollCell >= 0 ? 4 : 0) | (gPollWifi >= 0 ? 8 : 0);
    uint64_t c = cell < 0 ? 0xFF : (uint64_t)(cell & 0xFF);
    uint64_t w = wifi < 0 ? 0xFF : (uint64_t)(wifi & 0xFF);
    uint64_t state = (1ULL << 63) | c | (w << 8) | (src << 16);
    notify_set_state(gToken, state);
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
    if (gIsSpringBoard) SCPublish();
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

static UIColor *SCWhite(void) { return [UIColor colorWithWhite:1.0 alpha:kOpacity]; }

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
        [UIImageSymbolConfiguration configurationWithPointSize:kIconSize weight:UIImageSymbolWeightSemibold];
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

static BOOL SCReadShared(NSInteger *cell, NSInteger *wifi, uint64_t *src) {
    if (!gTokenOK) return NO;
    uint64_t s = 0;
    if (notify_get_state(gToken, &s) != NOTIFY_STATUS_OK || !(s >> 63)) return NO;
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

    gClock = SCLabel(kClockSize);
    gClock.numberOfLines = 2;
    [gWindow addSubview:gClock];

    gCell = SCIcon();    [gWindow addSubview:gCell];
    gWifi = SCIcon();    [gWindow addSubview:gWifi];
    gBattery = SCIcon(); [gWindow addSubview:gBattery];
    gPct = SCLabel(kPctSize); [gWindow addSubview:gPct];

    gDebug = SCLabel(8.0);
    gDebug.numberOfLines = 3;
    gDebug.hidden = !kDebug;
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
    if (level < 0) { gBattery.hidden = YES; gPct.hidden = YES; return; }
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
    BOOL shared = SCReadShared(&cell, &wifi, &src);
    NSInteger sbCell = cell, sbWifi = wifi;

    if (cell < 0) cell = gHookCell;   // fall back to this app's own status bar, if it has one
    if (wifi < 0) wifi = gHookWifi;

    if (!gOnWifi)      wifi = -1;     // only show Wi-Fi when actually connected to Wi-Fi
    else if (wifi < 0) wifi = 3;      // connected but no bar count: show full

    gCell.hidden = (cell < 0);
    if (cell >= 0) gCell.image = SCSymbol(@"cellularbars", MIN(cell, 4) / 4.0);

    gWifi.hidden = (wifi < 0);
    if (wifi >= 0) gWifi.image = SCSymbol(@"wifi", MIN(wifi, 3) / 3.0);

    if (kDebug) {
        gDebug.text = [NSString stringWithFormat:@"sb:%@ c%ld w%ld\napp:c%ld w%ld net:%@",
                       shared ? [NSString stringWithFormat:@"%llx", src] : @"none",
                       (long)sbCell, (long)sbWifi, (long)gHookCell, (long)gHookWifi,
                       gOnWifi ? @"wifi" : @"cell"];
    }
}

static void SCRefresh(void) {
    UIWindowScene *scene = SCActiveScene();
    if (!scene || !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation)) {
        gWindow.hidden = YES;
        return;
    }
    if (!gWindow || gWindow.windowScene != scene) SCBuildWindow(scene);

    CGRect bounds = scene.coordinateSpace.bounds;
    gWindow.frame = bounds;
    CGFloat W = bounds.size.width, H = bounds.size.height;
    CGFloat barWidth = (W - H * kVideoAspect) / 2.0;   // width of each side bar

    gClock.text = [gFormatter stringFromDate:[NSDate date]];
    [gClock sizeToFit];
    if (barWidth < gClock.bounds.size.width + 8.0) {   // no room, don't cover the video
        gWindow.hidden = YES;
        return;
    }

    // Left bar: clock, centered in the bar
    CGFloat clockCY = kStackedClock ? kTopCenter + 5.0 : kTopCenter;
    gClock.center = CGPointMake(barWidth / 2.0, clockCY);

    // Right bar: signal row on top, battery row below, centered in the bar
    SCUpdateSignal();
    SCUpdateBattery();
    CGFloat rightCX = W - barWidth / 2.0;
    SCRow(@[gCell, gWifi], rightCX, kTopCenter - 11.0);
    SCRow(@[gPct, gBattery], rightCX, kTopCenter + 11.0);

    if (kDebug) gDebug.frame = CGRectMake(W - barWidth, kTopCenter + 24.0, barWidth, 40.0);

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

    // Follow the phone's 12h / 24h setting.
    NSString *pattern = [NSDateFormatter dateFormatFromTemplate:@"j" options:0 locale:NSLocale.currentLocale];
    BOOL twelveHour = [pattern containsString:@"a"];
    NSString *hours = twelveHour ? @"hh" : @"HH";
    gFormatter = [NSDateFormatter new];
    gFormatter.dateFormat = [hours stringByAppendingString:(kStackedClock ? @"\nmm" : @":mm")];

    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        SCRefresh();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    SCRefresh();
}

static void SCStartSpringBoard(void) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        SCPollSpringBoard();
        SCPublish();
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

%ctor {
    gIsSpringBoard = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    gTokenOK = (notify_register_check(SC_NOTIFY_NAME, &gToken) == NOTIFY_STATUS_OK);

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