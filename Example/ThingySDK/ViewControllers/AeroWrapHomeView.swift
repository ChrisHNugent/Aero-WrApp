//
//  AeroWrapHomeView.swift
//  ThingySDK
//
//  Home / Monitor screen — SwiftUI port of the React "clinical" prototype,
//  now wired to a real Thingy:52.
//
//  ── How the device protocol works (per device team, June 2026) ──────────
//  The wrap runs custom firmware that repurposes the Thingy UI service:
//  writing a ONE-SHOT LED command with a preset color is the inflate command.
//    green  → inflate to the HIGHEST pressure level
//    yellow → inflate to the MIDDLE pressure level
//    blue   → inflate to the LOWEST pressure level
//    red    → DEFLATE the bladder
//  The device LED lights up in the matching color. Live pressure streams from
//  the environment service (`beginPressureUpdates`) in hPa (absolute,
//  barometric). The gauge shows pressure RELATIVE to a baseline captured when
//  the stream starts (hPa above baseline → mmHg, 1 hPa = 0.750062 mmHg).
//
//  The view only talks to a `PressureSource`. `ThingyPressureSource` is the
//  live BLE implementation; the plain base class is the "offline" state
//  (no device — controls disabled); `MockPressureSource` drives previews.
//

import SwiftUI
import IOSThingyLibrary

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
// MARK: - Wrap commands (the firmware protocol)
// ─────────────────────────────────────────────

/// The four things the wrap firmware can be told to do. Each maps to a
/// one-shot LED write with a preset color — that's the custom protocol.
enum WrapCommand: String, CaseIterable, Identifiable {
    case low, medium, high, deflate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low:     return "Low"
        case .medium:  return "Medium"
        case .high:    return "High"
        case .deflate: return "Deflate"
        }
    }

    var detail: String {
        switch self {
        case .low:     return "Lowest pressure"
        case .medium:  return "Middle pressure"
        case .high:    return "Highest pressure"
        case .deflate: return "Empty the bladder"
        }
    }

    /// LED preset the firmware interprets as this command (and lights up).
    var ledPreset: ThingyLEDColorPreset {
        switch self {
        case .low:     return .blue
        case .medium:  return .yellow
        case .high:    return .green
        case .deflate: return .red
        }
    }

    /// Dot shown on the button so the user can match it to the device LED.
    var ledColor: Color {
        switch self {
        case .low:     return Color(hex: "#2E86DE")
        case .medium:  return Color(hex: "#E0B30E")
        case .high:    return Color(hex: "#15A37A")
        case .deflate: return Theme.alert
        }
    }

    /// The three inflate levels, in display order.
    static var inflateLevels: [WrapCommand] { [.low, .medium, .high] }
}

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

/// Small uppercase section heading shown above a card (e.g. "INFLATE TO").
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

/// One of the three inflate-level buttons (Low / Medium / High).
struct LevelButton: View {
    var command: WrapCommand
    var selected: Bool
    var enabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(command.ledColor)
                        .frame(width: 9, height: 9)
                    Text(command.label)
                        .font(.system(size: 14, weight: .bold))
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                    }
                }
                Text(command.detail)
                    .font(.system(size: 10.5))
                    .opacity(selected ? 0.85 : 0.55)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
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
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
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
// The seam between the UI and the hardware. The base class doubles as the
// "offline" implementation: not connected, controls disabled, no readings.
// ─────────────────────────────────────────────

class PressureSource: ObservableObject {
    /// Pressure above baseline, in mmHg (the unit the gauge displays).
    @Published var pressure: Double = 0
    /// Last absolute barometer reading, hPa (shown small, for debugging).
    @Published var rawHPa: Double? = nil
    /// Baseline captured when the stream started / last re-zeroed, hPa.
    @Published var baselineHPa: Double? = nil
    /// Whether we currently have a live feed (drives the status dot).
    @Published var isConnected: Bool = false
    /// The last command sent (drives button highlighting).
    @Published var activeCommand: WrapCommand? = nil
    /// Display name of the device, if any.
    @Published var deviceName: String? = nil

    /// Begin producing readings.
    func start() {}
    /// Send an inflate/deflate command to the wrap.
    func send(_ command: WrapCommand) {}
    /// Re-capture the baseline from the current raw reading.
    func rezero() {}
    /// Tear down (timers, BLE notifications, …).
    func stop() {}
}

/// Live BLE implementation, backed by a connected Thingy:52.
///
/// * Pressure: `beginPressureUpdates` streams absolute hPa from the LPS22HB.
///   The first reading becomes the baseline; the published value is
///   (reading − baseline) converted to mmHg, clamped at 0.
/// * Control: one-shot LED writes — the custom firmware maps the preset color
///   to an inflate level (blue=low, yellow=mid, green=high) or deflate (red).
final class ThingyPressureSource: PressureSource {

