//
//  AeroWrapHomeView.swift
//  ThingySDK
//
//  Home / Monitor screen — SwiftUI port of the React "clinical" prototype.
//  Rebuilt to match the React reference: light clinical palette, instrument
//  needle gauge with reference band + ticks, preset grid, monospace readouts.
//
//  Uses fake data so it runs in the simulator with no Thingy:52 connected.
//  UIKit embedding helper is at the bottom (AeroWrapHostingController).
//
//  NOTE ON FONTS: the React design uses IBM Plex Sans / IBM Plex Mono.
//  Those aren't system fonts, so this file uses the system font with a
//  .monospaced design for the numeric readouts (visually very close). To get
//  a pixel-exact match, add the IBM Plex .ttf files to the app bundle and
//  swap the `.system(... design: .monospaced)` calls for `.custom("IBMPlexMono", ...)`.
//

import SwiftUI

// ─────────────────────────────────────────────
// MARK: - Theme  (matches the React `C` object — light "clinical")
// ─────────────────────────────────────────────

enum Theme {
    static let bg          = Color(hex: "#EEF2F6")   // screen background
    static let surface     = Color(hex: "#FFFFFF")   // cards
    static let surfaceAlt   = Color(hex: "#F4F8FB")  // chips / headers
    static let ink         = Color(hex: "#0E1A2B")   // primary text
    static let inkSoft     = Color(hex: "#33445A")   // body copy
    static let muted       = Color(hex: "#5E6E7F")
    static let faint       = Color(hex: "#9AA8B6")
    static let line        = Color(hex: "#E3EAF0")   // borders / track
    static let primary     = Color(hex: "#1C6FD6")   // clinical blue (needle, accents)
    static let primaryDeep = Color(hex: "#0E4FA3")
    static let blue        = Color(hex: "#2E86DE")
    static let normal      = Color(hex: "#15A37A")   // in-range green
    static let caution     = Color(hex: "#E0930E")   // amber
    static let alert       = Color(hex: "#E25555")   // red
}

extension Color {
    /// `Color(hex: "#RRGGBB")` or `Color(hex: "#RRGGBBAA")`.
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        let value = UInt64(h, radix: 16) ?? 0
        let r, g, b, a: Double
        switch h.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >>  8) & 0xFF) / 255
            b = Double( value        & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >>  8) & 0xFF) / 255
            a = Double( value        & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0; a = 1
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}

// ─────────────────────────────────────────────
// MARK: - Preset model
// ─────────────────────────────────────────────

struct Preset: Identifiable {
    let id = UUID()
    let label: String
    let value: Double      // mmHg
    let range: String
}

let presets: [Preset] = [
    Preset(label: "Light",  value: 20, range: "15–20"),
    Preset(label: "Medium", value: 30, range: "20–30"),
    Preset(label: "Firm",   value: 40, range: "30–40"),
    Preset(label: "Max",    value: 50, range: "40–50"),
]

// ─────────────────────────────────────────────
// MARK: - Gauge geometry
//
// One source of truth for converting a pressure value -> screen point on a
// top-facing semicircle. v=min sits at the left baseline, v=max at the right
// baseline, v=mid at the top. Y is flipped here (cy - r*sin) so the arc bows
// UP. Everything (track, band, ticks, needle, hub) uses this, so it can never
// disagree with itself — no `addArc` / `clockwise` ambiguity.
// ─────────────────────────────────────────────

enum GaugeMath {
    static let minV = 0.0
    static let maxV = 60.0

    static func geom(_ size: CGSize) -> (cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let w = size.width, h = size.height
        let r = min(w / 2 - 30, h - 28)          // leave room for side labels & top
        return (w / 2, h - 16, max(r, 1))         // center near the bottom edge
    }

