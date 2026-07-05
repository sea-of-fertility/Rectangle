//
//  StackedWindowsPickerWindow.swift
//  Rectangle
//
//  A small borderless HUD that lists a horizontal row of app-icon + title cards,
//  one per candidate window. Arrow keys / Tab navigate, Return picks, Esc cancels.
//

import Cocoa

final class StackedWindowsPickerWindow: NSWindow {

    // MARK: - Public callbacks

    /// Called with the user-selected window when the user confirms.
    var onSelection: ((AccessibilityElement) -> Void)?
    /// Called when the picker is dismissed (selected or cancelled).
    var onClose: (() -> Void)?

    // MARK: - State

    private let activeWindow: AccessibilityElement
    private let candidates: [AccessibilityElement]
    private let targetScreen: NSScreen
    private var cards: [CardView] = []
    private var selectedIndex: Int = 0
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var isDismissing = false

    // MARK: - Layout

    private static let cardWidth: CGFloat = 140
    private static let cardHeight: CGFloat = 96
    private static let cardSpacing: CGFloat = 12
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 16

    /// Pure layout math for the card grid (B12): fit as many card columns as
    /// `maxContentWidth` allows (at least one) and wrap the rest into rows.
    /// A maximized active window makes every window on the screen a candidate
    /// (D-max overlap is 1.0 from the candidate's side), so a single row can
    /// easily outgrow the display. Internal so the unit tests can exercise
    /// the boundaries.
    static func gridLayout(count: Int, maxContentWidth: CGFloat) -> (columns: Int, rows: Int) {
        let cards = max(count, 1)
        let cardStride = cardWidth + cardSpacing
        let available = maxContentWidth - horizontalPadding * 2 + cardSpacing
        let maxColumns = max(1, Int(available / cardStride))
        let columns = min(cards, maxColumns)
        let rows = (cards + columns - 1) / columns
        return (columns, rows)
    }

    // MARK: - Init

    init(activeWindow: AccessibilityElement,
         candidates: [AccessibilityElement],
         onScreen: NSScreen) {
        self.activeWindow = activeWindow
        self.candidates = candidates
        self.targetScreen = onScreen

        let count = max(candidates.count, 1)
        let grid = Self.gridLayout(count: count,
                                   maxContentWidth: onScreen.visibleFrame.width * 0.9)
        let contentWidth = CGFloat(grid.columns) * Self.cardWidth
            + CGFloat(grid.columns - 1) * Self.cardSpacing
            + Self.horizontalPadding * 2
        let contentHeight = CGFloat(grid.rows) * Self.cardHeight
            + CGFloat(grid.rows - 1) * Self.cardSpacing
            + Self.verticalPadding * 2
        let initialRect = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)

        super.init(contentRect: initialRect, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        level = .modalPanel
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior.insert(.transient)
        collectionBehavior.insert(.canJoinAllSpaces)
        ignoresMouseEvents = false
        hidesOnDeactivate = false

        // Background container with rounded corners + blur material.
        let container = NSVisualEffectView(frame: initialRect)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        contentView = container

        // Lay out cards in a grid, top row first (the container view is
        // non-flipped, so row 0 gets the highest y).
        for (i, w) in candidates.enumerated() {
            let row = i / grid.columns
            let col = i % grid.columns
            let x = Self.horizontalPadding + CGFloat(col) * (Self.cardWidth + Self.cardSpacing)
            let y = Self.verticalPadding + CGFloat(grid.rows - 1 - row) * (Self.cardHeight + Self.cardSpacing)
            let card = CardView(frame: NSRect(x: x, y: y,
                                              width: Self.cardWidth, height: Self.cardHeight))
            card.configure(with: w, indexLabel: i + 1)
            card.onClick = { [weak self] in
                guard let self else { return }
                self.selectedIndex = i
                self.confirmSelection()
            }
            container.addSubview(card)
            cards.append(card)
        }
        updateHighlight()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Borderless windows default to canBecomeKey == false, which would make
    // makeKeyAndOrderFront() order the HUD without key status and turn the
    // resignKey() override below into dead code — after Cmd+Tab the picker
    // would stay up on every Space with Esc no longer reaching it.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Show / dismiss

    func show() {
        // Center on the active display's visible frame.
        let screenFrame = targetScreen.visibleFrame
        var f = frame
        f.origin.x = screenFrame.midX - f.width / 2
        f.origin.y = screenFrame.midY - f.height / 2
        setFrame(f, display: false)

        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installEventMonitors()
    }

    private func dismiss() {
        if isDismissing { return }
        isDismissing = true
        removeEventMonitors()
        orderOut(nil)
        onClose?()
    }

    private func confirmSelection() {
        if isDismissing { return }
        isDismissing = true
        let chosen = candidates[selectedIndex]
        removeEventMonitors()
        orderOut(nil)
        onSelection?(chosen)
        onClose?()
    }

    // MARK: - Navigation

    /// Public so the manager can advance selection on repeated invocations.
    func selectNext() {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % candidates.count
        updateHighlight()
    }

    private func selectPrevious() {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + candidates.count) % candidates.count
        updateHighlight()
    }

