import simd
import Foundation

// Procedural 3D models for the aircraft. Vertex alpha is the surface gloss
// (1 = polished film / glass, 0 = matte rubber).

private func gl(_ c: V4, _ g: Float) -> V4 { V4(c.x, c.y, c.z, g) }
private func dim(_ c: V4, _ k: Float) -> V4 { V4(c.x * k, c.y * k, c.z * k, c.w) }
private let film: Float = 0.6
private let black = V4(0.04, 0.04, 0.045, 0.25)
private let rubber = V4(0.045, 0.045, 0.045, 0.04)
private let alu = V4(0.72, 0.73, 0.75, 0.7)
private let carbon = V4(0.07, 0.07, 0.08, 0.55)
private let glass = V4(0.05, 0.08, 0.13, 1)

private let airfoilX: [Float] = [0, 0.012, 0.04, 0.1, 0.2, 0.32, 0.46, 0.62, 0.8, 1]

private func airfoilT(_ x: Float, _ t: Float) -> Float {
    5 * t * (0.2969 * sqrt(x) - 0.126 * x - 0.3516 * x * x + 0.2843 * x * x * x - 0.1036 * x * x * x * x)
}

private struct Section { var ring: [V3]; var xs: [Float]; var top: [Bool] }

/// Airfoil cross-section covering the chord range c0...c1 (so a wing and its aileron share one profile).
private func airfoil(le: V3, chord: Float, thick: Float, camber: Float, up: V3, c0: Float, c1: Float, scale: Float = 1) -> Section {
    var s = Section(ring: [], xs: [], top: [])
    let mid = (c0 + c1) / 2
    func point(_ xb: Float, _ upper: Bool) {
        let x0 = c0 + (c1 - c0) * xb
        let x = mid + (x0 - mid) * scale
        // thin sections are flat foam sheet: constant thickness with slightly rounded edges
        let yt = (thick < 0.045 ? thick * 0.55 * (xb < 0.005 || xb > 0.995 ? 0.5 : 1) : max(airfoilT(x0, thick), 0.0015)) * scale
        let y = camber * 4 * x0 * (1 - x0) + (upper ? yt : -yt * 0.8)
        s.ring.append(le + V3(0, 0, x * chord) + up * (y * chord)); s.xs.append(x0); s.top.append(upper)
    }
    for x in airfoilX { point(x, true) }
    for x in airfoilX.reversed() { point(x, false) }
    return s
}

/// Outward normals of a closed section, from its outline rather than its centre (so thin airfoils shade correctly).
private func ringNormals(_ r: [V3], axis: V3) -> [V3] {
    let m = r.count
    let c = r.reduce(V3.zero, +) / Float(m)
    return (0..<m).map { i in
        var a = i, b = i
        for _ in 0..<m { a = (a + m - 1) % m; if length(r[a] - r[i]) > 1e-6 { break } }
        for _ in 0..<m { b = (b + 1) % m; if length(r[b] - r[i]) > 1e-6 { break } }
        var n = cross(r[b] - r[a], axis)
        let l = length(n)
        if l < 1e-9 { let d = r[i] - c; return length(d) > 1e-9 ? normalize(d) : V3(0, 1, 0) }
        n /= l
        return dot(n, r[i] - c) < 0 ? -n : n
    }
}

extension MeshBuilder {
    /// Join two rings with smooth normals and one flat colour per quad, so painted edges stay sharp.
    /// Same, but with a colour per vertex so painted regions blend softly (camouflage).
    mutating func skinSoft(_ a: [V3], _ b: [V3], _ na: [V3], _ nb: [V3], ca: [V4], cb: [V4]) {
        let m = a.count
        for j in 0..<m {
            let k = (j + 1) % m
            v(a[j], na[j], ca[j]); v(a[k], na[k], ca[k]); v(b[k], nb[k], cb[k])
            v(a[j], na[j], ca[j]); v(b[k], nb[k], cb[k]); v(b[j], nb[j], cb[j])
        }
    }

    mutating func skin(_ a: [V3], _ b: [V3], _ na: [V3], _ nb: [V3], color: (Int) -> V4) {
        let m = a.count
        for j in 0..<m {
            let k = (j + 1) % m, c = color(j)
            v(a[j], na[j], c); v(a[k], na[k], c); v(b[k], nb[k], c)
            v(a[j], na[j], c); v(b[k], nb[k], c); v(b[j], nb[j], c)
        }
    }

    mutating func cap(_ ring: [V3], color: V4, flip: Bool = false) {
        let c = ring.reduce(V3.zero, +) / Float(ring.count)
        for j in 0..<ring.count {
            let a = ring[j], b = ring[(j + 1) % ring.count]
            if flip { tri(c, b, a, color) } else { tri(c, a, b, color) }
        }
    }

    /// Wing, tail or control-surface panel built from spanwise strips, each with its own colours so trim stays crisp.
    mutating func wingPanel(le: (Float) -> V3, chord: (Float) -> Float, thick: Float, camber: Float, up: V3,
                            f0: Float, f1: Float, c0: Float = 0, c1: Float = 1, strips: Int, roundTip: Bool, soft: Bool = false,
                            paint: (Float, Float, Bool) -> V4) {
        let span = normalize(le(f1) - le(f0))
        var prev = airfoil(le: le(f0), chord: chord(f0), thick: thick, camber: camber, up: up, c0: c0, c1: c1)
        var pn = ringNormals(prev.ring, axis: span)
        let m = prev.ring.count
        func quadColor(_ f: Float, _ j: Int) -> V4 {
            let k = (j + 1) % m
            return paint(f, (prev.xs[j] + prev.xs[k]) / 2, prev.top[j] && prev.top[k] ? true : (prev.top[j] != prev.top[k] ? prev.xs[j] < 0.5 : false))
        }
        cap(prev.ring, color: paint(f0, 0.5, true))
        for i in 0..<strips {
            let fa = f0 + (f1 - f0) * Float(i) / Float(strips), fb = f0 + (f1 - f0) * Float(i + 1) / Float(strips)
            let next = airfoil(le: le(fb), chord: chord(fb), thick: thick, camber: camber, up: up, c0: c0, c1: c1)
            let nn = ringNormals(next.ring, axis: span)
            if soft {
                skinSoft(prev.ring, next.ring, pn, nn, ca: (0..<m).map { paint(fa, prev.xs[$0], prev.top[$0]) }, cb: (0..<m).map { paint(fb, prev.xs[$0], prev.top[$0]) })
            } else {
                skin(prev.ring, next.ring, pn, nn) { quadColor((fa + fb) / 2, $0) }
            }
            prev = next; pn = nn
        }
        if roundTip {
            let r = chord(f1) * max(thick, 0.08) * 0.9
            for a in [Float(0.5), 1.0, 1.4] {
                let next = airfoil(le: le(f1) + span * (r * sin(a)), chord: chord(f1), thick: thick, camber: camber, up: up, c0: c0, c1: c1, scale: max(cos(a), 0.05))
                let nn = ringNormals(next.ring, axis: span).map { normalize($0 * cos(a) + span * sin(a)) }
                skin(prev.ring, next.ring, pn, nn) { quadColor(f1 - 0.001, $0) }
                prev = next; pn = nn
            }
        }
        cap(prev.ring, color: paint(f1 - 0.001, 0.5, true))
    }

