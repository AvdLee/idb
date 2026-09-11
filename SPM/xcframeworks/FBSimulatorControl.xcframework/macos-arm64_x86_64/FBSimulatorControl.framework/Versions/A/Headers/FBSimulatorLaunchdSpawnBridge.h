#import <Foundation/Foundation.h>

@class SimDevice;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT pid_t FBSpawnFromSimulatorLaunchd(
  SimDevice *device,
  NSString *launchPath,
  NSDictionary<NSString *, id> *options,
  dispatch_queue_t terminationQueue,
  void (^terminationHandler)(int32_t),
  NSError **error
);

NS_ASSUME_NONNULL_END
