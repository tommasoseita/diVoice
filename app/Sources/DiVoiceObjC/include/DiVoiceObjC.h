#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and returns the Objective-C exception it raised, if any. AVAudioEngine raises
/// one, instead of returning an error, when a microphone changes format while it's being set up
/// (a headset connecting): caught here, it's an error to report instead of a crash.
NSException *_Nullable DVCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
