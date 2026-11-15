import simd
import Foundation

/// What the airframe is made of. It sets where the weight sits, and so how readily the model rotates.
enum Construction {
    case foam           // EPP / depron: featherweight airframe, most of the mass is motor and battery at the middle
    case balsa          // built-up wood with film covering
    case composite      // moulded glass or carbon: heavy, stiff wings
    var label: String { self == .foam ? "Foam" : (self == .balsa ? "Balsa and film" : "Composite") }
    /// Fractions of the flying weight in the wing, fuselage, tail and power unit; the rest is battery and radio.
    var split: (wing: Float, fuse: Float, tail: Float, engine: Float) {
        switch self {
        case .foam: return (0.15, 0.13, 0.035, 0.2)
        case .balsa: return (0.24, 0.24, 0.065, 0.17)
        case .composite: return (0.33, 0.25, 0.05, 0.11)
        }
    }
}

/// Peak roll, pitch and yaw rates (degrees per second, full stick, at 1.6 times the stall speed) that each
/// kind of model is set up for. Control throws are scaled until the simulated aircraft matches.
let rateTargets: [String: (roll: Float, pitch: Float, yaw: Float)] = [
    "Trainers & Sport": (150, 120, 70), "Scale Civil": (110, 100, 60), "Warbirds": (200, 130, 70), "Aerobatic": (380, 240, 150),
    "Foam 3D": (330, 260, 200), "Wings": (230, 170, 60), "Jets": (240, 120, 60), "Gliders": (95, 85, 60),
]

enum GearType { case tricycle, taildragger, none, floats }

/// Wing section families. Each sets the zero-lift offset, where and how sharply the section stalls,
/// how far below the stall the flow reattaches, how much lift survives the stall, and the profile drag.
enum Airfoil {
    case flatBottom     // Clark-Y style trainer section: lots of lift, soft stall
    case semiSymmetric  // NACA 23xx / 24xx: the classic general-purpose section
    case symmetric      // aerobatic sections: same upright and inverted
    case laminar        // thin fast sections: low drag, sharp stall, slow to recover
    case thin           // undercambered First World War sections
    case glider         // high-lift, low-drag sailplane sections
    case slatted        // leading-edge slats: stalls late and gently
    case plate          // flat foam sheet: no real stall break
    case reflex         // tailless-wing section with an upturned trailing edge
    case delta          // low aspect ratio delta: vortex lift to very high angles
    var params: (camber: Float, stall: Float, width: Float, hyst: Float, post: Float, cd0: Float) {
        switch self {
        case .flatBottom: return (3.5, 15, 0.16, 0.035, 1.0, 0.016)
        case .semiSymmetric: return (2.0, 14.5, 0.11, 0.05, 0.95, 0.013)
        case .symmetric: return (0, 14, 0.11, 0.05, 0.95, 0.013)
        case .laminar: return (1.5, 13, 0.05, 0.09, 0.8, 0.009)
        case .thin: return (4, 12, 0.1, 0.04, 0.9, 0.02)
        case .glider: return (3.5, 13.5, 0.09, 0.05, 0.9, 0.008)
        case .slatted: return (3.5, 19, 0.2, 0.03, 1.0, 0.018)
        case .plate: return (0, 11, 0.25, 0, 1.1, 0.02)
        case .reflex: return (0.8, 12.5, 0.12, 0.04, 0.95, 0.012)
        case .delta: return (0, 24, 0.3, 0.02, 1.1, 0.014)
        }
    }
}

/// Published figures for the full-size aircraft (approximate): span and length in metres, wing area in
/// square metres, loaded mass in kg, power in kW (or thrust-to-weight for jets), top speed in km/h, wing taper ratio.
struct RealData {
    var span: Float, area: Float, length: Float, mass: Float, power: Float, vmax: Float, taper: Float
    var airfoil: Airfoil
    var washout: Float = 1.5
    var jetTW: Float = 0
}
private func rd(_ span: Float, _ area: Float, _ length: Float, _ mass: Float, _ power: Float, _ vmax: Float, _ taper: Float, _ af: Airfoil, washout: Float = 1.5, tw: Float = 0) -> RealData {
    RealData(span: span, area: area, length: length, mass: mass, power: power, vmax: vmax, taper: taper, airfoil: af, washout: washout, jetTW: tw)
}
let realData: [String: RealData] = [
    "Piper J-3 Cub": rd(10.74, 16.58, 6.83, 550, 48, 140, 1.0, .flatBottom, washout: 2),
    "Piper PA-18 Super Cub": rd(10.73, 16.58, 6.88, 794, 112, 210, 1.0, .flatBottom, washout: 2),
    "Cessna 152": rd(10.2, 14.9, 7.3, 757, 82, 200, 0.7, .semiSymmetric, washout: 2),
    "Cessna 172 Skyhawk": rd(11.0, 16.2, 8.28, 1111, 120, 230, 0.7, .semiSymmetric, washout: 2.5),
    "Cessna 182 Skylane": rd(11.0, 16.2, 8.84, 1406, 172, 280, 0.7, .semiSymmetric, washout: 2.5),
    "Cessna 208 Caravan": rd(15.87, 25.96, 11.46, 3629, 503, 344, 0.6, .semiSymmetric, washout: 2.5),
    "Pilatus PC-6 Porter": rd(15.87, 30.15, 10.9, 2800, 410, 232, 1.0, .flatBottom, washout: 2),
    "DHC-2 Beaver": rd(14.63, 23.2, 9.22, 2313, 336, 255, 1.0, .semiSymmetric, washout: 2),
    "Fieseler Storch": rd(14.25, 26.0, 9.9, 1325, 180, 175, 1.0, .slatted, washout: 0),
    "Piper PA-28 Cherokee": rd(9.14, 14.86, 7.16, 975, 112, 230, 1.0, .semiSymmetric, washout: 2),
    "Beechcraft Bonanza": rd(10.21, 16.8, 8.38, 1656, 224, 326, 0.5, .semiSymmetric, washout: 3),
    "Cirrus SR22": rd(11.68, 13.71, 7.92, 1633, 231, 340, 0.5, .laminar, washout: 2.5),
    "Diamond DA40": rd(11.94, 13.54, 8.06, 1198, 134, 285, 0.55, .laminar, washout: 2.5),
    "Robin DR400": rd(8.72, 14.2, 6.96, 1100, 134, 278, 0.8, .semiSymmetric, washout: 2),
    "DHC-6 Twin Otter": rd(19.8, 39.0, 15.77, 5670, 920, 314, 1.0, .flatBottom, washout: 2),
    "Beechcraft King Air": rd(16.61, 28.2, 13.34, 5670, 1268, 536, 0.45, .semiSymmetric, washout: 3),
    "Pilatus PC-12": rd(16.28, 25.81, 14.4, 4740, 895, 528, 0.5, .semiSymmetric, washout: 2.5),
    "Antonov An-2": rd(18.2, 71.5, 12.4, 5500, 750, 258, 1.0, .slatted, washout: 0),
    "Douglas DC-3": rd(29.0, 91.7, 19.7, 11430, 1790, 370, 0.35, .semiSymmetric, washout: 3),
    "Boeing Stearman": rd(9.8, 27.6, 7.63, 1232, 164, 200, 1.0, .semiSymmetric, washout: 0),
    "DH Tiger Moth": rd(8.94, 22.2, 7.34, 828, 97, 175, 1.0, .thin, washout: 0),
    "P-51D Mustang": rd(11.28, 21.83, 9.83, 4175, 1111, 703, 0.45, .laminar, washout: 1.5),
    "Supermarine Spitfire": rd(11.23, 22.48, 9.47, 3350, 1175, 650, 0.4, .semiSymmetric, washout: 2.5),
    "Messerschmitt Bf 109": rd(9.92, 16.05, 8.95, 3150, 1085, 640, 0.5, .slatted, washout: 0),
    "Mitsubishi A6M Zero": rd(12.0, 22.44, 9.06, 2410, 700, 533, 0.5, .semiSymmetric, washout: 2.5),
    "Grumman F6F Hellcat": rd(13.06, 31.0, 10.24, 5714, 1490, 610, 0.5, .semiSymmetric, washout: 2),
    "DH Mosquito": rd(16.52, 42.18, 13.57, 8500, 2200, 668, 0.35, .semiSymmetric, washout: 2),
    "Hawker Hurricane": rd(12.19, 23.92, 9.84, 3480, 880, 547, 0.5, .flatBottom, washout: 2),
    "P-47 Thunderbolt": rd(12.42, 27.87, 11.0, 6600, 1890, 697, 0.5, .semiSymmetric, washout: 1.5),
    "Curtiss P-40 Warhawk": rd(11.38, 21.92, 10.16, 3760, 860, 580, 0.5, .semiSymmetric, washout: 1.5),
    "Focke-Wulf Fw 190": rd(10.51, 18.3, 9.0, 4400, 1250, 656, 0.5, .laminar, washout: 1),
    "Yakovlev Yak-3": rd(9.2, 14.85, 8.5, 2692, 960, 655, 0.45, .semiSymmetric, washout: 1.5),
    "North American T-6 Texan": rd(12.81, 23.57, 8.84, 2548, 450, 335, 0.45, .semiSymmetric, washout: 1),
    "Hawker Sea Fury": rd(11.7, 26.0, 10.6, 5670, 1850, 740, 0.45, .laminar, washout: 1.5),
    "Douglas A-26 Invader": rd(21.34, 50.0, 15.24, 12500, 3000, 570, 0.4, .laminar, washout: 2),
    "Sopwith Camel": rd(8.53, 21.46, 5.71, 659, 97, 185, 1.0, .thin, washout: 0),
    "Royal Aircraft Factory S.E.5a": rd(8.11, 22.67, 6.38, 902, 150, 222, 1.0, .thin, washout: 0),
    "Extra 300": rd(8.0, 10.7, 6.95, 950, 224, 407, 0.45, .symmetric, washout: 0),
    "Pitts Special": rd(6.1, 11.6, 5.71, 737, 194, 340, 1.0, .symmetric, washout: 0),
    "Pilatus PC-7": rd(10.4, 16.6, 9.78, 2700, 410, 412, 0.5, .laminar, washout: 2),
    "Sukhoi Su-26": rd(7.8, 11.8, 6.83, 1000, 265, 450, 0.45, .symmetric, washout: 0),
    "Zivko Edge 540": rd(7.43, 9.1, 6.3, 816, 254, 426, 0.45, .symmetric, washout: 0),
    "Yakovlev Yak-54": rd(8.16, 12.89, 6.91, 990, 265, 450, 0.5, .symmetric, washout: 0),
    "Mudry CAP 232": rd(7.39, 9.86, 6.76, 816, 224, 340, 0.45, .symmetric, washout: 0),
    "Christen Eagle": rd(6.07, 11.6, 5.46, 725, 149, 296, 1.0, .symmetric, washout: 0),
    "Zlín Z-50": rd(8.58, 12.5, 6.62, 720, 194, 337, 0.5, .symmetric, washout: 0),
    "F-16 Fighting Falcon": rd(9.96, 27.87, 15.06, 12000, 0, 2120, 0.22, .laminar, washout: 0, tw: 1.0),
    "F-86 Sabre": rd(11.31, 29.11, 11.44, 6870, 0, 1100, 0.5, .laminar, washout: 2, tw: 0.42),
    "BAe Hawk": rd(9.39, 16.69, 11.17, 5700, 0, 1040, 0.35, .laminar, washout: 2, tw: 0.45),
    "Aero L-39 Albatros": rd(9.46, 18.8, 12.13, 4700, 0, 750, 0.5, .semiSymmetric, washout: 2, tw: 0.37),
    "Mikoyan MiG-15": rd(10.08, 20.6, 10.1, 4960, 0, 1076, 0.55, .laminar, washout: 1.5, tw: 0.54),
    "Lockheed F-104 Starfighter": rd(6.63, 18.22, 16.66, 9365, 0, 2137, 0.38, .laminar, washout: 0, tw: 0.76),
    "Aermacchi MB-339": rd(10.86, 19.3, 10.97, 4400, 0, 898, 0.5, .semiSymmetric, washout: 2, tw: 0.41),
    "ASK 21": rd(17.0, 17.95, 8.35, 600, 0, 280, 0.4, .glider, washout: 2.5),
    "Schleicher ASW 28": rd(15.0, 10.5, 6.59, 525, 0, 270, 0.4, .glider, washout: 2),
    "DG-1000": rd(20.0, 17.5, 8.57, 750, 0, 270, 0.35, .glider, washout: 2.5),
    "Schempp-Hirth Discus": rd(15.0, 10.58, 6.58, 525, 0, 250, 0.4, .glider, washout: 2),
    "Schleicher Ka 8": rd(15.0, 14.15, 7.0, 310, 0, 200, 0.5, .flatBottom, washout: 3),
]

