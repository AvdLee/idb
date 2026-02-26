/**
 * SimScreen protocol from CoreSimulator.
 *
 * In Xcode 26.3+, SimulatorKit moved from the old ioSurfacesChangeCallback
 * pattern to registerScreenCallbacksWithUUID:... for surface lifecycle.
 * The surfacesChangedCallback delivers (unmaskedSurface, maskedSurface).
 */

#import <Foundation/Foundation.h>

@class IOSurface;

@protocol SimScreenProperties;

@protocol SimScreen <NSObject>

@optional

/**
 Xcode 26.3+: Register for frame, surface-change, and property-change callbacks.

 @param uuid       unique registration token
 @param queue      dispatch queue for callbacks
 @param frame      called on every rendered frame
 @param surfaces   called when IOSurface pair changes (unmasked, masked)
 @param properties called when screen properties change
 */
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)queue
                          frameCallback:(void (^)(void))frame
                 surfacesChangedCallback:(void (^)(IOSurface * _Nullable unmasked, IOSurface * _Nullable masked))surfaces
               propertiesChangedCallback:(void (^)(id<SimScreenProperties> _Nullable properties))properties;

- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;

@end
