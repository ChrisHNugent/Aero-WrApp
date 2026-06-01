//
//  AeroWrapHomeView.swift
//  ThingySDK
//
//  Home / Monitor screen - SwiftUI port of the React clinical UI.
//  Uses fake data so it can be developed and tested in the simulator
//  without a real Thingy:52 device connected.
//
//  To embed in the existing UIKit app, see AeroWrapHostingController at
//  the bottom of this file.
//

import SwiftUI

// ─────────────────────────────────────────────
// MARK: - Theme
// ─────────────────────────────────────────────

/// All colours used by the clinical UI, matching the React `C` object.
enum Theme {
    static let background   = Color(hex: "#0D1117")
    static let surface      = Color(hex: "#161B22")
    static let surfaceAlt   = Color(hex: "#1C2128")
    static let border       = Color(hex: "#30363D")
    static let borderLight  = Color(hex: "#21262D")
    static let textPrimary  = Color(hex: "#E6EDF3")
    static let textSecondary = Color(hex: "#7D8590")
    static let textMuted    = Color(hex: "#484F58")
    static let accent       = Color(hex: "#58A6FF")
    static let accentGreen  = Color(hex: "#3FB950")
    static let accentOrange = Color(hex: "#D29922")
    static let accentRed    = Color(hex: "#F85149")
    static let accentPurple = Color(hex: "#BC8CFF")
    static let gaugeTrack   = Color(hex: "#21262D")
    static let gaugeGreen   = Color(hex: "#238636")
    static let gaugeFill    = Color(hex: "#58A6FF")
}

extension Color {
    /// Convenience initialiser: `Color(hex: "#RRGGBB")` or `Color(hex: "#RRGGBBAA")`.
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
    let id      : String
    let label   : String
    let target  : Double   // mmHg
    let color   : Color
}

let presets: [Preset] = [
    Preset(id: "light",  label: "Light",  target: 20, color: Theme.accentGreen),
    Preset(id: "medium", label: "Medium", target: 30, color: Theme.accent),
    Preset(id: "firm",   label: "Firm",   target: 40, color: Theme.accentOrange),
    Preset(id: "max",    label: "Max",    target: 55, color: Theme.accentRed),
]

// ─────────────────────────────────────────────
// MARK: - Gauge
// ─────────────────────────────────────────────

/// Semicircular instrument gauge: flat side at the bottom, arc goes left → top → right.
/// Range 0-60 mmHg, green therapeutic band 20-40 mmHg.
struct GaugeView: View {
    var value   : Double        // current pressure
    var target  : Double        // target pressure
    var minVal  : Double = 0
    var maxVal  : Double = 60

    private let greenLo: Double = 20
    private let greenHi: Double = 40

