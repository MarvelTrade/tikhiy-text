import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "/tmp/TikhiyTextIcon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSGraphicsContext.current?.imageInterpolation = .high

// 1. macOS Squircle Canvas (100pt margin around 824x824)
let bgRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let outerPath = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)

// Soft drop shadow
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.shadowBlurRadius = 36
shadow.set()
NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.14, alpha: 1).setFill()
outerPath.fill()
NSGraphicsContext.restoreGraphicsState()

// Deep Obsidian-Slate Gradient Background
outerPath.addClip()
let bgGrad = NSGradient(colors: [
    NSColor(calibratedRed: 0.043, green: 0.067, blue: 0.118, alpha: 1),
    NSColor(calibratedRed: 0.075, green: 0.118, blue: 0.196, alpha: 1),
    NSColor(calibratedRed: 0.055, green: 0.145, blue: 0.175, alpha: 1)
])!
bgGrad.draw(in: bgRect, angle: -45)

// Ambient Emerald & Cyan Glow
if let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.62, alpha: 0.28),
    NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.62, alpha: 0.0)
]) {
    glow.draw(fromCenter: NSPoint(x: 340, y: 660), radius: 20, toCenter: NSPoint(x: 340, y: 660), radius: 480, options: [])
}
if let cyanGlow = NSGradient(colors: [
    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.22),
    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.0)
]) {
    cyanGlow.draw(fromCenter: NSPoint(x: 720, y: 320), radius: 10, toCenter: NSPoint(x: 720, y: 320), radius: 420, options: [])
}

// Subtle Inner Glass Rim
let rimPath = NSBezierPath(roundedRect: bgRect.insetBy(dx: 4, dy: 4), xRadius: 181, yRadius: 181)
rimPath.lineWidth = 5
NSColor.white.withAlphaComponent(0.14).setStroke()
rimPath.stroke()

// 2. Inner Frosted Card (Centerpiece)
let glassRect = NSRect(x: 206, y: 206, width: 612, height: 612)
let glassPath = NSBezierPath(roundedRect: glassRect, xRadius: 112, yRadius: 112)
NSColor.white.withAlphaComponent(0.065).setFill()
glassPath.fill()
glassPath.lineWidth = 3
NSColor.white.withAlphaComponent(0.16).setStroke()
glassPath.stroke()

// 3. Luminous Emerald-to-Cyan Audio Waveform Bars (Top Half of Card)
let barHeights: [CGFloat] = [110, 200, 290, 175, 250, 145, 215]
let barWidth: CGFloat = 34
let gap: CGFloat = 28
let startX: CGFloat = 512 - (CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap) / 2
let waveCenterY: CGFloat = 585

let waveGrad = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.85, blue: 0.64, alpha: 1),
    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 1)
])!

for (idx, h) in barHeights.enumerated() {
    let x = startX + CGFloat(idx) * (barWidth + gap)
    let barRect = NSRect(x: x, y: waveCenterY - h / 2, width: barWidth, height: h)
    let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    waveGrad.draw(in: barPath, angle: 90)
}

// 4. Crisp Transcript Text Lines (Bottom Half of Card)
let lineWidths: [CGFloat] = [390, 310, 210]
for (idx, w) in lineWidths.enumerated() {
    let y = 370 - CGFloat(idx) * 46
    let lineRect = NSRect(x: 317, y: y, width: w, height: 20)
    let linePath = NSBezierPath(roundedRect: lineRect, xRadius: 10, yRadius: 10)
    let alpha: CGFloat = idx == 0 ? 0.88 : (idx == 1 ? 0.55 : 0.35)
    NSColor.white.withAlphaComponent(alpha).setFill()
    linePath.fill()
}

// 5. Sleek Stop-Frame Viewfinder Accent Badge (Bottom-Right Corner)
let badgeRect = NSRect(x: 642, y: 238, width: 132, height: 132)
let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 38, yRadius: 38)
let badgeGrad = NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.82, blue: 0.62, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.62, blue: 0.52, alpha: 1)
])!
badgeGrad.draw(in: badgePath, angle: -45)
badgePath.lineWidth = 4
NSColor.white.withAlphaComponent(0.35).setStroke()
badgePath.stroke()

// Camera lens ring inside badge
let center = NSPoint(x: badgeRect.midX, y: badgeRect.midY)
let lensOuter = NSBezierPath(ovalIn: NSRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64))
lensOuter.lineWidth = 9
NSColor.white.setStroke()
lensOuter.stroke()

let lensInner = NSBezierPath(ovalIn: NSRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))
NSColor.white.setFill()
lensInner.fill()

image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
