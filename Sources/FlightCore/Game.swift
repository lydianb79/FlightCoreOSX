import simd
import Foundation
import SwiftUI
import AppKit

struct HUDState {
    var aircraft = "", site = "", blurb = ""
    var alt: Float = 0, speed: Float = 0, dist: Float = 0, climb: Float = 0, throttle: Float = 0
    var wind = "", message = "", camera = "", mode = "", input = "", score = "", time = ""
    var lx: Float = 0, ly: Float = 0, rx: Float = 0, ry: Float = 0
    var leftLabel = "THR / RUD", rightLabel = "ELE / AIL", rates = "", config = ""
    var fps = 0
}

enum Overlay {
    case none, menu, aircraft, sites, environment, help, splash
    /// The simulation is frozen while these are open.
    var pausesSim: Bool { self == .menu || self == .aircraft || self == .sites || self == .splash }
}

final class HUDModel: ObservableObject {
    @Published var s = HUDState()
    @Published var visible = true
    @Published var overlay = Overlay.none
    @Published var fullscreen = false
    unowned var game: Game!
    var thumbnailer: ((AircraftSpec) -> NSImage?)?      // provided by the renderer
    var addPanorama: (() -> Void)?
    var openControllerSetup: (() -> Void)?
    private var thumbs: [String: NSImage] = [:]
    private var sitePreviews: [String: NSImage] = [:]

    func thumbnail(_ spec: AircraftSpec) -> NSImage? {
        if let t = thumbs[spec.name] { return t }
        guard let img = thumbnailer?(spec) else { return nil }
        thumbs[spec.name] = img
        return img
    }

    func sitePreview(_ site: SiteSpec) -> NSImage? {
        if let t = sitePreviews[site.name] { return t }
        var img: NSImage?
        if let url = site.panorama {
            // crop the middle of the panorama (the view straight ahead)
            if let full = Panoramas.image(url, maxSize: 2048) {
                let w = full.width, h = full.height
                let shift = Int(Float(w) * site.north / 360)
                let cx = ((w / 2 + shift) % w + w) % w
                let cw = w / 4, ch = Int(Float(cw) * 0.625)
                let x0 = min(max(cx - cw / 2, 0), w - cw)
                if let c = full.cropping(to: CGRect(x: x0, y: h / 2 - Int(Float(ch) * 0.62), width: cw, height: ch)) {
                    img = NSImage(cgImage: c, size: NSSize(width: cw, height: ch))
                }
            }
        } else if let url = resourceURL("Previews/site_\(site.key).jpg") {
            img = NSImage(contentsOf: url)
        }
        if let i = img { sitePreviews[site.name] = i }
        return img
    }
}

/// Locate a bundled resource, both inside the .app and when run from the source folder.
func resourceURL(_ rel: String) -> URL? {
    let fm = FileManager.default
    var roots: [URL] = []
    if let r = Bundle.main.resourceURL { roots.append(r) }
    roots.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources"))
    roots.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources"))
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<4 { roots.append(dir.appendingPathComponent("Resources")); dir = dir.deletingLastPathComponent() }
    for r in roots {
        let u = r.appendingPathComponent(rel)
        if fm.fileExists(atPath: u.path) { return u }
    }
    return nil
}

struct Balloon { var pos: V3; var color: V4; var alive = true }

/// A part that has broken off in a crash and tumbles on its own.
struct Debris { var part: Int; var pos: V3; var q: simd_quatf; var vel: V3; var omega: V3; var offset: V3 }

/// Smoke / dust puff, drawn as a camera-facing quad.
struct Particle { var pos: V3; var vel: V3; var age: Float; var life: Float; var size: Float; var color: V4 }

struct Lighting { var sunDir: V3; var sun: V3; var ambient: V3; var zenith: V3; var horizon: V3 }

final class Game {
    static let cameraNames = ["Pilot (line of sight)", "Chase", "Onboard"]
    static let zoomNames = ["Auto zoom", "Keep ground in view", "Fixed"]
    static let timeNames = ["Morning", "Midday", "Evening"]

