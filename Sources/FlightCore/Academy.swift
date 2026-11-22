import simd
import Foundation

// The Flight Academy: what a step is, how an attempt is judged, and what has been passed.
// The steps themselves are in AcademyCourse.swift; Game runs them and AcademyUI.swift shows them.

enum AcademyRules {
    static let passMark = 80
    static let stepsPerChapter = 5
    /// A chapter is complete when 80% of its steps are passed, rounded up.
    static let stepsToComplete = (stepsPerChapter * passMark + 99) / 100
    static let precisionPoints: Float = 80, timePoints: Float = 20
    static let countdown: Float = 3
}

enum Track: Int, CaseIterable {
    case planes, helicopters, multirotors
    var title: String { ["Planes", "Helicopters", "Multirotors"][rawValue] }
    var icon: String { ["airplane", "fanblades.fill", "circle.grid.cross.fill"][rawValue] }
}

enum Level: Int, CaseIterable {
    case beginner, advanced, professional
    var title: String { ["Beginner", "Advanced", "Professional"][rawValue] }
}

/// A box in the air or on the ground. `center.y` is the height above the ground beneath it. The box is turned so
/// that its depth lies along `dir`, the direction it is flown in.
struct TargetBox {
    var center: V3
    var size: V3                    // across, height, along
    var dir = V3(1, 0, 0)

    var across: V3 { normalize(cross(dir, V3(0, 1, 0))) }
    func world(_ t: Terrain) -> V3 { center + V3(0, t.height(center.x, center.z), 0) }
    func local(_ p: V3, _ t: Terrain) -> V3 {
        let d = p - world(t)
        return V3(dot(d, across), d.y, dot(d, dir))
    }
    func contains(_ p: V3, _ t: Terrain) -> Bool {
        let l = simd_abs(local(p, t)), h = size / 2
        return l.x <= h.x && l.y <= h.y && l.z <= h.z
    }
}

/// An attitude a step asks for, with how far off it may be.
enum Pose {
    case any
    case upright(Float)             // degrees
    case inverted(Float)
    case knifeEdge(Float)
    case noseUp(Float)
    case heading(V3, Float)         // upright, nose this way
    case invertedHeading(V3, Float)
    case facing(V3, Float)          // upright, nose toward this point

    /// 1 right on, 0.6 at the limit, nil outside it.
    func match(_ ac: Aircraft) -> Float? {
        func within(_ cosine: Float, _ limit: Float) -> Float? {
            let off = acos(clampf(cosine, -1, 1)) / deg
            return off > limit ? nil : 1 - 0.4 * smoothstep(0.4, 1, off / limit)
        }
        func yaw(_ d: V3, _ limit: Float, side: Float) -> Float? {
            guard ac.up.y * side > 0.5 else { return nil }
            let f = ac.forward, h = V3(f.x, 0, f.z), w = V3(d.x, 0, d.z)
            guard length(h) > 0.1, length(w) > 0.1 else { return nil }
            return within(dot(normalize(h), normalize(w)), limit)
        }
        switch self {
        case .any: return 1
        case .upright(let t): return within(ac.up.y, t)
        case .inverted(let t): return within(-ac.up.y, t)
        case .knifeEdge(let t): return within(abs(ac.right.y), t)
        case .noseUp(let t): return within(ac.forward.y, t)
        case .heading(let d, let t): return yaw(d, t, side: 1)
        case .invertedHeading(let d, let t): return yaw(d, t, side: -1)
        case .facing(let p, let t): return yaw(p - ac.pos, t, side: 1)
        }
    }

    var words: String {
        func way(_ d: V3) -> String {
            if abs(d.x) > abs(d.z) { return d.x > 0 ? "pointing right" : "pointing left" }
            return d.z < 0 ? "pointing away from you" : "pointing at you"
        }
        switch self {
        case .any: return ""
        case .upright: return "right side up"
        case .inverted: return "upside down"
        case .knifeEdge: return "wings vertical"
        case .noseUp: return "nose straight up"
        case .heading(let d, _): return "nose " + way(d)
        case .invertedHeading(let d, _): return "upside down, nose " + way(d)
        case .facing: return "nose toward the centre"
        }
    }
}

enum Spin { case roll, flip, yaw }

