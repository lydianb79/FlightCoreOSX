import Foundation
import simd
import CoreGraphics
import ImageIO

/// Optional sidecar file "<image name>.json" next to a panorama.
struct PanoMeta: Codable {
    var name: String?
    var north: Float?        // degrees the photo is rotated about the vertical axis
    var horizon: Float?      // degrees the photo's horizon sits above the image centre line
    var eyeHeight: Float?    // camera height above the ground when the photo was taken (m)
    var windFrom: Float?
    var windSpeed: Float?
}

/// Photo sites: a 360° equirectangular photograph is the whole scenery. The aircraft flies
/// over an invisible flat ground plane that only receives its shadow.
enum Panoramas {
    static let extensions = ["jpg", "jpeg", "png", "heic", "tif", "tiff"]

    static var userDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FlightCore/Panoramas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func site(for url: URL) -> SiteSpec {
        let pretty = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        var s = SiteSpec(name: pretty.capitalized, style: 0, seed: 1, runwayLen: 100, runwayWid: 0, runwayType: 3, flatCenterZ: 0, flatHalfZ: 100,
                         treeCount: 0, windFrom: 90, windSpeed: 1, turbulence: 0.2, rollMu: 0.05, cloud: 0, fog: 0)
        s.panorama = url
        s.startZ = -14
        if let d = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")),
           let m = try? JSONDecoder().decode(PanoMeta.self, from: d) {
            if let n = m.name { s.name = n }
            s.north = m.north ?? 0; s.horizon = m.horizon ?? 0; s.eyeHeight = m.eyeHeight ?? 1.7
            s.windFrom = m.windFrom ?? s.windFrom; s.windSpeed = m.windSpeed ?? s.windSpeed
        }
        s.name = "📷 " + s.name
        return s
    }

    static func discover() -> [SiteSpec] {
        var dirs = [userDir, URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Panoramas")]
        dirs.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Panoramas"))
        var seen = Set<String>(), out: [SiteSpec] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where extensions.contains(f.pathExtension.lowercased()) {
                if seen.insert(f.standardizedFileURL.path).inserted { out.append(site(for: f)) }
            }
        }
        return out
    }

    static func save(_ s: SiteSpec) {
        guard let url = s.panorama else { return }
        let name = s.name.hasPrefix("📷 ") ? String(s.name.dropFirst(2)) : s.name
        let m = PanoMeta(name: name, north: s.north, horizon: s.horizon, eyeHeight: s.eyeHeight, windFrom: s.windFrom, windSpeed: s.windSpeed)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(m) { try? d.write(to: url.deletingPathExtension().appendingPathExtension("json")) }
    }

    static func image(_ url: URL, maxSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSize]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Estimate sun direction and ambient light from the photo so the model is lit to match
    /// and its ground shadow falls the right way.
    static func analyze(_ s: SiteSpec) -> Lighting {
        var light = Lighting(sunDir: normalize(V3(-0.35, 0.8, 0.5)), sun: V3(1, 0.97, 0.9) * 2.6, ambient: V3(0.4, 0.45, 0.55) * 0.7,
                             zenith: V3(0.3, 0.4, 0.6), horizon: V3(0.6, 0.65, 0.7))
        guard let url = s.panorama, let img = image(url, maxSize: 512) else { return light }
        let W = 64, H = 32
        var px = [UInt8](repeating: 0, count: W * H * 4)
        guard let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return light }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        var sum = V3.zero, best: Float = -1, bx = 0, by = 0, lumSum: Float = 0
        for y in 0..<(H / 2) { for x in 0..<W {
            let i = (y * W + x) * 4
            let c = V3(pow(Float(px[i]) / 255, 2.2), pow(Float(px[i + 1]) / 255, 2.2), pow(Float(px[i + 2]) / 255, 2.2))
            let lum = dot(c, V3(0.2126, 0.7152, 0.0722))
            sum += c; lumSum += lum
            if lum > best { best = lum; bx = x; by = y }
        } }
        let n = Float(W * H / 2)
        let avg = sum / n, avgLum = max(lumSum / n, 0.01)
        let az = ((Float(bx) + 0.5) / Float(W) - 0.5 - s.north / 360) * 2 * .pi
        let el = max((0.5 - (Float(by) + 0.5) / Float(H)) * .pi - s.horizon * deg, 14 * deg)
        light.sunDir = normalize(V3(sin(az) * cos(el), sin(el), -cos(az) * cos(el)))
        let sunny = best / avgLum > 2
        light.sun = V3(1, 0.97, 0.9) * (sunny ? 2.8 : 1.3)
        let amb = avg / avgLum * (sunny ? 0.42 : 0.75)
        light.ambient = simd_clamp(amb, V3(repeating: 0.15), V3(repeating: 1.2))
        light.zenith = avg; light.horizon = avg
        return light
    }
}
