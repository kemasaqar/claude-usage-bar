import AppKit
import UsageCore

enum Palette {
    static let warning = NSColor(srgbRed: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255, alpha: 1)
    static let critical = NSColor(srgbRed: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255, alpha: 1)

    static func color(_ level: Level) -> NSColor? {
        switch level {
        case .normal: return nil
        case .warning: return warning
        case .critical: return critical
        }
    }
}

/// The menu bar icon: a ring, a gap, then a disc that drains from the top
/// like a battery. Full when nothing is used, empty at 100%. A template
/// image, so macOS tints it to match the menu bar.
func batteryIcon(remaining: Double, size: CGFloat = 16) -> NSImage {
    let ring: CGFloat = 1.5, gap: CGFloat = 1.5, margin: CGFloat = 0.5
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSColor.black.set()
        let outer = rect.insetBy(dx: margin + ring / 2, dy: margin + ring / 2)
        let ringPath = NSBezierPath(ovalIn: outer)
        ringPath.lineWidth = ring
        ringPath.stroke()

        let disc = rect.insetBy(dx: margin + ring + gap, dy: margin + ring + gap)
        let level = disc.height * CGFloat(max(0, min(100, remaining)) / 100)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: disc.minX, y: disc.minY, width: disc.width, height: level)).addClip()
        NSBezierPath(ovalIn: disc).fill()
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    image.isTemplate = true
    return image
}

let menuWidth: CGFloat = 320
let inset: CGFloat = 14

/// One limit: label, progress bar with the even-pace marker, percentage,
/// and the reset line (orange when the current pace runs out first).
final class WindowRowView: NSView {
    let row: WindowRow

    init(row: WindowRow) {
        self.row = row
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: row.spend == nil ? 42 : 58))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let label = NSAttributedString(string: row.name.label, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        label.draw(at: NSPoint(x: inset, y: 4))

        let pct = String(format: "%.1f%%", row.percent)
        let pctText = NSAttributedString(string: pct, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: Palette.color(row.level) ?? NSColor.labelColor,
        ])
        let pctWidth = pctText.size().width
        pctText.draw(at: NSPoint(x: bounds.width - inset - pctWidth, y: 4))

        // Bar between the label column and the percentage.
        let barX: CGFloat = inset + 54
        let bar = NSRect(x: barX, y: 10, width: bounds.width - inset - 60 - barX, height: 7)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3.5, yRadius: 3.5).fill()
        let fill = NSRect(x: bar.minX, y: bar.minY,
                          width: bar.width * CGFloat(min(100, max(0, row.percent)) / 100), height: bar.height)
        (Palette.color(row.level) ?? NSColor.labelColor.withAlphaComponent(0.8)).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3.5, yRadius: 3.5).fill()
        if let mark = row.paceMark {
            // Where an even pace would put you now.
            let x = (bar.minX + bar.width * CGFloat(mark)).rounded() + 0.5
            NSColor.labelColor.setFill()
            NSRect(x: x - 0.75, y: bar.minY - 3, width: 1.5, height: bar.height + 6).fill()
        }

        var detail = row.detail
        var detailColor = NSColor.secondaryLabelColor
        if let out = row.runsOut {
            detail += " · runs out ~\(out)"
            detailColor = Palette.warning
        }
        NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: detailColor,
        ]).draw(at: NSPoint(x: inset, y: 23))
        if let spend = row.spend {
            NSAttributedString(string: spend, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(at: NSPoint(x: inset, y: 39))
        }
    }
}

/// A line of text in the menu that isn't a command. Plain disabled menu
/// items render grey and hard to read; a view keeps normal colors.
final class InfoRowView: NSView {
    private let text: NSAttributedString

    init(_ string: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let height = text.boundingRect(
            with: NSSize(width: menuWidth - 2 * inset, height: 1000),
            options: [.usesLineFragmentOrigin]).height
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: ceil(height) + 6))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(with: NSRect(x: inset, y: 3, width: bounds.width - 2 * inset, height: bounds.height),
                  options: [.usesLineFragmentOrigin])
    }
}

func titleString(_ model: MenuModel) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        .baselineOffset: 0.5,
    ]
    if let color = Palette.color(model.titleLevel) { attributes[.foregroundColor] = color }
    return NSAttributedString(string: " " + model.title, attributes: attributes)
}