    var body: some View {
        GeometryReader { geo in
            let w  = geo.size.width
            let h  = geo.size.height
            let cx = w / 2
            let cy = h * 0.88          // centre of the arc circle sits near the bottom
            let r  = min(w, h) * 0.42  // radius of the main arc

            ZStack {
                // ── Track (full semicircle, left → right going over the top)
                arcPath(cx: cx, cy: cy, r: r, from: minVal, to: maxVal)
                    .stroke(Theme.gaugeTrack, style: StrokeStyle(lineWidth: 14, lineCap: .round))

                // ── Green therapeutic band (20-40 mmHg)
                arcPath(cx: cx, cy: cy, r: r, from: greenLo, to: greenHi)
                    .stroke(Theme.gaugeGreen.opacity(0.55),
                            style: StrokeStyle(lineWidth: 10, lineCap: .butt))

                // ── Target tick mark
                targetTick(cx: cx, cy: cy, r: r)

                // ── Fill arc (0 → current value)
                if value > minVal {
                    arcPath(cx: cx, cy: cy, r: r, from: minVal, to: min(value, maxVal))
                        .stroke(fillColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                }

                // ── Centre readout
                VStack(spacing: 2) {
                    Text(String(format: "%.1f", value))
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .foregroundColor(fillColor)
                    Text("mmHg")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                .position(x: cx, y: cy - r * 0.22)

                // ── Min / max labels
                Text("\(Int(minVal))")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .position(x: cx - r - 12, y: cy + 6)

                Text("\(Int(maxVal))")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .position(x: cx + r + 12, y: cy + 6)
            }
        }
    }

    // ── Helpers ──────────────────────────────

    /// Colour of the fill arc: red if above therapeutic range, green if in range, blue otherwise.
    private var fillColor: Color {
        if value > greenHi  { return Theme.accentRed }
        if value >= greenLo { return Theme.accentGreen }
        return Theme.gaugeFill
    }

    /// Convert a pressure value to an angle in radians.
    /// 0 mmHg → 180° (left),  maxVal → 0° (right),  half → 90° (top).
    /// Using standard screen coords: angles measured clockwise from the positive x-axis.
    private func angle(for v: Double) -> Double {
        let fraction = (v - minVal) / (maxVal - minVal)
        // map 0→π  to  1→0  (arc sweeps from left (π) to right (0) via the top)
        return Double.pi - fraction * Double.pi
    }

    /// A point on the arc circle.
    private func arcPoint(cx: Double, cy: Double, r: Double, v: Double) -> CGPoint {
        let a = angle(for: v)
        return CGPoint(x: cx + r * cos(a), y: cy - r * sin(a))   // -sin: y grows downward
    }

    /// A Path that draws the arc from `from` to `to` going counterclockwise (over the top).
    private func arcPath(cx: Double, cy: Double, r: Double, from lo: Double, to hi: Double) -> Path {
        Path { p in
            let startAngle = Angle(radians: Double.pi - (lo - minVal) / (maxVal - minVal) * Double.pi)
            let endAngle   = Angle(radians: Double.pi - (hi - minVal) / (maxVal - minVal) * Double.pi)
            // clockwise: false = counterclockwise in screen coords = arc over the top
            p.addArc(center: CGPoint(x: cx, y: cy),
                     radius: r,
                     startAngle: startAngle,
                     endAngle: endAngle,
                     clockwise: true)   // SwiftUI flips Y, so true = counterclockwise visually
        }
    }

    /// A short radial tick mark at the target value.
    @ViewBuilder
    private func targetTick(cx: Double, cy: Double, r: Double) -> some View {
        let inner = arcPoint(cx: cx, cy: cy, r: r - 18, v: target)
        let outer = arcPoint(cx: cx, cy: cy, r: r + 4,  v: target)
        Path { p in
            p.move(to: inner)
            p.addLine(to: outer)
        }
        .stroke(Theme.accentOrange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}

// ─────────────────────────────────────────────
// MARK: - Reusable sub-views
// ─────────────────────────────────────────────

/// Rounded card panel used throughout the screen.
struct PanelView<Content: View>: View {
    var title  : String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .tracking(1.2)
            }
            content()
        }
        .padding(16)
        .background(Theme.surface)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

/// Small coloured badge (e.g. "ACTIVE", "THERAPEUTIC").
struct BadgeView: View {
    let label : String
    let color : Color

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(color.opacity(0.35), lineWidth: 1)
            )
    }
}

/// One of the four target preset buttons (Light / Medium / Firm / Max).
struct PresetButton: View {
    let preset    : Preset
    let isSelected: Bool
    let action    : () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(preset.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? preset.color : Theme.textSecondary)
                Text("\(Int(preset.target))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isSelected ? preset.color.opacity(0.8) : Theme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? preset.color.opacity(0.12) : Theme.surfaceAlt)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? preset.color.opacity(0.5) : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────
// MARK: - Main Home / Monitor screen
// ─────────────────────────────────────────────

struct AeroWrapHomeView: View {
    // ── State ────────────────────────────────
    @State private var currentPressure : Double = 0
    @State private var selectedPreset  : Preset = presets[1]   // "Medium" default
    @State private var sessionActive   : Bool   = false
    @State private var elapsedSeconds  : Int    = 0
    @State private var sessionTimer    : Timer? = nil
    @State private var simTimer        : Timer? = nil

    // ── Derived ──────────────────────────────
    private var statusLabel: String {
        if !sessionActive { return "STANDBY" }
        if currentPressure < selectedPreset.target - 2  { return "INFLATING" }
        if currentPressure > selectedPreset.target + 2  { return "DEFLATING" }
        return "THERAPEUTIC"
    }
    private var statusColor: Color {
        switch statusLabel {
        case "THERAPEUTIC": return Theme.accentGreen
        case "INFLATING":   return Theme.accent
        case "DEFLATING":   return Theme.accentOrange
        default:            return Theme.textMuted
        }
    }
    private var elapsedFormatted: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }
    private var targetReached: Bool {
        abs(currentPressure - selectedPreset.target) < 2
    }

    // ── Body ─────────────────────────────────
    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    headerBar
                    gaugePanel
                    statusRow
                    controlButton
                    presetsPanel
                    statsRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .onDisappear { stopSession() }
    }

