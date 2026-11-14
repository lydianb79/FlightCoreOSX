import simd
import Foundation

struct SiteSpec {
    var name: String
    var style: Int              // 0 meadow, 1 desert, 2 alpine
    var seed: Int32
    var runwayLen: Float
    var runwayWid: Float
    var runwayType: Int         // 0 asphalt, 1 mown grass, 2 dirt
    var flatCenterZ: Float
    var flatHalfZ: Float
    var treeCount: Int
    var windFrom: Float
    var windSpeed: Float
    var turbulence: Float
    var rollMu: Float
    var cloud: Float
    var fog: Float
    var panorama: URL? = nil    // photo site: equirectangular 360° image
    var north: Float = 0
    var horizon: Float = 0
    var eyeHeight: Float = 1.7
    var startZ: Float = 0
    var startX: Float = -30
    var startHeading: Float = 90        // compass degrees: 0 = away from the pilot, 90 = to the right
    var obstacles: [PanoObstacle] = []

    static var all: [SiteSpec] = builtIn + Panoramas.discover()

    static let builtIn: [SiteSpec] = [
        SiteSpec(name: "Meadow Field", style: 0, seed: 11, runwayLen: 180, runwayWid: 12, runwayType: 0, flatCenterZ: 12, flatHalfZ: 45,
                 treeCount: 800, windFrom: 90, windSpeed: 2, turbulence: 0.3, rollMu: 0.035, cloud: 0.45, fog: 0.00011),
        SiteSpec(name: "Dry Lake", style: 1, seed: 29, runwayLen: 300, runwayWid: 24, runwayType: 2, flatCenterZ: 0, flatHalfZ: 120,
                 treeCount: 260, windFrom: 110, windSpeed: 4, turbulence: 0.2, rollMu: 0.05, cloud: 0.15, fog: 0.00007),
        SiteSpec(name: "Alpine Ridge", style: 2, seed: 47, runwayLen: 110, runwayWid: 10, runwayType: 1, flatCenterZ: 15, flatHalfZ: 25,
                 treeCount: 700, windFrom: 0, windSpeed: 6, turbulence: 0.35, rollMu: 0.07, cloud: 0.55, fog: 0.00009),
    ]
}

struct Tree { var p: V3; var h: Float }

final class Terrain {
    let n = 257
    let cell: Float = 24
    let half: Float
    var h: [Float]
    let site: SiteSpec
    var trees: [Tree] = []

    init(site: SiteSpec) {
        self.site = site
        half = Float(n - 1) * cell / 2
        h = [Float](repeating: 0, count: n * n)
        for j in 0..<n { for i in 0..<n {
            h[j * n + i] = raw(Float(i) * cell - half, Float(j) * cell - half)
        } }
        placeTrees()
    }

    private func raw(_ x: Float, _ z: Float) -> Float {
        if site.panorama != nil { return 0 }
        let r = sqrt(x * x + z * z), s = site.seed
        var y: Float
        switch site.style {
        case 0:
            y = 45 * (fbm(x / 800, z / 800, s) - 0.45) + 6 * (fbm(x / 150, z / 150, s + 7) - 0.5)
            y += smoothstep(1300, 2900, r) * 420 * fbm(x / 1400, z / 1400, s + 3)
        case 1:
            y = 1.5 * (fbm(x / 300, z / 300, s) - 0.5)
            y += smoothstep(1200, 2200, r) * 260 * smoothstep(0.5, 0.62, fbm(x / 1100, z / 1100, s + 5))
            y += smoothstep(1500, 3000, r) * 120 * fbm(x / 600, z / 600, s + 9)
        default:
            y = -260 * smoothstep(40, 650, -z) + 60 * smoothstep(80, 600, z)
            y += 25 * (fbm(x / 300, z / 300, s) - 0.5) * smoothstep(60, 300, r)
            let rd = 1 - abs(2 * fbm(x / 1600, z / 1600, s + 11) - 1)
            y += smoothstep(900, 2600, r) * 900 * rd * rd
        }
        let dx = max(abs(x) - (site.runwayLen / 2 + 25), 0), dz = max(abs(z - site.flatCenterZ) - site.flatHalfZ, 0)
        return y * smoothstep(34, site.style == 2 ? 110 : 190, sqrt(dx * dx + dz * dz))
    }

