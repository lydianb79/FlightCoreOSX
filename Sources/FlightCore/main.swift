import AppKit
import GameController
import MetalKit
import SwiftUI

func runSelfTest() {
    let site = SiteSpec.all[0]
    let terrain = Terrain(site: site)
    let env = Environment()
    env.configure(site)
    env.obstacles = terrain.windObstacles
    for spec in AircraftLibrary.all {
        let ac = Aircraft(spec)
        var ap = Autopilot()
        if spec.handLaunch {
            ac.reset(pos: V3(2, 1.9, 0), heading: 0, speed: clampf(spec.stallSpeed * 1.7, 4, 9))
        } else {
            ac.reset(pos: V3(spec.kind == .airplane ? -50 : -6, ac.restHeight + 0.02, 0), heading: -.pi / 2)
        }
        print("== \(spec.name)  mass \(spec.mass) kg")
        var c = Controls()
        var minAgl: Float = 1e9, maxSpeed: Float = 0
        for i in 0..<60_000 {
            if i % 10 == 0 { c = ap.update(ac, terrain: terrain, dt: 0.01) }
            env.advance(dt: 0.001, at: ac.pos, airspeed: ac.airspeed, terrain: terrain)
            ac.step(dt: 0.001, c: c, terrain: terrain, wind: env.wind(at: ac.pos, terrain: terrain), rollMu: site.rollMu)
            let agl = ac.pos.y - terrain.height(ac.pos.x, ac.pos.z)
            if i > 15_000 { minAgl = min(minAgl, agl); maxSpeed = max(maxSpeed, ac.airspeed) }
            if i % 5000 == 0 {
                print(String(format: "t=%4.1f pos=(%7.1f,%6.1f,%7.1f) agl=%5.1f v=%5.1f pitch=%5.1f roll=%6.1f thr=%.2f wp=%d %@",
                             Float(i) / 1000, ac.pos.x, ac.pos.y, ac.pos.z, agl, ac.airspeed, ac.pitch / deg, ac.roll / deg, c.throttle, ap.wp, ac.crashed ? "CRASHED" : ""))
            }
        }
        print(String(format: "   after 15 s: min agl %.1f m, max airspeed %.1f m/s, crashed=%@", minAgl, maxSpeed, ac.crashed ? "YES" : "no"))
    }
}

func runAutorotationTest() {
    let site = SiteSpec.all[0]
    let terrain = Terrain(site: site)
    let ac = Aircraft(AircraftLibrary.all[4])
    ac.reset(pos: V3(0, 90, 0), heading: 0)
    ac.vel = V3(0, 0, -8)
    var c = Controls(); c.hold = true
    print("== Autorotation: \(ac.spec.name), engine off at 90 m, 8 m/s forward")
    for i in 0..<12_000 {
        let agl = ac.pos.y - terrain.height(ac.pos.x, ac.pos.z)
        c.throttle = agl > 6 ? 0.42 : 0.9          // slightly negative collective, then flare
        c.elevator = clampf(3 * (-0.12 - ac.pitch) - 0.3 * ac.omega.x, -1, 1) * (agl > 6 ? 1 : 0) + (agl > 6 ? 0 : clampf(3 * (0.0 - ac.pitch), -1, 1))
        c.aileron = clampf(2 * (0 - ac.roll), -1, 1)
        ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0.05)
        if i % 1000 == 0 || ac.onGround {
            print(String(format: "t=%4.1f agl=%5.1f sink=%5.1f m/s fwd=%4.1f rotor=%3.0f%% %@", Float(i) / 1000, agl, -ac.vel.y, ac.airspeed, ac.levels[0] * 100, ac.crashed ? "CRASHED" : (ac.onGround ? "LANDED" : "")))
            if ac.onGround { break }
        }
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--soundtest"), i + 1 < CommandLine.arguments.count {
    writeSoundTest(to: CommandLine.arguments[i + 1])
    exit(0)
}

if CommandLine.arguments.contains("--hidtest") {
    // report what the controller code detects, then quit
    let input = InputManager()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    print("joysticks: \(input.hid.joysticks.count)  gamepad-class: \(input.hid.gamepads.count)  name: \(input.hid.name)  used as transmitter: \(input.hid.connected)")
    print("system game controllers: " + GCController.controllers().map { "\($0.vendorName ?? "?") extended=\($0.extendedGamepad != nil)" }.joined(separator: ", "))
    print("axes: " + input.hid.axes.map { String(format: "%+.2f", $0) }.joined(separator: " "))
    let c = input.poll(dt: 0.016, kind: .airplane)
    print(String(format: "channels: aileron %+.2f elevator %+.2f throttle %.2f rudder %+.2f  source: %@", c.aileron, c.elevator, c.throttle, c.rudder, input.source))
    exit(0)
}

