/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreMedia
import CoreVideo
import FBControlCore
@testable import FBSimulatorControl
import ImageIO
import VideoToolbox
import XCTest

final class FBSimulatorVideoStreamCallbackTests: XCTestCase {

  // MARK: - Helpers

  private func makeReadySampleBuffer() -> CMSampleBuffer {
    createH264SampleBuffer()
  }

  private func makeNotReadySampleBuffer() -> CMSampleBuffer {
    createNotReadySampleBuffer()
  }

  // MARK: - Tests

  func testWarmupFramesSuppressed() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // Send 5 not-ready buffers (simulates warmup)
    for _ in 0..<5 {
      let notReady = makeNotReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    // No per-frame messages during warmup
    for msg in logger.messages {
      XCTAssertFalse((msg as! String).contains("Sample Buffer is not ready"), "Should not log per-frame not-ready messages during warmup")
    }

    // Now send a ready buffer to complete warmup
    let ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    // Should have a single warmup message
    var warmupMessageCount: UInt = 0
    for msg in logger.messages {
      if (msg as! String).contains("Encoder warmed up after 5 skipped frames") {
        warmupMessageCount += 1
      }
    }
    XCTAssertEqual(warmupMessageCount, 1, "Should log exactly one warmup completion message")
    XCTAssertTrue(pusher.warmupComplete)
  }

  func testStarvationDetectedDuringWarmup() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // Send 20 not-ready buffers without any success
    for _ in 0..<20 {
      let notReady = makeNotReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    var foundStarvationWarning = false
    for msg in logger.messages {
      if (msg as! String).contains("has not produced a frame after 20 attempts") {
        foundStarvationWarning = true
      }
    }
    XCTAssertTrue(foundStarvationWarning, "Should warn about possible starvation after 20 warmup frames")
    XCTAssertTrue(pusher.starvationWarningLogged)
  }

  func testPostWarmupStarvation() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // First, complete warmup with a ready buffer
    let ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    XCTAssertTrue(pusher.warmupComplete)

    // Now send 10 not-ready buffers post-warmup
    for _ in 0..<10 {
      let notReady = makeNotReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    var foundStarvationWarning = false
    for msg in logger.messages {
      if (msg as! String).contains("Encoder starvation: 10 consecutive frames not ready after warmup") {
        foundStarvationWarning = true
      }
    }
    XCTAssertTrue(foundStarvationWarning, "Should warn about post-warmup starvation after 10 consecutive failures")
    XCTAssertTrue(pusher.starvationWarningLogged)
  }

  func testEncodeErrorLogged() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    pusher.handleCompressedSampleBuffer(nil, encodeStatus: -12345, infoFlags: VTEncodeInfoFlags())

