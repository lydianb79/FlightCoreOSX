import AppKit
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
            ac.reset(pos: V3(2, 1.9, 0), heading: 0, speed: 9)
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

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
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
        game = Game(site: siteArg, aircraft: Int(arg("--aircraft") ?? "") ?? 0)
        if let c = Int(arg("--cam") ?? "") { game.cameraMode = c }
        if let z = Int(arg("--zoom") ?? "") { game.zoomMode = z }
        if let t = Int(arg("--tod") ?? "") { game.timeOfDay = t }
        if CommandLine.arguments.contains("--auto") { game.autopilotOn = true }
        if CommandLine.arguments.contains("--balloons") { game.toggleChallenge() }
        if let ff = Float(arg("--ff") ?? "") { for _ in 0..<Int(ff * 60) { game.frame(dt: 1 / 60) } }

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FlightCore"
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
        NSApp.activate(ignoringOtherApps: true)
        buildMenus()
        if CommandLine.arguments.contains("--setup") { showSetup() }

        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [unowned self] e in
            guard e.window === self.window else { return e }
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
        menu("Aircraft", AircraftLibrary.all.enumerated().map { i, s in
            ClosureMenuItem(s.name, key: i < 9 ? "\(i + 1)" : "") { g.selectAircraft(i) }
        })
        var siteItems: [NSMenuItem] = SiteSpec.all.enumerated().map { i, s in
            ClosureMenuItem(s.name, key: i < 9 ? "\(i + 1)" : "", mods: [.command, .option]) { g.selectSite(i) }
        }
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
        menu("Flying Site", siteItems)
        menu("Simulation", [
            ClosureMenuItem("Reset Aircraft", key: "r") { g.resetAircraft() },
            ClosureMenuItem("Pause / Resume", key: "p") { g.paused.toggle() },
            ClosureMenuItem("Slow Motion") { g.keyDown(17) },
            .separator(),
            ClosureMenuItem("Balloon Burst Challenge", key: "b") { g.toggleChallenge() },
            ClosureMenuItem("Demo Pilot", key: "k") { g.keyDown(40) },
            ClosureMenuItem("Flight Mode (Self-level / Acro)") { g.keyDown(3) },
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
        viewItems.append(ClosureMenuItem("Show / Hide HUD") { g.hud.visible.toggle() })
        viewItems.append(ClosureMenuItem("Keyboard Help") { g.hud.showHelp.toggle() })
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
        if let l = last, let i = SiteSpec.all.firstIndex(where: { $0.panorama?.lastPathComponent == l.lastPathComponent }) { game.selectSite(i) }
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