    /// 1 hPa = 0.750062 mmHg (true physical conversion).
    static let mmHgPerHPa = 0.750062

    /// Empirical calibration. The sensor measures bladder AIR pressure, which
    /// overstates the compression actually applied to the leg: a full
    /// inflation (~1100 hPa absolute, ~120 hPa above baseline) is ~91 mmHg of
    /// air pressure but corresponds to roughly 20–30 mmHg of effective
    /// compression. 0.27 maps that full inflation to ~25 on the gauge.
    /// Tune this against a reference cuff gauge when one is available.
    static let displayCalibration = 0.27

    private let peripheral: ThingyPeripheral
    private weak var manager: ThingyManager?
    private var streaming = false

    init(peripheral: ThingyPeripheral, manager: ThingyManager?) {
        self.peripheral = peripheral
        self.manager = manager
        super.init()
        deviceName = peripheral.name
    }

    override func start() {
        switch peripheral.state {
        case .ready:
            beginUpdates()
        case .disconnected:
            // Mirror the main-menu behaviour: ask the manager to reconnect.
            // `thingyPeripheral(_:didChangeStateTo:)` on the hosting controller
            // calls back into `peripheralStateChanged` once it's ready.
            manager?.connect(toDevice: peripheral)
        default:
            break // connecting / discovering — wait for the .ready callback
        }
    }

    /// Called by the hosting controller when the peripheral's state changes.
    func peripheralStateChanged(to state: ThingyPeripheralState) {
        switch state {
        case .ready:
            beginUpdates()
        case .disconnected, .failedToConnect, .unavailable, .disconnecting, .notSupported:
            isConnected = false
            streaming = false
        default:
            break
        }
    }

    private func beginUpdates() {
        guard !streaming else { return }
        streaming = true
        peripheral.beginPressureUpdates(withCompletionHandler: { [weak self] success in
            self?.isConnected = success
            if !success { self?.streaming = false }
            print("AeroWrap: pressure notifications enabled: \(success)")
        }, andNotificationHandler: { [weak self] hPa in
            guard let self = self else { return }
            if self.baselineHPa == nil { self.baselineHPa = hPa }
            self.rawHPa = hPa
            self.isConnected = true
            let delta = (hPa - (self.baselineHPa ?? hPa)) * Self.mmHgPerHPa * Self.displayCalibration
            self.pressure = max(0, (delta * 10).rounded() / 10)
        })
    }

    override func send(_ command: WrapCommand) {
        guard peripheral.state == .ready else { return }
        activeCommand = command
        // The firmware reads the one-shot color as the inflate/deflate command.
        peripheral.turnOnOneShotLED(withCompletionHandler: { success in
            print("AeroWrap: command '\(command.rawValue)' sent: \(success)")
        }, intensity: 100, andPresetColor: command.ledPreset)
    }

    override func rezero() {
        if let raw = rawHPa {
            baselineHPa = raw
            pressure = 0
        }
    }

    override func stop() {
        streaming = false
        peripheral.stopPressureUpdates(withCompletionHandler: nil)
    }
}

/// Simulated source for SwiftUI previews — eases toward a per-command target.
final class MockPressureSource: PressureSource {
    private var timer: Timer?
    private var target: Double = 0

