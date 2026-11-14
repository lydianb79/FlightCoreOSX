import Foundation
import GameController
import IOKit
import IOKit.hid
import AVFoundation

/// Raw USB joystick access. RC transmitters and simulator dongles show up as generic HID
/// joysticks, which the GameController framework ignores, so they are read through IOKit.
final class HIDJoystick {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var axes = [Float](repeating: 0, count: 9)
    var deviceCount = 0
    var name = ""

    init() {
        let match: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, match as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let me = Unmanaged<HIDJoystick>.fromOpaque(ctx!).takeUnretainedValue()
            me.deviceCount += 1
            me.name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "USB Joystick"
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            let me = Unmanaged<HIDJoystick>.fromOpaque(ctx!).takeUnretainedValue()
            me.deviceCount = max(0, me.deviceCount - 1)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            let me = Unmanaged<HIDJoystick>.fromOpaque(ctx!).takeUnretainedValue()
            let el = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(el) == UInt32(kHIDPage_GenericDesktop) else { return }
            let idx = Int(IOHIDElementGetUsage(el)) - kHIDUsage_GD_X
            guard idx >= 0 && idx < 9 else { return }
            let lo = Float(IOHIDElementGetLogicalMin(el)), hi = Float(IOHIDElementGetLogicalMax(el))
            guard hi > lo else { return }
            me.axes[idx] = clampf((Float(IOHIDValueGetIntegerValue(value)) - lo) / (hi - lo) * 2 - 1, -1, 1)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    var connected: Bool { deviceCount > 0 }
}

/// Controller settings, saved in user defaults. Channel order: aileron, elevator, throttle, rudder.
struct InputSettings: Codable {
    var axis = [0, 1, 2, 3]
    var invert = [false, true, false, false]
    // per USB axis calibration (raw values are -1...1 from the device's reported range)
    var calMin = [Float](repeating: -1, count: 9)
    var calMid = [Float](repeating: 0, count: 9)
    var calMax = [Float](repeating: 1, count: 9)
    var stickMode = 2                       // 1-4, for gamepads and the on-screen stick display
    var lowRate: Float = 0.6                // control throw on low rates
    var expo: [Float] = [0.25, 0.25, 0.2]   // aileron, elevator, rudder
    var deadband: Float = 0.03

    static let axisNames = ["X", "Y", "Z", "Rx", "Ry", "Rz", "Slider", "Dial", "Wheel"]
    static let channelNames = ["Aileron", "Elevator", "Throttle", "Rudder"]
    static let modeNames = ["Mode 1  (left: elevator + rudder, right: throttle + aileron)",
                            "Mode 2  (left: throttle + rudder, right: elevator + aileron)",
                            "Mode 3  (left: elevator + aileron, right: throttle + rudder)",
                            "Mode 4  (left: throttle + aileron, right: elevator + rudder)"]

