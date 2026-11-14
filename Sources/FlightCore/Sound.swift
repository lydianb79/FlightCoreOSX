import Foundation
import AVFoundation

/// What the game tells the synthesizer each frame. Plain values, written on the main thread and read by the audio thread.
struct SoundState {
    var engine = 0              // 0 electric, 1 piston, 2 ducted fan / jet, 3 turboprop, 4 helicopter, 5 multirotor
    var shaftHz: Float = 0      // propeller or rotor revolutions per second, Doppler-shifted
    var blades: Float = 2
    var cylinders: Float = 4
    var radial = false
    var power: Float = 0        // 0...1 how hard the motor is working
    var running: Float = 0      // 0 stopped ... 1 running (engines idle, electric motors stop)
    var motors = SIMD4<Float>(0, 0, 0, 0)   // multirotor: per-motor speed 0...1
    var doppler: Float = 1
    var gain: Float = 0         // distance attenuation 0...1
    var muffle: Float = 0       // 0 close ... 1 far: high frequencies are absorbed by the air
    var pan: Float = 0          // -1 left ... 1 right
    var airspeed: Float = 0
    var groundRoll: Float = 0   // rolling speed while on the ground, m/s
    var windSpeed: Float = 0    // ambient wind at the pilot, m/s
    var ambience = 0            // 0 countryside (birds), 1 water (waves), 2 open / desert, 3 winter
    var paused = false
}

/// Procedural stereo sound: engine, propeller, rotor, airframe, ground roll, crashes and ambience.
final class SoundEngine {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    var state = SoundState()
    var muted = false
    let sampleRate: Float = 44100

    // smoothed parameters
    private var sHz: Float = 0, sPower: Float = 0, sRun: Float = 0, sGain: Float = 0, sMuffle: Float = 0, sPan: Float = 0
    private var sAir: Float = 0, sRoll: Float = 0, sWind: Float = 0, sMaster: Float = 0
    private var sMotor = SIMD4<Float>(0, 0, 0, 0)
    // oscillators
    private var pBlade: Float = 0, pShaft: Float = 0, pFire: Float = 0, pWhine: Float = 0, pTail: Float = 0
    private var pMotor = SIMD4<Float>(0, 0.31, 0.57, 0.83)
    private var seed: UInt32 = 0x1234567
    // filters (state-variable: low, band)
    private var propLo: Float = 0, propBd: Float = 0
    private var jetLo: Float = 0, jetBd: Float = 0
    private var airLo: Float = 0, airBd: Float = 0
    private var windLoL: Float = 0, windBdL: Float = 0, windLoR: Float = 0, windBdR: Float = 0
    private var exhaust: Float = 0, rumble: Float = 0, roar: Float = 0, muffL: Float = 0, muffR: Float = 0, wave: Float = 0
    private var lfo1: Float = 0, lfo2: Float = 0.4, lfo3: Float = 0.7
    // one-shots
    private var crashEnv: Float = 0, crashTone: Float = 0, crashPhase: Float = 0, crackle: Float = 0, splashEnv: Float = 0, splashLo: Float = 0
    private var crashPan: Float = 0
    // birds
    private var birdT: Float = 2, birdEnv: Float = 0, birdPhase: Float = 0, birdF0: Float = 3000, birdF1: Float = 4000, birdDur: Float = 0.1, birdAge: Float = 1
    private var birdRepeat = 0, birdGap: Float = 0, birdPan: Float = 0, birdVol: Float = 0

