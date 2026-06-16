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

/// How the wrap is being driven from the control card.
enum ControlMode: String, CaseIterable, Identifiable {
    case hold = "Hold"
    case cycle = "Cycle"
    var id: String { rawValue }
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

/// A label with a − value + stepper, used for the cycle settings.
struct AdjustRow: View {
    var label: String
    var hint: String
    var value: String
    var enabled: Bool
    var dec: () -> Void
    var inc: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(Theme.ink)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
            }
            Spacer()
            HStack(spacing: 10) {
                stepButton("minus", dec)
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.ink)
                    .frame(minWidth: 52)
                stepButton("plus", inc)
            }
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Theme.primary)
                .frame(width: 30, height: 30)
                .background(Theme.surface)
                .clipShape(Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 1))
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
// MARK: - Shared app bar
// ─────────────────────────────────────────────

/// Branding bar shown above the tabs: optional back chevron, "AERO WRAP" +
/// device name, and the avatar. Pulled out of the Live screen so the Live and
/// Trends tabs can share one bar.
struct AeroAppBar: View {
    var deviceName: String?
    var onBack: (() -> Void)? = nil

    var body: some View {
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
                Text(deviceName ?? "No device")
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
}

// ─────────────────────────────────────────────
// MARK: - Pressure source (data layer)
//
// The seam between the UI and the hardware. The base class doubles as the
// "offline" implementation: not connected, controls disabled, no readings.
// ─────────────────────────────────────────────

/// One time-stamped pressure reading, used to draw the Trends graph.
struct PressureSample: Identifiable {
    let id = UUID()
    let t: Date
    let mmHg: Double
}

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
    /// Whether the wrap is currently running an inflate/deflate cycle.
    @Published var isCycling: Bool = false
    /// Display name of the device, if any.
    @Published var deviceName: String? = nil
    /// Rolling history of readings this session, for the Trends graph.
    @Published var history: [PressureSample] = []

    /// Newest sample wins after this many; keeps memory + the chart bounded.
    private let maxSamples = 1000
    /// Don't record faster than this (sensor can notify quickly).
    private let minSampleInterval: TimeInterval = 0.3
    private var lastSampleTime: Date = .distantPast

    /// Append a reading to `history` (throttled + trimmed). Subclasses call
    /// this whenever they publish a new `pressure` value.
    func recordSample(_ mmHg: Double, at time: Date = Date()) {
        guard time.timeIntervalSince(lastSampleTime) >= minSampleInterval else { return }
        lastSampleTime = time
        history.append(PressureSample(t: time, mmHg: mmHg))
        if history.count > maxSamples {
            history.removeFirst(history.count - maxSamples)
        }
    }

