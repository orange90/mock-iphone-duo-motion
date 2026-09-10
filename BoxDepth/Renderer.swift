import SwiftUI
import MetalKit
import CoreImage
import simd

// All fields are 16-byte aligned; keep in sync with Uniforms in BoxShader.txt.
struct Uniforms {
    var rotation: simd_float4x4
    var eye: SIMD4<Float>
    var parameters: SIMD4<Float> // aspect, depth, photo aspect, fit
    var viewport: SIMD4<Float> // width, height, actual facing, optical mode
}

@MainActor final class BoxRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let device: MTLDevice
    private var texture: MTLTexture?
    private var blurredTexture: MTLTexture?
    private var slightTexture: MTLTexture?
    private var heavyTexture: MTLTexture?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var revision = -1
    let model: AppModel
    private var frames = 0
    private var lastReport = CACurrentMediaTime()

    init(view: MTKView, model: AppModel) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable
        }
        // Compile the tiny bundled shader once at launch. This avoids a separate
        // downloadable Metal build toolchain on fresh Xcode installations.
        guard let sourceURL = Bundle.main.url(forResource: "BoxShader", withExtension: "txt") else { throw RenderError.unavailable }
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: String(contentsOf: sourceURL, encoding: .utf8), options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "boxFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        commandQueue = queue; self.device = device; self.model = model
        super.init()
        try updateTexture()
    }

    private func makeTexture(_ cg: CGImage) throws -> MTLTexture {
        let pixels = try TexturePixels(image: cg)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
            width: pixels.width, height: pixels.height, mipmapped: true)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let result = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable }
        pixels.bytes.withUnsafeBytes { bytes in
            result.replace(region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                           withBytes: bytes.baseAddress!, bytesPerRow: pixels.width * 4)
        }
        guard let upload = commandQueue.makeCommandBuffer(), let blit = upload.makeBlitCommandEncoder() else { throw RenderError.unavailable }
        blit.generateMipmaps(for: result); blit.endEncoding(); upload.commit()
        return result
    }

    func updateTexture() throws {
        guard revision != model.imageRevision, let cg = model.image.cgImage else { return }
        let loaded = try makeTexture(cg)
        // Gaussian blur only runs when the photo changes, never each frame.
        let scale = min(1, 512.0 / Double(max(cg.width, cg.height)))
        let input = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = input.extent.integral
        func blur(_ radius: Double) throws -> MTLTexture {
            let softened = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let cg = imageContext.createCGImage(softened, from: extent, format: .RGBA8, colorSpace: srgb) else { throw RenderError.unavailable }
            return try makeTexture(cg)
        }
        let slight = try blur(2.0), soft = try blur(8.0), heavy = try blur(20.0)
        texture = loaded; slightTexture = slight; blurredTexture = soft; heavyTexture = heavy
        revision = model.imageRevision
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        if revision != model.imageRevision {
            do { try updateTexture() }
            catch { revision = model.imageRevision; model.error = "图片无法上传到 GPU，暂时保留原画面。" }
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass),
              let texture, let blurredTexture, let slightTexture, let heavyTexture else { return }
        let raw = model.motion.snapshot().rotation
        let q = raw
        let eye = SpatialMath.eye(overhead: false)
        var uniforms = Uniforms(rotation: simd_float4x4(q), eye: SIMD4(eye, 1),
            parameters: SIMD4(Float(view.drawableSize.width / view.drawableSize.height), model.preferences.depth,
                              Float(texture.width) / Float(texture.height), model.preferences.fit ? 1 : 0),
            viewport: SIMD4(Float(view.drawableSize.width), Float(view.drawableSize.height), SpatialMath.facing(rotation: raw, eye: eye), 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(blurredTexture, index: 1)
        encoder.setFragmentTexture(slightTexture, index: 2)
        encoder.setFragmentTexture(heavyTexture, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); buffer.present(drawable); buffer.commit()
        frames += 1
        let now = CACurrentMediaTime()
        if now - lastReport >= 10 {
            #if DEBUG
            print(String(format: "BoxDepth: %.1f rendered fps, thermal=%ld", Double(frames)/(now-lastReport), ProcessInfo.processInfo.thermalState.rawValue))
            #endif
            frames = 0; lastReport = now
        }
    }

    enum RenderError: LocalizedError {
        case unavailable
        var errorDescription: String? { "此设备无法初始化 Metal 渲染。" }
    }
}

struct MetalCanvas: UIViewRepresentable {
    @ObservedObject var model: AppModel
    var active: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.12, green: 0.13, blue: 0.12, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.isOpaque = true
        do {
            let renderer = try BoxRenderer(view: view, model: model)
            context.coordinator.renderer = renderer; view.delegate = renderer
        } catch {
            DispatchQueue.main.async { model.error = error.localizedDescription }
        }
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) { view.isPaused = !active }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) { view.isPaused = true; view.delegate = nil }
    final class Coordinator { var renderer: BoxRenderer? }
}