/// Scripted manoeuvres that exercise the stall, spin and propeller effects, and print each aircraft's figures.
func runPhysicsTest() {
    let site = SiteSpec.all[0]
    let terrain = Terrain(site: site)
    func fly(_ ac: Aircraft, _ seconds: Float, _ c: (Float) -> Controls, each: (Float) -> Void = { _ in }) {
        for i in 0..<Int(seconds * 1000) {
            ac.step(dt: 0.001, c: c(Float(i) / 1000), terrain: terrain, wind: .zero, rollMu: site.rollMu)
            if i % 20 == 0 { each(Float(i) / 1000) }
        }
    }
    print("name                          mass  W/S g/dm2  T/W  stall km/h  Ipitch  Iroll  CG %MAC")
    for spec in AircraftLibrary.all where spec.kind == .airplane {
        let wingZ = spec.surfaces.filter { $0.isWing }.map { $0.pos.z - 0.25 * $0.chord }.min() ?? 0
        let rootChord = spec.surfaces.first { $0.isWing }?.chord ?? 0.2
        print(String(format: "%-28@ %5.2f  %6.0f   %4.2f   %5.0f     %6.3f %6.3f   %3.0f", spec.name as NSString, spec.mass, spec.mass / spec.wingArea * 10,
                     spec.thrustToWeight, spec.stallSpeed * 3.6, spec.inertia.x, spec.inertia.z, -wingZ / rootChord * 100))
    }
    for name in ["Skylark Trainer", "North American T-6 Texan", "P-51D Mustang", "Piper J-3 Cub", "Extra 300", "Flatty 3D"] {
        guard let spec = AircraftLibrary.all.first(where: { $0.name == name }) else { continue }
        print("== \(name)")
        // 1. stalls the way a pilot meets them: hold height as the speed bleeds off, and when the wing lets go
        //    keep the stick where it is for two seconds. Power off, then with 60% power.
        let ac = Aircraft(spec); ac.unlimitedBattery = true
        for power in [Float(0), 0.6] {
            ac.reset(pos: V3(0, 150, 0), heading: 0, speed: spec.stallSpeed * 1.5)
            var elevI: Float = 0, held: Float? = nil, tBreak: Float = 0
            var breakV: Float = 0, pitch0: Float = 0, y0: Float = 0, minPitch: Float = 9, maxBank: Float = 0, done = false
            fly(ac, 25, { t in
                var c = Controls(); c.throttle = power
                if let h = held { c.elevator = h; return c }
                elevI = clampf(elevI + 0.6 * (-ac.vel.y - (power > 0 ? -0.3 : 0)) * 0.001, -0.3, 1)
                c.elevator = clampf(elevI + 0.12 * -ac.vel.y - 0.15 * ac.omega.x, -1, 1)
                c.aileron = clampf(-1.5 * ac.roll, -0.3, 0.3)
                if ac.wingStall > 0.45 || (t > 3 && elevI >= 0.999) { held = c.elevator; tBreak = t; breakV = ac.airspeed; pitch0 = ac.pitch; y0 = ac.pos.y }
                return c
            }, each: { t in
                guard held != nil, !done else { return }
                if t - tBreak > 2 { done = true; print(String(format: "   stall %@: breaks at %.0f km/h (predicted %.0f) with the nose %.0f° up; in the next 2 s the nose reaches %.0f°, bank up to %.0f°, height lost %.0f m",
                                                   power > 0 ? "with power" : "power off ", breakV * 3.6, spec.stallSpeed * 3.6, pitch0 / deg, minPitch / deg, maxBank / deg, y0 - ac.pos.y)); return }
                minPitch = min(minPitch, ac.pitch); maxBank = max(maxBank, abs(ac.roll))
            })
            if !done { print("   stall \(power > 0 ? "with power" : "power off "): did not stall in 25 s — it has the power to hold height") }
        }
        // 2. spin: stall it, then full rudder and up elevator; then neutralise and count the recovery
        ac.reset(pos: V3(0, 250, 0), heading: 0, speed: spec.stallSpeed * 1.15)
        var yawTurned: Float = 0, startY: Float = 0
        fly(ac, 6, { t in
            var c = Controls(); c.elevator = 1; c.rudder = t > 1 ? 1 : 0; c.aileron = 0; return c
        }, each: { t in if t > 1 { yawTurned += abs(ac.q.act(ac.omega).y) * 0.02 } })
        let spinRate = abs(ac.q.act(ac.omega).y) / deg, sink = -ac.vel.y
        startY = ac.pos.y
        var recovered: Float = -1
        fly(ac, 6, { _ in var c = Controls(); c.rudder = -0.6; c.elevator = -0.2; return c },
            each: { t in if recovered < 0 && ac.wingStall < 0.1 && abs(ac.q.act(ac.omega).y) < 0.4 && t > 0.3 { recovered = t } })
        print(String(format: "   spin: turned %.1f times in 5 s, %.0f°/s, sinking %.0f m/s; recovery %@, height lost recovering %.0f m",
                     yawTurned / (2 * .pi), spinRate, sink, recovered < 0 ? "not within 6 s" : String(format: "%.1f s", recovered), startY - ac.pos.y))
        // 3. take-off run with the controls untouched: how far does it swing?
        ac.reset(pos: V3(0, ac.restHeight + 0.02, 0), heading: 0)
        fly(ac, 3.0, { _ in var c = Controls(); c.throttle = 1; return c })
        let hd = atan2(-ac.forward.x, -ac.forward.z) / deg
        print(String(format: "   take-off, hands off, 3 s at full throttle: heading swings %.0f° %@, bank %.0f°, speed %.0f km/h",
                     abs(hd), hd > 0 ? "left" : "right", ac.roll / deg, ac.airspeed * 3.6))
        // 4. battery: full throttle on the ground
        let ac2 = Aircraft(spec)
        ac2.reset(pos: V3(0, 100, 0), heading: 0, speed: spec.stallSpeed * 1.5)
        var t50: Float = 0
        fly(ac2, 40, { _ in var c = Controls(); c.throttle = 1; c.elevator = clampf(2 * (0 - ac2.pitch), -0.5, 0.5); c.aileron = clampf(-2 * ac2.roll, -0.5, 0.5); return c })
        t50 = ac2.battery
        print(String(format: "   battery after 40 s at full throttle in flight: %.0f%%  (shaft speed %.0f%% of static)", t50 * 100, ac2.levels[0] * 100))
    }
}

