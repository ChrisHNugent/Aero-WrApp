//
//  AeroWrapConnectView.swift
//
//  Aero Wrap — the "connect a device" front door.
//
//  Shown when no wrap is paired yet. Scans for nearby wraps over Bluetooth using
//  the Nordic `ThingyManager`, lists them as tappable clinical cards, connects on
//  tap, then hands the connected peripheral back to the existing Nordic plumbing
//  so the Live / Trends screen opens. The old Nordic "empty" screen stays in the
//  navigation stack underneath as an escape hatch.
//
//  Reuses Theme / SoftCard / SectionLabel / AeroAppBar / StepRow from
//  AeroWrapHomeView.swift (same module). Charts are not used here — see
//  AeroWrapHomeView for why Apple Swift Charts is unavailable in this repo.
//

import SwiftUI
import UIKit
import IOSThingyLibrary
import CoreBluetooth
import SWRevealViewController

// ─────────────────────────────────────────────
// MARK: - Scanner (data layer)
//
// Thin ObservableObject wrapper over ThingyManager's scan/connect flow. It
// temporarily becomes the manager's delegate (like ThingyCreatorViewController
// does) to receive discovery + connection callbacks, and publishes a simple
// phase the SwiftUI screen can render.
// ─────────────────────────────────────────────

final class WrapScanner: NSObject, ObservableObject, ThingyManagerDelegate, ThingyPeripheralDelegate {

    /// What the connect screen is currently doing.
    enum Phase: Equatable {
        case idle                 // not scanning (e.g. scan ended with nothing found)
        case scanning             // actively looking for wraps
        case connecting(String)   // associated value = device name
        case failed(String)       // associated value = user-facing message
        case bluetoothOff         // Bluetooth is unavailable / powered off
    }

    @Published var phase: Phase = .idle
    @Published private(set) var discovered: [ThingyPeripheral] = []

    private weak var manager: ThingyManager?
    private var connecting: ThingyPeripheral?
    private var scanTimeout: DispatchWorkItem?

    /// Called on the main thread once a peripheral reaches `.ready`.
    var onConnected: ((ThingyPeripheral) -> Void)?

    init(manager: ThingyManager?) {
        self.manager = manager
        super.init()
    }

    // MARK: Control

    func startScanning() {
        guard let manager else { phase = .bluetoothOff; return }
        discovered.removeAll()
        connecting = nil
        manager.delegate = self

        guard manager.centralManager?.state == .poweredOn else {
            // Wait for Bluetooth; the manager will report `.idle` once it powers
            // on (see `thingyManager(_:didChangeStateTo:)`), and we resume there.
            phase = .bluetoothOff
            return
        }
        beginScan()
    }

    private func beginScan() {
        guard let manager else { return }
        phase = .scanning
        manager.discoverDevices()   // no-op unless the manager is idle
        scheduleTimeout()
    }

    func stopScanning() {
        scanTimeout?.cancel()
        scanTimeout = nil
        manager?.stopScan()
        if case .scanning = phase { phase = .idle }
    }

    /// Re-run a scan (used by the "Scan again" / "Try again" buttons).
    func rescan() {
        startScanning()
    }

    func connect(_ peripheral: ThingyPeripheral) {
        guard let manager else { return }
        scanTimeout?.cancel()
        scanTimeout = nil
        manager.stopScan()
        connecting = peripheral
        peripheral.delegate = self
        phase = .connecting(peripheral.name)
        manager.connect(toDevice: peripheral)
    }

    private func scheduleTimeout() {
        scanTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .scanning = self.phase, self.discovered.isEmpty {
                self.manager?.stopScan()
                self.phase = .idle
            }
        }
        scanTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    // MARK: ThingyManagerDelegate

