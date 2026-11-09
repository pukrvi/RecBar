import AppKit
import Foundation

// Draws the DMG window background: title, version, drag arrow, and the
// first-launch hint for the ad-hoc signed build.
//
// Usage: make_dmg_background <output.png> <version>
guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make_dmg_background <output.png> <version>\n".utf8))
    exit(2)
}

let outputPath = CommandLine.arguments[1]
let version = CommandLine.arguments[2]
let width: CGFloat = 660
let height: CGFloat = 400
let scale: CGFloat = 2

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width * scale),
    pixelsHigh: Int(height * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("could not allocate background bitmap\n".utf8))
    exit(1)
}
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("could not create background context\n".utf8))
    exit(1)
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.105, alpha: 1),
    ending: NSColor(calibratedRed: 0.075, green: 0.12, blue: 0.22, alpha: 1)
)
gradient?.draw(in: bounds, angle: 90)

// The drag arrow sits on the icon centres. In the shipped window the 128 pt
// icons centre at y=190 in this 400 pt-tall image; Finder's icon-view position
// is the top of the icon cell, which is why the raw {165, 200} value is not the
// centre used for drawing.
let iconCenterY: CGFloat = 190

// A subtle glow behind the drag arrow.
let glow = NSBezierPath(ovalIn: NSRect(x: 210, y: iconCenterY - 65, width: 240, height: 130))
NSColor(calibratedRed: 0.22, green: 0.38, blue: 0.72, alpha: 0.14).setFill()
glow.fill()

func drawCentered(_ text: String, font: NSFont, color: NSColor, y: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    (text as NSString).draw(
        at: NSPoint(x: (width - size.width) / 2, y: y),
        withAttributes: attributes
    )
}

drawCentered(
    "RecBar",
    font: NSFont.systemFont(ofSize: 30, weight: .bold),
    color: .white,
    y: 322
)
drawCentered(
    "Version \(version)",
    font: NSFont.systemFont(ofSize: 12, weight: .medium),
    color: NSColor(calibratedWhite: 0.72, alpha: 1),
    y: 300
)

// Divider under the title.
let divider = NSBezierPath()
divider.lineWidth = 1
divider.move(to: NSPoint(x: 250, y: 286))
divider.line(to: NSPoint(x: 410, y: 286))
NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
divider.stroke()

// Arrow between the app icon and the Applications folder.
let arrowColor = NSColor(calibratedRed: 0.45, green: 0.64, blue: 1.0, alpha: 1)
let shaft = NSBezierPath()
shaft.lineWidth = 3
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 258, y: iconCenterY))
shaft.line(to: NSPoint(x: 388, y: iconCenterY))
arrowColor.setStroke()
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 398, y: iconCenterY))
head.line(to: NSPoint(x: 378, y: iconCenterY + 12))
head.line(to: NSPoint(x: 378, y: iconCenterY - 12))
head.close()
arrowColor.setFill()
head.fill()

// Icon labels are drawn by Finder just below the icons, so keep the only
// background text below them. The old "Drag RecBar to Applications" line sat
// at the same height and collided with the two icon labels.
drawCentered(
    "First launch: right-click RecBar → Open",
    font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
    color: NSColor(calibratedWhite: 0.62, alpha: 1),
    y: 45
)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode background PNG\n".utf8))
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outputPath))
