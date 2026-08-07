@testable import SwiftTerm
import Foundation
import Testing

private final class TerminalGraphicsCollector: TerminalDelegate {
  struct Bitmap: Equatable {
    let bytes: [UInt8]
    let width: Int
    let height: Int
  }

  private(set) var bitmaps: [Bitmap] = []
  private(set) var responses: [UInt8] = []

  func send(source: Terminal, data: ArraySlice<UInt8>) {
    responses.append(contentsOf: data)
  }

  func createImageFromBitmap(
    source: Terminal,
    bytes: inout [UInt8],
    width: Int,
    height: Int
  ) {
    bitmaps.append(Bitmap(bytes: bytes, width: width, height: height))
  }
}

private func sixelBytes(_ body: String, parameters: String = "0;1;0") -> [UInt8] {
  Array("\u{1B}P\(parameters)q\(body)\u{1B}\\".utf8)
}

private func kittyBytes(_ command: String) -> [UInt8] {
  Array("\u{1B}_G\(command)\u{1B}\\".utf8)
}

private func pixel(_ bitmap: TerminalGraphicsCollector.Bitmap, x: Int, y: Int) -> [UInt8] {
  let offset = (y * bitmap.width + x) * 4
  return Array(bitmap.bytes[offset..<(offset + 4)])
}

@Suite("终端图形协议", .serialized)
struct TerminalGraphicsTests {

@Test("Sixel raster、RGB、RLE 与透明背景生成受声明尺寸约束的 RGBA 位图")
func sixelDecodesRasterRgbRleAndTransparency() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)

  terminal.feed(byteArray: sixelBytes(#""1;1;4;2#1;2;100;0;0!2@"#))

  let bitmap = collector.bitmaps.first
  #expect(collector.bitmaps.count == 1)
  #expect(bitmap?.width == 4)
  #expect(bitmap?.height == 2)
  if let bitmap, bitmap.width == 4, bitmap.height == 2, bitmap.bytes.count == 32 {
    #expect(pixel(bitmap, x: 0, y: 0) == [255, 0, 0, 255])
    #expect(pixel(bitmap, x: 1, y: 0) == [255, 0, 0, 255])
    #expect(pixel(bitmap, x: 2, y: 0) == [0, 0, 0, 0])
    #expect(pixel(bitmap, x: 0, y: 1) == [0, 0, 0, 0])
  }
}

@Test("Sixel raster 留空的 aspect 参数按 DEC 默认值解析")
func sixelRasterAcceptsDefaultedAspectParameters() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)

  terminal.feed(byteArray: sixelBytes(#"";;3;2#1;2;0;100;0@"#))

  #expect(collector.bitmaps.count == 1)
  #expect(collector.bitmaps.first?.width == 3)
  #expect(collector.bitmaps.first?.height == 2)
}

@Test("Sixel HLS 色彩定义使用 DEC 旋转后的色相环")
func sixelDecodesHlsPaletteDefinition() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)

  terminal.feed(byteArray: sixelBytes("#3;1;120;50;100@"))

  #expect(collector.bitmaps.count == 1)
  if let bitmap = collector.bitmaps.first {
    #expect(pixel(bitmap, x: 0, y: 0) == [255, 0, 0, 255])
  }
}

@Test("Sixel 未重定义的颜色寄存器使用 VT340 默认 256 色 palette")
func sixelUsesVt340DefaultPalette() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)

  terminal.feed(byteArray: sixelBytes("#2@"))
  terminal.feed(byteArray: sixelBytes("#200@"))

  #expect(collector.bitmaps.count == 2)
  if let bitmap = collector.bitmaps.first {
    #expect(pixel(bitmap, x: 0, y: 0) == [204, 33, 33, 255])
  }
  if collector.bitmaps.count == 2 {
    #expect(pixel(collector.bitmaps[1], x: 0, y: 0) == [255, 0, 215, 255])
  }
}

@Test("Sixel 拒绝超尺寸 raster 与超上限 repeat，不分配或提交位图")
func sixelRejectsOversizedRasterAndRepeat() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)

  terminal.feed(byteArray: sixelBytes(#""1;1;10001;1#1@"#))
  terminal.feed(byteArray: sixelBytes("#1!10001@"))
  terminal.feed(byteArray: sixelBytes(#""1;1;5000;5000#1@"#))
  terminal.feed(byteArray: sixelBytes("#1!999999999999999999999@"))

  #expect(collector.bitmaps.isEmpty)
}

@Test("Sixel 超过输入字节硬上限后丢弃整张图片")
func sixelRejectsOversizedEncodedInput() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)
  var sequence = Array("\u{1B}P0;1;0q#1".utf8)
  sequence.append(contentsOf: repeatElement(UInt8(ascii: "?"), count: 8 * 1024 * 1024 + 1))
  sequence.append(contentsOf: [0x1B, UInt8(ascii: "\\")])

  let split = sequence.count / 2
  terminal.feed(byteArray: Array(sequence[..<split]))
  terminal.feed(byteArray: Array(sequence[split...]))

  #expect(collector.bitmaps.isEmpty)
}

@Test("Kitty APC 分块可重组 RGBA payload")
func kittyReassemblesBoundedChunks() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)

  terminal.feed(byteArray: kittyBytes("a=T,f=32,s=1,v=1,i=7,m=1;AQID"))
  #expect(terminal.kittyGraphicsState.pending != nil)
  terminal.feed(byteArray: kittyBytes("m=0;BA=="))

  #expect(terminal.kittyGraphicsState.pending == nil)
  #expect(collector.bitmaps == [
    TerminalGraphicsCollector.Bitmap(bytes: [1, 2, 3, 4], width: 1, height: 1)
  ])
}

