// main.swift
import Cocoa
import OSLog
import SwiftUI

// MARK: - Single Instance Check

private func isAnotherInstanceRunning() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        Logger.general.warning("No bundle identifier available — skipping single-instance check")
        return false
    }

    let currentPID = ProcessInfo.processInfo.processIdentifier
    let others = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == bundleID && $0.processIdentifier != currentPID
    }

    return !others.isEmpty
}

// MARK: - Splash Screen

struct SplashView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "star.leadinghalf.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundStyle(.yellow)

            Text("Dimmer")
                .font(.title3)
                .fontWeight(.semibold)
        }
        .padding(36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

@MainActor
final class SplashWindowController {
    private var window: NSWindow?

    func show() {
        let hosting = NSHostingController(rootView: SplashView())
        let window = NSWindow(contentViewController: hosting)

        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.alphaValue = 0

        // Accessory apps aren't auto-activated; bring it to front explicitly.
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1
        }

        self.window = window
    }

    func hide(completion: (() -> Void)? = nil) {
        guard let window else {
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup(
            { ctx in
                ctx.duration = 0.25
                window.animator().alphaValue = 0
            },
            completionHandler: {
                window.orderOut(nil)
                completion?()
            })
        self.window = nil
    }
}

// MARK: - Logging

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.dimmer.app"
    static let general = Logger(subsystem: subsystem, category: "general")
    static let brightness = Logger(subsystem: subsystem, category: "brightness")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
}

// MARK: - Shared Display Helpers

private enum DisplayUtils {
    static func activeDisplays() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
            displayCount > 0
        else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return []
        }

        return Array(displays.prefix(Int(displayCount)))
    }
}

// MARK: - DisplayServices Bridge

typealias DisplayServicesGetBrightnessFunc =
    @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DisplayServicesSetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

final class DisplayBrightnessController {
    private var handle: UnsafeMutableRawPointer?
    private var getBrightnessFunc: DisplayServicesGetBrightnessFunc?
    private var setBrightnessFunc: DisplayServicesSetBrightnessFunc?
    private(set) var builtInDisplayID: CGDirectDisplayID?

    var isAvailable: Bool { builtInDisplayID != nil && getBrightnessFunc != nil }

    init() {
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                RTLD_LAZY
            )
        else {
            Logger.general.error("Failed to load DisplayServices framework")
            return
        }
        self.handle = handle

        if let ptr = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightnessFunc = unsafeBitCast(ptr, to: DisplayServicesGetBrightnessFunc.self)
        } else {
            Logger.general.error("Failed to resolve DisplayServicesGetBrightness symbol")
        }

        if let ptr = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightnessFunc = unsafeBitCast(ptr, to: DisplayServicesSetBrightnessFunc.self)
        } else {
            Logger.general.error("Failed to resolve DisplayServicesSetBrightness symbol")
        }

        let displays = DisplayUtils.activeDisplays()
        for id in displays {
            if CGDisplayIsBuiltin(id) != 0 {
                builtInDisplayID = id
                Logger.general.info("Built-in display found: id=\(id, privacy: .public)")
                return
            }
        }
        Logger.general.warning("No built-in display found – overlay dimming only")
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func getBrightness() -> Float {
        guard let id = builtInDisplayID, let get = getBrightnessFunc else { return -1 }
        var brightness: Float = 0
        let result = get(id, &brightness)

        guard result == 0, brightness.isFinite, brightness >= 0, brightness <= 1 else {
            Logger.brightness.error(
                "Failed to get brightness: result=\(result, privacy: .public), value=\(brightness, privacy: .public)"
            )
            return -1
        }

        Logger.brightness.debug(
            "Brightness read: \(brightness * 100, format: .fixed(precision: 1), privacy: .public)% (raw: \(brightness, privacy: .public))"
        )
        return brightness
    }

    func setBrightness(_ value: Float) -> Bool {
        guard let id = builtInDisplayID, let set = setBrightnessFunc else { return false }
        guard value.isFinite else { return false }

        let clamped = max(0, min(1, value))
        Logger.brightness.debug(
            "Setting brightness to \(clamped * 100, format: .fixed(precision: 1), privacy: .public)% (raw: \(clamped, privacy: .public))"
        )

        let result = set(id, clamped)
        if result != 0 {
            Logger.brightness.error(
                "DisplayServicesSetBrightness failed: result=\(result, privacy: .public)")
            return false
        }
        return true
    }
}

// MARK: - App State

@MainActor
final class PopoverState: ObservableObject {
    @Published var hardwareBrightness: Double = 100
    @Published var overlayBrightness: Double = 100
    @Published var displayName: String = "Display"
    @Published var isInternal: Bool = false

    var displayController: DisplayBrightnessController?
    var onOverlayChanged: ((Float) -> Void)?
    var onQuit: (() -> Void)?

    var showOverlaySlider: Bool {
        hardwareBrightness <= 1 || !(displayController?.isAvailable ?? false)
    }

    func syncFromSystem() {
        guard let controller = displayController, controller.isAvailable else { return }
        let current = controller.getBrightness()
        if current >= 0 {
            hardwareBrightness = max(1, Double(current * 100))
        }

        if let mainScreen = NSScreen.main {
            displayName = mainScreen.localizedName
            isInternal = controller.builtInDisplayID != nil
            Logger.general.debug(
                "Synced display name: \(self.displayName, privacy: .public), isInternal: \(self.isInternal, privacy: .public)"
            )
        }
    }

