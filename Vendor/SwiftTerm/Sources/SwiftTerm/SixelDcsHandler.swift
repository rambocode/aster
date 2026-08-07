//
//  SixelDcsHandler.swift
//
//  Created by Anders Borum on 28/04/2020.
//

import Foundation

/// Bounded decoder for DEC Sixel DCS payloads.
///
/// Decoding deliberately uses two passes. The first pass validates every command and computes
/// the final canvas without allocating attacker-controlled storage. Only then does the second
/// pass allocate an RGBA bitmap and paint pixels inside the already validated bounds.
final class SixelDcsHandler: DcsHandler {
    static let maximumInputBytes = 8 * 1024 * 1024
    static let maximumDimension = 10_000
    static let maximumRepeat = 10_000
    static let maximumBitmapBytes = 64 * 1024 * 1024

    private enum DecodeError: Error {
        case malformedInput
        case resourceLimit
    }

    private struct Dimensions {
        var declaredWidth = 0
        var declaredHeight = 0
        var drawnWidth = 0
        var drawnHeight = 0

        var width: Int { max(declaredWidth, drawnWidth) }
        var height: Int { max(declaredHeight, drawnHeight) }
    }

    private struct ByteCursor {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }
        var current: UInt8? { isAtEnd ? nil : bytes[index] }

        mutating func advance() {
            index += 1
        }

