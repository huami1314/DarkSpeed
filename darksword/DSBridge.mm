//
//  DSBridge.mm
//  TrollSpeed + DarkSword
//

#import "DSBridge.h"
#import "DSInProcessHUD.h"
#import "HUDHelper.h"
#import "HUDPresetPosition.h"
#import "SpringBoardServices.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <os/lock.h>
#import <os/log.h>

#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern "C" CFIndex CARenderServerGetDirtyFrameCount(void *);

NSString * const DSBridgeProgressNotification = @"com.huami.trollspeed.dsbridge.progress";

static os_unfair_lock g_errorLock = OS_UNFAIR_LOCK_INIT;
static NSString *g_dsLastError = @"";
static NSString *g_dsStage = @"等待启动";
static std::atomic_bool g_dsReady(false);
static std::atomic_bool g_dsRunning(false);
static std::atomic_bool g_hudRequested(false);
static std::atomic_bool g_hudActive(false);
static std::atomic<double> g_dsProgress(0.0);

static void ds_post_progress(void) {
    notify_post("com.huami.trollspeed.dsbridge.progress");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSBridgeProgressNotification object:nil];
    });
}

static NSString *ds_checkpoint_log_path(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *library = paths.firstObject;
    return library.length ? [library stringByAppendingPathComponent:@"DSBridge.log"] : nil;
}

static void ds_append_checkpoint(NSString *message) {
    NSString *path = ds_checkpoint_log_path();
    if (!path.length || !message.length) return;
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle synchronizeFile];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
}

static void ds_set_stage(NSString *stage) {
    NSString *next = [stage copy] ?: @"";
    os_unfair_lock_lock(&g_errorLock);
    g_dsStage = next;
    os_unfair_lock_unlock(&g_errorLock);
    os_log(OS_LOG_DEFAULT, "[DSBridge] stage: %{public}@", next);
    ds_append_checkpoint(next);
    ds_post_progress();
}

static void ds_set_error(NSString *message) {
    NSString *next = [message copy] ?: @"";
    os_unfair_lock_lock(&g_errorLock);
    g_dsLastError = next;
    os_unfair_lock_unlock(&g_errorLock);
    if (next.length > 0) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] %{public}@", next);
        ds_append_checkpoint([@"错误：" stringByAppendingString:next]);
        notify_post(NOTIFY_RELOAD_APP);
    }
    ds_post_progress();
}

#if USE_DARKSWORD

#import "DSRemoteCall.h"

// These vendored headers are plain C/Objective-C. Keep C linkage from this .mm.
extern "C" {
#import "darksword.h"
#import "offsets.h"
#import "utils.h"
}

static const NSInteger kDSSpringBoardHUDTag = 0x54534844; // "TSHD"
static const CGFloat kDSHUDMinFontSize = 9.0;
static const CGFloat kDSHUDMaxFontSize = 10.0;
static const CGFloat kDSHUDMinCornerRadius = 4.5;
static const CGFloat kDSHUDMaxCornerRadius = 5.0;
static const CGFloat kDSHUDInactiveOpacity = 0.667;
static const NSTimeInterval kDSHUDFocusDuration = 3.0;
static const CACornerMask kDSCornerMaskBottom =
    kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
static const CACornerMask kDSCornerMaskAll =
    kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
    kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;

static RemoteCall *g_springBoard = nil;
static uint64_t g_remoteContainer = 0;
static uint64_t g_remoteBlurView = 0;
static uint64_t g_remoteBlurEffect = 0;
static uint64_t g_remoteLabel = 0;
static uint64_t g_remoteSecureField = 0;
static uint64_t g_remoteSecureCanvas = 0;
static uint64_t g_remoteWindow = 0;
static uint64_t g_remoteWindowScene = 0;
static pid_t g_remoteWindowPid = 0;
static dispatch_source_t g_rateTimer = nil;
static AVAudioPlayer *g_keepAlivePlayer = nil;
static uint64_t g_previousInput = 0;
static uint64_t g_previousOutput = 0;
static CFAbsoluteTime g_previousSampleTime = 0;
static CFAbsoluteTime g_focusUntil = 0;
static CFIndex g_previousDirtyFrameCount = 0;
static BOOL g_needsFPSBaselineReset = YES;
static std::atomic<int> g_remoteOrientation(UIInterfaceOrientationUnknown);
static std::atomic_bool g_deviceLocked(false);
static int g_reloadHUDToken = -1;
static int g_lockStateToken = -1;
static NSUInteger g_lastPresentationSignature = 0;
static CGRect g_lastWindowFrame = CGRectNull;
static CGRect g_lastLabelFrame = CGRectNull;
static BOOL g_lastWindowHidden = NO;
static CGFloat g_lastContainerAlpha = -1.0;
static CGFloat g_lastFontSize = -1.0;
static BOOL g_lastInverted = NO;
static BOOL g_lastHideAtSnapshot = NO;
static NSMutableDictionary<NSString *, NSNumber *> *g_remoteSelectorCache = nil;
static NSMutableDictionary<NSString *, NSNumber *> *g_remoteClassCache = nil;

static const uint64_t kDSRemoteTextScratchOffset = 0x1000;
static const size_t kDSRemoteTextScratchCapacity = 0x800;

static void ds_update_rate(void);

typedef struct {
    BOOL landscape;
    BOOL centered;
    BOOL centeredMost;
    BOOL singleLine;
    BOOL bitrate;
    BOOL arrowPrefixes;
    BOOL inverted;
    BOOL followsRotation;
    BOOL hideAtSnapshot;
    BOOL displayFPS;
    BOOL passthrough;
    CGFloat fontSize;
    CGFloat cornerRadius;
    CGFloat inactiveOpacity;
    NSInteger numberOfLines;
    NSTextAlignment alignment;
    CACornerMask maskedCorners;
    CGRect windowFrame;
    CGRect blurFrame;
    CGRect labelFrame;
} DSHUDPresentation;

static dispatch_queue_t ds_bridge_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.huami.trollspeed.darksword", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void ds_bridge_log(const char *message) {
    if (message && message[0]) {
        os_log(OS_LOG_DEFAULT, "[DSBridge] %{public}s", message);
    }
}

// Feed the native progress callback into the controller UI so startup shows
// measured progress instead of an indeterminate spinner.
static void ds_bridge_progress(double progress) {
    g_dsProgress.store(progress);
    ds_post_progress();
}

static uint64_t ds_env_u64(const char *name) {
    const char *value = getenv(name);
    return value && value[0] ? strtoull(value, NULL, 0) : 0;
}

static int ds_env_int(const char *name, int fallback) {
    const char *value = getenv(name);
    return value && value[0] ? (int)strtol(value, NULL, 0) : fallback;
}

static BOOL ds_has_symbol_offsets(void) {
    NSUserDefaults *defaults = GetStandardUserDefaults();
    return [defaults objectForKey:@"darksword.kernprocoff"] != nil ||
           [defaults objectForKey:@"darksword.allprocoff"] != nil;
}

// Resolve kernproc/allproc from Documents/kernelcache. If the file
// is missing, download via dlkcache() on a background thread with a timeout so
// the UI never hangs at 92%. Never use vnode redirect here.
static BOOL ds_prepare_kernel_offsets(void) {
    if (ds_has_symbol_offsets()) return YES;
    if (emergencyfixfunctiontobereplacedlateronquestionmark()) return YES;

    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *kc = [docs stringByAppendingPathComponent:@"kernelcache"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:kc]) {
        return emergencyfixfunctiontobereplacedlateronquestionmark();
    }

    __block BOOL result = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        result = dlkcache();
        dispatch_semaphore_signal(sem);
    });
    // 90s timeout for kernelcache download + xpf parse
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC)) != 0) {
        os_log_error(OS_LOG_DEFAULT, "[DSBridge] dlkcache timed out after 90s");
        ds_set_error(@"系统数据准备超时，已切换安全模式。");
        return NO;
    }
    return result;
}