/// Reshape a model to the proportions of the full-size aircraft and give it scale wing and power loading.
func applyRealData(_ g: inout PlaneGeom) {
    guard let r = realData[g.dataKey ?? g.name] else { return }
    let nW: Float = g.upperWingY != nil ? 2 : 1
    let ar = r.span * r.span / (r.area / nW)
    let cbar = g.span / ar
    g.rootChord = 2 * cbar / (1 + r.taper); g.tipChord = r.taper * g.rootChord
    let newLen = g.span * r.length / r.span, f = newLen / g.fuseLen
    g.noseZ *= f; g.fuseLen = newLen; g.stabZ *= f; g.finZ *= f
    // wing cube loading rises with the logarithm of the full-size wing loading: a Cub model is light for
    // its size, a Starfighter model heavy
    let modelArea = cbar * g.span * nW
    let oldMass = g.mass
    g.mass = (2 + 2.6 * log(r.mass / r.area / 10)) * pow(modelArea, 1.5)
    if r.jetTW > 0 {
        g.thrust = g.mass * gravity * (0.45 + 0.5 * r.jetTW); g.pitchSpeed = 45 + r.vmax / 100
    } else if r.power > 0 {
        g.thrust = g.mass * gravity * (0.4 + 2.6 * r.power / r.mass + (g.category == "Aerobatic" ? 0.7 : 0))
        g.pitchSpeed = min(12 + r.vmax * 0.055, 40)
    } else {
        g.thrust *= g.mass / oldMass
    }
    g.airfoil = r.airfoil; g.washout = r.washout
}

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
    var flaps = false
    var retracts = false
    var airfoil: Airfoil? = nil     // nil = chosen by category
    var flyingWing = false          // tailless: elevons on the wing, no tailplane
    var winglets = false            // fins on the wingtips instead of on the fuselage
    var noFin = false
    var pusher = false              // propeller at the tail
    var trimCL: Float = 0.4         // lift coefficient a tailless wing flies at with the stick centred
    var build: Construction? = nil  // nil = chosen from the type
    var rightThrust: Float? = nil   // motor offset in degrees; nil = typical for the type (none on flat foamies)
    var downThrust: Float? = nil
    var dataKey: String? = nil      // full-size aircraft to take figures from, when the name differs
    var washout: Float = 1.5        // degrees of twist reducing the tip's incidence
    var margin: Float? = nil        // static margin as a fraction of mean chord; nil = by category
    var endurance: Float? = nil     // seconds at full throttle
    var scheme = 0                  // trim scheme: 0 sport, 1 aerobatic, 2 warbird, 3 glider, 4 jet, 5 vintage
    var fuseExp: Float = 2.8        // fuselage cross-section: 2 = round, higher = boxier
    var canopyLen: Float = 0.11     // canopy half-length as a fraction of fuselage length
    var struts = false
    var pants = false               // wheel spats
    var wheelR: Float = 0.035
    var category = "Sport"
    var blades = 2
    var spinnerScale: Float = 0.4   // spinner radius relative to fuselage half-width (small for radial engines)
    var spinnerColor: V4? = nil
    var tTail = false
    var noseIntake = false          // jets: intake in the nose instead of on the cheeks
    var profile = false             // flat foam "profile" airframe: plate fuselage and slab wings
    var tough: Float = 1            // crash tolerance multiplier (foam bounces)
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

/// Build an airplane and check its balance by test: if the simulated aircraft turns out less nose-heavy than
/// intended (biplanes and other shapes the estimate misjudges), move the wing back to put the centre of gravity right.
func makeAirplane(_ g: PlaneGeom) -> AircraftSpec {
    var spec = buildAirplane(g)
    for _ in 0..<2 {
        let actual = measuredMargin(spec, throttle: 0.3)
        if actual >= spec.designMargin - 0.01 { break }
        spec = buildAirplane(g, cgShift: spec.cgShift + (spec.designMargin - actual) * spec.mac)
    }
    return spec
}

func buildAirplane(_ g0: PlaneGeom, cgShift: Float = 0) -> AircraftSpec {
    var g = g0
    applyRealData(&g)
    // A biplane's weight sits between its wings, not level with the lower one. With the centre of gravity
    // too low, the upper wing's drag pitches the nose up harder the more the aircraft is pulled.
    if let uy = g.upperWingY {
        let shift = -0.38 * (uy - g.wingY) - g.wingY
        g.wingY += shift; g.upperWingY = uy + shift
    }
    // wing section
    let af: Airfoil = g.airfoil ?? (g.profile ? .plate : (["Wings": .reflex, "Aerobatic": .symmetric, "Gliders": .glider, "Jets": .laminar, "Trainers & Sport": .flatBottom][g.category] ?? .semiSymmetric))
    let afp = af.params
    if g.airfoil != nil || !g.profile { g.camber = af == .symmetric || af == .plate ? 0 : afp.camber; g.stall = afp.stall * deg; g.cd0 = afp.cd0 }
    if g.profile || g.category == "Aerobatic" { g.washout = 0 }

    let hs = g.span / 2
    let dih = g.dihedral * deg, inc = g.incidence * deg
    let nWings: Float = g.upperWingY != nil ? 2 : 1
    let wingEff: Float = nWings > 1 ? 0.85 : 1
    let area = (g.rootChord + g.tipChord) / 2 * g.span
    let ar = g.span * g.span / area
    let slope = 2 * Float.pi * ar / (ar + 2)
    let downK = 2 / (Float.pi * ar)                       // downwash angle per unit lift coefficient
    var staticMargin: Float = 0.1
    let taper = g.tipChord / g.rootChord
    let mac = 2.0 / 3.0 * g.rootChord * (1 + taper + taper * taper) / (1 + taper)
    // Tailplane size: keep the tail volume (area x arm relative to wing area x chord) in the range real
    // aircraft use, so reshaping the wing or fuselage does not leave an oversized or feeble tail.
    if !g.profile && !g.flyingWing {
        let vh = g.stabSpan * g.stabChord * (g.stabZ + 0.25 * g.stabChord) / (area * nWings * wingEff * mac)
        let hi: Float = g.category == "Aerobatic" ? 0.8 : 0.62, lo: Float = g.category == "Gliders" ? 0.38 : 0.45
        let k = sqrt(clampf(vh, lo, hi) / vh)
        g.stabSpan *= k; g.stabChord *= k
    }
    let sar = g.stabSpan / g.stabChord
    let tailSlope = 2 * Float.pi * sar / (sar + 2) * 0.9

    // Balance: put the centre of gravity a set fraction of the mean chord ahead of the neutral point
    // (the point where the wing's and tail's lift changes balance out).
    do {
        let ybar = (1 + 2 * taper) / (3 * (1 + taper))
        let acOff = g.sweep * ybar + 0.25 * mac + (nWings > 1 ? -0.035 : 0)
        let aW = slope * area * nWings * wingEff
        let aT = g.flyingWing ? 0 : tailSlope * g.stabSpan * g.stabChord * (1 - slope * downK)
        let zT = g.stabZ + 0.25 * g.stabChord
        let m = g.margin ?? (g.profile ? 0.07 : (["Wings": 0.10, "Aerobatic": 0.09, "Warbirds": 0.12, "Jets": 0.12, "Gliders": 0.13, "Scale Civil": 0.15, "Trainers & Sport": 0.17][g.category] ?? 0.12))
        g.wingLE = (m * mac * (aW + aT) - aT * zT) / aW - acOff + cgShift
        staticMargin = m
    }

    let L = g.fuseLen, nz = g.noseZ, tz = g.noseZ + g.fuseLen
    let w = g.fuseW / 2, h = g.fuseH / 2
    let finY = h * 0.3
    let stabY = g.tTail ? finY + g.finH : finY
    func chord(_ f: Float) -> Float { lerp(g.rootChord, g.tipChord, f) }

    let wings: [(y: Float, z: Float)] = g.upperWingY.map { [(g.wingY, Float(0)), ($0, Float(-0.07))] } ?? [(g.wingY, Float(0))]

    // --- Aerodynamics: six panels per half wing, each with its own chord, twist and loading
    var surfaces: [AeroSurface] = []
    let nPan = 6
    let meanChord = area / g.span
    // Schrenk's approximation: each section carries the average of its own chord and an elliptical one,
    // so a strongly tapered wing loads its tips hardest and a rectangular wing its root
    var loads = (0..<nPan).map { k -> Float in
        let fm = (Float(k) + 0.5) / Float(nPan)
        let cEll = 4 * area / (Float.pi * g.span) * sqrt(max(1 - fm * fm, 0))
        return (1 + cEll / chord(fm)) / 2
    }
    do {
        var sum: Float = 0, wsum: Float = 0
        for k in 0..<nPan { let c = chord((Float(k) + 0.5) / Float(nPan)); sum += loads[k] * c; wsum += c }
        // model-size wings at low Reynolds numbers let go gradually, so only half of the theoretical unevenness is used
        loads = loads.map { 1 + 0.5 * ($0 * wsum / sum - 1) }
    }
    for wg in wings { for side in [Float(-1), 1] {
        for k in 0..<nPan {
            let f0 = Float(k) / Float(nPan), fm = (Float(k) + 0.5) / Float(nPan)
            let ch = chord(fm), x = side * hs * fm
            let incL = inc - g.washout * deg * fm
            let n0 = V3(-sin(dih) * side, cos(dih), 0), c0 = V3(0, 0, -1)
            var s = AeroSurface(pos: V3(x, wg.y + abs(x) * tan(dih), g.wingLE + wg.z + g.sweep * fm + 0.25 * ch),
                                normal: n0 * cos(incL) - c0 * sin(incL), chordDir: c0 * cos(incL) + n0 * sin(incL),
                                area: ch * hs / Float(nPan) * wingEff, ar: ar, liftSlope: slope,
                                stall: g.stall * pow(ch / meanChord, 0.06), cd0: g.cd0, alpha0: g.camber * deg)
            s.isWing = true; s.load = loads[k]; s.chord = ch
            // small models stall softly: a wider break, little hysteresis, and most of the lift kept afterwards
            s.stallWidth = max(afp.width * 1.6, 0.14); s.hyst = afp.hyst * 0.35; s.postStall = clampf(afp.post - 0.1, 0.72, 0.92)
            if f0 >= g.ailStart - 0.01 { s.flapCh = 0; s.flapGain = -side * flapTau(g.ailFrac) * g.ailThrow * deg }
            s.wash = fm < 0.34 ? g.washWing : 0
            if g.flaps && g.ailStart > 0.4 && f0 < g.ailStart - 0.01 { s.flapsGain = 0.14 }
            if g.flyingWing {
                // elevons, and enough reflex to balance the wing at its trim lift coefficient
                if s.flapCh == 0 { s.elevGain = -flapTau(g.ailFrac) * g.elevThrow * deg }
                s.cm0 = g.trimCL * staticMargin * mac / ch
            }
            surfaces.append(s)
        }
    } }
    for side in [Float(-1), 1] where !g.flyingWing {
        surfaces.append(AeroSurface(pos: V3(side * g.stabSpan / 4, stabY, g.stabZ + 0.25 * g.stabChord), normal: V3(0, 1, 0),
                                    area: g.stabSpan * g.stabChord / 2, ar: sar, liftSlope: tailSlope,
                                    stall: 0.27, cd0: 0.012, flapCh: 1, flapGain: -flapTau(g.elevFrac) * g.elevThrow * deg, wash: g.washTail,
                                    chord: g.stabChord, downwash: g.tTail ? 0.5 : 1))
    }
    let far = 1.6 * g.finH / g.finChord
    let tipY0 = g.wingY + hs * tan(dih)
    let finSpots: [V3] = g.noFin ? [] : (g.winglets
        ? [V3(hs, tipY0 + g.finH / 2, g.wingLE + g.sweep + 0.5 * g.tipChord), V3(-hs, tipY0 + g.finH / 2, g.wingLE + g.sweep + 0.5 * g.tipChord)]
        : [V3(0, finY + g.finH / 2, g.finZ + 0.25 * g.finChord)])
    for fp in finSpots {
        surfaces.append(AeroSurface(pos: fp, normal: V3(1, 0, 0), area: g.finH * g.finChord, ar: far, liftSlope: 2 * .pi * far / (far + 2),
                                    stall: 0.27, cd0: 0.012, flapCh: g.flyingWing ? -1 : 2, flapGain: g.flyingWing ? 0 : -flapTau(g.rudFrac) * g.rudThrow * deg,
                                    wash: g.flyingWing ? 0 : g.washTail, chord: g.finChord, swirl: g.ducted || g.twin > 0 || g.flyingWing || g.profile ? 0 : 1))
    }
    if g.noFin {
        // a finless swept wing is kept straight by its tips: the advancing one gains drag
        for side in [Float(-1), 1] {
            surfaces.append(AeroSurface(pos: V3(side * hs * 0.9, tipY0, g.wingLE + g.sweep + 0.6 * g.tipChord), normal: V3(1, 0, 0), area: 0.012 * area, ar: 1, liftSlope: 2,
                                        stall: 0.4, cd0: 0.02, chord: g.tipChord))
        }
    }
    for (n, a) in [(V3(1, 0, 0), L * g.fuseH * 0.75), (V3(0, 1, 0), L * g.fuseW * 0.75)] {
        surfaces.append(AeroSurface(pos: V3(0, 0, nz + 0.42 * L), normal: n, area: a, ar: 0.4, liftSlope: 0.9, stall: 0.6, cd0: 0))
    }

    // --- Contacts
    var contacts: [Contact] = []
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
    case .floats:
        // two floats, each resting on its bow and stern
        for x in [g.track, -g.track] { for z in [-0.3 * L, 0.3 * L] {
            contacts.append(Contact(pos: V3(x, -g.gearH, z), crashSpeed: 4.5, mu: 0.35, float: true))
        } }
    case .none:
        contacts.append(Contact(pos: V3(0, -h, nz * 0.5), crashSpeed: 3.5, mu: 0.4))
        contacts.append(Contact(pos: V3(0, -h * 0.8, 0.25), crashSpeed: 3.5, mu: 0.4))
    }
    let tipY = g.wingY + hs * tan(dih)
    contacts.append(Contact(pos: V3(0, 0, nz - 0.03), crashSpeed: 2.5))
    contacts.append(Contact(pos: V3(0, -h * 0.9, nz * 0.7), crashSpeed: 3))
    contacts.append(Contact(pos: V3(0, -h * 0.85, 0.15), crashSpeed: 3.5, mu: 0.45))
    contacts.append(Contact(pos: V3(0, h * 0.2, tz), crashSpeed: 3.5))
    contacts.append(Contact(pos: V3(hs, tipY, g.wingLE + g.sweep + g.tipChord / 2), crashSpeed: 3))
    contacts.append(Contact(pos: V3(-hs, tipY, g.wingLE + g.sweep + g.tipChord / 2), crashSpeed: 3))
    contacts.append(Contact(pos: V3(0, finY + g.finH, g.finZ + g.finChord * 0.6), crashSpeed: 2.5))
    contacts = contacts.map { var c = $0; c.crashSpeed *= g.tough; return c }
    contacts.append(Contact(pos: V3(0, max(h, g.wingY) + 0.03, nz + 0.3 * L), crashSpeed: 2.5))

    let engines: [V3] = g.twin > 0 ? [V3(g.twin, g.wingY, g.wingLE - 0.1), V3(-g.twin, g.wingY, g.wingLE - 0.1)] : [V3(0, 0, g.pusher ? tz : nz)]

    let parts = buildAirplaneModel(g, wheels: wheels, engines: engines, wings: wings)

    // Mass distribution: wing, fuselage, tail, power unit, and a battery placed to balance the model
    // on its centre of gravity. The moments of inertia follow from where the mass sits.
    let engZ = g.ducted ? tz - 0.15 : (g.twin > 0 ? g.wingLE - 0.1 : nz + 0.04)
    let glider = g.category == "Gliders"
    let construction: Construction = g.build ?? (g.profile || g.category == "Foam 3D" || g.tough > 1.3 || (g.category == "Wings" && !g.ducted) ? .foam
        : (glider || g.category == "Jets" ? .composite : .balsa))
    let split = construction.split
    let mWing = g.mass * split.wing, mFuse = g.mass * split.fuse, mTail = g.mass * split.tail, mEng = g.mass * split.engine
    let mBatt = g.mass - mWing - mFuse - mTail - mEng
    let zWing = g.wingLE + g.sweep * 0.42 + 0.4 * mac, zFuse = nz + 0.45 * L, zTail = g.stabZ + 0.4 * g.stabChord
    let zBatt = clampf(-(mWing * zWing + mFuse * zFuse + mTail * zTail + mEng * engZ) / mBatt, nz + 0.05, tz - 0.2)
    var ixx = mWing * (mac * mac / 12 + zWing * zWing) + mFuse * (L * L / 12 + zFuse * zFuse) + mTail * zTail * zTail
        + mEng * engZ * engZ + mBatt * zBatt * zBatt
    var izz = mWing * g.span * g.span / 12 * (taper < 0.7 ? 0.8 : 1) + mTail * g.stabSpan * g.stabSpan / 12 + (mFuse + mBatt) * (w * w + h * h) / 4
        + mEng * g.twin * g.twin
    if nWings > 1, let uy = g.upperWingY { izz += mWing * 0.25 * pow(uy - g.wingY, 2); ixx += mWing * 0.25 * pow(uy - g.wingY, 2) }
    ixx = max(ixx, g.mass * 0.01); izz = max(izz, g.mass * 0.004)
    var spec = AircraftSpec(name: g.name, kind: .airplane, blurb: g.blurb, mass: g.mass, inertia: V3(ixx, ixx + izz * 0.92, izz), span: g.span)
    spec.surfaces = surfaces
    spec.props = engines.enumerated().map { i, pos in
        var p = Propulsor(pos: pos, staticThrust: g.thrust / Float(engines.count), pitchSpeed: g.pitchSpeed, diameter: g.propDia, torqueK: g.ducted ? 0 : 0.02)
        let d = g.ducted ? Float(0.08) : g.propDia
        p.tau = g.ducted ? 0.5 : 0.35 + 1.2 * g.propDia
        // propeller and motor rotor as a spinning mass; speed from the pitch speed and a typical pitch of 0.62 diameters
        let revs = g.pitchSpeed / (0.62 * (g.ducted ? 0.12 : g.propDia))
        p.momentum = 0.6 * pow(d, 2.5) * d * d / 12 * 1.5 * revs * 2 * .pi
        p.spinDir = g.twin > 0 && i == 1 ? -1 : 1            // twins have handed propellers
        p.pFactor = g.ducted ? 0 : 0.1
        // Motor offset: built-up and scale models have the motor angled a little right and down so that power
        // changes do not pull them off line. Flat foamies are built with the thrust line dead straight.
        if !g.profile && !g.ducted && !g.pusher && g.twin == 0 {
            let rt = (g.rightThrust ?? 1.2) * deg, dn = (g.downThrust ?? (g.wingY > g.fuseH * 0.3 ? 2.5 : 0.8)) * deg
            p.axis = normalize(V3(sin(rt), -sin(dn), -cos(rt) * cos(dn)))
        }
        if g.pusher { p.spinDir = -1 }
        return p
    }
    spec.wingArea = area * nWings
    spec.downwashK = downK * (nWings > 1 ? 1.3 : 1)
    spec.construction = construction.label
    spec.mac = mac; spec.designMargin = staticMargin; spec.cgShift = cgShift
    spec.endurance = g.endurance ?? (glider ? 420 : (g.profile ? 200 : 240))
    if g.ducted || g.pusher { for i in spec.surfaces.indices { spec.surfaces[i].wash = 0 } }
    spec.contacts = contacts
    spec.cdA = g.cdA
    spec.handLaunch = g.handLaunch
    spec.category = g.category
    spec.stallSpeed = sqrt(2 * g.mass * gravity / (rho * area * nWings * wingEff * max(slope * (g.stall + g.camber * deg) * 0.92, 0.5)))
    spec.hasFlaps = g.flaps && g.ailStart > 0.4
    spec.hasRetracts = g.retracts && g.gear != .none && g.gear != .floats
    spec.hasFloats = g.gear == .floats
    if g.gear == .floats { spec.cdA += 0.006 }
    spec.smokePos = V3(0, -h * 0.4, nz + 0.55 * L)
    spec.parts = parts
    spec.soundBase = g.sound
    spec.blades = g.blades
    // engine character: scale models of piston and turbine aircraft sound like them; sport models, gliders and foamies are electric
    let original = ["Vortex 3D", "Jester Biplane", "Falcon Warbird", "Bushmaster STOL", "Twin Courier"].contains(g.name)
    let roundCowl = g.spinnerScale < 0.33 && g.fuseExp <= 2.4
    if g.ducted { spec.engineSound = 2 }
    else if original || g.profile { spec.engineSound = 0 }
    else if (g.category == "Scale Civil" || g.category == "Aerobatic") && g.sound >= 165 { spec.engineSound = 3 }
    else if g.category == "Warbirds" { spec.engineSound = 1; spec.radial = roundCowl; spec.cylinders = roundCowl ? 9 : 12 }
    else if g.category == "Scale Civil" { spec.engineSound = 1; spec.radial = roundCowl; spec.cylinders = roundCowl ? 9 : 4 }
    else if g.category == "Aerobatic" { spec.engineSound = 1; spec.radial = roundCowl; spec.cylinders = roundCowl ? 9 : 6 }
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

