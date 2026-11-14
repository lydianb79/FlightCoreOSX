import SwiftUI
import AppKit

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.22, green: 0.6, blue: 1.0)
    static let panel = Color(red: 0.07, green: 0.08, blue: 0.1).opacity(0.9)
    static let glass = Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.62)
    static let card = Color.white.opacity(0.055)
    static let stroke = Color.white.opacity(0.1)
    static let dim = Color.white.opacity(0.6)
    static let faint = Color.white.opacity(0.38)
}

private struct GlassBox: ViewModifier {
    var radius: CGFloat = 12
    var fill = Theme.glass
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}
private extension View {
    func glass(_ radius: CGFloat = 12, fill: Color = Theme.glass) -> some View { modifier(GlassBox(radius: radius, fill: fill)) }
}

private struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1)))
    }
}
private struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

private struct Difficulty: View {
    var level: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle().fill(i <= level ? (level >= 4 ? Color.orange : Theme.accent) : Color.white.opacity(0.15)).frame(width: 7, height: 7)
            }
            Text(["", "Beginner", "Easy", "Intermediate", "Advanced", "Expert"][min(max(level, 1), 5)])
                .font(.system(size: 11, weight: .medium)).foregroundColor(Theme.dim).padding(.leading, 4)
        }
    }
}

private struct Tag: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

private func specRow(_ k: String, _ v: String) -> some View {
    HStack {
        Text(k).foregroundColor(Theme.dim)
        Spacer()
        Text(v).monospacedDigit().foregroundColor(.white)
    }
    .font(.system(size: 12.5))
    .padding(.vertical, 5)
    .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1), alignment: .bottom)
}

/// Preview image on a soft studio backdrop.
private struct Backdrop<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.5), Color(red: 0.11, green: 0.13, blue: 0.17)], center: .init(x: 0.5, y: 0.42), startRadius: 4, endRadius: 260)
            content
        }
    }
}

// MARK: - HUD

private struct StickView: View {
    var x: Float, y: Float, label: String
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1)
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1)
                Circle().fill(Theme.accent).frame(width: 12, height: 12)
                    .shadow(color: Theme.accent.opacity(0.7), radius: 5)
                    .offset(x: CGFloat(x) * 34, y: CGFloat(-y) * 34)
            }
            .frame(width: 84, height: 84)
            .glass(10)
            Text(label).font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundColor(Theme.faint)
        }
    }
}

private struct Metric: View {
    var label: String, value: String, unit: String
    var body: some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 9.5, weight: .semibold)).tracking(0.9).foregroundColor(Theme.faint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit().foregroundColor(.white)
                Text(unit).font(.system(size: 10.5, weight: .medium)).foregroundColor(Theme.dim)
            }
        }
        .frame(minWidth: 78)
    }
}

private struct BarButton: View {
    var icon: String, help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain).focusable(false).help(help)
    }
}

private struct Chip: View {
    var icon: String, title: String, subtitle: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Text(subtitle).font(.system(size: 10.5)).foregroundColor(Theme.dim).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .glass(9)
        }
        .buttonStyle(.plain).focusable(false)
    }
}

struct HUDView: View {
    @ObservedObject var m: HUDModel