static void ds_finish_enable_inprocess(NSString *reason) {
    os_log(OS_LOG_DEFAULT, "[DSBridge] using in-process HUD: %{public}@", reason);
    ds_set_stage(@"已切换安全显示");
    dispatch_sync(dispatch_get_main_queue(), ^{
        DSInProcessHUDSetEnabled(YES);
    });
    g_hudActive.store(true);
    g_dsRunning.store(false);
    g_dsProgress.store(1.0);
    ds_set_error(reason ?: @"");
    notify_post(NOTIFY_LAUNCHED_HUD);
    ds_post_progress();
}

static NSDictionary *ds_hud_preferences(void) {
    NSMutableDictionary *preferences = [[NSDictionary
        dictionaryWithContentsOfFile:JBROOT_PATH_NSSTRING(USER_DEFAULTS_PATH)] mutableCopy]
        ?: [NSMutableDictionary dictionary];

    // The original app keeps the advanced font/offset values in its standard
    // defaults rather than the HUD plist. Merge them into the remote snapshot
    // so the renderer has exactly one source of truth.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (HUDUserDefaultsKey key in @[
        HUDUserDefaultsKeyUsesCustomFontSize,
        HUDUserDefaultsKeyRealCustomFontSize,
        HUDUserDefaultsKeyUsesCustomOffset,
        HUDUserDefaultsKeyRealCustomOffsetX,
        HUDUserDefaultsKeyRealCustomOffsetY,
    ]) {
        id value = [defaults objectForKey:key];
        if (value) preferences[key] = value;
    }
    return preferences;
}

static void ds_append_wav_value(NSMutableData *data, const void *value, NSUInteger size) {
    [data appendBytes:value length:size];
}

static NSURL *ds_silent_wav_url(void) {
    NSURL *cache = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    return [cache URLByAppendingPathComponent:@"trollspeed-silent.wav"];
}

static BOOL ds_write_silent_wav(NSURL *url, NSError **error) {
    const uint32_t sampleRate = 8000;
    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint16_t blockAlign = channels * (bitsPerSample / 8);
    const uint32_t byteRate = sampleRate * blockAlign;
    const uint32_t dataSize = sampleRate * blockAlign;
    const uint32_t riffSize = 36 + dataSize;
    const uint32_t formatSize = 16;
    const uint16_t pcmFormat = 1;

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataSize];
    [wav appendBytes:"RIFF" length:4];
    ds_append_wav_value(wav, &riffSize, sizeof(riffSize));
    [wav appendBytes:"WAVEfmt " length:8];
    ds_append_wav_value(wav, &formatSize, sizeof(formatSize));
    ds_append_wav_value(wav, &pcmFormat, sizeof(pcmFormat));
    ds_append_wav_value(wav, &channels, sizeof(channels));
    ds_append_wav_value(wav, &sampleRate, sizeof(sampleRate));
    ds_append_wav_value(wav, &byteRate, sizeof(byteRate));
    ds_append_wav_value(wav, &blockAlign, sizeof(blockAlign));
    ds_append_wav_value(wav, &bitsPerSample, sizeof(bitsPerSample));
    [wav appendBytes:"data" length:4];
    ds_append_wav_value(wav, &dataSize, sizeof(dataSize));
    [wav increaseLengthBy:dataSize];
    return [wav writeToURL:url options:NSDataWritingAtomic error:error];
}

static BOOL ds_start_keepalive(void) {
    __block BOOL started = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (g_keepAlivePlayer.playing) {
            started = YES;
            return;
        }

        NSError *error = nil;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        if (![session setCategory:AVAudioSessionCategoryPlayback
                             mode:AVAudioSessionModeDefault
                          options:AVAudioSessionCategoryOptionMixWithOthers
                            error:&error] ||
            ![session setActive:YES error:&error]) {
            ds_set_error([NSString stringWithFormat:@"后台保持启动失败：%@", error.localizedDescription]);
            return;
        }

        NSURL *wavURL = ds_silent_wav_url();
        if (![[NSFileManager defaultManager] fileExistsAtPath:wavURL.path] &&
            !ds_write_silent_wav(wavURL, &error)) {
            ds_set_error([NSString stringWithFormat:@"后台资源准备失败：%@", error.localizedDescription]);
            return;
        }

        g_keepAlivePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:wavURL error:&error];
        g_keepAlivePlayer.numberOfLoops = -1;
        g_keepAlivePlayer.volume = 0.0f;
        [g_keepAlivePlayer prepareToPlay];
        started = [g_keepAlivePlayer play];
        if (!started) {
            ds_set_error([NSString stringWithFormat:@"后台保持播放失败：%@", error.localizedDescription]);
            g_keepAlivePlayer = nil;
        }
    });
    return started;
}

static void ds_stop_keepalive(void) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [g_keepAlivePlayer stop];
        g_keepAlivePlayer = nil;
        [AVAudioSession.sharedInstance setActive:NO
                                     withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                           error:nil];
    });
}

static void ds_read_network_bytes(uint64_t *input, uint64_t *output) {
    *input = 0;
    *output = 0;
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return;

    for (struct ifaddrs *interface = interfaces; interface; interface = interface->ifa_next) {
        if (!interface->ifa_name || !interface->ifa_addr || !interface->ifa_data) continue;
        if (interface->ifa_addr->sa_family != AF_LINK) continue;
        if (!(interface->ifa_flags & IFF_UP) && !(interface->ifa_flags & IFF_RUNNING)) continue;
        if (strncmp(interface->ifa_name, "en", 2) && strncmp(interface->ifa_name, "pdp_ip", 6)) continue;

        struct if_data *data = (struct if_data *)interface->ifa_data;
        *input += data->ifi_ibytes;
        *output += data->ifi_obytes;
    }
    freeifaddrs(interfaces);
}

static BOOL ds_pref_bool(NSDictionary *preferences, HUDUserDefaultsKey key) {
    return [preferences[key] boolValue];
}

static CGFloat ds_pref_double(NSDictionary *preferences, HUDUserDefaultsKey key,
                              CGFloat fallback) {
    NSNumber *number = preferences[key];
    return number ? number.doubleValue : fallback;
}

static NSString *ds_format_speed(double bytes, BOOL bitrate, BOOL focused) {
    double value = bitrate ? bytes * 8.0 : bytes;
    double kilo = bitrate ? 1000.0 : 1024.0;
    double mega = kilo * kilo;
    double giga = mega * kilo;
    NSString *suffix = focused ? @"" : @"/s";
    NSString *kiloUnit = bitrate ? @"Kb" : @"KB";
    NSString *megaUnit = bitrate ? @"Mb" : @"MB";
    NSString *gigaUnit = bitrate ? @"Gb" : @"GB";

    if (value < kilo) {
        return [NSString stringWithFormat:@"0\u00a0%@%@", kiloUnit, suffix];
    }
    if (value < mega) {
        return [NSString stringWithFormat:@"%.0f\u00a0%@%@", value / kilo, kiloUnit, suffix];
    }
    if (value < giga) {
        return [NSString stringWithFormat:@"%.2f\u00a0%@%@", value / mega, megaUnit, suffix];
    }
    return [NSString stringWithFormat:@"%.2f\u00a0%@%@", value / giga, gigaUnit, suffix];
}

static UIInterfaceOrientation ds_interface_orientation(void) {
    UIInterfaceOrientation remoteOrientation =
        (UIInterfaceOrientation)g_remoteOrientation.load();
    if (remoteOrientation != UIInterfaceOrientationUnknown) {
        return remoteOrientation;
    }
    __block UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) continue;
            orientation = windowScene.interfaceOrientation;
            break;
        }
    });
    return orientation;
}

static void ds_screen_geometry(CGRect *bounds, UIEdgeInsets *safeInsets) {
    __block CGRect currentBounds = UIScreen.mainScreen.bounds;
    __block UIEdgeInsets currentInsets = UIEdgeInsetsZero;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) continue;
            currentBounds = windowScene.coordinateSpace.bounds;
            for (UIWindow *window in windowScene.windows) {
                if (window.safeAreaInsets.top > currentInsets.top) {
                    currentInsets = window.safeAreaInsets;
                }
            }
            break;
        }
    });
    if (bounds) *bounds = currentBounds;
    if (safeInsets) *safeInsets = currentInsets;
}

