import simd
import Foundation

enum GearType { case tricycle, taildragger, none }

/// Parametric airplane: the same numbers drive both the aerodynamic panels and the visual model.
struct PlaneGeom {
    var name = "", blurb = ""
    var mass: Float = 2
    var span: Float = 1.5, rootChord: Float = 0.26, tipChord: Float = 0.26
    var wingY: Float = 0.1, wingLE: Float = -0.05, sweep: Float = 0
    var dihedral: Float = 4, incidence: Float = 2, camber: Float = 3
    var thick: Float = 0.13, stall: Float = 0.25, cd0: Float = 0.014
    var noseZ: Float = -0.48, fuseLen: Float = 1.4, fuseW: Float = 0.13, fuseH: Float = 0.17
    var stabSpan: Float = 0.56, stabChord: Float = 0.16, stabZ: Float = 0.74, elevFrac: Float = 0.4
    var finH: Float = 0.24, finChord: Float = 0.18, finZ: Float = 0.72, rudFrac: Float = 0.4
    var ailFrac: Float = 0.25, ailStart: Float = 0.5
    var ailThrow: Float = 20, elevThrow: Float = 20, rudThrow: Float = 25
    var thrust: Float = 18, pitchSpeed: Float = 24, propDia: Float = 0.28
    var washTail: Float = 0.5, washWing: Float = 0.2
    var ducted = false
    var twin: Float = 0             // engine offset from centreline; 0 = single nose engine
    var upperWingY: Float? = nil    // set for a biplane
    var gear = GearType.tricycle
    var gearH: Float = 0.2, track: Float = 0.2
    var cdA: Float = 0.012
    var handLaunch = false
    var fuse = rgb(0.95, 0.95, 0.93), wingTop = rgb(0.85, 0.12, 0.1), wingBottom = rgb(0.95, 0.85, 0.2)
    var tail = rgb(0.85, 0.12, 0.1), accent = rgb(0.98, 0.98, 0.98)
    var sound: Float = 150
}

private func flapTau(_ frac: Float) -> Float { min(0.9 * sqrt(frac), 0.8) }