    var siteIndex = 0, aircraftIndex = 0
    var site: SiteSpec
    var terrain: Terrain
    let env = Environment()
    var aircraft: Aircraft
    let input = InputManager()
    let sound = SoundEngine()
    let hud = HUDModel()

    var paused = false
    var timeScale: Float = 1
    var cameraMode = 0, zoomMode = 1, flightMode = 0, timeOfDay = 1
    var autopilotOn = false
    var autopilot = Autopilot()
    var controls = Controls()
    var siteVersion = 0, aircraftVersion = 0
    var panoLight: Lighting?

    var eye = V3(0, 1.7, 14), target = V3(0, 1, 0), upVec = V3(0, 1, 0)
    var fov: Float = 50 * deg
    private var camTarget = V3.zero
    private var camSnap = true

    var balloons: [Balloon] = []
    var debris: [Debris] = []
    var particles: [Particle] = []
    var showObstacles = false
    /// Graphics quality: 0 low (reduced resolution, no ambient occlusion), 1 medium, 2 high (full resolution)
    var quality: Int = (UserDefaults.standard.object(forKey: "quality") as? Int) ?? 2 { didSet { UserDefaults.standard.set(quality, forKey: "quality") } }
    static let qualityNames = ["Low", "Medium", "High"]
    var renderScale: Float = 1, gpuMs: Float = 0       // reported by the renderer
    var advanceMs: [Float] = []
    static let noInterp = CommandLine.arguments.contains("--no-interp")
    var cameFromMenu = false        // browsers return to the main menu when opened from it
    var fixedView: (eye: V3, target: V3)? = nil     // debug: absolute camera, heights above the pilot's ground
    var closeup: V3? = nil          // debug: fixed camera offset from the aircraft, in wingspans
    var flapSetting: Float = 0
    var gearUp = false, smokeOn = false, hold = false
    private var wasCrashed = false, smokeAcc: Float = 0
    private var rng = LCG(7)
    var challenge = false
    private var score = 0, challengeTime: Float = 0
    private var acc: Float = 0, crashTimer: Float = 0, hudTimer: Float = 0
    private var message = "", messageTimer: Float = 0
    private var frames = 0, fpsTime: Float = 0, fps = 0
    private var lastY: Float = 0, climb: Float = 0

    init(site si: Int = 0, aircraft ai: Int = 0) {
        siteIndex = min(max(si, 0), SiteSpec.all.count - 1)
        aircraftIndex = min(max(ai, 0), AircraftLibrary.all.count - 1)
        site = SiteSpec.all[siteIndex]
        terrain = Terrain(site: site)
        env.configure(site)
        panoLight = site.panorama != nil ? Panoramas.analyze(site) : nil
        timeOfDay = site.defaultTime
        aircraft = Aircraft(AircraftLibrary.all[aircraftIndex])
        resetAircraft()
        hud.game = self
    }

    var lighting: Lighting {
        if let p = panoLight { return p }
        switch timeOfDay {
        case 0: return Lighting(sunDir: normalize(V3(0.8, 0.3, 0.5)), sun: V3(1, 0.85, 0.65) * 2.8, ambient: V3(0.36, 0.42, 0.55) * 0.5,
                                zenith: V3(0.16, 0.3, 0.6), horizon: V3(0.7, 0.66, 0.6))
        case 2: return Lighting(sunDir: normalize(V3(-0.85, 0.2, 0.45)), sun: V3(1, 0.58, 0.3) * 3.4, ambient: V3(0.4, 0.38, 0.5) * 0.7,
                                zenith: V3(0.1, 0.17, 0.4), horizon: V3(0.8, 0.5, 0.32))
        default: return Lighting(sunDir: normalize(V3(-0.35, 0.8, 0.5)), sun: V3(1, 0.96, 0.88) * 3.2, ambient: V3(0.34, 0.45, 0.62) * 0.62,
                                 zenith: V3(0.09, 0.24, 0.6), horizon: V3(0.5, 0.65, 0.84))
        }
    }

