//
//  SimulatorControl.swift
//  RocketSim
//
//  Created by A.J. van der Lee on 07/06/2024.
//  Copyright © 2024 SwiftLee. All rights reserved.
//

import Foundation
import FBControlCore
import FBSimulatorControl
import AppKit

public final class SimulatorControl {
    enum Error: Swift.Error {
        case invalidSimulatorUDID
    }

    private var control: FBSimulatorControl?

    public static let shared = SimulatorControl()

    private func setupIfNeeded() throws -> FBSimulatorControl {
        if let control {
            return control
        } else {
            do {
                let deviceSetPath = FBSimulatorControlConfiguration.defaultDeviceSetPath()
                let control = try FBSimulatorControl.withConfiguration(
                    FBSimulatorControlConfiguration(deviceSetPath: deviceSetPath, logger: nil, reporter: nil)
                )
                self.control = control
                return control
            } catch {
                print("Failed to setup Simulator Control: \(error)")
                throw error
            }
        }
    }

    public func simulatorControllerForDeviceUDID(_ deviceUDID: String) throws -> SimulatorControlling {
        let control = try setupIfNeeded()

        guard let simulator = control.set.simulator(withUDID: deviceUDID) else {
            throw Error.invalidSimulatorUDID
        }

        return simulator
    }
}

public protocol SimulatorControlling {
    func accessibilityElements() throws -> [AccessibilityElement]
    func sendTapEvent(x: Double, y: Double) throws
    func sendText(_ query: String) async throws
    func login(username: String, password: String) throws
    func setSlowAnimationsEnabled(_ enabled: Bool) throws
}

extension FBSimulator: SimulatorControlling {
    public func accessibilityElements() throws -> [AccessibilityElement] {
        let accessibilityElements = try accessibilityElements(withNestedFormat: true).await(withTimeout: 5.0)
        let jsonData = try JSONSerialization.data(withJSONObject: accessibilityElements, options: [.prettyPrinted, .withoutEscapingSlashes])

        let jsonString = String(decoding: jsonData, as: UTF8.self)
        print(jsonString)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let elements = try decoder.decode([AccessibilityElement].self, from: jsonData)
        return elements
    }

    public func sendTapEvent(x: Double, y: Double) throws {
        let hid = try connectToHID().await(withTimeout: 5.0)
        print("Sending touch event at x: \(x) y: \(y)")
        hid.sendTouch(withType: .down, x: x, y: y)
        hid.sendTouch(withType: .up, x: x, y: y)
    }

    public func sendText(_ query: String) async throws {
        let hid = try connectToHID().await(withTimeout: 5.0)
        print("Sending text query: \(query)")
        for character in query {
            try await hid.press(String(character))
        }
    }

    public func login(username: String, password: String) throws {
        Task.detached {
            let hid = try self.connectToHID().await(withTimeout: 5.0)
            print("Trying to login with username \(username) password \(password)")
            try await self.sendText(username)
            try await hid.press("\n")

            try await Task.sleep(nanoseconds: 2_000_000_000)

            try await self.sendText(password)
            try await hid.press("\n")
        }
    }

    public func setSlowAnimationsEnabled(_ enabled: Bool) throws {
//        print("Setting slow animations to: \(enabled.description)")
//        let currentState = try getCurrentPreference("SlowMotionAnimation", domain: "com.apple.iphonesimulator").await(withTimeout: 5.0)

//        let screenshotData = try takeScreenshot(.PNG).await(withTimeout: 5.0)
//        let image = NSImage(data: screenshotData as Data)

//        let consumer = try FileOutput.path(output.path).makeWriter()

        try! FramebufferObserver.shared.observe(self)

//        print(simulatorDefaults().dictionaryRepresentation())
//
//        try! darwinNotificationSetState(enabled ? 1 : 0, name: "com.apple.UIKit.SimulatorSlowMotionAnimationState")
    }
}

final class FramebufferObserver {
    static let shared = FramebufferObserver()