    func height(_ x: Float, _ z: Float) -> Float {
        let gx = clampf((x + half) / cell, 0, Float(n - 1) - 0.001), gz = clampf((z + half) / cell, 0, Float(n - 1) - 0.001)
        let i = Int(gx), j = Int(gz)
        let fx = gx - Float(i), fz = gz - Float(j)
        let h00 = h[j * n + i], h10 = h[j * n + i + 1], h01 = h[(j + 1) * n + i], h11 = h[(j + 1) * n + i + 1]
        if fx + fz < 1 { return h00 + fx * (h10 - h00) + fz * (h01 - h00) }
        return h11 + (1 - fx) * (h01 - h11) + (1 - fz) * (h10 - h11)
    }

    func normal(_ x: Float, _ z: Float) -> V3 {
        let e: Float = 1.5
        return normalize(V3(height(x - e, z) - height(x + e, z), 2 * e, height(x, z - e) - height(x, z + e)))
    }

    func contains(_ p: V3) -> Bool { abs(p.x) < half - 50 && abs(p.z) < half - 50 }

    private func placeTrees() {
        var rng = LCG(UInt64(site.seed))
        var tries = 0
        while trees.count < site.treeCount && tries < site.treeCount * 40 {
            tries += 1
            let x = rng.range(-1300, 1300), z = rng.range(-1300, 1300)
            let dx = max(abs(x) - (site.runwayLen / 2 + 55), 0), dz = max(abs(z - site.flatCenterZ) - (site.flatHalfZ + 35), 0)
            if dx * dx + dz * dz < 100 { continue }
            if z < 0 && z > -230 && abs(x) < 320 { continue }         // keep the flying area in front of the pilot open
            if fbm(x / 260, z / 260, site.seed + 21) < (site.style == 1 ? 0.56 : 0.5) { continue }
            let y = height(x, z)
            if normal(x, z).y < 0.85 || (site.style == 2 && y > 180) { continue }
            trees.append(Tree(p: V3(x, y, z), h: site.style == 1 ? rng.range(1.2, 3) : rng.range(7, 15)))
        }
    }

    // MARK: Meshes

    func buildMesh() -> MeshBuilder {
        var b = MeshBuilder()
        b.data.reserveCapacity((n - 1) * (n - 1) * 60)
        var cols = [V4](repeating: .zero, count: n * n)
        var nrms = [V3](repeating: .zero, count: n * n)
        let s = site.seed
        for j in 0..<n { for i in 0..<n {
            let x = Float(i) * cell - half, z = Float(j) * cell - half
            let y = h[j * n + i]
            let hl = h[j * n + max(i - 1, 0)], hr = h[j * n + min(i + 1, n - 1)]
            let hd = h[max(j - 1, 0) * n + i], hu = h[min(j + 1, n - 1) * n + i]
            let nr = normalize(V3(hl - hr, 2 * cell, hd - hu))
            nrms[j * n + i] = nr
            let v = fbm(x / 110, z / 110, s + 31)
            let steep = smoothstep(0.86, 0.7, nr.y)
            var c: V4
            switch site.style {
            case 0:
                c = mix(rgb(0.24, 0.40, 0.13), rgb(0.38, 0.50, 0.17), v)
                c = mix(c, rgb(0.15, 0.27, 0.13), smoothstep(120, 260, y))
                c = mix(c, rgb(0.42, 0.40, 0.37), steep)
            case 1:
                c = mix(rgb(0.80, 0.70, 0.52), rgb(0.72, 0.60, 0.42), v)
                c = mix(c, rgb(0.62, 0.36, 0.24), smoothstep(15, 60, y))
                c = mix(c, rgb(0.45, 0.28, 0.2), steep)
            default:
                c = mix(rgb(0.27, 0.43, 0.16), rgb(0.40, 0.50, 0.20), v)
                c = mix(c, rgb(0.45, 0.44, 0.43), max(steep, smoothstep(260, 520, y)))
                c = mix(c, rgb(0.93, 0.95, 0.98), smoothstep(560, 760, y + 160 * v) * (1 - steep * 0.6))
            }
            cols[j * n + i] = c
        } }
        for j in 0..<(n - 1) { for i in 0..<(n - 1) {
            func emit(_ ii: Int, _ jj: Int) {
                let k = jj * n + ii
                b.v(V3(Float(ii) * cell - half, h[k], Float(jj) * cell - half), nrms[k], cols[k])
            }
            emit(i, j); emit(i, j + 1); emit(i + 1, j)
            emit(i + 1, j); emit(i, j + 1); emit(i + 1, j + 1)
        } }
        return b
    }