    // MARK: Commands

    func say(_ m: String, _ t: Float = 2.5) { message = m; messageTimer = t }

    func resetAircraft() {
        let spec = aircraft.spec
        if site.panorama != nil {
            // photo sites: each has its own start point and take-off direction
            let k: Float = spec.kind == .airplane ? 1 : 0.6
            let hd = -site.startHeading * deg
            if spec.handLaunch { aircraft.reset(pos: V3(2, 1.9, -3), heading: hd, speed: clampf(spec.stallSpeed * 1.7, 4, 9)) }
            else { aircraft.reset(pos: V3(site.startX * k, aircraft.restHeight + 0.02, site.startZ * k), heading: hd) }
        } else if spec.handLaunch {
            aircraft.reset(pos: terrain.pilotPos + V3(2, 1.9, -3), heading: 0, speed: clampf(spec.stallSpeed * 1.7, 4, 9))
        } else {
            let x: Float = spec.kind == .airplane ? -min(site.runwayLen / 2 - 20, 45) : -5
            let z: Float = site.startZ + (spec.kind == .airplane ? 0 : -1)
            aircraft.reset(pos: V3(x, terrain.height(x, z) + aircraft.restHeight + 0.02, z), heading: -.pi / 2)
        }
        input.resetThrottle(spec.kind, launch: spec.handLaunch)
        crashTimer = 0
        autopilot = Autopilot()
        camSnap = true
        debris = []; wasCrashed = false
        flapSetting = 0; gearUp = false; hold = false
        lastY = aircraft.pos.y; climb = 0
    }

    func selectAircraft(_ i: Int) {
        guard i >= 0 && i < AircraftLibrary.all.count else { return }
        aircraftIndex = i
        aircraft = Aircraft(AircraftLibrary.all[i])
        flightMode = 0
        aircraftVersion += 1
        resetAircraft()
        UserDefaults.standard.set(aircraft.spec.name, forKey: "lastAircraft")
        say(aircraft.spec.name + " — " + aircraft.spec.blurb, 4)
    }

    func selectSite(_ i: Int) {
        guard i >= 0 && i < SiteSpec.all.count else { return }
        siteIndex = i
        site = SiteSpec.all[i]
        terrain = Terrain(site: site)
        env.configure(site)
        panoLight = site.panorama != nil ? Panoramas.analyze(site) : nil
        if site.panorama != nil { cameraMode = 0 } else { timeOfDay = site.defaultTime }
        siteVersion += 1
        if challenge { spawnBalloons() }
        resetAircraft()
        UserDefaults.standard.set(site.name, forKey: "lastSite")
        say(site.name, 3)
    }

    /// Align a photo site: rotate it, shift its horizon, or change the camera height. Saved next to the image.
    func adjustPanorama(north: Float = 0, horizon: Float = 0, eye: Float = 0) {
        guard site.panorama != nil else { say("Only for photo sites"); return }
        site.north = (site.north + north).truncatingRemainder(dividingBy: 360)
        site.horizon = clampf(site.horizon + horizon, -20, 20)
        site.eyeHeight = clampf(site.eyeHeight + eye, 0.3, 30)
        SiteSpec.all[siteIndex] = site
        Panoramas.save(site)
        panoLight = Panoramas.analyze(site)
        say(String(format: "Rotation %.0f°  ·  horizon %+.1f°  ·  eye height %.1f m", site.north, site.horizon, site.eyeHeight))
    }

    func toggleChallenge() {
        challenge.toggle()
        if challenge { spawnBalloons(); say("Balloon Burst — pop all 10 balloons!", 4) } else { balloons = []; say("Challenge off") }
    }