static NSString *ds_display_text(NSDictionary *preferences,
                                 BOOL centered,
                                 BOOL focused,
                                 double down,
                                 double up) {
    if (ds_pref_bool(preferences, HUDUserDefaultsKeyDisplayMode)) {
        CFIndex current = CARenderServerGetDirtyFrameCount(NULL);
        if (g_needsFPSBaselineReset) {
            g_previousDirtyFrameCount = current;
            g_needsFPSBaselineReset = NO;
            return @"0 FPS";
        }
        CFIndex frameDiff = MAX((CFIndex)0, current - g_previousDirtyFrameCount);
        g_previousDirtyFrameCount = current;
        CGFloat maximumFPS = UIScreen.mainScreen.maximumFramesPerSecond;
        return [NSString stringWithFormat:@"%.0f FPS", MIN((CGFloat)frameDiff, maximumFPS)];
    }

    BOOL bitrate = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesBitrate);
    BOOL alternateArrows = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesArrowPrefixes);
    BOOL incomingOnly = ds_pref_bool(preferences, HUDUserDefaultsKeySingleLineMode);
    NSString *downloadPrefix = alternateArrows ? @"↓" : @"▼";
    NSString *uploadPrefix = alternateArrows ? @"↑" : @"▲";
    NSString *download = [NSString stringWithFormat:@"%@\u00a0%@",
                          downloadPrefix, ds_format_speed(down, bitrate, focused)];
    if (incomingOnly) return download;

    NSString *upload = [NSString stringWithFormat:@"%@\u00a0%@",
                        uploadPrefix, ds_format_speed(up, bitrate, focused)];
    return centered
        ? [NSString stringWithFormat:@"%@\t%@", download, upload]
        : [NSString stringWithFormat:@"%@\n%@", upload, download];
}

static DSHUDPresentation ds_hud_presentation(NSDictionary *preferences,
                                             NSString *text) {
    DSHUDPresentation presentation = {};
    UIInterfaceOrientation orientation = ds_interface_orientation();
    presentation.landscape = UIInterfaceOrientationIsLandscape(orientation);

    HUDUserDefaultsKey modeKey = presentation.landscape
        ? HUDUserDefaultsKeySelectedModeLandscape
        : HUDUserDefaultsKeySelectedMode;
    NSNumber *storedMode = preferences[modeKey];
    HUDPresetPosition mode = storedMode
        ? (HUDPresetPosition)storedMode.integerValue
        : HUDPresetPositionTopCenter;
    presentation.centered =
        mode == HUDPresetPositionTopCenter || mode == HUDPresetPositionTopCenterMost;
    presentation.centeredMost = mode == HUDPresetPositionTopCenterMost;
    presentation.singleLine = ds_pref_bool(preferences, HUDUserDefaultsKeySingleLineMode);
    presentation.bitrate = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesBitrate);
    presentation.arrowPrefixes = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesArrowPrefixes);
    presentation.inverted = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesInvertedColor);
    presentation.followsRotation = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesRotation);
    presentation.hideAtSnapshot = ds_pref_bool(preferences, HUDUserDefaultsKeyHideAtSnapshot);
    presentation.displayFPS = ds_pref_bool(preferences, HUDUserDefaultsKeyDisplayMode);
    presentation.passthrough = ds_pref_bool(preferences, HUDUserDefaultsKeyPassthroughMode);

    BOOL customFont = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesCustomFontSize);
    if (customFont) {
        presentation.fontSize = MIN(MAX(ds_pref_double(
            preferences, HUDUserDefaultsKeyRealCustomFontSize, kDSHUDMinFontSize), 8.0), 12.0);
        presentation.cornerRadius = presentation.fontSize / 2.0;
    } else {
        BOOL large = ds_pref_bool(preferences, HUDUserDefaultsKeyUsesLargeFont);
        presentation.fontSize = large ? kDSHUDMaxFontSize : kDSHUDMinFontSize;
        presentation.cornerRadius = large ? kDSHUDMaxCornerRadius : kDSHUDMinCornerRadius;
    }
    presentation.inactiveOpacity = presentation.inverted ? 1.0 : kDSHUDInactiveOpacity;
    presentation.numberOfLines = presentation.centered || presentation.singleLine ? 1 : 2;
    presentation.alignment = presentation.centered ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    presentation.maskedCorners =
        presentation.centeredMost && !presentation.landscape
            ? kDSCornerMaskBottom
            : kDSCornerMaskAll;

    UIFontWeight weight = presentation.inverted ? UIFontWeightMedium : UIFontWeightRegular;
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:presentation.fontSize weight:weight];
    CGRect measured = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                        options:NSStringDrawingUsesLineFragmentOrigin |
                                                NSStringDrawingUsesFontLeading
                                     attributes:@{NSFontAttributeName: font}
                                        context:nil];
    CGSize labelSize = CGSizeMake(ceil(measured.size.width), ceil(measured.size.height));
    if (labelSize.width < 1) labelSize.width = 1;
    if (labelSize.height < 1) labelSize.height = ceil(font.lineHeight);
    CGSize hudSize = CGSizeMake(labelSize.width + 8.0, labelSize.height + 4.0);

    CGRect screenBounds;
    UIEdgeInsets safeInsets;
    ds_screen_geometry(&screenBounds, &safeInsets);
    CGFloat realOffsetX = 0;
    CGFloat realOffsetY = 0;
    if (ds_pref_bool(preferences, HUDUserDefaultsKeyUsesCustomOffset)) {
        realOffsetX = -ds_pref_double(preferences, HUDUserDefaultsKeyRealCustomOffsetX, 0);
        realOffsetY = ds_pref_double(preferences, HUDUserDefaultsKeyRealCustomOffsetY, 0);
    }

    CGFloat x = CGRectGetMidX(screenBounds) - hudSize.width / 2.0;
    if (mode == HUDPresetPositionTopLeft) {
        x = CGRectGetMinX(screenBounds) + safeInsets.left + 10.0 + realOffsetX;
    } else if (mode == HUDPresetPositionTopRight) {
        x = CGRectGetMaxX(screenBounds) - safeInsets.right - 10.0 - hudSize.width + realOffsetX;
    }

    CGFloat y;
    if (presentation.centeredMost && !presentation.landscape) {
        y = CGRectGetMinY(screenBounds);
    } else if (presentation.landscape) {
        CGFloat minimumTop = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? 30.0 : 10.0;
        minimumTop += realOffsetY;
        NSNumber *saved = preferences[HUDUserDefaultsKeyCurrentLandscapePositionY];
        CGFloat topConstant = (!presentation.centered && saved) ? saved.doubleValue : minimumTop;
        y = CGRectGetMinY(screenBounds) + topConstant;
    } else {
        CGFloat minimumTop;
        if (safeInsets.top >= 51.0) minimumTop = -8.0;
        else if (safeInsets.top > 30.0) minimumTop = -12.0;
        else minimumTop = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
            ? 30.0 : 20.0;
        minimumTop += realOffsetY;
        NSNumber *saved = preferences[HUDUserDefaultsKeyCurrentPositionY];
        CGFloat topConstant = (!presentation.centered && saved) ? saved.doubleValue : minimumTop;
        y = CGRectGetMinY(screenBounds) + safeInsets.top + topConstant;
    }

    presentation.windowFrame = CGRectMake(round(x), round(y), hudSize.width, hudSize.height);
    presentation.blurFrame = CGRectMake(0, 0, hudSize.width, hudSize.height);
    presentation.labelFrame = CGRectMake(4, 2, labelSize.width, labelSize.height);
    return presentation;
}

static void ds_reset_remote_symbol_cache(void) {
    g_remoteSelectorCache = [NSMutableDictionary dictionary];
    g_remoteClassCache = [NSMutableDictionary dictionary];
}