    static func point(_ v: Double, _ size: CGSize, inset: CGFloat = 0) -> CGPoint {
        let g = geom(size)
        let r = g.r - inset
        let frac = (min(max(v, minV), maxV) - minV) / (maxV - minV)
        let a = Double.pi * (1 - frac)            // π (left) -> 0 (right), via top
        return CGPoint(x: g.cx + r * CGFloat(cos(a)),
                       y: g.cy - r * CGFloat(sin(a)))   // -sin => bow upward
    }
}

/// A stroked arc sampled as a polyline (predictable in any coordinate system).
struct ArcStroke: Shape {
    var v0: Double
    var v1: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = 90
        for i in 0...n {
            let v = v0 + (v1 - v0) * Double(i) / Double(n)
            let q = GaugeMath.point(v, rect.size)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }
}

/// Short radial tick marks just inside the track.
struct TicksStroke: Shape {
    var ticks: [Double]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for t in ticks {
            p.move(to: GaugeMath.point(t, rect.size, inset: 18))
            p.addLine(to: GaugeMath.point(t, rect.size, inset: 8))
        }
        return p
    }
}

/// The needle — animatable on `value` so it sweeps smoothly.
struct Needle: Shape {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let g = GaugeMath.geom(rect.size)
        var p = Path()
        p.move(to: CGPoint(x: g.cx, y: g.cy))
        p.addLine(to: GaugeMath.point(value, rect.size, inset: 20))
        return p
    }
}

// ─────────────────────────────────────────────
// MARK: - Instrument gauge
// ─────────────────────────────────────────────

struct InstrumentGauge: View {
    var value: Double
    var target: Double
    private let ticks: [Double] = [0, 10, 20, 30, 40, 50, 60]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let g = GaugeMath.geom(size)

            ZStack {
                // Track (full semicircle)
                ArcStroke(v0: 0, v1: 60)
                    .stroke(Theme.line, style: StrokeStyle(lineWidth: 13, lineCap: .round))

                // Therapeutic band 20–40
                ArcStroke(v0: 20, v1: 40)
                    .stroke(Theme.normal.opacity(0.85), style: StrokeStyle(lineWidth: 13, lineCap: .butt))

                // Tick marks
                TicksStroke(ticks: ticks)
                    .stroke(Theme.faint, lineWidth: 1.5)

                // Tick labels (inside the arc)
                ForEach(ticks, id: \.self) { t in
                    Text("\(Int(t))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.muted)
                        .position(GaugeMath.point(t, size, inset: 32))
                }

                // Needle
                Needle(value: value)
                    .stroke(Theme.primary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .animation(.easeInOut(duration: 0.7), value: value)

                // Hub
                Circle().fill(Theme.primary).frame(width: 14, height: 14)
                    .position(x: g.cx, y: g.cy)
                Circle().fill(Theme.surface).frame(width: 6, height: 6)
                    .position(x: g.cx, y: g.cy)
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Reusable sub-views
// ─────────────────────────────────────────────

/// Soft rounded card with a hairline border and a subtle drop shadow —
/// the `Card` primitive from the React design.
struct SoftCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Color(hex: "#102846").opacity(0.06), radius: 13, x: 0, y: 8)
    }
}

/// Small uppercase section heading shown above a card (e.g. "SET TARGET …").
struct SectionLabel: View {
    var text: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(0.5)
                .foregroundColor(Theme.muted)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 4)
    }
}

struct Badge: View {
    var label: String
    var color: Color
    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.094))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.25), lineWidth: 1))
    }
}

