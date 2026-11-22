import simd

/// The gyro settings. Every aircraft starts with the gyro off. Airplanes have two kinds of help, helicopters and
/// multirotors one (their flight controller levels them).
enum Gyro {
    static let off = 0
    /// Airplanes: rate damping. Helicopters and multirotors: stabilized, as there is only the one setting for them.
    static let on = 1
    /// Airplanes only: the sticks command bank and pitch angles.
    static let stabilized = 2

    static func names(_ kind: AircraftKind) -> [String] {
        kind == .airplane ? ["Off (Acro Mode)", "On (AS3X)", "Stabilized Mode"] : ["Off (Acro Mode)", "On (Stabilized Mode)"]
    }
    /// For the button in the top bar.
    static func shortNames(_ kind: AircraftKind) -> [String] {
        kind == .airplane ? ["OFF", "AS3X", "STAB"] : ["OFF", "STAB"]
    }
}

/// What an airplane's gyro needs to know about its wing.
struct WingFigures {
    var area: Float = 0
    var slope: Float = 0        // lift per radian
    var zero: Float = 0         // angle the wing already flies at with the fuselage level (incidence and camber)
    var maxAlpha: Float = 0     // fuselage angle of attack that stabilized mode will not exceed

    init(_ spec: AircraftSpec) {
        var stall: Float = 0
        for s in spec.surfaces where s.isWing {
            area += s.area; slope += s.area * s.liftSlope * s.load
            zero += s.area * (s.alpha0 + atan2(s.normal.z, -s.chordDir.z)); stall += s.area * s.stall
        }
        guard area > 0 else { return }
        slope /= area; zero /= area; stall /= area
        maxAlpha = clampf(0.7 * stall - zero, 3 * deg, 14 * deg)
    }
}

/// The airplane gyro. It only moves the control surfaces, through the same servos as the sticks, so it can do no
/// more than those surfaces can: with no air over them it is powerless.
///
/// One set of gains suits a 25 g foamy and a heavy warbird because the gyro asks for angular acceleration and
/// converts it with the bite the surfaces have at that moment (`ctrlPower`, measured in the airflow loop). That is
/// the job of the gain scheduling in a real gyro.
///
/// Channels here are in stick order and stick sense: x roll right, y pitch up, z yaw right.
struct AirplaneGyro {
    private static let gain = V3(10, 9, 7)      // per second: well inside what a 40 ms servo can follow
    private var mode = Gyro.off
    private var slow = V3.zero                  // the steady part of the rates, as in a turn or a loop
    private var lastRates = V3.zero
    private var accel = V3.zero, deflection = V3.zero       // what the aircraft just did, and where its surfaces were
    private var pathHold: Float = 0             // stabilized: nose angle found to hold the flight path
    private var airTime: Float = 0

    mutating func reset() { self = AirplaneGyro() }

    /// The surface commands: aileron, elevator, rudder.
    mutating func update(_ ac: Aircraft, _ c: Controls, va: V3, R: simd_float3x3, dt: Float) -> V3 {
        let stick = V3(c.aileron, c.elevator, c.rudder)
        let w = V3(-ac.omega.z, ac.omega.x, -ac.omega.y)
        if c.mode != mode { mode = c.mode; slow = w; pathHold = 0; lastRates = w; accel = .zero; deflection = ac.servo }
        // both through the same short filter, so that they describe the same moment
        let k = min(1, dt / 0.012)
        accel += ((w - lastRates) / dt - accel) * k
        deflection += (ac.servo - deflection) * k
        lastRates = w
        airTime = ac.onGround ? 0 : airTime + dt
        guard mode != Gyro.off, !ac.crashed else { return stick }

        // deflection per rad/s² wanted; fades smoothly to nothing as the surfaces lose their bite
        let b = simd_max(ac.ctrlPower, V3.zero)
        let perAccel = b / (b * b + V3(repeating: 16))
        slow += (w - slow) * min(1, dt / 0.8)
        return mode == Gyro.on
            ? damp(ac, stick, w: w, perAccel: perAccel, va: va)
            : level(ac, c, stick, w: w, perAccel: perAccel, va: va, R: R, dt: dt)
    }

    /// On (AS3X): opposes rotation the pilot did not ask for, and holds no attitude.
    private func damp(_ ac: Aircraft, _ stick: V3, w: V3, perAccel: V3, va: V3) -> V3 {
        // In flight a steady pitch or yaw rate is a turn or a loop and is left alone. Hanging on the propeller
        // there is no such thing, and all rotation is damped.
        let flying = smoothstep(0.8, 1.3, -va.z / max(ac.spec.stallSpeed, 1))
        let unwanted = w - V3(0, slow.y, slow.z) * flying
        var out = stick
        for i in 0..<3 {
            // the gyro steps back as the stick moves, so that full stick still gives the full rate
            let fade = clampf(1 - abs(stick[i]) / 0.45, 0.1, 1)
            out[i] += clampf(-AirplaneGyro.gain[i] * unwanted[i] * perAccel[i], -0.45, 0.45) * fade
            out[i] = clampf(out[i], -1, 1)
        }
        return out
    }