func makeAirplane(_ g: PlaneGeom) -> AircraftSpec {
    let hs = g.span / 2
    let dih = g.dihedral * deg, inc = g.incidence * deg
    let area = (g.rootChord + g.tipChord) / 2 * g.span
    let ar = g.span * g.span / area
    let slope = 2 * Float.pi * ar / (ar + 2)
    let L = g.fuseLen, nz = g.noseZ, tz = g.noseZ + g.fuseLen
    let w = g.fuseW / 2, h = g.fuseH / 2
    let stabY = h * 0.3
    func chord(_ f: Float) -> Float { lerp(g.rootChord, g.tipChord, f) }

    let wings: [(y: Float, z: Float)] = g.upperWingY.map { [(g.wingY, Float(0)), ($0, Float(-0.07))] } ?? [(g.wingY, Float(0))]
    let wingEff: Float = wings.count > 1 ? 0.85 : 1

    // --- Aerodynamics
    var surfaces: [AeroSurface] = []
    for wg in wings { for side in [Float(-1), 1] {
        for f0 in [Float(0), 0.5] {
            let fm = f0 + 0.25, ch = chord(fm), x = side * hs * fm
            let n0 = V3(-sin(dih) * side, cos(dih), 0), c0 = V3(0, 0, -1)
            var s = AeroSurface(pos: V3(x, wg.y + abs(x) * tan(dih), g.wingLE + wg.z + g.sweep * fm + 0.25 * ch),
                                normal: n0 * cos(inc) - c0 * sin(inc), chordDir: c0 * cos(inc) + n0 * sin(inc),
                                area: ch * hs * 0.5 * wingEff, ar: ar, liftSlope: slope, stall: g.stall, cd0: g.cd0, alpha0: g.camber * deg)
            if f0 >= g.ailStart - 0.01 { s.flapCh = 0; s.flapGain = -side * flapTau(g.ailFrac) * g.ailThrow * deg }
            s.wash = f0 == 0 ? g.washWing : 0
            surfaces.append(s)
        }
    } }
    let sar = g.stabSpan / g.stabChord
    for side in [Float(-1), 1] {
        surfaces.append(AeroSurface(pos: V3(side * g.stabSpan / 4, stabY, g.stabZ + 0.25 * g.stabChord), normal: V3(0, 1, 0),
                                    area: g.stabSpan * g.stabChord / 2, ar: sar, liftSlope: 2 * .pi * sar / (sar + 2) * 0.85,
                                    stall: 0.27, cd0: 0.012, flapCh: 1, flapGain: -flapTau(g.elevFrac) * g.elevThrow * deg, wash: g.washTail))
    }
    let far = 1.6 * g.finH / g.finChord
    surfaces.append(AeroSurface(pos: V3(0, stabY + g.finH / 2, g.finZ + 0.25 * g.finChord), normal: V3(1, 0, 0),
                                area: g.finH * g.finChord, ar: far, liftSlope: 2 * .pi * far / (far + 2),
                                stall: 0.27, cd0: 0.012, flapCh: 2, flapGain: -flapTau(g.rudFrac) * g.rudThrow * deg, wash: g.washTail))
    for (n, a) in [(V3(1, 0, 0), L * g.fuseH * 0.75), (V3(0, 1, 0), L * g.fuseW * 0.75)] {
        surfaces.append(AeroSurface(pos: V3(0, 0, nz + 0.42 * L), normal: n, area: a, ar: 0.4, liftSlope: 0.9, stall: 0.6, cd0: 0))
    }

    // --- Contacts
    var contacts: [Contact] = []
    let rw: Float = 0.035
    var wheels: [V3] = []
    switch g.gear {
    case .tricycle:
        wheels = [V3(0, -g.gearH, nz * 0.55), V3(g.track, -g.gearH, 0.08), V3(-g.track, -g.gearH, 0.08)]
        contacts.append(Contact(pos: wheels[0], wheel: true, steer: -1, crashSpeed: 4.5))
        contacts.append(Contact(pos: wheels[1], wheel: true, crashSpeed: 4.5))
        contacts.append(Contact(pos: wheels[2], wheel: true, crashSpeed: 4.5))
    case .taildragger:
        wheels = [V3(g.track, -g.gearH, g.wingLE - 0.03), V3(-g.track, -g.gearH, g.wingLE - 0.03), V3(0, -h * 0.4 - 0.03, tz - 0.06)]
        contacts.append(Contact(pos: wheels[0], wheel: true, crashSpeed: 4.5))
        contacts.append(Contact(pos: wheels[1], wheel: true, crashSpeed: 4.5))
        contacts.append(Contact(pos: wheels[2], wheel: true, steer: 1, crashSpeed: 4.5))
    case .none:
        contacts.append(Contact(pos: V3(0, -h, nz * 0.5), crashSpeed: 3.5, mu: 0.4))
        contacts.append(Contact(pos: V3(0, -h * 0.8, 0.25), crashSpeed: 3.5, mu: 0.4))
    }
    let tipY = g.wingY + hs * tan(dih)
    contacts.append(Contact(pos: V3(0, 0, nz - 0.03), crashSpeed: 2.5))
    contacts.append(Contact(pos: V3(0, -h * 0.9, nz * 0.7), crashSpeed: 3))
    contacts.append(Contact(pos: V3(0, h * 0.2, tz), crashSpeed: 3.5))
    contacts.append(Contact(pos: V3(hs, tipY, g.wingLE + g.sweep + g.tipChord / 2), crashSpeed: 3))
    contacts.append(Contact(pos: V3(-hs, tipY, g.wingLE + g.sweep + g.tipChord / 2), crashSpeed: 3))
    contacts.append(Contact(pos: V3(0, stabY + g.finH, g.finZ + g.finChord * 0.6), crashSpeed: 2.5))
    contacts.append(Contact(pos: V3(0, max(h, g.wingY) + 0.03, nz + 0.3 * L), crashSpeed: 2.5))

    let engines: [V3] = g.twin > 0 ? [V3(g.twin, g.wingY, g.wingLE - 0.1), V3(-g.twin, g.wingY, g.wingLE - 0.1)] : [V3(0, 0, nz)]

    // --- Visual model
    var parts: [Part] = []
    var b = MeshBuilder()
    b.body([(nz, w * 0.35, h * 0.35, 0), (nz + 0.04 * L, w * 0.78, h * 0.78, 0), (nz + 0.22 * L, w, h, 0),
            (nz + 0.45 * L, w * 0.95, h * 0.95, 0), (nz + 0.75 * L, w * 0.5, h * 0.55, h * 0.12), (tz, w * 0.15, h * 0.3, h * 0.3)], color: g.fuse)
    b.ellipsoid(center: V3(0, h * 0.75, nz + 0.3 * L), radii: V3(w * 0.72, h * 0.6, L * 0.11), color: rgb(0.1, 0.16, 0.3))
    for wg in wings { for side in [Float(-1), 1] {
        let up = V3(-sin(dih) * side, cos(dih), 0)
        func le(_ f: Float) -> V3 { V3(side * hs * f, wg.y + hs * f * tan(dih), g.wingLE + wg.z + g.sweep * f) }
        let a0 = g.ailStart, k = 1 - g.ailFrac
        if a0 > 0.01 {
            b.wing(root: le(0), tip: le(a0), rootChord: chord(0), tipChord: chord(a0), thick: g.thick, up: up, top: g.wingTop, bottom: g.wingBottom)
        }
        b.wing(root: le(a0), tip: le(1), rootChord: chord(a0) * k, tipChord: chord(1) * k, thick: g.thick / k, up: up, top: g.wingTop, bottom: g.wingBottom)
        let r0 = le(a0) + V3(0, 0, chord(a0) * k), r1 = le(1) + V3(0, 0, chord(1) * k)
        var am = MeshBuilder()
        am.wing(root: r0, tip: r1, rootChord: chord(a0) * g.ailFrac, tipChord: chord(1) * g.ailFrac, thick: g.thick * 1.2, up: up, top: g.accent, bottom: g.wingBottom)
        am.translate(-r0)
        parts.append(Part(mesh: am, pivot: r0, axis: normalize(r1 - r0) * side, anim: .hinge(0, -side * g.ailThrow * deg)))
        // wing tip stripe marker for orientation
        b.box(center: le(1) + V3(side * 0.004, 0, g.tipChord * 0.5), size: V3(0.012, g.thick * g.tipChord * 1.3, g.tipChord), color: side > 0 ? rgb(0.1, 0.7, 0.2) : rgb(0.9, 0.1, 0.1))
    } }
    if let uy = g.upperWingY {
        let grey = rgb(0.75, 0.75, 0.78)
        for side in [Float(-1), 1] {
            for dz in [Float(0.2), 0.75] {
                b.cylinder(from: V3(side * hs * 0.62, g.wingY + hs * 0.62 * tan(dih), g.wingLE + chord(0.62) * dz),
                           to: V3(side * hs * 0.62, uy + hs * 0.62 * tan(dih), g.wingLE - 0.07 + chord(0.62) * dz), r0: 0.006, r1: 0.006, seg: 5, color: grey)
            }
            b.cylinder(from: V3(side * w * 0.8, h * 0.8, g.wingLE + 0.05), to: V3(side * w * 1.3, uy, g.wingLE + 0.02), r0: 0.005, r1: 0.005, seg: 5, color: grey)
        }
    }
    // stabiliser + elevator
    let sk = 1 - g.elevFrac
    var em = MeshBuilder()
    let eh = V3(0, stabY, g.stabZ + g.stabChord * sk)
    for side in [Float(-1), 1] {
        let tipX = side * g.stabSpan / 2
        b.wing(root: V3(0, stabY, g.stabZ), tip: V3(tipX, stabY, g.stabZ + 0.15 * g.stabChord), rootChord: g.stabChord * sk, tipChord: g.stabChord * sk * 0.85,
               thick: 0.09, up: V3(0, 1, 0), top: g.tail, bottom: g.wingBottom)
        em.wing(root: eh, tip: V3(tipX, stabY, eh.z), rootChord: g.stabChord * g.elevFrac, tipChord: g.stabChord * g.elevFrac * 0.9,
                thick: 0.12, up: V3(0, 1, 0), top: g.accent, bottom: g.wingBottom)
    }
    em.translate(-eh)
    parts.append(Part(mesh: em, pivot: eh, axis: V3(1, 0, 0), anim: .hinge(1, -g.elevThrow * deg)))
    // fin + rudder
    let rk = 1 - g.rudFrac
    b.wing(root: V3(0, stabY, g.finZ), tip: V3(0, stabY + g.finH, g.finZ + 0.3 * g.finChord), rootChord: g.finChord * rk, tipChord: g.finChord * rk * 0.7,
           thick: 0.09, up: V3(1, 0, 0), top: g.tail, bottom: g.tail)
    let rr = V3(0, stabY, g.finZ + g.finChord * rk), rt = V3(0, stabY + g.finH, g.finZ + 0.3 * g.finChord + g.finChord * rk * 0.7)
    var rm = MeshBuilder()
    rm.wing(root: rr, tip: rt, rootChord: g.finChord * g.rudFrac, tipChord: g.finChord * g.rudFrac * 0.8, thick: 0.12, up: V3(1, 0, 0), top: g.accent, bottom: g.accent)
    rm.translate(-rr)
    parts.append(Part(mesh: rm, pivot: rr, axis: normalize(rt - rr), anim: .hinge(2, g.rudThrow * deg)))
    // propulsion
    if g.ducted {
        b.cylinder(from: V3(0, 0, tz - 0.12), to: V3(0, 0, tz + 0.03), r0: w * 0.55, r1: w * 0.45, color: rgb(0.15, 0.15, 0.16))
        for side in [Float(-1), 1] {
            b.cylinder(from: V3(side * w * 1.05, 0, nz + 0.3 * L), to: V3(side * w * 0.9, 0, nz + 0.5 * L), r0: w * 0.35, r1: w * 0.45, color: rgb(0.2, 0.2, 0.22))
        }
    } else {
        let tw = simd_quatf(angle: 0.35, axis: V3(0, 1, 0))
        for (i, pp) in engines.enumerated() {
            let sr = g.twin > 0 ? Float(0.03) : w * 0.36
            if g.twin > 0 { b.body([(pp.z, sr, sr, pp.y), (pp.z + 0.12, 0.042, 0.042, pp.y), (pp.z + 0.34, 0.012, 0.012, pp.y)].map { (z: $0.0, w: $0.1, h: $0.2, y: $0.3) }, seg: 8, color: g.tail, x: pp.x) }
            b.cylinder(from: pp - V3(0, 0, 0.055), to: pp, r0: 0.003, r1: sr, color: g.tail)
            var pm = MeshBuilder()
            pm.box(center: V3(0, g.propDia / 4, 0), size: V3(g.propDia * 0.09, g.propDia / 2, 0.006), color: rgb(0.12, 0.12, 0.12), rot: tw)
            pm.box(center: V3(0, -g.propDia / 4, 0), size: V3(g.propDia * 0.09, g.propDia / 2, 0.006), color: rgb(0.12, 0.12, 0.12), rot: tw.inverse)
            parts.append(Part(mesh: pm, pivot: pp - V3(0, 0, 0.02), axis: V3(0, 0, 1), anim: .spin(i)))
        }
    }
    for wp in wheels {
        let c = wp + V3(0, rw, 0)
        b.cylinder(from: c - V3(0.012, 0, 0), to: c + V3(0.012, 0, 0), r0: rw, r1: rw, seg: 12, color: rgb(0.08, 0.08, 0.08))
        b.cylinder(from: c, to: V3(wp.x * 0.35, -h * 0.6, wp.z), r0: 0.006, r1: 0.008, seg: 6, color: rgb(0.7, 0.7, 0.72))
    }
    parts.insert(Part(mesh: b), at: 0)

    var spec = AircraftSpec(name: g.name, kind: .airplane, blurb: g.blurb, mass: g.mass,
                            inertia: V3(g.mass * pow(0.19 * L, 2), 0, g.mass * pow(0.11 * g.span, 2)), span: g.span)
    spec.inertia.y = spec.inertia.x + spec.inertia.z * 0.9
    spec.surfaces = surfaces
    spec.props = engines.map { Propulsor(pos: $0, staticThrust: g.thrust / Float(engines.count), pitchSpeed: g.pitchSpeed, diameter: g.propDia, torqueK: g.ducted || g.twin > 0 ? 0 : 0.03) }
    if g.ducted { for i in spec.surfaces.indices { spec.surfaces[i].wash = 0 } }
    spec.contacts = contacts
    spec.cdA = g.cdA
    spec.handLaunch = g.handLaunch
    spec.parts = parts
    spec.soundBase = g.sound
    spec.eyeOffset = V3(0, max(h, g.wingY) + 0.1, nz + 0.35 * L)
    return spec
}

