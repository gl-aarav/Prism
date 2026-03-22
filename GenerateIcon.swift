import AppKit
import CoreGraphics

func generateIcon(name: String, triangleColor: NSColor) {
    let size = CGSize(width: 1024, height: 1024)
    let image = NSImage(size: size)

    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return
    }

    // Clear the context to ensure transparency
    context.clear(CGRect(origin: .zero, size: size))

    // Define the rounded rect path (Squircle approximation)
    let rect = CGRect(origin: .zero, size: size)
    let cornerRadius: CGFloat = 224.0  // ~22% of 1024

    // Use CGPath for clipping to ensure it affects the CGContext operations
    let clipPath = CGPath(
        roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    context.addPath(clipPath)
    context.clip()

    // Gradient Background (Cyan -> Blue -> Green)
    let colors =
        [
            NSColor.cyan.cgColor,
            NSColor.systemBlue.cgColor,
            NSColor.systemGreen.cgColor,
        ] as CFArray

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.5, 1.0])!

    let center = CGPoint(x: 512, y: 512)
    let radius = 900.0  // Slightly larger to cover corners

    context.drawRadialGradient(
        gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
        options: .drawsBeforeStartLocation)

    // Draw "Prism" Symbol (Triangle/Prism shape)
    let trianglePath = NSBezierPath()
    trianglePath.move(to: CGPoint(x: 512, y: 850))
    trianglePath.line(to: CGPoint(x: 200, y: 250))
    trianglePath.line(to: CGPoint(x: 824, y: 250))
    trianglePath.close()

    triangleColor.withAlphaComponent(0.2).setFill()
    trianglePath.fill()

    triangleColor.setStroke()
    trianglePath.lineWidth = 40
    trianglePath.stroke()

    // Add a shine/gloss effect
    let shinePath = NSBezierPath()
    shinePath.move(to: CGPoint(x: 512, y: 850))
    shinePath.line(to: CGPoint(x: 512, y: 250))
    triangleColor.withAlphaComponent(0.4).setStroke()
    shinePath.lineWidth = 10
    shinePath.stroke()

    image.unlockFocus()

    // Save to PNG
    if let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let pngData = bitmap.representation(using: .png, properties: [:])
    {
        let url = URL(fileURLWithPath: name)
        try! pngData.write(to: url)
        print("Icon generated at \(url.path)")
    }
}

// Generate Default Icon (White Triangle)
generateIcon(name: "AppIcon.png", triangleColor: .white)
