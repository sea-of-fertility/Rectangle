//
//  WindowHighlightWindow.swift
//  Rectangle
//
//  Borderless overlay that draws a blue outline around the rectangle the
//  user is currently aiming at while the focus picker is open.
//

import Cocoa

final class WindowHighlightWindow: NSWindow {

    /// Called when the window resigns key status (e.g. user switched apps).
    var onResignKey: (() -> Void)?

    private static let borderWidth: CGFloat = 5
    private static let cornerRadius: CGFloat = 10
    private static let borderColor: NSColor = .controlAccentColor

    private let outlineView: OutlineView

    init() {
        outlineView = OutlineView(frame: .zero)
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        isReleasedWhenClosed = false

        contentView = outlineView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Move the highlight to wrap the given window frame.
    /// `axFrame` is in AX (top-origin) coordinates — i.e. the same coordinates
    /// `AccessibilityElement.frame` returns.
    func update(toAXFrame axFrame: CGRect) {
        let cocoa = axFrame.screenFlipped
        // Slight outset so the outline sits just outside the target rect.
        let inset = Self.borderWidth / 2
        let outlineFrame = cocoa.insetBy(dx: -inset, dy: -inset)
        setFrame(outlineFrame, display: true)
        outlineView.needsDisplay = true
        orderFront(nil)
    }

    func dismiss() {
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    private final class OutlineView: NSView {
        override var isFlipped: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            let inset = WindowHighlightWindow.borderWidth / 2
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                xRadius: WindowHighlightWindow.cornerRadius,
                yRadius: WindowHighlightWindow.cornerRadius
            )
            path.lineWidth = WindowHighlightWindow.borderWidth
            WindowHighlightWindow.borderColor.setStroke()
            path.stroke()
        }
    }
}
