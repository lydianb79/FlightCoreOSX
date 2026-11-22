import SwiftUI

// The Flight Academy's screens: the chapters, a step's briefing, the panel in flight, pause and result.

private let passGreen = Color(red: 0.36, green: 0.78, blue: 0.42)

private struct ChapterRow: View {
    var level: Level
    var passed: Int
    var open: Bool
    var complete: Bool
    var selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: !open ? "lock.fill" : (complete ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: 11, weight: .bold)).frame(width: 14)
                .foregroundColor(complete ? passGreen : Theme.cream.opacity(open ? 0.7 : 0.35))
            Text(level.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream.opacity(open ? 1 : 0.45))
            Spacer()
            Text(open ? "\(passed) / \(AcademyRules.stepsPerChapter)" : "Locked").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundColor(Theme.cream.opacity(open ? 0.7 : 0.35))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.red : Theme.card))
        .contentShape(Rectangle())
    }
}

private struct StepRow: View {
    var number: Int
    var step: AcademyStep
    var record: AcademyProgress.Record?
    var open: Bool
    var selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(record?.passed == true ? passGreen : Theme.cream.opacity(0.12)).frame(width: 24, height: 24)
                if record?.passed == true { Image(systemName: "checkmark").font(.system(size: 11, weight: .black)).foregroundColor(Theme.ink) }
                else { Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.cream.opacity(0.8)) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cream.opacity(open ? 1 : 0.5)).lineLimit(1)
                Text(status).font(.system(size: 10.5)).foregroundColor(selected ? Theme.cream.opacity(0.85) : Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let r = record { Text("\(r.best)%").font(.system(size: 13, weight: .heavy)).monospacedDigit().foregroundColor(r.passed && !selected ? passGreen : Theme.cream) }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.red : Theme.card))
        .contentShape(Rectangle())
    }
    private var status: String {
        guard open else { return "Locked" }
        guard let r = record else { return "Not flown yet" }
        if r.passed { return r.helped ? "Passed, with gyro help" : "Passed" }
        return r.attempts == 1 ? "1 attempt" : "\(r.attempts) attempts"
    }
}

private func columnTitle(_ s: String) -> some View {
    Text(s).font(.system(size: 10.5, weight: .semibold)).tracking(1.5).foregroundColor(Theme.cream.opacity(0.6))
}

struct AcademyBrowser: View {
    @ObservedObject var m: HUDModel

