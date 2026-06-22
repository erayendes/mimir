# TelemetryDeck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** Anonymous, privacy-first usage telemetry via TelemetryDeck, opt-out, dev/prod split.

**Architecture:** A thin `Telemetry` wrapper gates every send through a pure `shouldSend`
function; pure parameter producers build categorical-only payloads; `MimirApp` wires start +
signals; a right-click status-bar menu hosts the opt-out toggle, update check, and quit.

**Tech Stack:** Swift 6, macOS 14, TelemetryDeck SwiftSDK, XCTest.

## Global Constraints

- Swift 6, macOS 14 (`.v14`).
- Dev builds (`bundleIdentifier` ends `.dev`) NEVER send telemetry.
- Opt-out: `UserDefaults` `"telemetry.enabled"`, **default true** (absent key = enabled).
- Signals are **categorical only** — no quota %, reset times, credits, account ids, tokens, PII.
- App ID is a non-secret constant; `start()` is a no-op when it's the placeholder/empty.
- Telemetry failures must never crash or affect the app.

---

### Task 1: SDK dependency + send gate (pure)

**Files:**
- Modify: `Package.swift` (deps + Mimir target product)
- Create: `Sources/Mimir/Telemetry.swift`
- Test: `Tests/MimirTests/TelemetryTests.swift`

**Interfaces:**
- Produces: `Telemetry.shouldSend(isDev: Bool, enabled: Bool) -> Bool`,
  `Telemetry.enabled: Bool { get }`, `Telemetry.appID: String`.

- [ ] **Step 1: Failing test** — `Tests/MimirTests/TelemetryTests.swift`
```swift
import XCTest
@testable import Mimir

final class TelemetryTests: XCTestCase {
    func testShouldSendOnlyWhenEnabledAndNotDev() {
        XCTAssertTrue(Telemetry.shouldSend(isDev: false, enabled: true))
        XCTAssertFalse(Telemetry.shouldSend(isDev: true, enabled: true))   // dev never sends
        XCTAssertFalse(Telemetry.shouldSend(isDev: false, enabled: false)) // opt-out
        XCTAssertFalse(Telemetry.shouldSend(isDev: true, enabled: false))
    }
}
```
- [ ] **Step 2: Add dependency** — `Package.swift`: add to `dependencies`
  `.package(url: "https://github.com/TelemetryDeck/SwiftSDK", from: "2.0.0"),`
  and to the Mimir target `dependencies` `.product(name: "TelemetryDeck", package: "SwiftSDK"),`
- [ ] **Step 3: Minimal impl** — `Sources/Mimir/Telemetry.swift`
```swift
import Foundation

/// Anonymous, privacy-first usage telemetry (TelemetryDeck). Every send passes through
/// `shouldSend`; dev builds and opt-out users never send. Categorical signals only.
enum Telemetry {
    /// TelemetryDeck app id (non-secret, embedded in the client). Empty/placeholder → no-op.
    static let appID = "REPLACE_WITH_TELEMETRYDECK_APP_ID"

    static let enabledKey = "telemetry.enabled"

    /// Opt-out: absent key means enabled.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var isDevBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    }

    /// Pure gate — unit-tested.
    static func shouldSend(isDev: Bool, enabled: Bool) -> Bool { !isDev && enabled }
}
```
- [ ] **Step 4: Run** — `swift test --filter TelemetryTests` → PASS
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(telemetry): add TelemetryDeck dep + pure send gate"`

---

### Task 2: Pure signal parameter producers

**Files:**
- Modify: `Sources/Mimir/Telemetry.swift`
- Test: `Tests/MimirTests/TelemetryTests.swift`

**Interfaces:**
- Produces: `Telemetry.providerParameters(from: [ServiceStatus]) -> [String: String]`,
  `Telemetry.widgetParameters(families: [String]) -> [String: String]`.

