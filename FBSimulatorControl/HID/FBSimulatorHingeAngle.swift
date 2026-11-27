/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import IOKit

/// A simulator hinge angle in degrees: 0 is closed and 180 is flat.
public struct FBSimulatorHingeAngle: Equatable, Hashable, Sendable {
  public let degrees: Double

  public init(degrees: Double) throws {
    guard degrees.isFinite, (0...180).contains(degrees) else {
      throw FBSimulatorHingeError.invalidAngle
    }
    self.degrees = degrees
  }

  static func requireSupportedModel(_ model: String?) throws {
    guard model == "iPhone19,4" else {
      throw FBSimulatorHingeError.unsupportedModel
    }
  }

  func vendorEvent() throws -> FBSimulatorIndigoVendorDefinedEvent {
    try .virtualMachineControl(source: "hinge-slider-control", type: "range", value: degrees)
  }
}

extension FBSimulatorHIDDeviceOrientation {
  /// The event Device Hub's orientation picker sends. The runtime applies it as a physical device
  /// orientation, in the convention `devicectl device orientation get` reports (landscape left is
  /// the device turned left), which is how an iPhone Duo is rotated: its CoreDevice
  /// orientation requests are accepted and then ignored.
  func vendorEvent() throws -> FBSimulatorIndigoVendorDefinedEvent {
    let value: String
    switch self {
    case .portrait: value = "portrait"
    case .portraitUpsideDown: value = "pud"
    case .landscapeLeft: value = "landscape-left"
    case .landscapeRight: value = "landscape-right"
    }
    return try .virtualMachineControl(source: "orientation-picker-control", type: "enum", value: value)
  }
}

enum FBSimulatorHingeError: Error, LocalizedError {
  case invalidAngle
  case unsupportedModel
  case serializationFailed

  var errorDescription: String? {
    switch self {
    case .invalidAngle:
      return "Hinge angle must be finite and between 0 and 180 degrees"
    case .unsupportedModel:
      return "Hinge input is supported only on iPhone Duo simulators"
    case .serializationFailed:
      return "Could not serialize the simulator hinge input"
    }
  }
}

struct FBSimulatorIndigoVendorDefinedEvent: Encodable {
  let usagePage: UInt16
  let usage: UInt16
  let version: UInt32
  let data: Data
}

extension FBSimulatorIndigoVendorDefinedEvent {
  /// A device-state control message, the vendor-defined HID event Device Hub's hinge slider and
  /// orientation picker send to the simulated device.
  static func virtualMachineControl(source: String, type: String, value: Any) throws -> Self {
    let payload: [String: Any] = [
      "provider": "com.apple.Virtualization.VirtualMachines",
      "source": source,
      "type": type,
      "value": value,
    ]
    guard let serialized = IOCFSerialize(payload as CFDictionary, 1) else {
      throw FBSimulatorHingeError.serializationFailed
    }
    return Self(usagePage: 0xff61, usage: 0x5b, version: 0, data: serialized as Data)
  }
}