    var body: some View {
        let progress = m.game.academyProgress
        let track = m.academyTrack, level = m.academyLevel
        let steps = AcademyCourse.steps(track, level), open = progress.open(track, level)
        let picked = steps.first { $0.id == m.academyStep } ?? steps.first { progress.records[$0.id]?.passed != true } ?? steps[0]
        let total = AcademyCourse.all.filter { progress.records[$0.id]?.passed == true }.count
        Sheet(m: m, title: "Flight Academy",
              subtitle: "\(total) of \(AcademyCourse.all.count) steps passed  ·  a step passes at \(AcademyRules.passMark)%, a chapter with \(AcademyRules.stepsToComplete) of its \(AcademyRules.stepsPerChapter) steps",
              back: .menu) {
            HStack(spacing: 0) {
                chapters(progress, track, level).frame(width: 236).padding(16)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                VStack(alignment: .leading, spacing: 8) {
                    columnTitle("STEPS, IN ANY ORDER")
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                        Button { m.academyStep = s.id } label: {
                            StepRow(number: i + 1, step: s, record: progress.records[s.id], open: open, selected: s.id == picked.id)
                        }
                        .buttonStyle(.plain).focusable(false)
                    }
                    if progress.complete(track, level) {
                        Label("Chapter complete", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(passGreen).padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 284).padding(16)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                Briefing(m: m, step: picked, open: open, record: progress.records[picked.id]).frame(maxWidth: .infinity)
            }
        }
    }

    private func chapters(_ progress: AcademyProgress, _ track: Track, _ level: Level) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Track.allCases, id: \.rawValue) { t in
                HStack(spacing: 7) {
                    Image(systemName: t.icon).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.red)
                    columnTitle(t.title.uppercased())
                }
                .padding(.top, t == .planes ? 0 : 14).padding(.bottom, 2)
                ForEach(Level.allCases, id: \.rawValue) { l in
                    Button { m.academyTrack = t; m.academyLevel = l; m.academyStep = "" } label: {
                        ChapterRow(level: l, passed: progress.passed(t, l), open: progress.open(t, l), complete: progress.complete(t, l), selected: t == track && l == level)
                    }
                    .buttonStyle(.plain).focusable(false)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct Briefing: View {
    @ObservedObject var m: HUDModel
    var step: AcademyStep
    var open: Bool
    var record: AcademyProgress.Record?

    private var weather: String {
        let w = step.weather
        guard w.wind > 0.1 else { return "Calm" }
        return String(format: "Wind %.1f m/s from %.0f°", w.wind, w.from) + (w.gusts > 0 ? ", gusty" : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(step.title).font(.system(size: 21, weight: .heavy)).foregroundColor(Theme.cream)
                    Text(step.goal).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Theme.cream.opacity(0.9)).fixedSize(horizontal: false, vertical: true)

                    columnTitle("WHAT YOU HAVE TO DO").padding(.top, 4)
                    ForEach(Array(step.tasks.enumerated()), id: \.offset) { i, t in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 11, weight: .heavy)).foregroundColor(Theme.red).frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.text).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.cream)
                                Text(t.measure).font(.system(size: 11)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    columnTitle("HOW").padding(.top, 4)
                    ForEach(Array(step.how.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.cream.opacity(0.5)).frame(width: 4, height: 4)
                            Text(line).font(.system(size: 12.5)).foregroundColor(Theme.cream.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    columnTitle("SET UP FOR YOU").padding(.top, 4)
                    VStack(spacing: 0) {
                        specRow("Aircraft", step.aircraft)
                        specRow("Scenery", step.site)
                        specRow("View", step.view.title)
                        specRow("Weather", weather)
                        specRow("Suggested gyro", step.gyroName)
                        specRow("Rates", step.highRates ? "High, for the figure" : "Low")
                        specRow("Time", String(format: "full marks within %.0f s, limit %.0f s", step.par, step.limit))
                    }
                    Text("The score is 80% precision and 20% time. More gyro help than suggested limits it to \(AcademyRules.passMark)%, which still passes.")
                        .font(.system(size: 11)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 12) {
                if let r = record {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Best \(r.best)%").font(.system(size: 14, weight: .heavy)).foregroundColor(r.passed ? passGreen : Theme.cream)
                        Text((r.attempts == 1 ? "1 attempt" : "\(r.attempts) attempts") + (r.bestTime.map { String(format: "  ·  quickest pass %.1f s", $0) } ?? "")).font(.system(size: 10.5)).foregroundColor(Theme.dim)
                    }
                }
                Spacer()
                if open {
                    let loading = m.game.pendingStep != nil
                    Button(loading ? "Loading…" : (record?.passed == true ? "Fly it again" : "Start step")) { m.game.startStep(step) }
                        .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).disabled(loading)
                } else {
                    Label("Pass \(AcademyRules.stepsToComplete) steps of \(Level(rawValue: step.level.rawValue - 1)?.title ?? "the level before") to open this chapter", systemImage: "lock.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.dim)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - In flight

struct AcademyPanel: View {
    var h: AcademyHUD

    private var throttleMarker: some View {
        let w: CGFloat = 260
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.cream.opacity(0.16)).frame(width: w, height: 8)
            Capsule().fill(passGreen.opacity(0.85)).frame(width: max(CGFloat(h.bandHigh - h.bandLow) * w, 6), height: 8).offset(x: CGFloat(h.bandLow) * w)
            RoundedRectangle(cornerRadius: 2).fill(Theme.cream).frame(width: 4, height: 16).offset(x: CGFloat(min(max(h.throttle, 0), 1)) * (w - 4))
        }
        .frame(width: w, height: 18)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                Text(h.title.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(1.2).foregroundColor(Theme.cream.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "timer").font(.system(size: 11, weight: .bold)).foregroundColor(h.hurry ? Theme.red : Theme.cream.opacity(0.7))
                Text(h.clock).font(.system(size: 15, weight: .heavy)).monospacedDigit().foregroundColor(h.hurry ? Theme.red : Theme.cream)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !h.count.isEmpty { Text(h.count).font(.system(size: 11, weight: .heavy)).foregroundColor(Theme.red) }
                Text(h.task).font(.system(size: 14.5, weight: .bold)).foregroundColor(Theme.cream).lineLimit(1)
                Spacer(minLength: 0)
            }
            if h.waiting {
                HStack(spacing: 10) {
                    throttleMarker
                    Spacer(minLength: 0)
                    Text(h.ready ? "Throttle ready" : "Move the throttle into the green")
                        .font(.system(size: 12, weight: .heavy)).foregroundColor(h.ready ? passGreen : Theme.cream)
                }
            } else {
                HStack(spacing: 8) {
                    Text(h.whereTo).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundColor(Theme.cream.opacity(0.85)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(h.progress).font(.system(size: 11.5, weight: .heavy)).monospacedDigit().foregroundColor(passGreen)
                }
            }
            if !h.note.isEmpty || h.gyroHelp {
                HStack(spacing: 8) {
                    Text(h.note).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Color(red: 1, green: 0.78, blue: 0.3)).lineLimit(1)
                    Spacer(minLength: 0)
                    if h.gyroHelp { Text("Gyro help: at most \(AcademyRules.passMark)%").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(red: 1, green: 0.78, blue: 0.3)) }
                }
            }
        }
        .frame(width: 520)
        .padding(.horizontal, 14).padding(.vertical, 9).glass(10)
    }
}

/// The count before a step: it stands at three until the throttle is in the green, runs down while it stays there,
/// and goes back to three if it leaves.
struct AcademyCountdown: View {
    var h: AcademyHUD
    static let height: CGFloat = 150
    var body: some View {
        let lit = h.go || h.ready
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(Theme.glass)
                Circle().stroke(Theme.cream.opacity(0.18), lineWidth: 7).padding(5)
                Circle().trim(from: 0, to: h.go ? 1 : CGFloat(h.countLeft))
                    .stroke(lit ? passGreen : Theme.cream.opacity(0.4), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(5)
                    .animation(h.ready && !h.go ? .linear(duration: 0.09) : nil, value: h.countLeft)
                Text(h.go ? "GO" : "\(max(h.countdown, 1))")
                    .font(.system(size: h.go ? 34 : 52, weight: .black, design: .rounded)).monospacedDigit()
                    .foregroundColor(lit ? passGreen : Theme.cream.opacity(0.6))
            }
            .frame(width: 112, height: 112)
            if !h.go {
                Text(h.ready ? "GET READY" : "THROTTLE INTO THE GREEN")
                    .font(.system(size: 11, weight: .heavy)).tracking(1.5).foregroundColor(Theme.cream)
                    .padding(.horizontal, 10).padding(.vertical, 5).glass(7)
            }
        }
        .frame(height: Self.height, alignment: .top)
    }
}

