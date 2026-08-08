//
//  HUDHelper.mm
//  TrollSpeed
//
//  Created by Lessica on 2024/1/24.
//

#import <spawn.h>
#import <notify.h>
#import <mach-o/dyld.h>

#import "HUDHelper.h"
#import "NSUserDefaults+Private.h"
#import "DSBridge.h"

extern "C" char **environ;

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

BOOL IsHUDEnabled(void)
{
    // DarkSword / developer-signed: the HUD is a tagged view in SpringBoard.
    if (DSBridgeCompiledIn()) {
        return DSBridgeHUDEnabled();
    }

    static char *executablePath = NULL;
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

#if !TARGET_OS_SIMULATOR
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
#endif

    int rc;
    pid_t task_pid;
    const char *args[] = { executablePath, "-check", NULL };
    rc = posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
    if (rc != 0) {
        log_debug(OS_LOG_DEFAULT, "posix_spawn error %s", strerror(rc));
    }

    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        return NO;
    }

    log_debug(OS_LOG_DEFAULT, "spawned %{public}s -check pid = %{public}d", executablePath, task_pid);
    
    int status;
    do {
        if (waitpid(task_pid, &status, 0) != -1)
        {
            log_debug(OS_LOG_DEFAULT, "child status %d", WEXITSTATUS(status));
        }
    } while (!WIFEXITED(status) && !WIFSIGNALED(status));

    return WEXITSTATUS(status) != 0;
}

void SetHUDEnabled(BOOL isEnabled)
{
    notify_post(NOTIFY_DISMISSAL_HUD);

    // DarkSword-aware path (no-op unless built with USE_DARKSWORD=1).
    // On success the bridge owns the spawn; otherwise fall through to the
    // stock TrollStore persona_np flow.
    if (DSBridgeSetHUDEnabled(isEnabled)) {
        log_debug(OS_LOG_DEFAULT, "DSBridge handled SetHUDEnabled(%{public}d)", isEnabled);
        return;
    }
    if (DSBridgeCompiledIn() && DSBridgeLastError().length > 0) {
        log_debug(OS_LOG_DEFAULT, "DSBridge fallback: %{public}@", DSBridgeLastError());
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

#if !TARGET_OS_SIMULATOR
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
#endif

    static char *executablePath = NULL;
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    if (isEnabled)
    {
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

        int rc;
        pid_t task_pid;
        const char *args[] = { executablePath, "-hud", NULL };
        rc = posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
        if (rc != 0) {
            log_debug(OS_LOG_DEFAULT, "posix_spawn error %s", strerror(rc));
        }

        posix_spawnattr_destroy(&attr);

        if (rc != 0) {
            return;
        }

        log_debug(OS_LOG_DEFAULT, "spawned %{public}s -hud pid = %{public}d", executablePath, task_pid);

        int unused;
        waitpid(task_pid, &unused, WNOHANG);
    }
    else
    {
        [NSThread sleepForTimeInterval:FADE_OUT_DURATION];

        int rc;
        pid_t task_pid;
        const char *args[] = { executablePath, "-exit", NULL };
        rc = posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
        if (rc != 0) {
            log_debug(OS_LOG_DEFAULT, "posix_spawn error %s", strerror(rc));
        }

        posix_spawnattr_destroy(&attr);

        if (rc != 0) {
            return;
        }

        log_debug(OS_LOG_DEFAULT, "spawned %{public}s -exit pid = %{public}d", executablePath, task_pid);

        int status;
        do {
            if (waitpid(task_pid, &status, 0) != -1)
            {
                log_debug(OS_LOG_DEFAULT, "child status %d", WEXITSTATUS(status));
            }
        } while (!WIFEXITED(status) && !WIFSIGNALED(status));
    }
}

NSUserDefaults *GetStandardUserDefaults(void)
{
    static NSUserDefaults *_userDefaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *containerPath = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject] stringByDeletingLastPathComponent];
        NSURL *containerURL = [NSURL fileURLWithPath:containerPath];
        _userDefaults = [[NSUserDefaults alloc] _initWithSuiteName:nil container:containerURL];
        [_userDefaults registerDefaults:@{
            HUDUserDefaultsKeyUsesCustomOffset: @NO,
            HUDUserDefaultsKeyRealCustomOffsetX: @0,
            HUDUserDefaultsKeyRealCustomOffsetY: @0,
            HUDUserDefaultsKeyUsesCustomFontSize: @NO,
            HUDUserDefaultsKeyRealCustomFontSize: @9,
        }];
    });
    return _userDefaults;
}