/// One thing to do within a step. A step's tasks are done in their order.
struct AcademyTask {
    enum Kind {
        /// Fly through the box in its direction. `via` is an attitude that must have been flown since the task before.
        case pass(via: Pose?)
        /// Gather this many seconds inside the box in the attitude.
        case hold(seconds: Float)
        /// Turn this far inside the box. Slower than `slowest` seconds earns the full marks.
        case rotate(Spin, degrees: Float, slowest: Float)
        /// Stall inside the box and recover.
        case stall
        /// Touch down in the box and come to rest there.
        case land
    }
    var text: String
    var kind: Kind
    var box: TargetBox
    var pose: Pose = .any

    /// What is measured, in words, for the briefing.
    var measure: String {
        let size = String(format: "%.0f × %.0f", box.size.x, box.size.y)
        let posed = pose.words.isEmpty ? "" : ", " + pose.words
        switch kind {
        case .pass: return "through a \(size) m box\(posed)"
        case .hold(let s): return String(format: "%.0f s in a %.0f × %.0f × %.0f m box", s, box.size.x, box.size.y, box.size.z) + posed
        case .rotate(_, let d, let t): return String(format: "%.0f° inside the box", d) + (t > 0 ? String(format: ", taking %.0f s or more", t) : "") + posed
        case .stall: return "stall and recover inside the box, losing little height"
        case .land: return String(format: "come to rest on the %.0f × %.0f m pad, gently and near its centre", box.size.z, box.size.x)
        }
    }
}

enum StepView {
    case pilot, fpv
    var cameraMode: Int { self == .pilot ? 0 : 2 }
    var title: String { self == .pilot ? "Pilot (line of sight)" : "FPV (onboard)" }
}

struct StepStart {
    var pos: V3                     // y: height above the ground, 0 = standing on it
    var dir = V3(1, 0, 0)
    var speed: Float = 0
    var vertical = false            // hanging on the propeller, nose up
    /// Where the throttle stick has to be before the countdown runs.
    var throttle: ClosedRange<Float>
    var airborne: Bool { pos.y > 0 }
}

struct StepWeather {
    var wind: Float = 0
    var from: Float = 90
    var turbulence: Float = 0.03
    var gusts: Float = 0
}

/// A failure imposed for the step.
enum StepFailure { case none, engineCut, throttleHold }

struct AcademyStep {
    var id: String                  // saved with the progress: never change one
    var track: Track
    var level: Level
    var title: String
    var goal: String
    var how: [String]
    var aircraft: String
    var site: String
    var view: StepView = .pilot
    var gyro: Int
    /// Figures in acro need the whole stick: these steps start on high rates.
    var highRates = false
    var weather = StepWeather()
    var start: StepStart
    var failure = StepFailure.none
    var par: Float                  // seconds that earn the whole time score
    var limit: Float
    var tasks: [AcademyTask]
}

struct StepResult: Equatable {
    var passed: Bool
    var score: Int
    var precision: Int              // percent
    var timeScore: Int              // percent
    var time: Float
    var capped: Bool
    var helped: Bool
    var reason: String              // empty when every task was done
}

/// One try at a step, from "go" to a result. It only watches the aircraft; it never moves it.
final class AcademyAttempt {
    enum Phase: Equatable { case waiting, flying, finished }

    let step: AcademyStep
    private(set) var phase = Phase.waiting
    private(set) var countdown = AcademyRules.countdown
    private(set) var throttleReady = false
    private(set) var time: Float = 0
    private(set) var index = 0
    private(set) var qualities: [Float] = []
    private(set) var mostHelp: Int
    private(set) var result: StepResult?
    private(set) var note = ""

    // state of the task being flown
    private var last: V3?
    private var lastSink: Float = 0
    private var viaSeen = false
    private var held: Float = 0, heldQuality: Float = 0, sinceEntry: Float = 0, entered = false
    private var turned: Float = 0, turnTime: Float = 0, halfway = false, turnFrom = V3.zero, turnDir = V3.zero
    private var stalled = false, stallHeight: Float = 0
    private var wasAirborne = false, touch: (pos: V3, sink: Float)?, restTime: Float = 0

    init(_ step: AcademyStep) { self.step = step; mostHelp = step.gyro }

