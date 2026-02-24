/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import <FBControlCore/FBControlCore.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Used for internal and external implementation.
 */
@protocol FBSimulatorAccessibilityOperations <NSObject>

/**
 Performs an "Accessibility Tap" on the element at the specified point

 @param point the point to tap
 @param expectedLabel if provided, the ax label will be confirmed prior to tapping. In the case of a label mismatch the tap will not proceed
 @return the accessibility element at the point, prior to the tap
 */
- (FBFuture<NSDictionary<NSString *, id> *> *)accessibilityPerformTapOnElementAtPoint:(CGPoint)point expectedLabel:(nullable NSString *)expectedLabel;

@end


/**
 An Implementation of FBSimulatorAccessibilityCommands.
 */
@interface FBSimulatorAccessibilityCommands : NSObject <FBAccessibilityCommands, FBSimulatorAccessibilityOperations>

/**
 Fetches accessibility elements by querying Simulator.app's macOS accessibility tree
 via the AXUIElement C API. This is the same API path that Accessibility Inspector uses,
 which returns the full element hierarchy including navigation bar children that are
 invisible to the CoreSimulator XPC path.

 Requires that Simulator.app is running with a visible window for the given simulator.

 @param simulatorPID the pid of the Simulator.app process hosting the target device window.
 @param deviceName the name of the device window to find (e.g. "iPhone 16 Pro"). Pass nil to use the first window.
 @param nestedFormat if YES, returns elements in a nested tree; if NO, returns a flat list.
 @return a future wrapping an array of accessibility element dictionaries in the same format as accessibilityElementsWithOptions:.
 */
- (FBFuture<NSArray<NSDictionary<NSString *, id> *> *> *)accessibilityElementsViaAXUIElementForSimulatorPID:(pid_t)simulatorPID deviceName:(nullable NSString *)deviceName nestedFormat:(BOOL)nestedFormat;

@end

NS_ASSUME_NONNULL_END
