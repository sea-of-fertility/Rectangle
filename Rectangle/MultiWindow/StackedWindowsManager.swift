//
//  StackedWindowsManager.swift
//  Rectangle
//
//  Adds the "Reveal Stacked Windows" action: shows a HUD listing every window
//  that overlaps the front window enough to be considered stacked underneath
//  it, so the user can pick one to bring forward.
//
//  The overlap rule is D-max: `max(A∩B / area(A), A∩B / area(B)) >= threshold`.
//  This treats both "same-frame stack" and "small panel half on top of a big
//  window" as the same kind of relationship, so each is surfaced as a
//  candidate.
//

import Cocoa

class StackedWindowsManager {

    /// Minimum overlap ratio for a window to count as "stacked under" the
    /// active window. Compared against `overlapRatio` (D-max). 0.25 means
    /// the candidate must share at least 25% of either its own area or the
    /// active window's area with the active window.
    static let overlapThreshold: CGFloat = 0.25

    /// D-max overlap: `max(A∩B / area(A), A∩B / area(B))`.
    /// Returns 0 when either rect has zero area or they do not intersect.
    /// Picking the larger of the two ratios lets small floating panels that
    /// sit half-on-top of a much larger window still register as "stacked",
    /// while ignoring incidental edge contact.
    static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let areaA = a.width * a.height
        let areaB = b.width * b.height
        guard areaA > 0, areaB > 0 else { return 0 }
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        return max(interArea / areaA, interArea / areaB)
    }

    /// Currently displayed picker, kept alive while visible.
    private static var activePicker: StackedWindowsPickerWindow?

    static var isActive: Bool {
        activePicker?.isVisible == true
    }

    static func reveal(windowElement passedWindow: AccessibilityElement? = nil) {
        // If a picker is already up, treat the second invocation as a "next"
        // action (advance selection) instead of opening another one.
        if let picker = activePicker, picker.isVisible {
            picker.selectNext()
            return
        }

        let screenDetection = ScreenDetection()

        guard let activeWindow = passedWindow ?? AccessibilityElement.getFrontWindowElement(),
              let screens = screenDetection.detectScreens(using: activeWindow)
        else {
            NSSound.beep()
            Logger.log("StackedWindows: no front window or screen")
            return
        }

        let currentScreen = screens.currentScreen
        let activeFrame = activeWindow.frame

        let candidates = collectCandidates(activeWindow: activeWindow,
                                           activeFrame: activeFrame)

        if candidates.isEmpty {
            NSSound.beep()
            Logger.log("StackedWindows: no other windows overlap the active window")
            return
        }

        // Order: candidates are returned in front-to-back order from
        // getAllWindowElements (which is itself derived from the
        // CFArray returned by CGWindowListCopyWindowInfo). We want to
        // present them in the same order.
        let picker = StackedWindowsPickerWindow(activeWindow: activeWindow,
                                                candidates: candidates,
                                                onScreen: currentScreen)
        picker.onSelection = { selected in
            selected.bringToFront(force: true)
        }
        picker.onClose = {
            StackedWindowsManager.activePicker = nil
        }
        picker.show()
        activePicker = picker
    }

    /// Returns every visible window whose frame overlaps `activeFrame` by at
    /// least `overlapThreshold` (D-max), excluding the active window itself.
    /// Display membership is not checked — the overlap predicate already
    /// excludes windows that don't share screen coordinates with the active
    /// window, and naturally includes windows that straddle a display
    /// boundary.
    static func collectCandidates(activeWindow: AccessibilityElement,
                                  activeFrame: CGRect) -> [AccessibilityElement] {

        let allWindows = AccessibilityElement.getAllWindowElements()
        var result: [AccessibilityElement] = []

        for w in allWindows {
            // AX/CG can surface the same macOS window via different
            // AccessibilityElement instances (e.g. Chromium helper processes
            // exposing windows under a non-main pid). The plain `==` ref
            // check misses those, so also reject by CGWindowID when
            // available — that's a system-level unique id and won't
            // accidentally include the active window as its own candidate.
            if w == activeWindow { continue }
            if let aWid = activeWindow.windowId, w.windowId == aWid { continue }
            if Defaults.todo.userEnabled, TodoManager.isTodoWindow(w) { continue }
            guard w.isWindow == true,
                  w.isSheet != true,
                  w.isMinimized != true,
                  w.isHidden != true,
                  w.isSystemDialog != true
            else { continue }

            if overlapRatio(activeFrame, w.frame) >= overlapThreshold {
                result.append(w)
            }
        }
        return result
    }
}
