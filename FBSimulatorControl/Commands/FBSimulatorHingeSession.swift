/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

protocol FBSimulatorHingeWriteTransport: Sendable {
  func setAngle(_ angle: FBSimulatorHingeAngle) async throws
  func finish() async throws
  func disconnect()
}

extension FBSimulatorDTUHIDTransport: FBSimulatorHingeWriteTransport {
  func setAngle(_ angle: FBSimulatorHingeAngle) async throws {
    try await send(
      messageType: "IndigoVendorDefinedEvent",
      payload: angle.vendorEvent())
  }

  func finish() async throws {
    try await flush()
  }
}

enum FBSimulatorHingeSessionError: Error, LocalizedError {
  case finished

  var errorDescription: String? {
    switch self {
    case .finished:
      return "The simulator hinge session has already finished"
    }
  }
}

/// A persistent, activated vendor-HID connection for streaming simulator hinge angles.
///
/// Create one session for an animation, send every sample through `setAngle(_:)`, then call
/// `finish()` once. `finish()` drains all outstanding samples and disconnects. Abandoning or
/// cancelling a session also disconnects its transport.
public actor FBSimulatorHingeSession {
  private let transport: any FBSimulatorHingeWriteTransport
  private var isFinished = false

  init(transport: any FBSimulatorHingeWriteTransport) {
    self.transport = transport
  }

  deinit {
    transport.disconnect()
  }

  /// Enqueues one validated angle without warming or draining the persistent connection.
  public func setAngle(_ angle: FBSimulatorHingeAngle) async throws {
    guard !isFinished else {
      throw FBSimulatorHingeSessionError.finished
    }
    do {
      try Task.checkCancellation()
      try await withTaskCancellationHandler {
        try await transport.setAngle(angle)
      } onCancel: {
        transport.disconnect()
      }
    } catch {
      isFinished = true
      transport.disconnect()
      throw error
    }
  }

  /// Drains all samples sent through this session and disconnects. Repeated calls are no-ops.
  public func finish() async throws {
    guard !isFinished else {
      return
    }
    isFinished = true
    defer {
      transport.disconnect()
    }
    try Task.checkCancellation()
    try await transport.finish()
  }
}
