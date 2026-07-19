// AppIcon.swift — the app icon, drawn at runtime (Dock icon + .icns source).

import AppKit

func makeAppIcon(_ px: CGFloat = 512) -> NSImage {
    return NSImage(size: NSSize(width: px, height: px), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let rgb = CGColorSpaceCreateDeviceRGB()

        // Rounded-square body with a vertical gradient (macOS-ish squircle).
        let body = CGRect(x: 0, y: 0, width: px, height: px).insetBy(dx: px * 0.055, dy: px * 0.055)
        let corner = body.width * 0.235
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner).addClip()
        let bgTop = NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.23, alpha: 1).cgColor
        let bgBot = NSColor(calibratedRed: 0.04, green: 0.07, blue: 0.10, alpha: 1).cgColor
        ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [bgTop, bgBot] as CFArray, locations: [0, 1])!,
                               start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

        // 2×2 grid of camera tiles.
        let area = body.insetBy(dx: body.width * 0.17, dy: body.width * 0.17)
        let gap = body.width * 0.05
        let tw = (area.width - gap) / 2, th = (area.height - gap) / 2
        let teal = NSColor(calibratedRed: 0.16, green: 0.74, blue: 0.80, alpha: 1)
        for row in 0..<2 { for col in 0..<2 {
            let tile = CGRect(x: area.minX + CGFloat(col) * (tw + gap),
                              y: area.minY + CGFloat(row) * (th + gap), width: tw, height: th)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: tile, xRadius: tw * 0.16, yRadius: tw * 0.16).addClip()
            let hi = teal.blended(withFraction: 0.10, of: .white)!.cgColor
            let lo = teal.blended(withFraction: 0.45, of: .black)!.cgColor
            ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [hi, lo] as CFArray, locations: [0, 1])!,
                                   start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
            NSGraphicsContext.restoreGraphicsState()
        }}

        // "Live" red dot on the top-right tile.
        let r = tw * 0.12
        let c = CGPoint(x: area.maxX - tw * 0.24, y: area.maxY - th * 0.24)
        NSColor(calibratedRed: 0.95, green: 0.27, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
}