    /// Fuselage from superellipse stations. `paint` gets (position along length 0...1, side -1...1, height -1...1).
    mutating func fuselage(_ st: [(z: Float, w: Float, h: Float, y: Float)], x: Float = 0, exp e: Float, seg: Int = 20, soft: Bool = false, paint: (Float, Float, Float) -> V4) {
        let rings = st.map { superRing(x: x, y: $0.y, z: $0.z, w: $0.w, h: $0.h, exp: e, seg: seg) }
        let nrms = rings.map { ringNormals($0, axis: V3(0, 0, 1)) }
        let z0 = st.first!.z, len = st.last!.z - z0
        for i in 0..<(st.count - 1) {
            let t = ((st[i].z + st[i + 1].z) / 2 - z0) / len
            if soft {
                func cols(_ k: Int) -> [V4] { (0..<seg).map { j in let a = Float(j) / Float(seg) * 2 * .pi; return paint((st[k].z - z0) / len, cos(a), sin(a)) } }
                skinSoft(rings[i], rings[i + 1], nrms[i], nrms[i + 1], ca: cols(i), cb: cols(i + 1))
                continue
            }
            skin(rings[i], rings[i + 1], nrms[i], nrms[i + 1]) { j in
                let a = (Float(j) + 0.5) / Float(seg) * 2 * .pi
                return paint(t, cos(a), sin(a))
            }
        }
        cap(rings.first!, color: paint(0, 0, 0)); cap(rings.last!, color: paint(1, 0, 0))
    }

    mutating func wheel(center c: V3, radius r: Float, width w: Float, hub: V4 = alu) {
        func ring(_ x: Float, _ rr: Float) -> [V3] { (0..<16).map { j in let a = Float(j) / 16 * 2 * .pi; return c + V3(x, cos(a) * rr, sin(a) * rr) } }
        loft([ring(-w / 2, r * 0.62), ring(-w * 0.42, r * 0.9), ring(-w * 0.2, r), ring(w * 0.2, r), ring(w * 0.42, r * 0.9), ring(w / 2, r * 0.62)], color: rubber, caps: false)
        loft([ring(-w * 0.5, r * 0.62), ring(-w * 0.52, r * 0.2)], color: hub); loft([ring(w * 0.5, r * 0.62), ring(w * 0.52, r * 0.2)], color: hub)
    }
}

/// Propeller (or rotor) about the Z axis at the origin: twisted blades plus the translucent disc seen at speed.
func makePropeller(diameter D: Float, blades n: Int, color: V4 = black, tip: V4 = V4(0.95, 0.8, 0.1, 0.4), pitch: Float = 0.2, chordScale: Float = 1) -> (blades: MeshBuilder, disc: MeshBuilder) {
    let R = D / 2
    var b = MeshBuilder()
    let rs: [Float] = [0.1, 0.24, 0.45, 0.66, 0.86, 0.94, 0.985, 1.0], cs: [Float] = [0.07, 0.14, 0.165, 0.15, 0.11, 0.085, 0.05, 0.015]
    for k in 0..<n {
        let q = simd_quatf(angle: Float(k) / Float(n) * 2 * .pi, axis: V3(0, 0, 1))
        var rings: [[V3]] = []
        for i in rs.indices {
            let beta = atan(pitch / rs[i]), c = cs[i] * R * chordScale, th = c * 0.11
            let t = V3(cos(beta), 0, -sin(beta)), nn = V3(sin(beta), 0, cos(beta))
            let o = V3(0, rs[i] * R, 0)
            rings.append([o - t * (c / 2), o - t * (c * 0.2) + nn * th, o + t * (c * 0.2) + nn * (th * 0.8), o + t * (c / 2), o + t * (c * 0.2) - nn * (th * 0.5), o - t * (c * 0.2) - nn * (th * 0.6)].map { q.act($0) })
        }
        b.loft(Array(rings[0...4]), color: color, caps: false)
        b.loft(Array(rings[4...7]), color: tip)
    }
    b.cylinder(from: V3(0, 0, -R * 0.03), to: V3(0, 0, R * 0.03), r0: R * 0.11, r1: R * 0.11, seg: 10, color: color)
    var d = MeshBuilder()
    let fr: [Float] = [0.1, 0.35, 0.7, 0.9, 0.95, 1.0], al: [Float] = [0, 0.1, 0.2, 0.26, 0.34, 0]
    let seg = 32, nz = V3(0, 0, 1)
    for i in 0..<(fr.count - 1) {
        let c0 = i >= 3 ? V4(tip.x * 0.6, tip.y * 0.6, tip.z * 0.6, al[i]) : V4(0.12, 0.12, 0.12, al[i])
        let c1 = i >= 2 ? V4(tip.x * 0.6, tip.y * 0.6, tip.z * 0.6, al[i + 1]) : V4(0.12, 0.12, 0.12, al[i + 1])
        for j in 0..<seg {
            let a0 = Float(j) / Float(seg) * 2 * .pi, a1 = Float(j + 1) / Float(seg) * 2 * .pi
            let p00 = V3(cos(a0), sin(a0), 0) * (fr[i] * R), p01 = V3(cos(a1), sin(a1), 0) * (fr[i] * R)
            let p10 = V3(cos(a0), sin(a0), 0) * (fr[i + 1] * R), p11 = V3(cos(a1), sin(a1), 0) * (fr[i + 1] * R)
            d.v(p00, nz, c0); d.v(p10, nz, c1); d.v(p11, nz, c1)
            d.v(p00, nz, c0); d.v(p11, nz, c1); d.v(p01, nz, c0)
        }
    }
    return (b, d)
}

