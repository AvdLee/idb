/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@_implementationOnly @preconcurrency import CoreSimDeviceIO
@_implementationOnly import CoreSimulator
@preconcurrency import FBControlCore
import Foundation
import IOSurface
// Fork addition: the reverse-engineered SimScreen / SimScreenAdapter protocols for
// Xcode 27's Swift-rewritten SimulatorKit live in the SimulatorKit private module.
@_implementationOnly @preconcurrency import SimulatorKit

// The FBSimulatorVideoStreamFramePusher protocol lives in FBSimulatorVideoStream.swift as a plain
// (non-@objc) Swift protocol; the pushers are only constructed and used from Swift.

@objc public protocol FBFramebufferConsumer: NSObjectProtocol {
  @objc(didChangeIOSurface:)
  func didChange(_ surface: IOSurface?)

  func didReceiveDamageRect()
}

/**
 Fork addition. Identification of a single simulator screen on Xcode 27+ (SimScreen-backed
 framebuffers). Multi-display devices such as iPhone Duo expose one entry per panel; callers use
 this to pick a framebuffer per panel via `FBFramebuffer.screenSurface(for:matching:logger:)`.

 `SimScreen` itself is `@_implementationOnly`, so this value type is the public projection of it.
 Every field is read defensively (`respondsToSelector:`); unavailable members fall back to
 `nil` / zero.
 */
public struct FBFramebufferScreenDescriptor: Sendable, Hashable, CustomStringConvertible {
  /// CoreSimulator's per-screen ID; matches the `screenID` reported by `simctl io <udid> enumerate`.
  public let screenID: UInt32
  /// Stable unique identifier (UUID string, same value `devicectl device info displays` reports), if vended.
  public let uniqueID: String?
  /// Human-readable name, if vended (iPhone Duo on Xcode 27.1: "LCD" == outer, "LCD-1" == inner).
  public let name: String?
  /// Framebuffer size in pixels (zero if unavailable).
  public let pixelSize: CGSize
  /// Whether SimulatorKit flags this as the device's default screen.
  public let isDefault: Bool
  /// Raw `SimScreenProperties.powerState`, if vended.
  public let powerState: Int32?
  /// Raw `SimScreenProperties.screenType`, if vended (0 == main display class on iOS).
  public let screenType: UInt64?
  /// Raw `SimScreenProperties.uiOrientation`, if vended.
  public let uiOrientation: UInt32?
  /// Raw `SimScreenProperties.backlight.state`, if vended. On iPhone Duo the folded-away
  /// (inactive) panel reports its backlight off while the active panel reports it on.
  public let backlightState: Int32?

  public var description: String {
    "Screen(id=\(screenID) name=\(name ?? "-") unique=\(uniqueID ?? "-") size=\(Int(pixelSize.width))x\(Int(pixelSize.height)) default=\(isDefault) power=\(powerState.map(String.init) ?? "-") type=\(screenType.map(String.init) ?? "-") orientation=\(uiOrientation.map(String.init) ?? "-") backlight=\(backlightState.map(String.init) ?? "-"))"
  }
}

/// A cancellable observation of Xcode 27+ `SimScreenProperties` changes.
public final class FBScreenPropertiesObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var invalidation: (@Sendable () -> Void)?

  fileprivate init(invalidation: @escaping @Sendable () -> Void) {
    self.invalidation = invalidation
  }

  /// Stops delivering changes. Safe to call more than once.
  public func invalidate() {
    lock.lock()
    let invalidation = self.invalidation
    self.invalidation = nil
    lock.unlock()
    invalidation?()
  }

  deinit {
    invalidate()
  }
}

@objc(FBFramebuffer)
public final class FBFramebuffer: NSObject, @unchecked Sendable {

  // MARK: - Properties

  // Fork addition: on Xcode 27+ displays are vended as SimScreens instead of the
  // legacy SimDisplayRenderable surfaces, so the framebuffer is backed by one of two
  // display representations.
  private enum Backing {
    /// Xcode <= 26: SimDisplayIOSurfaceRenderable & SimDisplayRenderable.
    case legacy(AnyObject)
    /// Xcode 27+: the Swift-rewritten SimulatorKit's SimScreen.
    case screen(any SimScreen)
  }

