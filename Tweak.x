// SideClock v0.1 — shows a small digital clock in the left black bar
// whenever the app is in landscape. Touches pass straight through it.

#import <UIKit/UIKit.h>

// A window that can never take focus or catch taps.
@interface SCPassthroughWindow : UIWindow
@end

@implementation SCPassthroughWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

static SCPassthroughWindow *gWindow;
static UILabel *gLabel;
static NSDateFormatter *gFormatter;

// ---- Settings (edit these to tweak the look) ----
static const CGFloat kFontSize    = 17.0;  // clock text size
static const CGFloat kOpacity     = 0.85;  // 0 = invisible, 1 = solid white
static const CGFloat kVideoAspect = 16.0 / 9.0; // assumed video shape for bar width
// --------------------------------------------------

static UIWindowScene *SCActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

// Safe-area inset of the app's own main window (keeps us clear of the notch).
static CGFloat SCLeftInset(UIWindowScene *scene) {
    for (UIWindow *w in scene.windows) {
        if (w != gWindow && w.isKeyWindow) return w.safeAreaInsets.left;
    }
    for (UIWindow *w in scene.windows) {
        if (w != gWindow) return w.safeAreaInsets.left;
    }
    return 0;
}

static void SCBuildWindow(UIWindowScene *scene) {
    gWindow.hidden = YES;
    gWindow = [[SCPassthroughWindow alloc] initWithWindowScene:scene];
    gWindow.windowLevel = UIWindowLevelStatusBar + 100;
    gWindow.backgroundColor = UIColor.clearColor;
    gWindow.userInteractionEnabled = NO;

    gLabel = [UILabel new];
    gLabel.numberOfLines = 2;   // hours on top, minutes underneath
    gLabel.textAlignment = NSTextAlignmentCenter;
    gLabel.font = [UIFont monospacedDigitSystemFontOfSize:kFontSize weight:UIFontWeightSemibold];
    gLabel.textColor = [UIColor colorWithWhite:1.0 alpha:kOpacity];
    gLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    gLabel.layer.shadowOpacity = 0.6;
    gLabel.layer.shadowRadius = 2.0;
    gLabel.layer.shadowOffset = CGSizeZero;
    [gWindow addSubview:gLabel];
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
    CGFloat barWidth = (W - H * kVideoAspect) / 2.0;   // width of the grey/black side bar
    CGFloat inset = SCLeftInset(scene);                 // notch zone to stay out of

    if (barWidth < inset + 20.0) {   // not enough room, don't cover the video
        gWindow.hidden = YES;
        return;
    }

    gLabel.text = [gFormatter stringFromDate:[NSDate date]];
    [gLabel sizeToFit];
    gLabel.center = CGPointMake((inset + barWidth) / 2.0, H / 2.0);
    gWindow.hidden = NO;
}

%ctor {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        // Follow the phone's 12h / 24h setting.
        NSString *pattern = [NSDateFormatter dateFormatFromTemplate:@"j" options:0 locale:NSLocale.currentLocale];
        BOOL twelveHour = [pattern containsString:@"a"];
        gFormatter = [NSDateFormatter new];
        gFormatter.dateFormat = twelveHour ? @"hh\nmm" : @"HH\nmm";

        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            SCRefresh();
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        SCRefresh();
    }];
}