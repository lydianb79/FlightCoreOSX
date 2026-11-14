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

/// Channel order: aileron, elevator, throttle, rudder
struct ChannelMap: Codable {
    var axis = [0, 1, 2, 3]
    var invert = [false, true, false, false]
    static let axisNames = ["X", "Y", "Z", "Rx", "Ry", "Rz", "Slider", "Dial", "Wheel"]
    static let channelNames = ["Aileron", "Elevator", "Throttle", "Rudder"]
}

final class InputManager {
    var keys = Set<UInt16>()
    let hid = HIDJoystick()
    var map = ChannelMap() { didSet { if let d = try? JSONEncoder().encode(map) { UserDefaults.standard.set(d, forKey: "channelMap") } } }
    private var kb = V3.zero
    var kbThrottle: Float = 0
    var source = "Keyboard"

    init() {
        if let d = UserDefaults.standard.data(forKey: "channelMap"), let m = try? JSONDecoder().decode(ChannelMap.self, from: d), m.axis.count == 4, m.invert.count == 4 {
            map = m
        }
    }

    func resetThrottle(_ kind: AircraftKind, launch: Bool) { kbThrottle = kind == .helicopter ? 0.5 : (launch ? 0.75 : 0) }

    private func expo(_ x: Float) -> Float { 0.65 * x + 0.35 * x * x * x }
    private func down(_ k: UInt16) -> Float { keys.contains(k) ? 1 : 0 }

    func channel(_ i: Int) -> Float {
        let v = hid.axes[min(max(map.axis[i], 0), 8)]
        return map.invert[i] ? -v : v
    }

    func poll(dt: Float, kind: AircraftKind) -> Controls {
        var c = Controls()
        // keyboard: arrows = right stick, A/D = rudder, W/S = throttle
        let full: Float = keys.contains(56) || keys.contains(60) ? 1 : 0.75
        let tgt = V3(down(124) - down(123), down(125) - down(126), down(2) - down(0)) * full
        for i in 0..<3 {
            let rate: Float = tgt[i] == 0 ? 7 : 4.5
            kb[i] += clampf(tgt[i] - kb[i], -rate * dt, rate * dt)
        }
        kbThrottle = clampf(kbThrottle + (down(13) - down(1)) * 0.7 * dt, 0, 1)
        if keys.contains(7) { kbThrottle = kind == .helicopter ? 0.5 : 0 }

        var dev = V3.zero
        var thr = kbThrottle
        if hid.connected {
            source = hid.name
            dev = V3(channel(0), channel(1), channel(3))
            thr = (channel(2) + 1) / 2
        } else if let gp = GCController.controllers().compactMap({ $0.extendedGamepad }).first {
            source = gp.controller?.vendorName ?? "Gamepad"
            dev = V3(expo(gp.rightThumbstick.xAxis.value), expo(-gp.rightThumbstick.yAxis.value), expo(gp.leftThumbstick.xAxis.value))
            let ly = gp.leftThumbstick.yAxis.value
            thr = kind == .airplane ? max(max(ly, 0), gp.rightTrigger.value) : (ly + 1) / 2
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
                out[i] = s * self.g * 0.5
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
    }
}
