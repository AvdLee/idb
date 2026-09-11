/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import XCTest

final class SimulatorConfigurationErrorTests: XCTestCase {

  func testMessagesAreStable() {
    XCTAssertEqual(
      SimulatorConfigurationError.noNewestAvailableOS(device: "iPhone 6").errorDescription,
      "No newest available OS for device iPhone 6"
    )
    XCTAssertEqual(
      SimulatorConfigurationError.unsupportedDevice(name: "FooPad").errorDescription,
      "Could not obtain Device for FooPad, perhaps it is unsupported by FBSimulatorControl"
    )
    XCTAssertEqual(
      SimulatorConfigurationError.noDefaultDeviceTypeRegistered(model: "iPhone 6").errorDescription,
      "No device type is registered for 'iPhone 6'"
    )
    XCTAssertEqual(
      SimulatorConfigurationError.noAvailableOSVersionsForDefault.errorDescription,
      "No available OS versions for the default simulator configuration"
    )
    XCTAssertEqual(
      SimulatorConfigurationError.missingRuntimeMetadata(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0").errorDescription,
      "Could not recover runtime metadata for identifier com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    )
    XCTAssertEqual(
      SimulatorConfigurationError.missingDeviceTypeMetadata(identifier: nil).errorDescription,
      "Could not recover device type metadata for identifier unknown"
    )
  }

  func testRuntimeUnavailableComposesReason() {
    XCTAssertEqual(
      SimulatorConfigurationError.runtimeUnavailable(configuration: "Device 'X' | OS 'Y'", reason: "no matches").errorDescription,
      "Could not obtain available SimRuntime for configuration Device 'X' | OS 'Y': no matches"
    )
    XCTAssertEqual(
      SimulatorConfigurationError.runtimeUnavailable(configuration: "Device 'X' | OS 'Y'", reason: nil).errorDescription,
      "Could not obtain available SimRuntime for configuration Device 'X' | OS 'Y'"
    )
  }
}