static uint64_t ds_remote_sel(RemoteCall *process, const char *name) {
    if (!process || !process.trojanMem || !name) return 0;
    if (!g_remoteSelectorCache) g_remoteSelectorCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return 0;
    NSNumber *cached = g_remoteSelectorCache[key];
    if (cached) return cached.unsignedLongLongValue;
    uint64_t value = remote_sel(process, name);
    if (value) g_remoteSelectorCache[key] = @(value);
    return value;
}

static uint64_t ds_remote_class(RemoteCall *process, const char *name) {
    if (!process || !process.trojanMem || !name) return 0;
    if (!g_remoteClassCache) g_remoteClassCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithUTF8String:name];
    if (!key) return 0;
    NSNumber *cached = g_remoteClassCache[key];
    if (cached) return cached.unsignedLongLongValue;
    uint64_t value = remote_getClass(process, name);
    if (value) g_remoteClassCache[key] = @(value);
    return value;
}

// The rate label changes every second. Keep its UTF-8 bytes in one reserved
// page instead of doing remote malloc/write/free for every sample. The latter
// eventually filled RemoteCall's finite shared-page cache and turned a failed
// write into a bogus Objective-C selector inside SpringBoard.
static uint64_t ds_remote_create_string(RemoteCall *process, NSString *value) {
    if (!process || !process.trojanMem || !value) return 0;
    const char *utf8 = value.UTF8String;
    if (!utf8) return 0;
    size_t length = strlen(utf8) + 1;
    if (length > kDSRemoteTextScratchCapacity) return 0;

    uint64_t scratch = process.trojanMem + kDSRemoteTextScratchOffset;
    if (![process remote_write:scratch from:utf8 size:length]) return 0;

    uint64_t stringClass = ds_remote_class(process, "NSString");
    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t init = ds_remote_sel(process, "initWithUTF8String:");
    if (!stringClass || !alloc || !init) return 0;
    uint64_t object = remote_msg(process, stringClass, alloc, 0, 0, 0, 0);
    if (!object) return 0;
    uint64_t string = remote_msg(process, object, init, scratch, 0, 0, 0);
    if (!string) {
        uint64_t release = ds_remote_sel(process, "release");
        if (release) remote_msg(process, object, release, 0, 0, 0, 0);
    }
    return string;
}

static BOOL ds_perform_on_springboard_main(RemoteCall *process, uint64_t target,
                                           uint64_t selector, uint64_t argument,
                                           BOOL waitUntilDone) {
    if (!process || !process.trojanMem || !target || !selector) return NO;
    uint64_t perform = ds_remote_sel(process, "performSelectorOnMainThread:withObject:waitUntilDone:");
    if (!perform) return NO;
    // a0=selector, a1=object, a2=waitUntilDone (BOOL as uint64 on little-endian).
    remote_msg(process, target, perform, selector, argument, waitUntilDone ? 1 : 0, 0);
    return process.trojanMem != 0;
}

static BOOL ds_remote_set_text_on_main(RemoteCall *process, uint64_t label,
                                       NSString *text) {
    uint64_t remoteText = ds_remote_create_string(process, text);
    if (!remoteText) return NO;
    BOOL sent = ds_perform_on_springboard_main(
        process, label, ds_remote_sel(process, "setText:"), remoteText, YES);
    uint64_t release = ds_remote_sel(process, "release");
    if (release && process.trojanMem) {
        remote_msg(process, remoteText, release, 0, 0, 0, 0);
    }
    return sent;
}

typedef struct {
    const void *bytes;
    uint64_t size;
} DSRemoteArgument;

// RemoteCall's doRemoteCallSyncOnMainThread assumes task->threads.next is the
// main thread. On iOS 17 it can be RemoteCall's newly-created pthread instead,
// which makes UIView initialization abort SpringBoard under
// CA_ASSERT_MAIN_THREAD_TRANSACTIONS. Build an NSInvocation on the call thread,
// then synchronously ask NSObject to invoke it on SpringBoard's real main thread.
static BOOL ds_remote_invoke_on_main_result(RemoteCall *process, uint64_t target,
                                            uint64_t selector,
                                            const DSRemoteArgument *arguments,
                                            NSUInteger argumentCount,
                                            void *result,
                                            NSUInteger resultSize) {
    if (!process || !target || !selector || !process.trojanMem) return NO;

    uint64_t poolClass = ds_remote_class(process, "NSAutoreleasePool");
    uint64_t allocSelector = ds_remote_sel(process, "alloc");
    uint64_t initSelector = ds_remote_sel(process, "init");
    uint64_t drainSelector = ds_remote_sel(process, "drain");
    uint64_t autoreleasePool = poolClass && allocSelector && initSelector && drainSelector
        ? remote_msg(process,
                     remote_msg(process, poolClass, allocSelector, 0, 0, 0, 0),
                     initSelector, 0, 0, 0, 0)
        : 0;
    if (!autoreleasePool) return NO;

    @try {

    uint64_t signature = remote_msg(process, target,
                                    ds_remote_sel(process, "methodSignatureForSelector:"),
                                    selector, 0, 0, 0);
    if (!process.trojanMem) return NO;
    uint64_t invocationClass = ds_remote_class(process, "NSInvocation");
    uint64_t invocation = signature && invocationClass
        ? remote_msg(process, invocationClass,
                     ds_remote_sel(process, "invocationWithMethodSignature:"),
                     signature, 0, 0, 0)
        : 0;
    if (!invocation || !process.trojanMem) return NO;

    remote_msg(process, invocation, ds_remote_sel(process, "setTarget:"), target, 0, 0, 0);
    if (!process.trojanMem) return NO;
    remote_msg(process, invocation, ds_remote_sel(process, "setSelector:"), selector, 0, 0, 0);
    if (!process.trojanMem) return NO;

    uint64_t scratch = process.trojanMem + 0x800;
    for (NSUInteger index = 0; index < argumentCount; index++) {
        if (!arguments[index].bytes || arguments[index].size == 0 ||
            ![process remote_write:scratch
                              from:arguments[index].bytes
                              size:arguments[index].size]) {
            return NO;
        }
        remote_msg(process, invocation, ds_remote_sel(process, "setArgument:atIndex:"),
                   scratch, index + 2, 0, 0);
        if (!process.trojanMem) return NO;
        scratch += (arguments[index].size + 15) & ~15ULL;
    }

    ds_perform_on_springboard_main(process, invocation,
                                   ds_remote_sel(process, "invoke"), 0, YES);
    if (!process.trojanMem) return NO;
    if (result && resultSize > 0) {
        uint64_t resultScratch = process.trojanMem + 0xC00;
        memset(result, 0, resultSize);
        if (![process remote_write:resultScratch from:result size:resultSize]) return NO;
        remote_msg(process, invocation, ds_remote_sel(process, "getReturnValue:"),
                   resultScratch, 0, 0, 0);
        if (!process.trojanMem) return NO;
        if (![process remoteRead:resultScratch to:result size:resultSize]) return NO;
    }
    return YES;
    } @finally {
        if (process.trojanMem) {
            remote_msg(process, autoreleasePool, drainSelector, 0, 0, 0, 0);
        }
    }
}

static BOOL ds_remote_invoke_on_main(RemoteCall *process, uint64_t target,
                                     uint64_t selector,
                                     const DSRemoteArgument *arguments,
                                     NSUInteger argumentCount) {
    return ds_remote_invoke_on_main_result(process, target, selector,
                                           arguments, argumentCount, NULL, 0);
}

static BOOL ds_remote_invoke_noarg_on_main(RemoteCall *process, uint64_t target,
                                           const char *selectorName) {
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    NULL, 0);
}

static uint64_t ds_remote_get_object_on_main(RemoteCall *process, uint64_t target,
                                             const char *selectorName) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName), NULL, 0,
        &result, sizeof(result));
    return invoked ? result : 0;
}

static uint64_t ds_remote_get_retained_object_on_main(
    RemoteCall *process, uint64_t target, const char *selectorName,
    const DSRemoteArgument *arguments, NSUInteger argumentCount) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName),
        arguments, argumentCount, &result, sizeof(result));
    if (!invoked || !result || !process.trojanMem) return 0;

    // Retain immediately after the synchronous main-thread return. This keeps
    // factory results alive across later performSelector turns and prevents the
    // dangling-object crash seen with the former UIColor factory result.
    remote_msg(process, result, ds_remote_sel(process, "retain"), 0, 0, 0, 0);
    return process.trojanMem ? result : 0;
}