private func spinner(_ b: inout MeshBuilder, base: V3, radius r: Float, length l: Float, color: V4) {
    var rings: [[V3]] = []
    for i in 0...6 {
        let s = Float(i) / 6
        let rr = r * sqrt(max(1 - (1 - s) * (1 - s), 0.0004))
        rings.append((0..<14).map { j in let a = Float(j) / 14 * 2 * .pi; return base + V3(cos(a) * rr, sin(a) * rr, -l * (1 - s)) })
    }
    b.loft(rings, color: color)
}

// MARK: - Airplanes

func buildAirplaneModel(_ g: PlaneGeom, wheels: [V3], engines: [V3], wings: [(y: Float, z: Float)]) -> [Part] {
    let hs = g.span / 2, dih = g.dihedral * deg
    let L = g.fuseLen, nz = g.noseZ, tz = g.noseZ + g.fuseLen
    let w = g.fuseW / 2, h = g.fuseH / 2
    let finY = h * 0.3
    let stabY = g.tTail ? finY + g.finH : finY
    func chord(_ f: Float) -> Float { lerp(g.rootChord, g.tipChord, f) }
    func camo(_ a: Float, _ b: Float) -> Bool { vnoise(a * 4.2 + 3.1, b * 4.2 + 1.7, 7) + 0.35 * vnoise(a * 11, b * 11, 9) > 0.66 }
    let film: Float = g.scheme == 7 ? 0.2 : (g.profile ? 0.15 : 0.6)        // camouflage and foam are matte
    let cFuse = gl(g.fuse, film), cTop = gl(g.wingTop, film), cBot = gl(g.wingBottom, film), cTail = gl(g.tail, film), cAcc = gl(g.accent, film)
    let dark = V4(0.06, 0.06, 0.07, film), white = V4(0.96, 0.96, 0.95, film)

    // --- trim schemes
    func wingPaint(_ f: Float, _ x: Float, _ top: Bool) -> V4 {
        switch g.scheme {
        case 1:     // aerobatic: tapering stripes on top, checkerboard underneath
            if top { return (f > 0.22 && f < 0.36 && x < 0.75) || (f > 0.5 && f < 0.62 && x < 0.6) || (f > 0.78 && f < 0.88 && x < 0.45) ? cAcc : (x < 0.1 ? white : cTop) }
            return (Int(f * 8) + (x > 0.5 ? 1 : 0)) % 2 == 0 ? cBot : dark
        case 2:     // warbird: invasion stripes
            if f > 0.36 && f < 0.66 { return Int((f - 0.36) / 0.06) % 2 == 0 ? white : dark }
            return top ? cTop : cBot
        case 3:     // glider: coloured tips, bold underside
            if top { return f > 0.82 ? cTail : cTop }
            return f > 0.82 || (f > 0.3 && f < 0.5) ? cBot : white
        case 4:     // jet: leading-edge and tip accents
            if x < 0.1 || f > 0.93 { return cAcc }
            return top ? cTop : cBot
        case 5:     // vintage: single colour with dark leading edge
            return top ? (x < 0.06 ? dark : cTop) : cBot
        case 6:     // civil: coloured tips
            return f > 0.9 ? cAcc : (top ? cTop : cBot)
        case 7:     // two-tone camouflage above, light below
            return top ? (camo(f * 1.6, x * 0.9) ? cAcc : cTop) : cBot
        case 8:     // plain
            return top ? cTop : cBot
        case 9:     // printed foam
            if top { return f > 0.86 ? cTail : ((f > 0.3 && f < 0.52 && x > 0.12) ? cAcc : (x < 0.12 ? dark : cTop)) }
            return (Int(f * 6) % 2 == 0) ? cBot : dark
        default:    // sport: bands on top, two dark stripes underneath
            if top { return f > 0.9 ? cAcc : ((f > 0.52 && f < 0.64) ? white : (x < 0.08 ? white : cTop)) }
            return (f > 0.28 && f < 0.42) || (f > 0.62 && f < 0.76) ? cTail : cBot
        }
    }
    func tailPaint(_ f: Float, _ x: Float, _ top: Bool) -> V4 {
        switch g.scheme {
        case 1: return (Int(f * 4) % 2 == 0) == (x < 0.5) ? cTail : cAcc
        case 2: return f > 0.8 ? cTail : (top ? cTop : cBot)
        case 6: return f > 0.72 ? cAcc : cTail
        case 7: return top ? (camo(f * 0.8 + 3, x * 0.6) ? cAcc : cTop) : (g.tTail ? cBot : cBot)
        case 8: return cTail
        case 9: return f > 0.7 ? cAcc : cTail
        default: return f > 0.78 ? cAcc : (top ? cTail : (g.scheme == 3 ? cBot : cTail))
        }
    }
    func fusePaint(_ t: Float, _ sx: Float, _ sy: Float) -> V4 {
        switch g.scheme {
        case 1:
            if t < 0.14 { return cTail }
            return sy > -0.3 && sy < 0.12 ? cTail : (sy < -0.3 ? white : cFuse)
        case 2: return t < 0.07 ? cTail : (sy < -0.35 ? cBot : (t > 0.72 && t < 0.78 ? white : cFuse))
        case 3: return t < 0.1 ? cTail : (abs(sy) < 0.16 && t < 0.6 ? cAcc : cFuse)
        case 4: return sy < -0.3 ? cBot : (abs(sy - 0.05) < 0.16 ? cAcc : cFuse)
        case 5: return abs(sy + 0.05) < 0.14 && t > 0.03 ? cTail : cFuse
        case 6: return abs(sy + 0.02) < 0.13 || (sy > -0.42 && sy < -0.3) ? cAcc : cFuse
        case 7: return sy < -0.35 ? cBot : (camo(t * 2.2, sy * 0.5 + sx * 0.3) ? cAcc : cTop)
        case 8: return t < 0.1 ? cAcc : cFuse
        case 9:
            if t > 0.2 && t < 0.4 && sy > 0.45 { return V4(0.08, 0.1, 0.14, film) }
            return abs(sy + 0.1) < 0.2 && t > 0.05 && t < 0.9 ? cAcc : (t < 0.05 ? dark : cFuse)
        default:
            if t < 0.11 { return cTail }
            return abs(sy) < 0.2 && t < 0.86 ? cTail : (abs(sy) < 0.3 && t < 0.86 ? white : cFuse)
        }
    }

    var parts: [Part] = []
    var b = MeshBuilder()

    // --- fuselage
    if g.profile {
        // flat foam plate with the side view of an aerobat, plus a horizontal stiffening plate
        let outline: [(Float, Float, Float)] = [(0, 0.2, 0), (0.04, 0.36, 0), (0.12, 0.56, 0.02), (0.22, 0.82, 0.12), (0.32, 0.9, 0.16), (0.45, 0.72, 0.06), (0.62, 0.5, 0), (0.82, 0.36, 0), (1, 0.3, 0.04)]
        b.fuselage(outline.map { (z: nz + $0.0 * L, w: Float(0.004), h: h * $0.1, y: h * $0.2) }, exp: 8, seg: 12, paint: fusePaint)
        b.box(center: V3(0, 0, nz + L * 0.45), size: V3(0.07, 0.006, L * 0.8), color: cFuse)
        b.cylinder(from: V3(0, 0, nz - 0.012), to: V3(0, 0, nz + 0.03), r0: 0.014, r1: 0.014, seg: 10, color: V4(0.75, 0.3, 0.1, 0.8))
        // carbon bracing rods
        for s in [Float(-1), 1] {
            b.cylinder(from: V3(0, h * 0.75, nz + L * 0.32), to: V3(s * hs * 0.6, g.wingY, g.wingLE + g.sweep * 0.6 + chord(0.6) * 0.3), r0: 0.0012, r1: 0.0012, seg: 4, color: black)
            b.cylinder(from: V3(0, -h * 0.7, nz + L * 0.32), to: V3(s * hs * 0.6, g.wingY, g.wingLE + g.sweep * 0.6 + chord(0.6) * 0.3), r0: 0.0012, r1: 0.0012, seg: 4, color: black)
        }
    } else {
        let prof: [(Float, Float, Float, Float)] = (g.ducted && !g.noseIntake) || g.twin > 0
            ? [(0, 0.06, 0.06, -0.1), (0.03, 0.3, 0.3, -0.08), (0.1, 0.62, 0.62, -0.04), (0.2, 0.86, 0.88, 0), (0.32, 1, 1, 0), (0.45, 1, 1, 0), (0.6, 0.86, 0.88, 0.04), (0.78, 0.58, 0.64, 0.12), (0.92, 0.34, 0.44, 0.22), (1, 0.16, 0.3, 0.3)]
            : [(0, 0.44, 0.46, 0), (0.012, 0.66, 0.68, 0), (0.05, 0.88, 0.88, 0), (0.12, 0.98, 0.98, 0), (0.22, 1, 1, 0), (0.36, 1, 1, 0), (0.5, 0.92, 0.94, 0.02), (0.64, 0.74, 0.8, 0.08), (0.8, 0.5, 0.6, 0.16), (0.93, 0.28, 0.42, 0.25), (1, 0.14, 0.3, 0.3)]
        b.fuselage(prof.map { (z: nz + $0.0 * L, w: w * $0.1, h: h * $0.2, y: h * $0.3) }, exp: g.fuseExp, soft: g.scheme == 7, paint: fusePaint)
        // canopy glass with a frame
        let cl = L * g.canopyLen, cz = nz + L * 0.3
        b.ellipsoid(center: V3(0, h * 0.78, cz), radii: V3(w * 0.7, h * 0.62, cl), color: glass, seg: 16, rings: 8)
        b.ellipsoid(center: V3(0, h * 0.74, cz), radii: V3(w * 0.74, h * 0.52, cl * 1.04), color: gl(g.fuse, film), seg: 16, rings: 4)
        if g.noseIntake {
            b.ellipsoid(center: V3(0, 0, nz + 0.002), radii: V3(w * 0.34, h * 0.36, 0.01), color: black, seg: 12, rings: 3)
        } else if !g.ducted && g.twin == 0 {
            // cooling inlets and exhaust on the cowl
            for s in [Float(-1), 1] { b.ellipsoid(center: V3(s * w * 0.42, h * 0.12, nz + 0.004), radii: V3(w * 0.2, h * 0.13, 0.008), color: black, seg: 8, rings: 3) }
            b.cylinder(from: V3(w * 0.4, -h * 0.75, nz + L * 0.1), to: V3(w * 0.45, -h * 1.02, nz + L * 0.13), r0: 0.006, r1: 0.006, seg: 6, color: alu)
        }
        // radio antenna
        b.cylinder(from: V3(0, h * 0.9, nz + L * 0.52), to: V3(0, h * 0.9 + 0.09, nz + L * 0.56), r0: 0.0015, r1: 0.0012, seg: 4, color: black)
    }

    // --- wings (separate parts so they can break off)
    for wg in wings { for side in [Float(-1), 1] {
        let up = V3(-sin(dih) * side, cos(dih), 0)
        func le(_ f: Float) -> V3 { V3(side * hs * f, wg.y + hs * f * tan(dih), g.wingLE + wg.z + g.sweep * f) }
        let a0 = g.ailStart, k = 1 - g.ailFrac
        let hasFlap = g.flaps && a0 > 0.4
        let fRoot: Float = 0.5 * w / hs       // start just inside the fuselage side
        var wm = MeshBuilder()
        if a0 > 0.01 {
            wm.wingPanel(le: le, chord: chord, thick: g.thick, camber: g.camber * 0.006, up: up, f0: fRoot, f1: hasFlap ? 0.09 : a0, strips: hasFlap ? 1 : 6, roundTip: false, soft: g.scheme == 7, paint: wingPaint)
            if hasFlap { wm.wingPanel(le: le, chord: chord, thick: g.thick, camber: g.camber * 0.006, up: up, f0: 0.09, f1: a0, c1: k, strips: 5, roundTip: false, soft: g.scheme == 7, paint: wingPaint) }
        }
        wm.wingPanel(le: le, chord: chord, thick: g.thick, camber: g.camber * 0.006, up: up, f0: max(a0, fRoot), f1: 1, c1: k, strips: a0 > 0.01 ? 7 : 12, roundTip: false, soft: g.scheme == 7, paint: wingPaint)
        // wing tip block spanning the full chord, with a navigation-colour marker: green right, red left
        let tipCol = side > 0 ? V4(0.05, 0.6, 0.15, film) : V4(0.8, 0.05, 0.05, film)
        wm.wingPanel(le: { le(1) + normalize(le(1) - le(0.5)) * ($0 * g.tipChord * 0.05) }, chord: { _ in g.tipChord }, thick: g.thick, camber: g.camber * 0.006, up: up,
                     f0: 0, f1: 1, strips: 1, roundTip: true, paint: { _, x, t in x < 0.3 ? tipCol : wingPaint(0.99, x, t) })
        parts.append(Part(mesh: wm, detach: true, center: le(0.5) + V3(0, 0, chord(0.5) * 0.5)))
        func surface(_ f0: Float, _ f1: Float, _ anim: Anim) {
            let pivot = le(f0) + V3(0, 0, chord(f0) * k)
            var m = MeshBuilder()
            m.wingPanel(le: le, chord: chord, thick: g.thick, camber: g.camber * 0.006, up: up, f0: f0, f1: f1, c0: k, strips: 6, roundTip: false, soft: g.scheme == 7, paint: wingPaint)
            m.translate(-pivot)
            parts.append(Part(mesh: m, pivot: pivot, axis: normalize(le(f1) + V3(0, 0, chord(f1) * k) - pivot) * side, anim: anim))
        }
        surface(max(a0, fRoot) + 0.005, 0.995, .hinge(0, -side * g.ailThrow * deg))
        if hasFlap { surface(0.095, a0 - 0.005, .hinge(3, 38 * deg)) }
        if g.struts && wg.y > h * 0.5 {
            // lift struts from the lower fuselage to the wing
            for dz in [Float(0.22), 0.62] {
                b.cylinder(from: V3(side * w * 0.9, -h * 0.8, g.wingLE + chord(0) * 0.4), to: le(0.48) + V3(0, -0.005, chord(0.48) * dz), r0: 0.006, r1: 0.006, seg: 6, color: cTail)
            }
        }
    } }
    if let uy = g.upperWingY {
        for side in [Float(-1), 1] {
            for dz in [Float(0.2), 0.75] {
                b.cylinder(from: V3(side * hs * 0.62, g.wingY + hs * 0.62 * tan(dih), g.wingLE + chord(0.62) * dz),
                           to: V3(side * hs * 0.62, uy + hs * 0.62 * tan(dih), g.wingLE - 0.07 + chord(0.62) * dz), r0: 0.006, r1: 0.006, seg: 6, color: alu)
                b.cylinder(from: V3(side * w * 0.8, h * 0.85, g.wingLE + chord(0) * dz), to: V3(side * w * 1.2, uy, g.wingLE - 0.07 + chord(0) * dz), r0: 0.005, r1: 0.005, seg: 6, color: alu)
            }
            // flying wires
            b.cylinder(from: V3(side * w, g.wingY, g.wingLE + chord(0) * 0.3), to: V3(side * hs * 0.62, uy + hs * 0.62 * tan(dih), g.wingLE - 0.07 + chord(0.62) * 0.3), r0: 0.0015, r1: 0.0015, seg: 4, color: alu)
        }
    }

    // --- tail
    let tailThick: Float = g.profile ? 0.03 : 0.085
    let sk = 1 - g.elevFrac
    var em = MeshBuilder()
    let eh = V3(0, stabY, g.stabZ + g.stabChord * sk)
    for side in [Float(-1), 1] {
        func sle(_ f: Float) -> V3 { V3(side * g.stabSpan / 2 * f, stabY, g.stabZ + 0.18 * g.stabChord * f) }
        func sch(_ f: Float) -> Float { g.stabChord * (1 - 0.18 * f) }
        b.wingPanel(le: sle, chord: sch, thick: tailThick, camber: 0, up: V3(0, 1, 0), f0: 0, f1: 1, c1: sk, strips: 4, roundTip: true, soft: g.scheme == 7, paint: tailPaint)
        em.wingPanel(le: sle, chord: sch, thick: tailThick, camber: 0, up: V3(0, 1, 0), f0: 0.02, f1: 0.99, c0: sk, strips: 4, roundTip: true, soft: g.scheme == 7, paint: tailPaint)
    }
    em.translate(-eh)
    parts.append(Part(mesh: em, pivot: eh, axis: V3(1, 0, 0), anim: .hinge(1, -g.elevThrow * deg)))
    let rk = 1 - g.rudFrac
    func fle(_ f: Float) -> V3 { V3(0, finY + g.finH * f, g.finZ + 0.32 * g.finChord * f) }
    func fch(_ f: Float) -> Float { g.finChord * (1 - 0.32 * f) }
    b.wingPanel(le: fle, chord: fch, thick: tailThick, camber: 0, up: V3(1, 0, 0), f0: 0, f1: 1, c1: rk, strips: 4, roundTip: true, soft: g.scheme == 7, paint: tailPaint)
    // dorsal fillet blending the fin into the fuselage
    if !g.profile { b.tri(V3(0, finY, g.finZ - g.finChord * 0.45), V3(0, finY, g.finZ + 0.02), V3(0, finY + g.finH * 0.3, g.finZ + 0.1 * g.finChord), tailPaint(0.1, 0.3, true)) }
    let rr = fle(0) + V3(0, 0, fch(0) * rk)
    var rm = MeshBuilder()
    rm.wingPanel(le: fle, chord: fch, thick: tailThick, camber: 0, up: V3(1, 0, 0), f0: 0.01, f1: 0.99, c0: rk, strips: 4, roundTip: true, soft: g.scheme == 7, paint: tailPaint)
    rm.translate(-rr)
    parts.append(Part(mesh: rm, pivot: rr, axis: normalize(fle(1) + V3(0, 0, fch(1) * rk) - rr), anim: .hinge(2, g.rudThrow * deg)))

    // --- propulsion
    if g.ducted {
        func ringAt(_ z: Float, _ r: Float) -> [V3] { (0..<14).map { j in let a = Float(j) / 14 * 2 * .pi; return V3(cos(a) * r, h * 0.3 + sin(a) * r, z) } }
        b.loft([ringAt(tz - 0.1, w * 0.5), ringAt(tz + 0.04, w * 0.42), ringAt(tz + 0.035, w * 0.36), ringAt(tz - 0.06, w * 0.3)], color: V4(0.2, 0.2, 0.22, 0.7), caps: false)
        b.cap(ringAt(tz - 0.06, w * 0.3), color: black)
        for side in [Float(-1), 1] where !g.noseIntake {
            // cheek intakes
            b.fuselage([(nz + 0.27 * L, w * 0.2, h * 0.36, -h * 0.1), (nz + 0.33 * L, w * 0.32, h * 0.5, -h * 0.1), (nz + 0.55 * L, w * 0.3, h * 0.5, 0)], x: side * w * 1.05, exp: 3, seg: 12,
                       paint: { t, _, _ in t < 0.08 ? black : cFuse })
        }
    } else {
        for (i, pp) in engines.enumerated() {
            let sr = g.profile ? Float(0.011) : (g.twin > 0 ? Float(0.032) : w * g.spinnerScale)
            if g.twin > 0 {
                b.fuselage([(pp.z, sr, sr, pp.y), (pp.z + 0.05, 0.044, 0.044, pp.y), (pp.z + 0.16, 0.046, 0.046, pp.y - 0.004), (pp.z + 0.3, 0.03, 0.03, pp.y - 0.008), (pp.z + 0.4, 0.008, 0.01, pp.y - 0.008)],
                           x: pp.x, exp: 2.2, seg: 12, paint: { t, _, _ in t < 0.18 ? cTail : cFuse })
            }
            var hub = MeshBuilder()
            spinner(&hub, base: .zero, radius: sr, length: sr * 1.5, color: g.spinnerColor.map { gl($0, film) } ?? cTail)
            let pr = makePropeller(diameter: g.propDia, blades: g.blades)
            parts.append(Part(mesh: hub, pivot: pp, axis: V3(0, 0, 1), anim: .spin(i)))
            parts.append(Part(mesh: pr.blades, pivot: pp + V3(0, 0, -sr * 0.45), axis: V3(0, 0, 1), anim: .spin(i), blur: 1))
            parts.append(Part(mesh: pr.disc, pivot: pp + V3(0, 0, -sr * 0.45), axis: V3(0, 0, 1), anim: .spin(i), blur: 2))
        }
    }

    // --- landing gear
    let rw = g.wheelR
    for wp in wheels {
        let c = wp + V3(0, rw, 0)
        let nose = abs(wp.x) < 0.01
        let top = nose ? V3(0, -h * 0.7, wp.z) : V3(wp.x * 0.3, -h * 0.75, wp.z)
        var gm = MeshBuilder()
        gm.wheel(center: c, radius: rw, width: rw * 0.7)
        if nose {
            gm.cylinder(from: top, to: c + V3(rw * 0.5, 0, 0), r0: 0.0045, r1: 0.004, seg: 6, color: alu)
            gm.cylinder(from: c - V3(rw * 0.5, 0, 0), to: c + V3(rw * 0.5, 0, 0), r0: 0.003, r1: 0.003, seg: 5, color: alu)
        } else {
            // flat sprung leg
            let s: Float = wp.x > 0 ? 1 : -1
            let foot = c - V3(s * rw * 0.45, 0, 0)
            gm.loft([[top + V3(0, 0, -0.02), top + V3(0, 0, 0.02), top + V3(0, -0.004, 0.02), top + V3(0, -0.004, -0.02)],
                     [foot + V3(0, 0.01, -0.012), foot + V3(0, 0.01, 0.012), foot + V3(-s * 0.004, 0.006, 0.012), foot + V3(-s * 0.004, 0.006, -0.012)]], color: g.pants ? cTail : alu)
            gm.cylinder(from: foot, to: c + V3(s * rw * 0.4, 0, 0), r0: 0.003, r1: 0.003, seg: 5, color: alu)
            if g.pants {
                gm.ellipsoid(center: c + V3(0, rw * 0.25, rw * 0.35), radii: V3(rw * 0.55, rw * 0.95, rw * 2.1), color: cTail, seg: 12, rings: 6)
            }
        }
        if g.retracts {
            gm.translate(-top)
            parts.append(Part(mesh: gm, pivot: top, axis: nose ? V3(1, 0, 0) : V3(0, 0, 1), anim: .hinge(4, (nose ? -88 : (wp.x > 0 ? -84 : 84)) * deg)))
        } else {
            b.append(gm)
        }
    }
    if g.gear == .none {
        // belly skid
        b.box(center: V3(0, -h * 0.98, nz + L * 0.3), size: V3(0.012, 0.01, L * 0.3), color: black)
    }
    parts.insert(Part(mesh: b), at: 0)
    return parts
}

