// main.swift
import Cocoa
import SwiftUI

// MARK: - DisplayServices Bridge

typealias DisplayServicesGetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DisplayServicesSetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

class DisplayBrightnessController {
    private var getBrightnessFunc: DisplayServicesGetBrightnessFunc?
    private var setBrightnessFunc: DisplayServicesSetBrightnessFunc?
    private(set) var builtInDisplayID: CGDirectDisplayID?
    
    var isAvailable: Bool { builtInDisplayID != nil && getBrightnessFunc != nil }
    
    init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ) else {
            print("⚠️ Failed to load DisplayServices framework")
            return
        }
        
        if let ptr = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightnessFunc = unsafeBitCast(ptr, to: DisplayServicesGetBrightnessFunc.self)
        }
        if let ptr = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightnessFunc = unsafeBitCast(ptr, to: DisplayServicesSetBrightnessFunc.self)
        }
        
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else { return }
        
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return }
        
        for id in displays.prefix(Int(displayCount)) {
            if CGDisplayIsBuiltin(id) != 0 {
                builtInDisplayID = id
                print("✅ Found built-in display: \(id)")
                return
            }
        }
        print("⚠️ No built-in display found - overlay dimming only")
    }
    
    func getBrightness() -> Float {
        guard let id = builtInDisplayID, let get = getBrightnessFunc else { return -1 }
        var brightness: Float = 0
        return get(id, &brightness) == 0 ? brightness : -1
    }
    
    func setBrightness(_ value: Float) -> Bool {
        guard let id = builtInDisplayID, let set = setBrightnessFunc else { return false }
        return set(id, max(0, min(1, value))) == 0
    }
}

// MARK: - Overlay Window

class DimOverlayWindow: NSWindow {
    init(for screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0)
        self.level = .screenSaver
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.hasShadow = false
    }
    
    func setDimLevel(_ level: Float) {
        let alpha = CGFloat(max(0, min(0.95, level)))
        self.backgroundColor = NSColor.black.withAlphaComponent(alpha)
    }
}

// MARK: - SwiftUI Popover View

class PopoverState: ObservableObject {
    @Published var hardwareBrightness: Double = 100
    @Published var overlayBrightness: Double = 100  // 100 = bright (no dim), 0 = darkest (max dim)
    
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
    }
    
    func applyHardwareBrightness() {
        guard let controller = displayController, controller.isAvailable else { return }
        let clamped = max(0.01, Float(hardwareBrightness / 100.0))
        _ = controller.setBrightness(clamped)
    }
    
    func applyOverlayDim() {
        // Original logic: 100 = no dim, 0 = max dim
        let dimLevel = Float((100 - overlayBrightness) / 100.0)
        onOverlayChanged?(dimLevel)
    }
    
    func resetOverlay() {
        overlayBrightness = 100
        onOverlayChanged?(0)
    }
}

struct PopoverView: View {
    @ObservedObject var state: PopoverState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // === Hardware Brightness ===
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
                        .onChange(of: state.hardwareBrightness) { _ in
                            state.applyHardwareBrightness()
                            
                            // Reset overlay when hardware brightness goes back up
                            if state.hardwareBrightness > 1 && state.overlayBrightness < 100 {
                                state.resetOverlay()
                            }
                        }
                }
            }
            
            // === Software Dimmer (appears when hardware is at minimum) ===
            if state.showOverlaySlider {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Software Dimmer (← darker | brighter →)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 10) {
                        Image(systemName: "moon.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        
                        Slider(value: $state.overlayBrightness, in: 0...100)
                            .onChange(of: state.overlayBrightness) { _ in
                                state.applyOverlayDim()
                            }
                    }
                }
            }
            
            // === Quit Button ===
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

class DimmerApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var displayController: DisplayBrightnessController!
    private var overlayWindows: [DimOverlayWindow] = []
    private var popoverState: PopoverState!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        displayController = DisplayBrightnessController()
        
        setupPopoverState()
        setupStatusItem()
        setupPopover()
        setupOverlayWindows()
        startBrightnessMonitoring()
    }
    
    private func setupPopoverState() {
        popoverState = PopoverState()
        popoverState.displayController = displayController
        popoverState.onOverlayChanged = { [weak self] level in
            self?.applyOverlayDim(level)
        }
        popoverState.onQuit = { [weak self] in
            self?.quitApp()
        }
        popoverState.syncFromSystem()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Dimmer")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(state: popoverState))
    }
    
    private func setupOverlayWindows() {
        for screen in NSScreen.screens {
            let overlay = DimOverlayWindow(for: screen)
            overlay.orderFrontRegardless()
            overlayWindows.append(overlay)
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    @objc private func screensChanged() {
        overlayWindows.forEach { $0.close() }
        overlayWindows.removeAll()
        setupOverlayWindows()
        let currentDim = Float((100 - popoverState.overlayBrightness) / 100.0)
        applyOverlayDim(currentDim)
    }
    
    private func startBrightnessMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.displayController.isAvailable && !self.popover.isShown {
                DispatchQueue.main.async {
                    self.popoverState.syncFromSystem()
                }
            }
        }
    }
    
    private func applyOverlayDim(_ level: Float) {
        for overlay in overlayWindows {
            overlay.setDimLevel(level)
        }
    }
    
    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popoverState.syncFromSystem()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    
    private func quitApp() {
        overlayWindows.forEach { $0.close() }
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = DimmerApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()