    var body: some View {
        let s = m.s
        ZStack {
            if m.visible && m.overlay != .menu {
                VStack(spacing: 0) {
                    // top bar
                    HStack(spacing: 8) {
                        Chip(icon: "airplane", title: s.aircraft, subtitle: s.mode.isEmpty ? "Aircraft" : s.mode) { m.overlay = .aircraft }
                        Chip(icon: "map", title: s.site, subtitle: s.time) { m.overlay = .sites }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(s.camera).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.85))
                            Text("\(s.input) · \(s.rates) rates · \(s.fps) fps").font(.system(size: 10)).monospacedDigit().foregroundColor(Theme.dim)
                        }
                        .padding(.trailing, 4).allowsHitTesting(false)
                        HStack(spacing: 5) {
                            BarButton(icon: "wind", help: "Wind, weather and time of day") { m.overlay = m.overlay == .environment ? .none : .environment }
                            BarButton(icon: "gamecontroller", help: "Controller setup") { m.openControllerSetup?() }
                            BarButton(icon: "questionmark", help: "Keyboard controls (H)") { m.overlay = m.overlay == .help ? .none : .help }
                            BarButton(icon: "line.3.horizontal", help: "Main menu (Esc)") { m.overlay = .menu }
                        }
                        .padding(4).glass(10)
                    }
                    .padding(.leading, m.fullscreen ? 12 : 84).padding(.trailing, 12).padding(.top, 9)

                    if !s.score.isEmpty {
                        Text(s.score).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit().foregroundColor(.yellow)
                            .padding(.horizontal, 14).padding(.vertical, 6).glass(9).padding(.top, 8).allowsHitTesting(false)
                    }
                    Spacer()
                    // bottom: sticks and telemetry
                    HStack(alignment: .bottom) {
                        StickView(x: s.lx, y: s.ly, label: s.leftLabel)
                        Spacer()
                        VStack(spacing: 7) {
                            if !s.config.isEmpty {
                                Text(s.config).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundColor(.yellow)
                                    .padding(.horizontal, 12).padding(.vertical, 4).glass(8)
                            }
                            HStack(spacing: 6) {
                                Metric(label: "ALTITUDE", value: String(format: "%.0f", max(s.alt, 0)), unit: "m")
                                Metric(label: "AIRSPEED", value: String(format: "%.0f", s.speed * 3.6), unit: "km/h")
                                Metric(label: "CLIMB", value: String(format: "%+.1f", s.climb), unit: "m/s")
                                Metric(label: "DISTANCE", value: String(format: "%.0f", s.dist), unit: "m")
                                Metric(label: "THROTTLE", value: String(format: "%.0f", s.throttle * 100), unit: "%")
                                Metric(label: "WIND", value: s.wind.components(separatedBy: " ").first ?? "", unit: s.wind.components(separatedBy: " ").dropFirst().joined(separator: " "))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8).glass(12)
                        }
                        Spacer()
                        StickView(x: s.rx, y: s.ry, label: s.rightLabel)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12).allowsHitTesting(false)
                }
            }
            if !s.message.isEmpty && !m.overlay.pausesSim {
                VStack {
                    Spacer().frame(height: 74)
                    let big = s.message == "CRASHED" || s.message == "PAUSED"
                    Text(s.message)
                        .font(.system(size: big ? 30 : 14, weight: big ? .heavy : .semibold, design: big ? .rounded : .default))
                        .tracking(big ? 3 : 0)
                        .foregroundColor(s.message == "CRASHED" ? Color(red: 1, green: 0.3, blue: 0.25) : .white)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .glass(10)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            switch m.overlay {
            case .menu: MainMenu(m: m)
            case .aircraft: AircraftBrowser(m: m)
            case .sites: SiteBrowser(m: m)
            case .environment: EnvironmentPanel(m: m)
            case .help: HelpView(m: m)
            case .none: EmptyView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Overlay scaffolding

private struct Sheet<Content: View>: View {
    @ObservedObject var m: HUDModel
    var title: String
    var subtitle: String
    var back: Overlay = .none
    var width: CGFloat = 1120
    var height: CGFloat = 660
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { m.overlay = back }
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 21, weight: .bold)).foregroundColor(.white)
                    Text(subtitle).font(.system(size: 12.5)).foregroundColor(Theme.dim).padding(.leading, 6)
                    Spacer()
                    Button { m.overlay = back } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.8))
                            .frame(width: 26, height: 26).background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                content
            }
            .frame(maxWidth: width, maxHeight: height)
            .glass(16, fill: Theme.panel)
            .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
            .padding(28)
        }
    }
}

// MARK: - Aircraft browser

struct AircraftBrowser: View {
    @ObservedObject var m: HUDModel
    @State private var category = "All"
    @State private var search = ""
    @State private var selected = 0

    private static let order = ["Trainers & Sport", "Scale Civil", "Warbirds", "Aerobatic", "Foam 3D", "Jets", "Gliders", "Helicopters", "Multirotors"]
    private var all: [AircraftSpec] { AircraftLibrary.all }
    private var shown: [Int] {
        all.indices.filter { i in
            (category == "All" || all[i].category == category)
                && (search.isEmpty || all[i].name.localizedCaseInsensitiveContains(search) || all[i].blurb.localizedCaseInsensitiveContains(search))
        }
    }
    private func fly(_ i: Int) { m.game.selectAircraft(i); m.overlay = .none }