static BOOL ds_remote_set_u64_on_main(RemoteCall *process, uint64_t target,
                                      const char *selectorName, uint64_t value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static uint64_t ds_remote_get_u64_on_main(RemoteCall *process, uint64_t target,
                                          const char *selectorName) {
    uint64_t result = 0;
    BOOL invoked = ds_remote_invoke_on_main_result(
        process, target, ds_remote_sel(process, selectorName), NULL, 0,
        &result, sizeof(result));
    return invoked ? result : 0;
}

static BOOL ds_remote_set_double_on_main(RemoteCall *process, uint64_t target,
                                         const char *selectorName, double value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static BOOL ds_remote_set_rect_on_main(RemoteCall *process, uint64_t target,
                                       const char *selectorName, CGRect value) {
    DSRemoteArgument argument = { &value, sizeof(value) };
    return ds_remote_invoke_on_main(process, target, ds_remote_sel(process, selectorName),
                                    &argument, 1);
}

static uint64_t ds_remote_font(RemoteCall *process, CGFloat size, BOOL medium) {
    uint64_t fontClass = ds_remote_class(process, "UIFont");
    if (!fontClass) return 0;
    double pointSize = size;
    double weight = medium ? UIFontWeightMedium : UIFontWeightRegular;
    DSRemoteArgument arguments[] = {
        { &pointSize, sizeof(pointSize) },
        { &weight, sizeof(weight) },
    };
    return ds_remote_get_retained_object_on_main(
        process, fontClass, "monospacedDigitSystemFontOfSize:weight:",
        arguments, 2);
}

static uint64_t ds_remote_secure_canvas(RemoteCall *process, uint64_t textField) {
    uint64_t canvasClass = ds_remote_class(process, "_UITextLayoutCanvasView");
    uint64_t subviews = ds_remote_get_retained_object_on_main(
        process, textField, "subviews", NULL, 0);
    if (!canvasClass || !subviews) return 0;

    uint64_t count = ds_remote_get_u64_on_main(process, subviews, "count");
    count = MIN(count, 16);
    for (uint64_t index = 0; index < count; index++) {
        DSRemoteArgument argument = { &index, sizeof(index) };
        uint64_t view = 0;
        if (!ds_remote_invoke_on_main_result(
                process, subviews, ds_remote_sel(process, "objectAtIndex:"),
                &argument, 1, &view, sizeof(view)) || !view) {
            continue;
        }
        uint64_t viewClass = ds_remote_get_object_on_main(process, view, "class");
        if (viewClass == canvasClass) return view;
    }
    return 0;
}

static BOOL ds_apply_snapshot_container(RemoteCall *process, BOOL hideAtSnapshot) {
    if (!process || !g_remoteWindow || !g_remoteContainer) return NO;
    BOOL canHide = g_remoteSecureField && g_remoteSecureCanvas;
    BOOL shouldHide = hideAtSnapshot && canHide;
    if (g_remoteSecureField) {
        ds_remote_set_u64_on_main(process, g_remoteSecureField,
                                  "setSecureTextEntry:", shouldHide ? 1 : 0);
    }
    uint64_t parent = shouldHide ? g_remoteSecureCanvas : g_remoteWindow;
    ds_perform_on_springboard_main(process, parent,
                                   ds_remote_sel(process, "addSubview:"),
                                   g_remoteContainer, YES);
    g_lastHideAtSnapshot = hideAtSnapshot;
    if (hideAtSnapshot && !canHide) {
        ds_append_checkpoint(@"截图隐藏容器不可用，已保持普通显示");
    }
    return !hideAtSnapshot || canHide;
}

// The HUD lives in its own UIWindow anchored to SBMainWorkspace.mainWindowScene
// Adding to whatever keyWindow we can find is
// unreliable — that window may be hidden, tiny, or off-screen.
static uint64_t ds_create_springboard_hud(RemoteCall *process) {
    NSDictionary *preferences = ds_hud_preferences();
    DSHUDPresentation probe = ds_hud_presentation(preferences, @"0");
    NSString *text = ds_display_text(preferences, probe.centered, YES, 0, 0);
    DSHUDPresentation presentation = ds_hud_presentation(preferences, text);

    uint64_t alloc = ds_remote_sel(process, "alloc");
    uint64_t workspaceClass = ds_remote_class(process, "SBMainWorkspace");
    uint64_t windowClass = ds_remote_class(process, "UIWindow");
    uint64_t viewClass = ds_remote_class(process, "UIView");
    uint64_t labelClass = ds_remote_class(process, "UILabel");
    uint64_t textFieldClass = ds_remote_class(process, "UITextField");
    uint64_t colorClass = ds_remote_class(process, "UIColor");
    if (!workspaceClass || !windowClass || !viewClass ||
        !labelClass || !textFieldClass || !colorClass) return 0;

    uint64_t workspace = ds_remote_get_object_on_main(
        process, workspaceClass, "sharedInstance");
    uint64_t scene = workspace
        ? ds_remote_get_object_on_main(process, workspace, "mainWindowScene")
        : 0;
    if (!scene) return 0;

    uint64_t window = remote_msg(process, windowClass, alloc, 0, 0, 0, 0);
    uint64_t container = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    uint64_t label = remote_msg(process, labelClass, alloc, 0, 0, 0, 0);
    uint64_t secureField = remote_msg(process, textFieldClass, alloc, 0, 0, 0, 0);
    // Safety renderer: keep the SpringBoard hierarchy to plain UIKit objects.
    // UIVisualEffectView/CABackdropLayer is intentionally not used here because
    // it starts extra render-server work immediately after RemoteCall setup.
    uint64_t blurView = remote_msg(process, viewClass, alloc, 0, 0, 0, 0);
    if (!window || !container || !label || !secureField || !blurView) return 0;
    if (!ds_remote_invoke_noarg_on_main(process, window, "init") ||
        !ds_remote_invoke_noarg_on_main(process, container, "init") ||
        !ds_remote_invoke_noarg_on_main(process, label, "init") ||
        !ds_remote_invoke_noarg_on_main(process, secureField, "init") ||
        !ds_remote_invoke_noarg_on_main(process, blurView, "init")) {
        return 0;
    }

    ds_remote_set_rect_on_main(process, window, "setFrame:", presentation.windowFrame);
    ds_perform_on_springboard_main(process, window, ds_remote_sel(process, "setWindowScene:"), scene, YES);
    ds_remote_set_double_on_main(process, window, "setWindowLevel:", UIWindowLevelStatusBar + 1.0);
    ds_remote_set_u64_on_main(process, window, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, window, "setOpaque:", 0);

    ds_remote_set_rect_on_main(process, container, "setFrame:", presentation.blurFrame);
    ds_remote_set_rect_on_main(process, blurView, "setFrame:", presentation.blurFrame);
    ds_remote_set_rect_on_main(process, label, "setFrame:", presentation.labelFrame);
    ds_remote_set_rect_on_main(process, secureField, "setFrame:", presentation.blurFrame);

    uint64_t clear = ds_remote_get_object_on_main(process, colorClass, "clearColor");
    uint64_t white = ds_remote_get_object_on_main(process, colorClass, "whiteColor");
    uint64_t black = ds_remote_get_object_on_main(process, colorClass, "blackColor");
    // Do not pass autoreleased factory results across separate main-thread
    // performSelector turns. The prior colorWithWhite:alpha: result was already
    // dead by setBackgroundColor:, producing SIGBUS in object_getClass.
    uint64_t safeBackground = ds_remote_get_object_on_main(
        process, colorClass, "darkGrayColor");
    if (!clear || !white || !black || !safeBackground) return 0;

    ds_perform_on_springboard_main(process, window,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, container,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, secureField,
                                   ds_remote_sel(process, "setBackgroundColor:"), clear, YES);
    ds_perform_on_springboard_main(process, blurView,
                                   ds_remote_sel(process, "setBackgroundColor:"),
                                   presentation.inverted ? white : safeBackground, YES);
    ds_remote_set_u64_on_main(process, container, "setTag:", (uint64_t)kDSSpringBoardHUDTag);
    ds_remote_set_u64_on_main(process, container, "setHidden:", 0);
    ds_remote_set_u64_on_main(process, container, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, container, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, blurView, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, secureField, "setAutoresizingMask:",
                              UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    ds_remote_set_u64_on_main(process, secureField, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, secureField, "setOpaque:", 0);
    ds_perform_on_springboard_main(process, label,
                                   ds_remote_sel(process, "setTextColor:"),
                                   presentation.inverted ? black : white, YES);
    ds_remote_set_u64_on_main(process, label, "setNumberOfLines:",
                              (uint64_t)presentation.numberOfLines);
    ds_remote_set_u64_on_main(process, label, "setHidden:", 0);
    uint64_t font = ds_remote_font(process, presentation.fontSize,
                                   presentation.inverted);
    if (!font) return 0;
    ds_perform_on_springboard_main(process, label,
                                   ds_remote_sel(process, "setFont:"), font, YES);
    ds_remote_set_u64_on_main(process, label, "setAdjustsFontSizeToFitWidth:", 0);
    ds_remote_set_u64_on_main(process, label, "setUserInteractionEnabled:", 0);
    ds_remote_set_u64_on_main(process, label, "setTextAlignment:",
                              (uint64_t)presentation.alignment);
    ds_remote_set_double_on_main(process, label, "setAlpha:", 0.85);

    uint64_t layer = ds_remote_get_object_on_main(process, blurView, "layer");
    if (layer) {
        ds_remote_set_double_on_main(process, layer, "setCornerRadius:",
                                     presentation.cornerRadius);
        ds_remote_set_u64_on_main(process, layer, "setMasksToBounds:", 1);
        ds_remote_set_u64_on_main(process, layer, "setMaskedCorners:",
                                  (uint64_t)presentation.maskedCorners);
    }
    ds_remote_set_double_on_main(process, container, "setAlpha:", 1.0);

    if (!process.trojanMem) return 0;
    if (!ds_remote_set_text_on_main(process, label, text)) return 0;
    ds_perform_on_springboard_main(process, blurView,
                                   ds_remote_sel(process, "addSubview:"), label, YES);
    ds_perform_on_springboard_main(process, container,
                                   ds_remote_sel(process, "addSubview:"), blurView, YES);
    ds_perform_on_springboard_main(process, window,
                                   ds_remote_sel(process, "addSubview:"), secureField, YES);

    g_remoteWindow = window;
    g_remoteContainer = container;
    g_remoteSecureField = secureField;
    g_remoteSecureCanvas = ds_remote_secure_canvas(process, secureField);
    ds_apply_snapshot_container(process, presentation.hideAtSnapshot);
    ds_remote_set_u64_on_main(process, window, "setHidden:", 0);

    g_remoteWindowScene = scene;
    g_remoteWindowPid = process.pid;
    g_remoteBlurView = blurView;
    g_remoteBlurEffect = 0;
    g_lastPresentationSignature = preferences.description.hash ^
                                  (NSUInteger)ds_interface_orientation();
    g_lastWindowFrame = presentation.windowFrame;
    g_lastLabelFrame = presentation.labelFrame;
    g_lastWindowHidden = NO;
    g_lastContainerAlpha = 1.0;
    g_lastFontSize = presentation.fontSize;
    g_lastInverted = presentation.inverted;
    g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
    return label;
}

// Never release remote UIViews: dealloc on a hijacked thread crashes SpringBoard
// (same CA main-thread assert). removeFromSuperview + hide, and intentionally
// leak the tiny view hierarchy for the lifetime of the remote session.
static void ds_remove_springboard_hud(RemoteCall *process) {
    if (!g_remoteWindow || g_remoteWindowPid != process.pid) return;
    if (g_remoteContainer) {
        ds_perform_on_springboard_main(process, g_remoteContainer,
                                       ds_remote_sel(process, "removeFromSuperview"), 0, YES);
    }
    ds_remote_set_u64_on_main(process, g_remoteWindow, "setHidden:", 1);
}

static BOOL ds_apply_remote_presentation(RemoteCall *process,
                                         const DSHUDPresentation *presentation,
                                         NSString *text,
                                         BOOL focused,
                                         BOOL applyStyle) {
    if (!process || !presentation || !g_remoteWindow || !g_remoteContainer ||
        !g_remoteBlurView || !g_remoteLabel) {
        return NO;
    }

    if (!CGRectEqualToRect(g_lastWindowFrame, presentation->windowFrame)) {
        ds_remote_set_rect_on_main(process, g_remoteWindow, "setFrame:",
                                   presentation->windowFrame);
        ds_remote_set_rect_on_main(process, g_remoteContainer, "setFrame:",
                                   presentation->blurFrame);
        ds_remote_set_rect_on_main(process, g_remoteBlurView, "setFrame:",
                                   presentation->blurFrame);
        if (g_remoteSecureField) {
            ds_remote_set_rect_on_main(process, g_remoteSecureField, "setFrame:",
                                       presentation->blurFrame);
        }
        g_lastWindowFrame = presentation->windowFrame;
    }
    if (!CGRectEqualToRect(g_lastLabelFrame, presentation->labelFrame)) {
        ds_remote_set_rect_on_main(process, g_remoteLabel, "setFrame:",
                                   presentation->labelFrame);
        g_lastLabelFrame = presentation->labelFrame;
    }

    BOOL hideForLandscape = presentation->landscape && !presentation->followsRotation;
    BOOL shouldHide = hideForLandscape || g_deviceLocked.load();
    if (shouldHide != g_lastWindowHidden) {
        ds_remote_set_u64_on_main(process, g_remoteWindow, "setHidden:", shouldHide ? 1 : 0);
        g_lastWindowHidden = shouldHide;
    }
    if (applyStyle) {
        ds_remote_set_u64_on_main(process, g_remoteLabel, "setNumberOfLines:",
                                  (uint64_t)presentation->numberOfLines);
        ds_remote_set_u64_on_main(process, g_remoteLabel, "setTextAlignment:",
                                  (uint64_t)presentation->alignment);

        uint64_t colorClass = ds_remote_class(process, "UIColor");
        uint64_t white = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "whiteColor") : 0;
        uint64_t black = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "blackColor") : 0;
        uint64_t darkGray = colorClass
            ? ds_remote_get_object_on_main(process, colorClass, "darkGrayColor") : 0;
        uint64_t textColor = presentation->inverted ? black : white;
        uint64_t backgroundColor = presentation->inverted ? white : darkGray;
        if (textColor && backgroundColor) {
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setTextColor:"), textColor, YES);
            ds_perform_on_springboard_main(process, g_remoteBlurView,
                                           ds_remote_sel(process, "setBackgroundColor:"),
                                           backgroundColor, YES);
        }

        if (fabs(g_lastFontSize - presentation->fontSize) > 0.001 ||
            g_lastInverted != presentation->inverted) {
            uint64_t font = ds_remote_font(process, presentation->fontSize,
                                           presentation->inverted);
            if (!font) return NO;
            ds_perform_on_springboard_main(process, g_remoteLabel,
                                           ds_remote_sel(process, "setFont:"), font, YES);
            g_lastFontSize = presentation->fontSize;
            g_lastInverted = presentation->inverted;
        }

        uint64_t layer = ds_remote_get_object_on_main(process, g_remoteBlurView, "layer");
        if (layer) {
            ds_remote_set_double_on_main(process, layer, "setCornerRadius:",
                                         presentation->cornerRadius);
            ds_remote_set_u64_on_main(process, layer, "setMaskedCorners:",
                                      (uint64_t)presentation->maskedCorners);
        }

        if (g_lastHideAtSnapshot != presentation->hideAtSnapshot) {
            ds_apply_snapshot_container(process, presentation->hideAtSnapshot);
        }
    }
    CGFloat alpha = focused ? 1.0 : presentation->inactiveOpacity;
    if (fabs(g_lastContainerAlpha - alpha) > 0.001) {
        ds_remote_set_double_on_main(process, g_remoteContainer, "setAlpha:", alpha);
        g_lastContainerAlpha = alpha;
    }

    if (!process.trojanMem) return NO;
    return ds_remote_set_text_on_main(process, g_remoteLabel, text);
}

static void ds_update_rate(void) {
    if (!g_hudRequested.load() || !g_hudActive.load() || !g_springBoard || !g_remoteLabel) return;

    uint64_t input = 0;
    uint64_t output = 0;
    ds_read_network_bytes(&input, &output);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double interval = g_previousSampleTime > 0 ? MAX(now - g_previousSampleTime, 0.1) : 1.0;
    double down = g_previousSampleTime > 0 && input >= g_previousInput ? (input - g_previousInput) / interval : 0;
    double up = g_previousSampleTime > 0 && output >= g_previousOutput ? (output - g_previousOutput) / interval : 0;
    g_previousInput = input;
    g_previousOutput = output;
    g_previousSampleTime = now;

    if (g_remoteWindowScene) {
        uint64_t orientation = ds_remote_get_u64_on_main(
            g_springBoard, g_remoteWindowScene, "interfaceOrientation");
        if (orientation <= UIInterfaceOrientationLandscapeRight) {
            g_remoteOrientation.store((int)orientation);
        }
    }

    NSDictionary *preferences = ds_hud_preferences();
    DSHUDPresentation probe = ds_hud_presentation(preferences, @"0");
    BOOL focused = now < g_focusUntil;
    NSString *text = ds_display_text(
        preferences, probe.centered, focused,
        focused ? (double)input : down,
        focused ? (double)output : up);
    DSHUDPresentation presentation = ds_hud_presentation(preferences, text);
    NSUInteger presentationSignature = preferences.description.hash ^
                                       (NSUInteger)ds_interface_orientation();
    BOOL applyStyle = presentationSignature != g_lastPresentationSignature;

    @try {
        if (!ds_apply_remote_presentation(
                g_springBoard, &presentation, text, focused, applyStyle)) {
            @throw [NSException exceptionWithName:@"DSRemoteHUDUpdate"
                                           reason:@"remote presentation update failed"
                                         userInfo:nil];
        }
        g_lastPresentationSignature = presentationSignature;
    } @catch (NSException *exception) {
        ds_set_error([NSString stringWithFormat:@"SpringBoard HUD update failed: %@", exception.reason]);
        g_hudActive.store(false);
    }
}

static void ds_start_rate_timer(void) {
    if (g_rateTimer) return;
    g_previousInput = 0;
    g_previousOutput = 0;
    g_previousSampleTime = 0;
    g_previousDirtyFrameCount = 0;
    g_needsFPSBaselineReset = YES;
    g_rateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, ds_bridge_queue());
    dispatch_source_set_timer(g_rateTimer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_rateTimer, ^{
        @autoreleasepool {
            ds_update_rate();
        }
    });
    dispatch_resume(g_rateTimer);
}

