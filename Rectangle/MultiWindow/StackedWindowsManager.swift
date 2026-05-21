//
//  StackedWindowsManager.swift
//  Rectangle
//
//  Adds the "Reveal Stacked Windows" action: shows a HUD listing every window
//  that currently occupies (roughly) the same frame as the front window on the
//  same display, so the user can pick one to bring forward.
//

import Cocoa

class StackedWindowsManager {

    /// Tolerance in points for considering two window frames "the same".
    /// Rectangle gaps and rounding from setFrame() can introduce small
    /// differences, so a few points of slack is sensible.
    static let frameMatchTolerance: CGFloat = 4

    /// Currently displayed picker, kept alive while visible.
    private static var activePicker: StackedWindowsPickerWindow?

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
                                           activeFrame: activeFrame,
                                           currentScreen: currentScreen,
                                           screenDetection: screenDetection)

        if candidates.isEmpty {
            NSSound.beep()
            Logger.log("StackedWindows: no other windows share this snap area")
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

    /// Returns every visible window on `currentScreen` whose frame matches
    /// `activeFrame` within `frameMatchTolerance`, excluding the active
    /// window itself.
    static func collectCandidates(activeWindow: AccessibilityElement,
                                  activeFrame: CGRect,
                                  currentScreen: NSScreen,
                                  screenDetection: ScreenDetection) -> [AccessibilityElement] {

        let allWindows = AccessibilityElement.getAllWindowElements()
        var result: [AccessibilityElement] = []

        for w in allWindows {
            if w == activeWindow { continue }
            if Defaults.todo.userEnabled, TodoManager.isTodoWindow(w) { continue }
            guard w.isWindow == true,
                  w.isSheet != true,
                  w.isMinimized != true,
                  w.isHidden != true,
                  w.isSystemDialog != true
            else { continue }

            // Same display?
            guard let wScreen = screenDetection.detectScreens(using: w)?.currentScreen,
                  wScreen == currentScreen
            else { continue }

            // Same frame (within tolerance)?
            if framesApproximatelyEqual(w.frame, activeFrame) {
                result.append(w)
            }
        }
        return result
    }

    private static func framesApproximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        return abs(a.origin.x - b.origin.x) <= frameMatchTolerance
            && abs(a.origin.y - b.origin.y) <= frameMatchTolerance
            && abs(a.size.width - b.size.width) <= frameMatchTolerance
            && abs(a.size.height - b.size.height) <= frameMatchTolerance
    }
}