    var body: some View {
        Sheet(m: m, title: "Choose Aircraft", subtitle: "\(all.count) models", back: m.game.cameFromMenu ? .menu : .none) {
            HStack(spacing: 0) {
                // categories
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(["All"] + Self.order, id: \.self) { c in
                        let n = c == "All" ? all.count : all.filter { $0.category == c }.count
                        Button { category = c } label: {
                            HStack {
                                Text(c).font(.system(size: 13, weight: category == c ? .semibold : .regular))
                                Spacer()
                                Text("\(n)").font(.system(size: 11)).monospacedDigit().foregroundColor(Theme.faint)
                            }
                            .foregroundColor(category == c ? .white : Theme.dim)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(category == c ? Theme.accent.opacity(0.28) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).focusable(false)
                    }
                    Spacer()
                }
                .frame(width: 176).padding(12)
                Rectangle().fill(Theme.stroke).frame(width: 1)

                // grid
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.faint)
                        TextField("Search aircraft", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 10)], spacing: 10) {
                            ForEach(shown, id: \.self) { i in
                                let spec = all[i]
                                VStack(alignment: .leading, spacing: 0) {
                                    Backdrop {
                                        if let img = m.thumbnail(spec) { Image(nsImage: img).resizable().scaledToFit().padding(4) }
                                    }
                                    .frame(height: 98).clipped()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(spec.name).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                                        Text(spec.category).font(.system(size: 10.5)).foregroundColor(Theme.dim).lineLimit(1)
                                    }
                                    .padding(.horizontal, 9).padding(.vertical, 7)
                                }
                                .background(Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected == i ? Theme.accent : Theme.stroke, lineWidth: selected == i ? 2 : 1))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { fly(i) }
                                .onTapGesture { selected = i }
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 14)
                        if shown.isEmpty { Text("No aircraft match “\(search)”.").font(.system(size: 13)).foregroundColor(Theme.dim).padding(30) }
                    }
                }
                Rectangle().fill(Theme.stroke).frame(width: 1)

                // details
                let spec = all[min(selected, all.count - 1)]
                VStack(alignment: .leading, spacing: 0) {
                    Backdrop {
                        if let img = m.thumbnail(spec) { Image(nsImage: img).resizable().scaledToFit().padding(6) }
                    }
                    .frame(height: 205).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(spec.name).font(.system(size: 20, weight: .bold)).foregroundColor(.white).padding(.top, 14)
                    HStack(spacing: 8) { Tag(text: spec.category); Difficulty(level: spec.difficulty) }.padding(.top, 6)
                    Text(spec.blurb).font(.system(size: 13)).foregroundColor(.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    VStack(spacing: 0) {
                        specRow(spec.sizeLabel, String(format: "%.2f m", spec.span))
                        specRow("Flying weight", spec.mass < 1 ? String(format: "%.0f g", spec.mass * 1000) : String(format: "%.1f kg", spec.mass))
                        if spec.kind == .airplane { specRow("Stall speed", String(format: "%.0f km/h", spec.stallSpeed * 3.6)) }
                        if spec.kind != .helicopter { specRow("Thrust to weight", String(format: "%.1f : 1", spec.thrustToWeight)) }
                    }
                    .padding(.top, 12)
                    if !spec.features.isEmpty {
                        HStack(spacing: 5) { ForEach(spec.features.prefix(3), id: \.self) { Tag(text: $0) } }.padding(.top, 10)
                    }
                    Spacer(minLength: 8)
                    Button { fly(selected) } label: { Text(selected == m.game.aircraftIndex ? "Fly Again" : "Fly This Aircraft").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                }
                .frame(width: 300).padding(16)
            }
        }
        .onAppear { selected = m.game.aircraftIndex }
    }
}

// MARK: - Site browser

struct SiteBrowser: View {
    @ObservedObject var m: HUDModel
    @State private var selected = 0
    @State private var filter = "All"
    @State private var search = ""
    private static let categories = ["Fields", "Airfields", "Mountains", "Water", "Desert", "Winter"]
    private var all: [SiteSpec] { SiteSpec.all }
    private func matches(_ s: SiteSpec, _ f: String) -> Bool {
        switch f {
        case "All": return true
        case "3D Sites": return s.panorama == nil
        case "Photo Sites": return s.panorama != nil
        default: return s.category == f
        }
    }
    private var shown: [Int] {
        all.indices.filter { i in
            matches(all[i], filter) && (search.isEmpty || all[i].displayName.localizedCaseInsensitiveContains(search) || all[i].summary.localizedCaseInsensitiveContains(search))
        }
    }
    private func fly(_ i: Int) { m.game.selectSite(i); m.overlay = .none }