    private func spawnBalloons() {
        var rng = LCG(UInt64(Date().timeIntervalSince1970))
        let cols = [rgb(0.95, 0.15, 0.15), rgb(0.98, 0.8, 0.1), rgb(0.15, 0.45, 0.95), rgb(0.2, 0.8, 0.3), rgb(0.9, 0.3, 0.8)]
        balloons = (0..<10).map { i in
            let x = rng.range(-130, 130), z = rng.range(-170, -25)
            return Balloon(pos: V3(x, terrain.height(x, z) + rng.range(6, 38), z), color: cols[i % cols.count])
        }
        score = 0; challengeTime = 0
    }

    func keyDown(_ k: UInt16) {
        switch k {
        case 49, 15: resetAircraft()
        case 35: paused.toggle()
        case 8:
            if site.panorama != nil { cameraMode = 0; say("Photo sites use the pilot camera only") }
            else { cameraMode = (cameraMode + 1) % 3; camSnap = true; say("Camera: " + Game.cameraNames[cameraMode]) }
        case 6: zoomMode = (zoomMode + 1) % 3; say("Zoom: " + Game.zoomNames[zoomMode])
        case 4: hud.overlay = hud.overlay == .help ? .none : .help
        case 9: hud.visible.toggle()
        case 17: timeScale = timeScale == 1 ? 0.5 : (timeScale == 0.5 ? 0.25 : 1); say(String(format: "Simulation speed %.0f%%", timeScale * 100))
        case 14:
            if aircraft.spec.hasFlaps { flapSetting = flapSetting >= 1 ? 0 : flapSetting + 0.5; say(["Flaps up", "Flaps half", "Flaps full"][Int(flapSetting * 2)]) }
            else { say("This aircraft has no flaps") }
        case 5:
            if aircraft.spec.hasRetracts { gearUp.toggle(); say(gearUp ? "Gear up" : "Gear down") } else { say("This aircraft has fixed gear") }
        case 16: smokeOn.toggle(); say(smokeOn ? "Smoke on" : "Smoke off")
        case 32:
            if aircraft.spec.kind == .helicopter { hold.toggle(); say(hold ? "Throttle hold — autorotate!" : "Engine engaged") }
        case 37: input.lowRates.toggle(); say(input.lowRates ? String(format: "Low rates (%.0f%%)", input.settings.lowRate * 100) : "High rates")
        case 46: sound.muted.toggle(); say(sound.muted ? "Sound off" : "Sound on")
        case 45: selectSite((siteIndex + 1) % SiteSpec.all.count)
        case 11: toggleChallenge()
        case 40: autopilotOn.toggle(); autopilot = Autopilot(); say(autopilotOn ? "Demo pilot flying" : "You have control")
        case 3:
            let n = aircraft.spec.modes.count
            if n > 1 { flightMode = (flightMode + 1) % n; say("Flight mode: " + aircraft.spec.modes[flightMode]) }
        case 43: env.windSpeed = max(0, env.windSpeed - 1); say(String(format: "Wind %.0f m/s", env.windSpeed))
        case 47: env.windSpeed = min(20, env.windSpeed + 1); say(String(format: "Wind %.0f m/s", env.windSpeed))
        case 18, 19, 20, 21, 23, 22, 26, 28, 25:
            selectAircraft([18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8][k]!)
        case 30: selectAircraft((aircraftIndex + 1) % AircraftLibrary.all.count)
        case 33: selectAircraft((aircraftIndex + AircraftLibrary.all.count - 1) % AircraftLibrary.all.count)
        default: break
        }
    }

    // MARK: Frame