struct PresetButton: View {
    var preset: Preset
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(preset.label)
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                    }
                }
                Text("\(Int(preset.value))")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .padding(.top, 2)
                Text("\(preset.range) mmHg")
                    .font(.system(size: 10.5, design: .monospaced))
                    .opacity(selected ? 0.85 : 0.55)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundColor(selected ? .white : Theme.ink)
            .background(selected ? Theme.primary : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.primary : Theme.line, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// One numbered "Applying your wrap" instruction row.
struct StepRow: View {
    var number: Int
    var text: String
    var showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.primary)
                    .frame(width: 26, height: 26)
                    .background(Theme.primary.opacity(0.08))
                    .clipShape(Circle())
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.inkSoft)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 14)
            if showDivider {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Pressure source (data layer)
//
// One small seam between the UI and wherever the numbers come from. The view
// only ever talks to a `PressureSource`; it neither knows nor cares whether the
// readings are faked or arriving over Bluetooth.
//
// Today the app ships `MockPressureSource` (a timer that eases toward the
// target with a little noise — the old `startSim()` behaviour, lifted out of
// the view). When the BLE protocol is known, add a `ThingyPressureSource:
// PressureSource` that wraps `beginPressureUpdates` and converts hPa→mmHg, then
// swap the default in one line (see `AeroWrapHomeView.init`). Nothing in the
// view changes.
// ─────────────────────────────────────────────

/// Base class so the view can hold it as a single `@StateObject` while the
/// concrete implementation (mock now, real BLE later) is injected.
class PressureSource: ObservableObject {
    /// Latest reading in mmHg (the unit the gauge displays).
    @Published var pressure: Double = 40
    /// Whether we currently have a live feed (drives the status dot / "LIVE").
    @Published var isConnected: Bool = false

    /// Begin producing readings, aiming at `target` mmHg.
    func start(target: Double) {}
    /// The user picked a new target compression.
    func updateTarget(_ target: Double) {}
    /// Tear down (timers, BLE notifications, …).
    func stop() {}
}

/// Simulated source: no hardware required, so the screen is fully usable in the
/// simulator. Eases the reading toward the target with small random noise.
final class MockPressureSource: PressureSource {
    private var timer: Timer?
    private var target: Double = 40

    override func start(target: Double) {
        self.target = target
        pressure = target
        isConnected = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            guard let self else { return }
            let diff = self.target - self.pressure
            let noise = Double.random(in: -0.25...0.25)
            self.pressure = ((self.pressure + diff * 0.18 + noise) * 10).rounded() / 10
        }
    }

    override func updateTarget(_ target: Double) {
        self.target = target
    }

    override func stop() {
        timer?.invalidate()
        timer = nil
        isConnected = false
    }
}

// ─────────────────────────────────────────────
// MARK: - Main Home / Monitor screen
// ─────────────────────────────────────────────

struct AeroWrapHomeView: View {
    /// Optional "go back" action. When set (e.g. when pushed onto a UIKit nav
    /// stack), a back chevron is shown in the app bar. Left nil in previews.
    var onBack: (() -> Void)? = nil

    /// The data layer. Defaults to the mock; inject a `ThingyPressureSource`
    /// here once the BLE protocol is wired up.
    @StateObject private var source: PressureSource

    @State private var selectedTarget: Double = 40    // "Firm" default
    @State private var blink = false

    init(source: PressureSource = MockPressureSource(), onBack: (() -> Void)? = nil) {
        self.onBack = onBack
        _source = StateObject(wrappedValue: source)
    }

    private let steps: [String] = [
        "Slip the wrap over your foot and rest the sensor flat against the inner ankle.",
        "Wrap firmly from the ankle upward with even overlap — no gaps or bunching.",
        "Pick a target below and adjust tension until the gauge sits in the green band.",
    ]

    private var inRange: Bool { source.pressure >= 20 && source.pressure <= 40 }