    var foundError = false
    for msg in logger.messages {
      if (msg as! String).contains("VideoToolbox encode error: OSStatus -12345") {
        foundError = true
      }
    }
    XCTAssertTrue(foundError, "Should log VideoToolbox encode error with status code")
    XCTAssertEqual(pusher.stats.callbackCount, 1)
  }

  func testFrameDroppedCountedAsFailure() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    pusher.handleCompressedSampleBuffer(nil, encodeStatus: noErr, infoFlags: .frameDropped)

    // Dropped frame should increment failure counter, not produce a per-frame log
    XCTAssertEqual(pusher.consecutiveNotReadyFrameCount, 1)
    XCTAssertEqual(pusher.stats.callbackCount, 1)
    XCTAssertEqual(UInt(logger.messages.count), 1, "Should only log the first-callback message, not per-frame drop messages")
  }

  func testDroppedFramesTriggersStarvationWarning() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // Send 20 dropped frames — should trigger starvation warning
    for _ in 0..<20 {
      pusher.handleCompressedSampleBuffer(nil, encodeStatus: noErr, infoFlags: .frameDropped)
    }

    var foundStarvationWarning = false
    for msg in logger.messages {
      if (msg as! String).contains("has not produced a frame after 20 attempts") {
        foundStarvationWarning = true
      }
    }
    XCTAssertTrue(foundStarvationWarning, "20 consecutive dropped frames should trigger starvation warning")
    XCTAssertEqual(UInt(logger.messages.count), 2, "Should produce the first-callback message and one starvation warning")
  }

  func testNoWarmupMessageWhenFirstFrameSucceeds() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // Send a ready buffer immediately
    let ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    XCTAssertTrue(pusher.warmupComplete)

    // No warmup message should be logged
    for msg in logger.messages {
      XCTAssertFalse((msg as! String).contains("Encoder warmed up"), "Should not log warmup message when first frame succeeds immediately")
    }
  }

  func testPeriodicStatsNotLoggedBeforeInterval() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // Send a few successful frames — stats interval hasn't elapsed
    for _ in 0..<3 {
      let ready = makeReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    for msg in logger.messages {
      XCTAssertFalse((msg as! String).contains("Video stats"), "Should not log stats before interval elapses")
    }
  }

  func testPeriodicStatsLoggedAfterInterval() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // Send one frame to initialize timing
    var ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    // Backdate statsTimer by 6 seconds to trigger stats on next frame
    var timer = pusher.statsTimer
    timer.lastLogTime = CFAbsoluteTimeGetCurrent() - 6.0
    pusher.statsTimer = timer

    ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    var foundStats = false
    for msg in logger.messages {
      if (msg as! String).contains("Video stats") {
        foundStats = true
      }
    }
    XCTAssertTrue(foundStats, "Should log stats after interval elapses")
  }

  func testPeriodicStatsCountersAccurate() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // 3 successful writes
    for _ in 0..<3 {
      let ready = makeReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    // 2 dropped frames
    for _ in 0..<2 {
      pusher.handleCompressedSampleBuffer(nil, encodeStatus: noErr, infoFlags: .frameDropped)
    }

    // 1 encode error
    pusher.handleCompressedSampleBuffer(nil, encodeStatus: -12345, infoFlags: VTEncodeInfoFlags())

    // Verify counters
    XCTAssertEqual(pusher.stats.writeCount, 3)
    XCTAssertEqual(pusher.stats.dropCount, 2)
    XCTAssertEqual(pusher.stats.encodeErrorCount, 1)
    XCTAssertEqual(pusher.stats.callbackCount, 6)

    // Backdate to trigger stats log
    var timer = pusher.statsTimer
    timer.lastLogTime = CFAbsoluteTimeGetCurrent() - 6.0
    pusher.statsTimer = timer

    let ready = makeReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(ready, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    var foundStats = false
    for msg in logger.messages {
      let s = msg as! String
      if s.contains("Video stats")
        && s.contains("4 written")
        && s.contains("2 dropped")
        && s.contains("1 encode errors")
      {
        foundStats = true
      }
    }
    XCTAssertTrue(foundStats, "Stats message should contain accurate counters")
  }

  func testPeriodicStatsDuringWarmup() {
    let logger = FBCapturingLogger()
    let pusher = createTestVideoStreamPusher(logger)

    // Send 10 not-ready buffers (write failures during warmup)
    for _ in 0..<10 {
      let notReady = makeNotReadySampleBuffer()
      pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())
    }

    // Backdate to trigger stats log
    var timer = pusher.statsTimer
    timer.lastLogTime = CFAbsoluteTimeGetCurrent() - 6.0
    pusher.statsTimer = timer

    // Send one more not-ready buffer to trigger the stats log
    let notReady = makeNotReadySampleBuffer()
    pusher.handleCompressedSampleBuffer(notReady, encodeStatus: noErr, infoFlags: VTEncodeInfoFlags())

    var foundStats = false
    for msg in logger.messages {
      let s = msg as! String
      if s.contains("Video stats")
        && s.contains("0 written")
        && s.contains("11 write failures")
      {
        foundStats = true
      }
    }
    XCTAssertTrue(foundStats, "Stats during warmup should show 0 written and write failures")
  }
}

/// Tests for the `.lazy` cadence frame-rate cap (`FrameRateLimiter` + `LazyFrameTriggers`).
/// The push loop awaits each push before pulling the next trigger, so iterating the triggers directly
/// and stamping each yield (`lastTriggerInstant`) models the push start times exactly. Most tests use a
/// fake clock whose sleep jumps to the deadline plus a configurable wake lateness, so nothing really sleeps.
final class FBSimulatorVideoStreamFrameRateCapTests: XCTestCase {

  private final class FakeClock: @unchecked Sendable {
    var now = ContinuousClock.now
    var wakeLateness = Duration.zero
    var sleepDeadlines: [ContinuousClock.Instant] = []
  }

  private func makeTriggers(limiter: FrameRateLimiter, clock: FakeClock) -> LazyFrameTriggers {
    LazyFrameTriggers(
      frameRateLimiter: limiter,
      now: { clock.now },
      sleepUntil: { deadline in
        clock.sleepDeadlines.append(deadline)
        clock.now = deadline + clock.wakeLateness
      })
  }