    func observe(_ simulator: FBSimulator) throws {
        let frameBuffer = try simulator.connectToFramebuffer().await(withTimeout: 5.0)
        let configuration = FBVideoStreamConfiguration(encoding: .BGRA, framesPerSecond: 120, compressionQuality: nil, scaleFactor: nil, avgBitrate: nil, keyFrameRate: nil)
        let stream = FBSimulatorVideoStream(framebuffer: frameBuffer, configuration: configuration, logger: FBControlCoreLoggerFactory.systemLoggerWriting(toStderr: true, withDebugLogging: true))
        let output = CaptureLocationFactory(prefix: "Stream", fileExtension: "mp4", simulatorName: "iPhone 15 Pro").make()
        print("Saving output to \(output)")
        let consumer = StreamDataConsumer(url: output, simulator: simulator)
        stream?.startStreaming(consumer)
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5), execute: DispatchWorkItem(block: {
            stream?.stopStreaming()
        }))
//        let frameBuffer = try simulator.connectToFramebuffer().await(withTimeout: 5.0)
//        let consumer = FramebufferConsumer()
//        frameBuffer.attach(consumer, on: .global())
//        let image = FBSimulatorImage(framebuffer: frameBuffer, logger: nil)
//        let jpegImageData = try image.jpegImageData()
//        let jpegImage = NSImage(data: jpegImageData)
//        print(jpegImage)
    }
}

final class FramebufferConsumer: NSObject, FBFramebufferConsumer {
    deinit {
        print("DEINIT")
    }

    func didReceiveDamage(_ rect: CGRect) {
        print(#function + rect.debugDescription)
    }

    func didChange(_ surface: IOSurface?) {
        print(#function + String(describing: surface?.debugDescription))
    }
}

final class StreamDataConsumer: NSObject, FBDataConsumer, RSPixelBufferConsumer {

    var videoWriter: VideoWriter?
    let url: URL
    let simulator: FBSimulator
    var sessionStartTime: CFTimeInterval?
    var lastFrameNumber: UInt = 0

    init(url: URL, simulator: FBSimulator) {
        self.url = url
        self.simulator = simulator
    }

    func writeEncodedFrame(_ pixelBuffer: CVPixelBuffer, frameNumber: UInt, timeAtFirstFrame: CFTimeInterval) throws {
        print("Writing frame \(frameNumber)")
        lastFrameNumber = frameNumber
//        print("Received timeatfirstframe: \(timeAtFirstFrame), CMTime: \(time)")
        if videoWriter == nil {
            let time = CMTime(seconds: CFAbsoluteTimeGetCurrent() - timeAtFirstFrame, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            sessionStartTime = timeAtFirstFrame
            videoWriter = VideoWriter(url: url, width: 1179, height: 2556, sessionStartTime: time, isRealTime: true, queue: .global())!
        }

        guard let sessionStartTime else { return }
        let time = CMTime(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

//        let image = nsImageFromPixelBuffer(pixelBuffer: pixelBuffer)
//        print(image)

        videoWriter?.add(sampleBuffer: pixelBuffer, presentationTime: time)
//        videoWriter?.pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: time)
    }

    func consumeData(_ data: Data) {

        print("Received data: \(data)")
        let image = NSImage(data: data)
        print("Image is \(String(describing: image))")
    }

    func consumeEndOfFile() {
        print("Stream stopped!")
        videoWriter?.finish { asset in
            let duration = asset!.duration.seconds
            let fps = Double(self.lastFrameNumber) / duration
            print("Finished recording with FPS \(fps)")
        }
    }

    func nsImageFromPixelBuffer(pixelBuffer: CVPixelBuffer) -> NSImage? {
        // Lock the base address of the pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        // Get the base address, width, and height of the pixel buffer
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Get pixel format type
        let pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // Create a color space
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Create a CGBitmapInfo value that matches the pixel buffer format
        var bitmapInfo: CGBitmapInfo = []
        if pixelFormatType == kCVPixelFormatType_32ARGB {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        } else if pixelFormatType == kCVPixelFormatType_32BGRA {
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        } else {
            return nil // Unsupported pixel format
        }

        // Create a CGContext from the pixel buffer data
        guard let context = CGContext(data: baseAddress,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue) else {
            return nil
        }

        // Create a CGImage from the CGContext
        guard let cgImage = context.makeImage() else {
            return nil
        }

        // Create an NSImage from the CGImage
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))

        return nsImage
    }
}

struct CaptureLocationFactory {
    static let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return dateFormatter
    }()

    /// The prefix to use in the filename. E.g. `RocketSim Recording`.
    let prefix: String

    /// The file extension to use for the target location.
    let fileExtension: String

    /// The `Simulator` that was used for capturing.
    let simulatorName: String

    func make() -> URL {
        let dateString = Self.dateFormatter.string(from: Date())
        let fileName = "\(prefix) \(simulatorName) \(dateString).\(fileExtension)".replacingOccurrences(of: " ", with: "_")
        let recordingsFolder = URL(fileURLWithPath: NSTemporaryDirectory())
        return recordingsFolder.appendingPathComponent(fileName)
    }
}

public enum FileOutput {
    case path(String)
    case standardOut

