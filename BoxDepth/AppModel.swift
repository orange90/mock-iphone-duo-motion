import SwiftUI
import PhotosUI
import ImageIO

struct Preferences: Codable, Equatable {
    var depth: Float = 0.06
    var fit = false
    init() {}
    private enum CodingKeys: String, CodingKey { case depth, fit }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        depth = try c.decodeIfPresent(Float.self, forKey: .depth) ?? 0.06
        fit = try c.decodeIfPresent(Bool.self, forKey: .fit) ?? false
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet { if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "preferences.v1") } }
    }
    @Published private(set) var image: UIImage
    @Published private(set) var imageRevision = 0
    @Published private(set) var importing = false
    @Published var error: String?
    let motion = MotionController()
    private var importID = UUID()
    private let imageURL: URL

    init() {
        var saved = UserDefaults.standard.data(forKey: "preferences.v1")
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        saved.depth = saved.depth.isFinite ? min(0.2, max(0.02, saved.depth)) : 0.08
        preferences = saved
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        imageURL = root.appendingPathComponent("selected-photo.jpg")
        image = UIImage(contentsOfFile: imageURL.path) ?? Self.testImage()
    }

    func importPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        let id = UUID(); importID = id; importing = true
        defer { if importID == id { importing = false } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ImageError.unreadable }
            let decoded = try await Task.detached(priority: .userInitiated) {
                try Self.decode(data)
            }.value
            guard id == importID else { return }
            guard let jpeg = decoded.jpegData(compressionQuality: 0.94) else { throw ImageError.unreadable }
            try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jpeg.write(to: imageURL, options: .atomic)
            image = decoded; imageRevision += 1
        } catch {
            if id == importID { self.error = "图片读取或保存失败，已保留原图。\n\(error.localizedDescription)" }
        }
    }

    nonisolated static func decode(_ data: Data) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageError.unreadable }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    func resetDefaults() { preferences = Preferences() }
    func useTestImage() {
        do {
            if FileManager.default.fileExists(atPath: imageURL.path) { try FileManager.default.removeItem(at: imageURL) }
            importID = UUID(); importing = false
            image = Self.testImage(); imageRevision += 1
        } catch { self.error = "无法恢复测试图：\(error.localizedDescription)" }
    }

    enum ImageError: LocalizedError {
        case unreadable
        var errorDescription: String? { "无法解码这张图片。" }
    }

    /// Local generated artwork; no external assets or network requests.
    static func testImage() -> UIImage {
        let size = CGSize(width: 800, height: 1600)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let ctx = renderer.cgContext
            let colors = [UIColor(red: 0.43, green: 0.64, blue: 0.79, alpha: 1).cgColor,
                          UIColor(red: 0.76, green: 0.84, blue: 0.84, alpha: 1).cgColor,
                          UIColor(red: 0.95, green: 0.79, blue: 0.76, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,0.6,1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 100, y: 1600), options: [])
            ctx.setStrokeColor(UIColor(white: 1, alpha: 0.13).cgColor); ctx.setLineWidth(1)
            for x in stride(from: 0, through: 800, by: 80) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: 1600)) }
            for y in stride(from: 0, through: 1600, by: 80) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: 800, y: y)) }
            ctx.strokePath()
            let ink = UIColor(red: 0.19, green: 0.24, blue: 0.22, alpha: 1)
            func label(_ s: String, _ rect: CGRect, _ font: UIFont) {
                let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
                (s as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
            }
            label("↑  TOP", CGRect(x: 0, y: 90, width: 800, height: 65), .monospacedSystemFont(ofSize: 30, weight: .medium))
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: 230, y: 430, width: 340, height: 340))
            ctx.strokeEllipse(in: CGRect(x: 270, y: 470, width: 260, height: 260))
            UIColor(red: 0.83, green: 0.39, blue: 0.23, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: 355, y: 555, width: 90, height: 90))
            label("mock iphone duo\nmotion", CGRect(x: 0, y: 825, width: 800, height: 155), .systemFont(ofSize: 58, weight: .light))
            label("OPTICAL MOTION", CGRect(x: 0, y: 990, width: 800, height: 60), .monospacedSystemFont(ofSize: 23, weight: .regular))
            label("L                         R", CGRect(x: 0, y: 1170, width: 800, height: 60), .monospacedSystemFont(ofSize: 26, weight: .medium))
            label("BOTTOM", CGRect(x: 0, y: 1430, width: 800, height: 60), .systemFont(ofSize: 26, weight: .regular))
        }
    }
}
