import simd

// The instructor pilot of `--academytest`. It has nothing but the sticks: it flies through the same game loop,
// servos and rates as a player (low rates, the suggested gyro) and reacts late. If it cannot pass a step, the step
// is at fault. It is not part of the game.

private func flat(_ v: V3) -> V3 { V3(v.x, 0, v.z) }
private func unit(_ v: V3, or d: V3) -> V3 { length(v) > 1e-4 ? normalize(v) : d }
private func limit(_ v: V3, _ m: Float) -> V3 { length(v) > m ? v * (m / length(v)) : v }
private func stickTravel(_ g: Game) -> Float { g.input.lowRates ? g.input.lowRateInUse : 1 }
private func wrapAngle(_ a: Float) -> Float { atan2(sin(a), cos(a)) }

final class InstructorPilot {
    /// Seconds between what it sees and what its sticks do.
    var reaction: Float = 0.05
    /// Flies to the boxes but ignores attitudes, figures and landings: must not pass a step that asks for them.
    var lazy = false

    private var seenTask = -1
    private var taskTime: Float = 0
    private var stage = 0
    private var integ: Float = 0, climbInteg: Float = 0, pushInteg = V3.zero
    private var queue: [Controls] = []
    private let dt: Float

    init(fps: Float) { dt = 1 / fps }

    func sticks(_ g: Game) -> Controls {
        var c = Controls()
        guard let a = g.attempt else { return c }
        c.throttle = a.step.throttleHint(g.aircraft.spec)
        guard a.phase != .waiting else { queue = []; return c }
        if a.index != seenTask {
            seenTask = a.index; taskTime = 0; stage = 0; integ = 0
        }
        taskTime += dt
        let task = a.task ?? a.step.tasks[a.step.tasks.count - 1]
        switch g.aircraft.spec.kind {
        case .airplane: c = plane(g, a, task)
        case .helicopter, .multirotor: c = rotor(g, a, task)
        }
        queue.append(c)
        let n = Int(reaction / dt)
        return queue.count > n ? queue.removeFirst() : queue[0]
    }

    // MARK: Planes

