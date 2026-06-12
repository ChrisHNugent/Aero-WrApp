# Aero-WrApp — Project Handoff

_Last updated: 2026-06-12_

A working-context document so a new chat can pick up exactly where this one left off.

---

## 1. What this project is

`Aero-WrApp` is a **fork of the Nordic Thingy:52 iOS app** (an 8-year-old, storyboard-based UIKit codebase) being refactored into the front end for a **leg-compression medical device**.

The device is an **inflatable leg-compression wrap** driven by a **Thingy:52 + pressure sensor**. The intended product flow:

1. Inflate the wrap to a **set target pressure** using the Thingy:52.
2. Monitor pressure changes over time to tell the user about **swelling reduction, activity levels, wear consistency**, etc.

**Guiding constraint (important):** keep as much of the baseline/backend Nordic code intact as possible. Only change the **front end / how data is displayed** — add new screens rather than rewriting the backend. Change the app root only if unavoidable.

---

## 2. Tech context

- Legacy app: **storyboard-based UIKit**, `SWRevealViewController` sidebar, custom `SetRootViewSegue` segues, targets older iOS.
- New screens are **SwiftUI**, bridged into UIKit via a `UIHostingController` subclass.
- BLE is provided by **`IOSThingyLibrary`** (the Nordic SDK already vendored in the repo).
- Bundle ID changed for personal-team signing: **`com.chrisnugent.aerowrap`**.

### Key SDK facts (from reading IOSThingyLibrary)
- Pressure: `ThingyPeripheral.beginPressureUpdates(withCompletionHandler:andNotificationHandler:)` → callback `pressureInHectoPascal: Double` (**hPa**, from the LPS22HB barometer).
- LED control: `turnOnConstantLED` / `turnOffLED` / presets.
- Button notifications: `beginButtonStateNotifications` → `ThingyButtonState`.

---

## 3. What's been built so far

### a) SwiftUI Live/Monitor screen — `AeroWrapHomeView.swift`
Location: `Example/ThingySDK/ViewControllers/AeroWrapHomeView.swift`

Currently styled to match the **"Live" tab of the newer softer React design** (clinical palette, rounded soft-shadow cards, instrument needle gauge, In-range/Adjusting badge, preset grid, "Applying your wrap" numbered steps).

Contains, top to bottom:
- `Theme` enum — soft clinical palette (screen `#EEF2F6`, primary `#1C6FD6`, green `#15A37A`, amber `#E0930E`, red `#E25555`, etc.) + `Color(hex:)` helper.
- `Preset` model + global `presets` (Light 20, Medium 30, Firm 40, Max 50).
- Gauge geometry: `GaugeMath`, `ArcStroke`, `TicksStroke`, `Needle`, `InstrumentGauge` (top-facing semicircle, 0–60, green therapeutic band 20–40).
- Primitives: `SoftCard`, `SectionLabel`, `Badge`, `PresetButton`, `StepRow`.
- **`PressureSource` (data layer)** — see section (b).
- `AeroWrapHomeView` — the screen. Has an optional `onBack` closure (shows a back chevron when pushed onto a nav stack).
- `AeroWrapHostingController` — UIKit bridge; hides the nav bar, keeps edge-swipe-back, wires `onBack` to pop.

### b) Pressure data abstraction (the BLE seam)
A clean seam so the UI never knows where numbers come from:

```swift
class PressureSource: ObservableObject {
    @Published var pressure: Double = 40   // mmHg (gauge unit)
    @Published var isConnected: Bool = false
    func start(target: Double) {}
    func updateTarget(_ target: Double) {}
    func stop() {}
}

final class MockPressureSource: PressureSource { /* timer eases toward target + noise */ }
```

`AeroWrapHomeView.init(source: PressureSource = MockPressureSource(), onBack:)` injects it.
**To go live later:** write `ThingyPressureSource: PressureSource` wrapping `beginPressureUpdates` (convert hPa→mmHg there), then change the default in `AeroWrapHostingController` — **one line**, nothing in the view changes.

### c) Reliable demo entry (simulator has no Bluetooth)
- `MainEmptyConfigurationViewController.swift` — added a programmatic **"Open Aero Wrap (Demo)"** button in `viewDidLoad` (`addDemoButton()` / `demoButtonTapped()`) that pushes `AeroWrapHostingController`. Lets you reach the screen in the simulator without a device. No storyboard edits.

### d) Navigation + preview fixes (earlier)
- `MainMenuViewController.swift` — added **"Aero Wrap Monitor"** row to the always-visible MORE section; `showAeroWrapView()` pushes the hosting controller.
- `TutorialViewController.swift` — added a guard so SwiftUI **#Preview** doesn't crash: previews boot the whole host app, and the `SkipTutorial` SWReveal segue crashed under the preview executor. Guard:
  ```swift
  if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
  ```

---

## 4. Device testing — current state

**Goal:** Core Bluetooth does **not** work in the iOS Simulator at all, so real pressure data requires running on a **physical iPhone**. Using **free Apple ID signing** (no paid Developer Program yet).

Progress / steps:
1. Apple ID signed into Xcode (Christopher Nugent — Personal Team). ✅
2. **Signing fix:** personal teams can't use **NFC Tag Reading** — that capability had to be **deleted entirely** from Signing & Capabilities, and the bundle ID changed from `no.nordicsemi.ios.thingy` → `com.chrisnugent.aerowrap`. ✅
3. iPhone paired/trusted; **Developer Mode** enabled on the phone. ✅
4. `codesign` keychain prompt: it wants the **Mac login password** (not Apple ID, not phone passcode) — click **Always Allow**.