    var valid: Bool {
        axis.count == 4 && invert.count == 4 && calMin.count == 9 && calMid.count == 9 && calMax.count == 9 && expo.count == 3 && (1...4).contains(stickMode)
    }
}

final class InputManager {
    var keys = Set<UInt16>()
    let hid = HIDJoystick()
    var settings = InputSettings() { didSet { if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "inputSettings") } } }
    var lowRates = false
    private var kb = V3.zero
    var kbThrottle: Float = 0
    var source = "Keyboard"

    // calibration recording
    private(set) var calibrating = false
    private var recMin = [Float](repeating: 0, count: 9), recMax = [Float](repeating: 0, count: 9)

    init() {
        if let d = UserDefaults.standard.data(forKey: "inputSettings"), let m = try? JSONDecoder().decode(InputSettings.self, from: d), m.valid {
            settings = m
        }
    }

    func resetThrottle(_ kind: AircraftKind, launch: Bool) { kbThrottle = kind == .helicopter ? 0.5 : (launch ? 0.75 : 0) }

    private func down(_ k: UInt16) -> Float { keys.contains(k) ? 1 : 0 }

    /// Deadband, expo and dual rate for a centred channel (0 aileron, 1 elevator, 2 rudder).
    private func shape(_ x: Float, _ i: Int) -> Float {
        let db = clampf(settings.deadband, 0, 0.3)
        let m = abs(x)
        if m <= db { return 0 }
        let v = (x < 0 ? -1 : 1) * min((m - db) / (1 - db), 1)
        let k = clampf(settings.expo[i], 0, 1)
        return ((1 - k) * v + k * v * v * v) * (lowRates ? settings.lowRate : 1)
    }

    /// Calibrated value of a USB axis: centred channels map min/centre/max to -1/0/+1, throttle maps min/max to -1/+1.
    private func calibrated(_ a: Int, centred: Bool) -> Float {
        let v = hid.axes[a], lo = settings.calMin[a], mid = settings.calMid[a], hi = settings.calMax[a]
        if centred {
            if v >= mid { return hi - mid > 0.05 ? clampf((v - mid) / (hi - mid), 0, 1) : 0 }
            return mid - lo > 0.05 ? clampf((v - mid) / (mid - lo), -1, 0) : 0
        }
        return hi - lo > 0.05 ? clampf((v - lo) / (hi - lo) * 2 - 1, -1, 1) : 0
    }

    /// Calibrated transmitter channel (0 aileron, 1 elevator, 2 throttle, 3 rudder), before expo and rates.
    func channel(_ i: Int) -> Float {
        let v = calibrated(min(max(settings.axis[i], 0), 8), centred: i != 2)
        return settings.invert[i] ? -v : v
    }

    func startCalibration() {
        recMin = hid.axes; recMax = hid.axes
        calibrating = true
    }

    /// Call with the sticks centred. Axes that were not moved keep their previous calibration.
    func finishCalibration() {
        guard calibrating else { return }
        calibrating = false
        var s = settings
        for a in 0..<9 where recMax[a] - recMin[a] > 0.5 {
            s.calMin[a] = recMin[a]; s.calMax[a] = recMax[a]
            s.calMid[a] = clampf(hid.axes[a], recMin[a] + 0.1, recMax[a] - 0.1)
        }
        settings = s
    }

    func resetCalibration() {
        calibrating = false
        var s = settings
        s.calMin = [Float](repeating: -1, count: 9); s.calMid = [Float](repeating: 0, count: 9); s.calMax = [Float](repeating: 1, count: 9)
        settings = s
    }

    func poll(dt: Float, kind: AircraftKind) -> Controls {
        var c = Controls()
        if calibrating { for a in 0..<9 { recMin[a] = min(recMin[a], hid.axes[a]); recMax[a] = max(recMax[a], hid.axes[a]) } }

        // keyboard: arrows = elevator / aileron, A/D = rudder, W/S = throttle
        let full: Float = (keys.contains(56) || keys.contains(60) ? 1 : 0.75) * (lowRates ? settings.lowRate : 1)
        let tgt = V3(down(124) - down(123), down(125) - down(126), down(2) - down(0)) * full
        for i in 0..<3 {
            let rate: Float = tgt[i] == 0 ? 7 : 4.5
            kb[i] += clampf(tgt[i] - kb[i], -rate * dt, rate * dt)
        }
        kbThrottle = clampf(kbThrottle + (down(13) - down(1)) * 0.7 * dt, 0, 1)
        if keys.contains(7) { kbThrottle = kind == .helicopter ? 0.5 : 0 }

        var dev = V3.zero       // aileron, elevator, rudder
        var thr = kbThrottle
        if hid.connected {
            source = hid.name
            dev = V3(shape(channel(0), 0), shape(channel(1), 1), shape(channel(3), 2))
            thr = (channel(2) + 1) / 2
        } else if let gp = GCController.controllers().compactMap({ $0.extendedGamepad }).first {
            source = gp.controller?.vendorName ?? "Gamepad"
            let lx = gp.leftThumbstick.xAxis.value, ly = gp.leftThumbstick.yAxis.value
            let rx = gp.rightThumbstick.xAxis.value, ry = gp.rightThumbstick.yAxis.value
            var a: Float, e: Float, r: Float, t: Float
            switch settings.stickMode {
            case 1: e = -ly; r = lx; t = ry; a = rx
            case 3: e = -ly; a = lx; t = ry; r = rx
            case 4: t = ly; a = lx; e = -ry; r = rx
            default: t = ly; r = lx; e = -ry; a = rx
            }
            dev = V3(shape(a, 0), shape(e, 1), shape(r, 2))
            // sprung throttle stick: airplanes use the upper half (or the right trigger), rotorcraft the full travel
            thr = kind == .airplane ? max(max(t, 0), gp.rightTrigger.value) : (t + 1) / 2
        } else {
            source = "Keyboard"
        }
        c.aileron = clampf(dev.x + kb.x, -1, 1)
        c.elevator = clampf(dev.y + kb.y, -1, 1)
        c.rudder = clampf(dev.z + kb.z, -1, 1)
        c.throttle = clampf(thr, 0, 1)
        return c
    }
}

