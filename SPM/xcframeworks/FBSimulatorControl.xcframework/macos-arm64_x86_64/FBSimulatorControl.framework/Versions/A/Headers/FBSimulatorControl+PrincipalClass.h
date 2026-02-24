/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FBBundleDescriptor;
@class FBSimulatorConfiguration;
@class FBSimulatorControlConfiguration;
@class FBSimulatorServiceContext;
@class FBSimulatorSet;
@protocol FBControlCoreLogger;

/**
 The Root Class for the FBSimulatorControl Framework.
 */
@interface FBSimulatorControl : NSObject

#pragma mark Initializers

/**
 Creates and returns a new `FBSimulatorControl` instance.

 @param configuration the Configuration to setup the instance with.
 @param error any error that occurred during instantiation.
 @return a new FBSimulatorControl instance.
 */
+ (nullable instancetype)withConfiguration:(FBSimulatorControlConfiguration *)configuration error:(NSError **)error;

/**
 Creates and returns a new `FBSimulatorControl` instance using an explicit developer directory.
 Use this from sandboxed apps that cannot resolve the Xcode path via xcode-select.
 When developerDirectory is nil, falls back to xcode-select resolution.

 @param configuration the Configuration to setup the instance with.
 @param developerDirectory the Xcode Contents/Developer path, or nil.
 @param error any error that occurred during instantiation.
 @return a new FBSimulatorControl instance.
 */
+ (nullable instancetype)withConfiguration:(FBSimulatorControlConfiguration *)configuration
                        developerDirectory:(nullable NSString *)developerDirectory
                                     error:(NSError **)error;

#pragma mark Properties

/**
 The Set of Simulators managed by FBSimulatorControl.
 */
@property (nonatomic, strong, readonly) FBSimulatorSet *set;

/**
 The Service Context.
 */
@property (nonatomic, strong, readonly) FBSimulatorServiceContext *serviceContext;

/**
 The Configuration that FBSimulatorControl was instantiated with.
 */
@property (nonatomic, copy, readwrite) FBSimulatorControlConfiguration *configuration;

@end

NS_ASSUME_NONNULL_END