    private func plane(_ g: Game, _ a: AcademyAttempt, _ task: AcademyTask) -> Controls {
        let ac = g.aircraft, box = task.box, L = stickTravel(g), stall = ac.spec.stallSpeed
        let middle = box.world(g.terrain), agl = ac.pos.y - g.terrain.height(ac.pos.x, ac.pos.z) - ac.restHeight
        let speed = length(ac.vel), path = asin(clampf(ac.vel.y / max(speed, 0.5), -1, 1))
        let right = normalize(cross(box.dir, V3(0, 1, 0)))
        var c = Controls()
        func level(_ v: Float) -> Float { clampf(v, -L, L) }

        /// Steer along the box's line, or on toward `at`.
        func navigate(height: Float, cruise: Float, sink: Float? = nil) {
            let rel = ac.pos - middle, along = dot(rel, box.dir)
            let carrot = middle + box.dir * (along + max(speed * 1.3, 12))
            let to = unit(flat(carrot - ac.pos), or: box.dir), f = unit(flat(ac.forward), or: box.dir)
            let error = atan2(-cross(f, to).y, dot(f, to))
            let bank = clampf(atan(max(speed, stall) * error * 1.5 / gravity), -0.85, 0.85)
            let want = sink ?? clampf((height - ac.pos.y) / max(speed * 1.2, 12), -0.25, 0.28)
            if g.flightMode == Gyro.stabilized {
                c.aileron = level(bank / (55 * deg) * L)
                c.elevator = level((want * 1.1 + (want - path) * 0.4) / (35 * deg) * L)
            } else {
                climbInteg = clampf(climbInteg + (want - path) * dt * 0.9, -0.15, 0.25)
                let nose = want + climbInteg + 0.03 + (want - path) * 0.2
                c.aileron = level(2.2 * (bank - ac.roll) + 0.2 * ac.omega.z)
                c.elevator = level(2.6 * (nose - ac.pitch) - 0.22 * ac.omega.x + 0.22 * abs(sin(ac.roll)))
                c.rudder = level(0.25 * (bank - ac.roll))
            }
            c.throttle = clampf(0.56 + 0.1 * (cruise - speed) + 1.3 * want, 0, 1)
        }
        /// Point the nose along `d` with elevator and rudder, whatever the bank.
        func point(_ d: V3, _ k: Float) {
            let l = ac.q.inverse.act(d)
            c.elevator = level(k * atan2(l.y, -l.z) - 0.11 * ac.omega.x)
            c.rudder = level(k * atan2(l.x, -l.z) + 0.11 * ac.omega.y)
        }
        /// The nose direction that flies along the box's line at its height.
        func line(gain: Float) -> V3 {
            let want = clampf((middle.y - ac.pos.y) * 0.035, -0.22, 0.25)
            climbInteg = clampf(climbInteg + (want - path) * dt * gain, -0.1, 0.45)
            let side = clampf(-dot(ac.pos - middle, right) * 0.015, -0.2, 0.2)
            return normalize(box.dir + right * side + V3(0, tan(clampf(want + climbInteg + 0.06, -0.5, 0.7)), 0))
        }

        switch task.kind {
        case .pass:
            if agl < 0.15 && speed < stall * 1.5 && ac.onGround {
                // the take-off run
                let f = unit(flat(ac.forward), or: box.dir)
                let error = atan2(-cross(f, box.dir).y, dot(f, box.dir))
                c.throttle = min(0.3 + a.time * 0.6, 1)
                c.rudder = level(2.5 * error + 0.3 * ac.omega.y)
                c.aileron = level(-2 * ac.roll)
                c.elevator = level(speed > stall * 1.05 ? 0.3 : 0.06)
            } else {
                var cruise = stall * 1.75
                if a.step.tasks.contains(where: { if case .land = $0.kind { return true }; return false }) { cruise = stall * 1.38 }
                if a.step.tasks.contains(where: { if case .rotate = $0.kind { return true }; return false }) { cruise = stall * 2.4 }
                navigate(height: middle.y, cruise: cruise)
            }

        case .hold:
            if lazy {
                navigate(height: middle.y, cruise: stall * 1.8)
            } else if case .noseUp = task.pose {
                hover(g, middle, spin: false, &c)
            } else {
                var bank: Float = .pi
                if case .knifeEdge = task.pose { bank = .pi / 2 }
                let error = wrapAngle(bank - ac.roll)
                // always rolls the same way round into the attitude
                c.aileron = level(abs(error) > 2.6 ? L : 1.5 * error + 0.12 * ac.omega.z)
                point(line(gain: 0.6), 0.9)
                c.throttle = bank < 2 ? 1 : clampf(0.75 + 0.06 * (stall * 2.2 - speed), 0.4, 1)
            }

        case .rotate(let axis, _, let slowest):
            if lazy {
                navigate(height: middle.y, cruise: stall * 1.8)
            } else if case .noseUp = task.pose {
                hover(g, middle, spin: true, &c)
            } else if case .flip = axis {
                let top = ac.up.y < 0
                c.throttle = top ? 0.7 : 1
                c.elevator = level(0.85 * L)
                c.aileron = level(1.8 * ac.right.y * (top ? -1 : 1) + 0.1 * ac.omega.z)
            } else {
                // nose a little up, then round
                let entry = taskTime < 0.35
                let rate: Float = slowest > 0 ? 2 * .pi / (slowest * 1.12) : 99
                let now = -ac.omega.z
                if entry {
                    navigate(height: middle.y + 8, cruise: stall * 2.4)
                } else if slowest > 0 {
                    integ = clampf(integ + (rate - now) * dt * 0.12, -0.3, 0.3)
                    c.aileron = level(rate / 8 + integ + 0.05 * (rate - now))
                    point(line(gain: 0.6), 1.3)
                    c.throttle = 1
                } else {
                    c.aileron = L
                    point(line(gain: 0.5), 1.2)
                    c.throttle = 0.9
                }
            }

        case .stall:
            if lazy { navigate(height: middle.y, cruise: stall * 1.8); break }
            if stage == 0 {
                c.throttle = 0
                c.elevator = min(taskTime * 0.4, L)
                c.aileron = level(-1.2 * ac.roll)
                if ac.wingStall > 0.55 { stage = 1 }
            } else {
                let quick = speed > stall * 1.22
                c.throttle = 1
                c.aileron = level(-1.8 * ac.roll + 0.2 * ac.omega.z)
                c.elevator = level(2.2 * ((quick ? 0.14 : -0.1) - ac.pitch) - 0.22 * ac.omega.x)
            }

        case .land:
            if lazy { navigate(height: middle.y + 7, cruise: stall * 1.8); break }
            let gliding = a.step.failure == .engineCut
            let aim = middle - box.dir * (box.size.z * (gliding ? 0.52 : 0.16))
            let before = dot(aim - ac.pos, box.dir)
            if ac.onGround || (agl < 0.08 && speed < stall) {
                let f = unit(flat(ac.forward), or: box.dir), to = unit(box.dir * 14 + right * clampf(-dot(ac.pos - middle, right), -5, 5), or: box.dir)
                c.rudder = level(1.8 * atan2(-cross(f, to).y, dot(f, to)) + 0.25 * ac.omega.y)
                c.aileron = level(-2 * ac.roll)
                c.elevator = level(0.12)
                c.brake = speed < stall * 0.95 ? 0.8 : (gliding ? 0.5 : 0.2)
                c.throttle = 0
            } else {
                var sink = clampf(-atan((ac.pos.y - g.terrain.height(aim.x, aim.z)) / max(before, 12)), -0.24, 0.03)
                if gliding && speed < stall * 1.3 { sink = min(sink, -0.13) }
                if agl < 2.2 { sink = -0.025 - agl * 0.035 }
                navigate(height: middle.y, cruise: stall * 1.38, sink: sink)
                if agl < 1 { c.throttle = 0 }
            }
        }
        return c
    }

