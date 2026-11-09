// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: factor, y: factor)
        let shape = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(srgbRed: 0.19, green: 0.70, blue: 0.53, alpha: 1), ending: NSColor(srgbRed: 0.06, green: 0.35, blue: 0.28, alpha: 1))!.draw(in: shape, angle: -65)
        NSColor.white.setFill()
        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: 300, y: 290))
        leaf.curve(to: NSPoint(x: 730, y: 725), controlPoint1: NSPoint(x: 210, y: 600), controlPoint2: NSPoint(x: 570, y: 650))
        leaf.curve(to: NSPoint(x: 300, y: 290), controlPoint1: NSPoint(x: 830, y: 390), controlPoint2: NSPoint(x: 520, y: 200))
        leaf.fill()
        let vein = NSBezierPath()
        vein.move(to: NSPoint(x: 272, y: 250))
        vein.curve(to: NSPoint(x: 630, y: 600), controlPoint1: NSPoint(x: 380, y: 350), controlPoint2: NSPoint(x: 480, y: 480))
        vein.lineWidth = 35
        vein.lineCapStyle = .round
        NSColor(srgbRed: 0.13, green: 0.52, blue: 0.40, alpha: 1).setStroke()
        vein.stroke()
        let sparkle = NSBezierPath()
        for (index, point) in [NSPoint(x: 768, y: 832), NSPoint(x: 790, y: 777), NSPoint(x: 845, y: 755), NSPoint(x: 790, y: 733), NSPoint(x: 768, y: 678), NSPoint(x: 746, y: 733), NSPoint(x: 691, y: 755), NSPoint(x: 746, y: 777)].enumerated() {
            if index == 0 { sparkle.move(to: point) } else { sparkle.line(to: point) }
        }
        sparkle.close()
        NSColor(srgbRed: 0.98, green: 0.85, blue: 0.45, alpha: 1).setFill()
        sparkle.fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
