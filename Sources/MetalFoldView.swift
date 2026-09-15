import Foundation
import Metal
import MetalKit
import AppKit

public struct Uniforms {
    public var imageSize: SIMD2<Float>
    public var cover: SIMD2<Float>
    public var aspect: Float
    public var turn: Float
    public var closureProgress: Float
    public var motionDirection: Float
    public var blurStrength: Float
    public var reflectionIntensity: Float
    
    public init(imageSize: SIMD2<Float> = .init(1, 1),
                cover: SIMD2<Float> = .init(1, 1),
                aspect: Float = 1.0,
                turn: Float = 0.0,
                closureProgress: Float = 0.0,
                motionDirection: Float = 0.0,
                blurStrength: Float = 1.0,
                reflectionIntensity: Float = 1.0) {
        self.imageSize = imageSize
        self.cover = cover
        self.aspect = aspect
        self.turn = turn
        self.closureProgress = closureProgress
        self.motionDirection = motionDirection
        self.blurStrength = blurStrength
        self.reflectionIntensity = reflectionIntensity
    }
}

public final class MetalFoldView: MTKView, MTKViewDelegate {
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private let textureUploadQueue = DispatchQueue(label: "com.lqsky7.duomo.texture-upload", qos: .userInitiated)
    private let textureStateLock = NSLock()
    
    private var currentTexture: MTLTexture?
    private var imageSize: SIMD2<Float> = .init(1920, 1080)
    private var textureGeneration: UInt64 = 0
    
    public var currentTurn: Float = 0.0
    public var closureProgress: Float = 0.0
    public var motionDirection: Float = 0.0
    public var blurStrength: Float = 0.5
    public var reflectionIntensity: Float = 0.0
    
    public init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }
        super.init(frame: frame, device: device)
        commonInit()
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
        if self.device == nil {
            self.device = MTLCreateSystemDefaultDevice()
        }
        commonInit()
    }
    
    private func commonInit() {
        guard let dev = self.device else { return }
        
        self.commandQueue = dev.makeCommandQueue()
        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0.003, green: 0.004, blue: 0.005, alpha: 1.0)
        self.framebufferOnly = true
        self.enableSetNeedsDisplay = false
        // Lid input is sampled at 60 Hz. Rendering the same state twice at 120 Hz
        // only doubles the fullscreen fragment workload without adding motion data.
        self.preferredFramesPerSecond = 60
        self.isPaused = false
        
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        self.samplerState = dev.makeSamplerState(descriptor: samplerDesc)
        
        buildPipeline()
    }
    
    private func buildPipeline() {
        guard let dev = self.device else { return }
        
        var library: MTLLibrary?
        
        let bundle = Bundle(for: Self.self)
        if let libUrl = bundle.url(forResource: "default", withExtension: "metallib") ?? Bundle.main.url(forResource: "default", withExtension: "metallib") {
            library = try? dev.makeLibrary(URL: libUrl)
        }
        
        if library == nil {
            library = dev.makeDefaultLibrary()
        }
        
        if library == nil {
            let possiblePaths = [
                Bundle.main.bundlePath + "/Contents/Resources/FoldShaders.metal",
                Bundle.main.bundlePath + "/FoldShaders.metal"
            ]
            for p in possiblePaths {
                if let source = try? String(contentsOfFile: p, encoding: .utf8) {
                    library = try? dev.makeLibrary(source: source, options: nil)
                    if library != nil { break }
                }
            }
        }
        
        guard let lib = library else {
            print("[MetalFoldView] Failed to find or compile Metal library.")
            return
        }
        
        let vertexFunc = lib.makeFunction(name: "foldVertex")
        let fragmentFunc = lib.makeFunction(name: "foldFragment")
        
        let pipeDesc = MTLRenderPipelineDescriptor()
        pipeDesc.vertexFunction = vertexFunc
        pipeDesc.fragmentFunction = fragmentFunc
        pipeDesc.colorAttachments[0].pixelFormat = self.colorPixelFormat
        
        self.pipelineState = try? dev.makeRenderPipelineState(descriptor: pipeDesc)
    }
    
    public func updateImage(_ cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0,
              height > 0,
              let dev = self.device,
              let cq = self.commandQueue else { return }

        textureStateLock.lock()
        textureGeneration &+= 1
        let generation = textureGeneration
        textureStateLock.unlock()

        // A Retina screenshot is tens of megabytes. Convert and upload it away
        // from the main run loop so lid polling and window presentation do not
        // stall exactly as the fold begins.
        textureUploadQueue.async { [weak self] in
            guard let self else { return }

            // The shader samples LOD 0...5. Building the rest of a full Retina
            // mip chain burns memory and bandwidth without changing a pixel.
            let fullMipCount = max(1, Int(floor(log2(Double(max(width, height))))) + 1)
            let levels = min(6, fullMipCount)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: true
            )
            desc.mipmapLevelCount = levels
            desc.usage = [.shaderRead]
            desc.storageMode = .private

            let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            stagingDesc.usage = [.shaderRead]
            stagingDesc.storageMode = .shared

            guard let texture = dev.makeTexture(descriptor: desc),
                  let staging = dev.makeTexture(descriptor: stagingDesc) else { return }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerRow = width * 4
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { return }
            staging.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: data,
                bytesPerRow: bytesPerRow
            )

            guard let cb = cq.makeCommandBuffer(),
                  let blit = cb.makeBlitCommandEncoder() else { return }
            blit.copy(
                from: staging,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cb.addCompletedHandler { [weak self] buffer in
                guard buffer.status == .completed, let self else { return }
                self.textureStateLock.lock()
                if self.textureGeneration == generation {
                    self.currentTexture = texture
                    self.imageSize = SIMD2<Float>(Float(width), Float(height))
                }
                self.textureStateLock.unlock()
            }
            cb.commit()
        }
    }
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    public func draw(in view: MTKView) {
        textureStateLock.lock()
        let texture = currentTexture
        let textureImageSize = imageSize
        textureStateLock.unlock()

        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let pipeline = self.pipelineState,
              let texture,
              let cq = self.commandQueue,
              let cb = cq.makeCommandBuffer(),
              let encoder = cb.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }
        
        let viewSize = view.drawableSize
        let aspect = Float(viewSize.width / max(1.0, viewSize.height))
        let imgAspect = textureImageSize.x / max(1.0, textureImageSize.y)
        
        let cover = SIMD2<Float>(
            min(1.0, aspect / imgAspect),
            min(1.0, imgAspect / aspect)
        )
        
        var uniforms = Uniforms(
            imageSize: textureImageSize,
            cover: cover,
            aspect: aspect,
            turn: currentTurn,
            closureProgress: closureProgress,
            motionDirection: motionDirection,
            blurStrength: blurStrength,
            reflectionIntensity: reflectionIntensity
        )
        
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        
        cb.present(drawable)
        cb.commit()
    }
}