  func testCappedTriggersAreSpacedByTheIntervalAndDeliverTheTrailingFrame() async throws {
    let clock = FakeClock()
    let triggers = makeTriggers(limiter: FrameRateLimiter(maximumFramesPerSecond: 20), clock: clock)
    let interval = Duration.milliseconds(50)
    var iterator = triggers.makeAsyncIterator()
    var pushInstants: [ContinuousClock.Instant] = []
    var deadlines: [ContinuousClock.Instant?] = []
    var lastDamageInstant = clock.now

    triggers.signalDamage()
    while await iterator.next() != nil {
      pushInstants.append(try XCTUnwrap(iterator.lastTriggerInstant))
      deadlines.append(iterator.lastTriggerDeadline)
      guard pushInstants.count < 5 else { continue }
      // A burst of damage before each wait coalesces into the next push.
      lastDamageInstant = clock.now
      for _ in 0..<10 {
        triggers.signalDamage()
      }
      if pushInstants.count == 4 {
        // Stop signalling: the burst above is the trailing damage and must still be pushed.
        triggers.finish()
      }
    }

    XCTAssertEqual(pushInstants.count, 5, "Each burst should coalesce into exactly one push, including the trailing one")
    XCTAssertNil(deadlines[0], "The first push is not rate limited")
    let scheduled = deadlines.dropFirst().compactMap { $0 }
    XCTAssertEqual(scheduled, (1...4).map { pushInstants[0] + interval * $0 }, "Every later push waits for a deadline one interval after the previous one")
    // The last wait precedes pulling the end of the finished stream.
    XCTAssertEqual(Array(clock.sleepDeadlines.prefix(4)), scheduled)
    XCTAssertEqual(Array(pushInstants.dropFirst()), scheduled, "Each push happens at its deadline, never before")
    XCTAssertGreaterThan(try XCTUnwrap(pushInstants.last), lastDamageInstant, "The final push must follow the trailing damage")
  }

  func testRuntimeCapChangeAppliesFromTheNextWait() async throws {
    let limiter = FrameRateLimiter(maximumFramesPerSecond: 20)
    let triggers = makeTriggers(limiter: limiter, clock: FakeClock())
    var iterator = triggers.makeAsyncIterator()
    var pushInstants: [ContinuousClock.Instant] = []

    triggers.signalDamage()
    while await iterator.next() != nil {
      pushInstants.append(try XCTUnwrap(iterator.lastTriggerInstant))
      switch pushInstants.count {
      case 2:
        limiter.setMaximumFramesPerSecond(10)
      case 4:
        limiter.setMaximumFramesPerSecond(nil)
      case 5:
        triggers.finish()
        continue
      default:
        break
      }
      triggers.signalDamage()
    }

    XCTAssertEqual(pushInstants.count, 5)
    XCTAssertGreaterThanOrEqual(pushInstants[1] - pushInstants[0], .milliseconds(50), "The initial 20 fps cap applies")
    XCTAssertGreaterThanOrEqual(pushInstants[2] - pushInstants[1], .milliseconds(100), "Lowering to 10 fps applies from the next wait")
    XCTAssertGreaterThanOrEqual(pushInstants[3] - pushInstants[2], .milliseconds(100))
    XCTAssertLessThan(pushInstants[4] - pushInstants[3], .milliseconds(100), "Removing the cap stops waiting")
  }

  func testWakeLatenessDoesNotAccumulate() async throws {
    let clock = FakeClock()
    clock.wakeLateness = .milliseconds(4)
    let triggers = makeTriggers(limiter: FrameRateLimiter(maximumFramesPerSecond: 30), clock: clock)
    var iterator = triggers.makeAsyncIterator()
    var pushInstants: [ContinuousClock.Instant] = []

    triggers.signalDamage()
    while pushInstants.count < 31, await iterator.next() != nil {
      pushInstants.append(try XCTUnwrap(iterator.lastTriggerInstant))
      triggers.signalDamage()
    }

    let elapsed = try XCTUnwrap(pushInstants.last) - pushInstants[0]
    XCTAssertGreaterThanOrEqual(elapsed, .seconds(1), "30 intervals at 30 fps must never run faster than the cap")
    XCTAssertLessThanOrEqual(elapsed, .milliseconds(1010), "Wake lateness must not compound: the rate stays within 1% of the cap")
    for (previous, next) in zip(pushInstants, pushInstants.dropFirst()) {
      XCTAssertGreaterThanOrEqual(next - previous, .seconds(1.0 / 30.0) - .milliseconds(4), "Spacing shrinks by at most the previous lateness")
    }
  }

  func testIdleGapRestartsTheScheduleWithoutBursting() async throws {
    let clock = FakeClock()
    let triggers = makeTriggers(limiter: FrameRateLimiter(maximumFramesPerSecond: 30), clock: clock)
    let interval = Duration.seconds(1.0 / 30.0)
    var iterator = triggers.makeAsyncIterator()

    triggers.signalDamage()
    _ = await iterator.next()
    clock.now += interval * 3
    let resumeInstant = clock.now

    triggers.signalDamage()
    _ = await iterator.next()
    XCTAssertEqual(iterator.lastTriggerInstant, resumeInstant, "The first trigger after an idle gap yields immediately")
    XCTAssertTrue(clock.sleepDeadlines.isEmpty)

    triggers.signalDamage()
    _ = await iterator.next()
    XCTAssertEqual(clock.sleepDeadlines, [resumeInstant + interval], "The next trigger waits a full interval, not a catch-up burst")
  }

