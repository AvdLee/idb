/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>

NS_ASSUME_NONNULL_BEGIN

@class FBDevice;

/**
 A FBVideoRecordingCommands implementation for devices
 */
@interface FBDeviceVideoRecordingCommands : NSObject <FBVideoRecordingCommands, FBVideoStreamCommands>

@end

NS_ASSUME_NONNULL_END