    var body: some View {
        VStack(spacing: 0) {
            appBar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    statusCard
                    livePressureCard

                    VStack(spacing: 8) {
                        SectionLabel(text: "Set target compression")
                        targetCard
                    }

                    VStack(spacing: 8) {
                        SectionLabel(text: "Applying your wrap")
                        stepsCard
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { blink = true }
            source.start(target: selectedTarget)
        }
        .onChange(of: selectedTarget) { newValue in
            source.updateTarget(newValue)
        }
        .onDisappear { source.stop() }
    }

    // ── App bar (branding + avatar) ──────────
    private var appBar: some View {
        HStack(alignment: .center) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.primary)
                        .frame(width: 28, height: 28, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AERO WRAP")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Theme.primary)
                Text("Left leg · Sensor A4-19")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.faint)
            }
            Spacer()
            Text("MR")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(
                    LinearGradient(colors: [Theme.primary, Theme.primaryDeep],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(Circle())
                .shadow(color: Theme.primary.opacity(0.5), radius: 6, x: 0, y: 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.ignoresSafeArea(edges: .top))   // white into the notch
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    // ── Screen heading ───────────────────────
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Live monitor")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(Theme.ink)
            Text("Real-time sub-wrap pressure")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    // ── Connection status card ───────────────
    private var statusCard: some View {
        SoftCard(padding: 14) {
            HStack(spacing: 9) {
                Circle().fill(source.isConnected ? Theme.normal : Theme.faint)
                    .frame(width: 9, height: 9)
                    .opacity(source.isConnected && blink ? 0.3 : 1)
                Text(source.isConnected ? "Sensor connected" : "Sensor offline")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.ink)
                Spacer()
                Text(source.isConnected ? "Thingy:52 · −58 dBm · 82%" : "Searching…")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Theme.muted)
            }
        }
    }

    // ── Live pressure card ───────────────────
    private var livePressureCard: some View {
        SoftCard {
            VStack(spacing: 0) {
                HStack {
                    Text("LIVE PRESSURE")
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(Theme.muted)
                    Spacer()
                    Badge(label: inRange ? "In range" : "Adjusting",
                          color: inRange ? Theme.normal : Theme.caution)
                }
                .padding(.bottom, 4)

                InstrumentGauge(value: source.pressure, target: selectedTarget)
                    .frame(height: 150)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", source.pressure))
                        .font(.system(size: 46, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.ink)
                    Text("mmHg")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.muted)
                }
                .padding(.top, -8)

                HStack(spacing: 4) {
                    Text("Target").foregroundColor(Theme.muted)
                    Text("\(Int(selectedTarget))")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.primary)
                    Text("mmHg").foregroundColor(Theme.muted)
                }
                .font(.system(size: 12.5))
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // ── Preset grid card ─────────────────────
    private var targetCard: some View {
        SoftCard(padding: 14) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8),
                          GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(presets) { p in
                    PresetButton(preset: p, selected: selectedTarget == p.value) {
                        selectedTarget = p.value
                    }
                }
            }
        }
    }

    // ── Applying-your-wrap steps card ────────
    private var stepsCard: some View {
        SoftCard {
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { idx, text in
                    StepRow(number: idx + 1,
                            text: text,
                            showDivider: idx < steps.count - 1)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - UIKit bridge
// ─────────────────────────────────────────────

import UIKit

/// Drop this UIHostingController into the existing UIKit navigation.
///
/// ```swift
/// let vc = AeroWrapHostingController()
/// navigationController?.setNavigationBarHidden(true, animated: false) // app bar is built in
/// navigationController?.pushViewController(vc, animated: true)
/// ```
final class AeroWrapHostingController: UIHostingController<AeroWrapHomeView> {
    required init?(coder: NSCoder) {
        super.init(coder: coder, rootView: AeroWrapHomeView())
        rootView.onBack = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
    }
    init() {
        super.init(rootView: AeroWrapHomeView())
        rootView.onBack = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        // Match the light clinical screen background (#EEF2F6).
        view.backgroundColor = UIColor(red: 0xEE / 255.0,
                                       green: 0xF2 / 255.0,
                                       blue: 0xF6 / 255.0,
                                       alpha: 1)
    }

    // Hide the host nav bar so the built-in app bar can bleed into the notch,
    // but keep the left-edge swipe-to-go-back gesture alive. Restore the bar
    // on the way out so the Nordic screens look unchanged.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactivePopGestureRecognizer?.delegate = self
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
    }
}

extension AeroWrapHostingController: UIGestureRecognizerDelegate {
    // Allow the edge-swipe pop only when there's somewhere to go back to.
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return (navigationController?.viewControllers.count ?? 0) > 1
    }
}

// ─────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────

#Preview {
    AeroWrapHomeView()
}
