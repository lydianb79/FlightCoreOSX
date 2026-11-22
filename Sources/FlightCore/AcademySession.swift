import simd

// What the Flight Academy needs around a step: the free flight it interrupted, and what the screen shows.

/// Free flight as it was when the first step started, put back when the Academy is left.
struct FreeFlight {
    var aircraft: Int
    var site: String
    var gyro: Int, lowRates: Bool, rotorSpeed: Int, trim: Int
    var camera: Int, zoom: Int, timeOfDay: Int, hudVisible: Bool
    var challenge: Bool, smoke: Bool
    var windSpeed: Float, windFrom: Float, turbulence: Float, gustiness: Float
    var thermalsOn: Bool, thermalStrength: Float, cloud: Float, haze: Float
}

/// The panel shown while a step is flown.
struct AcademyHUD: Equatable {
    var title = "", task = "", count = "", whereTo = "", progress = "", note = ""
    var clock = "", hurry = false
    var waiting = false, ready = false, countdown = 0
    var throttle: Float = 0, bandLow: Float = 0, bandHigh: Float = 0
    var gyroHelp = false
}

extension AcademyStep {
    var aircraftIndex: Int? { AircraftLibrary.all.firstIndex { $0.name == aircraft } }
    var siteIndex: Int? { SiteSpec.all.firstIndex { $0.name == site && $0.panorama == nil } }
    var gyroName: String { Gyro.names(track == .planes ? .airplane : (track == .helicopters ? .helicopter : .multirotor))[gyro] }

    /// Where a keyboard's throttle is put, so that it is already inside the band the step starts in.
    func throttleHint(_ spec: AircraftSpec) -> Float {
        let natural: Float
        switch spec.kind {
        case .airplane: natural = start.vertical ? 0.62 : (start.airborne ? 0.55 : 0)
        case .helicopter: natural = start.airborne ? 0.67 : 0.5
        case .multirotor: natural = start.airborne ? spec.hoverThrottle : 0
        }
        let lo = start.throttle.lowerBound, hi = start.throttle.upperBound
        return natural >= lo && natural <= hi ? natural : (lo + hi) / 2
    }

    /// The pose the aircraft is held in until "go".
    func startPose(_ ac: Aircraft, _ t: Terrain) -> (pos: V3, q: simd_quatf, vel: V3) {
        let d = normalize(start.dir)
        var q = simd_quatf(angle: atan2(-d.x, -d.z), axis: V3(0, 1, 0))
        if start.vertical { q = q * simd_quatf(angle: .pi / 2, axis: V3(1, 0, 0)) }
        let height = start.airborne ? start.pos.y + ac.restHeight : ac.restHeight + 0.02
        return (V3(start.pos.x, t.height(start.pos.x, start.pos.z) + height, start.pos.z), q, d * start.speed)
    }
}

/// Where the box is from the aircraft, in the words of whoever is looking: the pilot on the field, or through the camera.
func directions(to box: V3, from p: V3, eye: V3, target: V3, onboard: Bool) -> String {
    var look = target - eye; look.y = 0
    guard length(look) > 1e-3 else { return "" }
    look = normalize(look)
    let d = box - p
    let side = dot(d, cross(look, V3(0, 1, 0))), deep = dot(d, look)
    var parts: [String] = []
    if abs(side) >= 1 { parts.append(String(format: "%.0f m %@", abs(side), side > 0 ? "right" : "left")) }
    if abs(d.y) >= 1 { parts.append(String(format: "%.0f m %@", abs(d.y), d.y > 0 ? "higher" : "lower")) }
    if abs(deep) >= 1 { parts.append(String(format: "%.0f m %@", abs(deep), deep > 0 ? (onboard ? "ahead" : "farther away") : (onboard ? "behind" : "nearer you"))) }
    return parts.isEmpty ? "You are at the target" : "Target: " + parts.joined(separator: " · ")
}
