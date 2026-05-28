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
import Carbon

// MARK: - SkyLight / Process Manager private API (B5)
//
// NSRunningApplication.activate() promotes every window of the target app
// above unrelated apps, which is what produces B5 — picking one Brave window
// also unburies sibling Brave windows on other displays. The Carbon-era
// process-manager primitive that the real mouse-click path uses,
// _SLPSSetFrontProcessWithOptions, can activate a *specific* window without
// dragging siblings along. Plus a synthesized SLPSPostEventRecordTo pair so
// Chromium/Electron apps actually treat the targeted window as key.
//
// Verified usage:
//   - yabai (src/window_manager.c:1320, src/misc/extern.h:81)
//   - alt-tab-macos (Window.swift, SkyLight.framework.swift)
//
// These symbols live in SkyLight.framework and are private. If a future macOS
// release removes them, the dlsym lookup returns nil and we fall back to the
// public NSRunningApplication.activate path.
private enum SkyLightPrivate {
    typealias SLPSSetFrontProcessWithOptions =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> OSStatus
    typealias SLPSPostEventRecordTo =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> OSStatus
    // GetProcessForPID is marked unavailable in Swift but the C symbol still
    // exists in HIServices, so reach it via dlsym.
    typealias GetProcessForPIDFn =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    // Mode bits from yabai (src/window_manager.h:88-90).
    static let kCPSUserGenerated: UInt32 = 0x200

    private static let handle: UnsafeMutableRawPointer? = {
        // SkyLight is brought in transitively by AppKit; use RTLD_DEFAULT so
        // we don't pin to a specific framework path that might move.
        UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    }()

    static let setFrontProcess: SLPSSetFrontProcessWithOptions? = {
        guard let sym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else { return nil }
        return unsafeBitCast(sym, to: SLPSSetFrontProcessWithOptions.self)
    }()