- [ ] **Step 1: Failing tests** — append to `TelemetryTests`
```swift
func testProviderParametersAreCategoricalOnly() {
    let svcs = [
        ServiceStatus(name: "Claude", iconName: "claude", sessionResetAt: nil, weeklyResetAt: nil,
                      sessionRemainingPercent: 9, weeklyRemainingPercent: 11, models: [],
                      isAvailable: true, statusNote: nil),
        ServiceStatus(name: "Codex", iconName: "codex", sessionResetAt: nil, weeklyResetAt: nil,
                      models: [], isAvailable: false, statusNote: nil, isStale: true),
        ServiceStatus(name: "Antigravity", iconName: "antigravity", sessionResetAt: nil,
                      weeklyResetAt: nil, models: [], isAvailable: false, statusNote: nil),
    ]
    let p = Telemetry.providerParameters(from: svcs)
    XCTAssertEqual(p["claude"], "true")
    XCTAssertEqual(p["codex"], "true")          // stale counts as in-use
    XCTAssertEqual(p["antigravity"], "false")
    // No quota values leak.
    XCTAssertFalse(p.values.contains("9"))
    XCTAssertFalse(p.values.contains("11"))
}

func testWidgetParametersCountFamilies() {
    let p = Telemetry.widgetParameters(families: ["systemSmall", "systemSmall", "systemLarge"])
    XCTAssertEqual(p["small"], "2")
    XCTAssertEqual(p["large"], "1")
    XCTAssertEqual(p["medium"], "0")
    XCTAssertEqual(p["extraLarge"], "0")
}
```
- [ ] **Step 2: Run** → FAIL (undefined)
- [ ] **Step 3: Impl** — append to `Telemetry`
```swift
extension Telemetry {
    /// Which providers are in use (available or showing stale data) — boolean only, no values.
    static func providerParameters(from services: [ServiceStatus]) -> [String: String] {
        func active(_ name: String) -> String {
            (services.first { $0.name == name }.map { $0.isAvailable || $0.isStale } ?? false)
                ? "true" : "false"
        }
        return ["claude": active("Claude"), "codex": active("Codex"), "antigravity": active("Antigravity")]
    }

    /// Count of placed widgets per family (from WidgetCenter family raw names).
    static func widgetParameters(families: [String]) -> [String: String] {
        func count(_ raw: String) -> String { String(families.filter { $0 == raw }.count) }
        return ["small": count("systemSmall"), "medium": count("systemMedium"),
                "large": count("systemLarge"), "extraLarge": count("systemExtraLarge")]
    }
}
```
- [ ] **Step 4: Run** `swift test --filter TelemetryTests` → PASS
- [ ] **Step 5: Commit** — `git commit -am "feat(telemetry): pure categorical signal producers"`

---

### Task 3: Wrapper start/signal/setEnabled

**Files:** Modify `Sources/Mimir/Telemetry.swift`

**Interfaces:**
- Produces: `Telemetry.start()`, `Telemetry.signal(_:parameters:)`, `Telemetry.setEnabled(_:)`.

- [ ] **Step 1: Impl** — append (no unit test — SDK side-effects; gate already covered)
```swift
import TelemetryDeck

extension Telemetry {
    private static var started = false

    /// Initialise the SDK once, only for non-dev builds with a real app id and opt-in.
    static func start() {
        guard shouldSend(isDev: isDevBuild, enabled: enabled),
              !appID.isEmpty, appID != "REPLACE_WITH_TELEMETRYDECK_APP_ID",
              !started else { return }
        started = true
        TelemetryDeck.initialize(config: .init(appID: appID))
    }

    static func signal(_ name: String, parameters: [String: String] = [:]) {
        guard shouldSend(isDev: isDevBuild, enabled: enabled), started else { return }
        TelemetryDeck.signal(name, parameters: parameters)
    }

    /// Flip the opt-out flag; starting the SDK if newly enabled.
    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { start() }
    }
}
```
- [ ] **Step 2: Build** `swift build` → Build complete
- [ ] **Step 3: Commit** — `git commit -am "feat(telemetry): SDK start/signal/setEnabled wrapper"`

---

### Task 4: Wire into MimirApp (launch + 3rd-refresh)

**Files:** Modify `Sources/Mimir/MimirApp.swift`

**Interfaces:** Consumes Task 1/2/3. Adds private `refreshCount`, `sentProviderSignal`.

