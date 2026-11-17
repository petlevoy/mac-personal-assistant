import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 62,y: 62,width: 900,height: 900),xRadius: 210,yRadius: 210)
        NSGradient(starting: NSColor(calibratedWhite: 0.78, alpha: 1), ending: NSColor(calibratedWhite: 0.98, alpha: 1))!.draw(in: tile, angle: 90)
        NSColor(calibratedWhite: 0.65, alpha: 1).setStroke(); tile.lineWidth = 3; tile.stroke()
        NSColor(calibratedRed: 0.10,green: 0.37,blue: 0.84,alpha: 1).setStroke()
        let brackets = NSBezierPath()
        brackets.lineWidth = 66; brackets.lineCapStyle = .round; brackets.lineJoinStyle = .round
        brackets.move(to: NSPoint(x: 365,y: 735))
        brackets.curve(to: NSPoint(x: 280,y: 650),controlPoint1: NSPoint(x: 290,y: 735),controlPoint2: NSPoint(x: 280,y: 710))
        brackets.line(to: NSPoint(x: 280,y: 374))
        brackets.curve(to: NSPoint(x: 365,y: 289),controlPoint1: NSPoint(x: 280,y: 314),controlPoint2: NSPoint(x: 290,y: 289))
        brackets.move(to: NSPoint(x: 659,y: 735))
        brackets.curve(to: NSPoint(x: 744,y: 650),controlPoint1: NSPoint(x: 734,y: 735),controlPoint2: NSPoint(x: 744,y: 710))
        brackets.line(to: NSPoint(x: 744,y: 374))
        brackets.curve(to: NSPoint(x: 659,y: 289),controlPoint1: NSPoint(x: 744,y: 314),controlPoint2: NSPoint(x: 734,y: 289))
        brackets.stroke()
        NSColor(calibratedRed: 0.10,green: 0.37,blue: 0.84,alpha: 1).setFill()
        let gear = NSBezierPath()
        for tooth in 0..<12 {
            for (offset, radius) in [(0.0, 146.0), (0.16, 177.0), (0.66, 177.0), (0.82, 146.0)] {
                let angle = (Double(tooth) + offset) * Double.pi / 6
                let point = NSPoint(x: 512 + cos(angle) * radius, y: 512 + sin(angle) * radius)
                if tooth == 0 && offset == 0 { gear.move(to: point) } else { gear.line(to: point) }
            }
        }
        gear.close()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0, height: -7)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.48, alpha: 1).setFill(); gear.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.72, alpha: 1), ending: NSColor(calibratedRed: 0.38, green: 0.7, blue: 1.0, alpha: 1))!.draw(in: gear, angle: 90)
        NSColor(calibratedRed: 0.05, green: 0.26, blue: 0.57, alpha: 1).setStroke(); gear.lineWidth = 3; gear.stroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 400,y: 400,width: 224,height: 224))
        NSGradient(starting: NSColor(calibratedRed: 0.04, green: 0.2, blue: 0.48, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.85, alpha: 1))!.draw(in: ring, angle: 90)
        NSColor(calibratedRed: 0.68, green: 0.85, blue: 1.0, alpha: 1).setStroke(); ring.lineWidth = 5; ring.stroke()
        let hub = NSBezierPath(ovalIn: NSRect(x: 434,y: 434,width: 156,height: 156))
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.83, alpha: 1), ending: NSColor(calibratedRed: 0.42, green: 0.75, blue: 1.0, alpha: 1))!.draw(in: hub, angle: 90)
        NSColor(calibratedRed: 0.05, green: 0.26, blue: 0.57, alpha: 1).setStroke(); hub.lineWidth = 3; hub.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
