import AppKit
import ApplicationServices
import IOKit.hid

final class App: NSObject, NSApplicationDelegate {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    var device: IOHIDDevice?
    var running = false
    var bounds = CGRect.zero
    var gesture = TouchGesture()
    var statusItem: NSStatusItem!
    var status = "停止中"
    var reports = 0
    var events = 0
    var lastClick: (TimeInterval, CGPoint)?
    var clickCount: Int64 = 1
    let source = CGEventSource(stateID: .privateState)
    let statusLine = NSMenuItem(title: "停止中", action: nil, keyEquivalent: "")
    let counterLine = NSMenuItem(title: "入力 0 / 操作 0", action: nil, keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "タッチを開始", action: #selector(toggle), keyEquivalent: "")
    let singleFingerScrollItem = NSMenuItem(title: "1本指でスクロール", action: #selector(toggleSingleFingerScroll), keyEquivalent: "")
    var testWindow: NSWindow?
    var testCounts: [String: Int] = [:]
    var heartbeat: Timer?
    var lastReportAt: TimeInterval = 0
    var hasContacts = false
    var resumeAfterSleep = false
    var statusField: NSTextField?
    var singleFingerScrollCheckbox: NSButton?

    var targetScreen: NSScreen? { NSScreen.screens.first { $0.localizedName == "KD1" } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "K"
        statusItem.button?.font = NSFont.systemFont(ofSize: 17)
        statusItem.button?.setAccessibilityLabel("KD1のタッチ操作")
        emit(gesture.setSingleFingerScroll(UserDefaults.standard.bool(forKey: "singleFingerScroll")))
        singleFingerScrollItem.state = gesture.singleFingerScroll ? .on : .off
        let menu = NSMenu()
        for item in [statusLine, counterLine, .separator(), toggleItem, singleFingerScrollItem,
                     NSMenuItem(title: "動作確認を開く", action: #selector(showTest), keyEquivalent: ""),
                     NSMenuItem(title: "アクセシビリティ設定を開く", action: #selector(openPermissions), keyEquivalent: ""),
                     .separator(), NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")] {
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(waking),
            name: NSWorkspace.didWakeNotification, object: nil)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 切断や欠損した終端reportでマウスボタンを押しっぱなしにしない。
            if self.hasContacts && ProcessInfo.processInfo.systemUptime - self.lastReportAt > 2 {
                self.emit(self.gesture.cancel())
                self.hasContacts = false
            }
            self.statusLine.title = self.status
            self.counterLine.title = "入力 \(self.reports) / 操作 \(self.events)"
            self.statusField?.stringValue = "\(self.status)　入力 \(self.reports) / 操作 \(self.events)"
        }
        if AXIsProcessTrusted() { start() } else { status = "アクセシビリティ権限が必要" }
        showTest()
    }

    @objc func toggle() { running ? stop() : start() }

    @objc func toggleSingleFingerScroll() {
        emit(gesture.setSingleFingerScroll(!gesture.singleFingerScroll))
        singleFingerScrollItem.state = gesture.singleFingerScroll ? .on : .off
        singleFingerScrollCheckbox?.state = singleFingerScrollItem.state
        UserDefaults.standard.set(gesture.singleFingerScroll, forKey: "singleFingerScroll")
    }

    func start() {
        guard !running else { return }
        guard AXIsProcessTrusted() else {
            status = "アクセシビリティ権限が必要"
            let alert = NSAlert()
            alert.messageText = "KDTouchの操作権限が必要です"
            alert.informativeText = "システム設定の「プライバシーとセキュリティ → アクセシビリティ」でKDTouchを許可してください。タッチ座標をクリックやスクロールに変換するために使います。"
            alert.addButton(withTitle: "設定を開く")
            alert.addButton(withTitle: "キャンセル")
            if alert.runModal() == .alertFirstButtonReturn { openPermissions() }
            return
        }
        guard updateBounds() else { return }
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x29bd, kIOHIDProductIDKey: 0x4101] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<App>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, removed in
            guard let context else { return }
            let app = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
            if let active = app.device, CFEqual(active, removed) {
                app.emit(app.gesture.cancel())
                app.hasContacts = false
                app.device = nil
                app.status = "タッチ機器の接続待ち"
            }
        }, context)
        running = true
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            stop()
            status = "機器を開けません: \(hex(result))"
            return
        }
        // 再開時は接続済み機器のmatching callbackが再通知されないことがある。
        if let connected = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for candidate in connected { attach(candidate) }
        }
        guard running else { return }
        if device == nil { status = "タッチ機器の接続待ち" }
        toggleItem.title = "タッチを停止"
    }

    func attach(_ candidate: IOHIDDevice) {
        guard running, device == nil else { return }
        guard let descriptorURL = Bundle.main.url(forResource: "SW4101C", withExtension: "bin"),
              let expected = try? Data(contentsOf: descriptorURL),
              let actual = IOHIDDeviceGetProperty(candidate, kIOHIDReportDescriptorKey as CFString) as? Data,
              expected == actual else {
            stop()
            status = "未対応のタッチ情報形式です"
            return
        }
        let mode: [UInt8] = [7, 2, 0]
        let result = IOHIDDeviceSetReport(candidate, kIOHIDReportTypeFeature, 7, mode, mode.count)
        guard result == kIOReturnSuccess else {
            stop()
            status = "複数指モードにできません: \(hex(result))"
            return
        }
        device = candidate
        IOHIDDeviceRegisterInputReportCallback(candidate, reportBuffer, 64, { context, result, _, _, reportID, bytes, count in
            guard let context else { return }
            let app = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
            guard app.running, app.device != nil else { return }
            guard result == kIOReturnSuccess else {
                app.stop(); app.status = "タッチ入力でエラー: \(app.hex(result))"; return
            }
            guard reportID == 16 else { return }
            guard count == 64,
                  let contacts = TouchReport.decode(Array(UnsafeBufferPointer(start: bytes, count: count)), bounds: app.bounds) else {
                app.stop(); app.status = "タッチ情報が不正なため停止しました"; return
            }
            app.reports += 1
            app.lastReportAt = ProcessInfo.processInfo.systemUptime
            app.hasContacts = !contacts.isEmpty
            app.emit(app.gesture.update(contacts))
        }, Unmanaged.passUnretained(self).toOpaque())
        status = "KD1: タッチ操作中"
    }

    func stop() {
        emit(gesture.cancel())
        hasContacts = false
        if let device {
            IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, nil, nil)
            let mouseMode: [UInt8] = [7, 0, 0]
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 7, mouseMode, mouseMode.count)
            if result != kIOReturnSuccess { NSLog("KDTouch: mouse mode restore failed: %@", hex(result)) }
        }
        running = false
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        device = nil
        toggleItem.title = "タッチを開始"
        status = "停止中"
    }

    func emit(_ actions: [TouchAction]) {
        for action in actions {
            let event: CGEvent?
            switch action {
            case let .move(point):
                event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            case let .down(point):
                let now = ProcessInfo.processInfo.systemUptime
                if let (time, previous) = lastClick, now - time <= NSEvent.doubleClickInterval,
                   hypot(point.x - previous.x, point.y - previous.y) <= 6 {
                    clickCount = 2
                    lastClick = nil
                } else { clickCount = 1; lastClick = (now, point) }
                event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            case let .drag(point):
                event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
            case let .up(point):
                event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            case let .scroll(point, y, x, phase):
                event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
                event?.location = point
                event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            }
            switch action {
            case .down, .drag, .up: event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
            default: break
            }
            if let event { event.post(tap: .cghidEventTap); events += 1 }
        }
    }

    @discardableResult func updateBounds() -> Bool {
        guard let screen = targetScreen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            status = "KD1が見つかりません"
            return false
        }
        let id = CGDirectDisplayID(number.uint32Value)
        guard CGDisplayRotation(id) == 0 else { status = "KD1は横向きで使用してください"; return false }
        bounds = CGDisplayBounds(id)
        return true
    }

    @objc func displayChanged() {
        emit(gesture.cancel())
        hasContacts = false
        if !updateBounds() {
            let reason = status
            if running { stop() }
            status = reason
        }
    }

    @objc func sleeping() { resumeAfterSleep = running; if running { stop() } }
    @objc func waking() { if resumeAfterSleep { resumeAfterSleep = false; start() } }
    @objc func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { if running { stop() } }
    func hex(_ code: IOReturn) -> String { String(format: "0x%08x", code) }

    @objc func showTest() {
        guard let screen = targetScreen else { status = "KD1が見つかりません"; return }
        if let testWindow { testWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let frame = screen.visibleFrame.insetBy(dx: 30, dy: 30)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false, screen: screen)
        window.title = "KD1のタッチ操作を確認"
        window.isReleasedWhenClosed = false
        guard let content = window.contentView else { return }
        let w = content.bounds.width, h = content.bounds.height
        let description = NSTextField(labelWithString: "四隅をタップし、中央の文章をスクロールしてください。")
        description.frame = NSRect(x: 170, y: h - 65, width: w - 340, height: 40)
        description.alignment = .center
        content.addSubview(description)
        let toggleButton = NSButton(title: "タッチを開始／停止", target: self, action: #selector(toggle))
        toggleButton.bezelStyle = .rounded
        toggleButton.frame = NSRect(x: w / 2 - 90, y: h - 110, width: 180, height: 36)
        content.addSubview(toggleButton)
        let scrollCheckbox = NSButton(checkboxWithTitle: "1本指でスクロール", target: self, action: #selector(toggleSingleFingerScroll))
        scrollCheckbox.state = singleFingerScrollItem.state
        scrollCheckbox.frame = NSRect(x: w / 2 + 110, y: h - 110, width: 190, height: 36)
        content.addSubview(scrollCheckbox)
        singleFingerScrollCheckbox = scrollCheckbox
        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.frame = NSRect(x: 170, y: 25, width: w - 340, height: 28)
        statusLabel.alignment = .center
        content.addSubview(statusLabel)
        statusField = statusLabel
        for (name, x, y) in [("左上", 20.0, h - 65), ("右上", w - 150, h - 65),
                             ("左下", 20.0, 20.0), ("右下", w - 150, 20.0)] {
            let button = NSButton(title: "\(name): 0", target: self, action: #selector(testTapped(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(name)
            button.bezelStyle = .rounded
            button.frame = NSRect(x: x, y: y, width: 130, height: 44)
            content.addSubview(button)
        }
        let scroll = NSScrollView(frame: NSRect(x: w * 0.2, y: 80, width: w * 0.6, height: h - 190))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 3000))
        text.isEditable = false
        text.font = .systemFont(ofSize: 20)
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.string = (1...80).map { "\($0) 行目 — スクロールモードは1本指、通常は2本指でスクロールできます。" }.joined(separator: "\n\n")
        scroll.documentView = text
        content.addSubview(scroll)
        testWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func testTapped(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        testCounts[name, default: 0] += 1
        sender.title = "\(name): \(testCounts[name]!)"
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