    // ── Sub-sections ─────────────────────────

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AeroWrap")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("Compression Monitor")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            // Device status chip
            HStack(spacing: 6) {
                Circle()
                    .fill(sessionActive ? Theme.accentGreen : Theme.textMuted)
                    .frame(width: 7, height: 7)
                Text(sessionActive ? "Connected" : "No Device")
                    .font(.system(size: 12))
                    .foregroundColor(sessionActive ? Theme.accentGreen : Theme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surface)
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border, lineWidth: 1))
        }
        .padding(.top, 10)
    }

    private var gaugePanel: some View {
        PanelView {
            GaugeView(value: currentPressure, target: selectedPreset.target)
                .frame(height: 200)
                .padding(.top, 6)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            PanelView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("STATUS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .tracking(1.2)
                    BadgeView(label: statusLabel, color: statusColor)
                }
            }
            .frame(maxWidth: .infinity)

            PanelView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TARGET")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .tracking(1.2)
                    HStack(spacing: 4) {
                        Text(String(format: "%.0f", selectedPreset.target))
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(selectedPreset.color)
                        Text("mmHg")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            PanelView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SESSION")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                        .tracking(1.2)
                    Text(elapsedFormatted)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(sessionActive ? Theme.textPrimary : Theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var controlButton: some View {
        Button(action: sessionActive ? stopSession : startSession) {
            HStack(spacing: 8) {
                Image(systemName: sessionActive ? "stop.fill" : "play.fill")
                Text(sessionActive ? "Stop Session" : "Start Session")
                    .fontWeight(.semibold)
            }
            .foregroundColor(sessionActive ? Theme.accentRed : Theme.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(sessionActive ? Theme.accentRed.opacity(0.15) : Theme.accentGreen)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(sessionActive ? Theme.accentRed.opacity(0.5) : Color.clear,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var presetsPanel: some View {
        PanelView(title: "Target Preset") {
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    PresetButton(
                        preset: preset,
                        isSelected: selectedPreset.id == preset.id
                    ) {
                        selectedPreset = preset
                    }
                }
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            statTile(title: "Peak",
                     value: sessionActive ? String(format: "%.1f", currentPressure) : "--",
                     unit: "mmHg",
                     color: Theme.accentRed)
            statTile(title: "Time in Range",
                     value: targetReached && sessionActive ? "Active" : "--",
                     unit: "",
                     color: Theme.accentGreen)
            statTile(title: "Preset",
                     value: selectedPreset.label,
                     unit: "\(Int(selectedPreset.target)) mmHg",
                     color: selectedPreset.color)
        }
    }

    private func statTile(title: String, value: String, unit: String, color: Color) -> some View {
        PanelView {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                    .tracking(1.0)
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // ── Fake data simulation ──────────────────

    private func startSession() {
        sessionActive  = true
        elapsedSeconds = 0

        // Clock
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsedSeconds += 1
        }

        // Fake pressure: creeps toward target with small random noise
        simTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            let target = selectedPreset.target
            let diff   = target - currentPressure
            let step   = diff * 0.08                            // 8 % of remaining gap each tick
            let noise  = Double.random(in: -0.3...0.3)
            currentPressure = max(0, min(60, currentPressure + step + noise))
        }
    }

    private func stopSession() {
        sessionTimer?.invalidate(); sessionTimer = nil
        simTimer?.invalidate();     simTimer     = nil
        sessionActive  = false
        // Slowly bleed pressure back to 0
        simTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            currentPressure = max(0, currentPressure - 1.2)
            if currentPressure <= 0 { t.invalidate(); simTimer = nil }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - UIKit bridge
// ─────────────────────────────────────────────

/// Drop this UIHostingController into the existing UIKit navigation wherever
/// you want to show the new home screen.
///
/// Example (in a UIViewController):
/// ```swift
/// let vc = AeroWrapHostingController()
/// navigationController?.pushViewController(vc, animated: true)
/// ```
import UIKit

final class AeroWrapHostingController: UIHostingController<AeroWrapHomeView> {
    required init?(coder: NSCoder) {
        super.init(coder: coder, rootView: AeroWrapHomeView())
    }
    init() {
        super.init(rootView: AeroWrapHomeView())
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0x0D/255.0, green: 0x11/255.0, blue: 0x17/255.0, alpha: 1)
    }
}

// ─────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────

#Preview {
    AeroWrapHomeView()
}