  private let consumers: NSMapTable<AnyObject, NSUUID>
  private let logger: any FBControlCoreLogger
  private let backing: Backing

  private var stats: FBFramebufferStats
  private var lastLoggedStats: FBFramebufferStats
  private var statsTimer: FBPeriodicStatsTimer

  // MARK: - Initializers

  @objc(mainScreenSurfaceForSimulator:logger:error:)
  public class func mainScreenSurface(for simulator: FBSimulator, logger: any FBControlCoreLogger) throws -> FBFramebuffer {
    let ioClient = simulator.device.io!
    let ports: [Any]? = ioClient.ioPorts()
    guard let ports else {
      throw FBSimulatorError.describe("No IO ports available on \(ioClient)").build()
    }
    // iOS exposes the main display as displayClass 0. tvOS renders only on the TVOut display (a
    // non-zero class), so prefer class 0 but fall back to the first renderable display rather than
    // throwing — otherwise screenshots and video are impossible on a target with no class-0 display.
    var fallbackSurface: AnyObject?
    for port in ports {
      guard let portInterface = port as? SimDeviceIOPortInterface else {
        continue
      }
      let descriptor = portInterface.descriptor as AnyObject

      // Fork addition — Xcode 27+: SimulatorKit was rewritten in Swift and the headless
      // IOSurface path moved to the SimScreenAdapter / SimScreen protocols. Prefer this
      // when the descriptor conforms (runtime feature-detection, no version sniffing).
      if let adapter = descriptor as? SimScreenAdapter {
        if let screen = defaultScreen(for: adapter, logger: logger) {
          return FBFramebuffer(backing: .screen(screen), logger: logger)
        }
        logger.log("SimScreenAdapter \(descriptor) did not vend a usable screen, continuing")
        continue
      }

      guard descriptor.conforms(to: SimDisplayRenderable.self),
        descriptor.conforms(to: SimDisplayIOSurfaceRenderable.self)
      else {
        continue
      }
      guard descriptor.responds(to: NSSelectorFromString("state")) else {
        logger.log("SimDisplay \(descriptor) does not have a state, cannot determine if it is the main display")
        continue
      }
      let descriptorState = descriptor.perform(NSSelectorFromString("state"))?.takeUnretainedValue() as! SimDisplayDescriptorState
      let displayClass = descriptorState.displayClass
      if displayClass == 0 {
        return FBFramebuffer(backing: .legacy(descriptor), logger: logger)
      }
      if fallbackSurface == nil {
        logger.log("SimDisplay Class '\(displayClass)' is not the main display '0'; holding as fallback (e.g. tvOS TVOut)")
        fallbackSurface = descriptor
      }
    }
    if let fallbackSurface {
      return FBFramebuffer(backing: .legacy(fallbackSurface), logger: logger)
    }
    throw FBSimulatorError.describe("Could not find the Main Screen Surface for Clients \(FBCollectionInformation.oneLineDescription(from: ports)) in \(ioClient)").build()
  }

  // MARK: - Fork addition: per-screen framebuffers (Xcode 27+ / multi-display devices)

  /**
   Fork addition. Returns one framebuffer per screen vended by the simulator's `SimScreenAdapter`
   IO ports (Xcode 27+). This includes *every* screen CoreSimulator knows about — on iPhone Duo
   (Xcode 27.1) that is 5: the two panels (`screenType == 0`, "LCD" 1398x2034 outer and "LCD-1"
   2007x2853 inner) plus TVOut, Wireless and Resizable. Filter on `screenDescriptor` (typically
   `screenType == 0`) to get the device panels.

   Returns an empty array on the legacy (pre-Xcode 27, `SimDisplayRenderable`-only) path; callers
   should fall back to `mainScreenSurface(for:logger:)` there. The legacy path is deliberately
   untouched.
   */
  public class func allScreenSurfaces(for simulator: FBSimulator, logger: any FBControlCoreLogger) throws -> [FBFramebuffer] {
    let ioClient = simulator.device.io!
    guard let ports: [Any] = ioClient.ioPorts() else {
      throw FBSimulatorError.describe("No IO ports available on \(ioClient)").build()
    }
    var framebuffers: [FBFramebuffer] = []
    for port in ports {
      guard let portInterface = port as? SimDeviceIOPortInterface,
        let adapter = portInterface.descriptor as? SimScreenAdapter
      else {
        continue
      }
      guard let screens = enumerateScreens(for: adapter, logger: logger) else {
        continue
      }
      for screen in screens {
        framebuffers.append(FBFramebuffer(backing: backing(forEnumeratedScreen: screen), logger: logger))
      }
    }
    return framebuffers
  }