    func makeWriter() throws -> (FBDataConsumer) {
        switch self {
        case let .path(path):
            return try FBFileWriter.syncWriter(forFilePath: path)
        case .standardOut:
            return FBFileWriter.syncWriter(withFileDescriptor: FileHandle.standardOutput.fileDescriptor, closeOnEndOfFile: false)
        }
    }
}

public struct AccessibilityElement: Codable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case axFrame = "AXFrame"
        case axUniqueID = "AXUniqueId"
        case axLabel = "AXLabel"
        case axValue = "AXValue"
        case frame, roleDescription, contentRequired, type
        case title, help, customActions, enabled, role, children, subrole, pid
    }

    enum CGRectKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    public var id: String { axFrame }
    let axFrame: String
    let axUniqueID: String?
    let frame: CGRect
    let roleDescription: String
    let axLabel: String?
    let contentRequired: Bool
    let type: String
    let title: String?
    let help: String?
    let customActions: [String]
    let axValue: String?
    let enabled: Bool
    let role: String
    let children: [AccessibilityElement]?
    let subrole: String?
    let pid: Int

    var treeName: String {
        let name = axLabel ?? title ?? type

        switch children {
        case nil:
            return "📄 \(name)"
        case .some(let children):
            return children.isEmpty ? "📂 \(name)" : "📁 \(name)"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let frameContainer = try container.nestedContainer(keyedBy: CGRectKeys.self, forKey: .frame)
        let frameX = try frameContainer.decode(CGFloat.self, forKey: .x)
        let frameY = try frameContainer.decode(CGFloat.self, forKey: .y)
        let frameWidth = try frameContainer.decode(CGFloat.self, forKey: .width)
        let frameHeight = try frameContainer.decode(CGFloat.self, forKey: .height)
        frame = CGRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight)

        self.axFrame = try container.decode(String.self, forKey: .axFrame)
        self.axUniqueID = try container.decodeIfPresent(String.self, forKey: .axUniqueID)
        self.roleDescription = try container.decode(String.self, forKey: .roleDescription)
        self.axLabel = try container.decodeIfPresent(String.self, forKey: .axLabel)
        self.contentRequired = try container.decode(Bool.self, forKey: .contentRequired)
        self.type = try container.decode(String.self, forKey: .type)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.help = try container.decodeIfPresent(String.self, forKey: .help)
        self.customActions = try container.decode([String].self, forKey: .customActions)
        self.axValue = try container.decodeIfPresent(String.self, forKey: .axValue)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.role = try container.decode(String.self, forKey: .role)
        let children = try container.decodeIfPresent([AccessibilityElement].self, forKey: .children)
        if children?.isEmpty == false {
            self.children = children
        } else {
            self.children = nil
        }
        self.subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        self.pid = try container.decode(Int.self, forKey: .pid)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.axFrame, forKey: .axFrame)
        try container.encode(self.axUniqueID, forKey: .axUniqueID)

        var frameContainer = container.nestedContainer(keyedBy: CGRectKeys.self, forKey: .frame)
        try frameContainer.encode(frame.origin.x, forKey: .x)
        try frameContainer.encode(frame.origin.y, forKey: .y)
        try frameContainer.encode(frame.size.width, forKey: .width)
        try frameContainer.encode(frame.size.height, forKey: .height)

        try container.encode(self.roleDescription, forKey: .roleDescription)
        try container.encode(self.axLabel, forKey: .axLabel)
        try container.encode(self.contentRequired, forKey: .contentRequired)
        try container.encode(self.type, forKey: .type)
        try container.encodeIfPresent(self.title, forKey: .title)
        try container.encodeIfPresent(self.help, forKey: .help)
        try container.encode(self.customActions, forKey: .customActions)
        try container.encodeIfPresent(self.axValue, forKey: .axValue)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.role, forKey: .role)
        try container.encode(self.children, forKey: .children)
        try container.encodeIfPresent(self.subrole, forKey: .subrole)
        try container.encode(self.pid, forKey: .pid)
    }
}