  func testRemovingTheCapYieldsImmediately() async throws {
    let clock = FakeClock()
    let limiter = FrameRateLimiter(maximumFramesPerSecond: 30)
    let triggers = makeTriggers(limiter: limiter, clock: clock)
    var iterator = triggers.makeAsyncIterator()

    triggers.signalDamage()
    _ = await iterator.next()
    triggers.signalDamage()
    _ = await iterator.next()
    XCTAssertEqual(clock.sleepDeadlines.count, 1)
    let afterCappedPush = clock.now

    limiter.setMaximumFramesPerSecond(nil)
    triggers.signalDamage()
    _ = await iterator.next()
    XCTAssertEqual(clock.sleepDeadlines.count, 1, "Uncapped triggers must not wait")
    XCTAssertEqual(iterator.lastTriggerInstant, afterCappedPush)
  }

  func testUncappedTriggersDoNotWait() async throws {
    let clock = FakeClock()
    let triggers = makeTriggers(limiter: FrameRateLimiter(), clock: clock)
    let start = clock.now
    var iterator = triggers.makeAsyncIterator()
    var pushInstants: [ContinuousClock.Instant] = []

    triggers.signalDamage()
    while await iterator.next() != nil {
      pushInstants.append(try XCTUnwrap(iterator.lastTriggerInstant))
      XCTAssertNil(iterator.lastTriggerDeadline)
      if pushInstants.count == 3 {
        triggers.finish()
      } else {
        triggers.signalDamage()
      }
    }

    XCTAssertEqual(pushInstants, [start, start, start], "No cap means no wait between pushes")
    XCTAssertTrue(clock.sleepDeadlines.isEmpty)
  }

  func testCancelledTaskEndsTheTriggers() async {
    let clock = FakeClock()
    let triggers = makeTriggers(limiter: FrameRateLimiter(maximumFramesPerSecond: 30), clock: clock)
    triggers.signalDamage()

    let task = Task {
      var iterator = triggers.makeAsyncIterator()
      withUnsafeCurrentTask { $0?.cancel() }
      return await iterator.next()
    }

    let result = await task.value
    XCTAssertNil(result, "A cancelled push loop must end even though the triggers were never finished")
    XCTAssertTrue(clock.sleepDeadlines.isEmpty)
  }

  func testStreamFrameRateCapReachesTheLazyTriggers() throws {
    let logger = FBCapturingLogger()
    let configuration = FBVideoStreamConfiguration(
      format: .compressedVideo(withCodec: .h264, transport: .annexB),
      framesPerSecond: nil,
      rateControl: nil,
      scaleFactor: nil,
      keyFrameRate: 10.0)
    let stream = FBSimulatorVideoStream.make(
      framebuffer: FBFramebuffer(unbackedForTestingWithLogger: logger),
      configuration: configuration,
      logger: logger)
    let triggers = stream.makeLazyTriggers()

    XCTAssertTrue(triggers.frameRateLimiter === stream.frameRateLimiter, "The lazy push loop must read the stream's limiter")
    XCTAssertNil(stream.maximumFrameRate)
    XCTAssertNil(triggers.frameRateLimiter.minimumFrameInterval)

    stream.setMaximumFrameRate(24)
    XCTAssertEqual(stream.maximumFrameRate, 24)
    XCTAssertEqual(triggers.frameRateLimiter.minimumFrameInterval, .seconds(1.0 / 24.0))

    stream.setMaximumFrameRate(nil)
    XCTAssertNil(stream.maximumFrameRate)
    XCTAssertNil(triggers.frameRateLimiter.minimumFrameInterval)
  }

  func testFrameRateLimiterNormalizesTheCap() {
    let limiter = FrameRateLimiter()
    XCTAssertNil(limiter.maximumFramesPerSecond)
    XCTAssertNil(limiter.minimumFrameInterval)

    limiter.setMaximumFramesPerSecond(30)
    XCTAssertEqual(limiter.maximumFramesPerSecond, 30)
    XCTAssertEqual(limiter.minimumFrameInterval, .seconds(1.0 / 30.0))

    for invalid in [0, -15, Double.infinity, Double.nan] {
      limiter.setMaximumFramesPerSecond(30)
      limiter.setMaximumFramesPerSecond(invalid)
      XCTAssertNil(limiter.maximumFramesPerSecond, "\(invalid) should remove the cap")
    }
  }

  func testWriteQueueQoS() {
    XCTAssertEqual(FBSimulatorVideoStream.makeWriteQueue().qos, .unspecified, "The default matches a queue created without a QoS")
    XCTAssertEqual(FBSimulatorVideoStream.makeWriteQueue(qos: .userInitiated).qos, .userInitiated)
  }
}

