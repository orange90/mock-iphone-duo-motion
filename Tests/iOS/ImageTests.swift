import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import MetalKit
import simd
@testable import BoxDepth

final class ImageTests: XCTestCase {
    private func fixture(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { r in
            UIColor.red.setFill(); r.fill(CGRect(x:0,y:0,width:width,height:height))
            UIColor.blue.setFill(); r.fill(CGRect(x:width/2,y:0,width:width/2,height:height))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(image.cgImage),[kCGImagePropertyOrientation:orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testLargeLandscapeDownsamples() throws {
        let image = try AppModel.decode(fixture(width:6000,height:4000))
        XCTAssertEqual(image.imageOrientation,.up)
        XCTAssertEqual(image.size.width,2048)
        XCTAssertEqual(image.size.height/image.size.width,2.0/3.0,accuracy:0.001)
    }
    func testExifOrientationNormalizesPortrait() throws {
        let image = try AppModel.decode(fixture(width:4000,height:2000,orientation:6))
        XCTAssertEqual(image.imageOrientation,.up)
        XCTAssertEqual(image.size.height,2048)
        XCTAssertEqual(image.size.width,1024)
    }
    func testSmallImageIsNotUpscaled() throws {
        let image = try AppModel.decode(fixture(width:120,height:80))
        XCTAssertEqual(image.size,CGSize(width:120,height:80))
    }
    func testCorruptDataFails() {
        XCTAssertThrowsError(try AppModel.decode(Data([1,2,3,4])))
    }
    func testTextureHasExplicitRGBAAndCorrectRows() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { r in
            UIColor.red.setFill(); r.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
            UIColor.blue.setFill(); r.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        }
        let pixels = try TexturePixels(image: XCTUnwrap(image.cgImage))
        XCTAssertEqual(Array(pixels.bytes[0..<4]), [255, 0, 0, 255])
        XCTAssertEqual(Array(pixels.bytes[48..<52]), [0, 0, 255, 255])
    }
    func testJPEGTextureKeepsRedAndBlueChannels() throws {
        let decoded = try AppModel.decode(fixture(width: 40, height: 20))
        let pixels = try TexturePixels(image: XCTUnwrap(decoded.cgImage))
        XCTAssertGreaterThan(pixels.bytes[0], 240)
        XCTAssertLessThan(pixels.bytes[2], 15)
        let right = (10 * 40 + 35) * 4
        XCTAssertLessThan(pixels.bytes[right], 15)
        XCTAssertGreaterThan(pixels.bytes[right+2], 240)
    }
    func testExistingPreferencesKeepImageOptionsAfterModeRemoval() throws {
        let old = Data("{\"depth\":0.08,\"overhead\":true,\"optical\":false,\"fit\":true}".utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertTrue(decoded.fit)
        XCTAssertEqual(decoded.depth, 0.08)
    }
    @MainActor func testGlassShaderAndBlurTexturesInitialize() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 200, height: 400), device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        let model = AppModel()
        let renderer = try BoxRenderer(view: view, model: model)
        XCTAssertNotNil(renderer)
    }
    @MainActor func testOpticalGPUFlipIsFiniteAndReturnsToSameImage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let source = try String(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "BoxShader", withExtension: "txt")), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "fullScreenVertex")
        pd.fragmentFunction = library.makeFunction(name: "boxFragment")
        pd.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pd)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 16, height: 32, mipmapped: false)
        td.storageMode = .shared; td.usage = [.renderTarget, .shaderRead]
        let target = try XCTUnwrap(device.makeTexture(descriptor: td))
        let photo = try XCTUnwrap(device.makeTexture(descriptor: td))
        var pixels = [Float](repeating: 0, count: 16*32*4)
        for i in 0..<16*32 { pixels[i*4] = 0.4; pixels[i*4+1] = 0.6; pixels[i*4+2] = 0.8; pixels[i*4+3] = 1 }
        pixels.withUnsafeBytes { photo.replace(region: MTLRegionMake2D(0,0,16,32), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16*16) }
        func render(_ rotation: simd_quatf, textures: [MTLTexture]) throws -> [Float] {
            var u = Uniforms(rotation: simd_float4x4(rotation), eye: SIMD4(0,-1,3,1), parameters: SIMD4(0.5,0.06,0.5,0), viewport: SIMD4(16,32,1,1))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            for index in 0..<4 { encoder.setFragmentTexture(textures[index], index: index) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding(); buffer.commit(); buffer.waitUntilCompleted()
            XCTAssertEqual(buffer.status, .completed)
            pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16*16, from: MTLRegionMake2D(0,0,16,32), mipmapLevel: 0) }
            return pixels
        }
        var baseline: [Float] = []
        for degrees: Float in [0, 45, -45, 89, 90, 91, 180, 270, 360] {
            let rotation = simd_quatf(angle: degrees * .pi / 180, axis: SIMD3<Float>(0,1,0))
            let result = try render(rotation, textures: Array(repeating: photo, count: 4))
            XCTAssertTrue(result.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "angle \(degrees)")
            if degrees == 0 { baseline = result; XCTAssertGreaterThan(result[2], 0.7) }
            if degrees == 180 { XCTAssertLessThan(result[2], 0.06) }
            if degrees == 360 { for (a,b) in zip(result,baseline) { XCTAssertEqual(a,b,accuracy:0.00001) } }
        }
        // Identical textures remove blur as a variable: darkening must itself
        // depend on both position and angle, including on a uniform image.
        var previousRaised: Float = 1
        for degrees: Float in [0, 20, 45, 65, 75] {
            let q = simd_quatf(angle: degrees * .pi/180, axis: SIMD3<Float>(1,0,0))
            let result = try render(q, textures: Array(repeating: photo, count: 4))
            let raised: Float = result[162] // blue at x=8,y=2
            let hinge: Float = result[1890] // blue at x=8,y=29
            XCTAssertLessThanOrEqual(raised, previousRaised + 0.002, "Lifted side must darken monotonically")
            previousRaised = raised
            if degrees == 20 { XCTAssertGreaterThan(raised, 0.69, "Small angles should not acquire a heavy dark mask") }
            if degrees == 45 {
                func displayValue(_ linear: Float) -> Float {
                    linear <= 0.0031308 ? 12.92*linear : 1.055*pow(linear,1/2.4)-0.055
                }
                XCTAssertLessThan(displayValue(raised), displayValue(hinge)*0.5,
                                  "45-degree lifted side needs a visibly dark shadow after sRGB encoding")
                XCTAssertGreaterThan(hinge,0.70,"45-degree hinge must retain its brightness")
            }
            if degrees >= 65 {
                XCTAssertLessThan(raised, hinge*0.30, "Large-angle lifted side must be much darker than hinge")
                XCTAssertGreaterThan(hinge, 0.65, "Hinge must remain transmissive")
            }
        }
        for axis in [SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0), simd_normalize(SIMD3<Float>(1,1,0))] {
            var previous = try render(simd_quatf(angle: 0, axis: axis), textures: Array(repeating: photo, count: 4))
            for degree in 1...90 {
                let result = try render(simd_quatf(angle: Float(degree) * .pi/180, axis: axis), textures: Array(repeating: photo, count: 4))
                XCTAssertTrue(result.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                let largestStep = zip(result, previous).map { pair in abs(pair.0-pair.1) }.max() ?? 0
                XCTAssertLessThan(largestStep, 0.24, "No angle threshold may cause a jump at \(degree) degrees")
                previous = result
            }
        }
        let tinyPositive = try render(simd_quatf(angle: 0.001, axis: SIMD3(1,0,0)), textures: Array(repeating: photo, count: 4))
        let tinyNegative = try render(simd_quatf(angle: -0.001, axis: SIMD3(1,0,0)), textures: Array(repeating: photo, count: 4))
        XCTAssertLessThan(zip(tinyPositive,tinyNegative).map { pair in abs(pair.0-pair.1) }.max() ?? 1, 0.001)
        // Encode blur levels as luminance, so this tests the actual GPU's
        // spatial selection independently of image details or Gaussian kernels.
        let levels: [Float] = [1, 0.33, 0.66, 0] // sharp, medium, slight, heavy
        let textures = try levels.map { level -> MTLTexture in
            let t = try XCTUnwrap(device.makeTexture(descriptor: td))
            var bytes = [Float](repeating: level, count: 16*32*4)
            for i in 0..<16*32 { bytes[i*4+3] = 1 }
            bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0,0,16,32), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16*16) }
            return t
        }
        // Cancel absorption and cover reflection using uniform white/black
        // passes. The normalized value isolates the selected blur level.
        func scatteringOnly(_ rotation: simd_quatf) throws -> [Float] {
            let encoded = try render(rotation, textures: textures)
            let white = try render(rotation, textures: Array(repeating: textures[0], count: 4))
            let black = try render(rotation, textures: Array(repeating: textures[3], count: 4))
            var normalized = encoded
            for index in encoded.indices {
                normalized[index] = (encoded[index]-black[index])/max(0.0001,white[index]-black[index])
            }
            return normalized
        }
        for sign: Float in [-1,1] {
            let pitch = try scatteringOnly(simd_quatf(angle: sign * .pi/4, axis: SIMD3(1,0,0)))
            let top = pitch[(2*16+8)*4], bottom = pitch[(29*16+8)*4]
            XCTAssertGreaterThan((bottom-top)*sign, 0.25, "Raised top/bottom must select stronger diffusion")
            let yaw = try scatteringOnly(simd_quatf(angle: sign * .pi/4, axis: SIMD3(0,1,0)))
            let left = yaw[(16*16+1)*4], right = yaw[(16*16+14)*4]
            XCTAssertGreaterThan((right-left)*sign, 0.25, "Raised left/right must select stronger diffusion")
        }
    }

    private func calibrationSamples(rate: Double = 0.18, gravity: Double = 0,
                                    turning: Bool = false, frequency: Double = 100) -> [CalibrationSample] {
        (0...Int(0.4*frequency)).map { i in
            let t = Double(i)/frequency
            let angle = turning ? t*0.8 : sin(t*30)*0.008
            let q = simd_quatf(angle: Float(angle), axis: SIMD3<Float>(1,0,0))
            return CalibrationSample(rotation: i.isMultiple(of: 2) ? q : simd_quatf(vector: -q.vector),
                timestamp: 10+t, rotationRate: rate, acceleration: 0.025, gravityZ: gravity)
        }
    }
    func testCalibrationAcceptsHandheldTremorAtDifferentSampleRates() throws {
        for hz: Double in [30,60,100] {
            let samples = calibrationSamples(frequency: hz)
            let q = try XCTUnwrap(CalibrationWindow.reference(from: samples, now: 10.4, requireFlat: false))
            XCTAssertGreaterThan(abs(q.real), 0.999)
        }
    }
    func testCalibrationDoesNotResetOnSingleModerateNoiseSample() {
        var samples = calibrationSamples()
        samples[25] = CalibrationSample(rotation: samples[25].rotation, timestamp: samples[25].timestamp,
            rotationRate: 0.9, acceleration: 0.3, gravityZ: 0)
        XCTAssertNotNil(CalibrationWindow.reference(from: samples, now: 10.4, requireFlat: false))
    }
    func testCalibrationRejectsTurningAndStrongMovement() {
        XCTAssertNil(CalibrationWindow.reference(from: calibrationSamples(rate: 0.8, turning: true), now: 10.4, requireFlat: false))
        XCTAssertNil(CalibrationWindow.reference(from: calibrationSamples(rate: 1.4), now: 10.4, requireFlat: false))
    }
    func testCalibrationRejectsStaleAndShortHistory() {
        let samples = calibrationSamples()
        XCTAssertNil(CalibrationWindow.reference(from: samples, now: 11, requireFlat: false))
        XCTAssertNil(CalibrationWindow.reference(from: Array(samples.suffix(12)), now: 10.4, requireFlat: false))
    }
    func testCalibrationFlatConstraintOnlyAppliesToStrictMode() {
        XCTAssertNil(CalibrationWindow.reference(from: calibrationSamples(), now: 10.4, requireFlat: true))
        XCTAssertNotNil(CalibrationWindow.reference(from: calibrationSamples(gravity: -1), now: 10.4, requireFlat: true))
        XCTAssertNotNil(CalibrationWindow.reference(from: calibrationSamples(), now: 10.4, requireFlat: false))
    }

    @MainActor func testStoppingCancelsPendingCalibrationAndPreventsDuplicateRequests() async throws {
        let motion = MotionController()
        XCTAssertTrue(motion.calibrate())
        XCTAssertTrue(motion.isCalibrating)
        XCTAssertFalse(motion.calibrate())
        motion.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(motion.isCalibrating)
        XCTAssertFalse(motion.calibrated)
        XCTAssertTrue(motion.message.contains("返回"))
    }

    @MainActor func testUniformsMatchMetalLayout() {
        XCTAssertEqual(MemoryLayout<Uniforms>.stride,112)
        XCTAssertEqual(MemoryLayout<Uniforms>.alignment,16)
    }
}
