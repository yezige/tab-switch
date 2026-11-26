import Cocoa
import CoreGraphics
import IOKit.hid
import ServiceManagement

// MARK: - Constants & Settings
private enum KeyCode {
    static let tab: Int64 = 48
    static let esc: Int64 = 53
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let q: Int64 = 12
    static let h: Int64 = 4
}

enum TriggerModifier: String, CaseIterable {
    case control = "control"
    case option = "option"

    var displayName: String {
        switch self {
        case .control: return "Control + Tab（已互换 Ctrl↔Cmd 的 Win 布局 Alt+Tab）"
        case .option:  return "Option + Tab（标准 Alt+Tab）"
        }
    }

    var shortName: String {
        switch self {
        case .control: return "Control + Tab"
        case .option:  return "Option + Tab"
        }
    }

    var cgFlag: CGEventFlags {
        switch self {
        case .control: return .maskControl
        case .option:  return .maskAlternate
        }
    }

    var forbiddenFlags: [CGEventFlags] {
        switch self {
        case .control: return [.maskCommand, .maskAlternate]
        case .option:  return [.maskCommand, .maskControl]
        }
    }
}

struct KeyboardInfo: Equatable {
    let id: String       // "vendorID:productID" or "all"
    let name: String

    static let all = KeyboardInfo(id: "all", name: "所有键盘")
}

final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var targetKeyboardID: String {
        get { defaults.string(forKey: "targetKeyboardID") ?? KeyboardInfo.all.id }
        set { defaults.set(newValue, forKey: "targetKeyboardID") }
    }

    var triggerModifier: TriggerModifier {
        get { TriggerModifier(rawValue: defaults.string(forKey: "triggerModifier") ?? "") ?? .control }
        set { defaults.set(newValue.rawValue, forKey: "triggerModifier") }
    }
}

// MARK: - HID Keyboard Tracker
final class KeyboardTracker {
    static let shared = KeyboardTracker()

    private var manager: IOHIDManager?
    private(set) var keyboards: [KeyboardInfo] = []
    private(set) var lastActiveDeviceID: String?
    var onDevicesChanged: (() -> Void)?

    func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<KeyboardTracker>.fromOpaque(ctx).takeUnretainedValue().refreshDevices()
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<KeyboardTracker>.fromOpaque(ctx).takeUnretainedValue().refreshDevices()
        }, ctx)

        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
            guard let ctx else { return }
            let tracker = Unmanaged<KeyboardTracker>.fromOpaque(ctx).takeUnretainedValue()
            let elem = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(elem)
            if let id = KeyboardTracker.deviceID(for: device) {
                tracker.lastActiveDeviceID = id
            }
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
        refreshDevices()
    }

    func refreshDevices() {
        guard let mgr = manager,
              let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            keyboards = []
            onDevicesChanged?()
            return
        }

        var seen = Set<String>()
        var list: [KeyboardInfo] = []
        for dev in set {
            guard let id = KeyboardTracker.deviceID(for: dev), !seen.contains(id) else { continue }
            let product = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知键盘"
            let transport = (IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String) ?? ""
            let label = transport.isEmpty ? product : "\(product) (\(transport))"
            seen.insert(id)
            list.append(KeyboardInfo(id: id, name: label))
        }
        keyboards = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onDevicesChanged?()
    }

    func matchesTargetKeyboard() -> Bool {
        let target = AppSettings.shared.targetKeyboardID
        if target == KeyboardInfo.all.id { return true }
        // If Input Monitoring hasn't delivered any HID event yet, don't silently swallow wrong keyboards
        return lastActiveDeviceID == target
    }

    private static func deviceID(for device: IOHIDDevice) -> String? {
        guard let vid = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
              let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int else {
            return nil
        }
        return "\(vid):\(pid)"
    }
}

