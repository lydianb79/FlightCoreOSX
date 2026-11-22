import simd

/// One recorded moment of a flight: where the aircraft was, what its controls and motors were doing, and where the
/// pilot's sticks were.
struct FlightFrame {
    var t: Float
    var pos: V3, q: simd_quatf, vel: V3, omega: V3
    var levels: [Float], spin: [Float]
    var servo: V3, flap: Float, gear: Float
    var sticks: Controls
    var crashed: Bool, onGround: Bool, airspeed: Float, motorLoad: Float, battery: Float
}

/// A flight recorded frame by frame, the last two minutes of it.
struct FlightRecording {
    static let maxSeconds: Float = 120
    private(set) var frames: [FlightFrame] = []
    var duration: Float { frames.count > 1 ? frames[frames.count - 1].t - frames[0].t : 0 }
    var start: Float { frames.first?.t ?? 0 }

    mutating func add(_ f: FlightFrame) {
        frames.append(f)
        // drop the oldest second at a time, so the array is not shifted every frame
        if let first = frames.first, f.t - first.t > FlightRecording.maxSeconds + 1 {
            let cut = frames.firstIndex { f.t - $0.t <= FlightRecording.maxSeconds } ?? 0
            frames.removeFirst(cut)
        }
    }

    /// The aircraft at time `t`, between the two frames around it.
    func pose(at t: Float) -> FlightFrame? {
        guard var lo = frames.first else { return nil }
        guard frames.count > 1 else { return lo }
        if t <= lo.t { return lo }
        if t >= frames[frames.count - 1].t { return frames[frames.count - 1] }
        // binary search for the last frame at or before t
        var a = 0, b = frames.count - 1
        while b - a > 1 { let m = (a + b) / 2; if frames[m].t <= t { a = m } else { b = m } }
        lo = frames[a]
        let hi = frames[b], k = (t - lo.t) / max(hi.t - lo.t, 1e-5)
        var f = k < 0.5 ? lo : hi             // switches, sticks and propeller angles: the nearer frame
        f.t = t
        f.pos = lo.pos + (hi.pos - lo.pos) * k
        f.q = simd_slerp(lo.q, hi.q, k)
        f.vel = lo.vel + (hi.vel - lo.vel) * k
        f.omega = lo.omega + (hi.omega - lo.omega) * k
        return f
    }
}

/// Watching a recorded flight. The live aircraft waits, frozen, until the pilot goes back to flying.
struct ReplayState {
    var recording: FlightRecording
    var t: Float                    // seconds from the start of the recording
    let live: Aircraft              // the aircraft being flown, put aside
    let viewer: Aircraft            // the copy that is shown moving through the recording
}

extension Aircraft {
    func recordFrame(t: Float, sticks: Controls) -> FlightFrame {
        FlightFrame(t: t, pos: pos, q: q, vel: vel, omega: omega, levels: levels, spin: spin, servo: servo, flap: flap, gear: gear,
                    sticks: sticks, crashed: crashed, onGround: onGround, airspeed: airspeed, motorLoad: motorLoad, battery: battery)
    }

    func show(_ f: FlightFrame) {
        pos = f.pos; q = f.q; vel = f.vel; omega = f.omega
        if f.levels.count == levels.count { levels = f.levels }
        if f.spin.count == spin.count { spin = f.spin }
        servo = f.servo; flap = f.flap; gear = f.gear
        crashed = f.crashed; onGround = f.onGround; airspeed = f.airspeed; motorLoad = f.motorLoad; battery = f.battery
        updateRenderPose(ahead: 0)
    }
}