    static let postEventRecordTo: SLPSPostEventRecordTo? = {
        guard let sym = dlsym(handle, "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(sym, to: SLPSPostEventRecordTo.self)
    }()

    static let getProcessForPID: GetProcessForPIDFn? = {
        guard let sym = dlsym(handle, "GetProcessForPID") else { return nil }
        return unsafeBitCast(sym, to: GetProcessForPIDFn.self)
    }()

    /// Mouse-click-equivalent activation: focuses the given window without
    /// promoting its sibling windows. Returns false if the private symbols
    /// aren't available or the OS rejected the call — callers should fall
    /// back to NSRunningApplication.activate.
    static func focusWindowLikeClick(pid: pid_t, windowId: UInt32) -> Bool {
        guard let setFront = setFrontProcess,
              let postEvent = postEventRecordTo,
              let getPSN = getProcessForPID else { return false }

        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }

        let status1 = setFront(&psn, windowId, kCPSUserGenerated)
        if status1 != noErr { return false }

        // Synthesized make-key-window events. Byte layout reverse-engineered
        // from yabai's window_manager_make_key_window (src/window_manager.c:1269).
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowId) { src in
            for i in 0..<MemoryLayout<UInt32>.size {
                bytes[0x3c + i] = src[i]
            }
        }
        for i in 0..<0x10 { bytes[0x20 + i] = 0xff }

        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { buf in
            postEvent(&psn, buf.baseAddress!)
        }
        usleep(40_000)
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { buf in
            postEvent(&psn, buf.baseAddress!)
        }
        return true
    }
}

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

        // Capture the app that was frontmost *before* we activate Rectangle to
        // show the picker. On Esc-cancel we restore it as frontmost — otherwise
        // Rectangle stays frontmost (it has no visible window) and the next
        // reveal() bails out at getFrontWindowElement() == nil. Skip Rectangle
        // itself in the unlikely case it was already frontmost.
        let previousApp: NSRunningApplication? = {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != getpid() else { return nil }
            return app
        }()

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

        // ---- DIAGNOSTIC (B6) -----------------------------------------------
        // Off-Space windows park at very negative coordinates. The current
        // filter intersects against the union of all NSScreen frames — if
        // a parked window's frame still happens to overlap that union, it
        // sneaks into the candidate list and the picker cursor can land on
        // an invisible window. Log each NSScreen and the union rect so we
        // can confirm whether the filter is geometrically capable of
        // excluding them.
        NSLog("[FW] reveal: NSScreen.screens (flipped):")
        for (i, s) in NSScreen.screens.enumerated() {
            NSLog("[FW]   screen[%d] frame=%@", i, NSStringFromRect(s.frame.screenFlipped))
        }
        NSLog("[FW] reveal: visibleScreensFrame=%@", NSStringFromRect(visibleScreensFrame))
        // --------------------------------------------------------------------

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

        let session = Session(candidates: candidateInfos,
                              startIndex: activeIndex,
                              previousApp: previousApp)
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

        // ---- DIAGNOSTIC (B5) ------------------------------------------------
        // Snapshot the global front-to-back z-order BEFORE we raise/activate.
        // We log every window (not just the chosen app's) so we can see what
        // was above/below the chosen app's sibling windows on other displays.
        // Compared against the post-raise snapshot below, this reveals whether
        // activate() lifted *all* windows of the chosen app above unrelated
        // apps that were previously covering them.
        let preList = WindowUtil.getWindowList().filter { $0.level == 0 }
        NSLog("[FW] confirm: ---- pre-raise z-order (front→back, level=0) ----")
        for (i, w) in preList.enumerated() {
            let samePid = (w.pid == info.pid) ? " [SAME APP]" : ""
            NSLog("[FW]   z[%d] wid=%u pid=%d proc=%@ frame=%@%@",
                  i, w.id, w.pid, w.processName ?? "?",
                  NSStringFromRect(w.frame), samePid)
        }
        // ---------------------------------------------------------------------

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

        // Activation. Try the SkyLight private path first — it activates only
        // the chosen window and leaves sibling windows in their original
        // z-order, which is what we want for B5. If that fails (private
        // symbols missing, OS rejected the call), fall back to the public
        // NSRunningApplication.activate path. That fallback still has the B5
        // behavior, but it's better than not activating at all.
        let usedPrivate = SkyLightPrivate.focusWindowLikeClick(pid: resolvedPid,
                                                               windowId: info.id)
        if usedPrivate {
            NSLog("[FW] confirm: activated via SLPS (single-window) pid=%d wid=%u",
                  resolvedPid, info.id)
        } else if let runningApp = NSRunningApplication(processIdentifier: resolvedPid) {
            runningApp.activate(options: .activateIgnoringOtherApps)
            NSLog("[FW] confirm: activated via NSRunningApplication (fallback) pid=%d", resolvedPid)
        }

        if let target = resolvedTarget {
            let raiseOK = target.raise()
            target.setMain(true)
            NSLog("[FW] confirm: AXRaise result=%@ (post-activate)", raiseOK ? "OK" : "FAIL")
        } else {
            NSLog("[FW] confirm: gave up — no resolvable AX element. activate only.")
        }

        // ---- DIAGNOSTIC (B5) ------------------------------------------------
        // Snapshot the global z-order again after activate+raise has settled.
        // For B5 the smoking gun is: a sibling window of the chosen app sat
        // mid-stack pre-raise (with other apps' windows above it), and now
        // sits above those same windows post-raise — i.e. activate() lifted
        // the whole app group.
        let intendedId = info.id
        let intendedPid = info.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let postList = WindowUtil.getWindowList().filter { $0.level == 0 }
            NSLog("[FW] confirm: ---- post-raise z-order (front→back, level=0) ----")
            for (i, w) in postList.enumerated() {
                let samePid = (w.pid == intendedPid) ? " [SAME APP]" : ""
                let chosen = (w.id == intendedId) ? " <-- CHOSEN" : ""
                NSLog("[FW]   z[%d] wid=%u pid=%d proc=%@ frame=%@%@%@",
                      i, w.id, w.pid, w.processName ?? "?",
                      NSStringFromRect(w.frame), samePid, chosen)
            }
        }
        // ---------------------------------------------------------------------
    }

    private final class Session {
        private let candidates: [WindowInfo]
        private var cursorIndex: Int       // index into `candidates`
        private let previousApp: NSRunningApplication?
        private let highlight = WindowHighlightWindow()
        private var keyMonitor: Any?
        private var globalClickMonitor: Any?
        private var dismissing = false

        init(candidates: [WindowInfo], startIndex: Int, previousApp: NSRunningApplication?) {
            self.candidates = candidates
            self.cursorIndex = startIndex
            self.previousApp = previousApp
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
            // Restore the app that was frontmost before we showed the picker.
            // Without this, Rectangle stays frontmost and a subsequent reveal()
            // sees no front window (Rectangle has none) and bails out.
            previousApp?.activate(options: .activateIgnoringOtherApps)
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