static void ds_stop_rate_timer(void) {
    if (!g_rateTimer) return;
    dispatch_source_cancel(g_rateTimer);
    g_rateTimer = nil;
}

static void ds_unregister_hud_notifications(void) {
    if (g_reloadHUDToken >= 0) {
        notify_cancel(g_reloadHUDToken);
        g_reloadHUDToken = -1;
    }
    if (g_lockStateToken >= 0) {
        notify_cancel(g_lockStateToken);
        g_lockStateToken = -1;
    }
}

static void ds_register_hud_notifications(void) {
    ds_unregister_hud_notifications();
    notify_register_dispatch(NOTIFY_RELOAD_HUD, &g_reloadHUDToken,
                             ds_bridge_queue(), ^(int token) {
        (void)token;
        if (!g_hudActive.load()) return;
        NSDictionary *preferences = ds_hud_preferences();
        ds_append_checkpoint([NSString stringWithFormat:
            @"HUD 设置已刷新 position=%@ size=%@ snapshot=%@",
            preferences[UIInterfaceOrientationIsLandscape(ds_interface_orientation())
                ? HUDUserDefaultsKeySelectedModeLandscape
                : HUDUserDefaultsKeySelectedMode] ?: @"default",
            preferences[HUDUserDefaultsKeyUsesLargeFont] ?: @NO,
            preferences[HUDUserDefaultsKeyHideAtSnapshot] ?: @NO]);
        g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
        g_needsFPSBaselineReset = YES;
        ds_update_rate();
    });

    notify_register_dispatch("com.apple.springboard.lockstate", &g_lockStateToken,
                             ds_bridge_queue(), ^(int token) {
        (void)token;
        mach_port_t port = SBSSpringBoardServerPort();
        if (port == MACH_PORT_NULL) return;
        BOOL locked = NO;
        BOOL passcodeSet = NO;
        SBGetScreenLockStatus(port, &locked, &passcodeSet);
        (void)passcodeSet;
        g_deviceLocked.store(locked);
        if (!g_hudActive.load() || !g_springBoard || !g_remoteWindow) return;
        if (locked) {
            ds_remote_set_u64_on_main(g_springBoard, g_remoteWindow, "setHidden:", 1);
            g_lastWindowHidden = YES;
        } else {
            g_previousInput = 0;
            g_previousOutput = 0;
            g_previousSampleTime = 0;
            g_needsFPSBaselineReset = YES;
            g_focusUntil = CFAbsoluteTimeGetCurrent() + kDSHUDFocusDuration;
            g_lastWindowHidden = YES;
            ds_update_rate();
        }
    });
}