  /**
   Fork addition. Picks the backing for a screen returned by `enumerateScreens`.

   Observed on Xcode 27.1: the enumerated objects are CoreSimulator `ROCKRemoteProxy` instances
   that conform to `SimScreen` *and* to the legacy `SimDisplayIOSurfaceRenderable` /
   `SimDisplayRenderable` protocols, but do not respond to `unmaskedSurface` / `maskedSurface`
   (those live on SimulatorKit's `SimDeviceScreen` wrapper). For such objects the legacy surface
   + callback registration is the working path, so prefer it whenever available.
   */
  private class func backing(forEnumeratedScreen screen: any SimScreen) -> Backing {
    let object = screen as AnyObject
    if object.conforms(to: SimDisplayRenderable.self), object.conforms(to: SimDisplayIOSurfaceRenderable.self) {
      return .legacy(object)
    }
    return .screen(screen)
  }

  /**
   Fork addition. Returns the framebuffer for the first screen whose descriptor satisfies
   `matching`. Throws when no SimScreen-backed screen matches (including on the legacy path,
   which vends no descriptors).

   Example (iPhone Duo): `matching: { $0.pixelSize.width == 2007 }` for the inner panel.
   */
  public class func screenSurface(
    for simulator: FBSimulator,
    matching: (FBFramebufferScreenDescriptor) -> Bool,
    logger: any FBControlCoreLogger
  ) throws -> FBFramebuffer {
    let all = try allScreenSurfaces(for: simulator, logger: logger)
    for framebuffer in all {
      if let descriptor = framebuffer.screenDescriptor, matching(descriptor) {
        return framebuffer
      }
    }
    throw FBSimulatorError.describe(
      "No screen matched the predicate. Available screens: \(all.compactMap(\.screenDescriptor).map(\.description).joined(separator: ", "))"
    ).build()
  }

  /// Fork addition. Convenience: framebuffer for the screen with the given CoreSimulator `screenID`.
  public class func screenSurface(for simulator: FBSimulator, screenID: UInt32, logger: any FBControlCoreLogger) throws -> FBFramebuffer {
    try screenSurface(for: simulator, matching: { $0.screenID == screenID }, logger: logger)
  }

  /// Fork addition. Convenience: framebuffer for the screen whose pixel size matches `pixelSize` exactly.
  public class func screenSurface(for simulator: FBSimulator, pixelSize: CGSize, logger: any FBControlCoreLogger) throws -> FBFramebuffer {
    try screenSurface(for: simulator, matching: { $0.pixelSize == pixelSize }, logger: logger)
  }

  /**
   Fork addition. Identification of the screen backing this framebuffer. `nil` when the backing
   object does not conform to `SimScreen` (pre-Xcode 27). On Xcode 27.1 even the legacy
   `com.apple.framebuffer.display` port descriptors conform, so `mainScreenSurface` results carry a
   descriptor too.
   */
  public var screenDescriptor: FBFramebufferScreenDescriptor? {
    let object: AnyObject
    switch backing {
    case .screen(let screen):
      object = screen as AnyObject
    case .legacy(let legacy):
      object = legacy
    }
    // Only SimScreen-conforming objects (Xcode 27+) carry `screenProperties`; the pre-27
    // `SimDisplayRenderable` descriptors do not, and yield `nil` here.
    guard object.conforms(to: SimScreen.self), let screen = object as? any SimScreen else {
      return nil
    }
    return Self.descriptor(for: screen)
  }

