/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Backlight of a `SimScreen` (Xcode 27.1 runtime: `@protocol SimScreenBacklight`).
 On iPhone Duo the inactive (folded-away) panel reports its backlight off.
 */
@protocol SimScreenBacklight <NSObject>
@property (readonly, nonatomic) int state;
@property (readonly, nonatomic) double brightnessFactor;
@end

/**
 Properties payload of a `SimScreen` (Xcode 27's Swift rewrite of SimulatorKit,
 reverse-engineered). Vended by `-[SimScreen screenProperties]` and delivered by
 `-[SimScreen registerScreenCallbacksWithUUID:...]` via its `propertiesChangedCallback`.

 Every selector below was confirmed against the Xcode 27.1 runtime with
 `protocol_copyPropertyList(objc_getProtocol("SimScreenProperties"))`. Only the members
 the framebuffer needs to identify a screen are declared; callers must still guard with
 `respondsToSelector:` since the protocol is private and may shift across betas.
 */
@protocol SimScreenProperties <NSObject>

/** Monotonic per-screen identifier; matches `enumerate ... screenID` in `simctl io`. */
@property (readonly, nonatomic) unsigned int screenID;

/** Stable unique identifier (UUID string; matches `devicectl device info displays` `uniqueId`). */
@property (readonly, nonatomic, nullable) NSString *uniqueId;

/** Human-readable name (iPhone Duo on Xcode 27.1: "LCD" == outer, "LCD-1" == inner). */
@property (readonly, nonatomic, nullable) NSString *name;

/** Framebuffer size in pixels. */
@property (readonly, nonatomic) CGSize pixelSize;

/** Power state of the screen (see `SimDeviceIOPortDescriptorState.powerState`). */
@property (readonly, nonatomic) int powerState;

/** Screen type discriminator (`SimScreenType`; 0 == main/default display class). */
@property (readonly, nonatomic) unsigned long long screenType;

/** Current UI orientation. */
@property (readonly, nonatomic) unsigned int uiOrientation;

/** Backlight state; distinguishes the active from the inactive panel on multi-display devices. */
@property (readonly, nonatomic, nullable) id<SimScreenBacklight> backlight;

@end

NS_ASSUME_NONNULL_END