BOOL DSBridgeCompiledIn(void) {
    return YES;
}

BOOL DSBridgeIsReady(void) {
    return g_dsReady.load() && ds_is_ready();
}

BOOL DSBridgeAdoptFromEnvironment(void) {
    int control = ds_env_int("DS_CTRL_FD", ds_env_int("DS_HELPER_CTRL_FD", -1));
    int readWrite = ds_env_int("DS_RW_FD", ds_env_int("DS_HELPER_RW_FD", -1));
    uint64_t kernelBase = ds_env_u64("DS_KBASE");
    if (!kernelBase) kernelBase = ds_env_u64("DS_HELPER_KBASE");
    uint64_t kernelSlide = ds_env_u64("DS_KSLIDE");
    if (!kernelSlide) kernelSlide = ds_env_u64("DS_HELPER_KSLIDE");
    if (control < 0 || readWrite < 0 || !kernelBase) return NO;

    const char *lock = getenv("DS_XPROC_LOCK");
    if (!lock || !lock[0]) lock = getenv("DS_HELPER_DOCS");
    if (lock && lock[0]) {
        NSString *path = @(lock);
        if (![path.pathExtension isEqualToString:@"lock"]) {
            path = [path stringByAppendingPathComponent:@".darksword-krw.lock"];
        }
        ds_set_xproc_lock_path(path.fileSystemRepresentation);
    }

    if (!ds_adopt_krw(control, readWrite, kernelBase, kernelSlide)) {
        ds_set_error(@"DS 环境接入失败。");
        return NO;
    }

    init_offsets();
    offsets_init();
    if (!emergencyfixfunctiontobereplacedlateronquestionmark()) {
        ds_set_error(@"DS 系统数据不可用。");
        return NO;
    }
    g_dsReady.store(true);
    ds_set_stage(@"DS 初始化完成");
    ds_set_error(@"");
    os_log(OS_LOG_DEFAULT, "[DSBridge] adopted DarkSword KRW for SpringBoard HUD");
    return YES;
}

