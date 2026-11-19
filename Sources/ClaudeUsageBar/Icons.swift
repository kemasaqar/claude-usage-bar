import AppKit
import UsageCore

/// The app icon, drawn from the same glyph as the menu bar icon. macOS
/// shows it in Finder, System Settings and on notifications.
enum Icons {
    /// A square PNG `pixels` wide, drawn in points with the origin at the
    /// bottom left (one point per pixel).
    static func png(pixels: Int, _ draw: (NSRect) -> Void) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { throw CheckError("couldn't create the image") }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CheckError("couldn't encode the PNG")
        }
        return data
    }

    // MARK: App icon

    /// An Icon Composer file (.icon) for actool: an amber gradient with the
    /// white battery about two thirds full as its one layer. macOS 26 adds
    /// the glass; actool also makes an .icns for older versions.
    static func writeIconFile(to folder: URL) throws {
        let assets = folder.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        // The canvas is the whole tile; the glyph takes the middle 60%.
        let glyph = try png(pixels: 1024) { canvas in
            drawBattery(in: canvas.insetBy(dx: 205, dy: 205), remaining: 65, color: .white,
                        empty: NSColor.white.withAlphaComponent(0.25))
        }
        try glyph.write(to: assets.appendingPathComponent("battery.png"))
        try iconJSON.write(to: folder.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    }

    /// Top F8B84A to bottom E8901A, around the menu's warning orange.
    static let iconJSON = """
    {
      "fill" : {
        "linear-gradient" : [
          "srgb:0.97255,0.72157,0.29020,1.00000",
          "srgb:0.90980,0.56471,0.10196,1.00000"
        ]
      },
      "groups" : [
        {
          "layers" : [
            { "image-name" : "battery.png", "name" : "battery" }
          ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "translucency" : { "enabled" : true, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : "shared" }
    }
    """
}
