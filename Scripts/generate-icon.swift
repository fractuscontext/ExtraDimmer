import AppKit
// generate_icon.swift
import SwiftUI

@MainActor
func generateIcon() {
    let size: CGFloat = 1024
    let cornerRadius: CGFloat = 226  // Standard Apple squircle radius

    let view = ZStack {
        // 1. The exact flat #3b304a background
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(red: 59 / 255, green: 48 / 255, blue: 74 / 255))

        // 2. The macOS "invisible" edge highlight.
        // Gives the flat tile a tangible, physical edge without making it 3D.
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.15), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 2
            )

        // 3. The Star
        Image(systemName: "star.leadinghalf.fill")
            .resizable()
            .scaledToFit()
            // A slightly richer "Warm Gold" helps contrast against a muted purple
            .foregroundStyle(Color(red: 255 / 255, green: 204 / 255, blue: 0 / 255))
            // 760px fills the space aggressively, but leaves enough margin
            // so the icon doesn't feel squashed by the squircle corners.
            .frame(width: 760, height: 760)
            // A crisp, tight shadow. Keeps the 2D flat look, but prevents
            // the colors from bleeding into each other (Material Design style).
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 6)
    }
    .frame(width: size, height: size)

    let renderer = ImageRenderer(content: view)
    renderer.isOpaque = false

    guard let cgImage = renderer.cgImage else {
        print("Failed to render CGImage.")
        exit(1)
    }

    print("Rendered 'Flat' 1024x1024 icon.")

    let fm = FileManager.default
    let iconsetURL = URL(fileURLWithPath: "AppIcon.iconset")
    try? fm.removeItem(at: iconsetURL)
    try? fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    let sizes = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    for (name, dim) in sizes {
        let targetSize = CGSize(width: dim, height: dim)
        let scaledImage = NSImage(size: targetSize)
        scaledImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cgImage, size: CGSize(width: size, height: size))
            .draw(in: NSRect(origin: .zero, size: targetSize))
        scaledImage.unlockFocus()

        if let scaledCG = scaledImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let sBitmap = NSBitmapImageRep(cgImage: scaledCG)
            if let sData = sBitmap.representation(using: .png, properties: [:]) {
                let dest = iconsetURL.appendingPathComponent("\(name).png")
                try? sData.write(to: dest)
            }
        }
    }

    print("Generated AppIcon.iconset.")

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
    try? task.run()
    task.waitUntilExit()

    if task.terminationStatus == 0 {
        print("Success! Created AppIcon.icns")
        try? fm.removeItem(at: iconsetURL)
    } else {
        print("iconutil failed.")
    }
}

Task { @MainActor in
    generateIcon()
    exit(0)
}
RunLoop.main.run()