BOOL DSBridgeBootstrap(void) {
    if (DSBridgeIsReady()) return YES;
    if (DSBridgeAdoptFromEnvironment()) return YES;

    ds_set_log_callback(ds_bridge_log);
    ds_set_progress_callback(ds_bridge_progress);
    os_log(OS_LOG_DEFAULT, "[DSBridge] running DarkSword chain off-main-thread");

    // offsets_init() must run BEFORE ds_run() — pe_v1() needs the socket/inpcb
    // offsets to find the corrupted socket. Without this, the search runs with
    // all offsets = 0 and retries forever (stuck at ~50%).
    init_offsets();
    offsets_init();

    ds_set_stage(@"正在初始化 DS");
    int result = ds_run();
    if (result != 0 || !ds_is_ready()) {
        ds_set_error([NSString stringWithFormat:@"DS 初始化失败（%d）", result]);
        return NO;
    }

    g_dsReady.store(true);
    ds_set_stage(@"DS 初始化完成");
    ds_set_error(@"");
    os_log(OS_LOG_DEFAULT, "[DSBridge] DarkSword ready");
    return YES;
}

static void ds_finish_disable(void) {
    ds_set_stage(@"正在关闭 HUD");
    ds_unregister_hud_notifications();
    ds_stop_rate_timer();
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (DSInProcessHUDIsEnabled()) DSInProcessHUDSetEnabled(NO);
    });
    RemoteCall *process = g_springBoard;
    g_springBoard = nil;
    g_hudActive.store(false);
    if (process) {
        @try {
            ds_remove_springboard_hud(process);
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] HUD remove exception: %{public}@", exception.reason);
        }
        @try {
            [process destroyRemoteCall];
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "[DSBridge] destroyRemoteCall exception: %{public}@", exception.reason);
        }
    }
    g_remoteContainer = 0;
    g_remoteBlurView = 0;
    g_remoteBlurEffect = 0;
    g_remoteLabel = 0;
    g_remoteSecureField = 0;
    g_remoteSecureCanvas = 0;
    g_remoteWindow = 0;
    g_remoteWindowScene = 0;
    g_remoteWindowPid = 0;
    g_remoteOrientation.store(UIInterfaceOrientationUnknown);
    g_lastPresentationSignature = 0;
    g_lastWindowFrame = CGRectNull;
    g_lastLabelFrame = CGRectNull;
    g_lastWindowHidden = NO;
    g_lastContainerAlpha = -1.0;
    g_lastFontSize = -1.0;
    g_lastInverted = NO;
    g_lastHideAtSnapshot = NO;
    ds_reset_remote_symbol_cache();
    ds_stop_keepalive();
    ds_set_stage(@"HUD 已关闭");
    notify_post(NOTIFY_RELOAD_APP);
    os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard HUD disabled");
}

static void ds_finish_enable(void) {
    if (!g_hudRequested.load()) return;
    g_dsRunning.store(true);
    g_dsProgress.store(0.0);
    ds_set_stage(@"准备启动");
    ds_post_progress();

    if (!ds_start_keepalive()) {
        g_hudRequested.store(false);
        g_dsRunning.store(false);
        ds_post_progress();
        return;
    }
    if (!DSBridgeBootstrap() || !g_hudRequested.load()) {
        g_hudRequested.store(false);
        g_dsRunning.store(false);
        ds_stop_keepalive();
        ds_post_progress();
        return;
    }

    // After ds_run, resolve kernelcache offsets (download when
    // missing), then use procbyname("SpringBoard") for RemoteCall.
    g_dsProgress.store(0.92);
    ds_set_stage(@"准备系统数据");
    ds_post_progress();
    if (!ds_prepare_kernel_offsets()) {
        ds_finish_enable_inprocess(
            @"已启用进程内 HUD（安全模式）\n"
            @"系统数据准备失败，已跳过 SpringBoard 连接。");
        return;
    }

    g_dsProgress.store(0.96);
    ds_set_stage(@"定位 SpringBoard");
    ds_post_progress();
    uint64_t sbProc = proc_find_by_name("SpringBoard");
    if (!sbProc) {
        ds_finish_enable_inprocess(
            @"已启用进程内 HUD（安全模式）\n"
            @"SpringBoard 尚未就绪，已跳过连接。");
        return;
    }

    @try {
        os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard proc=0x%llx self=0x%llx — starting RemoteCall",
               (unsigned long long)sbProc, (unsigned long long)ds_get_our_proc());
        g_dsProgress.store(0.98);
        ds_set_stage(@"连接 SpringBoard");
        ds_reset_remote_symbol_cache();
        g_springBoard = [[RemoteCall alloc] initWithProcess:@"SpringBoard" useMigFilterBypass:NO];
        if (!g_springBoard || !g_springBoard.trojanMem || g_springBoard.pid <= 1) {
            NSString *remoteError = [RemoteCall lastInitError];
            if (remoteError.length == 0 && g_springBoard) remoteError = g_springBoard.lastError;
            if (remoteError.length == 0) remoteError = @"RemoteCall init failed (no detail)";
            ds_append_checkpoint([@"SpringBoard 连接失败：" stringByAppendingString:remoteError]);
            g_springBoard = nil;
            ds_finish_enable_inprocess([NSString stringWithFormat:
                @"已启用进程内 HUD（安全模式）\nSpringBoard 连接失败\n%@", remoteError]);
            return;
        }

        g_dsProgress.store(0.99);
        ds_set_stage(@"创建 SpringBoard HUD");
        g_remoteLabel = ds_create_springboard_hud(g_springBoard);
        if (!g_remoteLabel) {
            [g_springBoard destroyRemoteCall];
            g_springBoard = nil;
            ds_finish_enable_inprocess(@"已启用进程内 HUD（安全模式）\nSpringBoard HUD 创建失败");
            return;
        }
    } @catch (NSException *exception) {
        g_springBoard = nil;
        ds_finish_enable_inprocess([NSString stringWithFormat:
            @"已启用进程内 HUD（安全模式）\nSpringBoard HUD 异常：%@", exception.reason]);
        return;
    }

    g_hudActive.store(true);
    g_dsRunning.store(false);
    g_dsProgress.store(1.0);
    ds_set_stage(@"SpringBoard HUD 已启动");
    ds_set_error(@"");
    ds_start_rate_timer();
    ds_register_hud_notifications();
    notify_post(NOTIFY_LAUNCHED_HUD);
    ds_post_progress();
    os_log(OS_LOG_DEFAULT, "[DSBridge] SpringBoard HUD active (SpringBoard pid=%d)", g_springBoard.pid);
}

BOOL DSBridgeSetHUDEnabled(BOOL enabled) {
    g_hudRequested.store(enabled);
    dispatch_async(ds_bridge_queue(), ^{
        @autoreleasepool {
            if (enabled) {
                if (!g_hudRequested.load() || g_hudActive.load()) return;
                ds_finish_enable();
            } else {
                ds_finish_disable();
            }
        }
    });
    return YES;
}

BOOL DSBridgeHUDEnabled(void) {
    return g_hudActive.load();
}

double DSBridgeProgress(void) {
    return g_dsProgress.load();
}

BOOL DSBridgeIsRunning(void) {
    return g_dsRunning.load();
}

#else

BOOL DSBridgeCompiledIn(void) { return NO; }
BOOL DSBridgeIsReady(void) { return NO; }
BOOL DSBridgeAdoptFromEnvironment(void) {
    ds_set_error(@"当前构建未启用 DS。");
    return NO;
}
BOOL DSBridgeBootstrap(void) {
    ds_set_error(@"当前构建未启用 DS。");
    return NO;
}
BOOL DSBridgeSetHUDEnabled(BOOL enabled) {
    (void)enabled;
    return NO;
}
BOOL DSBridgeHUDEnabled(void) { return NO; }
double DSBridgeProgress(void) { return 0.0; }
BOOL DSBridgeIsRunning(void) { return NO; }

#endif

NSString *DSBridgeLastError(void) {
    os_unfair_lock_lock(&g_errorLock);
    NSString *error = [g_dsLastError copy] ?: @"";
    os_unfair_lock_unlock(&g_errorLock);
    return error;
}

NSString *DSBridgeStage(void) {
    os_unfair_lock_lock(&g_errorLock);
    NSString *stage = [g_dsStage copy] ?: @"";
    os_unfair_lock_unlock(&g_errorLock);
    return stage;
}