func makeQuad(shell: V4 = rgb(0.95, 0.55, 0.05), front: V4 = rgb(0.9, 0.1, 0.1), rear: V4 = rgb(0.95, 0.95, 0.95)) -> AircraftSpec {
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
    s.parts = buildQuadModel(motors: motors, shell: shell, front: front, rear: rear)
    s.eyeOffset = V3(0, 0.02, -0.14)
    return s
}

func makeHeli(body yel: V4 = rgb(0.98, 0.8, 0.05), canopy: V4 = rgb(0.1, 0.1, 0.12)) -> AircraftSpec {
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
    s.parts = buildHeliModel(rotorR: R, body: yel, accent: canopy)
    s.eyeOffset = V3(0, -0.02, -0.42)
    s.smokePos = V3(0, 0, 0.3)
    s.modes = []
    return s
}

/// Copy of a design scaled to a new wingspan (lengths scale linearly, mass and thrust roughly with volume).
func sized(_ base: PlaneGeom, span: Float, _ edit: (inout PlaneGeom) -> Void = { _ in }) -> PlaneGeom {
    var g = base
    let k = span / base.span, m = pow(k, 2.6)
    g.span = span; g.rootChord *= k; g.tipChord *= k; g.wingY *= k; g.wingLE *= k; g.sweep *= k
    g.noseZ *= k; g.fuseLen *= k; g.fuseW *= k; g.fuseH *= k
    g.stabSpan *= k; g.stabChord *= k; g.stabZ *= k; g.finH *= k; g.finChord *= k; g.finZ *= k
    g.propDia *= k; g.gearH *= k; g.track *= k; g.twin *= k; g.wheelR *= k
    if let u = g.upperWingY { g.upperWingY = u * k }
    g.mass *= m; g.thrust *= m; g.cdA *= k * k
    edit(&g)
    return g
}

/// Flat, empty ground for test flights made while the library is being built.
private let calibrationGround: Terrain = {
    var s = SiteSpec.builtIn[0]
    s.panorama = URL(fileURLWithPath: "/"); s.treeCount = 0; s.waterLevel = nil
    return Terrain(site: s)
}()

/// Peak roll, pitch and yaw rate (deg/s) at full stick from level flight at 1.6 times the stall speed.
func measureRates(_ spec: AircraftSpec) -> (roll: Float, pitch: Float, yaw: Float) {
    // `early` reads the rate a fifth of a second after the stick moves: in pitch the rate keeps building as the
    // aircraft slows and stalls, and it is the initial response that the pilot feels.
    func rate(_ set: (inout Controls) -> Void, _ pick: (Aircraft) -> Float, early: Bool = false) -> Float {
        let ac = Aircraft(spec); ac.unlimitedBattery = true
        ac.reset(pos: V3(0, 200, 0), heading: 0, speed: spec.stallSpeed * 1.6)
        var c = Controls(); c.throttle = 0.5
        for _ in 0..<150 { ac.step(dt: 0.001, c: c, terrain: calibrationGround, wind: .zero, rollMu: 0) }
        let base = pick(ac)
        set(&c)
        var peak: Float = 0
        for i in 0..<(early ? 200 : 450) {
            ac.step(dt: 0.001, c: c, terrain: calibrationGround, wind: .zero, rollMu: 0)
            peak = early ? (i == 199 ? abs(pick(ac) - base) : 0) : max(peak, abs(pick(ac)))
        }
        return peak / deg
    }
    // in pitch, also count two thirds of the peak, so an aircraft whose rate runs away after the first moment gets less throw
    let pitch = max(rate({ $0.elevator = 1 }, { $0.omega.x }, early: true), rate({ $0.elevator = 1 }, { $0.omega.x }) * 0.67)
    return (rate({ $0.aileron = 1 }, { $0.omega.z }), pitch, rate({ $0.rudder = 1 }, { $0.omega.y }))
}

/// Pitching moment (N m, nose-up positive) and lift (N) with the aircraft held at a fixed angle of attack and speed.
func pitchBalance(_ spec: AircraftSpec, alpha: Float, speed: Float, throttle: Float, elevator: Float = 0) -> (moment: Float, lift: Float) {
    let ac = Aircraft(spec); ac.unlimitedBattery = true
    ac.reset(pos: V3(0, 300, 0), heading: 0)
    var c = Controls(); c.throttle = throttle; c.elevator = elevator
    let v = V3(0, -speed * sin(alpha), -speed * cos(alpha))
    let q0 = ac.q
    // hold the attitude and speed while the motor, downwash and stall state settle
    for _ in 0..<230 { ac.vel = v; ac.omega = .zero; ac.q = q0; ac.step(dt: 0.001, c: c, terrain: calibrationGround, wind: .zero, rollMu: 0) }
    ac.vel = v; ac.omega = .zero; ac.q = q0
    ac.step(dt: 0.001, c: c, terrain: calibrationGround, wind: .zero, rollMu: 0)
    return (ac.omega.x / 0.001 * spec.inertia.x, ((ac.vel.y - v.y) / 0.001 + gravity) * spec.mass)
}

/// The static margin the simulated aircraft actually has: how far the centre of gravity sits ahead of the point
/// where lift changes act, as a fraction of the mean chord. Positive is nose-heavy and stable.
func measuredMargin(_ spec: AircraftSpec, throttle: Float) -> Float {
    let v = spec.stallSpeed * 1.7
    let a = pitchBalance(spec, alpha: 1.5 * deg, speed: v, throttle: throttle), b = pitchBalance(spec, alpha: 4 * deg, speed: v, throttle: throttle)
    let dL = b.lift - a.lift
    return abs(dL) > 1e-4 ? -(b.moment - a.moment) / dL / spec.mac : 0
}

