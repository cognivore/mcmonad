#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs an Obj-C block inside `@try`/`@catch`.
///
/// Some AppKit/AVFoundation entry points signal failure by *raising* an
/// `NSException` rather than returning an error — `-[AVAudioNode
/// installTapOnBus:bufferSize:format:block:]` is one. Swift cannot catch
/// those, and letting one unwind through Swift frames is not merely a leak:
/// it tears down the Swift concurrency runtime's per-thread executor
/// bookkeeping without restoring it, after which the *next* `@objc` entry
/// point dies with a bus error inside `swift_task_isCurrentExecutor`,
/// seconds later and nowhere near the real fault.
///
/// So calls that can raise are funnelled through here and come back to Swift
/// as an ordinary thrown error.
@interface MCObjCGuard : NSObject

/// Invokes `block`. Returns YES if it completed, NO if it raised — in which
/// case `error` (when non-NULL) carries the exception's name and reason.
+ (BOOL)perform:(NS_NOESCAPE dispatch_block_t)block
          error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(perform(_:));

@end

NS_ASSUME_NONNULL_END