    func frame(dt realDt: Float) {
        let dt = min(realDt, 0.05)
        frames += 1; fpsTime += realDt
        if fpsTime >= 0.5 { fps = Int(Float(frames) / fpsTime + 0.5); frames = 0; fpsTime = 0 }

        if autopilotOn && !aircraft.crashed {
            controls = autopilot.update(aircraft, terrain: terrain, dt: dt)
            _ = input.poll(dt: dt, kind: aircraft.spec.kind)
        } else {
            controls = input.poll(dt: dt, kind: aircraft.spec.kind)
            controls.mode = flightMode
        }
        controls.flaps = flapSetting; controls.gearUp = gearUp; controls.hold = hold

        if !paused && !hud.overlay.pausesSim {
            let h: Float = 0.001
            acc += dt * timeScale
            while acc >= h {
                env.time += h
                aircraft.step(dt: h, c: controls, terrain: terrain, wind: env.wind(at: aircraft.pos, terrain: terrain), rollMu: site.rollMu)
                acc -= h
            }
            let sdt = dt * timeScale
            if sdt > 0 { climb += ((aircraft.pos.y - lastY) / sdt - climb) * min(1, dt * 4); lastY = aircraft.pos.y }
            postStep(sdt)
        }
        let before = aircraft.renderPos
        aircraft.updateRenderPose(ahead: paused || hud.overlay.pausesSim || aircraft.crashed || Game.noInterp ? 0 : acc)
        // --perf: how much simulated time this frame's picture advanced by
        let sp = length(aircraft.vel)
        if sp > 3 { advanceMs.append(length(aircraft.renderPos - before) / sp * 1000) }
        updateCamera(dt)
        updateSound()
        messageTimer -= dt
        hudTimer -= dt
        if hudTimer <= 0 { hudTimer = 0.08; updateHUD() }
    }

    private func postStep(_ dt: Float) {
        let p = aircraft.pos
        if !p.x.isFinite || !p.y.isFinite || !p.z.isFinite || !terrain.contains(p) || p.y > 3000 {
            say("Out of range — aircraft reset"); resetAircraft(); return
        }
        if !aircraft.crashed {
            for t in terrain.trees {
                let dx = p.x - t.p.x, dz = p.z - t.p.z
                if abs(dx) < 6 && abs(dz) < 6 && dx * dx + dz * dz < pow(t.h * 0.3, 2) && p.y < t.p.y + t.h && p.y > t.p.y {
                    aircraft.crashed = true; aircraft.vel *= 0.25
                    break
                }
            }
        }
        if !aircraft.crashed {
            for o in site.obstacles {
                let c = Panoramas.position(o, north: site.north)
                let dx = p.x - c.x, dz = p.z - c.y
                if p.y < o.height && dx * dx + dz * dz < o.radius * o.radius {
                    aircraft.crashed = true; aircraft.crashImpact = length(aircraft.vel); aircraft.vel *= 0.2
                    break
                }
            }
        }
        if terrain.overWater(aircraft.pos) {
            // ditched: the model stops and floats
            if !aircraft.crashed { aircraft.crashed = true; aircraft.crashImpact = max(length(aircraft.vel) * 0.6, 4); say("Splash!") }
            aircraft.pos.y = max(aircraft.pos.y, (site.waterLevel ?? 0) - 0.06)
            aircraft.vel = V3(aircraft.vel.x * 0.92, max(aircraft.vel.y, 0), aircraft.vel.z * 0.92)
            aircraft.omega *= 0.9
        }
        if aircraft.crashed && !wasCrashed { breakUp() }
        wasCrashed = aircraft.crashed
        updateEffects(dt)
        if aircraft.crashed {
            crashTimer += dt
            if crashTimer > 3.5 { resetAircraft() }
        }
        if challenge {
            if score < balloons.count { challengeTime += dt }
            let r = 0.7 + aircraft.spec.span * 0.4
            for i in balloons.indices where balloons[i].alive {
                balloons[i].pos.y += sin(env.time * 1.3 + Float(i)) * 0.15 * dt
                if distance(balloons[i].pos, p) < r {
                    balloons[i].alive = false; score += 1
                    if score == balloons.count { say(String(format: "All balloons popped in %.1f s!  (B for a new round)", challengeTime), 6) }
                    else { say("Pop!  \(score)/\(balloons.count)", 1.2) }
                }
            }
        }
    }

