/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation

public extension FBSimulator {
  /// Sets the hinge angle on an iPhone Duo simulator.
  func setHingeAngle(_ angle: FBSimulatorHingeAngle) async throws {
    try FBSimulatorHingeAngle.requireSupportedModel(device.deviceType.modelIdentifier)
    let transport = try await FBSimulatorDTUHIDTransport.reliableDTUHID(
      for: self,
      serviceName: FBSimulatorDTUHIDTransport.vendorDefinedServiceName)
    defer {
      transport.disconnect()
    }
    try await transport.send(
      messageType: "IndigoVendorDefinedEvent",
      payload: angle.vendorEvent())
    try await transport.flush()
  }

  /// Reads a fresh measured hinge angle through CoreDevice's motion stream.
  func hingeAngle() async throws -> FBSimulatorHingeAngle {
    try FBSimulatorHingeAngle.requireSupportedModel(device.deviceType.modelIdentifier)
    let version = try FBSimulatorCoreDevice.installedVersion()
    let queue = DispatchQueue(label: "com.facebook.FBSimulatorControl.hinge-read")
    let transport = try FBSimulatorCoreDeviceXPCTransport(
      simulator: self,
      service: FBSimulatorHingeProtocol.service,
      queue: queue)
    let session = FBSimulatorHingeReadSession(transport: transport, queue: queue)
    return try await session.read(deviceID: udid, version: version)
  }
}