/// Tests of the ground, water, helicopter and weather models.
func runEnvTest() {
    func site(_ key: String) -> (SiteSpec, Terrain, Environment) {
        let s = SiteSpec.all.first { $0.key == key }!
        let t = Terrain(site: s); let e = Environment(); e.configure(s); e.obstacles = t.windObstacles
        return (s, t, e)
    }
    func plane(_ name: String) -> Aircraft { let a = Aircraft(AircraftLibrary.all.first { $0.name == name }!); a.unlimitedBattery = true; return a }
    // 1. water take-off
    do {
        let (_, terrain, env) = site("lake")
        for name in ["Beaver Floatplane", "Super Cub Floatplane", "Twin Otter Floatplane"] {
            let ac = plane(name)
            guard let p = terrain.waterStart(windFrom: env.windFrom) else { print("no water start found"); break }
            ac.reset(pos: p + V3(0, ac.restHeight - 0.05, 0), heading: -env.windFrom * deg)
            var rest: Float = 0, liftOff: Float = -1, run: Float = 0, hump: Float = 0
            for i in 0..<14000 {
                var c = Controls(); let t = Float(i) / 1000
                c.throttle = t > 2 ? 1 : 0
                c.elevator = t > 2 ? clampf(0.25 + 2 * (0.1 - ac.pitch), -0.3, 0.8) : 0
                c.aileron = clampf(-2 * ac.roll, -0.5, 0.5)
                ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0)
                if i == 1999 { rest = ac.pos.y - (terrain.site.waterLevel ?? 0) }
                if t > 2 && liftOff < 0 { hump = max(hump, ac.pitch); if !ac.onGround && ac.airspeed > 5 { liftOff = t - 2; run = distance(ac.pos, p) } }
            }
            print(String(format: "WATER %@: floats %.2f m above the surface at rest, %@, afterwards %.0f m up at %.0f km/h%@", name, rest,
                         liftOff < 0 ? "did not lift off in 12 s" : String(format: "airborne after %.1f s and %.0f m", liftOff, run),
                         ac.pos.y - (terrain.site.waterLevel ?? 0), ac.airspeed * 3.6, ac.crashed ? "  CRASHED" : ""))
        }
    }
    // 2. landing roll: touch down at 1.3 x stall speed and coast, then the same with brakes, on three surfaces
    for key in ["meadow", "lake", "snow"] {
        let (s, terrain, _) = site(key)
        var out = "ROLL \(s.displayName):"
        for brake in [Float(0), 1] {
            let ac = plane("Skylark Trainer")
            ac.reset(pos: V3(-60, ac.restHeight + 0.02, 0), heading: -.pi / 2, speed: ac.spec.stallSpeed * 1.2)
            var c = Controls(); c.brake = brake; c.elevator = -0.1
            var i = 0
            while i < 40000 && (length(ac.vel) > 0.3 || i < 500) { ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0); i += 1 }
            out += String(format: "  %@ %.0f m", brake > 0 ? "braked" : "coasting", ac.pos.x + 60)
        }
        print(out)
    }
    // 3. crosswind ground loop tendency: taildragger rolling at speed, kicked sideways
    for name in ["Skylark Trainer", "Piper J-3 Cub"] {
        let (_, terrain, _) = site("meadow")
        let ac = plane(name)
        ac.reset(pos: V3(-60, ac.restHeight + 0.02, 0), heading: -.pi / 2, speed: 9)
        ac.omega.y = 0.6
        for _ in 0..<4000 { ac.step(dt: 0.001, c: Controls(), terrain: terrain, wind: .zero, rollMu: 0) }
        let hd = atan2(-ac.forward.x, -ac.forward.z) / deg + 90
        print(String(format: "SWERVE %@: after a 35°/s yaw disturbance at 32 km/h, heading ends %.0f° off%@", name, abs(hd), ac.crashed ? " (tipped over)" : ""))
    }
    // 4. ground effect: fly level at a fixed height and attitude for 3 s; less drag near the ground keeps more speed
    do {
        let (_, terrain, _) = site("meadow")
        var res: [(Float, Float)] = []
        for h in [Float(40), 0.03] {
            let ac = plane("Stick 40")
            let y = h + ac.restHeight
            ac.reset(pos: V3(0, y, 0), heading: -.pi / 2, speed: ac.spec.stallSpeed * 1.5)
            ac.q = ac.q * simd_quatf(angle: 5 * deg, axis: V3(1, 0, 0))
            let q0 = ac.q
            var lift: Float = 0
            for i in 0..<3000 {
                let v0 = ac.vel.y
                ac.step(dt: 0.001, c: Controls(), terrain: terrain, wind: .zero, rollMu: 0)
                if i == 200 { lift = (ac.vel.y - v0) / 0.001 + gravity }
                ac.pos.y = y; ac.vel.y = 0; ac.q = q0; ac.omega = .zero       // hold height and attitude
            }
            res.append((ac.airspeed, lift))
        }
        print(String(format: "GROUND EFFECT low-wing Stick 40, held level at 5° nose-up for 3 s: speed left %.1f km/h at 40 m, %.1f km/h with the wheels just off the runway; lift %.2f g vs %.2f g",
                     res[0].0 * 3.6, res[1].0 * 3.6, res[0].1 / gravity, res[1].1 / gravity))
    }
    // 5. helicopter: vertical descent into vortex ring, then fly forward out of it
    do {
        let (_, terrain, _) = site("meadow")
        let ac = Aircraft(AircraftLibrary.all[4])
        ac.reset(pos: V3(0, 150, 0), heading: 0)
        var maxV: Float = 0, sinkIn: Float = 0, sinkOut: Float = 0
        for i in 0..<16000 {
            let t = Float(i) / 1000
            var c = Controls()
            let eb = simd_float3x3(ac.q).transpose * cross(ac.up, t < 9 ? V3(0, 1, 0) : normalize(V3(0, 1, -0.45)))
            c.elevator = clampf(eb.x * 6 / 5, -1, 1); c.aileron = clampf(-eb.z * 6 / 5, -1, 1)
            c.throttle = t < 3 ? 0.52 : (t < 9 ? 0.66 : 0.8)          // settle into a descent, then pull collective
            ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0)
            maxV = max(maxV, ac.vortexRing)
            if i == 8900 { sinkIn = -ac.vel.y }
            if i == 15900 { sinkOut = -ac.vel.y }
        }
        print(String(format: "VORTEX RING %@: depth %.0f%%; sinking %.1f m/s with hover collective held; %.1f m/s after flying forward out of it", ac.spec.name, maxV * 100, sinkIn, sinkOut))
    }
    // 6. weather: wind profile, turbulence strength, wake behind the clubhouse, thermals
    do {
        let (s, terrain, env) = site("meadow")
        env.windSpeed = 5; env.turbulence = 0
        let prof = [Float(0.3), 1, 2, 5, 10, 30, 100].map { String(format: "%.0f m: %.1f", $0, length(env.wind(at: V3(0, $0, -80), terrain: terrain))) }.joined(separator: ", ")
        print("WIND PROFILE (5 m/s at 10 m): " + prof)
        env.turbulence = 0.3
        func rms(_ p: V3) -> Float {
            var s2: Float = 0; var mean = V3.zero; var n: Float = 0
            var samples: [V3] = []
            for _ in 0..<20000 { env.advance(dt: 0.001, at: p, airspeed: 14, terrain: terrain); samples.append(env.wind(at: p, terrain: terrain)) }
            for v in samples { mean += v; n += 1 }; mean /= n
            for v in samples { s2 += length_squared(v - mean) }
            return sqrt(s2 / n)
        }
        let hw = s.runwayWid / 2
        let d = env.windVec / env.windSpeed
        let club = V3(-48, 2, hw + 34)
        print(String(format: "TURBULENCE (setting 30%%, wind 5 m/s): gust strength %.2f m/s in open air at 30 m, %.2f m/s at 3 m, %.2f m/s 15 m downwind of the clubhouse",
                     rms(V3(0, 30, -150)), rms(V3(0, 3, -150)), rms(club + d * 15)))
        env.thermalsOn = true; env.windSpeed = 0; env.turbulence = 0
        env.advance(dt: 0.001, at: .zero, airspeed: 10, terrain: terrain)
        var up: Float = -9, down: Float = 9
        for i in 0..<400 { let p = V3(Float(i % 20) * 40 - 400, 120, Float(i / 20) * 28 - 460); let w = env.wind(at: p, terrain: terrain).y; up = max(up, w); down = min(down, w) }
        print(String(format: "THERMALS at 120 m: strongest lift %.1f m/s, strongest sink %.1f m/s, %d active", up, down, env.thermals.count))
    }
}