    init(start: Bool = true) {
        guard start, let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2) else { return }
        let n = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard bufs.count >= 2, let l = bufs[0].mData, let r = bufs[1].mData else { return noErr }
            self.render(left: l.assumingMemoryBound(to: Float.self), right: r.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            return noErr
        }
        node = n
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
    }

    /// Impact: `strength` 0...1; `water` makes it a splash.
    func crash(_ strength: Float, water: Bool = false, pan: Float = 0) {
        let s = 0.35 + 0.65 * min(max(strength, 0), 1)
        crashPan = pan
        if water { splashEnv = max(splashEnv, s) } else { crashEnv = max(crashEnv, s); crashTone = s; crackle = s }
    }

    @inline(__always) private func noise() -> Float {
        seed = seed &* 1664525 &+ 1013904223
        return Float(Int32(bitPattern: seed)) * (1.0 / 2147483648.0)
    }
    @inline(__always) private func wrap(_ p: inout Float, _ hz: Float) {
        p += hz / sampleRate
        if p >= 1 { p -= floor(p) }
    }
    /// State-variable band-pass; returns the band output.
    @inline(__always) private func bandpass(_ x: Float, _ fc: Float, _ q: Float, _ lo: inout Float, _ bd: inout Float) -> Float {
        let f = 2 * sin(Float.pi * min(fc, 7000) / sampleRate)
        lo += f * bd
        let hi = x - lo - q * bd
        bd += f * hi
        return bd
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        let st = state
        let twoPi = 2 * Float.pi
        let k: Float = 0.0012                      // parameter smoothing per sample (~20 ms)
        let masterTarget: Float = (muted || st.paused) ? 0 : 1
        let dt = 1 / sampleRate
        for i in 0..<count {
            sHz += (st.shaftHz - sHz) * k; sPower += (st.power - sPower) * k; sRun += (st.running - sRun) * k * 0.5
            sGain += (st.gain - sGain) * k; sMuffle += (st.muffle - sMuffle) * k; sPan += (st.pan - sPan) * k
            sAir += (st.airspeed - sAir) * k; sRoll += (st.groundRoll - sRoll) * k; sWind += (st.windSpeed - sWind) * k * 0.2
            sMotor += (st.motors - sMotor) * k
            sMaster += (masterTarget - sMaster) * k
            let n0 = noise(), n1 = noise()
            let hz = max(sHz, 0.5)
            var eng: Float = 0

            switch st.engine {
            case 0:     // electric motor and propeller
                wrap(&pBlade, hz * st.blades); wrap(&pWhine, hz * 7)
                let b = twoPi * pBlade
                var prop = sin(b) + 0.5 * sin(2 * b + 0.4) + 0.3 * sin(3 * b + 1.1) + 0.16 * sin(4 * b) + 0.09 * sin(5 * b)
                prop *= 0.22 * (0.35 + 0.65 * sPower) * (1 + 0.12 * n0)
                let whine = (sin(twoPi * pWhine) + 0.4 * sin(2 * twoPi * pWhine)) * 0.035 * (0.4 + 0.6 * sPower)
                let wash = bandpass(n0, 500 + 2600 * sPower, 0.9, &propLo, &propBd) * 0.3 * sPower * sPower
                eng = (prop + whine + wash) * sRun
            case 1:     // piston engine: exhaust pulses, mechanical rumble, propeller
                let fire = hz * st.cylinders * 0.5
                wrap(&pFire, fire); wrap(&pBlade, hz * st.blades); wrap(&pShaft, hz * 0.5)
                // each firing is a sharp pressure pulse; cylinders are never perfectly even
                let uneven = 1 + (st.radial ? 0.35 : 0.18) * sin(twoPi * pShaft * (st.radial ? 1 : 2))
                let pulse = exp(-pFire * (5 + 4 * sPower)) * uneven
                exhaust += (pulse * (0.7 + 0.3 * n0) - exhaust) * 0.35
                rumble += (n1 * pulse - rumble) * 0.08
                let b = twoPi * pBlade
                let prop = (sin(b) + 0.45 * sin(2 * b) + 0.2 * sin(3 * b)) * 0.1 * (0.3 + 0.7 * sPower)
                let wash = bandpass(n0, 400 + 1800 * sPower, 1.0, &propLo, &propBd) * 0.22 * sPower * sPower
                eng = ((exhaust - 0.12) * (0.55 + 0.45 * sPower) + rumble * 1.6 + prop + wash) * sRun
            case 2, 3:  // ducted fan / jet (2) and turboprop (3)
                wrap(&pWhine, hz * (st.engine == 2 ? 11 : 28)); wrap(&pBlade, hz * st.blades)
                let whine = (sin(twoPi * pWhine) + 0.3 * sin(2 * twoPi * pWhine + 0.7)) * (st.engine == 2 ? 0.06 : 0.035) * (0.5 + 0.5 * sPower)
                let hiss = bandpass(n0, 1400 + 2600 * sPower, 0.7, &jetLo, &jetBd) * (st.engine == 2 ? 0.34 : 0.14) * (0.25 + 0.75 * sPower)
                roar += (n1 - roar) * 0.02
                var s = whine + hiss + roar * (st.engine == 2 ? 1.5 : 0.7) * (0.2 + 0.8 * sPower * sPower)
                if st.engine == 3 {
                    let b = twoPi * pBlade
                    s += (sin(b) + 0.55 * sin(2 * b + 0.3) + 0.3 * sin(3 * b) + 0.15 * sin(4 * b)) * 0.2 * (0.3 + 0.7 * sPower) * (1 + 0.1 * n0)
                }
                eng = s * sRun
            case 4:     // helicopter: blade slap, rotor wash, tail rotor, motor whine
                wrap(&pBlade, hz * 2); wrap(&pTail, hz * 9.3); wrap(&pWhine, hz * 33)
                let sl = max(sin(twoPi * pBlade), 0)
                let slap = sl * sl * sl * sl * sl * sl
                let wash = bandpass(n0, 300 + 500 * sPower, 0.8, &propLo, &propBd)
                let tail = (2 * pTail - 1) * 0.05 + sin(twoPi * pTail * 2) * 0.03
                let whine = sin(twoPi * pWhine) * 0.03
                eng = (slap * (0.35 + 0.5 * sPower) + wash * (0.25 + 0.55 * sPower) * (0.35 + 0.65 * slap) + tail + whine) * sRun
            default:    // multirotor: four motors beating against each other
                var s: Float = 0
                for m in 0..<4 {
                    let lv = sMotor[m]
                    if lv < 0.005 { continue }
                    pMotor[m] += hz * (0.35 + 0.9 * lv.squareRoot()) * st.doppler / sampleRate
                    if pMotor[m] >= 1 { pMotor[m] -= 1 }
                    let ph = twoPi * pMotor[m]
                    s += (sin(ph) + 0.6 * sin(2 * ph + Float(m)) + 0.35 * sin(3 * ph) + 0.2 * sin(4 * ph)) * (0.25 + 0.75 * lv) * 0.09
                }
                let wash = bandpass(n0, 900 + 2500 * sPower, 0.8, &propLo, &propBd) * 0.22 * sPower
                eng = s * (1 + 0.1 * n1) + wash
            }

            // airframe: the hiss of air over the model, and tyres on the ground
            let air = bandpass(n1, 350 + 60 * sAir, 0.6, &airLo, &airBd) * min(sAir * sAir / 2200, 0.5)
            let src = (eng + air) * sGain

            // distance: air absorbs the highs
            let cut = 0.9 - 0.82 * sMuffle
            let pl = (1 - sPan) * 0.5, pr = (1 + sPan) * 0.5
            muffL += (src * pl.squareRoot() - muffL) * cut
            muffR += (src * pr.squareRoot() - muffR) * cut
            var L = muffL * 1.25, R = muffR * 1.25

            // ground roll (low, close to the aircraft)
            if sRoll > 0.05 {
                let g = min(sRoll / 12, 1) * sGain
                rumbleRoll += (n0 - rumbleRoll) * 0.015
                L += rumbleRoll * 2.2 * g * pl.squareRoot(); R += rumbleRoll * 2.2 * g * pr.squareRoot()
            }

            // ---- ambience at the pilot's position
            lfo1 += dt * 0.11; if lfo1 > 1 { lfo1 -= 1 }
            lfo2 += dt * 0.047; if lfo2 > 1 { lfo2 -= 1 }
            lfo3 += dt * 0.19; if lfo3 > 1 { lfo3 -= 1 }
            let gust = 0.55 + 0.3 * sin(twoPi * lfo1) + 0.15 * sin(twoPi * lfo3)
            let wAmt = min(0.012 + sWind * 0.011, 0.14) * gust
            let wf = 260 + 70 * sWind + 140 * sin(twoPi * lfo2)
            L += bandpass(n0, wf, 0.5, &windLoL, &windBdL) * wAmt
            R += bandpass(n1, wf * 1.07, 0.5, &windLoR, &windBdR) * wAmt
            if st.ambience == 1 {
                // surf: slow swells of filtered noise
                let swell = max(sin(twoPi * lfo1), 0)
                wave += (n0 - wave) * 0.06
                let w = wave * (0.05 + 0.22 * swell * swell)
                L += w; R += w * 0.8 + (n1 - wave) * 0.004 * swell
            }
            if st.ambience == 0 {
                // songbirds: short rising or falling whistles in little bursts
                birdT -= dt
                if birdT <= 0 && birdRepeat == 0 {
                    birdRepeat = 2 + Int(abs(noise()) * 5)
                    birdF0 = 2400 + abs(noise()) * 2600; birdF1 = birdF0 * (0.75 + abs(noise()) * 0.7)
                    birdDur = 0.05 + abs(noise()) * 0.09; birdPan = noise(); birdVol = 0.012 + abs(noise()) * 0.02
                    birdAge = 0; birdGap = birdDur * (1.5 + abs(noise()))
                    birdT = 2.5 + abs(noise()) * 7
                }
                if birdRepeat > 0 {
                    birdAge += dt
                    if birdAge < birdDur {
                        let t = birdAge / birdDur
                        birdPhase += (birdF0 + (birdF1 - birdF0) * t) / sampleRate
                        if birdPhase > 1 { birdPhase -= 1 }
                        let s = sin(twoPi * birdPhase) * sin(Float.pi * t) * birdVol
                        L += s * (1 - birdPan) * 0.5; R += s * (1 + birdPan) * 0.5
                    } else if birdAge > birdGap {
                        birdAge = 0; birdRepeat -= 1
                    }
                }
            }

            // ---- one-shots
            if crashEnv > 0.0005 || crashTone > 0.0005 {
                wrap(&crashPhase, 58)
                crashEnv *= 0.99982; crashTone *= 0.9997; crackle *= 0.99993
                splashLo += (n0 - splashLo) * 0.05
                var c = splashLo * 3.0 * crashEnv * crashEnv + sin(twoPi * crashPhase) * 0.5 * crashTone * crashTone
                // debris: sparse clicks that thin out
                if abs(n1) > 0.9985 - 0.0012 * crackle { c += n0 * 0.5 * crackle }
                c *= max(sGain, 0.25)
                L += c * (1 - crashPan) * 0.6; R += c * (1 + crashPan) * 0.6
            }
            if splashEnv > 0.0005 {
                splashEnv *= 0.99992
                let hissy = n0 - splashLo
                splashLo += (n0 - splashLo) * 0.2
                let c = (hissy * 0.25 + splashLo * 0.5) * splashEnv * max(sGain, 0.25)
                L += c * (1 - crashPan) * 0.6; R += c * (1 + crashPan) * 0.6
            }

            // soft limiter
            L *= sMaster * 0.9; R *= sMaster * 0.9
            left[i] = L / (1 + abs(L)) * 1.6
            right[i] = R / (1 + abs(R)) * 1.6
        }
    }
    private var rumbleRoll: Float = 0
}