// MARK: - Helicopter

func buildHeliModel(rotorR R: Float, body: V4, accent: V4) -> [Part] {
    var b = MeshBuilder()
    let cBody = gl(body, 0.85), cAcc = gl(accent, 0.85)
    // canopy
    b.fuselage([(-0.42, 0.012, 0.014, -0.06), (-0.4, 0.035, 0.04, -0.055), (-0.34, 0.058, 0.07, -0.04), (-0.25, 0.074, 0.098, -0.015), (-0.14, 0.082, 0.115, 0.005),
                (-0.03, 0.08, 0.118, 0.015), (0.05, 0.07, 0.1, 0.02), (0.1, 0.05, 0.07, 0.02)].map { (z: $0.0, w: $0.1, h: $0.2, y: $0.3) }, exp: 2.3, seg: 20) { t, _, sy in
        if sy > 0.3 && t > 0.12 && t < 0.62 { return glass }
        return sy > -0.5 && sy < -0.12 ? cAcc : cBody
    }
    // frame, motor, main gear
    for s in [Float(-1), 1] {
        b.box(center: V3(s * 0.034, -0.01, 0.12), size: V3(0.004, 0.13, 0.26), color: carbon)
        b.box(center: V3(s * 0.034, -0.09, 0.0), size: V3(0.004, 0.06, 0.3), color: carbon)
    }
    b.box(center: V3(0, -0.06, 0.02), size: V3(0.06, 0.05, 0.16), color: V4(0.15, 0.3, 0.6, 0.4))            // battery
    b.cylinder(from: V3(0, -0.02, 0.1), to: V3(0, 0.05, 0.1), r0: 0.026, r1: 0.026, seg: 12, color: V4(0.75, 0.3, 0.1, 0.8))   // motor
    b.cylinder(from: V3(0, 0.075, 0.03), to: V3(0, 0.083, 0.03), r0: 0.085, r1: 0.085, seg: 20, color: V4(0.85, 0.85, 0.8, 0.3))
    // mast, swashplate, head
    b.cylinder(from: V3(0, 0.05, 0), to: V3(0, 0.26, 0), r0: 0.006, r1: 0.006, seg: 8, color: alu)
    b.cylinder(from: V3(0, 0.15, 0), to: V3(0, 0.165, 0), r0: 0.03, r1: 0.03, seg: 12, color: alu)
    b.cylinder(from: V3(0, 0.165, 0), to: V3(0, 0.172, 0), r0: 0.022, r1: 0.022, seg: 12, color: black)
    for a in [Float(0.5), 2.6, 4.7] { b.cylinder(from: V3(cos(a) * 0.027, 0.09, sin(a) * 0.027), to: V3(cos(a) * 0.027, 0.15, sin(a) * 0.027), r0: 0.002, r1: 0.002, seg: 4, color: alu) }
    // tail boom, supports, gearbox, fins
    b.cylinder(from: V3(0, 0.035, 0.16), to: V3(0, 0.035, 0.99), r0: 0.0125, r1: 0.011, seg: 10, color: carbon)
    for s in [Float(-1), 1] { b.cylinder(from: V3(s * 0.034, -0.1, 0.14), to: V3(0, 0.03, 0.6), r0: 0.003, r1: 0.003, seg: 5, color: carbon) }
    b.box(center: V3(0, 0.035, 0.985), size: V3(0.03, 0.035, 0.05), color: black)
    b.wingPanel(le: { V3(0, 0.03 + 0.19 * $0, 0.9 + 0.09 * $0) }, chord: { 0.1 - 0.05 * $0 }, thick: 0.06, camber: 0, up: V3(1, 0, 0), f0: 0, f1: 1, strips: 3, roundTip: true) { f, _, _ in f > 0.6 ? cAcc : cBody }
    b.wingPanel(le: { V3(0, 0.03 - 0.14 * $0, 0.92 + 0.06 * $0) }, chord: { 0.075 - 0.04 * $0 }, thick: 0.06, camber: 0, up: V3(1, 0, 0), f0: 0, f1: 1, strips: 3, roundTip: true) { _, _, _ in cBody }
    for s in [Float(-1), 1] {
        b.wingPanel(le: { V3(s * 0.11 * $0, 0.035, 0.63) }, chord: { 0.065 - 0.02 * $0 }, thick: 0.06, camber: 0, up: V3(0, 1, 0), f0: 0, f1: 1, strips: 2, roundTip: true) { _, _, _ in cBody }
    }
    // skids with upturned tips
    for x in [Float(-0.125), 0.125] {
        let pts = [V3(x, -0.15, -0.3), V3(x, -0.19, -0.25), V3(x, -0.195, -0.18), V3(x, -0.195, 0.2)]
        for i in 0..<3 { b.cylinder(from: pts[i], to: pts[i + 1], r0: 0.0065, r1: 0.0065, seg: 7, color: white05) }
        for z in [Float(-0.13), 0.1] {
            b.cylinder(from: V3(x, -0.195, z), to: V3(x * 0.75, -0.13, z), r0: 0.006, r1: 0.006, seg: 6, color: black)
            b.cylinder(from: V3(x * 0.75, -0.13, z), to: V3(0, -0.115, z), r0: 0.006, r1: 0.006, seg: 6, color: black)
        }
    }
    var parts = [Part(mesh: b)]
    // main rotor: head with blade grips, two airfoil blades, and the disc seen at speed
    var head = MeshBuilder()
    head.box(center: .zero, size: V3(0.11, 0.024, 0.03), color: alu)
    head.cylinder(from: V3(0, 0.012, 0), to: V3(0, 0.03, 0), r0: 0.012, r1: 0.008, seg: 8, color: black)
    for s in [Float(-1), 1] { head.box(center: V3(s * 0.075, 0, 0), size: V3(0.05, 0.02, 0.034), color: black) }
    parts.append(Part(mesh: head, pivot: V3(0, 0.25, 0), axis: V3(0, 1, 0), anim: .spin(0)))
    var blades = MeshBuilder()
    for s in [Float(-1), 1] {
        blades.wingPanel(le: { V3(s * (0.095 + (R - 0.095) * $0), 0, -s * 0.017) }, chord: { _ in s * 0.056 }, thick: 0.12, camber: 0, up: V3(0, 1, 0),
                         f0: 0, f1: 1, strips: 8, roundTip: true) { f, _, _ in f > 0.9 ? V4(0.95, 0.95, 0.95, 0.5) : (f > 0.82 ? V4(0.85, 0.1, 0.1, 0.5) : black) }
    }
    parts.append(Part(mesh: blades, pivot: V3(0, 0.25, 0), axis: V3(0, 1, 0), anim: .spin(0), blur: 1))
    let toY = M4.rotation(-.pi / 2, V3(1, 0, 0))
    var disc = MeshBuilder(); disc.append(makePropeller(diameter: 2 * R, blades: 2, tip: V4(0.9, 0.9, 0.9, 1)).disc, toY)
    parts.append(Part(mesh: disc, pivot: V3(0, 0.25, 0), axis: V3(0, 1, 0), anim: .spin(0), blur: 2))
    // tail rotor
    let toX = M4.rotation(.pi / 2, V3(0, 1, 0))
    let tr = makePropeller(diameter: 0.25, blades: 2, color: V4(0.9, 0.9, 0.9, 0.4), tip: V4(0.9, 0.1, 0.1, 0.4), pitch: 0.12, chordScale: 1.3)
    var tb = MeshBuilder(); tb.append(tr.blades, toX)
    var td = MeshBuilder(); td.append(tr.disc, toX)
    parts.append(Part(mesh: tb, pivot: V3(0.03, 0.035, 0.985), axis: V3(1, 0, 0), anim: .spin(1), blur: 1))
    parts.append(Part(mesh: td, pivot: V3(0.03, 0.035, 0.985), axis: V3(1, 0, 0), anim: .spin(1), blur: 2))
    return parts
}
private let white05 = V4(0.9, 0.9, 0.9, 0.5)