/// Uniformly rescale an aircraft's geometry (visuals, contacts, rotor layout).
func rescale(_ spec: AircraftSpec, _ k: Float) -> AircraftSpec {
    var s = spec
    let m = M4(diagonal: V4(k, k, k, 1))
    for i in s.parts.indices {
        var b = MeshBuilder(); b.append(s.parts[i].mesh, m)
        s.parts[i].mesh = b; s.parts[i].pivot *= k
    }
    for i in s.contacts.indices { s.contacts[i].pos *= k }
    s.span *= k; s.eyeOffset *= k
    if var mu = s.multi { mu.motors = mu.motors.map { $0 * k }; s.multi = mu }
    if var h = s.heli { h.rotorR *= k; h.hub *= k; h.rpm /= k; s.heli = h }
    return s
}

func makeQuad() -> AircraftSpec {
    let a: Float = 0.16
    let motors = [V3(a, 0.03, -a), V3(-a, 0.03, -a), V3(-a, 0.03, a), V3(a, 0.03, a)]
    var s = AircraftSpec(name: "Quad X450", kind: .multirotor, blurb: "450-class quadcopter, self-level or acro", mass: 1.2,
                         inertia: V3(0.012, 0.022, 0.012), span: 0.55)
    s.multi = MultiSpec(motors: motors, dirs: [1, -1, 1, -1], maxThrust: 8)
    s.cdA = 0.02
    s.modes = ["Self-level", "Acro"]
    s.soundBase = 210
    for m in motors { s.contacts.append(Contact(pos: V3(m.x * 0.8, -0.09, m.z * 0.8), crashSpeed: 4, mu: 0.6)) }
    for m in motors { s.contacts.append(Contact(pos: V3(m.x * 1.6, 0.06, m.z * 1.6), crashSpeed: 3, mu: 0.6)) }
    s.contacts.append(Contact(pos: V3(0, 0.09, 0), crashSpeed: 2.5))
    var b = MeshBuilder()
    b.box(center: V3(0, 0.015, 0), size: V3(0.11, 0.045, 0.2), color: rgb(0.13, 0.13, 0.15))
    b.ellipsoid(center: V3(0, 0.045, -0.02), radii: V3(0.05, 0.035, 0.09), color: rgb(0.95, 0.55, 0.05))
    b.box(center: V3(0, 0.0, -0.11), size: V3(0.05, 0.04, 0.03), color: rgb(0.05, 0.05, 0.05))
    var parts: [Part] = []
    for (i, m) in motors.enumerated() {
        let front = m.z < 0
        let col = front ? rgb(0.9, 0.1, 0.1) : rgb(0.95, 0.95, 0.95)
        b.cylinder(from: V3(m.x * 0.2, 0.015, m.z * 0.2), to: V3(m.x, 0.015, m.z), r0: 0.011, r1: 0.009, seg: 6, color: col)
        b.cylinder(from: V3(m.x, 0.0, m.z), to: V3(m.x, 0.045, m.z), r0: 0.02, r1: 0.02, seg: 8, color: rgb(0.3, 0.3, 0.32))
        b.cylinder(from: V3(m.x * 0.8, 0.01, m.z * 0.8), to: V3(m.x * 0.8, -0.09, m.z * 0.8), r0: 0.006, r1: 0.006, seg: 5, color: rgb(0.2, 0.2, 0.2))
        var pm = MeshBuilder()
        pm.box(center: .zero, size: V3(0.25, 0.004, 0.024), color: front ? rgb(0.95, 0.4, 0.05) : rgb(0.15, 0.15, 0.15))
        parts.append(Part(mesh: pm, pivot: V3(m.x, 0.052, m.z), axis: V3(0, 1, 0), anim: .spin(i)))
    }
    parts.insert(Part(mesh: b), at: 0)
    s.parts = parts
    s.eyeOffset = V3(0, 0.02, -0.14)
    return s
}