/// Handling diagnostics: control rates for every airplane, and the balance of forces in a prop-hang.
func runHandlingTest() {
    let terrain = Terrain(site: SiteSpec.all[0])
    print("name                            roll deg/s  pitch deg/s  yaw deg/s   (full stick at 1.6 x stall speed)")
    var rolls: [(String, Float)] = []
    for spec in AircraftLibrary.all where spec.kind == .airplane {
        let m = measureRates(spec)
        let r = m.roll, p = m.pitch, y = m.yaw
        rolls.append((spec.name, r))
        print(String(format: "%@  %6.0f      %6.0f      %6.0f", spec.name.padding(toLength: 30, withPad: " ", startingAt: 0), r, p, y))
    }
    let sorted = rolls.sorted { $0.1 < $1.1 }
    print(String(format: "ROLL RATE RANGE: slowest %@ %.0f deg/s, fastest %@ %.0f deg/s", sorted.first!.0, sorted.first!.1, sorted.last!.0, sorted.last!.1))

    // prop-hang: nose straight up, motionless, thrust equal to weight. What does the aircraft do untouched, and how much can the controls push back?
    for name in ["Flatty 3D", "Vortex 3D", "Extra 300"] {
        guard let spec = AircraftLibrary.all.first(where: { $0.name == name }) else { continue }
        func accel(_ c0: Controls) -> V3 {
            let ac = Aircraft(spec); ac.unlimitedBattery = true
            ac.reset(pos: V3(0, 100, 0), heading: 0)
            ac.q = simd_quatf(angle: .pi / 2, axis: V3(1, 0, 0))
            let n = sqrt(spec.mass * gravity / spec.props[0].staticThrust)
            ac.levels[0] = n
            var c = c0; c.throttle = 0.82 * n + 0.18 * n * n            // throttle that holds this shaft speed
            for _ in 0..<60 { ac.vel = .zero; ac.omega = .zero; ac.q = simd_quatf(angle: .pi / 2, axis: V3(1, 0, 0)); ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0) }
            ac.omega = .zero; ac.vel = .zero
            ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0)
            return ac.omega / 0.001 / deg
        }
        let rest = accel(Controls())
        var ca = Controls(); ca.aileron = 1; var ce = Controls(); ce.elevator = 1; var cr = Controls(); cr.rudder = 1
        let a = accel(ca) - rest, e = accel(ce) - rest, r = accel(cr) - rest
        print(String(format: "HOVER %@ (hover needs %.0f%% shaft speed): untouched it accelerates roll %.0f, pitch %.0f, yaw %.0f deg/s2; full stick can add roll %.0f, pitch %.0f, yaw %.0f deg/s2",
                     name, sqrt(spec.mass * gravity / spec.props[0].staticThrust) * 100, rest.z, rest.x, rest.y, abs(a.z), abs(e.x), abs(r.y)))
    }
    // continuous roll at speed: hold full aileron for three rolls and see how far the nose wanders off the direction of flight
    for name in ["Flatty 3D", "Vortex 3D", "Extra 300", "Skylark Trainer"] {
        guard let spec = AircraftLibrary.all.first(where: { $0.name == name }) else { continue }
        let ac = Aircraft(spec); ac.unlimitedBattery = true
        ac.reset(pos: V3(0, 300, 0), heading: 0, speed: spec.stallSpeed * 2.6)
        var c = Controls(); c.throttle = 0.8
        for _ in 0..<400 { ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0) }
        let dir0 = normalize(V3(ac.vel.x, 0, ac.vel.z))
        c.aileron = 1
        var turns: Float = 0, cone: Float = 0, t: Float = 0
        while turns < 3 && t < 6 {
            ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0)
            turns += abs(ac.omega.z) * 0.001 / (2 * .pi); t += 0.001
            cone = max(cone, acos(clampf(dot(ac.forward, normalize(ac.vel)), -1, 1)) / deg)
        }
        let hv = normalize(V3(ac.vel.x, 0, ac.vel.z))
        print(String(format: "ROLLS %@: 3 rolls in %.1f s; nose up to %.0f° off the direction of flight; heading drifts %.0f°; height lost %.0f m",
                     name, t, cone, acos(clampf(dot(hv, dir0), -1, 1)) / deg, 300 - ac.pos.y))
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--pitchdebug"), i + 2 < CommandLine.arguments.count {
    // step response in pitch: aircraft name, elevator amount
    let spec = AircraftLibrary.all.first { $0.name == CommandLine.arguments[i + 1] }!
    let terrain = Terrain(site: SiteSpec.all[0])
    let ac = Aircraft(spec); ac.unlimitedBattery = true
    ac.reset(pos: V3(0, 200, 0), heading: 0, speed: spec.stallSpeed * 1.6)
    var c = Controls(); c.throttle = 0.5
    for k in 0..<1000 {
        if k == 300 { c.elevator = Float(CommandLine.arguments[i + 2]) ?? 0.2 }
        ac.step(dt: 0.001, c: c, terrain: terrain, wind: .zero, rollMu: 0)
        if k % 50 == 0 {
            let va = simd_float3x3(ac.q).transpose * ac.vel
            print(String(format: "t=%.2f pitch rate %6.0f deg/s  alpha %5.1f  speed %4.1f  wing stall %.2f  pitch %5.1f", Float(k) / 1000, ac.omega.x / deg, atan2(-va.y, -va.z) / deg, ac.airspeed, ac.wingStall, ac.pitch / deg))
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--handlingtest") {
    let t0 = Date(); _ = AircraftLibrary.all.count
    print(String(format: "LIBRARY built and calibrated in %.2f s", Date().timeIntervalSince(t0)))
    runHandlingTest()
    exit(0)
}

if CommandLine.arguments.contains("--envtest") {
    runEnvTest()
    exit(0)
}

if CommandLine.arguments.contains("--physicstest") {
    runPhysicsTest()
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    runAutorotationTest()
    exit(0)
}

// MARK: - Application

final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?
    convenience init(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [.command], _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
        self.handler = handler
    }
    @objc private func fire() { handler?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var game: Game!
    var renderer: Renderer!
    var setupWindow: NSWindow?

    func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        _ = Panoramas.userDir
        var siteArg = Int(arg("--site") ?? "") ?? 0
        if let p = arg("--pano") { SiteSpec.all.append(Panoramas.site(for: URL(fileURLWithPath: p))); siteArg = SiteSpec.all.count - 1 }
        var acArg = Int(arg("--aircraft") ?? "") ?? 0
        let interactive = CommandLine.arguments.count == 1          // launched normally, not by a test command line
        if interactive {
            // restore the last aircraft and site
            if let n = UserDefaults.standard.string(forKey: "lastAircraft"), let i = AircraftLibrary.all.firstIndex(where: { $0.name == n }) { acArg = i }
            if let n = UserDefaults.standard.string(forKey: "lastSite"), let i = SiteSpec.all.firstIndex(where: { $0.name == n }) { siteArg = i }
        }
        game = Game(site: siteArg, aircraft: acArg)
        if CommandLine.arguments.contains("--menu") { game.hud.overlay = .menu }
        if interactive || CommandLine.arguments.contains("--splash") { game.hud.overlay = .splash }
        if let o = arg("--overlay") { game.hud.overlay = ["aircraft": .aircraft, "sites": .sites, "environment": .environment, "help": .help, "menu": .menu, "splash": .splash][o] ?? .none }
        game.hud.addPanorama = { [unowned self] in self.addPanorama() }
        game.hud.openControllerSetup = { [unowned self] in self.showSetup() }
        if let c = Int(arg("--cam") ?? "") { game.cameraMode = c }
        if let z = Int(arg("--zoom") ?? "") { game.zoomMode = z }
        if let t = Int(arg("--tod") ?? "") { game.timeOfDay = t }
        if CommandLine.arguments.contains("--auto") { game.autopilotOn = true }
        if CommandLine.arguments.contains("--balloons") { game.toggleChallenge() }
        let args = CommandLine.arguments
        if args.contains("--smoke") { game.smokeOn = true }
        if let q = Int(arg("--quality") ?? "") { game.quality = q }
        if args.contains("--obstacles") { game.showObstacles = true }
        if let c = arg("--view")?.split(separator: ",").compactMap({ Float($0) }), c.count == 6 { game.fixedView = (V3(c[0], c[1], c[2]), V3(c[3], c[4], c[5])) }
        if let c = arg("--closeup")?.split(separator: ",").compactMap({ Float($0) }), c.count == 3 { game.closeup = V3(c[0], c[1], c[2]) }
        if args.contains("--gearup") { game.gearUp = true }
        if args.contains("--flaps") { game.flapSetting = 1 }
        if let ff = Float(arg("--ff") ?? "") { for _ in 0..<Int(ff * 60) { game.frame(dt: 1 / 60) } }
        if args.contains("--crash") {       // test hook: dive into the ground
            game.aircraft.pos.y = game.terrain.height(game.aircraft.pos.x, game.aircraft.pos.z) + 2.5
            game.aircraft.vel = V3(9, -14, 0)
            for _ in 0..<40 { game.frame(dt: 1 / 60) }
        }

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FlightCore"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.76, green: 0.13, blue: 0.1, alpha: 1)
        window.minSize = NSSize(width: 1000, height: 640)
        window.center()
        window.collectionBehavior = [.fullScreenPrimary]
        let container = NSView(frame: frame)
        container.wantsLayer = true
        let mtk = MTKView(frame: frame)
        mtk.autoresizingMask = [.width, .height]
        guard let r = Renderer(view: mtk, game: game) else {
            let a = NSAlert(); a.messageText = "Metal is not available on this Mac."; a.runModal(); NSApp.terminate(nil); return
        }
        renderer = r
        if let shot = arg("--shot") {
            mtk.framebufferOnly = false
            r.shotPath = shot
            r.shotAfter = Double(arg("--after") ?? "") ?? 1.5
        }
        mtk.delegate = r
        container.addSubview(mtk)
        let hud = NSHostingView(rootView: HUDView(m: game.hud))
        hud.frame = frame
        hud.autoresizingMask = [.width, .height]
        container.addSubview(hud)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [unowned self] _ in self.game.hud.fullscreen = true }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [unowned self] _ in self.game.hud.fullscreen = false }
        // start in full screen (⌃⌘F leaves it); test command lines stay windowed unless asked
        if interactive || CommandLine.arguments.contains("--fullscreen") { window.toggleFullScreen(nil) }
        NSApp.activate(ignoringOtherApps: true)
        buildMenus()
        if CommandLine.arguments.contains("--setup") { showSetup() }
        if CommandLine.arguments.contains("--perf") {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in
                let iv = self.renderer.statIntervals.sorted(), cpu = self.renderer.statCpu.sorted()
                let pr = self.renderer.statPresented.sorted(); self.renderer.statPresented = []
                self.renderer.statIntervals = []; self.renderer.statCpu = []
                guard iv.count > 4, cpu.count > 4 else { return }
                let med = iv[iv.count / 2]; _ = med
                let late = iv.filter { $0 > med * 1.5 }.count
                let jitter = iv.map { abs($0 - med) }.reduce(0, +) / Float(iv.count)
                let lateOnScreen = pr.filter { $0 > 25 }.count
                let adv = self.game.advanceMs.sorted(); self.game.advanceMs = []
                if adv.count > 10 { print(String(format: "MOTION per-frame advance min %.2f max %.2f ms (spread %.2f ms)", adv[1], adv[adv.count - 2], adv[adv.count - 2] - adv[1])) }
                print(String(format: "PERF frames %d  on-screen %d late %d max %.1f ms | callback late %d jitter %.2f ms  cpu med %.1f max %.1f ms  gpu %.1f ms  scale %.2f  screen %d Hz",
                             iv.count, pr.count, lateOnScreen, pr.last ?? 0, late, jitter, cpu[cpu.count / 2], cpu.last!, self.game.gpuMs, self.game.renderScale, NSScreen.main?.maximumFramesPerSecond ?? 0)); fflush(stdout)
            }
        }
        if CommandLine.arguments.contains("--printwin") { print("WINDOW \(window.windowNumber)"); fflush(stdout) }

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [unowned self] e in
            guard e.window === self.window else { return e }
            // while a menu or browser is open the keyboard belongs to it; Esc steps back
            if self.game.hud.overlay == .splash {
                if e.type == .keyDown { self.game.hud.overlay = .menu }
                return nil
            }
            if self.game.hud.overlay != .none {
                if e.type == .keyDown && e.keyCode == 53 {
                    let o = self.game.hud.overlay
                    self.game.hud.overlay = (o == .aircraft || o == .sites) && self.game.cameFromMenu ? .menu : .none
                    return nil
                }
                if self.game.hud.overlay.pausesSim || self.game.hud.overlay == .help { self.game.input.keys.removeAll(); return e }
            } else if e.type == .keyDown && !e.modifierFlags.contains(.command) {
                if e.keyCode == 53 { self.game.cameFromMenu = false; self.game.hud.overlay = .menu; return nil }
                if e.keyCode == 48 { self.game.cameFromMenu = false; self.game.hud.overlay = .aircraft; return nil }
            }
            if e.type == .flagsChanged {
                if e.modifierFlags.contains(.shift) { self.game.input.keys.insert(56) } else { self.game.input.keys.remove(56); self.game.input.keys.remove(60) }
                return e
            }
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) { return e }
            if e.type == .keyDown {
                if !e.isARepeat { self.game.input.keys.insert(e.keyCode); self.game.keyDown(e.keyCode) }
            } else {
                self.game.input.keys.remove(e.keyCode)
            }
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [unowned self] _ in
            self.game.input.keys.removeAll()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        let g = game!
        menu("FlightCore", [
            ClosureMenuItem("About FlightCore") { NSApp.orderFrontStandardAboutPanel(nil) },
            .separator(),
            ClosureMenuItem("Hide FlightCore", key: "h") { NSApp.hide(nil) },
            ClosureMenuItem("Quit FlightCore", key: "q") { NSApp.terminate(nil) },
        ])
        // aircraft grouped into submenus by category
        var acItems: [NSMenuItem] = []
        let order = ["Trainers & Sport", "Scale Civil", "Warbirds", "Aerobatic", "Foam 3D", "Wings", "Jets", "Gliders", "Helicopters", "Multirotors"]
        let cats = order + Set(AircraftLibrary.all.map { $0.category }).subtracting(order).sorted()
        for cat in cats {
            let sub = NSMenu(title: cat)
            for (i, sp) in AircraftLibrary.all.enumerated() where sp.category == cat {
                sub.addItem(ClosureMenuItem(sp.name, key: i < 9 ? "\(i + 1)" : "") { g.selectAircraft(i) })
            }
            guard sub.items.count > 0 else { continue }
            let item = NSMenuItem(title: cat, action: nil, keyEquivalent: "")
            item.submenu = sub
            acItems.append(item)
        }
        acItems.insert(ClosureMenuItem("Choose Aircraft…", key: "a", mods: [.command, .shift]) { g.cameFromMenu = false; g.hud.overlay = .aircraft }, at: 0)
        acItems.insert(.separator(), at: 1)
        acItems.append(.separator())
        acItems.append(ClosureMenuItem("Next Aircraft", key: "]") { g.keyDown(30) })
        acItems.append(ClosureMenuItem("Previous Aircraft", key: "[") { g.keyDown(33) })
        menu("Aircraft", acItems)
        var siteItems: [NSMenuItem] = []
        for (title, photo) in [("3D Sites", false), ("Photo Sites", true)] {
            let sub = NSMenu(title: title)
            for (i, sp) in SiteSpec.all.enumerated() where (sp.panorama != nil) == photo { sub.addItem(ClosureMenuItem(sp.displayName) { g.selectSite(i) }) }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            siteItems.append(item)
        }
        siteItems.insert(ClosureMenuItem("Choose Flying Site…", key: "s", mods: [.command, .shift]) { g.cameFromMenu = false; g.hud.overlay = .sites }, at: 0)
        siteItems.insert(.separator(), at: 1)
        siteItems.append(.separator())
        siteItems.append(ClosureMenuItem("Add 360° Panorama Photo…", key: "o") { [unowned self] in self.addPanorama() })
        siteItems.append(ClosureMenuItem("Show Panoramas Folder") { NSWorkspace.shared.open(Panoramas.userDir) })
        siteItems.append(.separator())
        siteItems.append(ClosureMenuItem("Photo: Rotate Left 5°", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!), mods: [.command, .option]) { g.adjustPanorama(north: -5) })
        siteItems.append(ClosureMenuItem("Photo: Rotate Right 5°", key: String(UnicodeScalar(NSRightArrowFunctionKey)!), mods: [.command, .option]) { g.adjustPanorama(north: 5) })
        siteItems.append(ClosureMenuItem("Photo: Horizon Up 0.5°", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), mods: [.command, .option]) { g.adjustPanorama(horizon: 0.5) })
        siteItems.append(ClosureMenuItem("Photo: Horizon Down 0.5°", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), mods: [.command, .option]) { g.adjustPanorama(horizon: -0.5) })
        siteItems.append(ClosureMenuItem("Photo: Eye Height +0.1 m") { g.adjustPanorama(eye: 0.1) })
        siteItems.append(ClosureMenuItem("Photo: Eye Height −0.1 m") { g.adjustPanorama(eye: -0.1) })
        siteItems.append(ClosureMenuItem("Photo: Show / Hide Obstacles") { g.showObstacles.toggle(); g.say(g.site.obstacles.isEmpty ? "This site has no obstacles defined" : (g.showObstacles ? "Obstacles shown" : "Obstacles hidden")) })
        menu("Flying Site", siteItems)
        menu("Simulation", [
            ClosureMenuItem("Main Menu") { g.cameFromMenu = false; g.hud.overlay = .menu },
            ClosureMenuItem("Weather…", key: "e", mods: [.command, .shift]) { g.hud.overlay = .environment },
            .separator(),
            ClosureMenuItem("Reset Aircraft", key: "r") { g.resetAircraft() },
            ClosureMenuItem("Pause / Resume", key: "p") { g.paused.toggle() },
            ClosureMenuItem("Slow Motion") { g.keyDown(17) },
            .separator(),
            ClosureMenuItem("Balloon Burst Challenge", key: "b") { g.toggleChallenge() },
            ClosureMenuItem("Demo Pilot", key: "k") { g.keyDown(40) },
            ClosureMenuItem("Flight Mode (Self-level / Acro)") { g.keyDown(3) },
            ClosureMenuItem("Unlimited Battery On / Off") { g.unlimitedBattery.toggle(); g.say(g.unlimitedBattery ? "Unlimited battery" : "Battery drains with use") },
        ])
        var envItems: [NSMenuItem] = [0, 2, 5, 8, 12].map { s in ClosureMenuItem("Wind \(s) m/s") { g.env.windSpeed = Float(s); g.say("Wind \(s) m/s") } }
        envItems.append(.separator())
        envItems += [("North", 0), ("East", 90), ("South", 180), ("West", 270)].map { n, d in
            ClosureMenuItem("Wind from \(n)") { g.env.windFrom = Float(d); g.say("Wind from \(n)") }
        }
        envItems.append(.separator())
        envItems += [("Smooth air", 0), ("Light turbulence", 0.3), ("Gusty", 0.8)].map { n, t in
            ClosureMenuItem(n) { g.env.turbulence = Float(t); g.say(n) }
        }
        envItems.append(ClosureMenuItem("Thermals On / Off") { g.env.thermalsOn.toggle(); g.say(g.env.thermalsOn ? "Thermals on" : "Thermals off") })
        envItems.append(.separator())
        envItems += Game.timeNames.enumerated().map { i, n in ClosureMenuItem(n) { g.timeOfDay = i } }
        menu("Environment", envItems)
        var viewItems: [NSMenuItem] = Game.cameraNames.enumerated().map { i, n in ClosureMenuItem("Camera: " + n) { g.cameraMode = i; g.keyDown(8); g.keyDown(8); g.keyDown(8) } }
        viewItems.append(.separator())
        viewItems += Game.zoomNames.enumerated().map { i, n in ClosureMenuItem("Zoom: " + n) { g.zoomMode = i; g.say("Zoom: " + n) } }
        viewItems.append(.separator())
        viewItems += Game.qualityNames.enumerated().map { i, n in ClosureMenuItem("Graphics: " + n) { g.quality = i; g.say("Graphics quality: " + n) } }
        viewItems.append(.separator())
        viewItems.append(ClosureMenuItem("Show / Hide HUD") { g.hud.visible.toggle() })
        viewItems.append(ClosureMenuItem("Keyboard Controls") { g.hud.overlay = g.hud.overlay == .help ? .none : .help })
        viewItems.append(ClosureMenuItem("Toggle Full Screen", key: "f", mods: [.command, .control]) { [unowned self] in self.window.toggleFullScreen(nil) })
        menu("View", viewItems)
        menu("Controller", [
            ClosureMenuItem("Controller Setup…", key: ",") { [unowned self] in self.showSetup() },
            ClosureMenuItem("Switch High / Low Rates", key: "l") { g.keyDown(37) },
            ClosureMenuItem("Mute Sound", key: "m") { g.keyDown(46) },
        ])
        NSApp.mainMenu = main
    }

    private func addPanorama() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose 360° equirectangular panorama photos (2:1 aspect ratio)"
        guard panel.runModal() == .OK else { return }
        var last: URL?
        for src in panel.urls {
            let dst = Panoramas.userDir.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.copyItem(at: src, to: dst) }
            if FileManager.default.fileExists(atPath: dst.path) { last = dst }
        }
        SiteSpec.all = SiteSpec.builtIn + Panoramas.discover()
        buildMenus()
        if let l = last, let i = SiteSpec.all.firstIndex(where: { $0.panorama?.lastPathComponent == l.lastPathComponent }) { game.selectSite(i); game.hud.overlay = .none }
    }

    private func showSetup() {
        if setupWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Controller Setup"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(model: SetupModel(input: game.input)))
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            setupWindow = w
        }
        setupWindow?.makeKeyAndOrderFront(nil)
    }
}