    /// Called once when the aircraft crashes: parts break off, dust flies, and there is a thud.
    private func breakUp() {
        let ac = aircraft
        let sev = clampf(ac.crashImpact / 10, 0.25, 1)
        for (i, part) in ac.spec.parts.enumerated() where i > 0 {
            var animated = true
            if case .fixed = part.anim { animated = false }
            guard (animated || part.detach) && part.blur != 2 else { continue }
            if rng.next() > 0.3 + 0.7 * sev { continue }
            let origin = animated ? part.pivot : part.center
            let v = ac.vel * 0.6 + ac.q.act(cross(ac.omega, origin)) + V3(rng.range(-2.5, 2.5), rng.range(1, 4.5), rng.range(-2.5, 2.5)) * sev
            debris.append(Debris(part: i, pos: ac.pos + ac.q.act(origin), q: ac.q, vel: v,
                                 omega: V3(rng.range(-9, 9), rng.range(-9, 9), rng.range(-9, 9)), offset: animated ? .zero : -part.center))
            ac.detached.insert(i)
        }
        let ground = V3(ac.pos.x, max(terrain.height(ac.pos.x, ac.pos.z), site.waterLevel ?? -1e9) + 0.1, ac.pos.z)
        let wet = site.waterLevel.map { terrain.height(ac.pos.x, ac.pos.z) < $0 } ?? false
        sound.crash(sev, water: wet, pan: sound.state.pan)
        let dust: V4 = wet ? rgb(0.9, 0.95, 1.0) : site.pal.dust
        for _ in 0..<Int(10 + 22 * sev) {
            particles.append(Particle(pos: ground + V3(rng.range(-0.3, 0.3), 0, rng.range(-0.3, 0.3)),
                                      vel: V3(rng.range(-2.5, 2.5), rng.range(0.5, 3), rng.range(-2.5, 2.5)) * sev + ac.vel * 0.15,
                                      age: 0, life: rng.range(1.2, 2.4), size: rng.range(0.1, 0.22), color: V4(dust.x, dust.y, dust.z, 0.32)))
        }
    }

    private func updateEffects(_ dt: Float) {
        // tumbling wreckage
        for i in debris.indices {
            var d = debris[i]
            d.vel.y -= gravity * dt
            d.vel *= 1 - min(0.6 * dt, 1)
            d.pos += d.vel * dt
            let g = max(terrain.height(d.pos.x, d.pos.z), site.waterLevel ?? -1e9) + 0.03
            if d.pos.y < g {
                d.pos.y = g
                d.vel = V3(d.vel.x * 0.55, abs(d.vel.y) * 0.3, d.vel.z * 0.55)
                d.omega *= 0.5
                if length(d.vel) < 0.4 { d.vel = .zero; d.omega = .zero }
            }
            let w = length(d.omega)
            if w > 0.01 { d.q = simd_normalize(d.q * simd_quatf(angle: w * dt, axis: d.omega / w)) }
            debris[i] = d
        }
        // smoke trail
        if smokeOn && !aircraft.crashed && aircraft.power > 0.08 {
            smokeAcc += dt * 70
            let wind = env.windVec
            while smokeAcc >= 1 {
                smokeAcc -= 1
                let p = aircraft.pos + aircraft.q.act(aircraft.spec.smokePos) - aircraft.vel * (rng.next() * dt)
                particles.append(Particle(pos: p, vel: wind * 0.8 + aircraft.vel * 0.08 + V3(rng.range(-0.4, 0.4), rng.range(-0.2, 0.5), rng.range(-0.4, 0.4)),
                                          age: 0, life: rng.range(3.5, 5), size: rng.range(0.12, 0.2), color: V4(0.96, 0.96, 0.97, 0.5)))
            }
        }
        for i in particles.indices {
            particles[i].age += dt
            particles[i].vel *= 1 - min(0.8 * dt, 1)
            particles[i].pos += particles[i].vel * dt
        }
        particles.removeAll { $0.age >= $0.life }
        if particles.count > 900 { particles.removeFirst(particles.count - 900) }
    }

