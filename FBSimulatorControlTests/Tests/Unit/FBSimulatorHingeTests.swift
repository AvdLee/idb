/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBSimulatorControl
import Foundation
import IOKit
import XCTest
@preconcurrency import XPC

private func hingeEvent(
  channel: UUID,
  degrees: Double = 130,
  timestamp: Double = 200,
  valid: Bool = true
) -> xpc_object_t {
  let dictionary = FBSimulatorCoreDevice.dictionary
  return dictionary([
    "XPCSideChannel.uniqueIdentifier": xpc_string_create(channel.uuidString),
    "CoreDevice.XPCMessageKey.sideChannelStatus": dictionary([
      "pushing": dictionary([
        "elements": FBSimulatorCoreDevice.array([
          dictionary([
            "angle": dictionary([
              "value": xpc_double_create(degrees),
              "unit": dictionary([
                "symbol": xpc_string_create("°"),
                "converter": dictionary([
                  "coefficient": xpc_double_create(1),
                  "constant": xpc_double_create(0),
                ]),
              ]),
            ]),
            "timestamp": xpc_double_create(timestamp),
            "isAngleValid": xpc_bool_create(valid),
          ])
        ])
      ])
    ]),
  ])
}

private final class FBSimulatorHingeTransportStub:
  FBSimulatorCoreDeviceTransport, @unchecked Sendable
{
  let script: @Sendable (FBSimulatorHingeTransportStub) -> Void
  var event: (@Sendable (xpc_object_t) -> Void)?
  var reply: (@Sendable (xpc_object_t) -> Void)?
  var acknowledgements: [Bool] = []
  var cancellations = 0
  var completesCancellation = true

  init(script: @escaping @Sendable (FBSimulatorHingeTransportStub) -> Void) {
    self.script = script
  }

  func start(
    request: xpc_object_t,
    event: @escaping @Sendable (xpc_object_t) -> Void,
    reply: @escaping @Sendable (xpc_object_t) -> Void
  ) {
    self.event = event
    self.reply = reply
    script(self)
  }

  func acknowledge(_ event: xpc_object_t, cancelling: Bool) {
    acknowledgements.append(cancelling)
    if cancelling && completesCancellation {
      complete()
    }
  }

  func complete() {
    reply?(FBSimulatorCoreDevice.dictionary([
      "CoreDevice.output": xpc_dictionary_create(nil, nil, 0)
    ]))
  }

  func cancel() {
    cancellations += 1
  }
}

final class FBSimulatorHingeTests: XCTestCase {
  func testAngleValidationAndModelGate() throws {
    for degrees in [-1, 181, Double.nan, .infinity, -.infinity] {
      XCTAssertThrowsError(try FBSimulatorHingeAngle(degrees: degrees))
    }
    try FBSimulatorHingeAngle.requireSupportedModel("iPhone19,4")
    for model in [nil, "iPhone18,1", "iPad16,3"] {
      XCTAssertThrowsError(try FBSimulatorHingeAngle.requireSupportedModel(model))
    }
  }

  func testVendorPayloadAndTransportEnvelope() throws {
    let degrees = 135.5
    let event = try FBSimulatorHingeAngle(degrees: degrees).vendorEvent()
    let message = try XPCEncoder().encode(
      DTUHIDMessage(
        messageType: "IndigoVendorDefinedEvent",
        featureIdentifier: FBSimulatorDTUHIDTransport.vendorDefinedServiceName,
        payload: event))
    XCTAssertEqual(
      String(cString: xpc_dictionary_get_string(message, "featureIdentifier")!),
      "com.apple.coredevice.feature.remote.hid.vendordefined")
    let payload = try XCTUnwrap(xpc_dictionary_get_dictionary(message, "payload"))
    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "usagePage"), 0xff61)
    XCTAssertEqual(xpc_dictionary_get_uint64(payload, "usage"), 0x5b)
    let data = try XCTUnwrap(xpc_dictionary_get_value(payload, "data"))
    XCTAssertEqual(xpc_get_type(data), XPC_TYPE_DATA)
    let bytes = try XCTUnwrap(xpc_data_get_bytes_ptr(data))
    let decoded = try XCTUnwrap(
      IOCFUnserializeWithSize(
        bytes.assumingMemoryBound(to: CChar.self),
        xpc_data_get_length(data),
        nil,
        0,
        nil) as? [String: Any])
    XCTAssertEqual(decoded["provider"] as? String, "com.apple.Virtualization.VirtualMachines")
    XCTAssertEqual(decoded["source"] as? String, "hinge-slider-control")
    XCTAssertEqual(decoded["type"] as? String, "range")
    XCTAssertEqual(decoded["value"] as? Double, degrees)
  }

  func testReadProtocolSelectsFreshSample() throws {
    let channel = UUID()
    XCTAssertNil(
      try FBSimulatorHingeProtocol.sample(
        hingeEvent(channel: channel, timestamp: 198),
        channel: channel,
        notBefore: 199,
        now: 201))
    let angle = try FBSimulatorHingeProtocol.sample(
      hingeEvent(channel: channel, degrees: 121.64),
      channel: channel,
      notBefore: 199,
      now: 201)
    XCTAssertEqual(angle?.degrees, 121.64)
  }

  func testReadTimesOutAndCancelsTransport() async {
    let queue = DispatchQueue(label: "hinge-read-timeout-test")
    let transport = FBSimulatorHingeTransportStub { _ in }
    let session = FBSimulatorHingeReadSession(
      transport: transport,
      queue: queue,
      timeout: .milliseconds(10))
    do {
      _ = try await session.read(deviceID: "device", version: "651.13.4")
      XCTFail("Expected timeout")
    } catch {
      guard case FBSimulatorHingeReadError.timedOut = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    queue.sync {
      XCTAssertEqual(transport.cancellations, 1)
    }
  }

  func testTaskCancellationClosesTransport() async {
    let started = expectation(description: "request started")
    let queue = DispatchQueue(label: "hinge-read-cancellation-test")
    let transport = FBSimulatorHingeTransportStub { _ in
      started.fulfill()
    }
    let session = FBSimulatorHingeReadSession(transport: transport, queue: queue)
    let task = Task {
      try await session.read(deviceID: "device", version: "651.13.4")
    }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    queue.sync {
      XCTAssertEqual(transport.cancellations, 1)
    }
  }
}