final class SetupModel: ObservableObject {
    let input: InputManager
    @Published var values = [Float](repeating: 0, count: 4)
    @Published var device = ""
    @Published var connected = false
    @Published var calibrating = false
    @Published var s: InputSettings { didSet { input.settings = s } }
    private var timer: Timer?
    init(input: InputManager) {
        self.input = input
        s = input.settings
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let m = self else { return }
            m.values = (0..<4).map { m.input.channel($0) }
            m.connected = m.input.hid.connected
            m.device = m.connected ? m.input.hid.name : "No USB transmitter or joystick detected"
        }
    }
    func calibrate() {
        if calibrating { input.finishCalibration(); s = input.settings } else { input.startCalibration() }
        calibrating = input.calibrating
    }
    func resetCalibration() { input.resetCalibration(); s = input.settings; calibrating = false }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    private func pct(_ title: String, _ v: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: v, in: range)
            Text(String(format: "%.0f %%", v.wrappedValue * 100)).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("USB transmitter").font(.headline)
            Text(model.device).foregroundColor(model.connected ? .primary : .secondary)
            ForEach(0..<4, id: \.self) { i in
                HStack {
                    Text(InputSettings.channelNames[i]).frame(width: 70, alignment: .leading)
                    Picker("", selection: $model.s.axis[i]) {
                        ForEach(0..<9, id: \.self) { Text(InputSettings.axisNames[$0]).tag($0) }
                    }.labelsHidden().frame(width: 90)
                    Toggle("Reverse", isOn: $model.s.invert[i])
                    ProgressView(value: Double(model.values[i] + 1) / 2).frame(width: 110)
                    Text(String(format: "%+.2f", model.values[i])).monospacedDigit().frame(width: 48)
                }
            }
            HStack {
                Button(model.calibrating ? "Done — sticks are centred" : "Calibrate…") { model.calibrate() }
                Button("Reset Calibration") { model.resetCalibration() }.disabled(model.calibrating)
            }
            Text(model.calibrating
                 ? "Move both sticks through their full travel several times, then let them centre (throttle can stay anywhere) and click Done."
                 : "After calibrating, each bar should reach −1 and +1 at the stick ends. Throttle should read −1 at idle and elevator +1 with the stick pulled back; tick Reverse if not.")
                .font(.caption).foregroundColor(model.calibrating ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Stick mode").font(.headline)
            Picker("", selection: $model.s.stickMode) {
                ForEach(1...4, id: \.self) { Text(InputSettings.modeNames[$0 - 1]).tag($0) }
            }.labelsHidden()
            Text("Sets the stick layout for gamepads and the on-screen stick display. A transmitter's mode is fixed by its hardware.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Rates and expo").font(.headline)
            pct("Low rate", $model.s.lowRate, 0.3...1)
            pct("Aileron expo", $model.s.expo[0], 0...0.8)
            pct("Elevator expo", $model.s.expo[1], 0...0.8)
            pct("Rudder expo", $model.s.expo[2], 0...0.8)
            pct("Stick deadband", $model.s.deadband, 0...0.15)
            Text("Press L while flying to switch between high and low rates. Set expo to 0 if your transmitter already applies its own.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 520)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