    func thingyManager(_ manager: ThingyManager, didChangeStateTo state: ThingyManagerState) {
        switch state {
        case .unavailable:
            phase = .bluetoothOff
        case .idle:
            // Bluetooth just became available (or a scan ended). If the user is
            // waiting on Bluetooth, start the scan now that the manager can.
            if phase == .bluetoothOff { beginScan() }
        default:
            break
        }
    }

    func thingyManager(_ manager: ThingyManager, didDiscoverPeripheral peripheral: ThingyPeripheral) {
        add(peripheral)
    }

    func thingyManager(_ manager: ThingyManager, didDiscoverPeripheral peripheral: ThingyPeripheral, withPairingCode: String?) {
        add(peripheral)
    }

    private func add(_ peripheral: ThingyPeripheral) {
        guard discovered.contains(peripheral) == false else { return }
        discovered.append(peripheral)
    }

    // MARK: ThingyPeripheralDelegate

    func thingyPeripheral(_ peripheral: ThingyPeripheral, didChangeStateTo state: ThingyPeripheralState) {
        guard let connecting, peripheral.isEqual(connecting) else { return }
        switch state {
        case .ready:
            self.connecting = nil
            onConnected?(peripheral)
        case .failedToConnect:
            phase = .failed("Couldn't connect to \(peripheral.name). Move closer to your phone and try again.")
            self.connecting = nil
        case .notSupported:
            phase = .failed("\(peripheral.name) isn't a supported wrap.")
            self.connecting = nil
        case .unavailable:
            phase = .failed("\(peripheral.name) became unavailable. Make sure it's charged and switched on.")
            self.connecting = nil
        case .disconnected:
            phase = .failed("\(peripheral.name) disconnected before setup finished. Please try again.")
            self.connecting = nil
        default:
            break   // .connecting / .discoveringServices / … — keep the spinner up
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Connect screen (SwiftUI)
// ─────────────────────────────────────────────

struct AeroWrapConnectView: View {
    @ObservedObject var scanner: WrapScanner
    var onBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            AeroAppBar(deviceName: nil, onBack: onBack)
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    if scanner.discovered.isEmpty == false {
                        deviceList
                    }
                    helpCard
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    // MARK: Status card

    private var statusCard: some View {
        SoftCard {
            VStack(spacing: 14) {
                statusGraphic
                Text(statusTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(statusSubtitle)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                statusAction
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var statusGraphic: some View {
        switch scanner.phase {
        case .scanning:
            ScanPulse()
        case .connecting:
            ZStack {
                Circle().fill(Theme.primary.opacity(0.10)).frame(width: 110, height: 110)
                ProgressView()
                    .scaleEffect(1.7)
                    .tint(Theme.primary)
            }
            .frame(width: 130, height: 130)
        case .bluetoothOff:
            IconBadge(symbol: "antenna.radiowaves.left.and.right.slash", tint: Theme.caution)
        case .failed:
            IconBadge(symbol: "exclamationmark.triangle.fill", tint: Theme.alert)
        case .idle:
            IconBadge(symbol: scanner.discovered.isEmpty ? "magnifyingglass" : "checkmark.circle.fill",
                      tint: scanner.discovered.isEmpty ? Theme.muted : Theme.normal)
        }
    }

    private var statusTitle: String {
        switch scanner.phase {
        case .scanning:
            return scanner.discovered.isEmpty ? "Looking for your wrap…" : "Tap your wrap to connect"
        case .connecting(let name):
            return "Connecting to \(name)…"
        case .bluetoothOff:
            return "Turn on Bluetooth"
        case .failed:
            return "Connection problem"
        case .idle:
            return scanner.discovered.isEmpty ? "No wraps found" : "Select your wrap"
        }
    }

    private var statusSubtitle: String {
        switch scanner.phase {
        case .scanning:
            return "Make sure the wrap is charged, switched on, and held close to your phone."
        case .connecting:
            return "Setting up your wrap. This only takes a few seconds."
        case .bluetoothOff:
            return "Aero Wrap connects over Bluetooth. Switch it on in Settings to find your wrap."
        case .failed(let message):
            return message
        case .idle:
            return scanner.discovered.isEmpty
                ? "We didn't detect a wrap nearby. Check the wrap is on, then scan again."
                : "Choose the wrap you'd like to connect to from the list below."
        }
    }

    @ViewBuilder private var statusAction: some View {
        switch scanner.phase {
        case .bluetoothOff:
            ConnectActionButton(title: "Open Settings", symbol: "gearshape.fill") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        case .failed:
            ConnectActionButton(title: "Try again", symbol: "arrow.clockwise") {
                scanner.rescan()
            }
        case .idle where scanner.discovered.isEmpty:
            ConnectActionButton(title: "Scan again", symbol: "arrow.clockwise") {
                scanner.rescan()
            }
        default:
            EmptyView()
        }
    }

    // MARK: Discovered devices

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Detected wraps")
            SoftCard(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(scanner.discovered.enumerated()), id: \.element) { index, peripheral in
                        WrapRow(
                            name: peripheral.name,
                            isConnecting: connectingName == peripheral.name,
                            disabled: isConnecting && connectingName != peripheral.name
                        ) {
                            scanner.connect(peripheral)
                        }
                        if index < scanner.discovered.count - 1 {
                            Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 60)
                        }
                    }
                }
            }
        }
    }

    private var connectingName: String? {
        if case let .connecting(name) = scanner.phase { return name }
        return nil
    }

    private var isConnecting: Bool { connectingName != nil }

    // MARK: Help

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Trouble connecting?")
            SoftCard(padding: 6) {
                VStack(spacing: 0) {
                    StepRow(number: 1, text: "Charge the wrap and switch it on. The indicator light comes on when it's ready to pair.", showDivider: true)
                    StepRow(number: 2, text: "Keep the wrap within a few feet of your phone while it connects.", showDivider: true)
                    StepRow(number: 3, text: "If nothing appears, turn Bluetooth off and on again in iPhone Settings.", showDivider: false)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Small reusable pieces
// ─────────────────────────────────────────────

/// Animated radar "ping": three expanding rings around a clinical-blue core.
/// Self-animates on appear, so it only runs while it's on screen (i.e. while
/// scanning). Uses value-based `.animation`, the same approach as the gauge.
private struct ScanPulse: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(Theme.primary.opacity(0.40), lineWidth: 2)
                    .scaleEffect(animate ? 1.0 : 0.40)
                    .opacity(animate ? 0.0 : 0.55)
                    .animation(
                        .easeOut(duration: 2.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(ring) * 0.8),
                        value: animate
                    )
            }
            Circle()
                .fill(LinearGradient(colors: [Theme.primary, Theme.primaryDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 58, height: 58)
                .overlay(
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                )
                .shadow(color: Theme.primary.opacity(0.40), radius: 10, x: 0, y: 6)
        }
        .frame(width: 130, height: 130)
        .onAppear { animate = true }
    }
}

/// A flat circular icon badge used for the non-animated status states.
private struct IconBadge: View {
    var symbol: String
    var tint: Color
    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.12)).frame(width: 96, height: 96)
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(tint)
        }
        .frame(width: 130, height: 130)
    }
}