let keyMap: [String: UInt32] = [
    "a": 4,
    "b": 5,
    "c": 6,
    "d": 7,
    "e": 8,
    "f": 9,
    "g": 10,
    "h": 11,
    "i": 12,
    "j": 13,
    "k": 14,
    "l": 15,
    "m": 16,
    "n": 17,
    "o": 18,
    "p": 19,
    "q": 20,
    "r": 21,
    "s": 22,
    "t": 23,
    "u": 24,
    "v": 25,
    "w": 26,
    "x": 27,
    "y": 28,
    "z": 29,
    "A": 4,
    "B": 5,
    "C": 6,
    "D": 7,
    "E": 8,
    "F": 9,
    "G": 10,
    "H": 11,
    "I": 12,
    "J": 13,
    "K": 14,
    "L": 15,
    "M": 16,
    "N": 17,
    "O": 18,
    "P": 19,
    "Q": 20,
    "R": 21,
    "S": 22,
    "T": 23,
    "U": 24,
    "V": 25,
    "W": 26,
    "X": 27,
    "Y": 28,
    "Z": 29,
    "1": 30,
    "2": 31,
    "3": 32,
    "4": 33,
    "5": 34,
    "6": 35,
    "7": 36,
    "8": 37,
    "9": 38,
    "0": 39,
    "\n": 40,
    ";": 51,
    "=": 46,
    ",": 54,
    "-": 45,
    ".": 55,
    "/": 56,
    "`": 53,
    "[": 47,
    "\\": 49,
    "]": 48,
    "'": 52,
    " ": 44,
    "!": 30,
    "@": 31,
    "#": 32,
    "$": 33,
    "%": 34,
    "^": 35,
    "&": 36,
    "*": 37,
    "(": 38,
    ")": 39,
    "_": 45,
    "+": 46,
    "{": 47,
    "}": 48,
    ":": 51,
    "\"": 52,
    "|": 49,
    "<": 54,
    ">": 55,
    "?": 56,
    "~": 53,
    "\t": 43
]

extension FBSimulatorHID {
    func press(_ key: String) async throws {
        guard let keyCode = keyMap[String(key)] else { return }

        let requiresShift = key.rangeOfCharacter(from: CharacterSet.uppercaseLetters.union(CharacterSet(charactersIn: "!@#$%^&*()_+{}|:\"<>?~"))) != nil

        if requiresShift {
            // Requires SHIFT
            try sendKeyboardEvent(with: .down, keyCode: 225).await(withTimeout: 1)
        }

        try sendKeyboardEvent(with: .down, keyCode: keyCode).await(withTimeout: 1)
        try await Task.sleep(nanoseconds: 1_000_000_00)
        try sendKeyboardEvent(with: .up, keyCode: keyCode).await(withTimeout: 1)

        if requiresShift {
            try sendKeyboardEvent(with: .up, keyCode: 225).await(withTimeout: 1)
        }
    }
}