    private func updateHighlight() {
        for (i, card) in cards.enumerated() {
            card.setSelected(i == selectedIndex)
        }
    }

    // MARK: - Event monitors

    private func installEventMonitors() {
        // Local: arrow keys, tab, return, esc, digit shortcuts.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 0x35: // Esc
                self.dismiss()
                return nil
            case 0x24, 0x4C: // Return, Enter (keypad)
                self.confirmSelection()
                return nil
            case 0x7B: // Left
                self.selectPrevious()
                return nil
            case 0x7C: // Right
                self.selectNext()
                return nil
            case 0x30: // Tab
                if event.modifierFlags.contains(.shift) {
                    self.selectPrevious()
                } else {
                    self.selectNext()
                }
                return nil
            default:
                // 1..9 selects directly
                if let chars = event.charactersIgnoringModifiers,
                   let digit = Int(chars),
                   digit >= 1, digit <= self.candidates.count {
                    self.selectedIndex = digit - 1
                    self.confirmSelection()
                    return nil
                }
                return event
            }
        }
        // Global: click anywhere else dismisses.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeEventMonitors() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
    }

    override func resignKey() {
        super.resignKey()
        // Dismiss when focus leaves us (e.g. user clicked another window).
        dismiss()
    }
}

// MARK: - Card view

private final class CardView: NSView {

    var onClick: (() -> Void)?

    private let iconView: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        return iv
    }()
    private let appLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.alignment = .center
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return tf
    }()
    private let titleLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.alignment = .center
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.font = NSFont.systemFont(ofSize: 10)
        tf.textColor = .secondaryLabelColor
        return tf
    }()
    private let badgeLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.alignment = .center
        tf.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        tf.textColor = .secondaryLabelColor
        return tf
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.clear.cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor

        addSubview(iconView)
        addSubview(appLabel)
        addSubview(titleLabel)
        addSubview(badgeLabel)

        let iconSize: CGFloat = 48
        iconView.frame = NSRect(x: (frameRect.width - iconSize) / 2,
                                y: frameRect.height - iconSize - 12,
                                width: iconSize, height: iconSize)
        appLabel.frame = NSRect(x: 6, y: 22, width: frameRect.width - 12, height: 14)
        titleLabel.frame = NSRect(x: 6, y: 6, width: frameRect.width - 12, height: 14)
        badgeLabel.frame = NSRect(x: 6, y: frameRect.height - 16, width: 16, height: 14)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with window: AccessibilityElement, indexLabel: Int) {
        var appName = ""
        if let pid = window.pid, let app = NSRunningApplication(processIdentifier: pid) {
            iconView.image = app.icon
            appName = app.localizedName ?? ""
        }
        appLabel.stringValue = appName
        titleLabel.stringValue = window.title ?? ""
        badgeLabel.stringValue = "\(indexLabel)"
    }

    func setSelected(_ selected: Bool) {
        if selected {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        } else {
            layer?.borderColor = NSColor.clear.cgColor
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