    func applyHardwareBrightness() {
        guard let controller = displayController, controller.isAvailable else { return }
        let clamped = max(0.01, Float(hardwareBrightness / 100.0))
        _ = controller.setBrightness(clamped)
    }

    func applyOverlayDim() {
        let x = (100.0 - overlayBrightness) / 100.0
        let k = 3.0
        let dim = Float((exp(k * x) - 1.0) / (exp(k) - 1.0))
        Logger.overlay.debug(
            "Overlay slider: \(self.overlayBrightness, privacy: .public) → dim level: \(dim, privacy: .public)"
        )
        onOverlayChanged?(dim)
    }

    func resetOverlay() {
        Logger.overlay.info("Resetting software overlay")
        overlayBrightness = 100
        onOverlayChanged?(0)
    }
}

// MARK: - Popover UI

struct PopoverView: View {
    @ObservedObject var state: PopoverState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(spacing: 6) {
                Image(systemName: state.isInternal ? "laptopcomputer" : "display")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(state.isInternal ? "Internal" : "External")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(state.displayName)
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Display Brightness")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Image(systemName: "sun.max")
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    Slider(value: $state.hardwareBrightness, in: 1...100)
                        .disabled(!(state.displayController?.isAvailable ?? false))
                        .onChange(of: state.hardwareBrightness) { _, _ in
                            state.applyHardwareBrightness()

                            if state.hardwareBrightness > 1 && state.overlayBrightness < 100 {
                                state.resetOverlay()
                            }
                        }
                }
            }

            if state.showOverlaySlider {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Software Dimmer")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        Image(systemName: "moon.zzz")
                            .foregroundColor(.secondary)
                            .frame(width: 16)

                        Slider(value: $state.overlayBrightness, in: 0...100)
                            .onChange(of: state.overlayBrightness) { _, _ in
                                state.applyOverlayDim()
                            }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Quit") {
                    state.onQuit?()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

// MARK: - App Controller

@MainActor
final class DimmerApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var displayController: DisplayBrightnessController?
    private var popoverState: PopoverState?
    private var brightnessTimer: Timer?
    private var splashController: SplashWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.general.info("Application did finish launching")

        let splash = SplashWindowController()
        splashController = splash
        splash.show()  // <-- show immediately

        let controller = DisplayBrightnessController()
        displayController = controller

        setupPopoverState(with: controller)
        setupStatusItem()
        setupPopover()
        startBrightnessMonitoring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Ensure splash is visible for at least a moment, then dismiss.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.splashController?.hide {
                self?.splashController = nil
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        brightnessTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func setupPopoverState(with controller: DisplayBrightnessController) {
        let state = PopoverState()
        state.displayController = controller
        state.onOverlayChanged = { [weak self] level in
            self?.applySoftwareDim(level)
        }
        state.onQuit = { [weak self] in
            self?.quitApp()
        }
        state.syncFromSystem()
        popoverState = state
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "star.leadinghalf.fill", accessibilityDescription: "Dimmer")
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item
    }

    private func setupPopover() {
        guard let popoverState else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: PopoverView(state: popoverState))
        popover = pop
    }

    @objc private func screensChanged() {
        Logger.general.debug("Screen configuration changed, reapplying software overlay")
        popoverState?.applyOverlayDim()
    }

    private func startBrightnessMonitoring() {
        brightnessTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let controller = self.displayController, controller.isAvailable else {
                    return
                }

                let current = controller.getBrightness()
                guard current >= 0 else { return }

                let systemValue = max(1, Double(current * 100))
                if let state = self.popoverState,
                    abs(state.hardwareBrightness - systemValue) > 1
                {
                    Logger.brightness.info(
                        "External brightness change detected: \(systemValue, format: .fixed(precision: 1), privacy: .public)%"
                    )
                    state.hardwareBrightness = systemValue
                }
            }
        }
    }

    private func applySoftwareDim(_ level: Float) {
        guard level.isFinite else { return }
        let clamped = max(0, min(0.9, level))

        let remainingLight = 1.0 - clamped
        let signalScale = CGGammaValue(pow(remainingLight, 1.0 / 2.2))

        // Gentle contrast compensation: ramps 1.0 → 1.15 as dim deepens.
        // This is a shadow-deepening, not true contrast, but at this
        // magnitude it reads as "less washed out" without eating midtones.
        let gamma = CGGammaValue(1.0 + 0.15 * clamped * clamped)

        for display in DisplayUtils.activeDisplays() {
            CGSetDisplayTransferByFormula(
                display,
                0, signalScale, gamma,
                0, signalScale, gamma,
                0, signalScale, gamma
            )
        }
        Logger.overlay.info(
            "Software dim applied to \(DisplayUtils.activeDisplays().count, privacy: .public) display(s)"
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popoverState?.syncFromSystem()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func quitApp() {
        Logger.general.info("Quitting - resetting overlays and terminating")
        CGDisplayRestoreColorSyncSettings()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

@MainActor
private func launchApp() {
    if isAnotherInstanceRunning() {
        Logger.general.notice("Another instance is already running - exiting")
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = DimmerApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

MainActor.assumeIsolated {
    launchApp()
}
