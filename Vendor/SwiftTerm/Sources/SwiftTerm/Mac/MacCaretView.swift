//
//  MacCaretView.swift
//  
// Implements the caret in the Mac caret view
// TODO: looks like I can kill sub now. unless it can be used to draw a border when out of focus
//
//  Created by Miguel de Icaza on 3/20/20.
//

#if os(macOS)
import Foundation
import AppKit
import CoreText
import CoreGraphics
import CoreText

// The CaretView is used to show the cursor
class CaretView: NSView, CALayerDelegate {
    weak var terminal: TerminalView?
    var ctline: CTLine?
    /// Cell width of the character currently under the caret (2 for full-width
    /// CJK). Used to center its glyph within the caret, matching the text.
    var glyphColumnWidth: Int = 1
    var bgColor: CGColor
    var tracksFocus = true
    
    public init (frame: CGRect, cursorStyle: CursorStyle, terminal: TerminalView)
    {
        self.terminal = terminal
        style = cursorStyle
        bgColor = caretColor.cgColor
        super.init(frame: frame)
        wantsLayer = true

        updateView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Enable transparency support for the cursor (matches iOS behavior)
    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
        return layer
    }
    
    func setText (ch: CharData) {
        glyphColumnWidth = max(1, Int(ch.width))
        let character = terminal?.terminal.getCharacter(for: ch) ?? " "
        let res = NSAttributedString (
            string: UnicodeUtil.textPresentationAdjusted (character),
            attributes: terminal?.getAttributedValue(ch.attribute, usingFg: caretColor, andBg: caretTextColor ?? terminal?.nativeForegroundColor ?? NSColor.black))
        ctline = CTLineCreateWithAttributedString(res)

        setNeedsDisplay(bounds)
    }
    
    var style: CursorStyle {
        didSet {
            updateCursorStyle ()
        }
    }
    
    func updateCursorStyle () {
        switch style {
        case .blinkUnderline, .blinkBlock, .blinkHollowBlock, .blinkBar:
            updateAnimation(to: true)
        case .steadyBar, .steadyBlock, .steadyHollowBlock, .steadyUnderline:
            updateAnimation(to: false)
        }
        updateView ()
    }
    
    func updateAnimation (to: Bool) {
        layer?.removeAllAnimations()
        self.layer?.opacity = 1
        if to {
            let anim = CABasicAnimation.init(keyPath: #keyPath (CALayer.opacity))
            anim.duration = 0.7
            anim.autoreverses = true
            anim.repeatCount = Float.infinity
            anim.fromValue = NSNumber (floatLiteral: 1)
            anim.toValue = NSNumber (floatLiteral: 0)
            anim.timingFunction = CAMediaTimingFunction (name: .easeIn)
            layer?.add(anim, forKey: #keyPath (CALayer.opacity))
        }
    }
    
    func disableAnimations () {
        layer?.removeAllAnimations()
        layer?.opacity = 1
    }
    
    public var defaultCaretColor = NSColor.selectedControlColor
    
    public var caretColor: NSColor = NSColor.selectedControlColor {
        didSet {
            bgColor = caretColor.cgColor
            updateView()
        }
    }

    public var defaultCaretTextColor: NSColor? = nil
    public var caretTextColor: NSColor? = nil {
        didSet {
            updateView()
        }
    }

    public var focused: Bool = false {
        didSet {
            updateView()
        }
    }

    func updateView() {
        setNeedsDisplay(bounds)
    }

    /// Model geometry changes immediately so IME placement never lags. The presentation layer
    /// interpolates only short same-row moves; line changes, resize and Reduce Motion stay locked
    /// to the terminal grid.
    func move(to origin: CGPoint, size: CGSize, smoothly: Bool) {
        let oldFrame = frame
        let oldPosition = layer?.presentation()?.position ?? layer?.position
        frame = CGRect(origin: origin, size: size)
        guard smoothly, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            abs(oldFrame.minY - origin.y) < 0.5,
            abs(oldFrame.minX - origin.x) <= max(oldFrame.width, size.width) * 8,
            let layer, let oldPosition else { return }
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = oldPosition
        animation.toValue = layer.position
        animation.duration = 0.1
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "aster.cursor.position")
    }
    
    func draw(_ layer: CALayer, in context: CGContext) {
        drawCursor (in: context, hasFocus: tracksFocus ? (terminal?.hasFocus ?? true) : true)
    }
    
    override func draw(_ dirtyRect: NSRect) {
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // we do not want to steal hits, let the terminal view take them
        return nil
    }
}
#endif
