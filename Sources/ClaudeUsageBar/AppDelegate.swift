import AppKit
import UsageCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let paths: UsagePaths
    private var statusItem: NSStatusItem!
    private var model: MenuModel?
    private var timers: [Timer] = []
    private var checking = false

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
        // whether a request is due (at most every 5 minutes).
        timers = [
            Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.autoCheck() },
        ]
        autoCheck()
    }

    // MARK: Data

    private func refresh() {
        let now = Date().timeIntervalSince1970
        let model = MenuModel.build(
            cache: UsageCache.load(paths.cache), probeState: AutoCheck.loadState(paths),
            paused: AutoCheck.isPaused(paths), now: now, staleAfter: paths.staleAfter)
        self.model = model
        guard let button = statusItem?.button else { return }
        button.image = batteryIcon(remaining: model.remaining)
        button.attributedTitle = titleString(model)
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

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        guard let model else { return }
        menu.removeAllItems()

        if model.hasData {
            for row in model.rows { menu.addItem(viewItem(WindowRowView(row: row))) }
            menu.addItem(.separator())
            if let last = model.lastReading { menu.addItem(viewItem(InfoRowView(last))) }
            if let note = model.staleNote { menu.addItem(viewItem(InfoRowView(note))) }
        } else {
            menu.addItem(viewItem(InfoRowView("No usage data yet", size: 13, color: .labelColor)))
            menu.addItem(viewItem(InfoRowView(
                "Send a message in Claude Code, or use Check now. Limits appear only on Pro/Max plans.")))
        }

        menu.addItem(.separator())
        menu.addItem(viewItem(InfoRowView(model.autoCheck)))
        if let error = model.autoCheckError {
            menu.addItem(viewItem(InfoRowView(error, color: Palette.critical)))
        }
        menu.addItem(item(model.paused ? "Resume auto-check" : "Pause auto-check", #selector(togglePause)))
        menu.addItem(item("Check now", #selector(checkNow), key: "r"))

        menu.addItem(.separator())
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
