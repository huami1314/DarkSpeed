//
//  DSBridge.h
//  DarkSpeed
//
//  Bridge between DarkSpeed's HUD controller and its bundled runtime.
//

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when this build was compiled with USE_DARKSWORD=1.
OBJC_EXTERN BOOL DSBridgeCompiledIn(void);

/// YES after a successful bootstrap (or KRW adopt from the parent).
OBJC_EXTERN BOOL DSBridgeIsReady(void);

/// Trigger outbound network access and prefetch this build's kernelcache into
/// Documents/kernelcache. Safe to call repeatedly; work is coalesced.
OBJC_EXTERN void DSBridgeWarmUpNetworkAndPrefetchKernelCache(void);

/// Run DS initialization after loading device offsets.
/// No-ops / returns NO when USE_DARKSWORD is not defined or symbols are missing.
OBJC_EXTERN BOOL DSBridgeBootstrap(void);

/// Adopt KRW sockets handed over through DS_HELPER_* / DS_* environment values.
OBJC_EXTERN BOOL DSBridgeAdoptFromEnvironment(void);

/// Create or remove the HUD directly inside SpringBoard using RemoteCall.
/// Returns YES if the bridge handled the request (caller should return).
/// Returns NO to fall through to the stock TrollStore persona spawn.
OBJC_EXTERN BOOL DSBridgeSetHUDEnabled(BOOL enabled);

/// YES only after the remote view is attached inside SpringBoard.
OBJC_EXTERN BOOL DSBridgeHUDEnabled(void);

/// Last human-readable error from the bridge (may be empty).
OBJC_EXTERN NSString *DSBridgeLastError(void);

/// Current neutral, user-visible initialization stage.
OBJC_EXTERN NSString *DSBridgeStage(void);

/// DarkSword progress (0.0–0.99 while ds_run is active).
OBJC_EXTERN double DSBridgeProgress(void);

/// YES while the serialized bootstrap / SpringBoard attach is running.
OBJC_EXTERN BOOL DSBridgeIsRunning(void);

/// Posted on any DS progress / state change (observe on main queue).
OBJC_EXTERN NSString * const DSBridgeProgressNotification;

NS_ASSUME_NONNULL_END
