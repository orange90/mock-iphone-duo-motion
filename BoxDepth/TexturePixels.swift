import CoreGraphics

/// Explicit sRGB RGBA8 conversion avoids depending on the CGImage's original
/// RGB24/BGRA/extended-range byte layout when creating a Metal texture.
struct TexturePixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    init(image: CGImage) throws {
        let width = image.width, height = image.height
        self.width = width; self.height = height
        let rowBytes = width * 4
        var result = [UInt8](repeating: 0, count: rowBytes * height)
        let success = result.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw PixelError.conversion }
        bytes = result
    }
    enum PixelError: Error { case conversion }
}
