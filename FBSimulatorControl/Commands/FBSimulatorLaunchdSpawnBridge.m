#import "FBSimulatorLaunchdSpawnBridge.h"

@import CoreSimulator;

@interface SimDevice (FBSimulatorLaunchdSpawnBridge)

- (int)_spawnFromLaunchdWithPath:(NSString *)launchPath
                         options:(NSDictionary<NSString *, id> *)options
                terminationQueue:(dispatch_queue_t)terminationQueue
              terminationHandler:(void (^)(int32_t))terminationHandler
                           error:(NSError **)error;

@end

pid_t FBSpawnFromSimulatorLaunchd(
  SimDevice *device,
  NSString *launchPath,
  NSDictionary<NSString *, id> *options,
  dispatch_queue_t terminationQueue,
  void (^terminationHandler)(int32_t),
  NSError **error
) {
  return [device _spawnFromLaunchdWithPath:launchPath
                                  options:options
                         terminationQueue:terminationQueue
              terminationHandler:(CDUnknownBlockType)terminationHandler
                                    error:error];
}
