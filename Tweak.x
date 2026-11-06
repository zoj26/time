// SideClock v0.2
// Left bar (top):  clock
// Right bar (top): cell signal + Wi-Fi (if connected), battery underneath
// Only shows in landscape. Touches pass straight through.

#import <UIKit/UIKit.h>

// ---- Settings (edit these to tweak the look) ----
static const CGFloat kClockSize   = 19.0;  // clock text size
static const CGFloat kIconSize    = 13.0;  // signal / battery icon size
static const CGFloat kPctSize     = 12.0;  // battery % text size
static const CGFloat kTopCenter   = 37.0;  // how far down from the top edge things sit
static const CGFloat kOpacity     = 0.92;  // 0 = invisible, 1 = solid white
static const CGFloat kVideoAspect = 16.0 / 9.0; // assumed video shape for bar width
// --------------------------------------------------

@interface SCPassthroughWindow : UIWindow
@end
@implementation SCPassthroughWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

static SCPassthroughWindow *gWindow;
static UILabel *gClock;
static UIImageView *gCell, *gWifi, *gBattery;
static UILabel *gPct;
static NSDateFormatter *gFormatter;
static UIView *gLocalStatusBar;   // hidden copy of iOS's status bar, used only to read signal data

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

// ---------- Signal data (read from iOS's own status bar, safely) ----------

static id SCStatusData(UIWindowScene *scene) {
    @try {
        if (!gLocalStatusBar) {
            id mgr = scene.statusBarManager;
            if ([mgr respondsToSelector:NSSelectorFromString(@"createLocalStatusBar")])
                gLocalStatusBar = [mgr valueForKey:@"createLocalStatusBar"];
        }
        id bar = gLocalStatusBar;
        if ([bar respondsToSelector:NSSelectorFromString(@"statusBar")]) bar = [bar valueForKey:@"statusBar"];
        if ([bar respondsToSelector:NSSelectorFromString(@"currentData")]) return [bar valueForKey:@"currentData"];
    } @catch (NSException *e) {}
    return nil;
}

// Returns bars (0...max), or -1 if hidden/unknown.
static NSInteger SCBars(id data, NSString *entryKey) {
    @try {
        id entry = [data valueForKey:entryKey];
        if (!entry) return -1;
        if (![[entry valueForKey:@"enabled"] boolValue]) return -1;
        return [[entry valueForKey:@"displayValue"] integerValue];
    } @catch (NSException *e) {}
    return -1;
}

// ---------- Building the overlay ----------

static void SCBuildWindow(UIWindowScene *scene) {
    gWindow.hidden = YES;
    gWindow = [[SCPassthroughWindow alloc] initWithWindowScene:scene];
    gWindow.windowLevel = UIWindowLevelStatusBar + 100;
    gWindow.backgroundColor = UIColor.clearColor;
    gWindow.userInteractionEnabled = NO;

    gClock = [UILabel new];
    gClock.font = [UIFont monospacedDigitSystemFontOfSize:kClockSize weight:UIFontWeightSemibold];
    gClock.textColor = SCWhite();
    SCShadow(gClock);
    [gWindow addSubview:gClock];

    gCell = SCIcon();    [gWindow addSubview:gCell];
    gWifi = SCIcon();    [gWindow addSubview:gWifi];
    gBattery = SCIcon(); [gWindow addSubview:gBattery];

    gPct = [UILabel new];
    gPct.font = [UIFont monospacedDigitSystemFontOfSize:kPctSize weight:UIFontWeightSemibold];
    gPct.textColor = SCWhite();
    SCShadow(gPct);
    [gWindow addSubview:gPct];
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

static void SCUpdateSignal(UIWindowScene *scene) {
    id data = SCStatusData(scene);
    NSInteger cell = data ? SCBars(data, @"cellularEntry") : -1;
    NSInteger wifi = data ? SCBars(data, @"wifiEntry") : -1;

    gCell.hidden = (cell < 0);
    if (cell >= 0) gCell.image = SCSymbol(@"cellularbars", MIN(cell, 4) / 4.0);

    gWifi.hidden = (wifi < 0);
    if (wifi >= 0) gWifi.image = SCSymbol(@"wifi", MIN(wifi, 3) / 3.0);
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
    gClock.center = CGPointMake(barWidth / 2.0, kTopCenter);

    // Right bar: signal row on top, battery row below, centered in the bar
    SCUpdateSignal(scene);
    SCUpdateBattery();
    CGFloat rightCX = W - barWidth / 2.0;
    SCRow(@[gCell, gWifi], rightCX, kTopCenter - 11.0);
    SCRow(@[gPct, gBattery], rightCX, kTopCenter + 11.0);

    gWindow.hidden = NO;
}

%ctor {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;

        // Follow the phone's 12h / 24h setting.
        NSString *pattern = [NSDateFormatter dateFormatFromTemplate:@"j" options:0 locale:NSLocale.currentLocale];
        BOOL twelveHour = [pattern containsString:@"a"];
        gFormatter = [NSDateFormatter new];
        gFormatter.dateFormat = twelveHour ? @"hh:mm" : @"HH:mm";

        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            SCRefresh();
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        SCRefresh();
    }];
}