    private func hover(_ g: Game, _ spot: V3, spin: Bool, _ c: inout Controls) {
        let ac = g.aircraft, L = stickTravel(g)
        let off = spot - ac.pos
        let lean = limit(flat(off) * 0.045 - flat(ac.vel) * 0.11, 0.22)
        let l = ac.q.inverse.act(normalize(V3(0, 1, 0) + lean))
        c.elevator = clampf(0.55 * atan2(l.y, -l.z) - 0.07 * ac.omega.x, -L, L)
        c.rudder = clampf(0.55 * atan2(l.x, -l.z) + 0.07 * ac.omega.y, -L, L)
        let rate: Float = spin ? 1.25 : 0       // the way the motor's torque turns it
        integ = clampf(integ + (ac.omega.z - rate) * dt * 0.1, -0.2, 0.2)
        c.aileron = clampf(0.12 * (ac.omega.z - rate) + integ, -L, L)
        let n = sqrt(ac.spec.mass * gravity / ac.spec.props[0].staticThrust)
        climbInteg = clampf(climbInteg + off.y * dt * 0.06, -0.2, 0.2)
        c.throttle = clampf(0.82 * n + 0.18 * n * n + 0.14 * off.y - 0.18 * ac.vel.y + climbInteg, 0, 1)
    }

    // MARK: Helicopters and multirotors

