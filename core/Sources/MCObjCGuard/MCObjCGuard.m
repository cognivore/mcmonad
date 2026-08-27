#import "MCObjCGuard.h"

NSString *const MCObjCGuardErrorDomain = @"MCObjCGuardErrorDomain";

@implementation MCObjCGuard

+ (BOOL)perform:(NS_NOESCAPE dispatch_block_t)block
          error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] =
                exception.reason ?: @"Obj-C exception with no reason";
            info[@"MCObjCGuardExceptionName"] = exception.name ?: @"(unnamed)";
            *error = [NSError errorWithDomain:MCObjCGuardErrorDomain
                                         code:1
                                     userInfo:info];
        }
        return NO;
    }
}

@end