    private func updateCamera(_ dt: Float) {
        let p = aircraft.renderPos, spec = aircraft.spec
        let rq = aircraft.renderQ
        switch cameraMode {
        case 0:
            eye = terrain.pilotPos + V3(0, site.panorama != nil ? site.eyeHeight : 1.7, 0)
            if camSnap { camTarget = p }
            camTarget += (p - camTarget) * min(1, dt * 14)
            let d = max(distance(eye, p), 1)
            let auto = 2 * atan(spec.span * 7 / (2 * d))
            var want: Float
            switch zoomMode {
            case 0: want = clampf(auto, 4 * deg, 55 * deg)
            case 1:
                let el = asin(clampf((p.y - eye.y) / d, -1, 1))
                want = clampf(max(auto, 2 * (el + 3 * deg) * 1.08), 4 * deg, 105 * deg)
            default: want = 50 * deg
            }
            fov = camSnap ? want : fov + (want - fov) * min(1, dt * 3.5)
            target = camTarget; upVec = V3(0, 1, 0)
        case 1:
            var back = rq.act(V3(0, 0, 1)); back.y = 0
            back = length(back) > 0.05 ? normalize(back) : V3(0, 0, 1)
            var want = p + back * (spec.span * 2.2 + 1.5) + V3(0, spec.span * 0.5 + 0.4, 0)
            want.y = max(want.y, terrain.height(want.x, want.z) + 0.4)
            eye = camSnap ? want : eye + (want - eye) * min(1, dt * 5)
            target = p; upVec = V3(0, 1, 0); fov = 60 * deg
        default:
            eye = p + rq.act(spec.eyeOffset)
            target = eye + rq.act(V3(0, 0, -1)); upVec = rq.act(V3(0, 1, 0)); fov = 85 * deg
        }
        if let c = closeup {
            eye = p + c * max(spec.span, 0.6); target = p; upVec = V3(0, 1, 0); fov = 32 * deg
        }
        if let v = fixedView {
            let g = terrain.pilotPos.y
            eye = v.eye + V3(0, g, 0); target = v.target + V3(0, g, 0); upVec = V3(0, 1, 0); fov = 58 * deg
        }
        camSnap = false
    }

    private func updateSound() {
        let spec = aircraft.spec
        let rel = aircraft.pos - eye
        let d = max(length(rel), 0.5)
        let onboard = cameraMode == 2
        var st = SoundState()
        st.doppler = cameraMode == 0 ? 343 / (343 + dot(aircraft.vel, rel / d)) : 1
        let lv = aircraft.power
        switch spec.kind {
        case .helicopter:
            st.engine = 4
            st.shaftHz = spec.soundBase / 2 * aircraft.levels[0]
            st.power = clampf(abs(2 * controls.throttle - 1) * 0.8 + 0.15, 0, 1)
            st.running = aircraft.levels[0] > 0.05 ? min(aircraft.levels[0], 1) : 0
        case .multirotor:
            st.engine = 5
            st.shaftHz = spec.soundBase
            st.power = lv; st.running = lv > 0.01 ? 1 : 0
            st.motors = SIMD4(aircraft.levels[0], aircraft.levels[1], aircraft.levels[2], aircraft.levels[3])
        case .airplane:
            st.engine = spec.engineSound
            st.blades = Float(spec.blades); st.cylinders = Float(spec.cylinders); st.radial = spec.radial
            // piston and turbine engines idle; electric motors stop
            let idles = spec.engineSound != 0 && !aircraft.crashed
            let rpm = idles ? max(lv, 0.24) : lv
            st.shaftHz = spec.soundBase / Float(max(spec.blades, 1)) * (0.25 + 0.75 * rpm)
            st.power = lv
            st.running = idles ? 1 : (lv > 0.01 ? 1 : 0)
        }
        st.shaftHz *= st.doppler
        // distance: inverse-distance loudness, and the air soaks up the highs
        let size = max(spec.span, 0.6)
        st.gain = onboard ? 0.8 : min(1, (3 + 2.5 * size) / (d + 2))
        st.muffle = onboard ? 0 : clampf(d / 320, 0, 1)
        var fwd = target - eye; fwd.y = 0
        if length(fwd) > 0.001 && !onboard {
            fwd = normalize(fwd)
            let right = V3(-fwd.z, 0, fwd.x)
            st.pan = clampf(dot(rel / d, right) * 1.6, -1, 1)
        }
        st.airspeed = aircraft.airspeed
        st.groundRoll = aircraft.onGround && !aircraft.crashed ? length(V3(aircraft.vel.x, 0, aircraft.vel.z)) : 0
        st.windSpeed = env.windSpeed
        st.ambience = site.waterLevel != nil ? 1 : (site.pal.flowers ? 0 : (site.palette == 4 ? 3 : 2))
        if site.panorama != nil { st.ambience = site.category == "Winter" || site.category == "Desert" ? 2 : 0 }
        st.paused = paused || hud.overlay.pausesSim
        sound.state = st
    }

