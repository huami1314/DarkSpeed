#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Floating speed overlay inside the TrollSpeed app process.
/// Used when persona spawn is unavailable (developer-signed / no TrollStore).
OBJC_EXTERN void DSInProcessHUDSetEnabled(BOOL enabled);
OBJC_EXTERN BOOL DSInProcessHUDIsEnabled(void);

NS_ASSUME_NONNULL_END
