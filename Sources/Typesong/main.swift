import AppKit
import CoreAudio
import WebKit
import CoreGraphics

// Typesong for Mac: a menu-bar app. The sound engine is the same web page as the web version, running in a
// WKWebView; a listen-only keyboard event tap feeds it which key was pressed and when. Nothing typed is stored,
// logged or sent anywhere. macOS hides keystrokes in password fields (secure input) from event taps entirely.

let styles: [(key: String, title: String)] = [
    ("lofi", "Lofi"), ("night", "Late night"), ("ambient", "Ambient"), ("angelic", "Ethereal"),
    ("rain", "Rainfall"), ("noise", "Noise"), ("free", "Instruments"),
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var web: WKWebView!
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var activity: NSObjectProtocol?
    private var pageReady = false
    private var clock: Timer?

    private var currentStyle = "lofi"
    private var tipURL: URL?   // set by the engine page; the menu shows "Leave a tip" only when it exists
    private var muted = false
    private var paused = false
    private var agentOn = UserDefaults.standard.object(forKey: "agentMode") as? Bool ?? false   // Beta: off until chosen
    private var agentServer: AgentServer?
    private var agentScope = UserDefaults.standard.string(forKey: "agentScope") ?? "focus"   // "focus" or "all"
    private var pendingAgent: [[String: Any]] = []
    private let selfTest = CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--agent-test")
    private var agentEvents = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the audio clock and scheduler at full speed while the app sits in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Playing music as you type")
        buildWindow()
        buildStatusItem()
        if !selfTest { startListening() }          // the self-test never triggers the permission prompt
        agentServer = AgentServer { [weak self] event in self?.agentEvent(event) }
        // After the Mac wakes, the audio clock can come back frozen; rebuild the engine's audio right away.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            HealthLog.write("mac woke: resetting audio")
            self?.startClock()
            self?.js("typesongHost.resetAudio('mac woke')")
        }
        watchOutputDevice()
        if agentOn || selfTest { agentServer?.start() }
        if CommandLine.arguments.contains("--show") { showWindow() }
    }

    // MARK: Web engine

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.inactiveSchedulingPolicy = .none      // never throttle timers when the window is hidden
        let bridge = WKUserScript(source: "window.TYPESONG_HOST='mac';", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(bridge)
        config.userContentController.add(self, name: "typesong")

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 780), configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Typesong"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web      // must stay in a window: a detached web view gets its audio cut ('interrupted')
        park()

        guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else {
            NSLog("Typesong: engine page missing from the app bundle")
            return
        }
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        startClock()
        js("typesongHost.setAgentScope('\(agentScope)')")
        pendingAgent.forEach(agentEvent); pendingAgent.removeAll()
        if CommandLine.arguments.contains("--selftest") { runSelfTest() }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "state":
            if let s = body["style"] as? String { currentStyle = s }
            if let m = body["muted"] as? Bool { muted = m }
            if let t = body["tipURL"] as? String { tipURL = Self.safeLink(t) }
            refreshIcon()
        case "openURL":
            if let t = body["url"] as? String, let url = Self.safeLink(t) { NSWorkspace.shared.open(url) }
        case "audioReset":
            HealthLog.write("audio reset: \(body["reason"] as? String ?? "?")")
        case "sleep":
            stopClock()
            HealthLog.write("asleep: audio suspended, clock stopped")
        case "wake":
            startClock()
        case "health":
            let ticks = body["ticks"] as? Int ?? 0, audio = body["audio"] as? String ?? "?", t = body["t"] as? Double ?? 0
            let m = body["music"] as? [String: Any] ?? [:]
            let music = ["notes", "pitches", "top", "maxRun", "range", "beats", "chats", "heard"].compactMap { k in m[k].map { "\(k)=\($0)" } }.joined(separator: " ")
            HealthLog.write("ticks/5s=\(ticks) audio=\(audio) clock=\(t) style=\(currentStyle) listening=\(tap != nil) paused=\(paused) agentEvents=\(agentEvents) | \(music)")
        default: break
        }
    }

    // The page's own timers get throttled to 1/s while hidden, so the app drives its 25 ms clock.
    // The page asks for it to stop ('sleep') once everything has gone quiet, and to restart ('wake') when sound starts.
    private func startClock() {
        guard clock == nil, pageReady else { return }
        let t = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in self?.web.evaluateJavaScript("typesongHost.tick()", completionHandler: nil) }
        t.tolerance = 0.003
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    private func js(_ source: String) {
        guard pageReady else { return }
        web.evaluateJavaScript(source, completionHandler: nil)
    }

    private func send(key ch: String, kind: String) {
        guard !paused, let data = try? JSONSerialization.data(withJSONObject: [ch, kind]),
              let args = String(data: data, encoding: .utf8) else { return }
        startClock()
        js("typesongHost.key(...\(args))")
    }

    // MARK: Agent mode

    private func agentEvent(_ event: [String: Any]) {
        guard agentOn || selfTest else { return }
        guard pageReady else { pendingAgent.append(event); return }
        guard let data = try? JSONSerialization.data(withJSONObject: event), let json = String(data: data, encoding: .utf8) else { return }
        agentEvents += 1
        startClock()
        js("typesongHost.agent(\(json))")
    }

    @objc private func pickAgentScope(_ sender: NSMenuItem) {
        guard let scope = sender.representedObject as? String else { return }
        agentScope = scope
        UserDefaults.standard.set(scope, forKey: "agentScope")
        js("typesongHost.setAgentScope('\(scope)')")
    }

    @objc private func toggleAgent() {
        agentOn.toggle()
        UserDefaults.standard.set(agentOn, forKey: "agentMode")
        if agentOn { agentServer?.start() } else { agentServer?.stop() }
        refreshIcon()
        if agentOn && !Hook.isInstalled(command: hookCommand) { DispatchQueue.main.async { self.setUpClaude() } }
    }

    // The hook is this app run with --hook, so it works without Python or a copy of the repo.
    private var hookCommand: String { "\"\(Bundle.main.executablePath ?? "/Applications/Typesong.app/Contents/MacOS/Typesong")\" --hook" }

    @objc private func setUpClaude() {
        NSApp.activate(ignoringOtherApps: true)
        let ask = NSAlert()
        ask.messageText = "Connect Claude Code to Typesong?"
        ask.informativeText = "Typesong will add a few hooks to ~/.claude/settings.json so Claude Code can tell it when it's working, using tools and done. Your other settings stay as they are, and a backup is saved next to the file.\n\nChats you start after this will play. Chats already open need a restart."
        ask.addButton(withTitle: "Connect")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let done = NSAlert()
        do {
            _ = try Hook.install(command: hookCommand)
            done.messageText = "Claude Code is connected"
            done.informativeText = "Start a new Claude Code chat and it will play while it works."
        } catch {
            done.alertStyle = .warning
            done.messageText = "Couldn't connect Claude Code"
            done.informativeText = error.localizedDescription
        }
        done.runModal()
    }

    // MARK: Keyboard listener

    private func startListening() {
        if CGPreflightListenEventAccess() {
            installTap()
        } else {
            CGRequestListenEventAccess()     // adds Typesong to Input Monitoring and shows the system prompt once
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, CGPreflightListenEventAccess() else { return }
                self.permissionTimer?.invalidate()
                self.installTap()
            }
        }
        refreshIcon()
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            app.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Typesong: could not create the keyboard listener (Input Monitoring not granted?)")
            refreshIcon()
            return
        }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        refreshIcon()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }   // held keys don't machine-gun notes
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // ⌃⌥⌘M toggles mute from anywhere.
        if code == 46 && flags.contains(.maskCommand) && flags.contains(.maskAlternate) && flags.contains(.maskControl) {
            DispatchQueue.main.async { self.toggleMute() }
            return
        }
        // Shortcuts (⌘ or ⌃ held) are commands, not writing.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return }

        switch code {
        case 49: send(key: " ", kind: "space")
        case 36, 76: send(key: "\n", kind: "enter")
        case 51, 117: send(key: "", kind: "back")
        default:
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
            guard length > 0 else { return }
            let s = String(utf16CodeUnits: chars, count: length)
            guard let c = s.last, !c.isNewline, c.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return }
            send(key: String(c), kind: "char")
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
    }

    // ♪ = your typing plays (agent music may be on too) · ♪ with a sparkle = only agent music, typing paused ·
    // mute = muted, or nothing can play · triangle = typing is on but keyboard permission is missing.
    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        if muted || (paused && !agentOn) {
            button.image = NSImage(systemSymbolName: "speaker.slash", accessibilityDescription: "Typesong muted")
        } else if paused {
            button.image = Self.agentIcon
        } else if tap == nil {
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Typesong needs Input Monitoring")
        } else {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Typesong")
        }
    }

    // A music note with a small sparkle in its top-right corner, drawn as a template so it follows the menu bar's color.
    static let agentIcon: NSImage = {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
                note.draw(in: NSRect(x: 0, y: (size.height - note.size.height) / 2, width: note.size.width, height: note.size.height))
            }
            if let spark = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
                spark.draw(in: NSRect(x: size.width - spark.size.width, y: size.height - spark.size.height, width: spark.size.width, height: spark.size.height))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Typesong, agent music only"
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if tap == nil { status = "Needs Input Monitoring permission" }
        else if paused { status = "Paused" }
        else if muted { status = "Muted" }
        else { status = "Listening · \(styles.first { $0.key == currentStyle }?.title ?? currentStyle)" }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if tap == nil {
            menu.addItem(item("Grant Input Monitoring…", #selector(openPermissions)))
            menu.addItem(.separator())
        }

        let mute = item(muted ? "Unmute" : "Mute", #selector(toggleMute))
        mute.keyEquivalent = "m"
        mute.keyEquivalentModifierMask = [.command, .option, .control]
        menu.addItem(mute)
        menu.addItem(item(paused ? "Resume listening to my typing" : "Pause listening to my typing", #selector(togglePause)))
        let agent = item("Agent music for Claude Code (Beta)", #selector(toggleAgent))
        agent.state = agentOn ? .on : .off
        menu.addItem(agent)
        if agentOn {
            let setUp = Hook.isInstalled(command: hookCommand)
            let setup = item(setUp ? "Claude Code is connected ✓" : "Connect Claude Code…", #selector(setUpClaude))
            setup.indentationLevel = 1
            menu.addItem(setup)
            for (scope, title) in [("focus", "Only my latest chat"), ("all", "All chats, each in its own spot")] {
                let i = item(title, #selector(pickAgentScope(_:)))
                i.representedObject = scope
                i.state = agentScope == scope ? .on : .off
                i.indentationLevel = 1
                menu.addItem(i)
            }
        }

        let styleMenu = NSMenu()
        for s in styles {
            let i = item(s.title, #selector(pickStyle(_:)))
            i.representedObject = s.key
            i.state = s.key == currentStyle ? .on : .off
            styleMenu.addItem(i)
        }
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(item("Show Typesong window", #selector(showWindowAction)))
        if tipURL != nil { menu.addItem(item("Leave a tip ♥", #selector(openTip))) }
        menu.addItem(.separator())
        menu.addItem(item("Quit Typesong", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        currentStyle = k
        startClock()
        js("typesongHost.setStyle('\(k)')")
    }

    // When the Mac's output changes (AirPods connect, headphones unplug), the web view's audio can stay attached to
    // the old device and play into nothing. Rebuild the engine's audio on the new device, once things settle.
    private var outputChange: DispatchWorkItem?
    private func watchOutputDevice() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self else { return }
            self.outputChange?.cancel()
            let work = DispatchWorkItem { [weak self] in
                HealthLog.write("audio output changed: rebuilding audio")
                self?.js("typesongHost.resetAudio('output changed', true)")
            }
            self.outputChange = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)   // AirPods can fire several changes in a row
        }
    }

    @objc private func toggleMute() {
        muted.toggle()
        js("typesongHost.setMuted(\(muted))")
        // If the Mac switched outputs while muted (AirPods, headphones), the old audio route is dead: rebuild on unmute.
        if !muted { HealthLog.write("unmuted: rebuilding audio"); js("typesongHost.resetAudio('unmute', true)") }
        refreshIcon()
    }

    @objc private func togglePause() {
        paused.toggle()
        refreshIcon()
    }

    @objc private func openPermissions() {
        CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showWindowAction() { showWindow() }

    @objc private func openTip() { if let tipURL { NSWorkspace.shared.open(tipURL) } }

    /// Only plain https links leave the app.
    private static func safeLink(_ s: String) -> URL? {
        guard let url = URL(string: s), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        js("typesongHost.setVisible(true)")
        // A saved size only counts if it's a real window size; the hidden window is parked at 2×2.
        let saved = UserDefaults.standard.string(forKey: "windowFrame").map(NSRectFromString).flatMap(Self.usableFrame)
        window.setFrame(saved ?? NSRect(x: 0, y: 0, width: 920, height: 780), display: false)
        if saved == nil { window.center() }
        window.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window keeps the music running from the menu bar; the page stops drawing.
        js("typesongHost.setVisible(false)")
        if let frame = Self.usableFrame(window.frame) {   // quitting also "closes" the parked 2×2 window: never save that
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "windowFrame")
        }
        DispatchQueue.main.async { self.park() }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private static func usableFrame(_ r: NSRect) -> NSRect? { r.width >= 400 && r.height >= 300 ? r : nil }

    // While hidden, the page is laid out at 2×2 points so WebKit keeps almost no graphics memory for it.
    private func park() {
        window.setContentSize(NSSize(width: 2, height: 2))
    }

    // MARK: Self-test (--selftest): feeds synthetic keys with the window never shown, and logs engine health.

    private func runSelfTest() {
        HealthLog.write("selftest: page loaded")
        let text = "Hello there, this is a test of the typing music. "
        var delay = 0.5
        for ch in text {
            let kind = ch == " " ? "space" : "char"
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.send(key: String(ch), kind: kind) }
            delay += 0.12
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) {
            HealthLog.write("selftest: second pass, still hidden")
            var d = 0.0
            for ch in text {
                let kind = ch == " " ? "space" : "char"
                DispatchQueue.main.asyncAfter(deadline: .now() + d) { self.send(key: String(ch), kind: kind) }
                d += 0.12
            }
        }
    }
}

enum HealthLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Typesong")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("health.log")
    }()

    // Only engine health goes here (timer rate, audio state). Never keystrokes.
    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

if CommandLine.arguments.contains("--hook") { Hook.run() }   // Claude Code hook mode: no UI, exits right away

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