@Test("Kitty APC 被 CAN 取消后清理分块状态并接受下一次传输")
func kittyCancellationClearsPendingTransfer() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)

  terminal.feed(byteArray: kittyBytes("a=T,f=32,s=1,v=1,i=7,m=1;AQID"))
  #expect(terminal.kittyGraphicsState.pending != nil)
  terminal.feed(byteArray: Array("\u{1B}_Gm=1;BA".utf8) + [0x18])
  #expect(terminal.kittyGraphicsState.pending == nil)
  terminal.feed(byteArray: kittyBytes("a=T,f=32,s=1,v=1,i=8;BQYHCA=="))

  #expect(collector.bitmaps == [
    TerminalGraphicsCollector.Bitmap(bytes: [5, 6, 7, 8], width: 1, height: 1)
  ])
}

@Test("Kitty 非法 continuation 清理 pending transfer 并允许后续图片")
func kittyMalformedContinuationClearsPendingTransfer() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)

  terminal.feed(byteArray: kittyBytes("a=T,f=32,s=1,v=1,i=11,m=1;AQID"))
  #expect(terminal.kittyGraphicsState.pending != nil)
  terminal.feed(byteArray: kittyBytes("m=not-a-number;BA=="))
  #expect(terminal.kittyGraphicsState.pending == nil)
  terminal.feed(byteArray: kittyBytes("a=T,f=32,s=1,v=1,i=12;DQ4PEA=="))

  #expect(collector.bitmaps == [
    TerminalGraphicsCollector.Bitmap(bytes: [13, 14, 15, 16], width: 1, height: 1)
  ])
}

@Test("Kitty pending buffer 同时约束累计字节与 chunk 数")
func kittyPendingBufferEnforcesByteAndChunkBounds() throws {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)
  terminal.feed(byteArray: kittyBytes("a=T,f=32,s=1,v=1,i=13,m=1;AQ"))

  var byteBoundPending = try #require(terminal.kittyGraphicsState.pending)
  let secondChunk: ArraySlice<UInt8> = [UInt8(ascii: "I"), UInt8(ascii: "D")][...]
  let acceptedSecondChunk = byteBoundPending.append(
    secondChunk,
    maximumBytes: 4,
    maximumChunks: 2
  )
  #expect(acceptedSecondChunk)
  let overflowingByte: ArraySlice<UInt8> = [UInt8(ascii: "B")][...]
  let acceptedOverflowingByte = byteBoundPending.append(
    overflowingByte,
    maximumBytes: 4,
    maximumChunks: 3
  )
  #expect(!acceptedOverflowingByte)
  #expect(byteBoundPending.base64Payload.isEmpty)

  var chunkBoundPending = try #require(terminal.kittyGraphicsState.pending)
  let emptyChunk: ArraySlice<UInt8> = []
  let acceptedExcessChunk = chunkBoundPending.append(
    emptyChunk,
    maximumBytes: 4,
    maximumChunks: 1
  )
  #expect(!acceptedExcessChunk)
  #expect(chunkBoundPending.base64Payload.isEmpty)
}

@Test("Kitty 单个 APC 超过硬上限后丢弃输入并清理分块状态")
func kittyRejectsOversizedApcAndRecovers() {
  let collector = TerminalGraphicsCollector()
  let terminal = Terminal(delegate: collector)
  var oversized = Array("\u{1B}_Ga=T,f=32,s=1,v=1,i=9,m=1;".utf8)
  oversized.append(contentsOf: repeatElement(UInt8(ascii: "A"), count: 1024 * 1024 + 1))
  oversized.append(contentsOf: [0x1B, UInt8(ascii: "\\")])

  let split = oversized.count / 2
  terminal.feed(byteArray: Array(oversized[..<split]))
  terminal.feed(byteArray: Array(oversized[split...]))
  #expect(terminal.kittyGraphicsState.pending == nil)
  terminal.feed(byteArray: kittyBytes("a=T,f=32,s=1,v=1,i=10;CQoLDA=="))

  #expect(collector.bitmaps == [
    TerminalGraphicsCollector.Bitmap(bytes: [9, 10, 11, 12], width: 1, height: 1)
  ])
}

}
