/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreGraphics
@_implementationOnly import CoreSimulator
import Darwin
@preconcurrency import FBControlCore
import Foundation
import Synchronization
import XPC

/// The reply-driven waits used by reliable DTUHID delivery.
enum FBSimulatorDTUHIDTiming {
  static let drain = Duration.milliseconds(80)
  static let replyTail = Duration.milliseconds(200)
  static let replyTimeout = DispatchTimeInterval.seconds(2)
  static let fallbackDrain = Duration.seconds(1)
  static let livenessTimeout = DispatchTimeInterval.seconds(4)
  static let livenessRetryBackoff = Duration.seconds(4)
  static let livenessAttempts = 5
}

private struct FBSimulatorDTUHIDXPCReply: Sendable {
  let errorDescription: String?
}

private func awaitFBSimulatorDTUHIDXPCReply(
  _ connection: xpc_connection_t,
  _ message: xpc_object_t,
  timeout: DispatchTimeInterval
) async throws -> FBSimulatorDTUHIDXPCReply {
  try await withCheckedThrowingContinuation {
    (continuation: CheckedContinuation<FBSimulatorDTUHIDXPCReply, Error>) in
    let pending = Mutex(true)
    xpc_connection_send_message_with_reply(
      connection,
      message,
      DispatchQueue.global(qos: .userInitiated)
    ) { reply in
      var errorDescription: String?
      if xpc_get_type(reply) == XPC_TYPE_ERROR {
        errorDescription =
          xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
          .map { String(cString: $0) } ?? "unknown XPC error"
      }
      let shouldResume = pending.withLock { pending in
        defer { pending = false }
        return pending
      }
      if shouldResume {
        continuation.resume(
          returning: FBSimulatorDTUHIDXPCReply(errorDescription: errorDescription))
      }
    }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
      let shouldResume = pending.withLock { pending in
        defer { pending = false }
        return pending
      }
      if shouldResume {
        continuation.resume(throwing: FBSimulatorDTUHIDDrainTimeout.expired)
      }
    }
  }
}

struct FBSimulatorDTUHIDDrainClock: Sendable {
  let sleep: @Sendable (Duration) async throws -> Void
  let awaitBarrierReply:
    @Sendable (xpc_connection_t, xpc_object_t) async throws -> Void
  let awaitLivenessReply:
    @Sendable (xpc_connection_t, xpc_object_t) async throws -> Void

  init(
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    awaitBarrierReply:
      @escaping @Sendable (xpc_connection_t, xpc_object_t) async throws -> Void,
    awaitLivenessReply:
      @escaping @Sendable (xpc_connection_t, xpc_object_t) async throws -> Void = { _, _ in }
  ) {
    self.sleep = sleep
    self.awaitBarrierReply = awaitBarrierReply
    self.awaitLivenessReply = awaitLivenessReply
  }

  static let live = FBSimulatorDTUHIDDrainClock(
    sleep: { try await Task.sleep(for: $0) },
    awaitBarrierReply: { connection, message in
      _ = try await awaitFBSimulatorDTUHIDXPCReply(
        connection,
        message,
        timeout: FBSimulatorDTUHIDTiming.replyTimeout)
    },
    awaitLivenessReply: { connection, message in
      let reply: FBSimulatorDTUHIDXPCReply
      do {
        reply = try await awaitFBSimulatorDTUHIDXPCReply(
          connection,
          message,
          timeout: FBSimulatorDTUHIDTiming.livenessTimeout)
      } catch {
        throw FBSimulatorDTUHIDLivenessFailure.timedOut
      }
      if let errorDescription = reply.errorDescription {
        throw FBSimulatorDTUHIDLivenessFailure.peerUnavailable(errorDescription)
      }
    })
}

enum FBSimulatorDTUHIDDrainTimeout: Error {
  case expired
}

enum FBSimulatorDTUHIDLivenessFailure: Error, CustomStringConvertible {
  case timedOut
  case peerUnavailable(String)

  var description: String {
    switch self {
    case .timedOut:
      return "no reply within \(FBSimulatorDTUHIDTiming.livenessTimeout)"
    case let .peerUnavailable(detail):
      return detail
    }
  }
}