/// Tests for the `.eager` cadence clock (`FrameCadence.Iterator`), driven by a fake Mach clock whose
/// sleep jumps straight to the requested deadline, so timing is exact and nothing really sleeps.
final class FBSimulatorVideoStreamFrameCadenceTests: XCTestCase {

  private final class FakeClock: @unchecked Sendable {
    var now: UInt64 = 1_000_000_000
    var sleepDeadlines: [UInt64] = []
  }

  private func makeIterator(clock: FakeClock, logger: FBControlCoreLogger = FBCapturingLogger()) -> FrameCadence.Iterator {
    FrameCadence.Iterator(
      framesPerSecond: 60,
      logger: logger,
      now: { clock.now },
      sleepUntil: { deadline in
        clock.sleepDeadlines.append(deadline)
        clock.now = deadline
      })
  }

  func testFirstTickIsImmediate() async throws {
    let clock = FakeClock()
    var iterator = makeIterator(clock: clock)

    let triggerResult = await iterator.next()

    let trigger = try XCTUnwrap(triggerResult)

    XCTAssertFalse(trigger.overran)
    XCTAssertEqual(trigger.droppedTicks, 0)
    XCTAssertTrue(clock.sleepDeadlines.isEmpty, "The first tick must not wait")
  }

  func testSteadyStateSleepsToEachAlignedDeadline() async throws {
    let clock = FakeClock()
    let start = clock.now
    var iterator = makeIterator(clock: clock)
    let interval = iterator.frameIntervalMach

    _ = await iterator.next()
    for _ in 0..<5 {
      let triggerResult = await iterator.next()
      let trigger = try XCTUnwrap(triggerResult)
      XCTAssertFalse(trigger.overran)
      XCTAssertEqual(trigger.droppedTicks, 0)
    }

    XCTAssertEqual(clock.sleepDeadlines, (1...5).map { start + UInt64($0) * interval })
  }

  func testStallDropsMissedTicksInsteadOfBursting() async throws {
    let clock = FakeClock()
    let logger = FBCapturingLogger()
    let start = clock.now
    var iterator = makeIterator(clock: clock, logger: logger)
    let interval = iterator.frameIntervalMach

    _ = await iterator.next()
    // The first push stalls until 5.5 intervals past its successor's deadline (start + interval).
    clock.now = start + interval + 5 * interval + interval / 2

    let lateResult = await iterator.next()

    let late = try XCTUnwrap(lateResult)
    XCTAssertTrue(late.overran)
    XCTAssertEqual(late.droppedTicks, 5)
    XCTAssertTrue(clock.sleepDeadlines.isEmpty, "The late tick fires immediately")

    let nextResult = await iterator.next()

    let next = try XCTUnwrap(nextResult)
    XCTAssertFalse(next.overran, "Missed ticks must not be caught up back-to-back")
    XCTAssertEqual(clock.sleepDeadlines, [start + 7 * interval], "The next tick waits for the first phase-aligned deadline after the stall")

    let overrunLogs = logger.messages.compactMap { $0 as? String }.filter { $0.hasPrefix("Frame push exceeded budget") }
    XCTAssertEqual(overrunLogs.count, 1, "One overrun line per stall, not one per missed tick")
    XCTAssertTrue(overrunLogs.first?.hasSuffix("dropped 5 ticks") ?? false, "\(overrunLogs)")
  }

  func testTickExactlyAtTheDeadlineIsOnTime() async throws {
    let clock = FakeClock()
    let logger = FBCapturingLogger()
    let start = clock.now
    var iterator = makeIterator(clock: clock, logger: logger)
    let interval = iterator.frameIntervalMach

    _ = await iterator.next()
    clock.now = start + interval

    let onTimeResult = await iterator.next()

    let onTime = try XCTUnwrap(onTimeResult)
    XCTAssertFalse(onTime.overran, "Reaching the deadline exactly is not an overrun")
    XCTAssertEqual(onTime.droppedTicks, 0)
    XCTAssertTrue(clock.sleepDeadlines.isEmpty, "Nothing to wait for at the deadline")
    XCTAssertTrue(logger.messages.compactMap { $0 as? String }.filter { $0.hasPrefix("Frame push exceeded budget") }.isEmpty)

    _ = await iterator.next()
    XCTAssertEqual(clock.sleepDeadlines, [start + 2 * interval], "The schedule advances by one interval")
  }

  func testOverrunWithinOneIntervalDropsNothing() async throws {
    let clock = FakeClock()
    let start = clock.now
    var iterator = makeIterator(clock: clock)
    let interval = iterator.frameIntervalMach

    _ = await iterator.next()
    clock.now = start + interval + interval / 2

    let lateResult = await iterator.next()

    let late = try XCTUnwrap(lateResult)
    XCTAssertTrue(late.overran)
    XCTAssertEqual(late.droppedTicks, 0)
    _ = await iterator.next()
    XCTAssertEqual(clock.sleepDeadlines, [start + 2 * interval])
  }
}