    private func updateHUD() {
        var s = HUDState()
        let spec = aircraft.spec
        s.aircraft = spec.name; s.site = site.name; s.blurb = spec.blurb
        s.alt = aircraft.pos.y - terrain.height(aircraft.pos.x, aircraft.pos.z) - aircraft.restHeight
        s.speed = aircraft.airspeed
        s.dist = distance(aircraft.pos, terrain.pilotPos)
        s.climb = climb
        s.throttle = controls.throttle
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        s.wind = env.windSpeed < 0.1 ? "Calm" : String(format: "%@ %.0f m/s", dirs[Int((env.windFrom + 22.5) / 45) % 8], env.windSpeed)
        s.camera = Game.cameraNames[cameraMode] + (cameraMode == 0 ? " · " + Game.zoomNames[zoomMode] : "")
        s.mode = spec.modes.count > 1 ? spec.modes[flightMode] : ""
        s.input = autopilotOn ? "Demo pilot" : input.source
        s.time = Game.timeNames[timeOfDay] + (timeScale < 1 ? String(format: " · %.0f%% speed", timeScale * 100) : "")
        if challenge { s.score = String(format: "Balloons %d/%d   %.1f s", score, balloons.count, challengeTime) }
        if aircraft.crashed { s.message = "CRASHED" }
        else if paused { s.message = "PAUSED" }
        else if messageTimer > 0 { s.message = message }
        let tY = controls.throttle * 2 - 1, eY = -controls.elevator
        switch input.settings.stickMode {
        case 1: s.lx = controls.rudder; s.ly = eY; s.rx = controls.aileron; s.ry = tY; s.leftLabel = "ELE / RUD"; s.rightLabel = "THR / AIL"
        case 3: s.lx = controls.aileron; s.ly = eY; s.rx = controls.rudder; s.ry = tY; s.leftLabel = "ELE / AIL"; s.rightLabel = "THR / RUD"
        case 4: s.lx = controls.aileron; s.ly = tY; s.rx = controls.rudder; s.ry = eY; s.leftLabel = "THR / AIL"; s.rightLabel = "ELE / RUD"
        default: s.lx = controls.rudder; s.ly = tY; s.rx = controls.aileron; s.ry = eY
        }
        s.rates = input.lowRates ? "Low" : "High"
        var cfg: [String] = []
        if spec.hasFlaps { cfg.append(["Flaps up", "Flaps ½", "Flaps full"][Int(flapSetting * 2)]) }
        if spec.hasRetracts { cfg.append(gearUp ? "Gear up" : "Gear down") }
        if spec.kind == .helicopter { cfg.append(String(format: "Rotor %.0f%%%@", aircraft.levels[0] * 100, hold ? " HOLD" : "")) }
        if smokeOn { cfg.append("Smoke") }
        s.config = cfg.joined(separator: " · ")
        s.fps = fps
        hud.s = s
    }
}

