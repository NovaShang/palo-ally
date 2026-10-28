#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil.
/// Swift cannot catch one: some system calls (AVAudioEngine's installTap
/// on a changed input device) report failure only by raising, which would
/// otherwise end the app.
NSException *_Nullable PAOCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