/// Tracks the per-contact phase so that a stream of Indigo `.down`/`.up` events maps onto the
/// `dtuhidd` `start` / `position` / `end` model: the first `.down` is a `start`, subsequent `.down`s
/// (a drag/swipe) are `position`s, and `.up` is the `end`.
struct DigitizerContactTracker {
  private var active = false

  mutating func eventType(for direction: FBSimulatorHIDDirection) -> DigitizerEventType {
    switch direction {
    case .down:
      if active {
        return .position
      }
      active = true
      return .start
    case .up:
      active = false
      return .end
    }
  }
}

/**
 The DTUHID transport (Xcode 27 / macOS 26 / iOS 26+).

 Drives the modern `dtuhidd` daemon: events cross the host→guest boundary as plain-XPC dictionaries
 delivered to the `com.apple.coredevice.feature.remote.hid.digitizer` service. Each message is built
 as an `Encodable` model (e.g. `IndigoDigitizerEvent`) wrapped in a `DTUHIDMessage` envelope and
 serialized with `XPCEncoder`, rather than hand-rolled `xpc_dictionary_set_*` calls. The host XPC
 connection is built from the simulator's Mach port via the private `_4sim` endpoint symbols
 (resolved with `dlsym`) and must be marked simulator-to-host with `xpc_connection_enable_sim2host_4sim`
 before messages reach the service handler.

 Capabilities are added one per commit; not-yet-implemented primitives throw
 `notImplementedOnDTUHIDTransport` rather than silently falling back to Indigo.

 An `actor`: the mutable contact state is actor-isolated, so the type needs no `@unchecked Sendable`.
 The XPC connection handle is thread-safe, so `disconnect()` cancels it from a `nonisolated` context.
 */