    /// Begin producing readings.
    func start() {}
    /// Send a one-shot inflate/deflate command to the wrap ("Hold" mode).
    func send(_ command: WrapCommand) {}
    /// Start cycling: inflate to `level`, hold for `dutyPercent` of each
    /// `periodMs` cycle, deflate for the rest, repeat ("Cycle" mode).
    func startCycle(level: WrapCommand, dutyPercent: UInt8, periodMs: UInt16) {}
    /// Stop cycling and vent the bladder.
    func stopCycle() {}
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
            self.recordSample(self.pressure)
        })
    }

    override func send(_ command: WrapCommand) {
        guard peripheral.state == .ready else { return }
        activeCommand = command
        isCycling = false   // a one-shot command ends any running cycle
        // The firmware reads the one-shot color as the inflate/deflate command.
        peripheral.turnOnOneShotLED(withCompletionHandler: { success in
            print("AeroWrap: command '\(command.rawValue)' sent: \(success)")
        }, intensity: 100, andPresetColor: command.ledPreset)
    }

    override func startCycle(level: WrapCommand, dutyPercent: UInt8, periodMs: UInt16) {
        guard peripheral.state == .ready else { return }
        activeCommand = level
        isCycling = true
        // Breathe-LED write = cycle command. Color picks the pressure level
        // (same mapping as one-shot); intensity = how much of each cycle the
        // bladder stays inflated; breathe delay = the cycle length in ms.
        peripheral.turnOnBreathingLED(withCompletionHandler: { success in
            print("AeroWrap: cycle started (\(level.rawValue), \(dutyPercent)% / \(periodMs)ms): \(success)")
        }, presetColor: level.ledPreset, intensity: dutyPercent, andBreatheDelay: periodMs)
    }

    override func stopCycle() {
        guard peripheral.state == .ready else { return }
        isCycling = false
        activeCommand = .deflate
        // Vent the bladder; a one-shot deflate also halts the cycle.
        peripheral.turnOnOneShotLED(withCompletionHandler: { success in
            print("AeroWrap: cycle stopped (deflate): \(success)")
        }, intensity: 100, andPresetColor: WrapCommand.deflate.ledPreset)
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

/// Simulated source for SwiftUI previews — eases toward a per-command target,
/// and pulses between the level and baseline when cycling.
final class MockPressureSource: PressureSource {
    private var timer: Timer?
    private let tick = 0.3
    private var target: Double = 0
    private var cycling = false
    private var cycleLevel: Double = 30
    private var cycleDuty: Double = 0.5     // fraction of period inflated
    private var cyclePeriod: Double = 3.5   // seconds
    private var cyclePhase: Double = 0

    override func start() {
        isConnected = true
        deviceName = "Preview"
        rawHPa = 978.9
        baselineHPa = 978.9
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.cycling {
                self.cyclePhase += self.tick
                if self.cyclePhase >= self.cyclePeriod { self.cyclePhase -= self.cyclePeriod }
                self.target = self.cyclePhase < self.cyclePeriod * self.cycleDuty ? self.cycleLevel : 0
            }
            let diff = self.target - self.pressure
            let noise = Double.random(in: -0.2...0.2)
            self.pressure = max(0, ((self.pressure + diff * 0.3 + noise) * 10).rounded() / 10)
            let perHPa = ThingyPressureSource.mmHgPerHPa * ThingyPressureSource.displayCalibration
            self.rawHPa = (self.baselineHPa ?? 978.9) + self.pressure / perHPa
            self.recordSample(self.pressure)
        }
    }

    private func levelTarget(_ c: WrapCommand) -> Double {
        switch c {
        case .low:     return 20
        case .medium:  return 30
        case .high:    return 42
        case .deflate: return 0
        }
    }

    override func send(_ command: WrapCommand) {
        cycling = false
        isCycling = false
        activeCommand = command
        target = levelTarget(command)
    }

    override func startCycle(level: WrapCommand, dutyPercent: UInt8, periodMs: UInt16) {
        activeCommand = level
        isCycling = true
        cycling = true
        cycleLevel = levelTarget(level)
        cycleDuty = Double(dutyPercent) / 100
        cyclePeriod = Double(periodMs) / 1000
        cyclePhase = 0
    }

    override func stopCycle() {
        cycling = false
        isCycling = false
        activeCommand = .deflate
        target = 0
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
    /// The shared data layer, owned by `AeroWrapRootView` and also observed by
    /// the Trends tab. Plain `PressureSource` = offline; `ThingyPressureSource`
    /// for a live device; `MockPressureSource` in previews.
    @ObservedObject var source: PressureSource

    @State private var blink = false

    // Control-card state
    @State private var mode: ControlMode = .hold
    @State private var selectedLevel: WrapCommand = .medium  // level used in Cycle mode
    @State private var dutyPercent: Double = 50              // % of each cycle inflated
    @State private var periodSeconds: Double = 3.5           // cycle length

    private let steps: [String] = [
        "Slip the wrap over your foot and rest the sensor flat against the inner ankle.",
        "Wrap firmly from the ankle upward with even overlap — no gaps or bunching.",
        "Pick a pressure level below. Use Hold to inflate and stay firm, or Cycle to gently pulse on and off. The device LED matches the button color.",
    ]

    private var inRange: Bool { source.pressure >= 20 && source.pressure <= 40 }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                header
                statusCard
                livePressureCard

                    VStack(spacing: 8) {
                        SectionLabel(text: "Compression")
                        controlCard
                    }

                    VStack(spacing: 8) {
                        SectionLabel(text: "Applying your wrap")
                        stepsCard
                    }
                }
                .padding(16)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        // (app bar + tab bar live in AeroWrapRootView; lifecycle starts there)
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { blink = true }
        }
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
            VStack(spacing: 12) {
                modeToggle
                levelPicker

                if mode == .hold {
                    deflateButton
                } else {
                    cycleControls
                }

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

    // Hold vs Cycle segmented toggle.
    private var modeToggle: some View {
        HStack(spacing: 0) {
            ForEach(ControlMode.allCases) { m in
                Button { mode = m } label: {
                    Text(m.rawValue)
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(mode == m ? .white : Theme.muted)
                        .background(mode == m ? Theme.primary : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        // Don't let the user leave Cycle mode while a cycle is running — they'd
        // lose the Stop button and the wrap would keep pulsing. Stop first.
        .disabled(source.isCycling)
        .opacity(source.isCycling ? 0.6 : 1)
    }

    // Low / Medium / High level buttons (shared by both modes).
    private var levelPicker: some View {
        HStack(spacing: 8) {
            ForEach(WrapCommand.inflateLevels) { cmd in
                LevelButton(command: cmd,
                            selected: mode == .hold ? source.activeCommand == cmd
                                                    : selectedLevel == cmd,
                            enabled: source.isConnected && !source.isCycling) {
                    selectedLevel = cmd
                    if mode == .hold { source.send(cmd) }   // Cycle mode applies on Start
                }
            }
        }
    }

    // Hold-mode deflate — full-width, destructive styling.
    private var deflateButton: some View {
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
    }

    // Cycle-mode settings + start/stop.
    private var cycleControls: some View {
        VStack(spacing: 10) {
            AdjustRow(label: "Inflated time",
                      hint: "how long it stays firm each cycle",
                      value: "\(Int(dutyPercent))%",
                      enabled: source.isConnected && !source.isCycling,
                      dec: { dutyPercent = max(20, dutyPercent - 5) },
                      inc: { dutyPercent = min(80, dutyPercent + 5) })

            Rectangle().fill(Theme.line).frame(height: 1)

            AdjustRow(label: "Cycle length",
                      hint: "one inflate-and-release",
                      value: String(format: "%.1fs", periodSeconds),
                      enabled: source.isConnected && !source.isCycling,
                      dec: { periodSeconds = max(2, periodSeconds - 0.5) },
                      inc: { periodSeconds = min(20, periodSeconds + 0.5) })

            Button {
                if source.isCycling {
                    source.stopCycle()
                } else {
                    source.startCycle(level: selectedLevel,
                                      dutyPercent: UInt8(dutyPercent),
                                      periodMs: UInt16(periodSeconds * 1000))
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: source.isCycling ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(source.isCycling ? "Stop cycling" : "Start cycling")
                        .font(.system(size: 14, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(.white)
                .background(source.isCycling ? Theme.alert : Theme.primary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!source.isConnected)
            .opacity(source.isConnected ? 1 : 0.45)

            if source.isCycling {
                Text("Cycling on \(selectedLevel.label) — \(Int(dutyPercent))% inflated, \(String(format: "%.1f", periodSeconds))s per cycle")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
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
// MARK: - Root container (Live + Trends tabs)
// ─────────────────────────────────────────────

/// Owns the shared `PressureSource` and hosts the bottom tab bar. The app bar
/// sits above the tabs so both screens share it, and the pressure stream is
/// started here (not per-tab) so it keeps running while you switch tabs.
struct AeroWrapRootView: View {
    @StateObject private var source: PressureSource
    var onBack: (() -> Void)? = nil
    @State private var tab = 0

    init(source: PressureSource = PressureSource(), onBack: (() -> Void)? = nil) {
        _source = StateObject(wrappedValue: source)
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            AeroAppBar(deviceName: source.deviceName, onBack: onBack)
            TabView(selection: $tab) {
                AeroWrapHomeView(source: source)
                    .tabItem { Label("Live", systemImage: "gauge") }
                    .tag(0)
                AeroWrapTrendsView(source: source)
                    .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                    .tag(1)
            }
            .tint(Theme.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { source.start() }
        .onDisappear { source.stop() }
    }
}

// ─────────────────────────────────────────────
// MARK: - Trends tab (pressure over time)
// ─────────────────────────────────────────────

struct AeroWrapTrendsView: View {
    @ObservedObject var source: PressureSource

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                header
                chartCard
                statsCard
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }

    // ── Heading ──────────────────────────────
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Trends")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(Theme.ink)
            Text("Pressure over this session")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    // ── Chart card ───────────────────────────
    private var chartCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PRESSURE OVER TIME")
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(Theme.muted)
                    Spacer()
                    Badge(label: source.isConnected ? "Live" : "Offline",
                          color: source.isConnected ? Theme.normal : Theme.faint)
                }
                if source.history.count >= 2 {
                    PressureChart(samples: source.history)
                        .frame(height: 200)
                } else {
                    emptyChart
                        .frame(height: 200)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyChart: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 28))
                .foregroundColor(Theme.faint)
            Text(source.isConnected ? "Collecting data…"
                                    : "Connect a wrap to start recording.")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // ── Quick session stats ──────────────────
    private var statsCard: some View {
        SoftCard {
            VStack(spacing: 12) {
                if let s = stats {
                    HStack(spacing: 0) {
                        StatCell(label: "Now", value: fmt(source.pressure))
                        StatCell(label: "Min", value: fmt(s.min))
                        StatCell(label: "Max", value: fmt(s.max))
                        StatCell(label: "Avg", value: fmt(s.avg))
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    HStack {
                        Text("Time in 20–40 mmHg range")
                            .font(.system(size: 12.5))
                            .foregroundColor(Theme.inkSoft)
                        Spacer()
                        Badge(label: "\(s.inRangePct)%",
                              color: s.inRangePct >= 60 ? Theme.normal : Theme.caution)
                    }
                } else {
                    Text("Stats appear once readings come in.")
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.0f", v) }

    /// Min / max / average / time-in-range over the session history.
    private var stats: (min: Double, max: Double, avg: Double, inRangePct: Int)? {
        let vals = source.history.map { $0.mmHg }
        guard !vals.isEmpty else { return nil }
        let mn = vals.min() ?? 0
        let mx = vals.max() ?? 0
        let avg = vals.reduce(0, +) / Double(vals.count)
        let inRange = vals.filter { $0 >= 20 && $0 <= 40 }.count
        let pct = Int((Double(inRange) / Double(vals.count) * 100).rounded())
        return (mn, mx, avg, pct)
    }
}

/// A compact stat: a big mono value over a small uppercase label.
struct StatCell: View {
    var label: String
    var value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.ink)
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.4)
                .foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

// ─────────────────────────────────────────────
// MARK: - Pressure history chart (hand-drawn)
//
// Drawn with plain SwiftUI Paths instead of Apple's Swift Charts: this app
// already links the third-party `Charts` CocoaPod (danielgindi/Charts) for the
// Nordic sensor screens, and its module is *also* named `Charts`, which shadows
// Apple's framework. So `import Charts` can't reach `Chart`/`LineMark`/etc. here.
// A hand-rolled chart sidesteps the collision and matches the gauge's approach.
// ─────────────────────────────────────────────

/// Line + area chart of pressure (mmHg) over time, with solid gridlines every
/// 20 mmHg and dashed green guides at the 20 and 40 mmHg edges of the
/// therapeutic band. Pure SwiftUI `Path` drawing (see note above).
struct PressureChart: View {
    var samples: [PressureSample]

    private let leftPad: CGFloat = 30   // room for the y-axis labels
    private let topPad: CGFloat = 4
    private let bottomPad: CGFloat = 4

    /// Top of the y-axis: at least 60, rounded up to the next 10 above the peak.
    private var yMax: Double {
        let peak = samples.map { $0.mmHg }.max() ?? 60
        return max(60, (peak / 10).rounded(.up) * 10)
    }

    /// Horizontal gridline values: 0, 20, 40, … up to `yMax`.
    private var yGuides: [Double] { Array(stride(from: 0, through: yMax, by: 20)) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // Gridlines + y-axis labels every 20 mmHg.
                ForEach(yGuides, id: \.self) { g in
                    let gy = yPos(g, size)
                    hLine(at: gy, in: size)
                        .stroke(Theme.line, lineWidth: 1)
                    Text("\(Int(g))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.faint)
                        .position(x: leftPad / 2, y: gy)
                }

                // Dashed therapeutic-band edges at 20 and 40 mmHg.
                ForEach([20.0, 40.0], id: \.self) { band in
                    hLine(at: yPos(band, size), in: size)
                        .stroke(Theme.normal.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                // Soft area fill under the trace.
                areaPath(size)
                    .fill(LinearGradient(colors: [Theme.primary.opacity(0.22),
                                                  Theme.primary.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))

                // The pressure trace.
                linePath(size)
                    .stroke(Theme.primary,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    // ── Coordinate mapping ───────────────────
    private func xPos(_ i: Int, _ size: CGSize) -> CGFloat {
        guard samples.count > 1 else { return leftPad }
        let plotW = max(size.width - leftPad, 1)
        return leftPad + plotW * CGFloat(i) / CGFloat(samples.count - 1)
    }

    private func yPos(_ v: Double, _ size: CGSize) -> CGFloat {
        let plotH = max(size.height - topPad - bottomPad, 1)
        let frac = min(max(v, 0), yMax) / yMax
        return topPad + plotH * CGFloat(1 - frac)
    }

    // ── Path builders ────────────────────────
    private func hLine(at y: CGFloat, in size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: leftPad, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
        }
    }

    private func linePath(_ size: CGSize) -> Path {
        Path { p in
            for (i, s) in samples.enumerated() {
                let pt = CGPoint(x: xPos(i, size), y: yPos(s.mmHg, size))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func areaPath(_ size: CGSize) -> Path {
        Path { p in
            guard !samples.isEmpty else { return }
            let bottom = yPos(0, size)
            p.move(to: CGPoint(x: xPos(0, size), y: bottom))
            for (i, s) in samples.enumerated() {
                p.addLine(to: CGPoint(x: xPos(i, size), y: yPos(s.mmHg, size)))
            }
            p.addLine(to: CGPoint(x: xPos(samples.count - 1, size), y: bottom))
            p.closeSubpath()
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
final class AeroWrapHostingController: UIHostingController<AeroWrapRootView>, HasThingyTarget {

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
        super.init(rootView: AeroWrapRootView(source: source))
        rootView.onBack = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
    }

    required init?(coder: NSCoder) {
        source = PressureSource()
        super.init(coder: coder, rootView: AeroWrapRootView(source: source))
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
    AeroWrapRootView(source: {
        let s = MockPressureSource()
        s.start()
        s.startCycle(level: .medium, dutyPercent: 50, periodMs: 3500)
        return s
    }())
}

#Preview("Trends (mock)") {
    AeroWrapTrendsView(source: {
        let s = MockPressureSource()
        let now = Date()
        for i in 0..<90 {
            s.recordSample(max(0, 30 + 10 * sin(Double(i) / 6)),
                           at: now.addingTimeInterval(Double(i - 90)))
        }
        s.start()
        return s
    }())
}

#Preview("Offline") {
    AeroWrapRootView()
}
