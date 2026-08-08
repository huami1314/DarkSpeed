#import "DSInProcessHUD.h"
#import "HUDPresetPosition.h"

#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <os/log.h>

#ifndef NOTIFY_LAUNCHED_HUD
#define NOTIFY_LAUNCHED_HUD "ch.xxtou.notification.hud.launched"
#endif

@interface DSInProcessHUDController : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) uint64_t prevIn;
@property (nonatomic, assign) uint64_t prevOut;
@end

@implementation DSInProcessHUDController

+ (instancetype)shared {
    static DSInProcessHUDController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DSInProcessHUDController new]; });
    return s;
}

- (void)readBytes:(uint64_t *)inB out:(uint64_t *)outB {
    *inB = 0; *outB = 0;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return;
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || !ifa->ifa_addr || !ifa->ifa_data) continue;
        if (ifa->ifa_addr->sa_family != AF_LINK) continue;
        if (!(ifa->ifa_flags & IFF_UP) && !(ifa->ifa_flags & IFF_RUNNING)) continue;
        if (strncmp(ifa->ifa_name, "en", 2) && strncmp(ifa->ifa_name, "pdp_ip", 6)) continue;
        struct if_data *d = (struct if_data *)ifa->ifa_data;
        *inB += d->ifi_ibytes;
        *outB += d->ifi_obytes;
    }
    freeifaddrs(list);
}

- (NSString *)formatRate:(double)bps {
    if (bps < 1024) return [NSString stringWithFormat:@"%.0f B/s", bps];
    if (bps < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB/s", bps / 1024.0];
    return [NSString stringWithFormat:@"%.2f MB/s", bps / (1024.0 * 1024.0)];
}

- (void)tick {
    uint64_t inB = 0, outB = 0;
    [self readBytes:&inB out:&outB];
    double down = 0, up = 0;
    if (_prevIn || _prevOut) {
        down = (double)(inB >= _prevIn ? inB - _prevIn : 0);
        up = (double)(outB >= _prevOut ? outB - _prevOut : 0);
    }
    _prevIn = inB;
    _prevOut = outB;
    NSString *text = [NSString stringWithFormat:@"↑ %@\n↓ %@", [self formatRate:up], [self formatRate:down]];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.label.text = text;
    });
}

- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.window) return;
        CGRect screen = UIScreen.mainScreen.bounds;
        const CGFloat width = 120.0;
        const CGFloat height = 48.0;
        BOOL landscape = CGRectGetWidth(screen) > CGRectGetHeight(screen);
        NSString *modeKey = landscape ? @"selectedModeLandscape" : @"selectedMode";
        NSNumber *storedMode = [NSUserDefaults.standardUserDefaults objectForKey:modeKey];
        HUDPresetPosition mode = storedMode
            ? (HUDPresetPosition)storedMode.integerValue
            : HUDPresetPositionTopCenter;
        CGFloat x = (CGRectGetWidth(screen) - width) / 2.0;
        CGFloat y = 54.0;
        if (mode == HUDPresetPositionTopLeft) x = 12.0;
        if (mode == HUDPresetPositionTopRight) x = CGRectGetWidth(screen) - width - 12.0;
        if (mode == HUDPresetPositionTopCenterMost) y = 18.0;

        UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(x, y, width, height)];
        win.windowLevel = UIWindowLevelStatusBar + 1;
        win.backgroundColor = [UIColor clearColor];
        win.hidden = NO;

        UIView *bg = [[UIView alloc] initWithFrame:win.bounds];
        bg.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
        bg.layer.cornerRadius = 10;
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [win addSubview:bg];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(win.bounds, 8, 4)];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        label.numberOfLines = 2;
        label.textAlignment = NSTextAlignmentLeft;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [win addSubview:label];

        self.window = win;
        self.label = label;
        self.prevIn = self.prevOut = 0;
        [self tick];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
        // Unblock RootViewController's 5s wait after "Open HUD".
        notify_post(NOTIFY_LAUNCHED_HUD);
        os_log(OS_LOG_DEFAULT, "[DSInProcessHUD] shown mode=%ld frame=%{public}@",
               (long)mode, NSStringFromCGRect(win.frame));
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.timer invalidate];
        self.timer = nil;
        self.window.hidden = YES;
        self.window = nil;
        self.label = nil;
        os_log(OS_LOG_DEFAULT, "[DSInProcessHUD] hidden");
    });
}

@end

void DSInProcessHUDSetEnabled(BOOL enabled) {
    if (enabled) [[DSInProcessHUDController shared] show];
    else [[DSInProcessHUDController shared] hide];
}

BOOL DSInProcessHUDIsEnabled(void) {
    return [DSInProcessHUDController shared].window != nil;
}