actor FBSimulatorDTUHIDTransport: FBSimulatorHIDTransport {

  static let vendorDefinedServiceName = "com.apple.coredevice.feature.remote.hid.vendordefined"
  static let digitizerServiceName = "com.apple.coredevice.feature.remote.hid.digitizer"

  // Private XPC endpoint functions, resolved at runtime (not in the XPC module headers).
  private typealias EndpointFromMachPortFn = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
  private typealias ConnectionFromEndpointFn = @convention(c) (xpc_object_t) -> xpc_connection_t?
  private typealias EnableSim2HostFn = @convention(c) (xpc_connection_t) -> Void

  /// Time legacy digitizer `flush()` keeps the connection alive after a gesture's events are sent, so `dtuhidd`
  /// consumes them before the connection is torn down. `dtuhidd` resets its virtual services
  /// (dropping any in-flight gesture) the instant the host peer disconnects — which, for a one-shot
  /// gesture from a short-lived host process, is the moment that process exits right after the send.
  /// The XPC send barrier only confirms the bytes reached the connection, not that the daemon
  /// consumed them, and `dtuhidd` does not reply to events or barriers — so a bounded wait is the
  /// only signal available. It runs once per gesture (in `flush()`), not after every primitive.
  private static let drainNanos: UInt64 = 200_000_000 // 200ms

  /// The host→guest XPC connection to `dtuhidd`. XPC connections are thread-safe, so it is marked
  /// `nonisolated(unsafe)` to be read from the `nonisolated` `disconnect()` as well as the
  /// actor-isolated send path.
  nonisolated(unsafe) private let connection: xpc_connection_t
  private let serviceName: String
  private let mainScreenSize: CGSize
  private let mainScreenScale: Float
  private let usesReplyDrivenDelivery: Bool
  private let clock: FBSimulatorDTUHIDDrainClock
  private var contact = DigitizerContactTracker()
  private var twoFingerContact = DigitizerContactTracker()
  private var coldDrainState = ColdDrainState.pending
  private var sendGeneration = 0
  private var drainedGeneration = 0

  // MARK: Initializers

  /// Builds a DTUHID transport for the provided Simulator, establishing the host XPC connection to
  /// `dtuhidd`. All setup is synchronous, so the returned transport is ready to send.
  ///
  /// `onInvalidated` is invoked (exactly once) when the XPC connection reports a connection-level
  /// error, so a cached session backed by this transport is evicted as soon as the connection dies
  /// rather than lingering until the next boot/shutdown notification.
  static func dtuhid(
    for simulator: FBSimulator,
    serviceName: String = digitizerServiceName,
    onInvalidated: @escaping @Sendable () -> Void = {},
    usesReplyDrivenDelivery: Bool = false
  ) throws -> FBSimulatorDTUHIDTransport {
    guard let handle = dlopen(nil, RTLD_NOW) else {
      throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable
    }
    guard
      let endpointFromPort = symbol(handle, "xpc_endpoint_create_mach_port_4sim", as: EndpointFromMachPortFn.self),
      let connectionFromEndpoint = symbol(handle, "xpc_connection_create_from_endpoint", as: ConnectionFromEndpointFn.self),
      let enableSim2Host = symbol(handle, "xpc_connection_enable_sim2host_4sim", as: EnableSim2HostFn.self)
    else {
      throw FBSimulatorHIDError.dtuhidXPCSymbolsUnavailable
    }

    var lookupError: NSError?
    let servicePort = simulator.device.lookup(serviceName, error: &lookupError)
    if servicePort == 0 {
      if serviceName == digitizerServiceName {
        throw FBSimulatorHIDError.dtuhidDigitizerServiceUnavailable(underlying: lookupError)
      }
      throw FBSimulatorHIDError.dtuhidServiceUnavailable(
        name: serviceName,
        underlying: lookupError)
    }

    guard
      let endpoint = endpointFromPort(servicePort, 0, 0),
      let connection = connectionFromEndpoint(endpoint)
    else {
      throw FBSimulatorHIDError.dtuhidConnectionFailed
    }

    // The load-bearing step: without this the daemon observes the peer but never the payload.
    enableSim2Host(connection)
    xpc_connection_set_event_handler(
      connection, makeInvalidationEventHandler(onInvalidated: onInvalidated))
    xpc_connection_resume(connection)

    return FBSimulatorDTUHIDTransport(
      connection: connection,
      serviceName: serviceName,
      mainScreenSize: simulator.device.deviceType.mainScreenSize,
      mainScreenScale: simulator.device.deviceType.mainScreenScale,
      usesReplyDrivenDelivery: usesReplyDrivenDelivery)
  }

  /// Connects to a DTUHID service and proves that a live peer has activated before returning.
  /// Vendor-defined controls require this handshake; otherwise the first event can be silently
  /// discarded while `dtuhidd` is still demand-launching its virtual service.
  static func reliableDTUHID(
    for simulator: FBSimulator,
    serviceName: String,
    onInvalidated: @escaping @Sendable () -> Void = {}
  ) async throws -> FBSimulatorDTUHIDTransport {
    let logger = FBControlCoreGlobalConfiguration.defaultLogger
    var lastFailure: Error?
    for attempt in 1...FBSimulatorDTUHIDTiming.livenessAttempts {
      do {
        let transport = try dtuhid(
          for: simulator,
          serviceName: serviceName,
          onInvalidated: onInvalidated,
          usesReplyDrivenDelivery: true)
        do {
          try await transport.confirmLiveness()
          return transport
        } catch {
          transport.disconnect()
          throw error
        }
      } catch let error as FBSimulatorHIDError where !error.isTransientDTUHIDFailure {
        throw error
      } catch {
        lastFailure = error
        logger.log(
          "dtuhidd did not answer the liveness probe (attempt \(attempt) of \(FBSimulatorDTUHIDTiming.livenessAttempts)): \(error)")
        guard attempt < FBSimulatorDTUHIDTiming.livenessAttempts else {
          break
        }
        try await Task.sleep(for: FBSimulatorDTUHIDTiming.livenessRetryBackoff)
      }
    }
    throw FBSimulatorHIDError.dtuhidUnresponsive(
      attempts: FBSimulatorDTUHIDTiming.livenessAttempts,
      underlying: lastFailure)
  }

  init(
    connection: xpc_connection_t,
    serviceName: String = digitizerServiceName,
    mainScreenSize: CGSize,
    mainScreenScale: Float,
    usesReplyDrivenDelivery: Bool = false,
    clock: FBSimulatorDTUHIDDrainClock = .live
  ) {
    self.connection = connection
    self.serviceName = serviceName
    self.mainScreenSize = mainScreenSize
    self.mainScreenScale = mainScreenScale
    self.usesReplyDrivenDelivery = usesReplyDrivenDelivery
    self.clock = clock
  }

  func confirmLiveness() async throws {
    try await clock.awaitLivenessReply(connection, barrierMessage())
    try await clock.sleep(FBSimulatorDTUHIDTiming.replyTail)
    coldDrainState = .done
  }

  /// Builds the connection's XPC event handler: invokes `onInvalidated` exactly once on the first
  /// connection-level error. Both XPC errors are terminal for this connection — the endpoint is
  /// created from a Mach port looked up on one specific boot, so neither an interruption (the
  /// daemon or the boot died) nor an invalidation (cancellation) is recoverable on the same
  /// connection. This mirrors the Indigo client's send-failure invalidation: without it a failed
  /// DTUHID transport would stay cached, and every subsequent command would hit the dead
  /// connection until a boot/shutdown notification finally evicted it.
  nonisolated static func makeInvalidationEventHandler(
    onInvalidated: @escaping @Sendable () -> Void
  ) -> @Sendable (xpc_object_t) -> Void {
    let invalidationReported = Mutex(false)
    return { event in
      guard xpc_get_type(event) == XPC_TYPE_ERROR else {
        return
      }
      let shouldReport = invalidationReported.withLock { reported in
        defer { reported = true }
        return !reported
      }
      if shouldReport {
        onInvalidated()
      }
    }
  }

  private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let sym = dlsym(handle, name) else {
      return nil
    }
    return unsafeBitCast(sym, to: type)
  }

  // MARK: FBSimulatorHIDTransport

  nonisolated func disconnect() {
    xpc_connection_cancel(connection)
  }

  func sendTouch(direction: FBSimulatorHIDDirection, x: Double, y: Double) async throws {
    let ratio = FBSimulatorIndigoHID.screenRatio(
      from: CGPoint(x: x, y: y), screenSize: mainScreenSize, screenScale: mainScreenScale)
    let event = IndigoDigitizerEvent(
      pointOne: DigitizerPoint(x: Double(ratio.x), y: Double(ratio.y)),
      eventType: contact.eventType(for: direction))
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendTwoFingerTouch(direction: FBSimulatorHIDDirection, finger1: CGPoint, finger2: CGPoint) async throws {
    let r1 = FBSimulatorIndigoHID.screenRatio(from: finger1, screenSize: mainScreenSize, screenScale: mainScreenScale)
    let r2 = FBSimulatorIndigoHID.screenRatio(from: finger2, screenSize: mainScreenSize, screenScale: mainScreenScale)
    let event = IndigoDigitizerEvent(
      pointOne: DigitizerPoint(x: Double(r1.x), y: Double(r1.y)),
      pointTwo: DigitizerPoint(x: Double(r2.x), y: Double(r2.y)),
      eventType: twoFingerContact.eventType(for: direction))
    try await send(messageType: "IndigoDigitizerEvent", payload: event)
  }

  func sendButton(direction: FBSimulatorHIDDirection, button: FBSimulatorHIDButton) async throws {
    guard let usage = button.dtuhidUsage else {
      throw FBSimulatorHIDError.notImplementedOnDTUHIDTransport(
        operation: "sendButton(.applePay) — Apple Pay is a double side-button press, not a single HID usage; send two .sideButton presses instead")
    }
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoButtonEvent",
      payload: IndigoButtonEvent(usagePage: UInt64(usage.page), usageCode: UInt64(usage.code), state: state))
  }

  func sendKeyboard(direction: FBSimulatorHIDDirection, keyCode: UInt32) async throws {
    let state: HIDButtonState = direction == .down ? .down : .up
    try await send(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: UInt64(keyCode), state: state))
  }

  // The tvOS Siri Remote trackpad is not exposed by `dtuhidd`: its digitizer targets are displays
  // (`DigitizerTarget` = mainScreen/display1..10) and its scroll targets are rotary devices
  // (`ScrollTarget` = digitalCrown/dial) — none is the trackpad, and the tvOS guest registers no
  // trackpad/pointer service. So the trackpad pan is the legacy Indigo transport's job.
  func sendTrackpad(point: CGPoint, phase: FBSimulatorTrackpadPhase) async throws {
    throw FBSimulatorHIDError.notImplementedOnDTUHIDTransport(
      operation: "trackpad pan — the tvOS Siri Remote trackpad is not exposed by dtuhidd")
  }

  // MARK: Sending

  /// Wraps `payload` in a `DTUHIDMessage` and serializes it to the `xpc_object_t` `dtuhidd` decodes.
  /// Pure and stateless, so the envelope shape is unit-testable without a live daemon connection.
  nonisolated func encode(
    messageType: String,
    payload: some Encodable,
    isBarrier: Bool = false
  ) throws -> xpc_object_t {
    let message = DTUHIDMessage(
      messageType: messageType,
      featureIdentifier: serviceName,
      isBarrier: isBarrier,
      payload: payload)
    return try XPCEncoder().encode(message)
  }

  /// Encodes and sends `payload`. The established digitizer path retains its sandbox-compatible
  /// enqueue behavior. Reply-driven services additionally wait for the local XPC send barrier;
  /// `flush()` then establishes peer activation and guest dispatch before teardown.
  func send(messageType: String, payload: some Encodable) async throws {
    let object = try encode(messageType: messageType, payload: payload)
    guard usesReplyDrivenDelivery else {
      xpc_connection_send_message(connection, object)
      return
    }
    try await deliver(object)
  }

  private func deliver(_ object: xpc_object_t) async throws {
    sendGeneration += 1
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      xpc_connection_send_message(connection, object)
      xpc_connection_send_barrier(connection) {
        continuation.resume()
      }
    }
  }

  /// Drains sends before teardown. The digitizer retains its existing fixed sandbox wait.
  /// Reply-driven services use a barrier reply to activate the peer and a generation snapshot so
  /// sends racing a drain remain outstanding for the next flush.
  func flush() async throws {
    guard usesReplyDrivenDelivery else {
      try? await Task.sleep(nanoseconds: Self.drainNanos)
      return
    }

    let generation = sendGeneration
    guard generation > drainedGeneration else {
      return
    }
    if case .done = coldDrainState {
      try await clock.sleep(FBSimulatorDTUHIDTiming.drain)
    } else {
      let coldGeneration = try await coldDrain()
      if generation > coldGeneration {
        try await clock.sleep(FBSimulatorDTUHIDTiming.drain)
      }
    }
    drainedGeneration = max(drainedGeneration, generation)
  }

  private enum ColdDrainState {
    case pending
    case running(Task<Int, Error>)
    case done
  }

  private func coldDrain() async throws -> Int {
    if case let .running(task) = coldDrainState {
      return try await task.value
    }
    let generation = sendGeneration
    let task = Task<Int, Error> {
      do {
        try await self.performColdDrain()
      } catch {
        self.coldDrainState = .pending
        throw error
      }
      self.coldDrainState = .done
      return generation
    }
    coldDrainState = .running(task)
    return try await task.value
  }

  private func performColdDrain() async throws {
    do {
      try await clock.awaitBarrierReply(connection, barrierMessage())
    } catch is FBSimulatorDTUHIDDrainTimeout {
      return try await clock.sleep(FBSimulatorDTUHIDTiming.fallbackDrain)
    }
    try await clock.sleep(FBSimulatorDTUHIDTiming.replyTail)
  }

  private nonisolated func barrierMessage() throws -> xpc_object_t {
    try encode(
      messageType: "IndigoKeyboardButtonEvent",
      payload: IndigoKeyboardButtonEvent(usageCode: 0, state: .up),
      isBarrier: true)
  }

}

// MARK: - Button usage mapping

extension FBSimulatorHIDButton {

  /// The HID usage (page, code) that drives this hardware button via `dtuhidd`'s `mainScreenButtons`
  /// service. All live-confirmed against a booted Xcode 27 / iOS 26 simulator (Consumer page 0x0C).
  /// Apple Pay has no single usage — it is a double-press of the side button — so it is nil.
  var dtuhidUsage: (page: UInt16, code: UInt16)? {
    switch self {
    case .homeButton:
      return (0x0C, 0x40) // Consumer: Menu
    case .lock:
      return (0x0C, 0x30) // Consumer: Power
    case .sideButton:
      return (0x0C, 0x30) // the side button is the power/lock button
    case .siri:
      return (0x0C, 0xCF) // Consumer: Voice Command
    case .playPause:
      return (0x0C, 0xCD) // Consumer: Play/Pause
    case .applePay:
      return nil // double-press of the side button; not a single HID usage
    }
  }
}