/// Set the tailplane's incidence (or a tailless wing's reflex) so the aircraft flies level, hands off, at its
/// cruising speed. Without this a model balanced for slow flight pitches up as soon as it gathers speed.
func trimForCruise(_ spec0: AircraftSpec) -> AircraftSpec {
    var spec = spec0
    guard spec.kind == .airplane else { return spec }
    let glider = spec.category == "Gliders"
    let v = spec.stallSpeed * (glider ? 1.45 : 1.8), thr: Float = glider ? 0 : 0.45
    let tailless = !spec.surfaces.contains { $0.flapCh == 1 }
    func apply(_ d: Float, to s: inout AircraftSpec) {
        for i in s.surfaces.indices {
            if tailless { if s.surfaces[i].isWing { s.surfaces[i].cm0 += d } }
            else if s.surfaces[i].flapCh == 1 { s.surfaces[i].alpha0 += d }
        }
    }
    // angle of attack that carries the weight at cruise, from two test points
    func momentAt1g(_ s: AircraftSpec) -> Float {
        let a = pitchBalance(s, alpha: 1 * deg, speed: v, throttle: thr), b = pitchBalance(s, alpha: 5 * deg, speed: v, throttle: thr)
        let w = s.mass * gravity
        let k = clampf((w - a.lift) / max(b.lift - a.lift, 1e-4), -1, 2.5)
        return a.moment + (b.moment - a.moment) * k
    }
    let m0 = momentAt1g(spec)
    var probe = spec
    let step: Float = tailless ? 0.01 : 0.02
    apply(step, to: &probe)
    let slope = (momentAt1g(probe) - m0) / step
    guard abs(slope) > 1e-6 else { return spec }
    let d = clampf(-m0 / slope, tailless ? -0.04 : -0.12, tailless ? 0.08 : 0.12)
    apply(d, to: &spec)
    spec.trimSetting = d
    return spec
}

/// Scale the control throws so the aircraft rolls, pitches and yaws at the rates its category is set up for.
func calibrateRates(_ spec0: AircraftSpec) -> AircraftSpec {
    var spec = spec0
    guard spec.kind == .airplane, let target = rateTargets[spec.category] else { return spec }
    // long wings roll more slowly than the category norm, short ones faster
    let sizeK = clampf(pow(1.4 / spec.span, 0.35), 0.75, 1.3)
    for _ in 0..<2 {
        let m = measureRates(spec)
        let kr = clampf(target.roll * sizeK / max(m.roll, 1), 0.4, 2.2), kp = clampf(target.pitch / max(m.pitch, 1), 0.4, 2.2), ky = clampf(target.yaw / max(m.yaw, 1), 0.4, 2.2)
        for i in spec.surfaces.indices {
            switch spec.surfaces[i].flapCh {
            case 0: spec.surfaces[i].flapGain *= kr
            case 1: spec.surfaces[i].flapGain *= kp
            case 2: spec.surfaces[i].flapGain *= ky
            default: break
            }
            spec.surfaces[i].elevGain *= kp
        }
        // keep the visible deflections in step with the aerodynamic ones
        for i in spec.parts.indices {
            if case .hinge(let ch, let a) = spec.parts[i].anim {
                let k: Float = ch == 0 || ch == 5 || ch == 6 ? kr : (ch == 1 ? kp : (ch == 2 ? ky : 1))
                spec.parts[i].anim = .hinge(ch, clampf(a * k, -55 * deg, 55 * deg))
            }
        }
    }
    return spec
}

