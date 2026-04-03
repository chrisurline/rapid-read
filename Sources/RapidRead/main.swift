import Cocoa
import SwiftUI

// MARK: - Virtual Keycodes

enum VK {
    static let c: UInt16 = 8
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

// MARK: - Settings

struct Settings: Codable {
    var wpm: Int = 425
    var wpmStep: Int = 25
    var fontSize: CGFloat = 42
    var startDelay: Double = 0.5
    var windowWidth: CGFloat = 600
    var windowHeight: CGFloat = 160
    var cornerRadius: CGFloat = 16
    var skipSmall: Int = 5
    var skipLarge: Int = 10

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wpm = try c.decodeIfPresent(Int.self, forKey: .wpm) ?? 425
        wpmStep = try c.decodeIfPresent(Int.self, forKey: .wpmStep) ?? 25
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 42
        startDelay = try c.decodeIfPresent(Double.self, forKey: .startDelay) ?? 0.5
        windowWidth = try c.decodeIfPresent(CGFloat.self, forKey: .windowWidth) ?? 600
        windowHeight = try c.decodeIfPresent(CGFloat.self, forKey: .windowHeight) ?? 160
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 16
        skipSmall = try c.decodeIfPresent(Int.self, forKey: .skipSmall) ?? 5
        skipLarge = try c.decodeIfPresent(Int.self, forKey: .skipLarge) ?? 10
    }

    // File paths
    private static let configDir: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rapidread")

    static let configFile: URL =
        configDir.appendingPathComponent("settings.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: configFile) else {
            let s = Settings()
            s.save()
            return s
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(Settings.self, from: data)) ?? Settings()
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.configFile)
        }
    }

    var charWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }
}

// MARK: - RSVP Engine

class RSVPEngine: ObservableObject {
    @Published var currentWord = ""
    @Published var orpIndex = 0
    @Published var wordIndex = 0
    @Published var totalWords = 0
    @Published var wpm: Int
    @Published var isPlaying = false
    @Published var isFinished = false

    let settings: Settings
    private var words: [String] = []
    private var timer: Timer?

    init(settings: Settings) {
        self.settings = settings
        self.wpm = settings.wpm
    }

    var progress: Double {
        guard totalWords > 0 else { return 0 }
        return Double(min(wordIndex + 1, totalWords)) / Double(totalWords)
    }

    func load(_ text: String) {
        stop()
        words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        totalWords = words.count
        wordIndex = 0
        isFinished = false
        guard !words.isEmpty else { return }
        show(0)
        // Don't auto-play — caller handles start delay
    }

    func play() {
        guard wordIndex < words.count else { return }
        isPlaying = true
        isFinished = false
        tick()
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func toggle() {
        if isFinished { wordIndex = 0; show(0); play() }
        else if isPlaying { pause() }
        else { play() }
    }

    func skip(_ n: Int) {
        let playing = isPlaying
        pause()
        wordIndex = max(0, min(words.count - 1, wordIndex + n))
        show(wordIndex)
        if playing { play() }
    }

    func nudgeSpeed(_ delta: Int) {
        wpm = max(50, min(1500, wpm + delta))
        if isPlaying { timer?.invalidate(); tick() }
    }

    func stop() {
        pause()
        currentWord = ""
        words = []
        wordIndex = 0
        totalWords = 0
        isFinished = false
    }

    private func show(_ i: Int) {
        guard i >= 0, i < words.count else { return }
        currentWord = words[i]
        orpIndex = Self.orp(words[i])
    }

    private func tick() {
        guard wordIndex < words.count else {
            isPlaying = false; isFinished = true; return
        }
        let d = delay(words[wordIndex])
        timer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in
            guard let s = self, s.isPlaying else { return }
            s.wordIndex += 1
            if s.wordIndex < s.words.count {
                s.show(s.wordIndex)
                s.tick()
            } else {
                s.isPlaying = false
                s.isFinished = true
            }
        }
    }

    private func delay(_ w: String) -> TimeInterval {
        let base = 60.0 / Double(wpm)
        var m = 1.0
        if w.count > 8 { m += 0.3 } else if w.count > 6 { m += 0.15 }
        if let c = w.last {
            if ".!?".contains(c) { m += 0.6 }
            else if ";:".contains(c) { m += 0.4 }
            else if ",-)".contains(c) { m += 0.2 }
        }
        return base * m
    }

    static func orp(_ w: String) -> Int {
        switch w.count {
        case 0...1: return 0
        case 2...5: return 1
        case 6...9: return 2
        case 10...13: return 3
        default: return 4
        }
    }
}

// MARK: - Reader View