- [ ] **Step 1: Start at launch** — in `applicationDidFinishLaunching`, after the Sentry block:
```swift
Telemetry.start()
WidgetCenter.shared.getCurrentConfigurations { result in
    let families = (try? result.get())?.map { "\($0.family)" } ?? []
    Telemetry.signal("widget.installed", parameters: Telemetry.widgetParameters(families: families))
}
```
  Add `import WidgetKit` at top if absent.
- [ ] **Step 2: Add counters** — near other private vars:
```swift
private var refreshCount = 0
private var sentProviderSignal = false
```
- [ ] **Step 3: 3rd-refresh provider signal** — inside the `store.$services` sink, after `refreshStatusTitle()`:
```swift
self?.noteRefreshForTelemetry(services)
```
  And add the method:
```swift
private func noteRefreshForTelemetry(_ services: [ServiceStatus]) {
    guard !sentProviderSignal else { return }
    refreshCount += 1
    // Sample on the 3rd refresh so Antigravity (only visible while its IDE runs) has appeared.
    guard refreshCount >= 3 else { return }
    sentProviderSignal = true
    Telemetry.signal("provider.active", parameters: Telemetry.providerParameters(from: services))
}
```
- [ ] **Step 4: Build** `swift build` → Build complete
- [ ] **Step 5: Commit** — `git commit -am "feat(telemetry): emit widget + provider signals from the app"`

---

### Task 5: Right-click status-bar menu

**Files:** Modify `Sources/Mimir/MimirApp.swift`

- [ ] **Step 1: Left/right split** — after setting `item.button?.action`, add:
```swift
item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
```
- [ ] **Step 2: Branch in togglePopover** — at the top of `togglePopover(_:)`:
```swift
if NSApp.currentEvent?.type == .rightMouseUp {
    showStatusMenu()
    return
}
```
- [ ] **Step 3: Build the menu**
```swift
private func showStatusMenu() {
    guard let item = statusItem else { return }
    let menu = NSMenu()

    let toggle = NSMenuItem(title: String(localized: "Send anonymous statistics"),
                            action: #selector(toggleTelemetry), keyEquivalent: "")
    toggle.target = self
    toggle.state = Telemetry.enabled ? .on : .off
    menu.addItem(toggle)
    menu.addItem(.separator())

    let update = NSMenuItem(title: String(localized: "Check for updates"),
                            action: #selector(menuCheckForUpdates), keyEquivalent: "")
    update.target = self
    menu.addItem(update)

    let quit = NSMenuItem(title: String(localized: "Quit Mimir"),
                          action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)

    item.menu = menu
    item.button?.performClick(nil)
    item.menu = nil   // transient: keep left-click bound to the popover
}

@objc private func toggleTelemetry() {
    Telemetry.setEnabled(!Telemetry.enabled)
    if Telemetry.enabled { Telemetry.signal("telemetry.enabled") }
}

@objc private func menuCheckForUpdates() {
    updaterController?.checkForUpdates(nil)
    Telemetry.signal("update.checkRequested")
}
```
- [ ] **Step 4: Localize** — add to both `Localizable.strings` (en/tr):
  en: `"Send anonymous statistics" = "Send anonymous statistics";` `"Quit Mimir" = "Quit Mimir";`
  (`"Check for updates"` already exists.)
  tr: `"Send anonymous statistics" = "Anonim istatistik gönder";` `"Quit Mimir" = "Mimir'den Çık";`
- [ ] **Step 5: Build + run** `WIDGET=0 ./script/build_and_run.sh` → right-click shows the menu;
  toggle flips the checkmark; Quit terminates.
- [ ] **Step 6: Commit** — `git commit -am "feat(telemetry): right-click menu (opt-out, updates, quit)"`

---

### Task 6: Final review (security · privacy · simplify)

- [ ] **Step 1: Security review** — `/security-review` over the diff (new dep + send paths).
- [ ] **Step 2: Privacy audit** — re-read every `Telemetry.signal(...)` call site; confirm
  categorical-only, anonymous id intact, opt-out stops sends (incl. init), dev silent.
- [ ] **Step 3: Simplify** — `/simplify` over the changed files; apply, keep tests green.
- [ ] **Step 4: Full test** — `swift test` → all pass.
- [ ] **Step 5: Commit** any fixes.

(CHANGELOG entry is written at release time, EN + TR, like prior versions.)
