/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

@class FBSimulatorControlConfiguration;
@class SimDeviceSet;
@class SimDeviceType;
@class SimRuntime;
@class SimServiceContext;

@protocol FBControlCoreLogger;

NS_ASSUME_NONNULL_BEGIN

/**
 An FBSimulatorControl wrapper for SimServiceContext.
 */
@interface FBSimulatorServiceContext : NSObject

#pragma mark Initializers

/**
 Returns the shared Service Context instance.

 @param logger the logger to use.
 @return the shared context.
 */
+ (instancetype)sharedServiceContextWithLogger:(nullable id<FBControlCoreLogger>)logger;

/**
 Returns a Service Context for a specific developer directory.
 When developerDirectory is nil, falls back to the shared cached context.
 When non-nil, creates a context using the provided path (for sandboxed apps
 that cannot read xcode-select).

 @param logger the logger to use.
 @param developerDirectory the Xcode Contents/Developer path, or nil.
 @return the context.
 */
+ (instancetype)serviceContextWithLogger:(nullable id<FBControlCoreLogger>)logger
                      developerDirectory:(nullable NSString *)developerDirectory;

/**
 Returns the shared Service Context instance.

 @return the shared context.
 */
+ (instancetype)sharedServiceContext;

#pragma mark Public Methods

/**
 Return the paths to all of the device sets.
 */
- (NSArray<NSString *> *)pathsOfAllDeviceSets;

/**
 Returns all of the supported runtimes.
 */
- (NSArray<SimRuntime *> *)supportedRuntimes;

/**
 Returns all of the supported device types.
 */
- (NSArray<SimDeviceType *> *)supportedDeviceTypes;

/**
 Obtains the SimDeviceSet for a given configuration.

 @param configuration the configuration to use.
 @param error an error out for any error that occurs.
 @return the Device Set if present. nil otherwise.
 */
- (nullable SimDeviceSet *)createDeviceSetWithConfiguration:(FBSimulatorControlConfiguration *)configuration error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