  /// Fork addition. Defensive projection of `SimScreen` + `SimScreenProperties` into a value type.
  private class func descriptor(for screen: any SimScreen) -> FBFramebufferScreenDescriptor {
    let isDefault = screen.responds(to: #selector(getter: SimScreen.isDefault)) && screen.isDefault
    var properties: (any SimScreenProperties)?
    if screen.responds(to: #selector(getter: SimScreen.screenProperties)) {
      properties = (try? FBObjCExceptionGuard.guarded { screen.screenProperties }) as? (any SimScreenProperties)
    }
    guard let properties else {
      return FBFramebufferScreenDescriptor(
        screenID: 0, uniqueID: nil, name: nil, pixelSize: .zero, isDefault: isDefault, powerState: nil, screenType: nil, uiOrientation: nil, backlightState: nil)
    }
    return descriptor(for: screen, properties: properties)
  }

  /// Fork addition. Defensive projection using properties delivered by a screen callback.
  private class func descriptor(
    for screen: any SimScreen,
    properties: any SimScreenProperties
  ) -> FBFramebufferScreenDescriptor {
    let isDefault = screen.responds(to: #selector(getter: SimScreen.isDefault)) && screen.isDefault
    func has(_ selector: Selector) -> Bool { properties.responds(to: selector) }
    let pixelSize: CGSize
    if has(#selector(getter: SimScreenProperties.pixelSize)) {
      pixelSize = properties.pixelSize
    } else if screen.responds(to: #selector(getter: SimScreen.unmaskedSurface)), let surface = screen.unmaskedSurface {
      pixelSize = CGSize(width: surface.width, height: surface.height)
    } else {
      pixelSize = .zero
    }
    var backlightState: Int32?
    if has(#selector(getter: SimScreenProperties.backlight)),
      let backlight = (try? FBObjCExceptionGuard.guarded { properties.backlight }) as? (any SimScreenBacklight),
      backlight.responds(to: #selector(getter: SimScreenBacklight.state))
    {
      backlightState = backlight.state
    }
    return FBFramebufferScreenDescriptor(
      screenID: has(#selector(getter: SimScreenProperties.screenID)) ? properties.screenID : 0,
      uniqueID: has(#selector(getter: SimScreenProperties.uniqueId)) ? properties.uniqueId : nil,
      name: has(#selector(getter: SimScreenProperties.name)) ? properties.name : nil,
      pixelSize: pixelSize,
      isDefault: isDefault,
      powerState: has(#selector(getter: SimScreenProperties.powerState)) ? properties.powerState : nil,
      screenType: has(#selector(getter: SimScreenProperties.screenType)) ? properties.screenType : nil,
      uiOrientation: has(#selector(getter: SimScreenProperties.uiOrientation)) ? properties.uiOrientation : nil,
      backlightState: backlightState)
  }

  /**
   Fork addition. Synchronously resolves the default `SimScreen` from a `SimScreenAdapter`.

   `mainScreenSurface(for:logger:)` is a synchronous factory, but the Xcode 27
   enumeration API is asynchronous, so we bridge it with a bounded semaphore wait.
   */
  private class func defaultScreen(for adapter: SimScreenAdapter, logger: any FBControlCoreLogger) -> (any SimScreen)? {
    guard let screens = enumerateScreens(for: adapter, logger: logger) else {
      return nil
    }
    return screens.first { $0.responds(to: #selector(getter: SimScreen.isDefault)) && $0.isDefault } ?? screens.first
  }

  /**
   Fork addition. Synchronously enumerates every `SimScreen` on a `SimScreenAdapter` (bounded
   semaphore bridge over the asynchronous Xcode 27 API). Returns `nil` when the adapter cannot
   enumerate or times out.
   */
  private class func enumerateScreens(for adapter: SimScreenAdapter, logger: any FBControlCoreLogger) -> [any SimScreen]? {
    guard adapter.responds(to: #selector(SimScreenAdapter.enumerateScreens(completionQueue:completionHandler:))) else {
      logger.log("SimScreenAdapter \(adapter) does not respond to enumerateScreensWithCompletionQueue:completionHandler:")
      return nil
    }

    let semaphore = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "com.facebook.fbsimulatorcontrol.framebuffer.screenenumeration")
    nonisolated(unsafe) var resolvedScreens: [any SimScreen]?
    nonisolated(unsafe) let loggerRef = logger

    adapter.enumerateScreens(completionQueue: queue) { screens, enumerationError in
      if let enumerationError {
        loggerRef.log("Failed to enumerate SimScreens: \(enumerationError)")
      }
      resolvedScreens = screens ?? []
      semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + 10) == .success else {
      logger.log("Timed out waiting for SimScreenAdapter \(adapter) to enumerate screens")
      return nil
    }
    return resolvedScreens
  }

  private init(backing: Backing, logger: any FBControlCoreLogger) {
    self.consumers = NSMapTable(keyOptions: .weakMemory, valueOptions: .copyIn)
    self.logger = logger
    self.backing = backing
    self.stats = FBFramebufferStats()
    self.lastLoggedStats = FBFramebufferStats()
    self.statsTimer = FBPeriodicStatsTimerCreate(5.0)
    super.init()
  }

  // MARK: - Public Methods

  @objc(attachConsumer:onQueue:)
  public func attach(_ consumer: any FBFramebufferConsumer, on queue: DispatchQueue) -> IOSurface? {
    // Don't attach the same consumer twice
    assert(!isConsumerAttached(consumer), "Cannot re-attach the same consumer \(consumer)")
    let consumerUUID = NSUUID()

    // Attempt to return the surface synchronously (if supported).
    let immediateSurface = extractImmediatelyAvailableSurface()

    // Register the consumer.
    consumers.setObject(consumerUUID, forKey: consumer as AnyObject)
    registerConsumer(consumer, uuid: consumerUUID, queue: queue)

    return immediateSurface
  }

  @objc(detachConsumer:)
  public func detach(_ consumer: any FBFramebufferConsumer) {
    guard let uuid = consumers.object(forKey: consumer as AnyObject) else {
      return
    }
    consumers.removeObject(forKey: consumer as AnyObject)
    unregisterConsumer(uuid: uuid)
  }

  @objc(isConsumerAttached:)
  public func isConsumerAttached(_ consumer: any FBFramebufferConsumer) -> Bool {
    let enumerator = consumers.keyEnumerator()
    while let existingConsumer = enumerator.nextObject() {
      if existingConsumer as AnyObject === consumer as AnyObject {
        return true
      }
    }
    return false
  }

  /**
   Observes screen-property changes for Xcode 27+ `SimScreen` framebuffers.

   The current descriptor is delivered once on `queue`, followed by changed descriptors.
   Calling `invalidate()` unregisters this observation. True legacy framebuffers (whose backing
   object does not also conform to `SimScreen`) return a no-op observation because their display
   API has no equivalent properties callback. Xcode 27 screen proxies can use a legacy surface
   backing while still supporting the `SimScreen` properties callback.
   */
  public func observeScreenProperties(
    queue: DispatchQueue,
    handler: @escaping @Sendable (FBFramebufferScreenDescriptor) -> Void
  ) -> FBScreenPropertiesObservation {
    let screen: any SimScreen
    switch backing {
    case .screen(let screenBacking):
      screen = screenBacking
    case .legacy(let legacy) where legacy.conforms(to: SimScreen.self):
      guard let screenBacking = legacy as? any SimScreen else {
        return FBScreenPropertiesObservation(invalidation: {})
      }
      screen = screenBacking
    case .legacy:
      return FBScreenPropertiesObservation(invalidation: {})
    }

    let currentDescriptor = Self.descriptor(for: screen)
    queue.async {
      handler(currentDescriptor)
    }

    let uuid = UUID()
    _ = try? FBObjCExceptionGuard.guarded {
      screen.registerScreenCallbacks(
        uuid: uuid,
        callbackQueue: queue,
        frameCallback: {},
        surfacesChangedCallback: { _, _ in },
        propertiesChangedCallback: { properties in
          handler(Self.descriptor(for: screen, properties: properties))
        })
    }

    return FBScreenPropertiesObservation { [weak screen] in
      guard let screen,
        screen.responds(to: #selector(SimScreen.unregisterScreenCallbacks(uuid:)))
      else {
        return
      }
      _ = try? FBObjCExceptionGuard.guarded {
        screen.unregisterScreenCallbacks(uuid: uuid)
      }
    }
  }

  // MARK: - Stats

  @objc
  public func currentStats() -> FBFramebufferStats {
    stats
  }

  @objc public var statsStartTime: CFTimeInterval {
    statsTimer.startTime
  }

  // MARK: - Private

  private func extractImmediatelyAvailableSurface() -> IOSurface? {
    switch backing {
    case .legacy(let surface):
      guard let renderable = surface as? SimDisplayIOSurfaceRenderable else {
        return nil
      }
      if let surface = try? FBObjCExceptionGuard.guarded({ renderable.framebufferSurface }) as? IOSurface {
        return surface
      }
      return try? FBObjCExceptionGuard.guarded({ renderable.ioSurface }) as? IOSurface
    case .screen(let screen):
      // Prefer the raw (unmasked) surface to mirror the legacy framebufferSurface.
      // Fork hardening: CoreSimulator proxies may conform to SimScreen without these getters.
      let unmasked = screen.responds(to: #selector(getter: SimScreen.unmaskedSurface)) ? screen.unmaskedSurface : nil
      let masked = screen.responds(to: #selector(getter: SimScreen.maskedSurface)) ? screen.maskedSurface : nil
      return unmasked ?? masked
    }
  }

  private func registerConsumer(_ consumer: any FBFramebufferConsumer, uuid: NSUUID, queue: DispatchQueue) {
    switch backing {
    case .legacy(let surface):
      registerLegacyConsumer(consumer, surface: surface, uuid: uuid, queue: queue)
    case .screen(let screen):
      registerScreenConsumer(consumer, screen: screen, uuid: uuid, queue: queue)
    }
  }

  /// Fork addition: consumer registration against Xcode 27's unified SimScreen callbacks.
  /// The per-frame callback maps onto `didReceiveDamageRect()` so deferred (damage-driven)
  /// video streaming keeps working on Xcode 27, where rect-level damage callbacks no longer exist.
  private func registerScreenConsumer(_ consumer: any FBFramebufferConsumer, screen: any SimScreen, uuid: NSUUID, queue: DispatchQueue) {
    nonisolated(unsafe) let consumerRef = consumer

    _ = try? FBObjCExceptionGuard.guarded {
      screen.registerScreenCallbacks(
        uuid: uuid as UUID,
        callbackQueue: queue,
        frameCallback: { [weak self] in
          guard let self else { return }
          self.stats.damageCallbackCount += 1
          self.logStatsIfNeeded()
          queue.async {
            consumerRef.didReceiveDamageRect()
          }
        },
        surfacesChangedCallback: { [weak self] (unmaskedSurface: IOSurface?, maskedSurface: IOSurface?) in
          guard let self else { return }
          self.stats.ioSurfaceChangeCount += 1
          // Prefer the raw (unmasked) surface to mirror the legacy framebufferSurface.
          nonisolated(unsafe) let surfaceRef = unmaskedSurface ?? maskedSurface
          if self.stats.ioSurfaceChangeCount == 1 {
            self.logger.info().log("First SimScreen surface change callback, surface=\(String(describing: surfaceRef))")
          }
          queue.async {
            consumerRef.didChange(surfaceRef)
          }
        },
        propertiesChangedCallback: { _ in })
    }
  }

  private func registerLegacyConsumer(_ consumer: any FBFramebufferConsumer, surface: AnyObject, uuid: NSUUID, queue: DispatchQueue) {
    let renderable = surface as! SimDisplayIOSurfaceRenderable
    nonisolated(unsafe) let consumerRef = consumer

    let ioSurfaceChanged: (Any?) -> Void = { [weak self] surfaceArg in
      guard let self else { return }
      self.stats.ioSurfaceChangeCount += 1
      if self.stats.ioSurfaceChangeCount == 1 {
        self.logger.info().log("First IOSurface change callback, surface=\(String(describing: surfaceArg))")
      }
      nonisolated(unsafe) let surfaceRef = surfaceArg
      queue.async {
        consumerRef.didChange(surfaceRef as? IOSurface)
      }
    }

    _ = try? FBObjCExceptionGuard.guarded {
      renderable.registerCallback(with: uuid as UUID, ioSurfacesChangeCallback: ioSurfaceChanged)
    }
    _ = try? FBObjCExceptionGuard.guarded {
      renderable.registerCallback(with: uuid as UUID, ioSurfaceChangeCallback: ioSurfaceChanged)
    }

    let displayRenderable = surface as! SimDisplayRenderable
    let damageCallback: ([Any]?) -> Void = { [weak self] frames in
      guard let self else { return }
      let frameArray = frames ?? []
      self.stats.damageCallbackCount += 1
      self.stats.damageRectCount += UInt(frameArray.count)
      if frameArray.isEmpty {
        self.stats.emptyDamageCallbackCount += 1
      }
      self.logStatsIfNeeded()
      queue.async {
        consumerRef.didReceiveDamageRect()
      }
    }
    _ = try? FBObjCExceptionGuard.guarded {
      displayRenderable.registerCallback(with: uuid as UUID, damageRectanglesCallback: damageCallback)
    }
  }

  private func logStatsIfNeeded() {
    var timer = statsTimer
    var intervalDuration: CFTimeInterval = 0
    var totalElapsed: CFTimeInterval = 0
    if !FBPeriodicStatsTimerTick(&timer, &intervalDuration, &totalElapsed) {
      if timer.startTime != statsTimer.startTime {
        statsTimer = timer
        logger.info().log("First damage callback received")
      }
      return
    }
    statsTimer = timer

    let current = stats
    let last = lastLoggedStats
    let intervalCallbacks = current.damageCallbackCount - last.damageCallbackCount
    let intervalRects = current.damageRectCount - last.damageRectCount
    let intervalEmpty = current.emptyDamageCallbackCount - last.emptyDamageCallbackCount
    let intervalIOSurface = current.ioSurfaceChangeCount - last.ioSurfaceChangeCount
    lastLoggedStats = current

    let intervalRate = intervalDuration > 0 ? Double(intervalCallbacks) / intervalDuration : 0
    let totalRate = totalElapsed > 0 ? Double(current.damageCallbackCount) / totalElapsed : 0

    logger.info().log(
      String(
        format: "Framebuffer stats (interval): %lu damage callbacks in %.1fs (%.1f/s, %lu rects, %lu empty) — %lu IOSurface changes",
        intervalCallbacks, intervalDuration, intervalRate, intervalRects, intervalEmpty, intervalIOSurface))
    logger.info().log(
      String(
        format: "Framebuffer stats (total): %lu damage callbacks in %.1fs (%.1f/s, %lu rects, %lu empty) — %lu IOSurface changes",
        current.damageCallbackCount, totalElapsed, totalRate, current.damageRectCount, current.emptyDamageCallbackCount, current.ioSurfaceChangeCount))
  }

  private func unregisterConsumer(uuid: NSUUID) {
    switch backing {
    case .legacy(let surface):
      let renderable = surface as! SimDisplayIOSurfaceRenderable
      _ = try? FBObjCExceptionGuard.guarded {
        renderable.unregisterIOSurfacesChangeCallback(with: uuid as UUID)
      }
      _ = try? FBObjCExceptionGuard.guarded {
        renderable.unregisterIOSurfaceChangeCallback(with: uuid as UUID)
      }
      let displayRenderable = surface as! SimDisplayRenderable
      _ = try? FBObjCExceptionGuard.guarded {
        displayRenderable.unregisterDamageRectanglesCallback(with: uuid as UUID)
      }
    case .screen(let screen):
      guard screen.responds(to: #selector(SimScreen.unregisterScreenCallbacks(uuid:))) else {
        return
      }
      _ = try? FBObjCExceptionGuard.guarded {
        screen.unregisterScreenCallbacks(uuid: uuid as UUID)
      }
    }
  }
}