func makeHeli() -> AircraftSpec {
    let R: Float = 0.62
    var s = AircraftSpec(name: "Kestrel 550", kind: .helicopter, blurb: "Flybarless collective-pitch 3D helicopter", mass: 3.2,
                         inertia: V3(0.10, 0.09, 0.04), span: 2 * R)
    s.heli = HeliSpec(rotorR: R, hub: V3(0, 0.24, 0), rpm: 2000, sigma: 0.058, collMax: 11 * deg,
                      maxMoment: 9, tailMax: 3.5, maxRate: 5, maxYaw: 7)
    s.cdA = 0.03
    s.soundBase = 67
    for x in [Float(-0.12), 0.12] { for z in [Float(-0.17), 0.13] { s.contacts.append(Contact(pos: V3(x, -0.2, z), crashSpeed: 4, mu: 0.6)) } }
    for p in [V3(R, 0.24, 0), V3(-R, 0.24, 0), V3(0, 0.24, R), V3(0, 0.24, -R)] { s.contacts.append(Contact(pos: p, crashSpeed: 0.8)) }
    s.contacts.append(Contact(pos: V3(0, -0.02, 1.0), crashSpeed: 2.5))
    s.contacts.append(Contact(pos: V3(0, -0.05, -0.38), crashSpeed: 2.5))
    var b = MeshBuilder()
    let yel = rgb(0.98, 0.8, 0.05), dark = rgb(0.12, 0.12, 0.14)
    b.body([(-0.38, 0.01, 0.01, -0.03), (-0.3, 0.05, 0.06, -0.02), (-0.12, 0.075, 0.1, 0), (0.08, 0.06, 0.09, 0.01), (0.2, 0.03, 0.04, 0.03)], color: yel)
    b.ellipsoid(center: V3(0, 0.04, -0.22), radii: V3(0.05, 0.045, 0.1), color: rgb(0.08, 0.1, 0.2))
    b.box(center: V3(0, 0.02, 0.1), size: V3(0.08, 0.16, 0.22), color: dark)
    b.cylinder(from: V3(0, 0.03, 0.15), to: V3(0, 0.03, 0.98), r0: 0.013, r1: 0.011, seg: 8, color: dark)
    b.wing(root: V3(0, 0.03, 0.9), tip: V3(0, 0.2, 0.98), rootChord: 0.1, tipChord: 0.05, thick: 0.08, up: V3(1, 0, 0), top: yel, bottom: yel)
    b.wing(root: V3(0, 0.03, 0.92), tip: V3(0, -0.1, 0.97), rootChord: 0.07, tipChord: 0.04, thick: 0.08, up: V3(1, 0, 0), top: yel, bottom: yel)
    b.wing(root: V3(-0.1, 0.03, 0.66), tip: V3(0.1, 0.03, 0.66), rootChord: 0.06, tipChord: 0.06, thick: 0.08, up: V3(0, 1, 0), top: yel, bottom: dark)
    b.cylinder(from: V3(0, 0.1, 0), to: V3(0, 0.25, 0), r0: 0.008, r1: 0.008, seg: 6, color: rgb(0.7, 0.7, 0.72))
    for x in [Float(-0.12), 0.12] {
        b.cylinder(from: V3(x, -0.195, -0.24), to: V3(x, -0.195, 0.2), r0: 0.007, r1: 0.007, seg: 6, color: dark)
        for z in [Float(-0.12), 0.1] { b.cylinder(from: V3(x, -0.195, z), to: V3(x * 0.4, -0.06, z), r0: 0.006, r1: 0.006, seg: 5, color: dark) }
    }
    var rotor = MeshBuilder()
    rotor.box(center: V3(R / 2 + 0.03, 0, 0), size: V3(R - 0.06, 0.006, 0.055), color: rgb(0.1, 0.1, 0.1))
    rotor.box(center: V3(-R / 2 - 0.03, 0, 0), size: V3(R - 0.06, 0.006, 0.055), color: rgb(0.1, 0.1, 0.1))
    rotor.box(center: V3(R - 0.03, 0, 0), size: V3(0.06, 0.007, 0.056), color: rgb(0.95, 0.95, 0.95))
    rotor.box(center: V3(-R + 0.03, 0, 0), size: V3(0.06, 0.007, 0.056), color: rgb(0.9, 0.1, 0.1))
    rotor.cylinder(from: V3(0, -0.015, 0), to: V3(0, 0.02, 0), r0: 0.03, r1: 0.025, seg: 8, color: rgb(0.6, 0.6, 0.62))
    var tail = MeshBuilder()
    tail.box(center: .zero, size: V3(0.004, 0.24, 0.026), color: rgb(0.9, 0.9, 0.9))
    s.parts = [Part(mesh: b), Part(mesh: rotor, pivot: V3(0, 0.25, 0), axis: V3(0, 1, 0), anim: .spin(0)),
               Part(mesh: tail, pivot: V3(0.03, 0.03, 0.98), axis: V3(1, 0, 0), anim: .spin(1))]
    s.eyeOffset = V3(0, -0.02, -0.42)
    return s
}