    override func start() {
        isConnected = true
        deviceName = "Preview"
        rawHPa = 978.9
        baselineHPa = 978.9
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let diff = self.target - self.pressure
            let noise = Double.random(in: -0.25...0.25)
            self.pressure = max(0, ((self.pressure + diff * 0.18 + noise) * 10).rounded() / 10)
            self.rawHPa = (self.baselineHPa ?? 978.9) + self.pressure / ThingyPressureSource.mmHgPerHPa
        }
    }

    override func send(_ command: WrapCommand) {
        activeCommand = command
        switch command {
        case .low:     target = 20
        case .medium:  target = 30
        case .high:    target = 42
        case .deflate: target = 0
        }
    }

    override func rezero() {
        baselineHPa = rawHPa
        pressure = 0
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

    /// The data layer. Plain `PressureSource` = offline; inject a
    /// `ThingyPressureSource` for a live device, `MockPressureSource` in previews.
    @StateObject private var source: PressureSource

    @State private var blink = false

    init(source: PressureSource = PressureSource(), onBack: (() -> Void)? = nil) {
        self.onBack = onBack
        _source = StateObject(wrappedValue: source)
    }

    private let steps: [String] = [
        "Slip the wrap over your foot and rest the sensor flat against the inner ankle.",
        "Wrap firmly from the ankle upward with even overlap — no gaps or bunching.",
        "Pick a pressure level below — the wrap inflates on its own. The device LED matches the button color.",
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
                        SectionLabel(text: "Inflate to")
                        controlCard
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
            source.start()
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
                Text(source.deviceName ?? "No device")
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
                Text(source.isConnected
                     ? (source.deviceName ?? "Thingy:52")
                     : "Connect from the menu")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
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
                    Badge(label: source.isConnected ? (inRange ? "In range" : "Adjusting") : "Offline",
                          color: source.isConnected ? (inRange ? Theme.normal : Theme.caution) : Theme.faint)
                }
                .padding(.bottom, 4)

                InstrumentGauge(value: source.pressure)
                    .frame(height: 150)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(source.isConnected ? String(format: "%.1f", source.pressure) : "––.–")
                        .font(.system(size: 46, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.ink)
                    Text("mmHg")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.muted)
                }
                .padding(.top, -8)

                Text("above baseline")
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.muted)
                    .padding(.top, 2)

                // Raw sensor line + re-zero — small, for first-device debugging.
                HStack(spacing: 10) {
                    Text(rawCaption)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Theme.faint)
                    if source.isConnected {
                        Button("Re-zero") { source.rezero() }
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(Theme.primary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var rawCaption: String {
        guard let raw = source.rawHPa else { return "no sensor data yet" }
        let base = source.baselineHPa.map { String(format: "%.1f", $0) } ?? "—"
        return String(format: "raw %.1f hPa · baseline %@ hPa", raw, base)
    }

    // ── Inflate / deflate control card ───────
    private var controlCard: some View {
        SoftCard(padding: 14) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(WrapCommand.inflateLevels) { cmd in
                        LevelButton(command: cmd,
                                    selected: source.activeCommand == cmd,
                                    enabled: source.isConnected) {
                            source.send(cmd)
                        }
                    }
                }

                // Deflate — full-width, destructive styling.
                Button {
                    source.send(.deflate)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Deflate")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(source.activeCommand == .deflate ? .white : Theme.alert)
                    .background(source.activeCommand == .deflate ? Theme.alert : Theme.alert.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.alert.opacity(source.activeCommand == .deflate ? 1 : 0.35),
                                    lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!source.isConnected)
                .opacity(source.isConnected ? 1 : 0.45)

                if !source.isConnected {
                    Text("Controls are disabled until a wrap is connected.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
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
/// let vc = AeroWrapHostingController(peripheral: targetPeripheral, manager: thingyManager)
/// navigationController?.pushViewController(vc, animated: true)
/// ```
///
/// Conforms to `HasThingyTarget` so `MainNavigationViewController` forwards
/// peripheral state changes (connect / disconnect) while this is on top.
final class AeroWrapHostingController: UIHostingController<AeroWrapHomeView>, HasThingyTarget {

    var thingyManager: ThingyManager?
    var targetPeripheral: ThingyPeripheral?

    private let source: PressureSource

    /// Pass the currently selected peripheral (or nil for the offline state,
    /// e.g. the simulator demo button).
    init(peripheral: ThingyPeripheral? = nil, manager: ThingyManager? = nil) {
        if let peripheral {
            source = ThingyPressureSource(peripheral: peripheral, manager: manager)
        } else {
            source = PressureSource()   // offline — controls disabled
        }
        targetPeripheral = peripheral
        thingyManager = manager
        super.init(rootView: AeroWrapHomeView(source: source))
        rootView.onBack = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
    }

    required init?(coder: NSCoder) {
        source = PressureSource()
        super.init(coder: coder, rootView: AeroWrapHomeView(source: source))
        rootView.onBack = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
    }

    // MARK: HasThingyTarget

    func setTargetPeripheral(_ aTargetPeripheral: ThingyPeripheral?, andManager aManager: ThingyManager?) {
        targetPeripheral = aTargetPeripheral
        thingyManager = aManager
        // The screen is built around the peripheral it was opened with; if the
        // user switches devices, pop back so it can be reopened cleanly.
        if aTargetPeripheral == nil {
            (source as? ThingyPressureSource)?.peripheralStateChanged(to: .disconnected)
        }
    }

    func thingyPeripheral(_ peripheral: ThingyPeripheral, didChangeStateTo state: ThingyPeripheralState) {
        (source as? ThingyPressureSource)?.peripheralStateChanged(to: state)
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
// MARK: - Previews
// ─────────────────────────────────────────────

#Preview("Live (mock)") {
    AeroWrapHomeView(source: MockPressureSource())
}

#Preview("Offline") {
    AeroWrapHomeView()
}