    var task: AcademyTask? { index < step.tasks.count ? step.tasks[index] : nil }
    var timeLeft: Float { max(step.limit - time, 0) }

    /// Before "go". The countdown only runs while the throttle is where the step starts.
    func wait(dt: Float, throttle: Float) {
        guard phase == .waiting else { return }
        throttleReady = step.start.throttle.contains(throttle)
        countdown = throttleReady ? countdown - dt : AcademyRules.countdown
        if countdown <= 0 { phase = .flying }
    }

    private var timeShare: Float { clampf(1 - (time - step.par) / max(step.limit - step.par, 0.1), 0, 1) }

    /// How much of the precision has been earned so far, over all tasks, 0 to 1.
    private var precision: Float { qualities.reduce(0, +) / Float(step.tasks.count) }

    func update(_ ac: Aircraft, terrain: Terrain, dt: Float, gyro: Int) {
        guard phase == .flying else { return }
        time += dt
        mostHelp = max(mostHelp, gyro)
        if ac.crashed { fail("The aircraft crashed."); return }
        guard let t = task else { return }
        let p = ac.pos, before = last ?? p
        let agl = p.y - terrain.height(p.x, p.z) - ac.restHeight
        var done: Float?
        switch t.kind {
        case .pass(let via): done = passed(t, via: via, ac, terrain, from: before)
        case .hold(let seconds): done = holding(t, seconds: seconds, ac, terrain, dt: dt)
        case .rotate(let axis, let degrees, let slowest): done = rotating(t, axis, degrees: degrees, slowest: slowest, ac, terrain, dt: dt)
        case .stall: done = stalling(t, ac, terrain)
        case .land: done = landing(t, ac, terrain, agl: agl, dt: dt)
        }
        if phase == .finished { return }
        last = p
        lastSink = max(-ac.vel.y, 0)
        if let q = done {
            qualities.append(q); index += 1
            clearTask()
            if index == step.tasks.count { finish(); return }
        }
        if time >= step.limit { fail("Time is up.") }
    }

    private func clearTask() {
        viaSeen = false; held = 0; heldQuality = 0; sinceEntry = 0; entered = false
        turned = 0; turnTime = 0; halfway = false; stalled = false
        wasAirborne = false; touch = nil; restTime = 0; note = ""
    }

    /// 1 in the middle of the box, 0.6 at its sides.
    private func centred(_ l: V3, _ box: TargetBox, along: Bool) -> Float {
        let h = box.size / 2
        let off = max(abs(l.x) / h.x, abs(l.y) / h.y, along ? abs(l.z) / h.z : 0)
        return 1 - 0.4 * smoothstep(0.35, 1, off)
    }

    private func passed(_ t: AcademyTask, via: Pose?, _ ac: Aircraft, _ ter: Terrain, from: V3) -> Float? {
        if let v = via, v.match(ac) != nil { viaSeen = true }
        let a = t.box.local(from, ter), b = t.box.local(ac.pos, ter)
        guard a.z < 0, b.z >= 0 else { return nil }
        let at = a + (b - a) * (-a.z / max(b.z - a.z, 1e-5)), h = t.box.size / 2
        guard abs(at.x) <= h.x, abs(at.y) <= h.y else {
            if abs(at.x) < 8 * h.x && abs(at.y) < 8 * h.y { note = "Missed the box: come round again." }
            return nil
        }
        if let v = via, !viaSeen { note = "Be \(v.words) before this box."; return nil }
        guard let posed = t.pose.match(ac) else { note = "Go through \(t.pose.words)."; return nil }
        return centred(at, t.box, along: false) * 0.6 + posed * 0.4
    }

    private func holding(_ t: AcademyTask, seconds: Float, _ ac: Aircraft, _ ter: Terrain, dt: Float) -> Float? {
        let posed = t.pose.match(ac), inside = t.box.contains(ac.pos, ter) && !ac.onGround
        if entered { sinceEntry += dt }
        if inside, let q = posed {
            entered = true; note = ""
            held += dt
            heldQuality += (centred(t.box.local(ac.pos, ter), t.box, along: true) * 0.6 + q * 0.4) * dt
            if held >= seconds {
                // drifting out and coming back costs marks
                let unbroken = min(seconds / max(sinceEntry + dt, seconds), 1)
                return heldQuality / held * (0.4 + 0.6 * unbroken)
            }
        } else if inside {
            note = "Hold it \(t.pose.words)."
        } else if entered {
            note = "Back into the box."
        }
        return nil
    }

