/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation

extension FBSimulator {
  public func accessibilityElementsViaBridge(
    options: FBAccessibilityRequestOptions
  ) async throws -> FBAccessibilityElementsResponse {
    let data = try await runAccessibilityBridge(
      action: "describe",
      arguments: [
        "--x", "0",
        "--y", "0",
        "--method", "window-server",
        "--automation-mode", "true",
        "--max-depth", String(options.maxDepth),
      ]
    )
    let envelope = try Self.axBridgeEnvelope(from: data)
    guard envelope["ok"] as? Bool == true else {
      throw Self.axBridgeError(from: envelope)
    }
    guard
      let tree = envelope["tree"] as? [String: Any],
      let pid = (envelope["pid"] as? NSNumber)?.int32Value
    else {
      throw FBSimulatorError.describe("Accessibility bridge returned no tree").build()
    }

    let root = AXBridgePlatformElement.tree(from: tree, pid: pid)
    return try FBAXTranslationRequest(kind: .frontmostApplication).run(root, options: options)
  }

  public func performAccessibilityBridgeTap(
    x: Double,
    y: Double,
    expectedLabel: String?
  ) async throws {
    var arguments = [
      "--x", String(x),
      "--y", String(y),
      "--action", "press",
    ]
    if let expectedLabel {
      arguments.append(contentsOf: [
        "--assert-key", AXWire.Node.label.rawValue,
        "--assert-value", expectedLabel,
      ])
    }

    let envelope = try Self.axBridgeEnvelope(
      from: try await runAccessibilityBridge(action: "perform", arguments: arguments)
    )
    guard envelope["ok"] as? Bool == true else {
      throw Self.axBridgeError(from: envelope)
    }
  }

  private static func axBridgeEnvelope(from data: Data) throws -> [String: Any] {
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FBSimulatorError.describe("Accessibility bridge returned malformed JSON").build()
    }
    return envelope
  }

  private static func axBridgeError(from envelope: [String: Any]) -> Error {
    let message = envelope["error"] as? String ?? "Accessibility bridge request failed"
    return FBSimulatorError.describe(message).build()
  }
}