struct ReaderView: View {
    @ObservedObject var engine: RSVPEngine
    let settings: Settings
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Word display with ORP centering
            ZStack {
                // ORP guide markers
                VStack {
                    marker
                    Spacer()
                    marker
                }
                // Word — offset so ORP char is centered
                wordView.offset(x: wordXOffset)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .clipped()

            Spacer().frame(height: 14)

            // Status line
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 10, weight: .medium))
                    Text("\(engine.wpm)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.white.opacity(0.45))

                Spacer()

                if engine.totalWords > 0 {
                    Text("\(engine.wordIndex + 1)/\(engine.totalWords)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer().frame(height: 8)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.orange.opacity(0.55))
                        .frame(width: geo.size.width * engine.progress)
                        .animation(.linear(duration: 0.08), value: engine.progress)
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 30)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .onTapGesture { engine.toggle() }
    }

    private var wordView: some View {
        HStack(spacing: 0) {
            ForEach(Array(engine.currentWord.enumerated()), id: \.offset) { i, c in
                Text(String(c))
                    .foregroundColor(i == engine.orpIndex ? .orange : .white.opacity(0.88))
            }
        }
        .font(.system(size: settings.fontSize, weight: .medium, design: .monospaced))
    }

    private var wordXOffset: CGFloat {
        let cw = settings.charWidth
        let n = CGFloat(engine.currentWord.count)
        let raw = (n / 2.0 - CGFloat(engine.orpIndex) - 0.5) * cw
        // Clamp so word stays within visible area
        let wordW = n * cw
        let available = settings.windowWidth - 60 // horizontal padding
        guard wordW < available else { return 0 }
        let limit = (available - wordW) / 2
        return max(-limit, min(limit, raw))
    }

    private var statusIcon: String {
        engine.isFinished ? "checkmark.circle.fill" :
            engine.isPlaying ? "play.fill" : "pause.fill"
    }

    private var marker: some View {
        Rectangle()
            .fill(Color.orange.opacity(0.6))
            .frame(width: 2.5, height: 14)
    }
}

// MARK: - Floating Panel

class ReaderPanel: NSPanel {
    let engine: RSVPEngine
    let settings: Settings
    let dismissAction: () -> Void

    init(engine: RSVPEngine, settings: Settings, dismiss: @escaping () -> Void) {
        self.engine = engine
        self.settings = settings
        self.dismissAction = dismiss
        let r = NSRect(x: 0, y: 0, width: settings.windowWidth, height: settings.windowHeight)
        super.init(contentRect: r, styleMask: [.borderless], backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow

        // Frosted glass
        let glass = NSVisualEffectView(frame: r)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = settings.cornerRadius
        glass.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        contentView = glass

        // SwiftUI content
        let host = NSHostingView(rootView: ReaderView(
            engine: engine, settings: settings, onDismiss: dismiss))
        host.frame = r
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        let opt = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case VK.space where !event.modifierFlags.contains(.command):
            engine.toggle()
        case VK.escape:
            dismissAction()
        case VK.left:
            engine.skip(-(opt ? settings.skipLarge : settings.skipSmall))
        case VK.right:
            engine.skip(opt ? settings.skipLarge : settings.skipSmall)
        case VK.up:
            engine.nudgeSpeed(settings.wpmStep)
        case VK.down:
            engine.nudgeSpeed(-settings.wpmStep)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = Settings.load()
    private lazy var engine = RSVPEngine(settings: settings)
    private var panel: ReaderPanel?
    private var globalMon: Any?
    private var localMon: Any?
    private var startWork: DispatchWorkItem?
    private var isDismissing = false

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMenu()
        setupHotkey()
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "text.viewfinder",
            accessibilityDescription: "RapidRead"
        )
        let menu = NSMenu()
        let info = NSMenuItem(title: "RapidRead — ⌘Space", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if !FileManager.default.fileExists(atPath: Settings.configFile.path) {
            settings.save()
        }
        NSWorkspace.shared.open(Settings.configFile)
    }

    private func setupHotkey() {
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if self?.isCmdSpace(e) == true {
                DispatchQueue.main.async { self?.fire() }
            }
        }
        localMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if self?.isCmdSpace(e) == true {
                DispatchQueue.main.async { self?.fire() }
                return nil // consume
            }
            return e
        }
    }

    private func isCmdSpace(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        return e.keyCode == VK.space && mods == .command
    }

    // MARK: Hotkey handler

    private func fire() {
        if let p = panel, p.isVisible { dismiss(); return }

        grabSelection { [weak self] text in
            guard let self else { return }
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            self.present(t)
        }
    }

    private func grabSelection(_ done: @escaping (String?) -> Void) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: VK.c, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: VK.c, keyDown: false)
        else { done(nil); return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            done(NSPasteboard.general.string(forType: .string))
        }
    }

    private func present(_ text: String) {
        isDismissing = false
        engine.load(text)

        if panel == nil {
            panel = ReaderPanel(
                engine: engine, settings: settings,
                dismiss: { [weak self] in self?.dismiss() })
            // Close when the user clicks away
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel, queue: .main
            ) { [weak self] _ in
                self?.dismiss()
            }
        }
        guard let panel else { return }

        // Position offset from cursor: above → left → right → below
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main!
        let vis = screen.visibleFrame
        let (w, h) = (panel.frame.width, panel.frame.height)
        let gap: CGFloat = 16
        let margin: CGFloat = 8

        var x: CGFloat
        var y: CGFloat

        if mouse.y + gap + h <= vis.maxY - margin {
            // Above cursor, centered horizontally
            x = mouse.x - w / 2
            y = mouse.y + gap
        } else if mouse.x - gap - w >= vis.minX + margin {
            // Left of cursor, centered vertically
            x = mouse.x - gap - w
            y = mouse.y - h / 2
        } else if mouse.x + gap + w <= vis.maxX - margin {
            // Right of cursor, centered vertically
            x = mouse.x + gap
            y = mouse.y - h / 2
        } else {
            // Below cursor (fallback), centered horizontally
            x = mouse.x - w / 2
            y = mouse.y - gap - h
        }

        // Clamp to screen edges
        x = max(vis.minX + margin, min(vis.maxX - w - margin, x))
        y = max(vis.minY + margin, min(vis.maxY - h - margin, y))

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        // Start reading after configured delay
        startWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.engine.play()
        }
        startWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.startDelay, execute: work)
    }

    private func dismiss() {
        guard let panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        startWork?.cancel()
        engine.stop()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }) { [weak self] in
            panel.orderOut(nil)
            self?.isDismissing = false
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
