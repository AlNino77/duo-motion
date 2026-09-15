import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Metal
@preconcurrency import ScreenCaptureKit

/// A short-lived ScreenCaptureKit stream primed before the fold begins.
/// It keeps the newest IOSurface-backed frame and stops shortly after the
/// overlay is hidden. Callers can always fall back to one-shot capture.
public final class StreamCapture: NSObject, @unchecked Sendable {
    public static let shared = StreamCapture()

    private let lock = NSLock()
    private let outputQueue = DispatchQueue(
        label: "com.lqsky7.duomo.stream-output",
        qos: .utility
    )
    private var stream: SCStream?
    private var running = false
    private var starting = false
    private var generation: UInt64 = 0
    private var latestPixelBuffer: CVPixelBuffer?
    private var textureCache: CVMetalTextureCache?
    private var cacheDevice: MTLDevice?
    private var stopWorkItem: DispatchWorkItem?

    private override init() {
        super.init()
    }

    public func prime() {
        outputQueue.async { [weak self] in
            self?.startIfNeeded()
        }
    }

    public func noteVisible() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            self.startIfNeeded()
        }
    }

    public func noteHidden() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.stopStreamOnQueue()
            }
            self.stopWorkItem = item
            self.outputQueue.asyncAfter(deadline: .now() + 1.5, execute: item)
        }
    }

    public func restart() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            self.stopStreamOnQueue()
        }
    }

    private func startIfNeeded() {
        guard !running, !starting, ScreenCapture.shared.hasPermission() else { return }
        starting = true
        lock.lock()
        generation &+= 1
        let startGeneration = generation
        lock.unlock()

        let queue = outputQueue
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let newStream = await self.makeStream()
            queue.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let isCurrent = self.generation == startGeneration
                self.lock.unlock()

                guard isCurrent else {
                    if let newStream {
                        Task.detached(priority: .utility) {
                            try? newStream.removeStreamOutput(self, type: .screen)
                            try? await newStream.stopCapture()
                        }
                    }
                    return
                }

                self.starting = false
                guard let newStream else {
                    self.running = false
                    return
                }
                self.lock.lock()
                self.stream = newStream
                self.running = true
                self.lock.unlock()
            }
        }
    }

    private func makeStream() async -> SCStream? {
        do {
            let content: SCShareableContent
            if #available(macOS 14.4, *) {
                content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            } else {
                content = try await SCShareableContent.current
            }
            guard let display = ScreenCapture.preferredDisplay(from: content) else { return nil }

            let processID = NSRunningApplication.current.processIdentifier
            let excludedWindows = content.windows.filter {
                $0.owningApplication?.processID == processID
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let scale = await MainActor.run {
                DisplayTopology.builtInBackingScale()
            }

            let configuration = SCStreamConfiguration()
            configuration.width = max(2, Int(Double(display.width) * scale))
            configuration.height = max(2, Int(Double(display.height) * scale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            return stream
        } catch {
            return nil
        }
    }

    private func stopStreamOnQueue() {
        lock.lock()
        let oldStream = stream
        generation &+= 1
        stream = nil
        running = false
        starting = false
        latestPixelBuffer = nil
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        lock.unlock()

        guard let oldStream else { return }
        Task.detached(priority: .utility) {
            try? oldStream.removeStreamOutput(self, type: .screen)
            try? await oldStream.stopCapture()
        }
    }

    /// Returns a zero-copy Metal mapping of the newest complete stream frame.
    /// The keeper must stay alive until the GPU has copied the mapped texture.
    public func takeLatestTexture(
        device: MTLDevice
    ) -> (texture: MTLTexture, width: Int, height: Int, keeper: CVMetalTexture)? {
        lock.lock()
        defer { lock.unlock() }
        guard let pixelBuffer = latestPixelBuffer else { return nil }

        if cacheDevice !== device || textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
            cacheDevice = device
        }
        guard let textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var mappedTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &mappedTexture
        )
        guard result == kCVReturnSuccess,
              let mappedTexture,
              let texture = CVMetalTextureGetTexture(mappedTexture) else { return nil }
        return (texture, width, height, mappedTexture)
    }
}

extension StreamCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferDataIsReady(sampleBuffer),
              Self.frameIsComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    private static func frameIsComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let rawStatus = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }
        return status == .complete
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard let current = self.stream, current === stream else {
                self.lock.unlock()
                return
            }
            self.stream = nil
            self.running = false
            self.latestPixelBuffer = nil
            self.lock.unlock()
        }
    }
}
