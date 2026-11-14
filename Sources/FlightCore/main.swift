import AppKit
import GameController
import MetalKit
import SwiftUI

func runSelfTest() {
    let site = SiteSpec.all[0]
    let terrain = Terrain(site: site)
    let env = Environment()
    env.configure(site)
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
            env.time += 0.001
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
        // 1. power-off stall from level flight: hold the nose up as the speed bleeds away
        let ac = Aircraft(spec); ac.unlimitedBattery = true
        ac.reset(pos: V3(0, 150, 0), heading: 0, speed: spec.stallSpeed * 1.6)
        var minV: Float = 99, breakV: Float = 0, maxBank: Float = 0, pitchAtBreak: Float = 0, lowestPitch: Float = 9
        fly(ac, 14, { t in
            var c = Controls()
            c.elevator = clampf(0.1 + t * 0.09, -1, 1)
            c.aileron = clampf(-1.5 * ac.roll, -0.3, 0.3) * (ac.wingStall > 0.3 ? 0 : 1)
            return c
        }, each: { _ in
            minV = min(minV, ac.airspeed)
            if breakV == 0 && ac.wingStall > 0.5 { breakV = ac.airspeed; pitchAtBreak = ac.pitch }
            if breakV > 0 { maxBank = max(maxBank, abs(ac.roll)); lowestPitch = min(lowestPitch, ac.pitch) }
        })
        print(String(format: "   stall: wing lets go at %.0f km/h (predicted %.0f), nose %.0f° -> %.0f°, wing drop up to %.0f°",
                     breakV * 3.6, spec.stallSpeed * 3.6, pitchAtBreak / deg, lowestPitch / deg, maxBank / deg))
        // 1b. the same with power on: torque and slipstream make one wing go first
        ac.reset(pos: V3(0, 150, 0), heading: 0, speed: spec.stallSpeed * 1.5)
        var bank2: Float = 0, went = false
        fly(ac, 12, { t in var c = Controls(); c.throttle = 0.7; c.elevator = clampf(0.1 + t * 0.1, -1, 1); return c },
            each: { _ in if ac.wingStall > 0.4 { went = true }; if went && abs(bank2) < abs(ac.roll) { bank2 = ac.roll } })
        print(String(format: "   power-on stall, ailerons neutral: rolls %.0f° %@", abs(bank2) / deg, bank2 < 0 ? "left" : "right"))
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
        let order = ["Trainers & Sport", "Scale Civil", "Warbirds", "Aerobatic", "Foam 3D", "Jets", "Gliders", "Helicopters", "Multirotors"]
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