Remaining first-run step once it installs to the phone:
- Trust the developer profile: **Settings → General → VPN & Device Management → (your Apple ID) → Trust** (this entry only appears *after* the app is first installed to the device).

### Free vs paid signing
- **Free Apple ID:** deploys to your own device, BLE works, but signature **expires after 7 days** (re-run from Xcode to refresh), no TestFlight.
- **Paid Developer Program ($99/yr):** year-long signing + **TestFlight** for over-the-air distribution to other testers. Get this once others need to test.

---

## 5. The firmware / BLE protocol question (open)

The wrap is operated by pressing lights (UI service) to inflate/deflate — that behavior is **not** in stock Nordic firmware, which strongly implies the devices run **custom firmware**. Implications:

- If firmware is **stock**, the SDK is the protocol spec and `beginPressureUpdates` just works.
- If firmware is **custom** (likely), the **firmware source is the authoritative spec**. Ask the device team for:
  1. The **GATT table / service + characteristic UUIDs**.
  2. The **pressure-sensor handling code** (where the sensor value is read and packed into a BLE notification) — answers the hPa vs mmHg question definitively.
  3. How **inflation is triggered** (LED write interpreted as inflate? dedicated control characteristic?).
- Fallback if source isn't available: use **nRF Connect** on the phone to sniff which characteristic streams changing numbers when the wrap is squeezed, and infer the format. Workable but slower.

**Unit caveat:** the SDK reports barometric pressure in **hPa (atmospheric)**; the gauge/mock use **mmHg (cuff pressure, 0–60)**. The conversion/decoding belongs inside the future `ThingyPressureSource`.

---

## 6. Files touched (all under `Example/ThingySDK/`)

| File | Change |
|---|---|
| `ViewControllers/AeroWrapHomeView.swift` | The SwiftUI Live screen + `PressureSource`/`MockPressureSource` + `AeroWrapHostingController`. Restyled to the new soft React "Live" design. |
| `ViewControllers/ConfigurationView/MainEmptyConfigurationViewController.swift` | Added programmatic "Open Aero Wrap (Demo)" button. |
| `ViewControllers/MainMenu/MainMenuViewController.swift` | Added "Aero Wrap Monitor" sidebar row + `showAeroWrapView()`. |
| `ViewControllers/TutorialView/TutorialViewController.swift` | Preview-crash guard. |
| Xcode target settings | Bundle ID → `com.chrisnugent.aerowrap`; removed NFC Tag Reading capability. |

---

## 7. Open / next tasks

> **Update 2026-06-12 — live BLE wired up.** The device team (Baoguo Wei) confirmed the
> protocol: the custom firmware interprets a **one-shot LED write** as the command —
> **green = inflate to highest level, yellow = middle, blue = lowest, red = deflate**
> (device LED lights the matching color). Live pressure streams from the environment
> service in hPa. Implemented:
> - `ThingyPressureSource: PressureSource` — wraps `beginPressureUpdates`; captures a
>   baseline at first reading and publishes (reading − baseline) × 0.750062 as relative
>   mmHg (with a small "Re-zero" button and a raw-hPa debug caption on screen).
> - `WrapCommand` enum (low/medium/high/deflate → `ThingyLEDColorPreset`) +
>   `send(_:)` via `turnOnOneShotLED(intensity: 100)`.
> - UI reworked: 3 level buttons + full-width red Deflate button; controls disabled and
>   "Sensor offline" shown when no peripheral (no mock fallback on device; mock is
>   preview-only now).
> - `AeroWrapHostingController(peripheral:manager:)` conforms to `HasThingyTarget`, so
>   `MainNavigationViewController` forwards connect/disconnect state. The sidebar row
>   passes `targetPeripheral` + `thingyManager`; the demo button passes nil → offline.

- [x] **Run on the physical iPhone** — verified working against the real wrap (2026-06-12). Full inflation reads ~1100 hPa absolute (~120 hPa over baseline ≈ 91 mmHg of bladder air pressure), which overshot the gauge. Added `ThingyPressureSource.displayCalibration = 0.27` so full inflation displays ~25 mmHg (bladder air pressure ≠ leg interface pressure). **Tune this constant against a reference cuff gauge.**
- [ ] **Get the firmware source** (GATT table + pressure handling) — still worth having to confirm units and the exact level pressures.
- [x] **Write `ThingyPressureSource: PressureSource`** wrapping `beginPressureUpdates`, with hPa→mmHg conversion. Swapped into `AeroWrapHostingController`. _(Done 2026-06-12.)_
- [ ] Decide whether to build the **full tab shell** — the React design also has **Today / Progress / Insights** tabs (rings, weekly swelling trend, wear calendar, time-in-range, muscle-pump chart, Static Stiffness Index). These would be additional SwiftUI screens + a tab bar.
- [ ] _(Optional)_ Bundle the real **IBM Plex Sans / Mono** fonts for a pixel-exact match (currently using system font with `.monospaced` design).
- [ ] _(Advisory, deferred)_ Make the repo private — forks can't be made private; migrate to a fresh private repo (push & verify before deleting the public fork).

---

## 8. Reference: the React design

The newer "softer" React prototype (provided in chat) defines four tabs — **Today, Progress, Insights, Live**. Only the **Live** tab has been ported to SwiftUI so far. The React `App` component holds the same mock model used here: `pressure` eases toward `target` every 900ms with small noise, presets Light/Medium/Firm/Max, gauge max 60, green band 20–40, In-range = 20–40 mmHg.