/// Render a scripted fly-past of each engine type to a WAV file (used to check the synthesizer without speakers).
func writeSoundTest(to path: String) {
    let s = SoundEngine(start: false)
    let sr = Int(s.sampleRate)
    var pcm: [Int16] = []
    let l = UnsafeMutablePointer<Float>.allocate(capacity: 512), r = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    defer { l.deallocate(); r.deallocate() }
    let names = ["electric", "piston", "jet", "turboprop", "helicopter", "multirotor"]
    for kind in 0..<6 {
        var peak: Float = 0, sumSq: Double = 0, n = 0, bad = false
        let total = sr * 6 / 512
        for blk in 0..<total {
            let t = Float(blk) / Float(total)                // 0...1 through the pass
            var st = SoundState()
            st.engine = kind
            st.blades = kind == 3 ? 3 : 2; st.cylinders = 9; st.radial = true
            let thr = t < 0.15 ? t / 0.15 * 0.5 : (t < 0.7 ? 0.5 + 0.5 * sin((t - 0.15) * 9) * 0.6 + 0.2 : max(0, (1 - t) / 0.3) * 0.6)
            st.power = min(max(thr, 0), 1); st.running = kind == 1 || kind == 4 ? 1 : (thr > 0.02 ? 1 : 0)
            let x = (t - 0.5) * 2                              // passes left to right
            st.doppler = 1 - 0.06 * x
            let base: Float = [70, 45, 300, 38, 33, 180][kind]
            st.shaftHz = base * (kind == 4 ? 1 : 0.25 + 0.75 * st.power) * st.doppler
            st.motors = SIMD4(st.power, st.power * 0.9, st.power * 1.05, st.power * 0.95)
            st.gain = 1 / (1 + 6 * x * x); st.muffle = min(abs(x) * 0.8, 1); st.pan = x
            st.airspeed = 8 + 14 * st.power; st.windSpeed = 3; st.ambience = kind % 2
            s.state = st
            if blk == total * 9 / 10 { s.crash(0.8, water: kind % 2 == 1, pan: 0.5) }
            s.render(left: l, right: r, count: 512)
            for i in 0..<512 {
                if !l[i].isFinite || !r[i].isFinite { bad = true }
                peak = max(peak, abs(l[i]), abs(r[i])); sumSq += Double(l[i] * l[i] + r[i] * r[i]); n += 2
                pcm.append(Int16(max(-1, min(1, l[i])) * 32000)); pcm.append(Int16(max(-1, min(1, r[i])) * 32000))
            }
        }
        print(String(format: "SOUND %@: peak %.2f rms %.3f %@", names[kind], peak, sqrt(sumSq / Double(n)), bad ? "NON-FINITE SAMPLES" : "ok"))
    }
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let bytes = UInt32(pcm.count * 2)
    d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr * 4)); u16(4); u16(16)
    d.append("data".data(using: .ascii)!); u32(bytes)
    pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
    try? d.write(to: URL(fileURLWithPath: path))
}
