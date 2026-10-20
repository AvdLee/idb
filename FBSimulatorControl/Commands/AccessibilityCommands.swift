/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

/// `displayID` is the CoreSimulator screen ID the request resolves against; `0` is the device's main
/// display. Multi-display devices such as iPhone Duo need the ID of the panel showing the interface.
public protocol AccessibilityOperations: AnyObject {

  func accessibilityElement(at point: CGPoint, displayID: UInt32) async throws -> FBAccessibilityElement

  func accessibilityElementForFrontmostApplication(displayID: UInt32) async throws -> FBAccessibilityElement

  func accessibilityElementMatching(
    value: String,
    forKey key: FBAXSearchableKey,
    depth: UInt,
    displayID: UInt32
  ) async throws -> FBAccessibilityElement
}

public protocol AccessibilityCommands: AccessibilityOperations {}