/// Tests for whole-frame MJPEG delivery to `RSEncodedFrameConsumer`.
final class FBSimulatorVideoStreamEncodedFrameConsumerTests: XCTestCase {

  private final class CapturingEncodedFrameConsumer: NSObject, RSEncodedFrameConsumer, @unchecked Sendable {
    private let lock = NSLock()
    private var _encodedFrames: [Data] = []
    private var _consumedData: [Data] = []
    var onEncodedFrame: ((Data) -> Void)?

    var encodedFrames: [Data] { lock.withLock { _encodedFrames } }
    var consumedData: [Data] { lock.withLock { _consumedData } }

    func consumeEncodedFrame(_ data: Data) {
      lock.withLock { _encodedFrames.append(data) }
      onEncodedFrame?(data)
    }

    func consumeData(_ data: Data) {
      lock.withLock { _consumedData.append(data) }
    }

    func consumeEndOfFile() {}
  }

  // MARK: - Helpers

  private let segments: [[UInt8]] = [[0xFF, 0xD8, 0x01, 0x02], [0x03, 0x04, 0xFF, 0xD9]]

  /// A block buffer backed by one memory block per segment, so it is not contiguous.
  private func makeSegmentedBlockBuffer() throws -> CMBlockBuffer {
    var blockBuffer: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateEmpty(allocator: nil, capacity: UInt32(segments.count), flags: 0, blockBufferOut: &blockBuffer), kCMBlockBufferNoErr)
    let buffer = try XCTUnwrap(blockBuffer)
    var offset = 0
    for segment in segments {
      XCTAssertEqual(
        CMBlockBufferAppendMemoryBlock(
          buffer, memoryBlock: nil, length: segment.count, blockAllocator: nil, customBlockSource: nil,
          offsetToData: 0, dataLength: segment.count, flags: kCMBlockBufferAssureMemoryNowFlag),
        kCMBlockBufferNoErr)
      segment.withUnsafeBytes { bytes in
        XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: buffer, offsetIntoDestination: offset, dataLength: segment.count), kCMBlockBufferNoErr)
      }
      offset += segment.count
    }
    XCTAssertFalse(CMBlockBufferIsRangeContiguous(buffer, atOffset: 0, length: 0), "The fixture must span multiple memory blocks")
    return buffer
  }

  private func makeJPEGSampleBuffer(dataBuffer: CMBlockBuffer) throws -> CMSampleBuffer {
    var formatDescription: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG, width: 2, height: 2, extensions: nil, formatDescriptionOut: &formatDescription), noErr)
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = CMBlockBufferGetDataLength(dataBuffer)
    XCTAssertEqual(
      CMSampleBufferCreate(
        allocator: nil, dataBuffer: dataBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
        formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer),
      noErr)
    return try XCTUnwrap(sampleBuffer)
  }

  private func makeMJPEGPusher(consumer: any FBDataConsumer, logger: FBControlCoreLogger = FBCapturingLogger()) -> FBSimulatorVideoStreamFramePusher_VideoToolbox {
    let configuration = FBVideoStreamConfiguration(format: .mjpeg, framesPerSecond: nil, rateControl: nil, scaleFactor: nil, keyFrameRate: nil)
    return FBSimulatorVideoStreamFramePusher_VideoToolbox(
      configuration: configuration,
      compressionSessionProperties: FBSimulatorVideoStream.compressionSessionProperties(for: configuration, callerProperties: [:]),
      videoCodec: kCMVideoCodecType_JPEG,
      consumer: consumer,
      outputMode: .mjpeg,
      encodedSampleConsumer: nil,
      logger: logger)
  }

  // MARK: - Tests

  func testContiguousDataCopiesEverySegment() throws {
    let data = try contiguousData(from: makeSegmentedBlockBuffer())
    XCTAssertEqual(data, Data(segments.joined()))
  }

  func testMJPEGDeliversOneWholeFrameToEncodedFrameConsumer() throws {
    let consumer = CapturingEncodedFrameConsumer()
    let pusher = makeMJPEGPusher(consumer: consumer)

    pusher.handleMJPEGSampleBuffer(try makeJPEGSampleBuffer(dataBuffer: makeSegmentedBlockBuffer()))

    XCTAssertEqual(consumer.encodedFrames, [Data(segments.joined())], "A segmented JPEG must arrive as exactly one Data")
    XCTAssertTrue(consumer.consumedData.isEmpty, "Whole-frame consumers must not also receive the piecewise bytes")
  }

  func testMJPEGWritesPiecewiseToPlainConsumer() throws {
    let consumer = FBDataBuffer.accumulatingBuffer()
    let pusher = makeMJPEGPusher(consumer: consumer)

    pusher.handleMJPEGSampleBuffer(try makeJPEGSampleBuffer(dataBuffer: makeSegmentedBlockBuffer()))

    XCTAssertEqual(consumer.data(), Data(segments.joined()), "Consumers without RSEncodedFrameConsumer keep the existing byte stream")
  }

  func testJPEGEncoderSpecificationsOmitLowLatencyRateControl() {
    let specifications = FBSimulatorVideoStreamFramePusher_VideoToolbox.encoderSpecifications(for: kCMVideoCodecType_JPEG)
    XCTAssertEqual(specifications.count, 2, "JPEG requires the hardware encoder first, then falls back without the requirement")
    XCTAssertEqual(specifications[0].specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] as? Bool, true)
    XCTAssertNil(specifications[1].specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String])
    for candidate in specifications {
      XCTAssertNil(candidate.specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String], "VideoToolbox rejects low-latency rate control for JPEG")
    }
  }

  func testH264AndHEVCEncoderSpecificationsAreUnchanged() {
    for codec in [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC] {
      let specifications = FBSimulatorVideoStreamFramePusher_VideoToolbox.encoderSpecifications(for: codec)
      XCTAssertEqual(specifications.count, 1)
      XCTAssertEqual(specifications[0].specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] as? Bool, true)
      XCTAssertEqual(specifications[0].specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] as? Bool, true)
    }
  }

  /// End-to-end through VideoToolbox: session setup, encode, and whole-frame delivery.
  func testMJPEGEncodeDeliversWholeJPEGToEncodedFrameConsumer() throws {
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixelBuffer)

    let consumer = CapturingEncodedFrameConsumer()
    let frameDelivered = expectation(description: "JPEG delivered")
    consumer.onEncodedFrame = { _ in frameDelivered.fulfill() }
    let logger = FBCapturingLogger()
    let pusher = makeMJPEGPusher(consumer: consumer, logger: logger)
    try pusher.setup(with: buffer, edgeInsets: FBVideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0))
    defer { try? pusher.tearDown() }
    XCTAssertTrue(
      logger.messages.contains { ($0 as! String).hasPrefix("Created jpeg compression session") },
      "Setup should log which encoder specification was used")

    try pusher.writeEncodedFrame(buffer, frameNumber: 0, timeAtFirstFrame: CFAbsoluteTimeGetCurrent(), frameUptime: ProcessInfo.processInfo.systemUptime, frameDuration: 0, forceKeyFrame: false)
    wait(for: [frameDelivered], timeout: 5)

    let frame = try XCTUnwrap(consumer.encodedFrames.first)
    XCTAssertEqual(consumer.encodedFrames.count, 1)
    XCTAssertEqual(Array(frame.prefix(2)), [0xFF, 0xD8], "Frame should start with the JPEG SOI marker")
    XCTAssertEqual(Array(frame.suffix(2)), [0xFF, 0xD9], "Frame should end with the JPEG EOI marker")
    XCTAssertTrue(consumer.consumedData.isEmpty)
  }

  /// JPEG decoders (JFIF, browsers, ImageIO) decode with BT.601 coefficients, so saturated colours must
  /// survive the real `.mjpeg` pipeline within JPEG quantization error.
  func testMJPEGPreservesSaturatedColours() throws {
    let colours: [(name: String, rgb: [UInt8])] = [
      ("red", [255, 0, 0]),
      ("green", [0, 255, 0]),
      ("blue", [0, 0, 255]),
      ("sky blue", [135, 206, 235]),
      ("grey", [128, 128, 128]),
    ]
    for colour in colours {
      let decoded = try encodeAndDecodeSolidFrame(rgb: colour.rgb)
      for channel in 0..<3 {
        XCTAssertLessThanOrEqual(
          abs(Int(decoded[channel]) - Int(colour.rgb[channel])), 6,
          "\(colour.name) \(colour.rgb) decoded as \(decoded)")
      }
    }
  }

  /// Encodes a solid 64x64 BGRA frame through the `.mjpeg` pusher and returns the decoded centre pixel as sRGB.
  private func encodeAndDecodeSolidFrame(rgb: [UInt8]) throws -> [UInt8] {
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixelBuffer)
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<64 {
      for x in 0..<64 {
        let pixel = base + y * bytesPerRow + x * 4
        pixel[0] = rgb[2]
        pixel[1] = rgb[1]
        pixel[2] = rgb[0]
        pixel[3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let consumer = CapturingEncodedFrameConsumer()
    let frameDelivered = expectation(description: "JPEG delivered")
    consumer.onEncodedFrame = { _ in frameDelivered.fulfill() }
    let pusher = makeMJPEGPusher(consumer: consumer)
    try pusher.setup(with: buffer, edgeInsets: FBVideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0))
    defer { try? pusher.tearDown() }
    try pusher.writeEncodedFrame(buffer, frameNumber: 0, timeAtFirstFrame: CFAbsoluteTimeGetCurrent(), frameUptime: ProcessInfo.processInfo.systemUptime, frameDuration: 0, forceKeyFrame: false)
    wait(for: [frameDelivered], timeout: 5)

    let jpeg = try XCTUnwrap(consumer.encodedFrames.first)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var decoded = [UInt8](repeating: 0, count: 4)
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    try decoded.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(
        CGContext(
          data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      let centre = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
      context.draw(centre, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return Array(decoded.prefix(3))
  }
}

/// Tests for the bitmap (BGRA) frame pusher's raw byte contract.
final class FBSimulatorVideoStreamBitmapPusherTests: XCTestCase {

  // MARK: - Helpers

  /// Creates an IOSurface-backed BGRA pixel buffer filled with a constant byte.
  private func makeBGRAPixelBuffer(width: Int, height: Int, fill: UInt8) -> CVPixelBuffer {
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
    let buffer = pixelBuffer!

    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      memset(base, Int32(fill), CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }

  // MARK: - Tests

  func testBitmapPusherWritesRawPixelBytes() throws {
    let buffer = makeBGRAPixelBuffer(width: 16, height: 8, fill: 0xAB)
    let consumer = FBDataBuffer.accumulatingBuffer()
    let pusher = FBSimulatorVideoStreamFramePusher_Bitmap(consumer: consumer, scaleFactor: nil)

    let zeroInsets = FBVideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)
    try pusher.setup(with: buffer, edgeInsets: zeroInsets)
    try pusher.writeEncodedFrame(
      buffer,
      frameNumber: 0,
      timeAtFirstFrame: 0,
      frameUptime: 0,
      frameDuration: 0,
      forceKeyFrame: false
    )

    // The bitmap pusher writes the raw pixel buffer bytes through to the consumer, unframed.
    let output = consumer.data()
    XCTAssertEqual(output.count, CVPixelBufferGetDataSize(buffer))
    XCTAssertFalse(output.isEmpty)
    XCTAssertTrue(output.allSatisfy { $0 == 0xAB }, "Raw BGRA bytes should pass through unchanged")

    try pusher.tearDown()
  }

  func testBitmapPusherWithoutScaleDoesNotResize() throws {
    let buffer = makeBGRAPixelBuffer(width: 16, height: 8, fill: 0x10)
    let consumer = FBDataBuffer.accumulatingBuffer()
    // nil scaleFactor → no pixel transfer session, raw passthrough at source dimensions.
    let pusher = FBSimulatorVideoStreamFramePusher_Bitmap(consumer: consumer, scaleFactor: nil)

    let zeroInsets = FBVideoStreamEdgeInsets(top: 0, bottom: 0, left: 0, right: 0)
    try pusher.setup(with: buffer, edgeInsets: zeroInsets)
    try pusher.writeEncodedFrame(
      buffer,
      frameNumber: 0,
      timeAtFirstFrame: 0,
      frameUptime: 0,
      frameDuration: 0,
      forceKeyFrame: false
    )

    // Output is exactly one source-sized frame.
    XCTAssertEqual(consumer.data().count, CVPixelBufferGetDataSize(buffer))

    try pusher.tearDown()
  }

  // MARK: - Frame presentation time

  func testFrameUptimeUsesTheLatestDamageSinceThePreviousFrame() {
    let frameUptime = FBSimulatorVideoStream.frameUptime(pendingPresentationUptime: 10.02, lastFrameUptime: 10.0, pushUptime: 10.3)
    XCTAssertEqual(frameUptime, 10.02)
  }

  func testFrameUptimeFallsBackToThePushWithoutDamage() {
    let frameUptime = FBSimulatorVideoStream.frameUptime(pendingPresentationUptime: nil, lastFrameUptime: 10.0, pushUptime: 10.3)
    XCTAssertEqual(frameUptime, 10.3)
  }

  func testFrameUptimeIgnoresDamageAlreadyCapturedByThePreviousFrame() {
    let frameUptime = FBSimulatorVideoStream.frameUptime(pendingPresentationUptime: 9.9, lastFrameUptime: 10.0, pushUptime: 10.3)
    XCTAssertEqual(frameUptime, 10.3)
  }

  func testFrameUptimeStrictlyIncreasesWhenThePushClockStalls() {
    let frameUptime = FBSimulatorVideoStream.frameUptime(pendingPresentationUptime: nil, lastFrameUptime: 10.0, pushUptime: 10.0)
    XCTAssertGreaterThan(frameUptime, 10.0)
  }
}