// MARK: - Lightweight Icon Switcher HUD
final class SwitcherHUD: NSPanel {
    private let container = NSView()
    private let stackView = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var cells: [NSView] = []

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.93).cgColor
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        container.addSubview(stackView)
        container.addSubview(titleLabel)
        contentView = container
    }

    private func applyHighlight(to cell: NSView, selected: Bool) {
        cell.layer?.backgroundColor = selected ? NSColor(white: 1.0, alpha: 0.22).cgColor : nil
        cell.layer?.borderWidth = selected ? 1.5 : 0
        cell.layer?.borderColor = selected ? NSColor(white: 1.0, alpha: 0.55).cgColor : nil
    }

    func render(apps: [NSRunningApplication], selectedIndex: Int) {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cells.removeAll(keepingCapacity: true)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let maxWidth = (screen?.visibleFrame.width ?? 1200) * 0.85

        let count = apps.count
        let spacing: CGFloat = 8
        let paddingX: CGFloat = 20
        let cellSize = min(72, max(44, floor((maxWidth - paddingX * 2 - spacing * CGFloat(count - 1)) / CGFloat(count))))
        let iconSize = cellSize - 14

        for (idx, app) in apps.enumerated() {
            let cell = NSView(frame: NSRect(x: 0, y: 0, width: cellSize, height: cellSize))
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 12
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.widthAnchor.constraint(equalToConstant: cellSize).isActive = true
            cell.heightAnchor.constraint(equalToConstant: cellSize).isActive = true

            let iconView = NSImageView(frame: NSRect(x: 7, y: 7, width: iconSize, height: iconSize))
            iconView.image = app.icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(iconView)

            applyHighlight(to: cell, selected: idx == selectedIndex)
            stackView.addArrangedSubview(cell)
            cells.append(cell)
        }

        let totalW = max(220, paddingX * 2 + CGFloat(count) * cellSize + CGFloat(count - 1) * spacing)
        let totalH = cellSize + 48

        container.frame = NSRect(x: 0, y: 0, width: totalW, height: totalH)
        stackView.frame = NSRect(x: paddingX, y: 34, width: totalW - paddingX * 2, height: cellSize)
        titleLabel.frame = NSRect(x: 16, y: 10, width: totalW - 32, height: 18)
        titleLabel.stringValue = apps[selectedIndex].localizedName ?? ""

        if let s = screen {
            let x = s.frame.origin.x + (s.frame.width - totalW) / 2
            let y = s.frame.origin.y + (s.frame.height - totalH) / 2
            setFrame(NSRect(x: x, y: y, width: totalW, height: totalH), display: true)
        }
    }

    func updateSelection(apps: [NSRunningApplication], selectedIndex: Int) {
        for (idx, cell) in cells.enumerated() {
            applyHighlight(to: cell, selected: idx == selectedIndex)
        }
        titleLabel.stringValue = apps[selectedIndex].localizedName ?? ""
    }
}