    private func filterRow(_ f: String, icon: String) -> some View {
        Button { filter = f } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11.5)).frame(width: 16).foregroundColor(filter == f ? .white : Theme.faint)
                Text(f).font(.system(size: 13, weight: filter == f ? .semibold : .regular))
                Spacer()
                Text("\(all.filter { matches($0, f) }.count)").font(.system(size: 11)).monospacedDigit().foregroundColor(Theme.faint)
            }
            .foregroundColor(filter == f ? .white : Theme.dim)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(filter == f ? Theme.accent.opacity(0.28) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false)
    }
    private func heading(_ t: String) -> some View {
        Text(t).font(.system(size: 9.5, weight: .semibold)).tracking(1).foregroundColor(Theme.faint).padding(.leading, 10).padding(.top, 12).padding(.bottom, 3)
    }
    private func badge(_ site: SiteSpec) -> some View {
        Text(site.panorama != nil ? "360° PHOTO" : "3D").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(site.panorama != nil ? Color(red: 0.55, green: 0.35, blue: 0.9).opacity(0.9) : Theme.accent.opacity(0.9)))
    }

    var body: some View {
        Sheet(m: m, title: "Choose Flying Site", subtitle: "\(all.count) sites", back: m.game.cameFromMenu ? .menu : .none) {
            HStack(spacing: 0) {
                // filters
                VStack(alignment: .leading, spacing: 2) {
                    filterRow("All", icon: "square.grid.2x2")
                    heading("TYPE")
                    filterRow("3D Sites", icon: "cube")
                    filterRow("Photo Sites", icon: "camera")
                    heading("LANDSCAPE")
                    filterRow("Fields", icon: "leaf")
                    filterRow("Airfields", icon: "airplane.departure")
                    filterRow("Mountains", icon: "mountain.2")
                    filterRow("Water", icon: "water.waves")
                    filterRow("Desert", icon: "sun.max")
                    filterRow("Winter", icon: "snowflake")
                    Spacer()
                    Button { m.addPanorama?() } label: { Label("Add Photo…", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(QuietButton())
                    Text("Any 360° equirectangular photo becomes a site.").font(.system(size: 10.5)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
                .frame(width: 176).padding(12)
                Rectangle().fill(Theme.stroke).frame(width: 1)

                // grid
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.faint)
                        TextField("Search sites", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 230), spacing: 10)], spacing: 10) {
                            ForEach(shown, id: \.self) { i in
                                let site = all[i]
                                VStack(alignment: .leading, spacing: 0) {
                                    ZStack(alignment: .topLeading) {
                                        LinearGradient(colors: [Color(red: 0.25, green: 0.4, blue: 0.6), Color(red: 0.2, green: 0.32, blue: 0.2)], startPoint: .top, endPoint: .bottom)
                                        if let img = m.sitePreview(site) { Image(nsImage: img).resizable().scaledToFill().frame(minWidth: 0, maxWidth: .infinity, minHeight: 104, maxHeight: 104).clipped() }
                                        badge(site).padding(7)
                                    }
                                    .frame(height: 104).clipped()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(site.displayName).font(.system(size: 12.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                                        Text(site.category).font(.system(size: 10.5)).foregroundColor(Theme.dim).lineLimit(1)
                                    }
                                    .padding(.horizontal, 9).padding(.vertical, 7)
                                }
                                .background(Theme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected == i ? Theme.accent : Theme.stroke, lineWidth: selected == i ? 2 : 1))
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { fly(i) }
                                .onTapGesture { selected = i }
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 14)
                        if shown.isEmpty { Text("No sites match.").font(.system(size: 13)).foregroundColor(Theme.dim).padding(30) }
                    }
                }
                Rectangle().fill(Theme.stroke).frame(width: 1)

                // details
                let site = all[min(selected, all.count - 1)]
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Color.black.opacity(0.3)
                        if let img = m.sitePreview(site) { Image(nsImage: img).resizable().scaledToFill() }
                    }
                    .frame(width: 300, height: 188).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(site.displayName).font(.system(size: 20, weight: .bold)).foregroundColor(.white).padding(.top, 14)
                    HStack(spacing: 8) { Tag(text: site.kindLabel); Tag(text: site.category); Difficulty(level: site.difficulty) }.padding(.top, 6)
                    Text(site.summary).font(.system(size: 13)).foregroundColor(.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    VStack(spacing: 0) {
                        specRow("Surface", site.surfaceLabel)
                        specRow("Typical wind", site.windSpeed < 0.5 ? "Calm" : String(format: "%.0f m/s from %.0f°", site.windSpeed, site.windFrom))
                        specRow("Turbulence", site.turbulence < 0.25 ? "Light" : (site.turbulence < 0.5 ? "Moderate" : "Strong"))
                        specRow("Cameras", site.panorama != nil ? "Pilot" : "Pilot, chase, onboard")
                    }
                    .padding(.top, 12)
                    Spacer(minLength: 8)
                    Button { fly(selected) } label: { Text(selected == m.game.siteIndex ? "Fly Here Again" : "Fly Here").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                }
                .frame(width: 300).padding(16)
            }
        }
        .onAppear { selected = m.game.siteIndex }
    }
}