    var windsockBase: V3 { V3(32, height(32, -site.runwayWid / 2 - 9), -site.runwayWid / 2 - 9) }
    var pilotPos: V3 { site.panorama != nil ? .zero : V3(0, height(0, site.runwayWid / 2 + 7), site.runwayWid / 2 + 7) }
}

func buildWindsock() -> MeshBuilder {
    var b = MeshBuilder()
    let n = 6
    for i in 0..<n {
        let z0 = Float(i) * 0.4, z1 = z0 + 0.4
        let r0 = 0.36 - 0.035 * Float(i), r1 = r0 - 0.035
        func ring(_ z: Float, _ r: Float) -> [V3] { (0..<10).map { j in let a = Float(j) / 10 * 2 * .pi; return V3(cos(a) * r, sin(a) * r, z) } }
        b.loft([ring(z0, r0), ring(z1, r1)], color: i % 2 == 0 ? rgb(0.95, 0.35, 0.05) : rgb(0.96, 0.96, 0.96), caps: false)
    }
    return b
}

struct Thermal { var c: SIMD2<Float>; var r: Float; var s: Float }

final class Environment {
    var windSpeed: Float = 2
    var windFrom: Float = 90
    var turbulence: Float = 0.3
    var thermalsOn = true
    var time: Float = 0
    var thermals: [Thermal] = []

    func configure(_ site: SiteSpec) {
        windSpeed = site.windSpeed; windFrom = site.windFrom; turbulence = site.turbulence
        var rng = LCG(UInt64(site.seed) + 5)
        thermals = (0..<5).map { _ in Thermal(c: SIMD2(rng.range(-350, 350), rng.range(-420, -60)), r: rng.range(35, 65), s: rng.range(1.5, 3.2)) }
    }

    var windVec: V3 { let t = windFrom * deg; return V3(-sin(t), 0, cos(t)) * windSpeed }

    func wind(at p: V3, terrain: Terrain) -> V3 {
        let agl = max(p.y - terrain.height(p.x, p.z), 0)
        let base = windVec
        var w = base * (0.45 + 0.55 * min(1, agl / 25))
        let t = time
        if turbulence > 0 {
            let g1 = sin(t * 0.61 + p.x * 0.013) + 0.6 * sin(t * 1.37 + p.z * 0.021 + 1.3) + 0.35 * sin(t * 3.1 + p.x * 0.05 + p.z * 0.04)
            let g2 = sin(t * 0.83 + p.z * 0.017 + 2.1) + 0.5 * sin(t * 2.3 + p.x * 0.03)
            let g3 = sin(t * 1.1 + p.x * 0.02 + p.z * 0.015 + 0.7) + 0.5 * sin(t * 2.9 + p.y * 0.06)
            let amp = turbulence * (0.3 + 0.25 * windSpeed) * min(1, agl / 4 + 0.2)
            let dir = windSpeed > 0.01 ? normalize(base) : V3(1, 0, 0)
            w += dir * (g1 * amp * 0.5) + V3(-dir.z, 0, dir.x) * (g2 * amp * 0.35) + V3(0, g3 * amp * 0.3, 0)
        }
        if windSpeed > 0.1 {
            let n = terrain.normal(p.x, p.z)
            w.y += (base.x * -n.x + base.z * -n.z) / n.y * exp(-agl / 60) * 0.9
        }
        if thermalsOn {
            for th in thermals {
                let dx = p.x - th.c.x - base.x * 4, dz = p.z - th.c.y - base.z * 4
                w.y += th.s * exp(-(dx * dx + dz * dz) / (th.r * th.r)) * min(1, agl / 40)
            }
        }
        return w
    }
}