    /// Stabilized: the sticks command bank and pitch angles, and centred sticks return to level flight.
    private mutating func level(_ ac: Aircraft, _ c: Controls, _ stick: V3, w: V3, perAccel: V3, va: V3, R: simd_float3x3, dt: Float) -> V3 {
        let wing = ac.wing, speed = length(va)
        let lean = c.lean ?? SIMD2(c.aileron, c.elevator)
        let nose = R * V3(0, 0, -1), up = R * V3(0, 1, 0), right = R * V3(1, 0, 0)

        // Level flight needs an angle of attack that depends on the speed. That is what centred sticks hold, and
        // however far the stick is pulled the nose stays below the stalling angle above the flight path.
        let blend = smoothstep(0, 0.4, airTime)
        let working = blend > 0.99 && speed > 0.6 * ac.spec.stallSpeed
        let bankWanted = clampf(lean.x, -1, 1) * 55 * deg
        let v = max(-va.z, 0.9 * ac.spec.stallSpeed, 1)
        let cl = ac.spec.mass * gravity / max(0.5 * rho * v * v * wing.area * cos(bankWanted), 1e-3)
        let cruise = clampf(cl / max(wing.slope, 0.1) - wing.zero, -4 * deg, 0.85 * wing.maxAlpha)
        // trim and launch assist tilt the flight path that centred sticks hold
        let pathWanted = c.climb * 35 * deg
        let path = speed > 2 ? asin(clampf((R * va).y / speed, -1, 1)) : 0
        if !working { pathHold = 0 }
        else if abs(lean.y) < 0.05 { pathHold = clampf(pathHold + 0.6 * (pathWanted - path) * dt, -5 * deg, 5 * deg) }
        var pitchWanted = clampf(lean.y, -1, 1) * 35 * deg + cruise + pathWanted + pathHold
        if speed > 2 {
            pitchWanted = max(min(pitchWanted, path + wing.maxAlpha), -35 * deg)
        }

        // where the wing's upper side should point, worked out from the heading so that it holds at any attitude
        var heading = V3(nose.x, 0, nose.z)
        if length(heading) < 0.15 { heading = V3(up.x, 0, up.z) * (nose.y > 0 ? -1 : 1) }
        heading = length(heading) > 1e-3 ? normalize(heading) : V3(0, 0, -1)
        let abeam = cross(heading, V3(0, 1, 0))
        let upright = V3(0, cos(pitchWanted), 0) - heading * sin(pitchWanted)
        let target = R.transpose * (upright * cos(bankWanted) + abeam * sin(bankWanted))

        // roll upright first: upside down, pulling through would be a half loop into the ground
        let rollError = atan2(target.x, target.y) * smoothstep(0.05, 0.35, sqrt(target.x * target.x + target.y * target.y))
        let pitchError = atan2(target.z, sqrt(target.x * target.x + target.y * target.y)) * (1 - smoothstep(0, 0.5, -target.y))
        var want = V3(clampf(rollError * 4, -3.5, 3.5), clampf(pitchError * 3.5, -2.5, 2.5), 0)
        // the rates a coordinated turn at this bank has
        let bank = clampf(atan2(-right.y, up.y), -60 * deg, 60 * deg)
        let turn = gravity * tan(bank) / max(speed, ac.spec.stallSpeed) * sqrt(max(1 - nose.y * nose.y, 0)) * smoothstep(-0.1, 0.3, up.y)
        want.x -= turn * nose.y         // in a turn with the nose up part of the turning is about the roll axis
        want.y += turn * sin(bank)
        want.z = turn * cos(bank)

        // The correction starts from where the surfaces are and how the aircraft is answering them, so whatever
        // else turns it (its own damping, motor torque, thrust line, trim) is allowed for within a few hundredths of
        // a second. Not while held in the hand or standing: there it cannot answer, and the surfaces would run away.
        let moving = blend * smoothstep(0.1, 1, length(ac.vel))
        var out = V3.zero
        for i in 0..<2 {
            // A light airframe's own damping acts faster than its servos. Allowing for it late would make the gyro
            // sluggish, so it asks for more by as much as that damping does within the 52 ms of servo and filter.
            let asked = AirplaneGyro.gain[i] * (1 + clampf(ac.rateDamping[i], 0, 150) * 0.052) * (want[i] - w[i])
            let total = deflection[i] * moving + (asked - accel[i] * moving) * perAccel[i]
            // on the wheels the sticks work the surfaces directly, so take-off and taxiing are as usual
            out[i] = clampf(stick[i] + (total - stick[i]) * blend, -1, 1)
        }
        let yawFade = clampf(1 - abs(stick.z) / 0.45, 0.1, 1) * blend
        out.z = clampf(stick.z + clampf(AirplaneGyro.gain.z * (want.z - w.z) * perAccel.z, -0.45, 0.45) * yawFade, -1, 1)
        return out
    }
}