// MARK: - Main menu

struct MainMenu: View {
    @ObservedObject var m: HUDModel

    private func tile(_ label: String, _ title: String, _ sub: String, image: NSImage?, studio: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if studio { Backdrop { if let i = image { Image(nsImage: i).resizable().scaledToFit().padding(6) } } }
                    else { Color.black.opacity(0.3); if let i = image { Image(nsImage: i).resizable().scaledToFill() } }
                }
                .frame(width: 262, height: 150).clipped()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.system(size: 9.5, weight: .semibold)).tracking(1).foregroundColor(Theme.faint)
                        Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                        Text(sub).font(.system(size: 11)).foregroundColor(Theme.dim).lineLimit(1)
                    }
                    Spacer()
                    Text("Change").font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.accent)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .frame(width: 262)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain).focusable(false)
    }

    var body: some View {
        let spec = m.game.aircraft.spec, site = m.game.site
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    if let url = resourceURL("AppIcon.png"), let icon = NSImage(contentsOf: url) {
                        Image(nsImage: icon).resizable().frame(width: 62, height: 62)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FlightCore").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundColor(.white)
                        Text("Radio-control flight simulator").font(.system(size: 13)).foregroundColor(Theme.dim)
                    }
                    Spacer()
                }
                .padding(.bottom, 20)
                HStack(spacing: 14) {
                    tile("AIRCRAFT", spec.name, spec.category, image: m.thumbnail(spec), studio: true) { m.game.cameFromMenu = true; m.overlay = .aircraft }
                    tile("FLYING SITE", site.displayName, site.kindLabel, image: m.sitePreview(site), studio: false) { m.game.cameFromMenu = true; m.overlay = .sites }
                }
                Button { m.game.cameFromMenu = false; m.overlay = .none } label: {
                    HStack(spacing: 8) { Image(systemName: "play.fill"); Text("Fly") }.font(.system(size: 16, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 3)
                }
                .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).padding(.top, 18)
                HStack(spacing: 8) {
                    Button { m.game.cameFromMenu = false; m.overlay = .environment } label: { Label("Weather", systemImage: "wind") }.buttonStyle(QuietButton())
                    Button { m.openControllerSetup?() } label: { Label("Controller", systemImage: "gamecontroller") }.buttonStyle(QuietButton())
                    Button { m.game.cameFromMenu = false; m.overlay = .help } label: { Label("Controls", systemImage: "keyboard") }.buttonStyle(QuietButton())
                    Spacer()
                    Button { NSApp.terminate(nil) } label: { Text("Quit") }.buttonStyle(QuietButton())
                }
                .padding(.top, 12)
                HStack(spacing: 10) {
                    Text("Graphics").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.dim)
                    Picker("", selection: Binding(get: { m.game.quality }, set: { m.game.quality = $0; m.objectWillChange.send() })) {
                        ForEach(0..<3, id: \.self) { Text(Game.qualityNames[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    Spacer()
                    Text("⌃⌘F  full screen").font(.system(size: 11)).foregroundColor(Theme.faint)
                }
                .padding(.top, 14)
            }
            .padding(26)
            .frame(width: 590)
            .glass(18, fill: Theme.panel)
            .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
        }
    }
}

// MARK: - Environment panel

struct EnvironmentPanel: View {
    @ObservedObject var m: HUDModel

