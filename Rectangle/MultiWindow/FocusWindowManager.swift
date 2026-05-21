//
//  FocusWindowManager.swift
//  Rectangle
//
//  Entry point for the "Focus Window Picker" action. Highlights the active
//  window with a blue outline and lets the user move the focus to a
//  neighboring (geometrically) window using arrow keys.
//
//  Window list semantics:
//    We use WindowUtil.getWindowList() directly (not getAllWindowElements)
//    so we keep the front-to-back z-order CGWindowList gives us. That ordering
//    is required by FocusWindowVisibility's occlusion calculation. We also
//    filter by kCGWindowLayer == 0 to drop menu bar items, status items,
//    Notification Center, Dock, and other non-app overlays.
//

import Cocoa

class FocusWindowManager {

    private static let minVisibleRatio: CGFloat = 0.10
    private static let excludedProcessNames: Set<String> = ["Dock", "WindowManager", "Notification Center", "Window Server"]
    private static let minDimension: CGFloat = 40   // ignore tiny floating chrome

    private static var activeSession: Session?

    static func reveal() {
        if activeSession != nil { return }   // already running

        // Active window (we anchor the picker here).
        guard let active = AccessibilityElement.getFrontWindowElement(),
              let activeWindowId = active.windowId else {
            NSSound.beep()
            Logger.log("FocusWindow: no front window")
            return
        }

        // All visible windows in front-to-back order, filtered to app-level windows.
        let allInfos = WindowUtil.getWindowList().filter { info in
            info.level == 0
                && !excludedProcessNames.contains(info.processName ?? "")
                && info.frame.width >= minDimension
                && info.frame.height >= minDimension
        }

        let frames = allInfos.map { $0.frame }
        let visibleSet = FocusWindowVisibility.visibleIndices(in: frames, minVisibleRatio: minVisibleRatio)

        // Build candidates (visible + not active).
        var candidateInfos: [WindowInfo] = []
        for (i, info) in allInfos.enumerated() where visibleSet.contains(i) {
            if info.id == activeWindowId { continue }
            candidateInfos.append(info)
        }

        // We still anchor visually on the active window's AX frame, but to be
        // consistent with the candidate frames (which come from CGWindowList
        // and are top-origin like AX frames) we use the active window's
        // CGWindowList frame too — that's what allInfos contains.
        let activeFrame: CGRect = allInfos.first(where: { $0.id == activeWindowId })?.frame ?? active.frame

        let session = Session(activeFrame: activeFrame, candidates: candidateInfos)
        session.start()
        activeSession = session
    }

    fileprivate static func sessionEnded() {
        activeSession = nil
    }

    private final class Session {
        private let activeFrame: CGRect
        private let candidates: [WindowInfo]
        private var cursorIndex: Int       // -1 = active, else index into candidates
        private let highlight = WindowHighlightWindow()
        private var keyMonitor: Any?
        private var dismissing = false

        init(activeFrame: CGRect, candidates: [WindowInfo]) {
            self.activeFrame = activeFrame
            self.candidates = candidates
            self.cursorIndex = -1
        }

        func start() {
            highlight.update(toAXFrame: activeFrame)
            highlight.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            installKeyMonitor()
        }

        private func currentFrame() -> CGRect {
            return cursorIndex == -1 ? activeFrame : candidates[cursorIndex].frame
        }

        private func move(_ direction: FocusDirection) {
            guard !candidates.isEmpty else { return }
            let current = currentFrame()
            let frames = candidates.map { $0.frame }
            if let next = FocusWindowGeometry.nextWindow(from: current, direction: direction, candidates: frames) {
                cursorIndex = next
                highlight.update(toAXFrame: candidates[next].frame)
            }
        }

        private func confirm() {
            if dismissing { return }
            dismissing = true
            removeKeyMonitor()
            highlight.dismiss()
            if cursorIndex >= 0 {
                let chosen = candidates[cursorIndex]
                if let element = AccessibilityElement.getWindowElement(chosen.id) {
                    element.bringToFront(force: true)
                } else {
                    Logger.log("FocusWindow: could not resolve AX element for windowId=\(chosen.id)")
                }
            }
            FocusWindowManager.sessionEnded()
        }

        private func cancel() {
            if dismissing { return }
            dismissing = true
            removeKeyMonitor()
            highlight.dismiss()
            FocusWindowManager.sessionEnded()
        }

        private func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 0x35: self.cancel(); return nil      // Esc
                case 0x24, 0x4C: self.confirm(); return nil // Return / Enter
                case 0x7B: self.move(.left);  return nil   // ←
                case 0x7C: self.move(.right); return nil   // →
                case 0x7E: self.move(.up);    return nil   // ↑
                case 0x7D: self.move(.down);  return nil   // ↓
                default: return event
                }
            }
        }

        private func removeKeyMonitor() {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }
}