// MARK: - Quadcopter

func buildQuadModel(motors: [V3], shell: V4, front: V4, rear: V4) -> [Part] {
    var b = MeshBuilder()
    let cShell = gl(shell, 0.9)
    // carbon plates and stack
    b.box(center: V3(0, 0.0, 0), size: V3(0.1, 0.004, 0.2), color: carbon)
    b.box(center: V3(0, 0.03, 0), size: V3(0.09, 0.004, 0.18), color: carbon)
    for (x, z) in [(Float(-0.035), Float(-0.07)), (0.035, -0.07), (0.035, 0.07), (-0.035, 0.07)] {
        b.cylinder(from: V3(x, 0, z), to: V3(x, 0.03, z), r0: 0.004, r1: 0.004, seg: 6, color: V4(0.8, 0.15, 0.15, 0.8))
    }
    b.box(center: V3(0, 0.015, 0.01), size: V3(0.05, 0.02, 0.05), color: V4(0.05, 0.25, 0.1, 0.3))
    // shell
    b.fuselage([(-0.105, 0.02, 0.012, 0.04), (-0.085, 0.042, 0.026, 0.047), (-0.03, 0.05, 0.034, 0.052), (0.05, 0.048, 0.032, 0.05), (0.095, 0.03, 0.018, 0.045)].map { (z: $0.0, w: $0.1, h: $0.2, y: $0.3) },
               exp: 2.4, seg: 16) { t, _, sy in t < 0.3 && sy > -0.2 ? glass : cShell }
    // battery slung underneath, with strap
    b.box(center: V3(0, -0.022, 0.0), size: V3(0.045, 0.034, 0.13), color: V4(0.12, 0.12, 0.14, 0.3))
    b.box(center: V3(0, -0.02, 0.0), size: V3(0.049, 0.04, 0.02), color: V4(0.9, 0.5, 0.05, 0.2))
    // camera
    b.box(center: V3(0, 0.0, -0.115), size: V3(0.04, 0.036, 0.03), color: black)
    b.cylinder(from: V3(0, 0.0, -0.13), to: V3(0, 0.0, -0.142), r0: 0.012, r1: 0.011, seg: 10, color: glass)
    // antennas
    for s in [Float(-1), 1] { b.cylinder(from: V3(s * 0.02, 0.03, 0.09), to: V3(s * 0.05, 0.1, 0.12), r0: 0.0015, r1: 0.0015, seg: 4, color: black) }
    var parts: [Part] = []
    let toY = M4.rotation(-.pi / 2, V3(1, 0, 0))
    for (i, m) in motors.enumerated() {
        let col = gl(m.z < 0 ? front : rear, 0.6)
        let root = V3(m.x * 0.22, 0.015, m.z * 0.3)
        let dir = normalize(V3(m.x, 0, m.z) - V3(root.x, 0, root.z)), side = V3(-dir.z, 0, dir.x)
        // flat arm
        b.loft([[root + side * 0.012 + V3(0, 0.005, 0), root - side * 0.012 + V3(0, 0.005, 0), root - side * 0.012 - V3(0, 0.005, 0), root + side * 0.012 - V3(0, 0.005, 0)],
                [V3(m.x, 0.015, m.z) + side * 0.009 + V3(0, 0.004, 0), V3(m.x, 0.015, m.z) - side * 0.009 + V3(0, 0.004, 0), V3(m.x, 0.015, m.z) - side * 0.009 - V3(0, 0.004, 0), V3(m.x, 0.015, m.z) + side * 0.009 - V3(0, 0.004, 0)]], color: col)
        // motor: base and bell
        b.cylinder(from: V3(m.x, 0.012, m.z), to: V3(m.x, 0.024, m.z), r0: 0.017, r1: 0.017, seg: 12, color: black)
        b.cylinder(from: V3(m.x, 0.025, m.z), to: V3(m.x, 0.043, m.z), r0: 0.0185, r1: 0.016, seg: 12, color: V4(0.75, 0.76, 0.8, 0.9))
        b.cylinder(from: V3(m.x, 0.043, m.z), to: V3(m.x, 0.054, m.z), r0: 0.004, r1: 0.004, seg: 6, color: alu)
        // landing leg and status LED
        b.cylinder(from: V3(m.x * 0.8, 0.01, m.z * 0.8), to: V3(m.x * 0.86, -0.085, m.z * 0.86), r0: 0.005, r1: 0.004, seg: 6, color: black)
        b.blob(center: V3(m.x * 0.86, -0.088, m.z * 0.86), radii: V3(0.008, 0.006, 0.008), color: rubber, seg: 6, rings: 3, seed: 1, lump: 0)
        b.box(center: V3(m.x * 0.6, 0.007, m.z * 0.6), size: V3(0.012, 0.004, 0.012), color: m.z < 0 ? V4(1, 0.15, 0.1, 1) : V4(0.2, 1, 0.3, 1))
        let pr = makePropeller(diameter: 0.25, blades: 2, color: m.z < 0 ? gl(shell, 0.4) : black, tip: m.z < 0 ? gl(shell, 0.4) : V4(0.9, 0.9, 0.9, 0.4), pitch: 0.16)
        var pb = MeshBuilder(); pb.append(pr.blades, toY)
        var pd = MeshBuilder(); pd.append(pr.disc, toY)
        parts.append(Part(mesh: pb, pivot: V3(m.x, 0.052, m.z), axis: V3(0, 1, 0), anim: .spin(i), blur: 1))
        parts.append(Part(mesh: pd, pivot: V3(m.x, 0.052, m.z), axis: V3(0, 1, 0), anim: .spin(i), blur: 2))
    }
    parts.insert(Part(mesh: b), at: 0)
    return parts
}