enum AircraftLibrary {
    static let all: [AircraftSpec] = {
        var trainer = PlaneGeom()
        trainer.name = "Skylark Trainer"; trainer.blurb = "Stable high-wing trainer with tricycle gear"
        trainer.mass = 2.2; trainer.span = 1.6; trainer.sound = 140

        var acro = PlaneGeom()
        acro.name = "Vortex 3D"; acro.blurb = "Unlimited aerobat: hovers, knife-edges and tumbles"
        acro.mass = 1.5; acro.span = 1.25; acro.rootChord = 0.34; acro.tipChord = 0.22
        acro.wingY = 0; acro.wingLE = -0.075; acro.dihedral = 0; acro.incidence = 0; acro.camber = 0; acro.stall = 0.24
        acro.noseZ = -0.42; acro.fuseLen = 1.2; acro.fuseW = 0.1; acro.fuseH = 0.22
        acro.stabSpan = 0.5; acro.stabChord = 0.2; acro.stabZ = 0.6; acro.elevFrac = 0.55
        acro.finH = 0.26; acro.finChord = 0.24; acro.finZ = 0.56; acro.rudFrac = 0.6
        acro.ailFrac = 0.35; acro.ailStart = 0; acro.ailThrow = 34; acro.elevThrow = 42; acro.rudThrow = 42
        acro.thrust = 28; acro.pitchSpeed = 23; acro.propDia = 0.34; acro.washTail = 0.75; acro.washWing = 0.5
        acro.gear = .taildragger; acro.gearH = 0.2; acro.track = 0.17
        acro.fuse = rgb(0.98, 0.85, 0.1); acro.wingTop = rgb(0.1, 0.25, 0.75); acro.wingBottom = rgb(0.95, 0.95, 0.95)
        acro.tail = rgb(0.1, 0.25, 0.75); acro.accent = rgb(0.98, 0.85, 0.1); acro.sound = 160

        var glider = PlaneGeom()
        glider.name = "Thermal 2M"; glider.blurb = "Hand-launched electric glider for thermal and slope soaring"
        glider.mass = 0.85; glider.span = 2.0; glider.rootChord = 0.22; glider.tipChord = 0.15
        glider.wingY = 0.05; glider.wingLE = -0.04; glider.dihedral = 5; glider.incidence = 2; glider.camber = 3.5; glider.cd0 = 0.01
        glider.noseZ = -0.36; glider.fuseLen = 1.12; glider.fuseW = 0.06; glider.fuseH = 0.085
        glider.stabSpan = 0.5; glider.stabChord = 0.11; glider.stabZ = 0.63; glider.finH = 0.2; glider.finChord = 0.14; glider.finZ = 0.6
        glider.ailFrac = 0.25; glider.ailStart = 0.5; glider.ailThrow = 18; glider.elevThrow = 14; glider.rudThrow = 25
        glider.thrust = 7; glider.pitchSpeed = 15; glider.propDia = 0.25; glider.washTail = 0.3; glider.washWing = 0
        glider.gear = .none; glider.cdA = 0.004; glider.handLaunch = true
        glider.fuse = rgb(0.96, 0.96, 0.96); glider.wingTop = rgb(0.96, 0.96, 0.96); glider.wingBottom = rgb(0.9, 0.15, 0.5)
        glider.tail = rgb(0.9, 0.15, 0.5); glider.accent = rgb(0.2, 0.2, 0.25); glider.sound = 120

        var jet = PlaneGeom()
        jet.name = "Arrow EDF"; jet.blurb = "Swept-wing ducted-fan sport jet"
        jet.mass = 1.3; jet.span = 0.95; jet.rootChord = 0.32; jet.tipChord = 0.14; jet.sweep = 0.22
        jet.wingY = -0.01; jet.wingLE = -0.16; jet.dihedral = 1; jet.incidence = 0.5; jet.camber = 1; jet.thick = 0.09; jet.cd0 = 0.01
        jet.noseZ = -0.52; jet.fuseLen = 1.1; jet.fuseW = 0.1; jet.fuseH = 0.11
        jet.stabSpan = 0.4; jet.stabChord = 0.15; jet.stabZ = 0.4; jet.finH = 0.2; jet.finChord = 0.2; jet.finZ = 0.36
        jet.ailFrac = 0.28; jet.ailStart = 0.5; jet.ailThrow = 16; jet.elevThrow = 14; jet.rudThrow = 20
        jet.thrust = 15; jet.pitchSpeed = 58; jet.ducted = true
        jet.gear = .tricycle; jet.gearH = 0.13; jet.track = 0.14; jet.cdA = 0.005
        jet.fuse = rgb(0.55, 0.58, 0.62); jet.wingTop = rgb(0.5, 0.53, 0.57); jet.wingBottom = rgb(0.85, 0.87, 0.9)
        jet.tail = rgb(0.9, 0.35, 0.05); jet.accent = rgb(0.9, 0.35, 0.05); jet.sound = 420

        var warbird = PlaneGeom()
        warbird.name = "Falcon Warbird"; warbird.blurb = "Heavy low-wing fighter: fast, needs speed on landing"
        warbird.mass = 2.6; warbird.span = 1.4; warbird.rootChord = 0.30; warbird.tipChord = 0.18
        warbird.wingY = -0.05; warbird.wingLE = -0.075; warbird.dihedral = 5; warbird.incidence = 1; warbird.camber = 2; warbird.cd0 = 0.011
        warbird.noseZ = -0.45; warbird.fuseLen = 1.2; warbird.fuseW = 0.13; warbird.fuseH = 0.16
        warbird.stabSpan = 0.5; warbird.stabChord = 0.15; warbird.stabZ = 0.6; warbird.finH = 0.2; warbird.finChord = 0.17; warbird.finZ = 0.57
        warbird.ailThrow = 18; warbird.elevThrow = 16; warbird.rudThrow = 25
        warbird.thrust = 30; warbird.pitchSpeed = 33; warbird.propDia = 0.33; warbird.washTail = 0.5; warbird.washWing = 0.25
        warbird.gear = .taildragger; warbird.gearH = 0.2; warbird.track = 0.2; warbird.cdA = 0.008
        warbird.fuse = rgb(0.35, 0.4, 0.3); warbird.wingTop = rgb(0.33, 0.38, 0.28); warbird.wingBottom = rgb(0.7, 0.78, 0.85)
        warbird.tail = rgb(0.8, 0.1, 0.1); warbird.accent = rgb(0.9, 0.85, 0.2); warbird.sound = 130

        var bush = PlaneGeom()
        bush.name = "Bushmaster STOL"; bush.blurb = "Slow high-wing taildragger for short take-offs and landings"
        bush.mass = 2.0; bush.span = 1.8; bush.rootChord = 0.28; bush.tipChord = 0.28
        bush.wingY = 0.11; bush.wingLE = -0.055; bush.dihedral = 2; bush.incidence = 2.5; bush.camber = 4.5
        bush.noseZ = -0.42; bush.fuseLen = 1.25; bush.fuseW = 0.13; bush.fuseH = 0.18
        bush.stabSpan = 0.6; bush.stabChord = 0.18; bush.stabZ = 0.62; bush.finH = 0.24; bush.finChord = 0.2; bush.finZ = 0.6
        bush.ailThrow = 22; bush.elevThrow = 24; bush.rudThrow = 30
        bush.thrust = 21; bush.pitchSpeed = 18; bush.propDia = 0.33; bush.washTail = 0.6; bush.washWing = 0.3
        bush.gear = .taildragger; bush.gearH = 0.25; bush.track = 0.24; bush.cdA = 0.016
        bush.fuse = rgb(0.98, 0.8, 0.1); bush.wingTop = rgb(0.98, 0.8, 0.1); bush.wingBottom = rgb(0.12, 0.12, 0.12)
        bush.tail = rgb(0.12, 0.12, 0.12); bush.accent = rgb(0.98, 0.8, 0.1); bush.sound = 110

        var park = PlaneGeom()
        park.name = "Feather Park Flyer"; park.blurb = "Featherweight slow flyer for calm air and small spaces"
        park.mass = 0.32; park.span = 0.95; park.rootChord = 0.2; park.tipChord = 0.17
        park.wingY = 0.06; park.wingLE = -0.035; park.dihedral = 6; park.incidence = 2.5; park.camber = 4; park.thick = 0.08
        park.noseZ = -0.26; park.fuseLen = 0.78; park.fuseW = 0.06; park.fuseH = 0.08
        park.stabSpan = 0.34; park.stabChord = 0.11; park.stabZ = 0.39; park.finH = 0.14; park.finChord = 0.12; park.finZ = 0.38
        park.ailThrow = 18; park.elevThrow = 18; park.rudThrow = 25
        park.thrust = 3.6; park.pitchSpeed = 12; park.propDia = 0.18; park.washTail = 0.5; park.washWing = 0.2
        park.gear = .tricycle; park.gearH = 0.11; park.track = 0.1; park.cdA = 0.005
        park.fuse = rgb(0.95, 0.95, 0.95); park.wingTop = rgb(0.2, 0.7, 0.9); park.wingBottom = rgb(0.95, 0.5, 0.1)
        park.tail = rgb(0.2, 0.7, 0.9); park.accent = rgb(0.95, 0.95, 0.95); park.sound = 190

        var racer = PlaneGeom()
        racer.name = "Stiletto Racer"; racer.blurb = "Slippery pylon racer: very fast, twitchy at low speed"
        racer.mass = 1.1; racer.span = 1.1; racer.rootChord = 0.2; racer.tipChord = 0.13
        racer.wingY = 0; racer.wingLE = -0.05; racer.dihedral = 1; racer.incidence = 0.5; racer.camber = 1.5; racer.thick = 0.09; racer.cd0 = 0.008
        racer.noseZ = -0.4; racer.fuseLen = 0.95; racer.fuseW = 0.07; racer.fuseH = 0.09
        racer.stabSpan = 0.36; racer.stabChord = 0.11; racer.stabZ = 0.45; racer.finH = 0.15; racer.finChord = 0.13; racer.finZ = 0.43
        racer.ailThrow = 14; racer.elevThrow = 12; racer.rudThrow = 18
        racer.thrust = 22; racer.pitchSpeed = 50; racer.propDia = 0.2; racer.washTail = 0.4; racer.washWing = 0.15
        racer.gear = .tricycle; racer.gearH = 0.12; racer.track = 0.12; racer.cdA = 0.003
        racer.fuse = rgb(0.95, 0.95, 0.95); racer.wingTop = rgb(0.9, 0.1, 0.45); racer.wingBottom = rgb(0.1, 0.1, 0.12)
        racer.tail = rgb(0.9, 0.1, 0.45); racer.accent = rgb(0.1, 0.1, 0.12); racer.sound = 260

        var twin = PlaneGeom()
        twin.name = "Twin Courier"; twin.blurb = "Twin-engine transport with gentle manners and long legs"
        twin.mass = 2.9; twin.span = 1.75; twin.rootChord = 0.3; twin.tipChord = 0.2; twin.twin = 0.3
        twin.wingY = 0.07; twin.wingLE = -0.065; twin.dihedral = 4; twin.incidence = 2; twin.camber = 3
        twin.noseZ = -0.55; twin.fuseLen = 1.5; twin.fuseW = 0.15; twin.fuseH = 0.17
        twin.stabSpan = 0.62; twin.stabChord = 0.17; twin.stabZ = 0.76; twin.finH = 0.28; twin.finChord = 0.2; twin.finZ = 0.73
        twin.thrust = 30; twin.pitchSpeed = 26; twin.propDia = 0.25; twin.washTail = 0.25; twin.washWing = 0.5
        twin.gear = .tricycle; twin.gearH = 0.2; twin.track = 0.3; twin.cdA = 0.014
        twin.fuse = rgb(0.93, 0.93, 0.95); twin.wingTop = rgb(0.93, 0.93, 0.95); twin.wingBottom = rgb(0.15, 0.3, 0.6)
        twin.tail = rgb(0.15, 0.3, 0.6); twin.accent = rgb(0.9, 0.5, 0.1); twin.sound = 150

        var bipe = PlaneGeom()
        bipe.name = "Jester Biplane"; bipe.blurb = "Compact aerobatic biplane with a fast roll rate"
        bipe.mass = 1.7; bipe.span = 1.0; bipe.rootChord = 0.2; bipe.tipChord = 0.19; bipe.upperWingY = 0.19
        bipe.wingY = -0.04; bipe.wingLE = -0.03; bipe.dihedral = 1.5; bipe.incidence = 0.5; bipe.camber = 0.5; bipe.stall = 0.25
        bipe.noseZ = -0.36; bipe.fuseLen = 0.95; bipe.fuseW = 0.12; bipe.fuseH = 0.16
        bipe.stabSpan = 0.42; bipe.stabChord = 0.16; bipe.stabZ = 0.46; bipe.elevFrac = 0.5; bipe.finH = 0.2; bipe.finChord = 0.18; bipe.finZ = 0.43; bipe.rudFrac = 0.55
        bipe.ailFrac = 0.3; bipe.ailStart = 0; bipe.ailThrow = 24; bipe.elevThrow = 28; bipe.rudThrow = 35
        bipe.thrust = 27; bipe.pitchSpeed = 24; bipe.propDia = 0.3; bipe.washTail = 0.7; bipe.washWing = 0.4
        bipe.gear = .taildragger; bipe.gearH = 0.19; bipe.track = 0.16; bipe.cdA = 0.016
        bipe.fuse = rgb(0.85, 0.1, 0.1); bipe.wingTop = rgb(0.85, 0.1, 0.1); bipe.wingBottom = rgb(0.96, 0.96, 0.96)
        bipe.tail = rgb(0.96, 0.96, 0.96); bipe.accent = rgb(0.96, 0.96, 0.96); bipe.sound = 150

        var sail = PlaneGeom()
        sail.name = "Zephyr 3.6 Sailplane"; sail.blurb = "Large self-launching sailplane with a very flat glide"
        sail.mass = 3.4; sail.span = 3.6; sail.rootChord = 0.25; sail.tipChord = 0.12
        sail.wingY = 0.05; sail.wingLE = -0.05; sail.dihedral = 3.5; sail.incidence = 2; sail.camber = 3.5; sail.cd0 = 0.008; sail.thick = 0.11
        sail.noseZ = -0.6; sail.fuseLen = 1.75; sail.fuseW = 0.1; sail.fuseH = 0.13
        sail.stabSpan = 0.7; sail.stabChord = 0.13; sail.stabZ = 1.0; sail.finH = 0.3; sail.finChord = 0.2; sail.finZ = 0.95
        sail.ailFrac = 0.22; sail.ailStart = 0.5; sail.ailThrow = 20; sail.elevThrow = 14; sail.rudThrow = 28
        sail.thrust = 24; sail.pitchSpeed = 17; sail.propDia = 0.36; sail.washTail = 0.2; sail.washWing = 0
        sail.gear = .none; sail.cdA = 0.005; sail.handLaunch = true
        sail.fuse = rgb(0.97, 0.97, 0.97); sail.wingTop = rgb(0.97, 0.97, 0.97); sail.wingBottom = rgb(0.95, 0.45, 0.05)
        sail.tail = rgb(0.95, 0.45, 0.05); sail.accent = rgb(0.2, 0.25, 0.6); sail.sound = 105

        var trainerHeli = rescale(makeHeli(), 0.6)
        trainerHeli.name = "Sparrow 450"; trainerHeli.blurb = "Small, docile helicopter for learning to hover"
        trainerHeli.mass = 0.9; trainerHeli.inertia = V3(0.010, 0.009, 0.004); trainerHeli.cdA = 0.012; trainerHeli.soundBase = 105
        trainerHeli.heli!.collMax = 9 * deg; trainerHeli.heli!.maxMoment = 1.1; trainerHeli.heli!.tailMax = 0.45
        trainerHeli.heli!.maxRate = 3.2; trainerHeli.heli!.maxYaw = 4.5

        var bigHeli = rescale(makeHeli(), 1.27)
        bigHeli.name = "Condor 700"; bigHeli.blurb = "Large 700-class helicopter: smooth, powerful, imposing"
        bigHeli.mass = 5.3; bigHeli.inertia = V3(0.27, 0.24, 0.11); bigHeli.cdA = 0.045; bigHeli.soundBase = 52
        bigHeli.heli!.maxMoment = 22; bigHeli.heli!.tailMax = 8

        var racerQuad = rescale(makeQuad(), 0.5)
        racerQuad.name = "Wasp Racing Quad"; racerQuad.blurb = "5-inch racing quad: brutal power, best flown in acro"
        racerQuad.mass = 0.6; racerQuad.inertia = V3(0.0016, 0.0028, 0.0016); racerQuad.cdA = 0.008; racerQuad.soundBase = 380
        racerQuad.multi!.maxThrust = 6.5; racerQuad.multi!.kYaw = 0.008; racerQuad.multi!.maxRate = 9; racerQuad.multi!.maxYaw = 6; racerQuad.multi!.maxAngle = 0.95

        return [makeAirplane(trainer), makeAirplane(acro), makeAirplane(glider), makeAirplane(jet), makeHeli(), makeQuad(),
                makeAirplane(park), makeAirplane(bush), makeAirplane(warbird), makeAirplane(twin), makeAirplane(bipe), makeAirplane(racer),
                makeAirplane(sail), trainerHeli, bigHeli, racerQuad]
    }()
}