/// One discovered-wrap row inside the device list card.
private struct WrapRow: View {
    var name: String
    var isConnecting: Bool
    var disabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.primary.opacity(0.10))
                        .frame(width: 42, height: 42)
                    Image(systemName: "badge.plus.radiowaves.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.primary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.ink)
                        .lineLimit(1)
                    Text(isConnecting ? "Connecting…" : "Tap to connect")
                        .font(.system(size: 12))
                        .foregroundColor(isConnecting ? Theme.primary : Theme.muted)
                }
                Spacer(minLength: 8)
                if isConnecting {
                    ProgressView().tint(Theme.primary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.faint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || isConnecting)
        .opacity(disabled ? 0.45 : 1)
    }
}

/// Full-width primary action button (matches the clinical blue theme).
private struct ConnectActionButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                Text(title).font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                LinearGradient(colors: [Theme.primary, Theme.primaryDeep],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Theme.primary.opacity(0.35), radius: 8, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

// ─────────────────────────────────────────────
// MARK: - UIKit bridge + live-screen handoff
// ─────────────────────────────────────────────

/// Hosts `AeroWrapConnectView` and owns the BLE scan lifecycle. While on screen
/// it temporarily takes over `ThingyManager.delegate`; on a successful connect it
/// restores the previous delegate, remembers the peripheral, swaps itself for the
/// live `AeroWrapHostingController` in place, and tells `RootViewController` about
/// the new active peripheral so the existing connect/disconnect plumbing kicks in.
final class AeroWrapConnectHostingController: UIHostingController<AeroWrapConnectView> {

    private let scanner: WrapScanner
    private weak var manager: ThingyManager?
    private var previousManagerDelegate: ThingyManagerDelegate?
    private var didHandOff = false

    init(manager: ThingyManager?) {
        self.manager = manager
        let scanner = WrapScanner(manager: manager)
        self.scanner = scanner
        super.init(rootView: AeroWrapConnectView(scanner: scanner))
        rootView.onBack = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
        scanner.onConnected = { [weak self] peripheral in
            self?.handleConnected(peripheral)
        }
    }

    required init?(coder: NSCoder) {
        let scanner = WrapScanner(manager: nil)
        self.scanner = scanner
        super.init(coder: coder, rootView: AeroWrapConnectView(scanner: scanner))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Match the light clinical screen background (#EEF2F6).
        view.backgroundColor = UIColor(red: 0xEE / 255.0,
                                       green: 0xF2 / 255.0,
                                       blue: 0xF6 / 255.0,
                                       alpha: 1)
    }

    // Hide the host nav bar so the Aero Wrap app bar can bleed into the notch,
    // and start scanning. Capture the manager's current delegate so we can hand
    // it back when we leave (or on a successful connect).
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        guard didHandOff == false, let manager else { return }
        previousManagerDelegate = manager.delegate
        scanner.startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        // If we're leaving without a handoff (user backed out), stop scanning and
        // give the manager's delegate back. After a handoff this is already done.
        if didHandOff == false {
            scanner.stopScanning()
            restorePreviousManagerDelegate()
        }
    }

    private func restorePreviousManagerDelegate() {
        if let previousManagerDelegate, let manager {
            manager.delegate = previousManagerDelegate
        }
    }

    private func handleConnected(_ peripheral: ThingyPeripheral) {
        guard let manager else { return }
        didHandOff = true
        scanner.stopScanning()
        restorePreviousManagerDelegate()
        manager.addPeripheral(peripheral)   // remember this wrap for next launch

        // Grab the reveal/root controller *before* we leave the nav stack — once
        // we're removed, `revealViewController()` can no longer resolve.
        let root = revealViewController() as? RootViewController

        // Swap this connect screen for the live Aero Wrap screen, in place, so the
        // Nordic "empty" screen stays underneath as the back target.
        let live = AeroWrapHostingController(peripheral: peripheral, manager: manager)
        if let nav = navigationController {
            var stack = nav.viewControllers
            if let index = stack.firstIndex(of: self) {
                stack[index] = live
            } else {
                stack.append(live)
            }
            nav.setViewControllers(stack, animated: true)
        }

        // Make the root treat this as the active peripheral: its didSet re-points
        // the peripheral delegate at the root and forwards state to the live
        // screen, so disconnects are handled exactly like the menu-launched flow.
        root?.targetPeripheral = peripheral
    }
}

// ─────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────

#Preview("Connect (offline)") {
    AeroWrapConnectView(scanner: WrapScanner(manager: nil))
}