// MARK: - Native Settings Window
final class SettingsWindowController: NSWindowController {
    private let keyboardPopup = NSPopUpButton()
    private let modifierPopup = NSPopUpButton()
    private let launchCheckbox = NSButton(checkboxWithTitle: "登录 macOS 时自动启动 TabSwitch", target: nil, action: nil)
    private let axStatusLabel = NSTextField(labelWithString: "")
    private let hidStatusLabel = NSTextField(labelWithString: "")
    private var displayedKeyboards: [KeyboardInfo] = []
    private var refreshTimer: Timer?

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 278),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "TabSwitch 设置"
        win.isReleasedWhenClosed = false
        super.init(window: win)
        buildUI()
        reloadAll()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let kbLabel = NSTextField(labelWithString: "目标键盘：")
        kbLabel.frame = NSRect(x: 24, y: 228, width: 84, height: 20)
        kbLabel.alignment = .right
        content.addSubview(kbLabel)

        keyboardPopup.frame = NSRect(x: 112, y: 224, width: 256, height: 26)
        keyboardPopup.target = self
        keyboardPopup.action = #selector(keyboardChanged)
        content.addSubview(keyboardPopup)

        let refreshBtn = NSButton(title: "刷新", target: self, action: #selector(refreshKeyboards))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.frame = NSRect(x: 376, y: 223, width: 60, height: 28)
        content.addSubview(refreshBtn)

        let modLabel = NSTextField(labelWithString: "切换热键：")
        modLabel.frame = NSRect(x: 24, y: 184, width: 84, height: 20)
        modLabel.alignment = .right
        content.addSubview(modLabel)

        modifierPopup.frame = NSRect(x: 112, y: 180, width: 324, height: 26)
        modifierPopup.target = self
        modifierPopup.action = #selector(modifierChanged)
        for mod in TriggerModifier.allCases {
            modifierPopup.addItem(withTitle: mod.displayName)
        }
        content.addSubview(modifierPopup)

        launchCheckbox.frame = NSRect(x: 112, y: 142, width: 320, height: 22)
        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchChanged)
        content.addSubview(launchCheckbox)

        let divider = NSBox(frame: NSRect(x: 24, y: 120, width: 412, height: 1))
        divider.boxType = .separator
        content.addSubview(divider)

        let axTitle = NSTextField(labelWithString: "辅助功能权限：")
        axTitle.frame = NSRect(x: 24, y: 84, width: 110, height: 20)
        axTitle.alignment = .right
        content.addSubview(axTitle)

        axStatusLabel.frame = NSRect(x: 140, y: 84, width: 190, height: 20)
        content.addSubview(axStatusLabel)

        let axBtn = NSButton(title: "前往设置", target: self, action: #selector(openAccessibility))
        axBtn.bezelStyle = .rounded
        axBtn.frame = NSRect(x: 350, y: 80, width: 86, height: 28)
        content.addSubview(axBtn)

        let hidTitle = NSTextField(labelWithString: "输入监控权限：")
        hidTitle.frame = NSRect(x: 24, y: 46, width: 110, height: 20)
        hidTitle.alignment = .right
        content.addSubview(hidTitle)

        hidStatusLabel.frame = NSRect(x: 140, y: 46, width: 206, height: 20)
        content.addSubview(hidStatusLabel)

        let hidBtn = NSButton(title: "前往设置", target: self, action: #selector(openInputMonitoring))
        hidBtn.bezelStyle = .rounded
        hidBtn.frame = NSRect(x: 350, y: 42, width: 86, height: 28)
        content.addSubview(hidBtn)

        let hint = NSTextField(labelWithString: "提示：选择“指定键盘”时需开启输入监控；选“所有键盘”仅需辅助功能。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 24, y: 14, width: 416, height: 18)
        content.addSubview(hint)
    }

    func show() {
        reloadAll()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else {
                self?.refreshTimer?.invalidate()
                return
            }
            self.refreshPermissionsAndLogin()
        }
    }

    func reloadAll() {
        reloadKeyboardList()
        if let idx = TriggerModifier.allCases.firstIndex(of: AppSettings.shared.triggerModifier) {
            modifierPopup.selectItem(at: idx)
        }
        refreshPermissionsAndLogin()
    }

    func reloadKeyboardList() {
        var items = [KeyboardInfo.all] + KeyboardTracker.shared.keyboards
        let savedID = AppSettings.shared.targetKeyboardID
        if savedID != KeyboardInfo.all.id && !items.contains(where: { $0.id == savedID }) {
            items.append(KeyboardInfo(id: savedID, name: "已保存的键盘 (\(savedID)，未连接)"))
        }
        displayedKeyboards = items

        keyboardPopup.removeAllItems()
        for kb in items {
            keyboardPopup.addItem(withTitle: kb.name)
        }
        if let idx = items.firstIndex(where: { $0.id == savedID }) {
            keyboardPopup.selectItem(at: idx)
        }
    }

    private func refreshPermissionsAndLogin() {
        launchCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        let axGranted = AXIsProcessTrusted()
        axStatusLabel.stringValue = axGranted ? "已授权 ✓" : "未授权（必需）"
        axStatusLabel.textColor = axGranted ? .systemGreen : .systemOrange

        let hidGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let needsHID = AppSettings.shared.targetKeyboardID != KeyboardInfo.all.id
        if hidGranted {
            hidStatusLabel.stringValue = "已授权 ✓"
            hidStatusLabel.textColor = .systemGreen
        } else {
            hidStatusLabel.stringValue = needsHID ? "未授权（指定键盘必需）" : "未授权（当前无需）"
            hidStatusLabel.textColor = needsHID ? .systemOrange : .secondaryLabelColor
        }
    }

    @objc private func keyboardChanged() {
        let idx = keyboardPopup.indexOfSelectedItem
        guard displayedKeyboards.indices.contains(idx) else { return }
        let selected = displayedKeyboards[idx]
        AppSettings.shared.targetKeyboardID = selected.id
        if selected.id != KeyboardInfo.all.id && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        refreshPermissionsAndLogin()
        AppController.shared.refreshMenuStatus()
    }

    @objc private func refreshKeyboards() {
        KeyboardTracker.shared.refreshDevices()
    }

    @objc private func modifierChanged() {
        let idx = modifierPopup.indexOfSelectedItem
        guard TriggerModifier.allCases.indices.contains(idx) else { return }
        AppSettings.shared.triggerModifier = TriggerModifier.allCases[idx]
        AppController.shared.refreshMenuStatus()
    }

    @objc private func launchChanged() {
        AppController.shared.setLaunchAtLogin(launchCheckbox.state == .on)
        refreshPermissionsAndLogin()
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoring() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - App Controller & Event Tap
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppController()

    private let hud = SwitcherHUD()
    private lazy var settingsWC = SettingsWindowController()
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?
    private var mruApps: [NSRunningApplication] = []
    private var sessionApps: [NSRunningApplication] = []
    private var selectedIndex = 0
    private var isSwitching = false
    private var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        setupStatusBar()
        observeWorkspace()
        _ = syncRunningApps()

        KeyboardTracker.shared.onDevicesChanged = { [weak self] in
            self?.settingsWC.reloadKeyboardList()
        }
        KeyboardTracker.shared.start()
        startEventTapWhenTrusted()
    }

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "TabSwitch") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let styled = icon.withSymbolConfiguration(config) ?? icon
            styled.isTemplate = true
            item.button?.image = styled
        } else {
            item.button?.title = "TS"
        }

        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "TabSwitch：等待辅助功能权限...", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "偏好设置...", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 TabSwitch", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        statusMenuItem = status
        launchAtLoginItem = loginItem
        refreshLaunchAtLoginState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLaunchAtLoginState()
        refreshMenuStatus()
    }

    func refreshMenuStatus() {
        if eventTap != nil {
            statusMenuItem?.title = "TabSwitch：运行中 ✓（\(AppSettings.shared.triggerModifier.shortName)）"
        } else {
            statusMenuItem?.title = "TabSwitch：等待辅助功能权限..."
        }
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        refreshLaunchAtLoginState()
    }

    @objc private func openSettings() {
        settingsWC.show()
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(SMAppService.mainApp.status != .enabled)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self.mruApps.removeAll { $0.processIdentifier == app.processIdentifier }
            self.mruApps.insert(app, at: 0)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.mruApps.removeAll { $0.processIdentifier == app.processIdentifier }
        }
    }

    private func syncRunningApps() -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let alivePIDs = Set(running.map(\.processIdentifier))
        mruApps.removeAll { !alivePIDs.contains($0.processIdentifier) }
        for app in running where !mruApps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
            mruApps.append(app)
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           let idx = mruApps.firstIndex(where: { $0.processIdentifier == front.processIdentifier }),
           idx != 0 {
            mruApps.insert(mruApps.remove(at: idx), at: 0)
        }
        return mruApps
    }

    private func startEventTapWhenTrusted() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) && createEventTap() { return }

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            if AXIsProcessTrusted() && self.createEventTap() {
                timer.invalidate()
            }
        }
    }

    private func createEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, _ in
            AppController.shared.handleEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: nil
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        refreshMenuStatus()
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !sessionApps.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + sessionApps.count) % sessionApps.count
        hud.updateSelection(apps: sessionApps, selectedIndex: selectedIndex)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let trigger = AppSettings.shared.triggerModifier
        let flags = event.flags
        let hasTrigger = flags.contains(trigger.cgFlag)

        switch type {
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            let forbiddenPressed = trigger.forbiddenFlags.contains { flags.contains($0) }
            if keyCode == KeyCode.tab && hasTrigger && !forbiddenPressed {
                if !isSwitching {
                    guard KeyboardTracker.shared.matchesTargetKeyboard() else {
                        return Unmanaged.passUnretained(event)
                    }
                    let apps = syncRunningApps()
                    guard !apps.isEmpty else { return nil }
                    let step = flags.contains(.maskShift) ? -1 : 1
                    isSwitching = true
                    sessionApps = apps
                    selectedIndex = apps.count > 1 ? (step > 0 ? 1 : apps.count - 1) : 0
                    hud.render(apps: sessionApps, selectedIndex: selectedIndex)
                    hud.orderFrontRegardless()
                } else {
                    moveSelection(by: flags.contains(.maskShift) ? -1 : 1)
                }
                return nil
            }

            guard isSwitching else { break }

            switch keyCode {
            case KeyCode.esc:
                cancelSwitching()
                return nil
            case KeyCode.left:
                moveSelection(by: -1)
                return nil
            case KeyCode.right:
                moveSelection(by: 1)
                return nil
            case KeyCode.q:
                sessionApps.remove(at: selectedIndex).terminate()
                if sessionApps.isEmpty {
                    cancelSwitching()
                } else {
                    selectedIndex = min(selectedIndex, sessionApps.count - 1)
                    hud.render(apps: sessionApps, selectedIndex: selectedIndex)
                }
                return nil
            case KeyCode.h:
                sessionApps[selectedIndex].hide()
                return nil
            default:
                break
            }

        case .keyUp:
            if isSwitching {
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == KeyCode.tab || keyCode == KeyCode.left || keyCode == KeyCode.right {
                    return nil
                }
            }

        case .flagsChanged:
            if isSwitching && !hasTrigger {
                commitSwitching()
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func commitSwitching() {
        isSwitching = false
        hud.orderOut(nil)
        if sessionApps.indices.contains(selectedIndex) {
            let target = sessionApps[selectedIndex]
            target.unhide()
            target.activate(options: .activateAllWindows)
        }
        sessionApps.removeAll(keepingCapacity: true)
    }

    private func cancelSwitching() {
        isSwitching = false
        hud.orderOut(nil)
        sessionApps.removeAll(keepingCapacity: true)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = AppController.shared
app.run()