/// Procedural engine / rotor sound with distance attenuation and Doppler shift.
final class SoundEngine {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    var kind = 0
    var targetFreq: Float = 100
    var targetGain: Float = 0
    var muted = false
    private var f: Float = 100, g: Float = 0
    private var p1: Float = 0, p2: Float = 0, p3: Float = 0
    private var seed: UInt32 = 12345
    private var lp: Float = 0
    private var crashEnv: Float = 0, thud: Float = 0

    func crash(_ strength: Float) { crashEnv = max(crashEnv, 0.4 + 0.6 * strength) }

    init() {
        let sr: Float = 44100
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 1) else { return }
        node = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl -> OSStatus in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard let raw = bufs[0].mData else { return noErr }
            let out = raw.assumingMemoryBound(to: Float.self)
            let tg = self.muted ? 0 : self.targetGain
            let twoPi = 2 * Float.pi
            for i in 0..<Int(frameCount) {
                self.f += (self.targetFreq - self.f) * 0.0015
                self.g += (tg - self.g) * 0.0015
                self.p1 += self.f / sr; if self.p1 > 1 { self.p1 -= 1 }
                self.p2 += self.f * 1.017 / sr; if self.p2 > 1 { self.p2 -= 1 }
                self.p3 += self.f * 0.984 / sr; if self.p3 > 1 { self.p3 -= 1 }
                self.seed = self.seed &* 1664525 &+ 1013904223
                let n = Float(Int32(bitPattern: self.seed)) / 2147483648
                self.lp += (n - self.lp) * 0.12
                var s: Float
                switch self.kind {
                case 0:
                    s = 0
                    for h in 1...6 { s += sin(twoPi * Float(h) * self.p1) / Float(h) }
                    s = s * 0.3 + self.lp * 0.45
                case 1:
                    s = sin(twoPi * self.p1) * 0.12 + sin(twoPi * 2 * self.p2) * 0.06 + (n - self.lp) * 0.16 + self.lp * 0.5
                case 2:
                    let th = max(sin(twoPi * self.p1), 0)
                    let t2 = th * th
                    s = t2 * t2 * t2 * 0.9 + sin(twoPi * 11 * self.p1) * 0.05 + self.lp * 0.3
                default:
                    s = ((2 * self.p1 - 1) + (2 * self.p2 - 1) + (2 * self.p3 - 1)) * 0.17 + self.lp * 0.25
                }
                self.thud += (n - self.thud) * 0.04
                self.crashEnv *= 0.99975
                let boom = self.muted ? 0 : (self.thud * 2.2 + n * 0.25) * self.crashEnv * self.crashEnv
                out[i] = s * self.g * 0.5 + boom
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
    }
}