        /// Parses a required decimal integer with checked arithmetic and an operation-specific
        /// ceiling. Rejecting during parsing avoids wrapping before later range validation.
        mutating func parseUnsigned(maximum: Int) throws -> Int {
            var result = 0
            var consumedDigit = false
            while let byte = current, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                consumedDigit = true
                let digit = Int(byte - UInt8(ascii: "0"))
                let (multiplied, multiplyOverflow) = result.multipliedReportingOverflow(by: 10)
                let (next, addOverflow) = multiplied.addingReportingOverflow(digit)
                guard !multiplyOverflow, !addOverflow, next <= maximum else {
                    throw DecodeError.resourceLimit
                }
                result = next
                advance()
            }
            guard consumedDigit else {
                throw DecodeError.malformedInput
            }
            return result
        }

        /// DEC parameter lists permit an empty field. The caller supplies the command-specific
        /// default while non-empty fields still use the same checked integer parser.
        mutating func parseUnsigned(maximum: Int, defaultValue: Int) throws -> Int {
            guard let byte = current,
                  byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                return defaultValue
            }
            return try parseUnsigned(maximum: maximum)
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            advance()
            return true
        }
    }

    private enum Command {
        case raster(width: Int, height: Int)
        case selectColor(index: Int)
        case defineColor(index: Int, system: Int, x: Int, y: Int, z: Int)
        case sixel(pattern: Int, repeatCount: Int)
        case carriageReturn
        case nextLine
    }

    private unowned let terminal: Terminal
    private var data: [UInt8] = []
    private var rejected = false
    private var usesTransparentBackground = false

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    func hook(collect: cstring, parameters: [Int], flag: UInt8) {
        data.removeAll(keepingCapacity: true)
        rejected = false
        // DEC P2=1 leaves zero bits untouched. For an independently rendered bitmap that means
        // transparent RGBA pixels; P2=0/2 use the terminal's current background color.
        usesTransparentBackground = parameters.count > 1 && parameters[1] == 1
    }

    func put(data: ArraySlice<UInt8>) {
        guard !rejected else { return }
        guard data.count <= Self.maximumInputBytes - self.data.count else {
            // Release already buffered attacker-controlled data immediately and ignore the rest
            // of this DCS until `unhook`; a truncated image must never be rendered.
            self.data.removeAll(keepingCapacity: false)
            rejected = true
            return
        }
        self.data.append(contentsOf: data)
    }

    func unhook() {
        defer {
            data.removeAll(keepingCapacity: false)
            rejected = false
        }
        guard !rejected, !data.isEmpty else { return }

        do {
            let dimensions = try measure()
            guard dimensions.width > 0, dimensions.height > 0 else {
                throw DecodeError.malformedInput
            }
            let byteCount = try validatedBitmapByteCount(
                width: dimensions.width,
                height: dimensions.height
            )
            var pixels = backgroundPixels(byteCount: byteCount)
            try render(
                pixels: &pixels,
                width: dimensions.width,
                height: dimensions.height
            )
            terminal.tdel?.createImageFromBitmap(
                source: terminal,
                bytes: &pixels,
                width: dimensions.width,
                height: dimensions.height
            )
        } catch {
            // Malformed or over-budget images are protocol input failures. They are ignored as a
            // whole so partially decoded pixels cannot leak into terminal state.
            return
        }
    }

    private func measure() throws -> Dimensions {
        var dimensions = Dimensions()
        var x = 0
        var y = 0

        try walkCommands { command in
            switch command {
            case .raster(let width, let height):
                dimensions.declaredWidth = max(dimensions.declaredWidth, width)
                dimensions.declaredHeight = max(dimensions.declaredHeight, height)
            case .sixel(let pattern, let repeatCount):
                let (nextX, overflow) = x.addingReportingOverflow(repeatCount)
                guard !overflow, nextX <= Self.maximumDimension else {
                    throw DecodeError.resourceLimit
                }
                dimensions.drawnWidth = max(dimensions.drawnWidth, nextX)
                if let highestBit = Self.highestSetBit(in: pattern) {
                    let (bottom, heightOverflow) = y.addingReportingOverflow(highestBit + 1)
                    guard !heightOverflow, bottom <= Self.maximumDimension else {
                        throw DecodeError.resourceLimit
                    }
                    dimensions.drawnHeight = max(dimensions.drawnHeight, bottom)
                }
                x = nextX
            case .carriageReturn:
                x = 0
            case .nextLine:
                let (nextY, overflow) = y.addingReportingOverflow(6)
                guard !overflow, nextY <= Self.maximumDimension else {
                    throw DecodeError.resourceLimit
                }
                y = nextY
                x = 0
            case .selectColor, .defineColor:
                break
            }
        }

        guard dimensions.width <= Self.maximumDimension,
              dimensions.height <= Self.maximumDimension else {
            throw DecodeError.resourceLimit
        }
        return dimensions
    }

    private func render(pixels: inout [UInt8], width: Int, height: Int) throws {
        var palette = Self.vt340Palette256()
        var colorIndex = 0
        var x = 0
        var y = 0

        try walkCommands { command in
            switch command {
            case .raster:
                break
            case .selectColor(let index):
                colorIndex = index
            case .defineColor(let index, let system, let first, let second, let third):
                if system == 1 {
                    palette[index] = Self.hlsColor(
                        hue: min(first, 360),
                        luminosity: min(second, 100),
                        saturation: min(third, 100)
                    )
                } else {
                    palette[index] = Self.rgba(
                        red: Self.percentToByte(first),
                        green: Self.percentToByte(second),
                        blue: Self.percentToByte(third)
                    )
                }
            case .sixel(let pattern, let repeatCount):
                let color = palette[colorIndex]
                for offset in 0..<repeatCount {
                    let column = x + offset
                    for bit in 0..<6 where pattern & (1 << bit) != 0 {
                        let row = y + bit
                        guard column < width, row < height else {
                            throw DecodeError.malformedInput
                        }
                        Self.write(color: color, to: &pixels, width: width, x: column, y: row)
                    }
                }
                x += repeatCount
            case .carriageReturn:
                x = 0
            case .nextLine:
                y += 6
                x = 0
            }
        }
    }

    /// Tokenizes the Sixel command stream without allocating an intermediate operation list.
    /// Both decoder passes therefore have O(input + bitmap) memory usage under fixed ceilings.
    private func walkCommands(_ body: (Command) throws -> Void) throws {
        var cursor = ByteCursor(bytes: data)
        while let byte = cursor.current {
            cursor.advance()
            switch byte {
            case UInt8(ascii: "\""):
                let rawPan = try cursor.parseUnsigned(
                    maximum: Self.maximumDimension,
                    defaultValue: 0
                )
                guard cursor.consume(UInt8(ascii: ";")) else { throw DecodeError.malformedInput }
                let rawPad = try cursor.parseUnsigned(
                    maximum: Self.maximumDimension,
                    defaultValue: 0
                )
                guard cursor.consume(UInt8(ascii: ";")) else { throw DecodeError.malformedInput }
                let width = try cursor.parseUnsigned(
                    maximum: Self.maximumDimension,
                    defaultValue: 0
                )
                guard cursor.consume(UInt8(ascii: ";")) else { throw DecodeError.malformedInput }
                let height = try cursor.parseUnsigned(
                    maximum: Self.maximumDimension,
                    defaultValue: 0
                )
                // DEC defines omitted or zero aspect fields as 1. The ratio does not alter the
                // decoded pixel grid, but normalizing it here validates the complete command.
                let pan = max(1, rawPan)
                let pad = max(1, rawPad)
                guard pan > 0, pad > 0 else { throw DecodeError.malformedInput }
                try body(.raster(width: width, height: height))

            case UInt8(ascii: "#"):
                let index = try cursor.parseUnsigned(maximum: 255)
                guard cursor.consume(UInt8(ascii: ";")) else {
                    try body(.selectColor(index: index))
                    continue
                }
                let system = try cursor.parseUnsigned(maximum: 2)
                guard system == 1 || system == 2,
                      cursor.consume(UInt8(ascii: ";")) else {
                    throw DecodeError.malformedInput
                }
                let first = try cursor.parseUnsigned(maximum: 1_000)
                guard cursor.consume(UInt8(ascii: ";")) else { throw DecodeError.malformedInput }
                let second = try cursor.parseUnsigned(maximum: 1_000)
                guard cursor.consume(UInt8(ascii: ";")) else { throw DecodeError.malformedInput }
                let third = try cursor.parseUnsigned(maximum: 1_000)
                try body(.defineColor(
                    index: index,
                    system: system,
                    x: first,
                    y: second,
                    z: third
                ))
                try body(.selectColor(index: index))

            case UInt8(ascii: "!"):
                let repeatCount = try cursor.parseUnsigned(maximum: Self.maximumRepeat)
                guard repeatCount > 0,
                      let sixel = cursor.current,
                      sixel >= 63, sixel <= 126 else {
                    throw DecodeError.malformedInput
                }
                cursor.advance()
                try body(.sixel(pattern: Int(sixel - 63), repeatCount: repeatCount))

            case UInt8(ascii: "$"):
                try body(.carriageReturn)
            case UInt8(ascii: "-"):
                try body(.nextLine)
            case 63...126:
                try body(.sixel(pattern: Int(byte - 63), repeatCount: 1))
            case 10, 13:
                // Line breaks are frequently inserted by transport wrappers and have no graphics
                // meaning inside a Sixel DCS.
                continue
            default:
                throw DecodeError.malformedInput
            }
        }
    }

    private func validatedBitmapByteCount(width: Int, height: Int) throws -> Int {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow, byteCount <= Self.maximumBitmapBytes else {
            throw DecodeError.resourceLimit
        }
        return byteCount
    }

    private func backgroundPixels(byteCount: Int) -> [UInt8] {
        guard !usesTransparentBackground else {
            return [UInt8](repeating: 0, count: byteCount)
        }
        let background = terminal.backgroundColor
        let rgba: [UInt8] = [
            UInt8(background.red >> 8),
            UInt8(background.green >> 8),
            UInt8(background.blue >> 8),
            255,
        ]
        var pixels = [UInt8](repeating: 0, count: byteCount)
        for offset in stride(from: 0, to: byteCount, by: 4) {
            pixels[offset] = rgba[0]
            pixels[offset + 1] = rgba[1]
            pixels[offset + 2] = rgba[2]
            pixels[offset + 3] = rgba[3]
        }
        return pixels
    }

    private static func highestSetBit(in pattern: Int) -> Int? {
        for bit in stride(from: 5, through: 0, by: -1) where pattern & (1 << bit) != 0 {
            return bit
        }
        return nil
    }

    private static func write(
        color: UInt32,
        to pixels: inout [UInt8],
        width: Int,
        x: Int,
        y: Int
    ) {
        let offset = (y * width + x) * 4
        pixels[offset] = UInt8(color >> 24)
        pixels[offset + 1] = UInt8((color >> 16) & 0xFF)
        pixels[offset + 2] = UInt8((color >> 8) & 0xFF)
        pixels[offset + 3] = UInt8(color & 0xFF)
    }

    private static func rgba(red: Int, green: Int, blue: Int) -> UInt32 {
        UInt32(red << 24 | green << 16 | blue << 8 | 0xFF)
    }

    private static func percentToByte(_ value: Int) -> Int {
        min(max(value, 0), 100) * 255 / 100
    }

    /// Returns the VT340 color-register defaults in slots 0...15 and the conventional
    /// 6×6×6 cube plus grayscale ramp in slots 16...255 used by modern 256-color Sixel tools.
    private static func vt340Palette256() -> [UInt32] {
        let vt340Percent: [(Int, Int, Int)] = [
            (0, 0, 0), (20, 20, 80), (80, 13, 13), (20, 80, 20),
            (80, 20, 80), (20, 80, 80), (80, 80, 20), (53, 53, 53),
            (26, 26, 26), (33, 33, 60), (60, 26, 26), (33, 60, 33),
            (60, 33, 60), (33, 60, 60), (60, 60, 33), (80, 80, 80),
        ]
        var result = vt340Percent.map {
            rgba(
                red: percentToByte($0.0),
                green: percentToByte($0.1),
                blue: percentToByte($0.2)
            )
        }
        let levels = [0, 95, 135, 175, 215, 255]
        for red in levels {
            for green in levels {
                for blue in levels {
                    result.append(rgba(red: red, green: green, blue: blue))
                }
            }
        }
        for index in 0..<24 {
            let component = 8 + index * 10
            result.append(rgba(red: component, green: component, blue: component))
        }
        return result
    }

    /// Converts DEC HLS, whose hue ring is rotated by 120 degrees from CSS HSL, to RGBA.
    private static func hlsColor(hue: Int, luminosity: Int, saturation: Int) -> UInt32 {
        guard saturation > 0 else {
            let gray = percentToByte(luminosity)
            return rgba(red: gray, green: gray, blue: gray)
        }

        let lightness = Double(min(max(luminosity, 0), 100))
        let chroma = Double(min(max(saturation, 0), 100))
        let maximum: Double
        if lightness > 50 {
            maximum = lightness + chroma * (1 - lightness / 100)
        } else {
            maximum = lightness + chroma * lightness / 100
        }
        let minimum = 2 * lightness - maximum
        let rotatedHue = (min(max(hue, 0), 360) + 240) % 360
        let sector = rotatedHue / 60
        let fraction = Double(rotatedHue % 60) / 60
        let rising = minimum + (maximum - minimum) * fraction
        let falling = maximum - (maximum - minimum) * fraction
        let percentages: (Double, Double, Double) = switch sector {
        case 0: (maximum, rising, minimum)
        case 1: (falling, maximum, minimum)
        case 2: (minimum, maximum, rising)
        case 3: (minimum, falling, maximum)
        case 4: (rising, minimum, maximum)
        default: (maximum, minimum, falling)
        }
        return rgba(
            red: percentToByte(Int(percentages.0.rounded())),
            green: percentToByte(Int(percentages.1.rounded())),
            blue: percentToByte(Int(percentages.2.rounded()))
        )
    }
}
