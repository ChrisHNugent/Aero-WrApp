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
    static let bg          = Color(hex: "#EBEFF3")   // screen background
    static let surface     = Color(hex: "#FFFFFF")   // panels
    static let surfaceAlt   = Color(hex: "#F4F7FA")  // panel headers / chips
    static let ink         = Color(hex: "#0F1B2D")   // primary text
    static let muted       = Color(hex: "#5B6B7C")
    static let faint       = Color(hex: "#8A99A8")
    static let line        = Color(hex: "#DBE3EA")   // borders / track
    static let primary     = Color(hex: "#0E5AA7")   // clinical blue (needle, accents)
    static let primaryDeep = Color(hex: "#0A4178")
    static let blue        = Color(hex: "#2E86DE")
    static let normal      = Color(hex: "#138A6B")   // in-range green
    static let caution     = Color(hex: "#C98A00")   // amber
    static let alert       = Color(hex: "#D64545")   // red
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

struct Panel<Content: View>: View {
    var title: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(Theme.muted)
                    Spacer()
                    if let trailing { trailing }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(Theme.surfaceAlt)

                Rectangle().fill(Theme.line).frame(height: 1)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
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
            .background(color.opacity(0.10))
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
                        Text("●").font(.system(size: 11))
                    }
                }
                Text("\(Int(preset.value))")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                Text("\(preset.range) mmHg")
                    .font(.system(size: 10.5, design: .monospaced))
                    .opacity(selected ? 0.85 : 0.55)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundColor(selected ? .white : Theme.ink)
            .background(selected ? Theme.primary : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Theme.primary : Theme.line, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────
// MARK: - Main Home / Monitor screen
// ─────────────────────────────────────────────

struct AeroWrapHomeView: View {
    /// Optional "go back" action. When set (e.g. when pushed onto a UIKit nav
    /// stack), a back chevron is shown in the app bar. Left nil in previews.
    var onBack: (() -> Void)? = nil

    @State private var pressure: Double = 40          // starts at target like the React version
    @State private var selectedTarget: Double = 40    // "Firm" default
    @State private var blink = false
    @State private var simTimer: Timer? = nil

    private var rangeBadge: (String, Color) {
        if pressure > 40 { return ("High", Theme.alert) }
        if pressure < 20 { return ("Low", Theme.caution) }
        return ("In range", Theme.normal)
    }

    var body: some View {
        VStack(spacing: 0) {
            appBar
            statusRow
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    livePressurePanel
                    targetPanel
                    bottomRow
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { blink = true }
            startSim()
        }
        .onDisappear { simTimer?.invalidate(); simTimer = nil }
    }

    // ── App bar ──────────────────────────────
    private var appBar: some View {
        HStack(alignment: .top) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.primary)
                        .frame(width: 30, height: 30, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("AERO WRAP · v1.0")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Theme.primary)
                Text("Monitor")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Theme.ink)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("LEFT LEG")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.muted)
                Text("Sensor #A4-19")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.faint)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.ignoresSafeArea(edges: .top))   // white into the notch
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    // ── Status row ───────────────────────────
    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.normal).frame(width: 8, height: 8)
                .opacity(blink ? 0.35 : 1)
            Text("Sensor connected")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("·").foregroundColor(Theme.faint)
            Text("Thingy:52 · −58 dBm")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(Theme.muted)
            Spacer()
            Text("LIVE")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(Theme.faint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Theme.surfaceAlt)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }

    // ── Live pressure ────────────────────────
    private var livePressurePanel: some View {
        Panel(title: "Live pressure",
              trailing: AnyView(Badge(label: rangeBadge.0, color: rangeBadge.1))) {
            VStack(spacing: 2) {
                InstrumentGauge(value: pressure, target: selectedTarget)
                    .frame(height: 150)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", pressure))
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.ink)
                    Text("mmHg")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.muted)
                }

                HStack(spacing: 4) {
                    Text("Target").foregroundColor(Theme.muted)
                    Text("\(Int(selectedTarget))")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.primary)
                    Text("· Normal band 20–40").foregroundColor(Theme.muted)
                }
                .font(.system(size: 12.5))
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // ── Set target compression ───────────────
    private var targetPanel: some View {
        Panel(title: "Set target compression") {
            VStack(spacing: 8) {
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

                Button(action: {}) {
                    Text("+ Custom value")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundColor(Theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ── Session / Last sync ──────────────────
    private var bottomRow: some View {
        HStack(spacing: 14) {
            Panel(title: "Session") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("02:14")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.ink)
                    Text("elapsed")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity)

            Panel(title: "Last sync") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("2s")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.ink)
                    Text("ago")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // ── Fake data simulation (mirrors the React useEffect) ──
    private func startSim() {
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { _ in
            let diff = selectedTarget - pressure
            let noise = Double.random(in: -0.25...0.25)
            pressure = ((pressure + diff * 0.18 + noise) * 10).rounded() / 10
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
        // Match the light clinical screen background (#EBEFF3).
        view.backgroundColor = UIColor(red: 0xEB / 255.0,
                                       green: 0xEF / 255.0,
                                       blue: 0xF3 / 255.0,
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