struct AcademyPauseView: View {
    @ObservedObject var m: HUDModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                columnTitle("FLIGHT ACADEMY")
                Text(m.game.attempt?.step.title ?? "").font(.system(size: 21, weight: .heavy)).foregroundColor(Theme.cream)
                Text("The clock has stopped.").font(.system(size: 12)).foregroundColor(Theme.dim)
                Button("Resume") { m.overlay = .none }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).padding(.top, 6)
                HStack(spacing: 8) {
                    Button("Restart step") { if let a = m.game.attempt { m.game.startStep(a.step) } }.buttonStyle(QuietButton())
                    Button("All steps") { m.game.openAcademy() }.buttonStyle(QuietButton())
                    Button("Leave the Academy") { m.game.closeAcademy() }.buttonStyle(QuietButton())
                }
            }
            .padding(26).glass(16, fill: Theme.panel)
        }
    }
}

struct AcademyResultView: View {
    @ObservedObject var m: HUDModel

    private func bar(_ title: String, _ percent: Int, weight: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.cream).frame(width: 70, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.cream.opacity(0.14)).frame(width: 220, height: 6)
                Capsule().fill(Theme.cream).frame(width: 220 * CGFloat(min(max(percent, 0), 100)) / 100, height: 6)
            }
            Text("\(percent)%").font(.system(size: 12.5, weight: .bold)).monospacedDigit().foregroundColor(Theme.cream).frame(width: 42, alignment: .trailing)
            Text(weight).font(.system(size: 11)).foregroundColor(Theme.dim)
        }
    }

    /// The next step to fly: one not passed yet in this chapter, or else in the level it opened.
    private func next(after step: AcademyStep) -> AcademyStep? {
        let p = m.game.academyProgress, steps = AcademyCourse.steps(step.track, step.level)
        let i = steps.firstIndex { $0.id == step.id } ?? 0
        let later = Array(steps[(i + 1)...]) + Array(steps[..<i])
        if !p.complete(step.track, step.level), let s = later.first(where: { p.records[$0.id]?.passed != true }) { return s }
        if let up = Level(rawValue: step.level.rawValue + 1), p.open(step.track, up),
           let s = AcademyCourse.steps(step.track, up).first(where: { p.records[$0.id]?.passed != true }) { return s }
        return later.first { p.records[$0.id]?.passed != true }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            if let a = m.game.attempt, let r = a.result {
                let p = m.game.academyProgress, step = a.step
                let following = r.passed ? next(after: step) : nil
                VStack(spacing: 11) {
                    columnTitle("\(step.track.title.uppercased())  ·  \(step.level.title.uppercased())")
                    Text(step.title).font(.system(size: 19, weight: .heavy)).foregroundColor(Theme.cream)
                    Text("\(r.score)%").font(.system(size: 62, weight: .black)).monospacedDigit().foregroundColor(r.passed ? passGreen : Theme.cream)
                    Text(r.passed ? "PASSED" : "NOT PASSED YET").font(.system(size: 13, weight: .heavy)).tracking(2).foregroundColor(r.passed ? passGreen : Theme.red)
                    if !r.reason.isEmpty { Text(r.reason).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.cream) }
                    VStack(alignment: .leading, spacing: 6) {
                        bar("Precision", r.precision, weight: "× 0.8")
                        bar("Time", r.timeScore, weight: "× 0.2")
                    }
                    .padding(.vertical, 4)
                    Text(String(format: "%.1f s  ·  best score %d%%", r.time, p.records[step.id]?.best ?? r.score)).font(.system(size: 11.5)).foregroundColor(Theme.dim)
                    if r.helped {
                        Text(r.capped ? "With gyro help: the score is limited to \(AcademyRules.passMark)%." : "With gyro help.").font(.system(size: 11.5)).foregroundColor(Theme.dim)
                    }
                    if p.complete(step.track, step.level) {
                        Text("\(step.level.title) complete" + (step.level == .professional ? "" : ": the next level is open"))
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(passGreen)
                    } else {
                        Text("\(p.passed(step.track, step.level)) of the \(AcademyRules.stepsToComplete) passes this chapter needs").font(.system(size: 11.5)).foregroundColor(Theme.dim)
                    }
                    if let n = following {
                        Button("Next: \(n.title)") {
                            m.academyTrack = n.track; m.academyLevel = n.level; m.academyStep = n.id
                            m.game.openAcademy()
                        }
                        .buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).padding(.top, 4)
                    } else {
                        Button("Try again") { m.game.startStep(step) }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction).padding(.top, 4)
                    }
                    HStack(spacing: 8) {
                        if following != nil { Button("Fly it again") { m.game.startStep(step) }.buttonStyle(QuietButton()) }
                        Button("Watch replay") { m.game.replayAttempt() }.buttonStyle(QuietButton())
                        Button("All steps") { m.game.openAcademy() }.buttonStyle(QuietButton())
                        Button("Main menu") { m.game.closeAcademy() }.buttonStyle(QuietButton())
                    }
                }
                .padding(26).glass(16, fill: Theme.panel)
            }
        }
    }
}