    private func rotor(_ g: Game, _ a: AcademyAttempt, _ task: AcademyTask) -> Controls {
        let ac = g.aircraft, box = task.box, spec = ac.spec, L = stickTravel(g)
        let heli = spec.kind == .helicopter, acro = g.flightMode == Gyro.off
        let middle = box.world(g.terrain), ground = g.terrain.height(ac.pos.x, ac.pos.z)
        let agl = ac.pos.y - ground - ac.restHeight
        var c = Controls()

        var goal = middle, velocity = V3.zero
        var facing: V3? = nil
        var side: Float = 1                     // -1: hanging upside down
        var fixedYaw: Float? = nil
        var climbing: Float? = nil

        switch task.pose {
        case .heading(let d, _), .invertedHeading(let d, _): facing = d
        case .facing(let p, _): facing = flat(p - ac.pos)
        default: break
        }
        if lazy { facing = nil }

        switch task.kind {
        case .hold:
            if !lazy, case .inverted = task.pose {
                side = -1
                if stage == 0 {
                    if taskTime < 0.45 { side = 1; climbing = 2.5; break }
                    if ac.up.y < -0.45 { stage = 1 } else {
                        c.aileron = L
                        c.throttle = heli ? clampf(0.5 + 0.17 * ac.up.y, 0, 1) : 0.05
                        return c
                    }
                }
            }
        case .pass(let via):
            let fast: Float = a.step.id.hasSuffix("race") ? 7.5 : (heli ? 5.5 : 4.5)
            let along = dot(ac.pos - middle, box.dir)
            var carrot = middle + box.dir * min(along + 5.5, 4)
            carrot.y = middle.y
            velocity = unit(carrot - ac.pos, or: box.dir) * fast
            if facing == nil { facing = length(flat(ac.vel)) > 1.5 ? flat(ac.vel) : box.dir }
            if !lazy, via != nil {
                // split-S
                if stage == 0 {
                    c.aileron = inverseRate(7, spec, L)
                    c.throttle = 0.06
                    if ac.up.y < -0.8 { stage = 1 }
                    return c
                }
                if stage == 1 {
                    c.elevator = inverseRate(3.3, spec, L)
                    c.throttle = ac.up.y < 0.2 ? 0.06 : spec.hoverThrottle * 1.1
                    if ac.up.y > 0.6 && ac.forward.x < 0 { stage = 2 }
                    return c
                }
            }
            if !lazy, a.step.id == "multi.pro.powerloop", a.index > 0 {
                let x = ac.pos.x - middle.x
                facing = V3(1, 0, 0)
                if a.index == 1 {
                    // up and back over the gate, then pull over and coast across the top upside down
                    if stage == 0 {
                        let high = ac.pos.y > middle.y - 8
                        velocity = V3(high ? -6 : clampf((2.2 - x) * 2, -3, 3), clampf((middle.y - 1 - ac.pos.y) * 2, 1, 7), middle.z - ac.pos.z)
                        if high && ac.vel.x < -2.7 && x < 2.4 { stage = 1 }
                    } else {
                        c.elevator = ac.up.y > -0.75 + reaction * 3 ? inverseRate(11, spec, L) : 0
                        c.throttle = 0.05
                        return c
                    }
                } else if stage == 0 {
                    c.elevator = inverseRate(8, spec, L)
                    c.throttle = 0.05
                    if ac.up.y > 0.6 { stage = 1 }
                    return c
                } else if stage == 1 {
                    // down behind the gate, then through it
                    velocity = limit((middle - box.dir * 6 - ac.pos) * 1.6, 6)
                    if ac.pos.y < middle.y + 1.5 && x < -3 { stage = 2 }
                }
            }
        case .rotate(let axis, _, _):
            if lazy { break }
            switch axis {
            case .yaw:
                if case .inverted = task.pose {
                    side = -1
                    if stage == 0 {
                        if taskTime < 0.45 { side = 1; climbing = 2.5; break }
                        if ac.up.y < -0.45 { stage = 1 } else {
                            c.aileron = L
                            c.throttle = clampf(0.5 + 0.17 * ac.up.y, 0, 1)
                            return c
                        }
                    }
                    if ac.up.y < -0.9 { fixedYaw = 0.35 }
                } else {
                    fixedYaw = 0.3
                }
            case .roll, .flip:
                if stage == 0 {
                    climbing = 4
                    if ac.vel.y > 2.8 || taskTime > 1.2 { stage = 1 }
                } else if stage == 1 {
                    var flipping = false
                    if case .flip = axis { flipping = true }
                    if flipping { c.elevator = L } else { c.aileron = L }
                    c.throttle = heli ? clampf(0.5 + 0.17 * ac.up.y, 0, 1) : (ac.up.y > 0.4 ? spec.hoverThrottle : 0.04)
                    if ac.up.y < -0.5 { integ = 1 }
                    if integ == 1 && ac.up.y > 0.5 { stage = 2 }
                    return c
                }
            }
        case .stall:
            break
        case .land:
            if lazy { goal.y = middle.y + 3; break }
            let off = length(flat(middle - ac.pos))
            if a.step.failure == .throttleHold {
                velocity = limit(flat(middle - ac.pos) * 0.5, 6)
            } else {
                goal.y = ac.pos.y
                climbing = off < 0.8 ? -clampf(agl * 0.7, 0.35, 0.9) : 0
            }
            if ac.onGround && off < box.size.z / 2 {
                c.throttle = heli ? 0.35 : 0
                return c
            }
        }

        var passing = false
        if case .pass = task.kind { passing = true }
        if !passing && !(a.step.failure == .throttleHold) { velocity = limit((goal - ac.pos) * 0.9, 3) }
        if let up = climbing { velocity.y = up }
        var accel = (velocity - ac.vel) * 1.6
        let error = flat(velocity - ac.vel)
        if !passing { pushInteg = limit(pushInteg + error * dt * 0.7, 2.5) }
        accel = limit(flat(accel), 5) + pushInteg + V3(0, accel.y, 0)

        // where the rotor's lift has to point
        let lift = V3(accel.x, gravity, accel.z)
        let bodyUp = unit(lift, or: V3(0, 1, 0)) * side
        let R = simd_float3x3(ac.q)
        if acro {
            let t = R.transpose * bodyUp
            var wx = atan2(t.z, t.y) * 5.5, wz = atan2(t.x, t.y) * 5.5
            if t.y < -0.2 {
                wx = 0                          // upright again by rolling
            } else if abs(t.y) < 0.2 {
                wx = clampf(wx, -3, 3); wz = clampf(wz, -3, 3)
            }
            c.elevator = inverseRate(wx, spec, L)
            c.aileron = inverseRate(wz, spec, L)
        } else {
            let f = unit(flat(ac.forward), or: V3(0, 0, -1)), r = cross(f, V3(0, 1, 0))
            let most: Float = heli ? 0.75 : spec.multi!.maxAngle
            c.elevator = clampf(-atan(dot(flat(accel), f) / gravity) / most, -L, L)
            c.aileron = clampf(atan(dot(flat(accel), r) / gravity) / most, -L, L)
        }

        // rudder
        if let y = fixedYaw {
            c.rudder = y
        } else {
            let d = facing ?? a.step.start.dir
            let f = flat(ac.forward)
            if length(f) > 0.2 && length(flat(d)) > 0.01 {
                let fn = normalize(f), dn = normalize(flat(d))
                let error = atan2(-cross(fn, dn).y, dot(fn, dn))
                c.rudder = clampf(0.45 * error * side + 0.04 * ac.omega.y, -L, L)
            }
        }

        // collective or throttle
        let rise = velocity.y - ac.vel.y
        climbInteg = clampf(climbInteg + rise * dt * 0.05, -0.15, 0.15)
        if heli {
            if a.step.failure == .throttleHold {
                c.throttle = agl > 3.5 ? clampf(0.42 + (ac.levels[0] - 0.85) * 0.3, 0.3, 0.55)
                                       : clampf(0.7 + 0.3 * (-0.6 - ac.vel.y), 0.35, 1)
            } else if side < 0 {
                c.throttle = clampf(0.335 - 0.13 * rise - climbInteg, 0, 1)
            } else {
                c.throttle = clampf(0.665 + 0.13 * rise + climbInteg, 0, 1)
            }
        } else {
            let pull = max(gravity + rise * 3.2, 0.5) / max(ac.up.y, 0.5)
            c.throttle = clampf(spec.hoverThrottle * sqrt(pull / gravity) + climbInteg * 0.5, 0, 1)
        }
        return c
    }

    /// The stick that gives a rate of rotation in acro.
    private func inverseRate(_ w: Float, _ spec: AircraftSpec, _ L: Float) -> Float {
        let full: Float, centre: Float
        if let h = spec.heli {
            full = h.maxRate; centre = 0.45
        } else {
            let m = spec.multi!
            full = m.acroRate > 0 ? m.acroRate : m.maxRate * 1.6; centre = m.center
        }
        var lo: Float = 0, hi: Float = L
        for _ in 0..<14 {
            let x = (lo + hi) / 2
            if rateCurve(x, center: centre, full: full) < abs(w) { lo = x } else { hi = x }
        }
        return w < 0 ? -(lo + hi) / 2 : (lo + hi) / 2
    }
}
