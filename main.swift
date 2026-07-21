// main.swift
import Cocoa

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

// MARK: - App Controller

class DimmerApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var displayController: DisplayBrightnessController!
    private var overlayWindows: [DimOverlayWindow] = []

    private var systemBrightnessSlider: NSSlider!
    private var sunIcon: NSImageView!          // ← new
    private var sysLabel: NSTextField!         // ← new
    private var overlaySlider: NSSlider!
    private var overlayContainer: NSView!

    private var currentOverlayDim: Float = 0
    private let hardwareMinimum: Float = 0.01

    func applicationDidFinishLaunching(_ notification: Notification) {
        displayController = DisplayBrightnessController()
        setupStatusItem()
        setupPopover()
        setupOverlayWindows()
        startBrightnessMonitoring()
    }

    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill",
                                   accessibilityDescription: "Dimmer")
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 80)  // ← default compact

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))

        // === System Brightness Row ===
        sunIcon = NSImageView(frame: NSRect(x: 12, y: 30, width: 20, height: 20))  // ← compact pos
        sunIcon.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: nil)
        sunIcon.contentTintColor = .secondaryLabelColor
        contentView.addSubview(sunIcon)

        systemBrightnessSlider = NSSlider(frame: NSRect(x: 40, y: 30, width: 200, height: 20))  // ← compact pos
        systemBrightnessSlider.minValue = 1
        systemBrightnessSlider.maxValue = 100
        systemBrightnessSlider.target = self
        systemBrightnessSlider.action = #selector(systemBrightnessChanged)
        systemBrightnessSlider.isContinuous = true
        if displayController.isAvailable {
            let current = displayController.getBrightness() * 100
            systemBrightnessSlider.floatValue = max(1, current)
        } else {
            systemBrightnessSlider.isEnabled = false
            systemBrightnessSlider.floatValue = 1
        }
        contentView.addSubview(systemBrightnessSlider)

        sysLabel = NSTextField(labelWithString: "Display Brightness")  // ← compact pos
        sysLabel.frame = NSRect(x: 40, y: 50, width: 200, height: 16)
        sysLabel.font = NSFont.systemFont(ofSize: 10)
        sysLabel.textColor = .tertiaryLabelColor
        contentView.addSubview(sysLabel)

        // === Overlay Dimmer Row ===
        overlayContainer = NSView(frame: NSRect(x: 0, y: 10, width: 280, height: 55))

        let moonIcon = NSImageView(frame: NSRect(x: 12, y: 20, width: 20, height: 20))
        moonIcon.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)
        moonIcon.contentTintColor = .secondaryLabelColor
        overlayContainer.addSubview(moonIcon)

        overlaySlider = NSSlider(frame: NSRect(x: 40, y: 20, width: 200, height: 20))
        overlaySlider.minValue = 0
        overlaySlider.maxValue = 100
        overlaySlider.floatValue = 100
        overlaySlider.target = self
        overlaySlider.action = #selector(overlayDimChanged)
        overlaySlider.isContinuous = true
        overlayContainer.addSubview(overlaySlider)

        let overlayLabel = NSTextField(labelWithString: "Software Dimmer (← darker | brighter →)")
        overlayLabel.frame = NSRect(x: 40, y: 40, width: 220, height: 16)
        overlayLabel.font = NSFont.systemFont(ofSize: 10)
        overlayLabel.textColor = .tertiaryLabelColor
        overlayContainer.addSubview(overlayLabel)

        contentView.addSubview(overlayContainer)

        // Quit button
        let quitButton = NSButton(frame: NSRect(x: 220, y: 5, width: 50, height: 20))
        quitButton.bezelStyle = .inline
        quitButton.title = "Quit"
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        contentView.addSubview(quitButton)

        updateOverlaySliderVisibility()

        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = contentView
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
        applyOverlayDim(currentOverlayDim)
    }
    
    private func startBrightnessMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            if self.displayController.isAvailable {
                let current = self.displayController.getBrightness()
                if current >= 0 {
                    DispatchQueue.main.async {
                        if !self.systemBrightnessSlider.isHighlighted {
                            self.systemBrightnessSlider.floatValue = max(1, current * 100)
                        }
                        self.updateOverlaySliderVisibility()
                    }
                }
            }
        }
    }
    
    private func updateOverlaySliderVisibility() {
        let brightness = systemBrightnessSlider.floatValue
        let shouldShow = brightness <= 1 || !displayController.isAvailable

        let wasHidden = overlayContainer.isHidden
        overlayContainer.isHidden = !shouldShow

        if shouldShow {
            // Expanded layout
            popover.contentSize = NSSize(width: 280, height: 120)
            sunIcon.frame.origin.y = 75
            systemBrightnessSlider.frame.origin.y = 75
            sysLabel.frame.origin.y = 95
            overlayContainer.frame.origin.y = 10
        } else {
            // Compact layout
            popover.contentSize = NSSize(width: 280, height: 70)
            sunIcon.frame.origin.y = 30
            systemBrightnessSlider.frame.origin.y = 30
            sysLabel.frame.origin.y = 50
        }

        // When overlay slider first appears, reset it to max brightness
        if wasHidden && !overlayContainer.isHidden {
            overlaySlider.floatValue = 100
            currentOverlayDim = 0
            applyOverlayDim(0)
        }

        // Reset overlay if system brightness goes back up
        if brightness > 1 && currentOverlayDim > 0 {
            currentOverlayDim = 0
            overlaySlider.floatValue = 100
            applyOverlayDim(0)
        }
    }

    
    @objc private func systemBrightnessChanged(_ sender: NSSlider) {
        // Clamp to minimum 1% (hardware floor)
        let value = max(hardwareMinimum, sender.floatValue / 100.0)
        _ = displayController.setBrightness(value)
        
        // Ensure slider reflects the clamped value
        sender.floatValue = max(1, sender.floatValue)
        
        updateOverlaySliderVisibility()
    }
    
    @objc private func overlayDimChanged(_ sender: NSSlider) {
        // Slider: 0 (left) = darkest, 100 (right) = brightest
        let dimLevel = (100 - sender.floatValue) / 100.0
        currentOverlayDim = Float(dimLevel)
        applyOverlayDim(currentOverlayDim)
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
            if displayController.isAvailable {
                systemBrightnessSlider.floatValue = max(1, displayController.getBrightness() * 100)
            }
            updateOverlaySliderVisibility()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    
    @objc private func quitApp() {
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