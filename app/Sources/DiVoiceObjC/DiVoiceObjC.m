#import "DiVoiceObjC.h"

NSException *DVCatchException(NS_NOESCAPE void (^block)(void)) {
  @try {
    block();
  } @catch (NSException *exception) {
    return exception;
  }
  return nil;
}