    private func rotating(_ t: AcademyTask, _ axis: Spin, degrees: Float, slowest: Float, _ ac: Aircraft, _ ter: Terrain, dt: Float) -> Float? {
        let inside = t.box.contains(ac.pos, ter) && !ac.onGround
        // a turn about the vertical axis or a torque roll is made in the attitude asked for, all the way round
        var posedThroughout = false
        if case .noseUp = t.pose { posedThroughout = true }
        if case .yaw = axis { posedThroughout = true }
        guard inside, !posedThroughout || t.pose.match(ac) != nil else {
            if abs(turned) > 45 { note = inside ? "Stay \(t.pose.words): start again." : "Left the box: start again." }
            turned = 0; turnTime = 0; halfway = false
            return nil
        }
        let rate: Float
        switch axis {
        case .roll: rate = -ac.omega.z
        case .flip: rate = ac.omega.x
        case .yaw: rate = -ac.q.act(ac.omega).y
        }
        turned += rate * dt / deg
        if !posedThroughout {
            if ac.up.y < -0.5 { halfway = true }
            // the rotation of an ordinary turn is not the beginning of a figure
            if !halfway && abs(rate) < 0.35 { turned *= max(1 - dt * 2, 0) }
        }
        if abs(turned) < 15 {
            if ac.up.y > 0 { halfway = false }      // back where it began: the figure starts over
            turnFrom = ac.pos; turnTime = 0; turnDir = ac.forward
        } else {
            turnTime += dt
        }
        guard abs(turned) >= degrees - 20, posedThroughout || (halfway && ac.up.y > 0.8) else { return nil }
        let end = simd_abs(ac.pos - turnFrom), h = t.box.size
        var q: Float
        if posedThroughout {
            q = 1 - 0.4 * smoothstep(0.2, 0.7, max(end.x / h.x, end.y / h.y, end.z / h.z))
        } else {
            let height = 1 - 0.4 * smoothstep(0.15, 0.6, end.y / h.y)
            let a = V3(turnDir.x, 0, turnDir.z), b = V3(ac.forward.x, 0, ac.forward.z)
            let straight: Float = length(a) > 0.3 && length(b) > 0.3 ? 1 - 0.4 * smoothstep(15, 60, acos(clampf(dot(normalize(a), normalize(b)), -1, 1)) / deg) : 1
            q = height * 0.6 + straight * 0.4
        }
        if slowest > 0 { q *= min(turnTime / slowest, 1) }
        return q
    }

    private func stalling(_ t: AcademyTask, _ ac: Aircraft, _ ter: Terrain) -> Float? {
        if !stalled {
            if t.box.contains(ac.pos, ter) && !ac.onGround && ac.wingStall > 0.5 { stalled = true; stallHeight = ac.pos.y; note = "Stalled: now recover." }
            return nil
        }
        guard ac.wingStall < 0.15, ac.airspeed > ac.spec.stallSpeed * 1.2, ac.vel.y > -0.6, ac.up.y > 0.85 else { return nil }
        guard t.box.contains(ac.pos, ter) else { fail("The recovery ended outside the box."); return nil }
        return 1 - 0.5 * smoothstep(7, 22, stallHeight - ac.pos.y)
    }

    private func landing(_ t: AcademyTask, _ ac: Aircraft, _ ter: Terrain, agl: Float, dt: Float) -> Float? {
        if agl > 0.25 { wasAirborne = true }
        guard wasAirborne else { return nil }
        if ac.onGround && touch == nil { touch = (ac.pos, lastSink) }
        let plane = ac.spec.kind == .airplane
        // a machine that can lift off again may have another go at the pad
        if !plane && agl > 0.5 { touch = nil }
        restTime = ac.onGround && length(ac.vel) < (plane ? 0.8 : 0.35) ? restTime + dt : 0
        guard restTime > 0.7, let td = touch else { return nil }
        let h = t.box.size / 2, here = simd_abs(t.box.local(ac.pos, ter)), first = simd_abs(t.box.local(td.pos, ter))
        guard here.x <= h.x, here.z <= h.z else {
            if plane { fail("It came to rest off the pad.") } else { note = "Off the pad: lift off and land on it." }
            return nil
        }
        guard ac.up.y > 0.8 else { fail("It did not land on its gear."); return nil }
        // a plane is marked where it touches down, anything else where it rests
        let at = plane ? first : here
        let off = max(at.x / h.x, at.z / h.z)
        let centre = off > 1 ? 0.4 : 1 - 0.4 * smoothstep(0.4, 1, off)
        let soft = plane ? 1 - 0.6 * smoothstep(1.4, 3.2, td.sink) : 1 - 0.6 * smoothstep(0.9, 2.4, td.sink)
        return centre * 0.55 + soft * 0.45
    }

