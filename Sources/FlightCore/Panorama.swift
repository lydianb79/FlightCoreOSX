import Foundation
import simd
import CoreGraphics
import ImageIO

/// A photographed object (tree, building) approximated as an upright cylinder you can crash into.
/// The bearing is measured in the photo: 0° is the image centre, positive to the right.
struct PanoObstacle: Codable {
    var bearing: Float
    var distance: Float
    var radius: Float
    var height: Float
}

/// Optional sidecar file "<image name>.json" next to a panorama.
struct PanoMeta: Codable {
    var name: String?
    var north: Float?        // degrees the photo is rotated about the vertical axis
    var horizon: Float?      // degrees the photo's horizon sits above the image centre line
    var eyeHeight: Float?    // camera height above the ground when the photo was taken (m)
    var windFrom: Float?
    var windSpeed: Float?
    var startX: Float?       // where aircraft start, metres right of / in front of (negative) the camera
    var startZ: Float?
    var startHeading: Float? // compass degrees after rotation: 0 = away from the camera, 90 = to the right
    var obstacles: [PanoObstacle]?
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
        var meta = presets[url.deletingPathExtension().lastPathComponent.lowercased()]
        if let d = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")),
           let m = try? JSONDecoder().decode(PanoMeta.self, from: d) { meta = m }
        if let m = meta {
            if let n = m.name { s.name = n }
            s.north = m.north ?? 0; s.horizon = m.horizon ?? 0; s.eyeHeight = m.eyeHeight ?? 1.7
            s.windFrom = m.windFrom ?? s.windFrom; s.windSpeed = m.windSpeed ?? s.windSpeed
            s.startX = m.startX ?? s.startX; s.startZ = m.startZ ?? s.startZ; s.startHeading = m.startHeading ?? s.startHeading
            s.obstacles = m.obstacles ?? []
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
        let m = PanoMeta(name: name, north: s.north, horizon: s.horizon, eyeHeight: s.eyeHeight, windFrom: s.windFrom, windSpeed: s.windSpeed,
                         startX: s.startX, startZ: s.startZ, startHeading: s.startHeading, obstacles: s.obstacles.isEmpty ? nil : s.obstacles)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(m) { try? d.write(to: url.deletingPathExtension().appendingPathExtension("json")) }
    }

    /// World position (x, z) of an obstacle for the site's current rotation.
    static func position(_ o: PanoObstacle, north: Float) -> SIMD2<Float> {
        let a = (o.bearing - north) * deg
        return SIMD2(sin(a), -cos(a)) * o.distance
    }

    private static func ring(_ from: Float, _ to: Float, _ n: Int, _ d: Float, _ r: Float, _ h: Float) -> [PanoObstacle] {
        (0..<n).map { PanoObstacle(bearing: from + (to - from) * (Float($0) + 0.5) / Float(n), distance: d, radius: r, height: h) }
    }

    /// Hand-tuned settings for the Poly Haven panoramas suggested in the README, keyed by file name.
    /// Distances are estimated from the photos, so treat the obstacles as approximate.
    static let presets: [String: PanoMeta] = [
        "alps_field": PanoMeta(name: "Alps Field", north: 0, horizon: 0, eyeHeight: 1.6, windFrom: 270, windSpeed: 2,
                               startX: -22, startZ: -24, startHeading: 90, obstacles: nil),
        "belfast_open_field": PanoMeta(name: "Belfast Open Field", north: 20, horizon: 0, eyeHeight: 1.6, windFrom: 90, windSpeed: 3,
                                       startX: -18, startZ: -20, startHeading: 90,
                                       obstacles: [PanoObstacle(bearing: -100, distance: 45, radius: 14, height: 26),
                                                   PanoObstacle(bearing: -78, distance: 52, radius: 8, height: 20),
                                                   PanoObstacle(bearing: 72, distance: 110, radius: 12, height: 17)]),
        "derelict_airfield_01": PanoMeta(name: "Derelict Airfield — Runway", north: -90, horizon: 0, eyeHeight: 1.6, windFrom: 270, windSpeed: 2,
                                         startX: 12, startZ: -4, startHeading: 270,
                                         obstacles: ring(-28, 18, 3, 50, 9, 14) + [PanoObstacle(bearing: -146, distance: 27, radius: 6, height: 7.5)]),
        "derelict_airfield_02": PanoMeta(name: "Derelict Airfield — Apron", north: -100, horizon: 0, eyeHeight: 1.6, windFrom: 0, windSpeed: 1,
                                         startX: -8, startZ: -12, startHeading: 90,
                                         obstacles: [PanoObstacle(bearing: -52, distance: 30, radius: 5, height: 13)]
                                             + ring(-35, 35, 3, 48, 10, 15) + ring(40, 122, 4, 42, 8, 8)
                                             + ring(-173, -135, 3, 36, 3, 24) + ring(126, 178, 4, 36, 3, 27)),
        "dry_cracked_lake": PanoMeta(name: "Dry Cracked Lake", north: 100, horizon: 0, eyeHeight: 1.6, windFrom: 0, windSpeed: 2,
                                     startX: -5, startZ: -9, startHeading: 15,
                                     obstacles: ring(-86, 36, 5, 40, 9, 14) + [PanoObstacle(bearing: -167, distance: 60, radius: 8, height: 10),
                                                                               PanoObstacle(bearing: 171, distance: 60, radius: 6, height: 10)]),
    ]

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
