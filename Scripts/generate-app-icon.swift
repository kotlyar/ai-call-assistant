#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconVariant {
    let filename: String
    let pixels: Int
}

private let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1024),
]

private let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: generate-app-icon.swift <1024-png-path> <iconset-directory>\n", stderr)
    exit(2)
}

private let fullSizeURL = URL(fileURLWithPath: arguments[1])
private let iconsetURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(
    at: iconsetURL,
    withIntermediateDirectories: true
)

private func renderedIcon(size: Int) throws -> Data {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    representation.size = NSSize(width: size, height: size)
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: representation) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.imageInterpolation = .high

    let dimension = CGFloat(size)
    let canvas = NSRect(x: 0, y: 0, width: dimension, height: dimension)
    NSColor.clear.setFill()
    canvas.fill()

    // The background deliberately reaches the canvas edges. macOS supplies
    // the final display margin; keeping the artwork full-size makes it read
    // slightly larger than the supplied reference in Finder and the Dock.
    let background = NSBezierPath(
        roundedRect: canvas,
        xRadius: dimension * 0.235,
        yRadius: dimension * 0.235
    )
    NSColor(
        calibratedRed: 21 / 255,
        green: 22 / 255,
        blue: 21 / 255,
        alpha: 1
    ).setFill()
    background.fill()

    // Draw the reference's continuous waveform ourselves instead of relying
    // on an SF Symbol whose geometry can change between macOS releases.
    // Dock and Finder render the artwork inside an additional macOS icon mask,
    // so a small central mark loses too much visual weight. Keep the same
    // waveform, but let it occupy roughly thirty percent of the tile.
    let glyphScale = dimension * 0.30 / 200
    let context = graphicsContext.cgContext
    context.saveGState()
    context.translateBy(x: dimension / 2, y: dimension / 2)
    context.scaleBy(x: glyphScale, y: glyphScale)
    context.beginPath()
    context.move(to: CGPoint(x: -100, y: 0))
    context.addLine(to: CGPoint(x: -82, y: 0))
    context.addCurve(
        to: CGPoint(x: -62, y: 45),
        control1: CGPoint(x: -73, y: 0),
        control2: CGPoint(x: -75, y: 35)
    )
    context.addCurve(
        to: CGPoint(x: -42, y: 25),
        control1: CGPoint(x: -51, y: 56),
        control2: CGPoint(x: -42, y: 45)
    )
    context.addLine(to: CGPoint(x: -42, y: -65))
    context.addCurve(
        to: CGPoint(x: -25, y: -90),
        control1: CGPoint(x: -42, y: -80),
        control2: CGPoint(x: -35, y: -90)
    )
    context.addCurve(
        to: CGPoint(x: -8, y: -65),
        control1: CGPoint(x: -15, y: -90),
        control2: CGPoint(x: -8, y: -80)
    )
    context.addLine(to: CGPoint(x: -8, y: 75))
    context.addCurve(
        to: CGPoint(x: 10, y: 100),
        control1: CGPoint(x: -8, y: 90),
        control2: CGPoint(x: 0, y: 100)
    )
    context.addCurve(
        to: CGPoint(x: 28, y: 75),
        control1: CGPoint(x: 20, y: 100),
        control2: CGPoint(x: 28, y: 90)
    )
    context.addLine(to: CGPoint(x: 28, y: -45))
    context.addCurve(
        to: CGPoint(x: 46, y: -70),
        control1: CGPoint(x: 28, y: -60),
        control2: CGPoint(x: 36, y: -70)
    )
    context.addCurve(
        to: CGPoint(x: 64, y: -45),
        control1: CGPoint(x: 56, y: -70),
        control2: CGPoint(x: 64, y: -60)
    )
    context.addLine(to: CGPoint(x: 64, y: 20))
    context.addCurve(
        to: CGPoint(x: 82, y: 43),
        control1: CGPoint(x: 64, y: 34),
        control2: CGPoint(x: 72, y: 43)
    )
    context.addLine(to: CGPoint(x: 100, y: 43))
    context.setStrokeColor(
        NSColor(
            calibratedRed: 244 / 255,
            green: 243 / 255,
            blue: 238 / 255,
            alpha: 1
        ).cgColor
    )
    context.setLineWidth(max(15.5, 1 / glyphScale))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for variant in variants {
    let data = try renderedIcon(size: variant.pixels)
    try data.write(to: iconsetURL.appendingPathComponent(variant.filename))

    if variant.pixels == 1024 {
        try data.write(to: fullSizeURL)
    }
}
