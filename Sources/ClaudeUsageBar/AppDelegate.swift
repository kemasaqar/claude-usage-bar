import AppKit
import UsageCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let paths: UsagePaths
    private var statusItem: NSStatusItem!
    private var model: MenuModel?
    private var timers: [Timer] = []
    private var checking = false
    /// The notification API needs the app bundle: in a bare `swift build`
    /// binary it aborts, so notifications aren't offered there.
    private let canNotify = Bundle.main.bundleIdentifier != nil
    /// What macOS said when asked to allow notifications; nil until it answers.
    private var notifyGranted: Bool?

    init(paths: UsagePaths) {
        self.paths = paths
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened twice (login item + by hand)? Keep the one already running.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0 != me && !$0.isTerminated }) {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        // Re-read the files often: the status line writes them on every
        // reply, and reading is cheap. Auto-check decides for itself
        // whether a request is due: every 5 minutes, or every minute while
        // the 5-hour limit is heading over. Asking every 15s keeps that
        // 1 minute close to 1 minute.
        timers = [
            Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                self?.refresh()
                self?.autoCheck()
                self?.askAgainIfBlocked()
            },
        ]
        autoCheck()
        if notifyStep > 0 { askToNotify() }
    }

    // MARK: Data

    private func refresh() {
        let now = Date().timeIntervalSince1970
        let model = MenuModel.build(
            cache: UsageCache.load(paths.cache), probeState: AutoCheck.loadState(paths),
            paused: AutoCheck.isPaused(paths), now: now, staleAfter: paths.staleAfter)
        self.model = model
        sendAlerts(model)
        guard let button = statusItem?.button else { return }
        button.image = batteryIcon(remaining: model.remaining)
        button.attributedTitle = titleString(model)
    }

    /// Size of the open menu's content, saved in the app's preferences.
    private var scalePercent: Int {
        get { TextScale.sanitize(UserDefaults.standard.object(forKey: TextScale.defaultsKey) as? Int) }
        set { UserDefaults.standard.set(TextScale.sanitize(newValue), forKey: TextScale.defaultsKey) }
    }

    private func autoCheck(force: Bool = false) {
        guard !checking else { return }
        checking = true
        let paths = self.paths
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let now = Date().timeIntervalSince1970
            if force {
                _ = AutoCheck.check(now: now, paths: paths)
            } else {
                AutoCheck.auto(now: now, paths: paths)
            }
            DispatchQueue.main.async {
                self?.checking = false
                self?.refresh()
            }
        }
    }

    // MARK: Notifications

    /// A notification every this many percent: picked in the menu, saved in
    /// the app's preferences. 0 is off.
    private var notifyStep: Int {
        get { canNotify ? UserDefaults.standard.integer(forKey: Alerts.stepKey) : 0 }
        set { UserDefaults.standard.set(newValue, forKey: Alerts.stepKey) }
    }

    /// macOS shows its prompt only the first time; after that it answers
    /// straight away. So this also runs at every launch: if an update lost
    /// the permission, you're asked again instead of hearing nothing.
    private func askToNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notifyGranted = granted
                self?.refresh()
            }
        }
    }

    /// After a no, keep asking: macOS answers without a prompt, so allowing
    /// notifications in System Settings is noticed within seconds.
    private func askAgainIfBlocked() {
        if notifyStep > 0, notifyGranted == false { askToNotify() }
    }

    private func sendAlerts(_ model: MenuModel) {
        // Without a reading there's nothing to say, and nothing sent to forget.
        guard notifyStep > 0, notifyGranted == true, model.hasData else { return }
        let defaults = UserDefaults.standard
        let before = defaults.stringArray(forKey: Alerts.sentKey) ?? []
        var sent = before
        for alert in Alerts.due(model.rows, every: notifyStep, sent: &sent) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if sent != before { defaults.set(sent, forKey: Alerts.sentKey) }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        guard let model else { return }
        menu.removeAllItems()
        let scale = CGFloat(TextScale.factor(scalePercent))
        // Plain command items follow the menu's font.
        menu.font = NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize * scale)

        if model.hasData {
            for row in model.rows { menu.addItem(viewItem(WindowRowView(row: row, scale: scale))) }
            menu.addItem(.separator())
            if let last = model.lastReading { menu.addItem(viewItem(InfoRowView(last, scale: scale))) }
            if let note = model.staleNote { menu.addItem(viewItem(InfoRowView(note, scale: scale))) }
        } else {
            menu.addItem(viewItem(InfoRowView("No usage data yet", size: 13, color: .labelColor, scale: scale)))
            menu.addItem(viewItem(InfoRowView(
                "Send a message in Claude Code, or use Check now. Limits appear only on Pro/Max plans.",
                scale: scale)))
        }

        menu.addItem(.separator())
        menu.addItem(viewItem(InfoRowView(model.autoCheck, scale: scale)))
        if let error = model.autoCheckError {
            menu.addItem(viewItem(InfoRowView(error, color: Palette.critical, scale: scale)))
        }
        menu.addItem(item(model.paused ? "Resume auto-check" : "Pause auto-check", #selector(togglePause)))
        menu.addItem(item("Check now", #selector(checkNow), key: "r"))

        menu.addItem(.separator())
        let sizes = NSMenu()
        sizes.font = menu.font
        for percent in TextScale.steps {
            let size = item("\(percent)%", #selector(setTextSize(_:)))
            size.tag = percent
            size.state = percent == scalePercent ? .on : .off
            sizes.addItem(size)
        }
        let textSize = NSMenuItem(title: "Text size", action: nil, keyEquivalent: "")
        textSize.submenu = sizes
        menu.addItem(textSize)
        if canNotify {
            let steps = NSMenu()
            steps.font = menu.font
            for percent in [0] + Alerts.steps {
                let step = item(percent == 0 ? "Off" : "Every \(percent)%", #selector(setNotifyStep(_:)))
                step.tag = percent
                step.state = percent == notifyStep ? .on : .off
                steps.addItem(step)
            }
            let notify = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
            notify.submenu = steps
            menu.addItem(notify)
            // macOS said no: its prompt takes any click but Allow as one.
            if notifyStep > 0, notifyGranted == false {
                menu.addItem(item("Allow in System Settings…", #selector(openNotificationSettings)))
            }
        }
        let login = item("Open at login", #selector(toggleLogin))
        login.state = LoginItem.isEnabled(paths) ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Show cache file", #selector(showCache)))
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func togglePause() {
        if AutoCheck.isPaused(paths) {
            AutoCheck.resume(paths)
        } else {
            try? AutoCheck.pause(paths)
        }
        refresh()
    }

    @objc private func checkNow() { autoCheck(force: true) }

    @objc private func setTextSize(_ sender: NSMenuItem) {
        scalePercent = sender.tag
        refresh()
    }

    @objc private func setNotifyStep(_ sender: NSMenuItem) {
        notifyStep = sender.tag
        if notifyStep > 0 { askToNotify() }
    }

    /// This app's page in System Settings → Notifications.
    @objc private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        if LoginItem.isEnabled(paths) {
            LoginItem.disable(paths)
        } else {
            try? LoginItem.enable(appPath: Bundle.main.bundlePath, paths: paths)
        }
    }

    @objc private func showCache() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.cache])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