enum AircraftLibrary {
    static let all: [AircraftSpec] = {
        var trainer = PlaneGeom()
        trainer.name = "Skylark Trainer"; trainer.blurb = "Stable high-wing trainer with tricycle gear"
        trainer.mass = 2.2; trainer.span = 1.6; trainer.sound = 140
        trainer.tail = rgb(0.1, 0.2, 0.55); trainer.wingBottom = rgb(0.96, 0.96, 0.94)

        var acro = PlaneGeom()
        acro.name = "Vortex 3D"; acro.blurb = "Unlimited aerobat: hovers, knife-edges and tumbles"
        acro.mass = 1.5; acro.span = 1.25; acro.rootChord = 0.34; acro.tipChord = 0.22
        acro.wingY = 0; acro.wingLE = -0.075; acro.dihedral = 0; acro.incidence = 0; acro.camber = 0; acro.stall = 0.24
        acro.noseZ = -0.42; acro.fuseLen = 1.2; acro.fuseW = 0.1; acro.fuseH = 0.22
        acro.stabSpan = 0.5; acro.stabChord = 0.2; acro.stabZ = 0.6; acro.elevFrac = 0.55
        acro.finH = 0.26; acro.finChord = 0.24; acro.finZ = 0.56; acro.rudFrac = 0.6
        acro.ailFrac = 0.35; acro.ailStart = 0; acro.ailThrow = 34; acro.elevThrow = 42; acro.rudThrow = 42
        acro.thrust = 28; acro.pitchSpeed = 23; acro.propDia = 0.34; acro.washTail = 0.75; acro.washWing = 0.5
        acro.scheme = 1; acro.pants = true; acro.fuseExp = 2.5; acro.canopyLen = 0.13
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
        glider.scheme = 3; glider.fuseExp = 2.0; glider.canopyLen = 0.12
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
        jet.scheme = 4; jet.fuseExp = 2.0; jet.canopyLen = 0.14; jet.wheelR = 0.026
        jet.gear = .tricycle; jet.gearH = 0.13; jet.track = 0.14; jet.cdA = 0.005
        jet.fuse = rgb(0.55, 0.58, 0.62); jet.wingTop = rgb(0.5, 0.53, 0.57); jet.wingBottom = rgb(0.85, 0.87, 0.9)
        jet.retracts = true
        jet.tail = rgb(0.9, 0.35, 0.05); jet.accent = rgb(0.9, 0.35, 0.05); jet.sound = 420

        var warbird = PlaneGeom()
        warbird.name = "Falcon Warbird"; warbird.blurb = "Heavy low-wing fighter: fast, needs speed on landing"
        warbird.mass = 2.6; warbird.span = 1.4; warbird.rootChord = 0.30; warbird.tipChord = 0.18
        warbird.wingY = -0.05; warbird.wingLE = -0.075; warbird.dihedral = 5; warbird.incidence = 1; warbird.camber = 2; warbird.cd0 = 0.011
        warbird.noseZ = -0.45; warbird.fuseLen = 1.2; warbird.fuseW = 0.13; warbird.fuseH = 0.16
        warbird.stabSpan = 0.5; warbird.stabChord = 0.15; warbird.stabZ = 0.6; warbird.finH = 0.2; warbird.finChord = 0.17; warbird.finZ = 0.57
        warbird.ailThrow = 18; warbird.elevThrow = 16; warbird.rudThrow = 25
        warbird.thrust = 30; warbird.pitchSpeed = 33; warbird.propDia = 0.33; warbird.washTail = 0.5; warbird.washWing = 0.25
        warbird.scheme = 2; warbird.fuseExp = 2.2; warbird.canopyLen = 0.12
        warbird.gear = .taildragger; warbird.gearH = 0.2; warbird.track = 0.2; warbird.cdA = 0.008
        warbird.fuse = rgb(0.35, 0.4, 0.3); warbird.wingTop = rgb(0.33, 0.38, 0.28); warbird.wingBottom = rgb(0.7, 0.78, 0.85)
        warbird.flaps = true; warbird.retracts = true
        warbird.tail = rgb(0.8, 0.1, 0.1); warbird.accent = rgb(0.9, 0.85, 0.2); warbird.sound = 130

        var bush = PlaneGeom()
        bush.name = "Bushmaster STOL"; bush.blurb = "Slow high-wing taildragger for short take-offs and landings"
        bush.mass = 2.0; bush.span = 1.8; bush.rootChord = 0.28; bush.tipChord = 0.28
        bush.wingY = 0.11; bush.wingLE = -0.055; bush.dihedral = 2; bush.incidence = 2.5; bush.camber = 4.5
        bush.noseZ = -0.42; bush.fuseLen = 1.25; bush.fuseW = 0.13; bush.fuseH = 0.18
        bush.stabSpan = 0.6; bush.stabChord = 0.18; bush.stabZ = 0.62; bush.finH = 0.24; bush.finChord = 0.2; bush.finZ = 0.6
        bush.ailThrow = 22; bush.elevThrow = 24; bush.rudThrow = 30
        bush.thrust = 21; bush.pitchSpeed = 18; bush.propDia = 0.33; bush.washTail = 0.6; bush.washWing = 0.3
        bush.scheme = 5; bush.struts = true; bush.wheelR = 0.06; bush.canopyLen = 0.1
        bush.gear = .taildragger; bush.gearH = 0.25; bush.track = 0.24; bush.cdA = 0.016
        bush.fuse = rgb(0.98, 0.8, 0.1); bush.wingTop = rgb(0.98, 0.8, 0.1); bush.wingBottom = rgb(0.12, 0.12, 0.12)
        bush.flaps = true
        bush.tail = rgb(0.12, 0.12, 0.12); bush.accent = rgb(0.98, 0.8, 0.1); bush.sound = 110

        var park = PlaneGeom()
        park.name = "Feather Park Flyer"; park.blurb = "Featherweight slow flyer for calm air and small spaces"
        park.mass = 0.32; park.span = 0.95; park.rootChord = 0.2; park.tipChord = 0.17
        park.wingY = 0.06; park.wingLE = -0.035; park.dihedral = 6; park.incidence = 2.5; park.camber = 4; park.thick = 0.08
        park.noseZ = -0.26; park.fuseLen = 0.78; park.fuseW = 0.06; park.fuseH = 0.08
        park.stabSpan = 0.34; park.stabChord = 0.11; park.stabZ = 0.39; park.finH = 0.14; park.finChord = 0.12; park.finZ = 0.38
        park.ailThrow = 18; park.elevThrow = 18; park.rudThrow = 25
        park.thrust = 3.6; park.pitchSpeed = 12; park.propDia = 0.18; park.washTail = 0.5; park.washWing = 0.2
        park.wheelR = 0.022; park.fuseExp = 3.2
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
        racer.scheme = 4; racer.fuseExp = 2.0; racer.wheelR = 0.024; racer.canopyLen = 0.13
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
        twin.fuseExp = 2.2; twin.canopyLen = 0.07
        twin.gear = .tricycle; twin.gearH = 0.2; twin.track = 0.3; twin.cdA = 0.014
        twin.fuse = rgb(0.93, 0.93, 0.95); twin.wingTop = rgb(0.93, 0.93, 0.95); twin.wingBottom = rgb(0.15, 0.3, 0.6)
        twin.flaps = true; twin.retracts = true
        twin.tail = rgb(0.15, 0.3, 0.6); twin.accent = rgb(0.9, 0.5, 0.1); twin.sound = 150

        var bipe = PlaneGeom()
        bipe.name = "Jester Biplane"; bipe.blurb = "Compact aerobatic biplane with a fast roll rate"
        bipe.mass = 1.7; bipe.span = 1.0; bipe.rootChord = 0.2; bipe.tipChord = 0.19; bipe.upperWingY = 0.19
        bipe.wingY = -0.04; bipe.wingLE = -0.03; bipe.dihedral = 1.5; bipe.incidence = 0.5; bipe.camber = 0.5; bipe.stall = 0.25
        bipe.noseZ = -0.36; bipe.fuseLen = 0.95; bipe.fuseW = 0.12; bipe.fuseH = 0.16
        bipe.stabSpan = 0.42; bipe.stabChord = 0.16; bipe.stabZ = 0.46; bipe.elevFrac = 0.5; bipe.finH = 0.2; bipe.finChord = 0.18; bipe.finZ = 0.43; bipe.rudFrac = 0.55
        bipe.ailFrac = 0.3; bipe.ailStart = 0; bipe.ailThrow = 24; bipe.elevThrow = 28; bipe.rudThrow = 35
        bipe.thrust = 27; bipe.pitchSpeed = 24; bipe.propDia = 0.3; bipe.washTail = 0.7; bipe.washWing = 0.4
        bipe.scheme = 1; bipe.pants = true; bipe.fuseExp = 2.4
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
        sail.scheme = 3; sail.fuseExp = 2.0; sail.canopyLen = 0.11
        sail.gear = .none; sail.cdA = 0.005; sail.handLaunch = true
        sail.fuse = rgb(0.97, 0.97, 0.97); sail.wingTop = rgb(0.97, 0.97, 0.97); sail.wingBottom = rgb(0.95, 0.45, 0.05)
        sail.tail = rgb(0.95, 0.45, 0.05); sail.accent = rgb(0.2, 0.25, 0.6); sail.sound = 105


        // ---- categories for the original designs
        trainer.category = "Trainers & Sport"; park.category = "Trainers & Sport"; racer.category = "Trainers & Sport"
        bush.category = "Scale Civil"; twin.category = "Scale Civil"; warbird.category = "Warbirds"
        acro.category = "Aerobatic"; bipe.category = "Aerobatic"; jet.category = "Jets"
        glider.category = "Gliders"; sail.category = "Gliders"

        // ---- scale models of real aircraft
        let silver = rgb(0.36, 0.38, 0.41), cream = rgb(0.95, 0.94, 0.9)
        let j3 = sized(bush, span: 1.9) {
            $0.name = "Piper J-3 Cub"; $0.blurb = "The classic yellow high-wing taildragger: slow, gentle, honest"
            $0.flaps = false; $0.wheelR = 0.05; $0.thrust *= 0.75; $0.camber = 4; $0.sound = 105
        }
        let c182 = sized(trainer, span: 1.75) {
            $0.name = "Cessna 182 Skylane"; $0.blurb = "Scale high-wing tourer with tricycle gear and flaps"; $0.category = "Scale Civil"
            $0.scheme = 6; $0.struts = true; $0.flaps = true; $0.fuseExp = 2.5; $0.canopyLen = 0.13; $0.mass *= 1.12
            $0.fuse = cream; $0.wingTop = cream; $0.wingBottom = cream; $0.tail = cream; $0.accent = rgb(0.1, 0.25, 0.6); $0.spinnerColor = cream; $0.sound = 120
        }
        let pc6 = sized(bush, span: 2.0) {
            $0.name = "Pilatus PC-6 Porter"; $0.blurb = "Swiss STOL workhorse: long turbine nose, huge flaps, short strips"
            $0.scheme = 6; $0.fuseExp = 3.3; $0.noseZ *= 1.25; $0.fuseLen *= 1.12; $0.blades = 3; $0.spinnerScale = 0.3; $0.thrust *= 1.25; $0.wheelR = 0.05
            $0.fuse = cream; $0.wingTop = cream; $0.wingBottom = cream; $0.tail = cream; $0.accent = rgb(0.8, 0.08, 0.08); $0.spinnerColor = silver; $0.sound = 170
        }
        let beaver = sized(bush, span: 1.8) {
            $0.name = "DHC-2 Beaver"; $0.blurb = "Radial-engined bush plane, steady and strong"
            $0.scheme = 6; $0.fuseExp = 2.3; $0.spinnerScale = 0.18; $0.mass *= 1.15; $0.wheelR = 0.05
            $0.fuse = rgb(0.95, 0.75, 0.1); $0.wingTop = rgb(0.95, 0.75, 0.1); $0.wingBottom = rgb(0.95, 0.75, 0.1); $0.tail = rgb(0.95, 0.75, 0.1)
            $0.accent = rgb(0.1, 0.2, 0.5); $0.spinnerColor = silver; $0.sound = 95
        }
        let storch = sized(bush, span: 1.7) {
            $0.name = "Fieseler Storch"; $0.blurb = "Stilt-legged STOL observation plane that almost hovers into wind"
            $0.scheme = 7; $0.fuseExp = 3.2; $0.gearH *= 1.3; $0.camber = 5.5; $0.mass *= 0.85; $0.canopyLen = 0.15
            $0.fuse = rgb(0.2, 0.26, 0.15); $0.wingTop = rgb(0.2, 0.26, 0.15); $0.accent = rgb(0.1, 0.13, 0.09); $0.wingBottom = rgb(0.42, 0.52, 0.6)
            $0.tail = rgb(0.2, 0.26, 0.15); $0.spinnerColor = rgb(0.1, 0.13, 0.09); $0.sound = 100
        }
        let p51 = sized(warbird, span: 1.5) {
            $0.name = "P-51D Mustang"; $0.blurb = "Polished-metal long-range fighter: fast, slippery, lands hot"
            $0.scheme = 2; $0.blades = 4; $0.canopyLen = 0.1; $0.spinnerColor = rgb(0.8, 0.1, 0.1)
            $0.fuse = silver; $0.wingTop = silver; $0.wingBottom = silver; $0.tail = rgb(0.8, 0.1, 0.1); $0.accent = silver
        }
        let spit = sized(warbird, span: 1.5) {
            $0.name = "Supermarine Spitfire"; $0.blurb = "Graceful wide-chord wing, light on the controls"
            $0.scheme = 7; $0.rootChord *= 1.12; $0.tipChord *= 0.72; $0.blades = 4; $0.track *= 0.75; $0.mass *= 0.95
            $0.fuse = rgb(0.16, 0.22, 0.12); $0.wingTop = rgb(0.16, 0.22, 0.12); $0.accent = rgb(0.22, 0.25, 0.27); $0.wingBottom = rgb(0.44, 0.5, 0.55)
            $0.tail = rgb(0.16, 0.22, 0.12); $0.spinnerColor = rgb(0.1, 0.1, 0.1)
        }
        let bf109 = sized(warbird, span: 1.4) {
            $0.name = "Messerschmitt Bf 109"; $0.blurb = "Small, heavy, narrow-track fighter: tricky on the ground"
            $0.scheme = 7; $0.track *= 0.6; $0.blades = 3; $0.mass *= 1.05; $0.canopyLen = 0.09
            $0.fuse = rgb(0.27, 0.29, 0.31); $0.wingTop = rgb(0.27, 0.29, 0.31); $0.accent = rgb(0.15, 0.17, 0.19); $0.wingBottom = rgb(0.42, 0.5, 0.58)
            $0.tail = rgb(0.27, 0.29, 0.31); $0.spinnerColor = rgb(0.9, 0.8, 0.1)
        }
        let zero = sized(warbird, span: 1.5) {
            $0.name = "Mitsubishi A6M Zero"; $0.blurb = "Very light radial fighter that turns on a wingtip"
            $0.scheme = 8; $0.fuseExp = 2.0; $0.spinnerScale = 0.24; $0.blades = 3; $0.mass *= 0.85; $0.rootChord *= 1.1
            let grey = rgb(0.48, 0.5, 0.46)
            $0.fuse = grey; $0.wingTop = grey; $0.wingBottom = grey; $0.tail = grey; $0.accent = rgb(0.06, 0.06, 0.08); $0.spinnerColor = silver; $0.sound = 115
        }
        let hellcat = sized(warbird, span: 1.55) {
            $0.name = "Grumman F6F Hellcat"; $0.blurb = "Big, rugged carrier fighter with a deep radial growl"
            $0.scheme = 8; $0.fuseExp = 2.0; $0.fuseW *= 1.2; $0.fuseH *= 1.12; $0.spinnerScale = 0.2; $0.blades = 3; $0.mass *= 1.12; $0.thrust *= 1.1
            let navy = rgb(0.07, 0.11, 0.24)
            $0.fuse = navy; $0.wingTop = navy; $0.wingBottom = navy; $0.tail = navy; $0.accent = navy; $0.spinnerColor = silver; $0.sound = 100
        }
        let mossie = sized(twin, span: 1.9) {
            $0.name = "DH Mosquito"; $0.blurb = "Fast twin-engine wooden wonder; watch the swing on take-off"; $0.category = "Warbirds"
            $0.scheme = 7; $0.gear = .taildragger; $0.fuseExp = 2.1; $0.wingY = -0.01; $0.blades = 3; $0.thrust *= 1.25; $0.pitchSpeed = 32; $0.cdA *= 0.7
            $0.fuse = rgb(0.16, 0.22, 0.12); $0.wingTop = rgb(0.16, 0.22, 0.12); $0.accent = rgb(0.22, 0.25, 0.27); $0.wingBottom = rgb(0.44, 0.48, 0.5)
            $0.tail = rgb(0.16, 0.22, 0.12); $0.spinnerColor = rgb(0.1, 0.1, 0.1)
        }
        let dc3 = sized(twin, span: 2.1) {
            $0.name = "Douglas DC-3"; $0.blurb = "Stately twin airliner: wide circuits, wheel landings"
            $0.scheme = 8; $0.gear = .taildragger; $0.fuseExp = 2.0; $0.wingY = -0.035; $0.sweep = 0.07; $0.blades = 3; $0.canopyLen = 0.05; $0.dihedral = 5
            $0.fuse = silver; $0.wingTop = silver; $0.wingBottom = silver; $0.tail = silver; $0.accent = silver; $0.spinnerColor = rgb(0.1, 0.1, 0.1); $0.sound = 95
        }
        let extra = sized(acro, span: 1.5) {
            $0.name = "Extra 300"; $0.blurb = "Unlimited competition aerobat with a straight-edged wing"; $0.category = "Aerobatic"
            $0.fuse = rgb(0.96, 0.96, 0.96); $0.wingTop = rgb(0.85, 0.08, 0.08); $0.wingBottom = rgb(0.96, 0.96, 0.96); $0.tail = rgb(0.85, 0.08, 0.08)
            $0.accent = rgb(0.96, 0.96, 0.96); $0.spinnerColor = rgb(0.08, 0.08, 0.08); $0.blades = 3
        }
        let pitts = sized(bipe, span: 1.1) {
            $0.name = "Pitts Special"; $0.blurb = "Tiny snap-rolling biplane: short-coupled and lively"
            $0.fuse = rgb(0.85, 0.08, 0.08); $0.wingTop = rgb(0.85, 0.08, 0.08); $0.wingBottom = rgb(0.97, 0.97, 0.97); $0.tail = rgb(0.97, 0.97, 0.97)
            $0.accent = rgb(0.97, 0.97, 0.97); $0.fuseExp = 2.1
        }
        let stearman = sized(bipe, span: 1.4) {
            $0.name = "Boeing Stearman"; $0.blurb = "Big open-cockpit trainer biplane with a lazy radial"; $0.category = "Scale Civil"
            $0.scheme = 8; $0.pants = false; $0.fuseExp = 2.2; $0.spinnerScale = 0.15; $0.incidence = 2; $0.camber = 3; $0.dihedral = 2.5
            $0.thrust *= 0.5; $0.ailThrow = 18; $0.elevThrow = 20; $0.rudThrow = 28; $0.washTail = 0.5; $0.wheelR = 0.05; $0.gearH *= 1.1
            let yel = rgb(0.96, 0.78, 0.08)
            $0.fuse = rgb(0.1, 0.2, 0.5); $0.wingTop = yel; $0.wingBottom = yel; $0.tail = yel; $0.accent = silver; $0.spinnerColor = silver; $0.sound = 90
        }
        let moth = sized(bipe, span: 1.5) {
            $0.name = "DH Tiger Moth"; $0.blurb = "Gentle 1930s trainer biplane: lots of rudder, little power"; $0.category = "Scale Civil"
            $0.scheme = 8; $0.pants = false; $0.fuseExp = 3.0; $0.sweep = 0.06; $0.incidence = 2.5; $0.camber = 3.5; $0.dihedral = 3
            $0.mass *= 0.8; $0.thrust *= 0.36; $0.ailThrow = 16; $0.elevThrow = 18; $0.rudThrow = 28; $0.washTail = 0.5; $0.wheelR = 0.045
            let yel = rgb(0.96, 0.8, 0.1)
            $0.fuse = silver; $0.wingTop = yel; $0.wingBottom = yel; $0.tail = silver; $0.accent = silver; $0.spinnerColor = silver; $0.sound = 85
        }
        let pc7 = sized(warbird, span: 1.45) {
            $0.name = "Pilatus PC-7"; $0.blurb = "Swiss turboprop trainer: tandem canopy, crisp aerobatics"; $0.category = "Aerobatic"
            $0.scheme = 0; $0.gear = .tricycle; $0.gearH = 0.17; $0.fuseExp = 2.0; $0.canopyLen = 0.17; $0.blades = 3; $0.spinnerScale = 0.3; $0.mass *= 0.92
            $0.ailThrow = 22; $0.elevThrow = 20
            $0.fuse = rgb(0.96, 0.96, 0.96); $0.wingTop = rgb(0.85, 0.08, 0.08); $0.wingBottom = rgb(0.96, 0.96, 0.96); $0.tail = rgb(0.85, 0.08, 0.08)
            $0.accent = rgb(0.96, 0.96, 0.96); $0.spinnerColor = silver; $0.sound = 175
        }
        var f16 = jet
        f16.name = "F-16 Fighting Falcon"; f16.blurb = "EDF fighter with a cropped delta wing: fast, needs room"
        f16.mass = 1.5; f16.span = 0.9; f16.rootChord = 0.42; f16.tipChord = 0.12; f16.sweep = 0.3; f16.wingLE = -0.2; f16.wingY = 0; f16.dihedral = 0
        f16.thrust = 20; f16.pitchSpeed = 62; f16.stabSpan = 0.5; f16.stabChord = 0.17; f16.stabZ = 0.43; f16.finH = 0.27; f16.finChord = 0.24; f16.finZ = 0.33
        f16.noseZ = -0.58; f16.fuseLen = 1.18; f16.canopyLen = 0.13; f16.ailThrow = 14; f16.elevThrow = 14
        f16.fuse = rgb(0.3, 0.33, 0.37); f16.wingTop = rgb(0.27, 0.3, 0.34); f16.wingBottom = rgb(0.42, 0.45, 0.5); f16.tail = rgb(0.22, 0.25, 0.29); f16.accent = rgb(0.2, 0.22, 0.26)
        var sabre = jet
        sabre.name = "F-86 Sabre"; sabre.blurb = "Swept-wing classic jet with a nose intake; smooth and fast"
        sabre.mass = 1.5; sabre.span = 1.05; sabre.rootChord = 0.3; sabre.tipChord = 0.15; sabre.sweep = 0.34; sabre.wingLE = -0.21; sabre.wingY = -0.02; sabre.dihedral = 2
        sabre.thrust = 18; sabre.pitchSpeed = 60; sabre.noseIntake = true; sabre.fuseW = 0.12; sabre.fuseH = 0.13; sabre.finH = 0.24; sabre.canopyLen = 0.12
        sabre.fuse = silver; sabre.wingTop = silver; sabre.wingBottom = silver; sabre.tail = silver; sabre.accent = rgb(0.95, 0.8, 0.1)
        let ask21 = sized(sail, span: 3.2) {
            $0.name = "ASK 21"; $0.blurb = "Two-seat training sailplane with a T-tail, here with a nose motor to self-launch"
            $0.tTail = true; $0.finH *= 1.15; $0.stabSpan *= 1.1; $0.canopyLen = 0.16
            $0.fuse = rgb(0.97, 0.97, 0.97); $0.wingTop = rgb(0.97, 0.97, 0.97); $0.wingBottom = rgb(0.85, 0.1, 0.1); $0.tail = rgb(0.85, 0.1, 0.1); $0.accent = rgb(0.97, 0.97, 0.97)
        }
        var scale = [j3, c182, pc6, beaver, storch, p51, spit, bf109, zero, hellcat, mossie, dc3, extra, pitts, stearman, moth, pc7, f16, sabre, ask21]
        for i in scale.indices where scale[i].category == "Sport" { scale[i].category = "Scale Civil" }

        // ---- flat foam 3D planes: plate fuselage, slab wings, huge surfaces, more thrust than weight
        var flatty = PlaneGeom()
        flatty.name = "Flatty 3D"; flatty.blurb = "Flat EPP profile plane: hovers, harriers and bounces off the ground"; flatty.category = "Foam 3D"
        flatty.profile = true; flatty.scheme = 9; flatty.tough = 2.2
        flatty.mass = 0.19; flatty.span = 0.82; flatty.rootChord = 0.27; flatty.tipChord = 0.2
        flatty.wingY = 0; flatty.wingLE = -0.075; flatty.dihedral = 0; flatty.incidence = 0; flatty.camber = 0; flatty.thick = 0.028; flatty.stall = 0.2; flatty.cd0 = 0.02
        flatty.noseZ = -0.3; flatty.fuseLen = 0.85; flatty.fuseW = 0.008; flatty.fuseH = 0.2
        flatty.stabSpan = 0.36; flatty.stabChord = 0.17; flatty.stabZ = 0.37; flatty.elevFrac = 0.65; flatty.finH = 0.17; flatty.finChord = 0.2; flatty.finZ = 0.36; flatty.rudFrac = 0.65
        flatty.ailFrac = 0.4; flatty.ailStart = 0; flatty.ailThrow = 42; flatty.elevThrow = 48; flatty.rudThrow = 48
        flatty.thrust = 4.3; flatty.pitchSpeed = 10; flatty.propDia = 0.2; flatty.washTail = 0.85; flatty.washWing = 0.6
        flatty.gear = .taildragger; flatty.gearH = 0.1; flatty.track = 0.09; flatty.wheelR = 0.018; flatty.cdA = 0.006
        flatty.fuse = rgb(0.97, 0.97, 0.97); flatty.wingTop = rgb(0.97, 0.97, 0.97); flatty.wingBottom = rgb(0.97, 0.97, 0.97)
        flatty.tail = rgb(0.9, 0.1, 0.5); flatty.accent = rgb(0.1, 0.6, 0.9); flatty.sound = 230

        var f3p = flatty
        f3p.name = "F3P Indoor Aerobat"; f3p.blurb = "90-gram indoor pattern ship: walking-pace manoeuvres in calm air"
        f3p.mass = 0.09; f3p.span = 0.8; f3p.rootChord = 0.31; f3p.tipChord = 0.24; f3p.thick = 0.02; f3p.thrust = 2.3; f3p.pitchSpeed = 7.5; f3p.propDia = 0.22
        f3p.gear = .none; f3p.handLaunch = true; f3p.fuseH = 0.24; f3p.cdA = 0.012
        f3p.tail = rgb(0.95, 0.5, 0.05); f3p.accent = rgb(0.5, 0.2, 0.75); f3p.sound = 250

        let edgeXL = sized(flatty, span: 1.05) {
            $0.name = "Profile Edge XL"; $0.blurb = "Metre-span EPP profile aerobat with punch for outdoor 3D in a breeze"
            $0.mass = 0.48; $0.thrust = 11.5; $0.pitchSpeed = 13; $0.tail = rgb(0.1, 0.1, 0.12); $0.accent = rgb(0.95, 0.75, 0.05); $0.sound = 200
        }
        var foamBipe = flatty
        foamBipe.name = "Foam Bipe 3D"; foamBipe.blurb = "Flat-plate biplane: enormous lift and drag, slowest hover of all"
        foamBipe.upperWingY = 0.2; foamBipe.wingY = -0.03; foamBipe.span = 0.74; foamBipe.mass = 0.26; foamBipe.thrust = 6.2; foamBipe.fuseH = 0.26
        foamBipe.tail = rgb(0.1, 0.65, 0.3); foamBipe.accent = rgb(0.95, 0.3, 0.1)
        let foamies = [flatty, f3p, edgeXL, foamBipe]


        // ---- fifty more: scale models of real aircraft plus original designs
        func mk(_ base: PlaneGeom, _ span: Float, _ name: String, _ cat: String, _ blurb: String, scheme: Int? = nil,
                fuse: V4? = nil, top: V4? = nil, bottom: V4? = nil, tail: V4? = nil, accent: V4? = nil, _ edit: (inout PlaneGeom) -> Void = { _ in }) -> PlaneGeom {
            sized(base, span: span) {
                $0.name = name; $0.category = cat; $0.blurb = blurb
                if let v = scheme { $0.scheme = v }
                if let v = fuse { $0.fuse = v }
                if let v = top { $0.wingTop = v }
                if let v = bottom { $0.wingBottom = v }
                if let v = tail { $0.tail = v }
                if let v = accent { $0.accent = v }
                edit(&$0)
            }
        }
        let white = rgb(0.96, 0.96, 0.95), red = rgb(0.85, 0.08, 0.08), blue = rgb(0.08, 0.22, 0.6), navy = rgb(0.06, 0.1, 0.24), yellow = rgb(0.97, 0.8, 0.08)
        let orange = rgb(0.95, 0.45, 0.05), green = rgb(0.1, 0.45, 0.2), olive = rgb(0.2, 0.25, 0.14), sand = rgb(0.6, 0.5, 0.34), grey = rgb(0.4, 0.42, 0.45), black = rgb(0.07, 0.07, 0.08)
        let more: [PlaneGeom] = [
            // Scale civil
            mk(bush, 1.8, "Piper PA-18 Super Cub", "Scale Civil", "The Cub with more power and flaps: the definitive bush taildragger", fuse: white, top: white, bottom: white, tail: red, accent: red) { $0.scheme = 6; $0.thrust *= 1.1 },
            mk(trainer, 1.5, "Cessna 152", "Scale Civil", "The little two-seat trainer half the world learned on", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: red) { $0.struts = true; $0.fuseExp = 2.5; $0.spinnerColor = white },
            mk(trainer, 1.7, "Cessna 172 Skyhawk", "Scale Civil", "Four-seat high-wing tourer: stable, predictable, unhurried", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: green) { $0.struts = true; $0.flaps = true; $0.fuseExp = 2.5; $0.canopyLen = 0.13; $0.spinnerColor = white },
            mk(bush, 2.2, "Cessna 208 Caravan", "Scale Civil", "Big single-turboprop utility hauler on tricycle gear", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: blue) {
                $0.gear = .tricycle; $0.gearH = 0.24; $0.noseZ *= 1.2; $0.fuseLen *= 1.15; $0.blades = 3; $0.spinnerScale = 0.3; $0.thrust *= 1.2; $0.wheelR = 0.045; $0.fuseExp = 3; $0.spinnerColor = grey; $0.sound = 170 },
            mk(warbird, 1.5, "Piper PA-28 Cherokee", "Scale Civil", "Low-wing club tourer with a constant-chord wing and fixed gear", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: orange) {
                $0.gear = .tricycle; $0.gearH = 0.17; $0.retracts = false; $0.tipChord = $0.rootChord; $0.mass *= 0.75; $0.thrust *= 0.6; $0.pitchSpeed = 24; $0.blades = 2; $0.canopyLen = 0.14; $0.spinnerColor = white; $0.camber = 3 },
            mk(warbird, 1.6, "Beechcraft Bonanza", "Scale Civil", "Fast retractable tourer with slippery lines", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: navy) {
                $0.gear = .tricycle; $0.gearH = 0.17; $0.mass *= 0.85; $0.thrust *= 0.75; $0.pitchSpeed = 28; $0.blades = 3; $0.canopyLen = 0.15; $0.spinnerColor = grey },
            mk(warbird, 1.65, "Cirrus SR22", "Scale Civil", "Modern composite tourer: sleek, quick, fixed spatted gear", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: rgb(0.05, 0.35, 0.55)) {
                $0.gear = .tricycle; $0.gearH = 0.17; $0.retracts = false; $0.pants = true; $0.mass *= 0.82; $0.thrust *= 0.7; $0.pitchSpeed = 28; $0.blades = 3; $0.canopyLen = 0.16; $0.spinnerColor = grey; $0.tipChord *= 0.85 },
            mk(warbird, 1.75, "Diamond DA40", "Scale Civil", "Long-winged T-tail trainer that glides like a sailplane", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: red) {
                $0.gear = .tricycle; $0.gearH = 0.17; $0.retracts = false; $0.pants = true; $0.tTail = true; $0.mass *= 0.7; $0.thrust *= 0.55; $0.pitchSpeed = 24; $0.blades = 3
                $0.canopyLen = 0.17; $0.rootChord *= 0.85; $0.tipChord *= 0.7; $0.spinnerColor = white },
            mk(warbird, 1.5, "Robin DR400", "Scale Civil", "French club favourite with cranked wingtips and a big bubble canopy", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: blue) {
                $0.gear = .tricycle; $0.gearH = 0.17; $0.retracts = false; $0.pants = true; $0.dihedral = 7; $0.mass *= 0.72; $0.thrust *= 0.58; $0.pitchSpeed = 24; $0.blades = 2; $0.canopyLen = 0.18; $0.spinnerColor = white },
            mk(twin, 2.0, "DHC-6 Twin Otter", "Scale Civil", "High-wing twin turboprop that gets in and out of anywhere", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: red) {
                $0.wingY = 0.1; $0.struts = true; $0.retracts = false; $0.blades = 3; $0.fuseExp = 3; $0.camber = 4; $0.canopyLen = 0.06; $0.wheelR = 0.045 },
            mk(twin, 1.9, "Beechcraft King Air", "Scale Civil", "Executive twin turboprop with a T-tail", scheme: 6, fuse: white, top: white, bottom: white, tail: white, accent: navy) {
                $0.wingY = -0.03; $0.tTail = true; $0.blades = 4; $0.thrust *= 1.2; $0.pitchSpeed = 30; $0.canopyLen = 0.06; $0.cdA *= 0.75 },
            mk(warbird, 1.9, "Pilatus PC-12", "Scale Civil", "Swiss single-turboprop business aircraft: T-tail, long wing, five-blade propeller", scheme: 6,
               fuse: white, top: white, bottom: white, tail: white, accent: rgb(0.75, 0.1, 0.1)) {
                $0.gear = .tricycle; $0.gearH = 0.17; $0.tTail = true; $0.blades = 5; $0.spinnerScale = 0.26; $0.spinnerColor = grey; $0.fuseExp = 2.1
                $0.fuseW *= 1.15; $0.fuseH *= 1.15; $0.canopyLen = 0.07; $0.dihedral = 6; $0.sound = 175; $0.finH *= 1.15 },
            mk(bipe, 1.9, "Antonov An-2", "Scale Civil", "Enormous radial biplane: flies slower than anything its size should", scheme: 8, fuse: green, top: green, bottom: rgb(0.6, 0.7, 0.8), tail: green, accent: grey) {
                $0.pants = false; $0.fuseExp = 2.4; $0.fuseW *= 1.25; $0.spinnerScale = 0.14; $0.blades = 4; $0.incidence = 2.5; $0.camber = 4.5; $0.dihedral = 2
                $0.thrust *= 0.42; $0.pitchSpeed = 18; $0.ailThrow = 16; $0.elevThrow = 18; $0.rudThrow = 26; $0.washTail = 0.5; $0.wheelR = 0.05; $0.spinnerColor = grey; $0.sound = 85 },
            // Warbirds
            mk(warbird, 1.5, "Hawker Hurricane", "Warbirds", "Sturdy, thick-winged fighter: gentler than it looks", scheme: 7, fuse: rgb(0.2, 0.26, 0.15), top: rgb(0.2, 0.26, 0.15), bottom: rgb(0.45, 0.52, 0.56), tail: rgb(0.2, 0.26, 0.15), accent: rgb(0.3, 0.24, 0.16)) {
                $0.thick = 0.15; $0.rootChord *= 1.08; $0.blades = 3; $0.mass *= 0.98; $0.spinnerColor = black },
            mk(warbird, 1.55, "P-47 Thunderbolt", "Warbirds", "Seven-tonne brute in miniature: heavy, fast, and needs the whole runway", scheme: 2, fuse: grey, top: grey, bottom: grey, tail: yellow, accent: grey) {
                $0.fuseW *= 1.25; $0.fuseH *= 1.2; $0.fuseExp = 2; $0.spinnerScale = 0.2; $0.blades = 4; $0.mass *= 1.2; $0.thrust *= 1.2; $0.spinnerColor = grey; $0.sound = 100 },
            mk(warbird, 1.45, "Curtiss P-40 Warhawk", "Warbirds", "Shark-nosed desert fighter with honest handling", scheme: 7, fuse: sand, top: sand, bottom: rgb(0.5, 0.6, 0.68), tail: sand, accent: rgb(0.38, 0.3, 0.2)) { $0.blades = 3; $0.spinnerColor = red },
            mk(warbird, 1.4, "Focke-Wulf Fw 190", "Warbirds", "Compact radial fighter with a wide, forgiving undercarriage and a fast roll", scheme: 7, fuse: rgb(0.3, 0.33, 0.35), top: rgb(0.3, 0.33, 0.35), bottom: rgb(0.45, 0.55, 0.62), tail: rgb(0.3, 0.33, 0.35), accent: rgb(0.17, 0.2, 0.2)) {
                $0.fuseExp = 2; $0.spinnerScale = 0.3; $0.blades = 3; $0.track *= 1.3; $0.ailThrow = 22; $0.spinnerColor = black; $0.sound = 110 },
            mk(warbird, 1.35, "Yakovlev Yak-3", "Warbirds", "Small, light and agile: the dogfighter of the set", scheme: 7, fuse: rgb(0.28, 0.32, 0.3), top: rgb(0.28, 0.32, 0.3), bottom: rgb(0.45, 0.58, 0.68), tail: rgb(0.28, 0.32, 0.3), accent: rgb(0.16, 0.2, 0.16)) {
                $0.mass *= 0.85; $0.blades = 3; $0.spinnerColor = red },
            mk(warbird, 1.6, "North American T-6 Texan", "Warbirds", "The advanced trainer: radial engine, long canopy, and a ground-loop waiting to happen", scheme: 8, fuse: yellow, top: yellow, bottom: yellow, tail: yellow, accent: black) {
                $0.fuseExp = 2; $0.spinnerScale = 0.16; $0.canopyLen = 0.18; $0.mass *= 0.9; $0.thrust *= 0.8; $0.pitchSpeed = 28; $0.blades = 2; $0.spinnerColor = grey; $0.sound = 95 },
            mk(warbird, 1.5, "Hawker Sea Fury", "Warbirds", "The last and fastest of the piston fighters, with a five-blade prop", scheme: 8, fuse: navy, top: navy, bottom: rgb(0.55, 0.62, 0.66), tail: navy, accent: navy) {
                $0.fuseExp = 2; $0.spinnerScale = 0.32; $0.blades = 5; $0.thrust *= 1.2; $0.pitchSpeed = 37; $0.mass *= 1.08; $0.spinnerColor = navy; $0.sound = 105 },
            mk(twin, 1.9, "Douglas A-26 Invader", "Warbirds", "Sleek twin-engine attack bomber on tricycle gear", scheme: 8, fuse: grey, top: grey, bottom: grey, tail: grey, accent: grey) {
                $0.wingY = 0.05; $0.blades = 3; $0.thrust *= 1.3; $0.pitchSpeed = 32; $0.cdA *= 0.75; $0.fuseExp = 2; $0.canopyLen = 0.07; $0.spinnerColor = black },
            mk(bipe, 1.3, "Sopwith Camel", "Warbirds", "Twitchy rotary-engined scout of 1917: turns right in a flash", scheme: 8, fuse: rgb(0.3, 0.32, 0.18), top: rgb(0.3, 0.32, 0.18), bottom: rgb(0.8, 0.76, 0.6), tail: rgb(0.3, 0.32, 0.18), accent: rgb(0.8, 0.76, 0.6)) {
                $0.pants = false; $0.fuseExp = 2.6; $0.spinnerScale = 0.12; $0.incidence = 2; $0.camber = 3.5; $0.dihedral = 3; $0.mass *= 0.75; $0.thrust *= 0.4; $0.pitchSpeed = 16
                $0.ailThrow = 20; $0.elevThrow = 22; $0.rudThrow = 30; $0.wheelR = 0.055; $0.gearH *= 1.1; $0.spinnerColor = grey; $0.sound = 80 },
            mk(bipe, 1.35, "Royal Aircraft Factory S.E.5a", "Warbirds", "Steady inline-engined First World War fighter: the stable gun platform", scheme: 8, fuse: rgb(0.34, 0.3, 0.18), top: rgb(0.34, 0.3, 0.18), bottom: rgb(0.8, 0.76, 0.6), tail: rgb(0.34, 0.3, 0.18), accent: rgb(0.8, 0.76, 0.6)) {
                $0.pants = false; $0.fuseExp = 3.2; $0.incidence = 2; $0.camber = 3.5; $0.dihedral = 4; $0.mass *= 0.8; $0.thrust *= 0.4; $0.pitchSpeed = 17
                $0.ailThrow = 16; $0.elevThrow = 18; $0.rudThrow = 26; $0.blades = 4; $0.wheelR = 0.055; $0.gearH *= 1.1; $0.sound = 85 },
            // Aerobatic
            mk(acro, 1.4, "Sukhoi Su-26", "Aerobatic", "Russian unlimited aerobat with a radial up front and brutal roll rate", fuse: white, top: red, bottom: white, tail: red, accent: blue) { $0.fuseExp = 2; $0.spinnerScale = 0.25; $0.blades = 3; $0.sound = 120 },
            mk(acro, 1.45, "Zivko Edge 540", "Aerobatic", "Air-race thoroughbred: straight leading edge, fierce acceleration", fuse: black, top: orange, bottom: white, tail: orange, accent: white) { $0.thrust *= 1.1; $0.tipChord *= 0.85 },
            mk(acro, 1.5, "Yakovlev Yak-54", "Aerobatic", "Two-seat aerobatic trainer with big surfaces and gentle 3D manners", fuse: yellow, top: blue, bottom: yellow, tail: blue, accent: white) { $0.fuseExp = 2; $0.spinnerScale = 0.25; $0.canopyLen = 0.17; $0.blades = 3 },
            mk(acro, 1.35, "Mudry CAP 232", "Aerobatic", "French world-champion aerobat: precise and razor sharp", fuse: white, top: blue, bottom: red, tail: blue, accent: red) { $0.mass *= 0.95 },
            mk(bipe, 1.15, "Christen Eagle", "Aerobatic", "Aerobatic biplane wearing its famous feathered paint", fuse: white, top: white, bottom: orange, tail: yellow, accent: red) { $0.fuseExp = 2.1; $0.canopyLen = 0.16 },
            mk(acro, 1.2, "Zlín Z-50", "Aerobatic", "Compact Czech competition aerobat", fuse: red, top: white, bottom: red, tail: white, accent: blue) { $0.mass *= 0.92 },
            // Jets
            mk(jet, 0.95, "BAe Hawk", "Jets", "Display-team jet trainer: smooth, graceful, easy for a jet", fuse: red, top: red, bottom: white, tail: red, accent: white) { $0.canopyLen = 0.17; $0.thrust *= 1.1; $0.sweep *= 0.8 },
            mk(jet, 1.0, "Aero L-39 Albatros", "Jets", "Straight-winged jet trainer with gentle low-speed handling", fuse: grey, top: rgb(0.24, 0.3, 0.2), bottom: rgb(0.5, 0.6, 0.68), tail: grey, accent: orange) {
                $0.sweep *= 0.35; $0.tipChord *= 1.2; $0.canopyLen = 0.17; $0.camber = 2 },
            mk(sabre, 1.0, "Mikoyan MiG-15", "Jets", "Stubby swept-wing fighter with a nose intake and a high tail", fuse: grey, top: grey, bottom: grey, tail: grey, accent: red) { $0.fuseW *= 1.1; $0.finH *= 1.15; $0.canopyLen = 0.1 },
            mk(f16, 0.75, "Lockheed F-104 Starfighter", "Jets", "A missile with tiny wings and a T-tail: blistering speed, very high landing speed", fuse: grey, top: grey, bottom: grey, tail: grey, accent: red) {
                $0.tTail = true; $0.rootChord *= 0.75; $0.sweep *= 0.5; $0.noseZ *= 1.3; $0.fuseLen *= 1.3; $0.mass *= 1.5; $0.thrust *= 1.9; $0.stabZ *= 1.25; $0.finZ *= 1.25; $0.dihedral = -4 },
            mk(jet, 0.98, "Aermacchi MB-339", "Jets", "Italian jet trainer with wingtip tanks", fuse: blue, top: blue, bottom: white, tail: blue, accent: white) { $0.sweep *= 0.4; $0.tipChord *= 1.15; $0.canopyLen = 0.18 },
            mk(jet, 1.1, "Comet Sport Jet", "Jets", "Original design: a big, floaty EDF for learning jet landings", fuse: white, top: orange, bottom: white, tail: orange, accent: navy) { $0.mass *= 0.85; $0.camber = 2.5; $0.sweep *= 0.6; $0.flaps = true },
            // Gliders
            mk(sail, 3.0, "Schleicher ASW 28", "Gliders", "Standard-class racing sailplane: slender wings, T-tail, long flat glide", fuse: white, top: white, bottom: white, tail: white, accent: red) { $0.tTail = true; $0.scheme = 3; $0.wingBottom = rgb(0.9, 0.3, 0.1) },
            mk(sail, 3.6, "DG-1000", "Gliders", "Big two-seat sailplane with a T-tail for cross-country and aerobatics", fuse: white, top: white, bottom: blue, tail: blue, accent: white) { $0.tTail = true; $0.canopyLen = 0.17; $0.mass *= 1.1 },
            mk(sail, 2.8, "Schempp-Hirth Discus", "Gliders", "Crescent-winged club sailplane, easy to thermal", fuse: white, top: white, bottom: yellow, tail: yellow, accent: white) { $0.tTail = true; $0.tipChord *= 0.8 },
            mk(glider, 2.4, "Schleicher Ka 8", "Gliders", "Fabric-covered vintage trainer: slow, light and happy in weak lift", fuse: rgb(0.9, 0.86, 0.7), top: rgb(0.9, 0.86, 0.7), bottom: rgb(0.9, 0.86, 0.7), tail: red, accent: red) {
                $0.wingY = 0.07; $0.rootChord *= 1.2; $0.tipChord *= 1.2; $0.fuseExp = 2.6 },
            mk(glider, 1.5, "Breeze 1.5", "Gliders", "Original design: small foam motor glider for a relaxed evening flight", fuse: white, top: white, bottom: green, tail: green, accent: white) { $0.mass *= 1.05 },
            // Trainers & sport (original designs)
            mk(trainer, 1.2, "Cadet 1200", "Trainers & Sport", "Small foam high-wing trainer: light, tough and slow enough for a first flight", fuse: white, top: yellow, bottom: blue, tail: blue, accent: white) { $0.mass *= 0.9; $0.tough = 1.4 },
            mk(warbird, 1.4, "Stick 40", "Trainers & Sport", "Classic low-wing sport model: the natural second aeroplane", scheme: 0, fuse: white, top: blue, bottom: yellow, tail: blue, accent: white) {
                $0.gear = .tricycle; $0.gearH = 0.17; $0.retracts = false; $0.flaps = false; $0.tipChord = $0.rootChord; $0.mass *= 0.72; $0.thrust *= 0.75; $0.pitchSpeed = 27; $0.blades = 2
                $0.fuseExp = 3.2; $0.ailThrow = 22; $0.elevThrow = 20; $0.camber = 1.5; $0.spinnerColor = white },
            mk(trainer, 1.4, "Night Hawk", "Trainers & Sport", "High-wing sport flyer in a dark scheme with bright undersides for dusk flying", fuse: black, top: black, bottom: rgb(0.4, 1.0, 0.3), tail: rgb(0.4, 1.0, 0.3), accent: rgb(0.4, 1.0, 0.3)) { $0.thrust *= 1.2; $0.ailThrow = 24 },
            mk(racer, 0.9, "Pulse Sport", "Trainers & Sport", "Pocket-sized hotliner: hand-launch speed machine", fuse: white, top: rgb(0.1, 0.8, 0.8), bottom: black, tail: rgb(0.1, 0.8, 0.8), accent: black) { $0.gear = .none; $0.handLaunch = true },
            mk(bush, 1.5, "Tundra Trainer", "Trainers & Sport", "Fat-tyred high-wing foamie that shrugs off rough grass and bad landings", scheme: 0, fuse: white, top: orange, bottom: navy, tail: navy, accent: white) { $0.wheelR = 0.07; $0.tough = 1.5; $0.mass *= 0.9 },
            mk(park, 0.75, "Mini Stick", "Trainers & Sport", "Tiny backyard flyer that turns inside a tennis court", fuse: yellow, top: red, bottom: yellow, tail: red, accent: white) { $0.tough = 1.5 },
            // Foam 3D
            mk(flatty, 0.86, "Slick 3D Profile", "Foam 3D", "Flat-foam profile with a long tail moment for locked-in harriers", fuse: white, top: white, bottom: white, tail: rgb(0.1, 0.5, 0.9), accent: rgb(0.95, 0.75, 0.05)) { $0.stabZ *= 1.12; $0.finZ *= 1.12; $0.fuseLen *= 1.08 },
            mk(flatty, 0.84, "Yak 3D Foamy", "Foam 3D", "Rounded-wing profile foamy that tumbles and recovers on the spot", fuse: yellow, top: yellow, bottom: yellow, tail: red, accent: navy) { $0.tipChord *= 0.8; $0.thrust *= 1.1 },
            mk(flatty, 0.6, "Micro Flatty", "Foam 3D", "Sixty-centimetre featherweight for the living room or a windless garden", fuse: white, top: white, bottom: white, tail: green, accent: orange) { $0.mass = 0.075; $0.thrust = 1.8; $0.pitchSpeed = 8 },
            mk(flatty, 1.3, "Foam Extra XL", "Foam 3D", "A 1.3-metre profile giant: big, slow, visible and still fully 3D", fuse: white, top: white, bottom: white, tail: red, accent: black) { $0.mass = 0.95; $0.thrust = 22; $0.pitchSpeed = 15; $0.sound = 170 },
            mk(flatty, 0.9, "Katana Foamy", "Foam 3D", "Lightly loaded profile with extra power for vertical work", fuse: white, top: white, bottom: white, tail: rgb(0.6, 0.15, 0.8), accent: rgb(0.1, 0.8, 0.5)) { $0.thrust *= 1.35 },
        ]
        // floatplanes: start on the water at sites that have it
        let seaplanes: [PlaneGeom] = [
            mk(bush, 1.8, "Beaver Floatplane", "Scale Civil", "The classic bush seaplane: takes off from and lands on water", scheme: 6,
               fuse: rgb(0.95, 0.75, 0.1), top: rgb(0.95, 0.75, 0.1), bottom: rgb(0.95, 0.75, 0.1), tail: rgb(0.95, 0.75, 0.1), accent: navy) {
                $0.dataKey = "DHC-2 Beaver"; $0.gear = .floats; $0.fuseExp = 2.3; $0.spinnerScale = 0.18; $0.spinnerColor = grey; $0.sound = 95; $0.thrust *= 1.15 },
            mk(bush, 1.8, "Super Cub Floatplane", "Scale Civil", "A Super Cub on floats: light enough to leap off a small lake", scheme: 6,
               fuse: white, top: white, bottom: white, tail: red, accent: red) {
                $0.dataKey = "Piper PA-18 Super Cub"; $0.gear = .floats; $0.thrust *= 1.15 },
            mk(twin, 2.0, "Twin Otter Floatplane", "Scale Civil", "Twin-turboprop island hopper on floats", scheme: 6,
               fuse: white, top: white, bottom: white, tail: white, accent: rgb(0.05, 0.5, 0.6)) {
                $0.dataKey = "DHC-6 Twin Otter"; $0.gear = .floats; $0.wingY = 0.1; $0.struts = true; $0.retracts = false; $0.blades = 3; $0.fuseExp = 3
                $0.camber = 4; $0.canopyLen = 0.06; $0.gearH = 0.26; $0.track = 0.26; $0.thrust *= 1.1 },
        ]

        // ---- flying wings: no tailplane; pitch and roll both come from elevons on the wing
        var wingBase = PlaneGeom()
        wingBase.category = "Wings"; wingBase.flyingWing = true; wingBase.winglets = true; wingBase.pusher = true
        wingBase.gear = .none; wingBase.handLaunch = true; wingBase.dihedral = 0; wingBase.incidence = 0; wingBase.washout = 0
        wingBase.noseZ = -0.2; wingBase.fuseLen = 0.48; wingBase.fuseW = 0.11; wingBase.fuseH = 0.085; wingBase.fuseExp = 2.2; wingBase.canopyLen = 0.2
        wingBase.wingY = 0; wingBase.ailStart = 0.34; wingBase.ailFrac = 0.22; wingBase.ailThrow = 14; wingBase.elevThrow = 16
        wingBase.finH = 0.13; wingBase.finChord = 0.14; wingBase.stabSpan = 0.01; wingBase.stabChord = 0.01; wingBase.stabZ = 0.2; wingBase.finZ = 0.2
        wingBase.washTail = 0; wingBase.washWing = 0; wingBase.cdA = 0.004; wingBase.scheme = 9; wingBase.tough = 1.6; wingBase.propDia = 0.2
        func wing(_ name: String, _ blurb: String, _ edit: (inout PlaneGeom) -> Void) -> PlaneGeom { var g = wingBase; g.name = name; g.blurb = blurb; edit(&g); return g }
        let flyingWings: [PlaneGeom] = [
            wing("Sweep 48 Combat Wing", "Tough EPP swept wing: the classic slope and combat machine, quick in roll and hard to break") {
                $0.span = 1.22; $0.rootChord = 0.33; $0.tipChord = 0.2; $0.sweep = 0.34; $0.mass = 0.72; $0.thrust = 8.5; $0.pitchSpeed = 24
                $0.thick = 0.1; $0.tough = 2.2; $0.ailThrow = 16; $0.elevThrow = 16; $0.washout = 2
                $0.fuse = black; $0.wingTop = yellow; $0.wingBottom = black; $0.tail = red; $0.accent = red; $0.sound = 230 },
            wing("Plank 1.5 Soarer", "Unswept reflexed plank for the slope: pitch-sensitive, with a long flat glide") {
                $0.span = 1.5; $0.rootChord = 0.22; $0.tipChord = 0.19; $0.sweep = 0; $0.mass = 0.6; $0.thrust = 4.2; $0.pitchSpeed = 15
                $0.winglets = false; $0.finH = 0.2; $0.finChord = 0.17; $0.finZ = 0.36; $0.fuseLen = 0.72; $0.noseZ = -0.26; $0.pusher = false
                $0.margin = 0.07; $0.trimCL = 0.5; $0.thick = 0.1; $0.dihedral = 2; $0.elevThrow = 10; $0.ailThrow = 14; $0.airfoil = .reflex; $0.endurance = 420
                $0.fuse = white; $0.wingTop = white; $0.wingBottom = rgb(0.1, 0.5, 0.9); $0.tail = rgb(0.1, 0.5, 0.9); $0.accent = white; $0.sound = 130 },
            wing("Delta Dart", "Small pusher delta: fast, flies to wild nose-high angles without letting go, sinks fast when slow") {
                $0.span = 0.8; $0.rootChord = 0.56; $0.tipChord = 0.06; $0.sweep = 0.5; $0.mass = 0.55; $0.thrust = 9; $0.pitchSpeed = 32
                $0.winglets = false; $0.finH = 0.16; $0.finChord = 0.22; $0.finZ = 0.22; $0.fuseLen = 0.62; $0.noseZ = -0.3; $0.fuseW = 0.08
                $0.airfoil = .delta; $0.thick = 0.06; $0.margin = 0.08; $0.trimCL = 0.25; $0.ailStart = 0; $0.ailFrac = 0.18; $0.ailThrow = 18; $0.elevThrow = 18
                $0.fuse = grey; $0.wingTop = grey; $0.wingBottom = orange; $0.tail = orange; $0.accent = black; $0.sound = 280 },
            wing("Voyager 2.1 FPV Wing", "Big long-range wing: efficient, steady, carries a lot and cruises for an age") {
                $0.span = 2.1; $0.rootChord = 0.4; $0.tipChord = 0.2; $0.sweep = 0.42; $0.mass = 2.6; $0.thrust = 17; $0.pitchSpeed = 22; $0.propDia = 0.3
                $0.fuseLen = 0.75; $0.noseZ = -0.32; $0.fuseW = 0.17; $0.fuseH = 0.12; $0.finH = 0.2; $0.finChord = 0.2; $0.washout = 3; $0.thick = 0.12
                $0.margin = 0.11; $0.ailThrow = 12; $0.elevThrow = 12; $0.endurance = 600; $0.tough = 1.2
                $0.fuse = white; $0.wingTop = white; $0.wingBottom = rgb(0.1, 0.1, 0.12); $0.tail = orange; $0.accent = orange; $0.sound = 150 },
            wing("Horten Ho 229", "Twin-jet flying wing with no fin at all: elegant, fast, and loose in yaw") {
                $0.span = 1.5; $0.rootChord = 0.56; $0.tipChord = 0.17; $0.sweep = 0.44; $0.mass = 1.9; $0.thrust = 19; $0.pitchSpeed = 55
                $0.ducted = true; $0.pusher = false; $0.winglets = false; $0.noFin = true; $0.handLaunch = false; $0.gear = .tricycle; $0.gearH = 0.12; $0.track = 0.2; $0.wheelR = 0.026
                $0.retracts = true; $0.fuseLen = 0.62; $0.noseZ = -0.3; $0.fuseW = 0.14; $0.fuseH = 0.1; $0.canopyLen = 0.16; $0.washout = 5; $0.thick = 0.11
                $0.margin = 0.12; $0.trimCL = 0.3; $0.ailThrow = 12; $0.elevThrow = 13; $0.scheme = 7; $0.tough = 1; $0.airfoil = .reflex
                $0.fuse = rgb(0.25, 0.3, 0.22); $0.wingTop = rgb(0.25, 0.3, 0.22); $0.accent = rgb(0.17, 0.2, 0.2); $0.wingBottom = rgb(0.5, 0.6, 0.68); $0.tail = rgb(0.25, 0.3, 0.22); $0.sound = 420 },
            wing("Race Wing 600", "Sixty-centimetre racing wing: tiny, twitchy and very fast") {
                $0.span = 0.6; $0.rootChord = 0.24; $0.tipChord = 0.13; $0.sweep = 0.19; $0.mass = 0.29; $0.thrust = 6.5; $0.pitchSpeed = 38; $0.propDia = 0.13
                $0.fuseLen = 0.3; $0.noseZ = -0.13; $0.fuseW = 0.07; $0.fuseH = 0.06; $0.finH = 0.07; $0.finChord = 0.09; $0.thick = 0.09; $0.washout = 1.5
                $0.margin = 0.07; $0.trimCL = 0.25; $0.ailThrow = 14; $0.elevThrow = 12; $0.tough = 2
                $0.fuse = black; $0.wingTop = rgb(0.5, 0.95, 0.1); $0.wingBottom = black; $0.tail = rgb(0.9, 0.1, 0.5); $0.accent = rgb(0.9, 0.1, 0.5); $0.sound = 330 },
        ]

        var trainerHeli = rescale(makeHeli(body: rgb(0.95, 0.95, 0.95), canopy: rgb(0.85, 0.1, 0.1)), 0.6)
        trainerHeli.name = "Sparrow 450"; trainerHeli.blurb = "Small, docile helicopter for learning to hover"
        trainerHeli.mass = 0.9; trainerHeli.inertia = V3(0.010, 0.009, 0.004); trainerHeli.cdA = 0.012; trainerHeli.soundBase = 105
        trainerHeli.heli!.collMax = 9 * deg; trainerHeli.heli!.maxMoment = 1.1; trainerHeli.heli!.tailMax = 0.45
        trainerHeli.heli!.maxRate = 3.2; trainerHeli.heli!.maxYaw = 4.5; trainerHeli.category = "Helicopters"

        var bigHeli = rescale(makeHeli(body: rgb(0.08, 0.25, 0.7), canopy: rgb(0.95, 0.6, 0.05)), 1.27)
        bigHeli.name = "Condor 700"; bigHeli.blurb = "Large 700-class helicopter: smooth, powerful, imposing"
        bigHeli.mass = 5.3; bigHeli.inertia = V3(0.27, 0.24, 0.11); bigHeli.cdA = 0.045; bigHeli.soundBase = 52
        bigHeli.heli!.maxMoment = 22; bigHeli.heli!.tailMax = 8; bigHeli.category = "Helicopters"

        var racerQuad = rescale(makeQuad(shell: rgb(0.55, 0.9, 0.1), front: rgb(0.6, 0.15, 0.8), rear: rgb(0.2, 0.2, 0.22)), 0.5)
        racerQuad.name = "Wasp Racing Quad"; racerQuad.blurb = "5-inch racing quad: brutal power, best flown in acro"
        racerQuad.mass = 0.6; racerQuad.inertia = V3(0.0016, 0.0028, 0.0016); racerQuad.cdA = 0.008; racerQuad.soundBase = 380
        racerQuad.multi!.maxThrust = 6.5; racerQuad.multi!.kYaw = 0.008; racerQuad.multi!.maxRate = 9; racerQuad.multi!.maxYaw = 6; racerQuad.multi!.maxAngle = 0.95; racerQuad.category = "Multirotors"

        var heli = makeHeli(); heli.category = "Helicopters"
        var quad = makeQuad(); quad.category = "Multirotors"
        let everything: [AircraftSpec] = [makeAirplane(trainer), makeAirplane(acro), makeAirplane(glider), makeAirplane(jet), heli, quad,
                makeAirplane(park), makeAirplane(bush), makeAirplane(warbird), makeAirplane(twin), makeAirplane(bipe), makeAirplane(racer),
                makeAirplane(sail), trainerHeli, bigHeli, racerQuad] + scale.map(makeAirplane) + foamies.map(makeAirplane) + more.map(makeAirplane) + seaplanes.map(makeAirplane) + flyingWings.map(makeAirplane)
        return everything.map { calibrateRates(trimForCruise($0)) }
    }()
}