    private func bind(_ get: @escaping () -> Float, _ set: @escaping (Float) -> Void) -> Binding<Float> {
        Binding(get: get, set: { set($0); m.objectWillChange.send() })
    }
    private func row(_ title: String, _ value: String, _ b: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.9))
                Spacer()
                Text(value).font(.system(size: 12.5)).monospacedDigit().foregroundColor(Theme.dim)
            }
            Slider(value: b, in: range).controlSize(.small)
        }
    }

    var body: some View {
        let env = m.game.env
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        HStack {
            Spacer()
            VStack {
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("Weather").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                        Spacer()
                        Button { m.overlay = .none } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.8))
                                .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    }
                    row("Wind speed", String(format: "%.0f m/s  (%.0f km/h)", env.windSpeed, env.windSpeed * 3.6), bind({ env.windSpeed }, { env.windSpeed = $0.rounded() }), 0...15)
                    row("Wind from", String(format: "%@  %.0f°", dirs[Int((env.windFrom + 22.5) / 45) % 8], env.windFrom), bind({ env.windFrom }, { env.windFrom = ($0 / 5).rounded() * 5 }), 0...355)
                    row("Turbulence", env.turbulence < 0.05 ? "Smooth" : String(format: "%.0f %%", env.turbulence * 100), bind({ env.turbulence }, { env.turbulence = $0 }), 0...1)
                    Toggle(isOn: Binding(get: { env.thermalsOn }, set: { env.thermalsOn = $0; m.objectWillChange.send() })) {
                        Text("Thermals").font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.9))
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    if m.game.site.panorama == nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Time of day").font(.system(size: 12.5, weight: .medium)).foregroundColor(.white.opacity(0.9))
                            Picker("", selection: Binding(get: { m.game.timeOfDay }, set: { m.game.timeOfDay = $0; m.objectWillChange.send() })) {
                                ForEach(0..<3, id: \.self) { Text(Game.timeNames[$0]).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                        }
                    }
                    Button { m.game.env.configure(m.game.site); m.objectWillChange.send() } label: { Text("Reset to Site Default").frame(maxWidth: .infinity) }.buttonStyle(QuietButton())
                }
                .padding(18)
                .frame(width: 300)
                .glass(14, fill: Theme.panel)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                Spacer()
            }
            .padding(.top, 54).padding(.trailing, 12)
        }
    }
}

// MARK: - Help

struct HelpView: View {
    @ObservedObject var m: HUDModel
    private let groups: [(String, [(String, String)])] = [
        ("Flying", [("← →", "Aileron (roll)"), ("↑ ↓", "Elevator — ↓ pulls up"), ("A  D", "Rudder (yaw)"), ("W  S", "Throttle / collective"),
                    ("X", "Throttle cut"), ("Shift", "Full stick deflection"), ("L", "High / low rates"), ("Space", "Reset aircraft")]),
        ("Aircraft", [("E", "Flaps: up, half, full"), ("G", "Landing gear"), ("Y", "Smoke"), ("U", "Helicopter throttle hold"),
                      ("F", "Quadcopter flight mode"), ("[  ]", "Previous / next aircraft"), ("Tab", "Aircraft browser")]),
        ("View and simulation", [("C", "Camera: pilot, chase, onboard"), ("Z", "Zoom mode"), ("V", "Hide / show display"), ("P", "Pause"),
                                 ("T", "Slow motion"), (",  .", "Less / more wind"), ("N", "Next flying site"), ("B", "Balloon Burst challenge"),
                                 ("K", "Demo pilot"), ("M", "Mute sound"), ("Esc", "Main menu")]),
    ]
    var body: some View {
        Sheet(m: m, title: "Controls", subtitle: "Keyboard", width: 860, height: 520) {
            HStack(alignment: .top, spacing: 26) {
                ForEach(groups, id: \.0) { g in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(g.0.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1).foregroundColor(Theme.accent).padding(.bottom, 3)
                        ForEach(g.1, id: \.0) { k in
                            HStack(spacing: 10) {
                                Text(k.0).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                                    .frame(minWidth: 46).padding(.vertical, 3).padding(.horizontal, 5)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
                                Text(k.1).font(.system(size: 12.5)).foregroundColor(.white.opacity(0.85))
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            Spacer(minLength: 0)
            Text("Gamepads and USB RC transmitters are detected automatically. Calibration, stick mode, rates and expo are in Controller Setup (⌘,).")
                .font(.system(size: 11.5)).foregroundColor(Theme.dim).padding(.horizontal, 24).padding(.bottom, 18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
