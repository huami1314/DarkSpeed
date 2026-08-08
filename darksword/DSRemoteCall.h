// Objective-C++ compatible public surface for the bundled RemoteCall implementation.
// The full header uses @import and also repeats a C symbol from utils.h;
// DarkSpeed only needs this smaller ABI-compatible interface.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class RemotePointer;

@interface RemoteCall : NSObject
@property(nonatomic, strong) NSString *lastError;
@property(nonatomic) uint64_t trojanMem;
@property(nonatomic) BOOL trojanMemIsStackFallback;
@property(nonatomic) uint64_t trojanMemScratchOffset;
@property(nonatomic) pid_t pid;

+ (NSString *)lastInitError;
- (instancetype)initWithProcess:(NSString *)process useMigFilterBypass:(BOOL)useMigFilterBypass;
- (BOOL)doRemoteCallSyncOnMainThread:(BOOL (^)(void))block;
- (NSUInteger)doRemoteCallStableWithTimeout:(int)timeout functionName:(char *)name functionPointer:(void *)ptr
                            args:(uint64_t *)args argCount:(NSUInteger)argCount;
- (BOOL)remoteRead:(uint64_t)src to:(void *)dst size:(uint64_t)size;
- (BOOL)remote_write:(uint64_t)dst from:(const void *)src size:(uint64_t)size;
- (int)destroyRemoteCall;
- (RemotePointer *)objectAtIndexedSubscript:(uint64_t)address;
@end

#ifdef __cplusplus
extern "C" {
#endif
uint64_t remote_sel(RemoteCall *process, const char *name);
uint64_t remote_getClass(RemoteCall *process, const char *name);
uint64_t remote_msg(RemoteCall *process, uint64_t object, uint64_t selector,
                    uint64_t argument0, uint64_t argument1,
                    uint64_t argument2, uint64_t argument3);
uint64_t remote_NSString(RemoteCall *process, const char *string);
CGRect remote_getCGRect(RemoteCall *process, uint64_t object, uint64_t selector);
void remote_setCGRect(RemoteCall *process, uint64_t object, uint64_t selector, CGRect rect);
#ifdef __cplusplus
}
#endif

#define DSRemoteArbCallWithTimeout(timeout, instance, _pc, ...) [instance doRemoteCallStableWithTimeout:timeout functionName:(char *)#_pc functionPointer:(void *)(_pc) args:(uint64_t[]){__VA_ARGS__} argCount:sizeof((uint64_t[]){__VA_ARGS__})/sizeof(uint64_t)]
#define DSRemoteArbCall(instance, _pc, ...) DSRemoteArbCallWithTimeout(5, instance, _pc, __VA_ARGS__)