    private func finish() {
        phase = .finished
        let t = timeShare
        // half a point of rounding in the arithmetic must not fail a perfect attempt
        var score = Int(precision * AcademyRules.precisionPoints + t * AcademyRules.timePoints + 0.001)
        let helped = mostHelp > step.gyro
        let capped = helped && score > AcademyRules.passMark
        if capped { score = AcademyRules.passMark }
        score = min(score, 100)
        result = StepResult(passed: score >= AcademyRules.passMark, score: score, precision: Int(precision * 100 + 0.001),
                            timeScore: Int(t * 100 + 0.001), time: time, capped: capped, helped: helped, reason: "")
    }

    /// An attempt that did not finish every task shows what it earned, and never passes.
    func fail(_ reason: String) {
        guard phase != .finished else { return }
        phase = .finished
        let score = min(Int(precision * AcademyRules.precisionPoints), AcademyRules.passMark - 1)
        result = StepResult(passed: false, score: score, precision: Int(precision * 100), timeScore: 0,
                            time: time, capped: false, helped: mostHelp > step.gyro, reason: reason)
    }

    /// What has been done of the current task, for the display.
    var progress: String {
        guard let t = task, phase == .flying else { return "" }
        switch t.kind {
        case .pass: return ""
        case .hold(let s): return String(format: "In the box %.1f / %.0f s", held, s)
        case .rotate(_, let d, _): return String(format: "Turned %.0f° / %.0f°", min(abs(turned), d), d)
        case .stall: return stalled ? "Stalled: recover" : "Not stalled yet"
        case .land: return touch == nil ? "Not down yet" : "Come to a stop on the pad"
        }
    }
}

/// What has been achieved. The best score of a step is kept, so doing one again can never lose a pass.
struct AcademyProgress {
    struct Record: Codable, Equatable {
        var best = 0
        var attempts = 0
        var bestTime: Float? = nil      // quickest pass
        var helped = false              // the best score was flown with more gyro help than suggested
        var passed: Bool { best >= AcademyRules.passMark }
    }
    static let key = "academyProgress"
    private let store: UserDefaults?
    private(set) var records: [String: Record] = [:]

    /// With no store, nothing is read or saved (tests).
    init(store: UserDefaults?) {
        self.store = store
        if let d = store?.data(forKey: AcademyProgress.key), let r = try? JSONDecoder().decode([String: Record].self, from: d) { records = r }
    }

    mutating func record(_ r: StepResult, for step: AcademyStep) {
        var rec = records[step.id] ?? Record()
        rec.attempts += 1
        if r.score > rec.best || (r.score == rec.best && rec.helped && !r.helped) { rec.best = r.score; rec.helped = r.helped }
        if r.passed { rec.bestTime = min(rec.bestTime ?? r.time, r.time) }
        records[step.id] = rec
        if let d = try? JSONEncoder().encode(records) { store?.set(d, forKey: AcademyProgress.key) }
    }

    func passed(_ track: Track, _ level: Level) -> Int {
        AcademyCourse.steps(track, level).filter { records[$0.id]?.passed == true }.count
    }
    func complete(_ track: Track, _ level: Level) -> Bool { passed(track, level) >= AcademyRules.stepsToComplete }
    /// Beginner is open, and each level opens the one after it.
    func open(_ track: Track, _ level: Level) -> Bool {
        guard let before = Level(rawValue: level.rawValue - 1) else { return true }
        return open(track, before) && complete(track, before)
    }
}
