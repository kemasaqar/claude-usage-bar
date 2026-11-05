import AppKit
import UsageCore

/// Draws the menu bar item and its open menu into a PNG, with the same views
/// the app uses, in dark mode. For the README, and for checking the menu
/// without clicking it. Scenarios use made-up numbers; "now" uses yours.
enum Preview {
    static func render(scenario: String, to url: URL, paths: UsagePaths,
                       scalePercent: Int = TextScale.defaultPercent) throws {
        _ = NSApplication.shared
        let now = Date().timeIntervalSince1970 + 30  // so "3h 00m" doesn't read 2h 59m
        let model: MenuModel
        switch scenario {
        case "now":
            model = MenuModel.build(
                cache: UsageCache.load(paths.cache), probeState: AutoCheck.loadState(paths),
                paused: AutoCheck.isPaused(paths), now: now, staleAfter: paths.staleAfter)
        case "heading-over":
            model = example(fiveHour: (48, 2 * 3600), sevenDay: (41, 3 * 86400 + 20 * 3600), now: now)
        case "on-track":
            model = example(fiveHour: (22, 2 * 3600), sevenDay: (30, 3 * 86400 + 12 * 3600), now: now)
        default:
            throw CheckError("unknown scenario \(scenario); use heading-over, on-track or now")
        }
        try png(of: canvas(model, scale: CGFloat(TextScale.factor(scalePercent))), to: url)
    }

    /// (used %, seconds since the window started) per window.
    static func example(fiveHour: (Double, Double), sevenDay: (Double, Double), now: Double) -> MenuModel {
        func window(_ name: WindowName, _ spec: (Double, Double)) -> Window {
            Window(usedPercentage: spec.0, resetsAt: now + name.length! - spec.1)
        }
        let cache = UsageCache(
            windows: [.fiveHour: window(.fiveHour, fiveHour), .sevenDay: window(.sevenDay, sevenDay)],
            updatedAt: now, checkedAt: now)
        return MenuModel.build(cache: cache, probeState: ["last_run": now - 120, "ok": true],
                               paused: false, now: now, staleAfter: 3600)
    }

    /// The menu bar item stays at its fixed size; the menu below it scales.
    static func canvas(_ model: MenuModel, scale: CGFloat = 1) -> NSView {
        var views: [NSView] = [MenuBarItemView(model: model)]
        var menu: [NSView] = model.rows.map { WindowRowView(row: $0, scale: scale) }
        menu.append(Separator(scale: scale))
        if let last = model.lastReading { menu.append(InfoRowView(last, scale: scale)) }
        menu.append(Separator(scale: scale))
        menu.append(InfoRowView(model.autoCheck, scale: scale))
        for title in [model.paused ? "Resume auto-check" : "Pause auto-check", "Check now"] {
            menu.append(InfoRowView(title, size: 13, color: .labelColor, scale: scale))
        }
        views.append(MenuPanel(views: menu))

        let height = views.reduce(0) { $0 + $1.frame.height } + 6
        let width = views.map(\.frame.width).max() ?? menuWidth
        let root = Flipped(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y: CGFloat = 0
        for view in views {
            view.setFrameOrigin(NSPoint(x: 0, y: y))
            root.addSubview(view)
            y += view.frame.height + 6
        }
        root.appearance = NSAppearance(named: .darkAqua)
        return root
    }

    static func png(of view: NSView, to url: URL) throws {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CheckError("couldn't create the image") }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CheckError("couldn't encode the PNG")
        }
        try data.write(to: url)
    }
}

private class Flipped: NSView {
    override var isFlipped: Bool { true }
}

/// The item as it sits in a blue menu bar: white icon and title.
private final class MenuBarItemView: Flipped {
    let model: MenuModel

    init(model: MenuModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 26))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0x3E / 255, green: 0x68 / 255, blue: 0xA6 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        // Template icon drawn white, the way macOS shows it on a dark bar.
        let icon = batteryIcon(remaining: model.remaining)
        let white = NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: NSRect(x: inset, y: 5, width: 16, height: 16))
        let title = NSMutableAttributedString(attributedString: titleString(model))
        if Palette.color(model.titleLevel) == nil {
            title.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: title.length))
        }
        title.draw(at: NSPoint(x: inset + 17, y: 4))
    }
}

private final class MenuPanel: Flipped {
    init(views: [NSView]) {
        let height = views.reduce(0) { $0 + $1.frame.height } + 10
        let width = views.map(\.frame.width).max() ?? menuWidth
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y: CGFloat = 5
        for view in views {
            view.setFrameOrigin(NSPoint(x: 0, y: y))
            addSubview(view)
            y += view.frame.height
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0x2A / 255, green: 0x2A / 255, blue: 0x2C / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

private final class Separator: Flipped {
    init(scale: CGFloat = 1) { super.init(frame: NSRect(x: 0, y: 0, width: menuWidth * scale, height: 11)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: inset, y: 5, width: bounds.width - 2 * inset, height: 1).fill()
    }
}
