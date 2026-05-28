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

    static var isActive: Bool {
        activeSession != nil
    }

    static func reveal() {
        if activeSession != nil { return }   // already running

        // ---- DIAGNOSTIC (B3 hypothesis A) ----------------------------------
        // Log who macOS considers frontmost at the moment reveal() starts.
        // If this is Rectangle itself after a previous cancel, getFrontWindow
        // Element() will return nil (we have no visible window) and bail.
        if let front = NSWorkspace.shared.frontmostApplication {
            NSLog("[FW] reveal: frontmost app pid=%d bundleId=%@ name=%@",
                  front.processIdentifier,
                  front.bundleIdentifier ?? "?",
                  front.localizedName ?? "?")
        } else {
            NSLog("[FW] reveal: NSWorkspace.frontmostApplication is nil")
        }
        // --------------------------------------------------------------------

        // Active window (we anchor the picker here).
        guard let active = AccessibilityElement.getFrontWindowElement(),
              let activeWindowId = active.windowId else {
            NSSound.beep()
            NSLog("[FW] reveal: no front window — bailing (likely Rectangle is frontmost)")
            Logger.log("FocusWindow: no front window")
            return
        }

        // Union of every NSScreen's frame, in CGWindowList (top-origin)
        // coordinates. macOS parks windows from *other* Spaces at large
        // negative coordinates (e.g. x = -4890), and CGWindowList's
        // `.optionOnScreenOnly` still returns them — they're "on screen" in
        // their own Space, just not in ours. We use this rect to filter them
        // out below.
        let visibleScreensFrame = NSScreen.screens
            .map { $0.frame.screenFlipped }
            .reduce(CGRect.null) { $0.union($1) }

        // All visible windows in front-to-back order, filtered to app-level windows.
        let allInfos = WindowUtil.getWindowList().filter { info in
            info.level == 0
                && !excludedProcessNames.contains(info.processName ?? "")
                && info.frame.width >= minDimension
                && info.frame.height >= minDimension
                && info.frame.intersects(visibleScreensFrame)
        }

        let frames = allInfos.map { $0.frame }
        let visibleSet = FocusWindowVisibility.visibleIndices(in: frames, minVisibleRatio: minVisibleRatio)

        // Build candidates — include the active window too, so the cursor can
        // navigate back to it after moving away. The cursor starts on the
        // active window, identified by its index in `candidateInfos`.
        var candidateInfos: [WindowInfo] = []
        var activeIndex: Int = -1
        for (i, info) in allInfos.enumerated() where visibleSet.contains(i) {
            if info.id == activeWindowId { activeIndex = candidateInfos.count }
            candidateInfos.append(info)
        }
        // Fall back to a synthetic active entry if the active window didn't
        // survive the visibility/level filters — keeps the picker meaningful
        // even for odd windows.
        if activeIndex == -1 {
            let activeFrameFromAX = active.frame
            let synthetic = WindowInfo(id: activeWindowId,
                                       level: 0,
                                       frame: activeFrameFromAX,
                                       pid: active.pid ?? 0,
                                       processName: nil)
            activeIndex = candidateInfos.count
            candidateInfos.append(synthetic)
        }

        // ---- DIAGNOSTIC -----------------------------------------------------
        NSLog("[FW] reveal: active wid=%u pid=%d activeIndex=%d",
              activeWindowId, active.pid ?? -1, activeIndex)
        for (i, info) in candidateInfos.enumerated() {
            NSLog("[FW] candidate[%d] wid=%u pid=%d proc=%@ frame=%@%@",
                  i, info.id, info.pid, info.processName ?? "?",
                  NSStringFromRect(info.frame),
                  i == activeIndex ? " (active)" : "")
        }
        // ---------------------------------------------------------------------

        let session = Session(candidates: candidateInfos, startIndex: activeIndex)
        session.start()
        activeSession = session
    }

    fileprivate static func sessionEnded() {
        activeSession = nil
    }

    /// Raise the given window via the AX standard `AXRaise` action and then
    /// activate its owning app. `AXRaise` is required to disambiguate between
    /// multiple same-app windows — `isMainWindow = true` + `NSRunningApplication
    /// .activate(...)` alone is unreliable on Chromium/Electron apps (e.g.
    /// Brave): they ignore the main-window setter and macOS then restores the
    /// app's most-recent key window, which can sit on a different display
    /// than the one the user picked.
    fileprivate static func raiseAndActivate(_ info: WindowInfo) {
        NSLog("[FW] confirm: chosen wid=%u pid=%d proc=%@ frame=%@",
              info.id, info.pid, info.processName ?? "?", NSStringFromRect(info.frame))

        // First attempt: use the PID we already have.
        let directApp = AccessibilityElement(info.pid)
        let directElements = directApp.windowElements ?? []
        NSLog("[FW] confirm: directApp(pid=%d) has %d AX windowElements", info.pid, directElements.count)
        for (i, w) in directElements.enumerated() {
            NSLog("[FW]   directAxwin[%d] wid=%@ frame=%@ title=%@",
                  i,
                  w.windowId.map { "\($0)" } ?? "nil",
                  NSStringFromRect(w.frame),
                  w.title ?? "?")
        }

        // If that PID didn't yield any windows (e.g. Chromium helper process),
        // scan every running app and look for the window by id.
        var resolvedTarget: AccessibilityElement?
        var resolvedPid: pid_t = info.pid

        if let viaDirect = directElements.first(where: { $0.windowId == info.id }) {
            resolvedTarget = viaDirect
            NSLog("[FW] confirm: matched directly via PID")
        } else {
            NSLog("[FW] confirm: direct PID match failed — scanning all running apps for windowId=%u", info.id)
            for runningApp in NSWorkspace.shared.runningApplications {
                guard runningApp.activationPolicy == .regular || runningApp.activationPolicy == .accessory else { continue }
                let pid = runningApp.processIdentifier
                let appElement = AccessibilityElement(pid)
                guard let windows = appElement.windowElements else { continue }
                if let match = windows.first(where: { $0.windowId == info.id }) {
                    NSLog("[FW]   found via scan: pid=%d bundleId=%@ name=%@",
                          pid,
                          runningApp.bundleIdentifier ?? "?",
                          runningApp.localizedName ?? "?")
                    resolvedTarget = match
                    resolvedPid = pid
                    break
                }
            }
        }

        // Fallback by frame if still nothing.
        if resolvedTarget == nil {
            NSLog("[FW] confirm: no AX match by windowId at all — trying frame-based fallback in directApp")
            resolvedTarget = directElements.first { w in
                let f = w.frame
                return abs(f.minX - info.frame.minX) < 2 && abs(f.minY - info.frame.minY) < 2
                    && abs(f.width - info.frame.width) < 2 && abs(f.height - info.frame.height) < 2
            }
        }

        // Order matters here for Chromium/Electron apps (Brave, Chrome, VS Code,
        // Slack, ...). If we AXRaise *before* activating the app, macOS often
        // re-promotes the app's last-known-main window during the subsequent
        // activate, undoing our raise. So: activate first, then AXRaise, then
        // set AXMain — that order survives Chromium's habit of resetting main
        // window state.
        if let runningApp = NSRunningApplication(processIdentifier: resolvedPid) {
            runningApp.activate(options: .activateIgnoringOtherApps)
            NSLog("[FW] confirm: activated app pid=%d", resolvedPid)
        }

        if let target = resolvedTarget {
            let raiseOK = target.raise()
            target.setMain(true)
            NSLog("[FW] confirm: AXRaise result=%@ (post-activate)", raiseOK ? "OK" : "FAIL")
        } else {
            NSLog("[FW] confirm: gave up — no resolvable AX element. activate only.")
        }
    }

    private final class Session {
        private let candidates: [WindowInfo]
        private var cursorIndex: Int       // index into `candidates`
        private let highlight = WindowHighlightWindow()
        private var keyMonitor: Any?
        private var globalClickMonitor: Any?
        private var dismissing = false

        init(candidates: [WindowInfo], startIndex: Int) {
            self.candidates = candidates
            self.cursorIndex = startIndex
        }

        func start() {
            // candidates is non-empty by construction in reveal() — at minimum
            // it contains the active window itself.
            highlight.update(toAXFrame: candidates[cursorIndex].frame)
            highlight.onResignKey = { [weak self] in self?.cancel() }
            highlight.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            installKeyMonitor()
            installGlobalClickMonitor()
        }

        private func move(_ direction: FocusDirection) {
            // FocusWindowGeometry expects "candidates exclusive of current".
            // We pass the full list but filter out the current cursor index
            // so the cursor can't pick itself.
            let current = candidates[cursorIndex].frame
            var others: [(idxInFull: Int, frame: CGRect)] = []
            for (i, c) in candidates.enumerated() where i != cursorIndex {
                others.append((i, c.frame))
            }
            let othersFrames = others.map { $0.frame }
            if let nextInOthers = FocusWindowGeometry.nextWindow(from: current,
                                                                  direction: direction,
                                                                  candidates: othersFrames) {
                let nextFullIndex = others[nextInOthers].idxInFull
                cursorIndex = nextFullIndex
                highlight.update(toAXFrame: candidates[nextFullIndex].frame)
                NSLog("[FW] move dir=%@ → cursorIndex=%d wid=%u proc=%@ frame=%@",
                      "\(direction)", nextFullIndex, candidates[nextFullIndex].id,
                      candidates[nextFullIndex].processName ?? "?",
                      NSStringFromRect(candidates[nextFullIndex].frame))
            } else {
                NSLog("[FW] move dir=%@ → no candidate", "\(direction)")
            }
        }

        private func confirm() {
            if dismissing { return }
            dismissing = true
            removeKeyMonitor()
            highlight.dismiss()
            let chosen = candidates[cursorIndex]
            FocusWindowManager.raiseAndActivate(chosen)
            FocusWindowManager.sessionEnded()
        }

        private func cancel() {
            if dismissing { return }
            dismissing = true
            removeKeyMonitor()
            highlight.dismiss()
            FocusWindowManager.sessionEnded()
            // ---- DIAGNOSTIC (B3 hypothesis A) ------------------------------
            // After cancel, who is frontmost? If Rectangle stays frontmost, the
            // next reveal() will see itself and bail.
            DispatchQueue.main.async {
                if let front = NSWorkspace.shared.frontmostApplication {
                    NSLog("[FW] cancel: post-cancel frontmost app pid=%d bundleId=%@ name=%@",
                          front.processIdentifier,
                          front.bundleIdentifier ?? "?",
                          front.localizedName ?? "?")
                } else {
                    NSLog("[FW] cancel: post-cancel frontmost is nil")
                }
            }
            // ----------------------------------------------------------------
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

        /// If the user clicks anywhere outside our highlight window, the
        /// picker should give up. Without this, picker can become a zombie
        /// when the user switches apps via mouse without confirming.
        private func installGlobalClickMonitor() {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.cancel()
            }
        }

        private func removeMonitors() {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        }

        private func removeKeyMonitor() {
            removeMonitors()
        }
    }
}