/// Simple demo pilot, also used for headless testing of the flight models.
struct Autopilot {
    var wp = 0
    var t: Float = 0
    static let circuit: [SIMD2<Float>] = [SIMD2(150, -80), SIMD2(150, -230), SIMD2(-150, -230), SIMD2(-150, -80)]

    mutating func update(_ ac: Aircraft, terrain: Terrain, dt: Float) -> Controls {
        t += dt
        var c = Controls()
        let agl = ac.pos.y - terrain.height(ac.pos.x, ac.pos.z)
        switch ac.spec.kind {
        case .airplane:
            let target = Autopilot.circuit[wp]
            let to = V3(target.x - ac.pos.x, 0, target.y - ac.pos.z)
            if length(to) < 45 { wp = (wp + 1) % Autopilot.circuit.count }
            var fh = ac.forward; fh.y = 0
            fh = length(fh) > 0.01 ? normalize(fh) : V3(0, 0, -1)
            let d = normalize(to)
            let herr = atan2(-cross(fh, d).y, dot(fh, d))
            let climbing = agl < 6
            let rollT = climbing ? 0 : clampf(herr * 1.2, -0.65, 0.65)
            let altT: Float = 40
            let pitchT = climbing ? (ac.airspeed > 9 ? 0.16 : 0.03) : clampf(0.02 * (altT - agl), -0.18, 0.28)
            c.aileron = clampf(2.5 * (rollT - ac.roll) + 0.25 * ac.omega.z, -1, 1)
            c.elevator = clampf(3 * (pitchT - ac.pitch) - 0.3 * ac.omega.x + 0.25 * abs(ac.roll), -1, 1)
            c.rudder = ac.onGround ? clampf(1.5 * herr * 0, -1, 1) : clampf(0.3 * (rollT - ac.roll), -0.5, 0.5)
            c.throttle = climbing ? 1 : clampf(0.6 + 0.08 * (16 - ac.airspeed) + 0.02 * (altT - agl), 0.2, 1)
        case .multirotor, .helicopter:
            let ang = t * 0.25
            let tp = V3(30 * sin(ang), 0, -45 + 20 * cos(ang))
            let alt: Float = min(12, 2 + t * 2)
            var vd = (tp - ac.pos) * 0.6; vd.y = 0
            if length(vd) > 7 { vd *= 7 / length(vd) }
            var ad = (vd - ac.vel) * 1.5; ad.y = 0
            if length(ad) > 5 { ad *= 5 / length(ad) }
            let vy = clampf(alt - agl, -2, 3)
            if ac.spec.kind == .multirotor {
                var fh = ac.forward; fh.y = 0; fh = normalize(fh)
                let hr = cross(fh, V3(0, 1, 0))
                let m = ac.spec.multi!
                c.elevator = clampf(-atan(dot(ad, fh) / gravity) / m.maxAngle, -1, 1)
                c.aileron = clampf(atan(dot(ad, hr) / gravity) / m.maxAngle, -1, 1)
                c.throttle = clampf(ac.spec.mass * gravity / (4 * m.maxThrust) + 0.12 * (vy - ac.vel.y), 0.05, 1)
            } else {
                let h = ac.spec.heli!
                let tgt = normalize(V3(ad.x, gravity, ad.z))
                let eb = simd_float3x3(ac.q).transpose * cross(ac.up, tgt)
                c.elevator = clampf(eb.x * 6 / h.maxRate, -1, 1)
                c.aileron = clampf(-eb.z * 6 / h.maxRate, -1, 1)
                c.throttle = clampf(0.67 + 0.1 * (vy - ac.vel.y), 0, 1)
            }
        }
        return c
    }
}
