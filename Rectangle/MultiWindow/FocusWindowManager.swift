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

    // MARK: Space filter (B6)
    //
    // CGWindowList.optionOnScreenOnly returns windows from *other* Spaces too —
    // macOS parks them at very negative coordinates that still fall inside the
    // NSScreen union, so a frame-based filter can't exclude them. The picker
    // cursor can then land on a window that isn't actually on screen.
    //
    // The fix is two-step:
    //   1. Collect every display's *current* active Space ID via
    //      CGSManagedDisplayGetCurrentSpace.
    //   2. For each candidate wid, ask CGSCopySpacesForWindows for the Spaces
    //      it lives on and keep it only if at least one of them is in (1).
    //
    // Note: the `mask` argument of CGSCopySpacesForWindows controls the result
    // *array shape*, not "filter". mask=5/6/7 all return the wid's Space IDs;
    // a non-empty result does NOT mean "on current Space". We have to compare
    // explicitly against the active-Space set we built ourselves.
    //
    // Verified pattern: alt-tab-macos Spaces.swift (display-keyed active-Space
    // collection) + Window.swift (per-window Space lookup with mask=all).

    typealias CGSConnectionID = UInt32
    typealias CGSSpaceID = UInt64
    typealias CGSMainConnectionIDFn = @convention(c) () -> CGSConnectionID
    typealias CGSCopySpacesForWindowsFn =
        @convention(c) (CGSConnectionID, Int32, CFArray) -> CFArray?
    typealias CGSManagedDisplayGetCurrentSpaceFn =
        @convention(c) (CGSConnectionID, CFString) -> CGSSpaceID

    static let kCGSAllSpacesMask: Int32 = 7

    static let cgsMainConnectionID: CGSMainConnectionIDFn? = {
        guard let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: CGSMainConnectionIDFn.self)
    }()

    static let copySpacesForWindows: CGSCopySpacesForWindowsFn? = {
        guard let sym = dlsym(handle, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(sym, to: CGSCopySpacesForWindowsFn.self)
    }()

    static let getCurrentSpaceForDisplay: CGSManagedDisplayGetCurrentSpaceFn? = {
        guard let sym = dlsym(handle, "CGSManagedDisplayGetCurrentSpace") else { return nil }
        return unsafeBitCast(sym, to: CGSManagedDisplayGetCurrentSpaceFn.self)
    }()

    /// Returns the set of currently active Space IDs across all connected
    /// displays. Each display can host its own active Space (multi-Space
    /// arrangement), so we union them.
    static func currentSpaceIds() -> Set<CGSSpaceID> {
        guard let connID = cgsMainConnectionID,
              let getSpace = getCurrentSpaceForDisplay else { return [] }
        let cid = connID()
        var result = Set<CGSSpaceID>()
        for screen in NSScreen.screens {
            // NSScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            // gives the CGDirectDisplayID; CGSManagedDisplayGetCurrentSpace
            // takes the display *UUID* as CFString.
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let nsNum = screen.deviceDescription[key] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(nsNum.uint32Value)
            guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { continue }
            let uuidStr = CFUUIDCreateString(nil, uuidRef)!
            let spaceId = getSpace(cid, uuidStr as CFString)
            if spaceId != 0 { result.insert(spaceId) }
        }
        return result
    }

    /// Returns the subset of `ids` that live on one of the currently active
    /// Spaces. If the private API is unavailable, returns the input set
    /// unchanged (no filtering). In multi-display arrangements with "Displays
    /// have separate Spaces" enabled every display contributes its own active
    /// Space, so all visible-on-any-display windows pass through; the filter
    /// only drops windows that are genuinely on a non-active Space.
    static func filterToCurrentSpace(_ ids: [CGWindowID]) -> Set<CGWindowID> {
        guard let connID = cgsMainConnectionID,
              let copySpaces = copySpacesForWindows,
              !ids.isEmpty else {
            return Set(ids)
        }
        let activeSpaces = currentSpaceIds()
        guard !activeSpaces.isEmpty else { return Set(ids) }
        let cid = connID()
        var onCurrent = Set<CGWindowID>()
        for wid in ids {
            let result = copySpaces(cid, kCGSAllSpacesMask, [wid] as CFArray)
            let arr = (result as? [CGSSpaceID]) ?? []
            if arr.contains(where: { activeSpaces.contains($0) }) {
                onCurrent.insert(wid)
            }
        }
        return onCurrent
    }

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

    private static let minVisibleRatio: CGFloat = 0.30
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

        // Active window (we anchor the picker here). B13: nil right after the
        // frontmost app's last window closes — fall through and anchor on
        // candidate 0 below (see the activeIndex == -1 fallback).
        let active = AccessibilityElement.getFrontWindowElement()
        let activeWindowId = active?.windowId
        if activeWindowId == nil {
            Logger.log("FocusWindow: no front window; anchoring on most-recent candidate (B13)")
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
        // Note: the visibleScreensFrame intersection isn't enough on its own —
        // macOS parks off-Space windows at negative coordinates that still fall
        // inside the NSScreen union, so we follow with a CGSCopySpacesForWindows
        // filter below to drop those.
        let rawInfos = WindowUtil.getWindowList().filter { info in
            info.level == 0
                && !excludedProcessNames.contains(info.processName ?? "")
                && info.frame.width >= minDimension
                && info.frame.height >= minDimension
                && info.frame.intersects(visibleScreensFrame)
        }

        // B6 fix: keep only windows that live on the *current* Space. Without
        // this the picker cursor can land on a window that's geometrically in
        // the NSScreen union but actually on a different Space, so the user
        // sees the highlight on top of whatever's actually displayed there and
        // confirm activates a window they never saw.
        let onCurrent = SkyLightPrivate.filterToCurrentSpace(rawInfos.map { $0.id })
        let allInfos = rawInfos.filter { onCurrent.contains($0.id) }
        Logger.log("FocusWindow: space-filter kept \(allInfos.count) of \(rawInfos.count) windows on current Space")

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
        // even for odd windows. But: if the "active" window is actually
        // minimized, getFrontWindowElement()'s AX state lags for a few
        // seconds after the minimize button is clicked, and its wid is
        // already gone from CGWindowList. The synthetic entry would then
        // hold the window's last on-screen frame, and the picker would
        // draw its highlight on empty desktop space (B8 follow-up).
        // In that case skip the synthetic entry and anchor the cursor on
        // the first real candidate instead — that's the front-most actual
        // window from CGWindowList, the natural place to start the picker.
        // B13 shares that anchor path: with no resolvable front window at
        // all (last window of the frontmost app was closed), candidate 0 is
        // the most recently used window that's still on screen.
        if activeIndex == -1 {
            if let active, let activeWindowId, active.isMinimized != true {
                let activeFrameFromAX = active.frame
                let synthetic = WindowInfo(id: activeWindowId,
                                           level: 0,
                                           frame: activeFrameFromAX,
                                           pid: active.pid ?? 0,
                                           processName: nil)
                activeIndex = candidateInfos.count
                candidateInfos.append(synthetic)
            } else {
                // B8 (active minimized) / B13 (no front window / no wid)
                guard !candidateInfos.isEmpty else {
                    NSSound.beep()
                    Logger.log("FocusWindow: no anchor and no candidates, bail")
                    return
                }
                activeIndex = 0
            }
        }

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
    /// Activates the given window. Returns `false` if the chosen window was
    /// minimized (B8) or closed (B11) between picker reveal and confirm —
    /// caller should treat that like a cancel (restore the previous frontmost
    /// app) rather than leaving Rectangle frontmost.
    @discardableResult
    static func raiseAndActivate(_ info: WindowInfo) -> Bool {
        // First attempt: use the PID we already have.
        let directApp = AccessibilityElement(info.pid)
        let directElements = directApp.windowElements ?? []

        // If that PID didn't yield any windows (e.g. Chromium helper process),
        // scan every running app and look for the window by id.
        var resolvedTarget: AccessibilityElement?
        var resolvedPid: pid_t = info.pid

        if let viaDirect = directElements.first(where: { $0.windowId == info.id }) {
            resolvedTarget = viaDirect
        } else {
            for runningApp in NSWorkspace.shared.runningApplications {
                guard runningApp.activationPolicy == .regular || runningApp.activationPolicy == .accessory else { continue }
                let pid = runningApp.processIdentifier
                let appElement = AccessibilityElement(pid)
                guard let windows = appElement.windowElements else { continue }
                if let match = windows.first(where: { $0.windowId == info.id }) {
                    resolvedTarget = match
                    resolvedPid = pid
                    break
                }
            }
        }

        // Fallback by frame if still nothing.
        if resolvedTarget == nil {
            resolvedTarget = directElements.first { w in
                let f = w.frame
                return abs(f.minX - info.frame.minX) < 2 && abs(f.minY - info.frame.minY) < 2
                    && abs(f.width - info.frame.width) < 2 && abs(f.height - info.frame.height) < 2
            }
        }

        // B8: if the chosen window was minimized between reveal() and now
        // (the picker keeps a static candidate snapshot, so the user can
        // minimize a candidate via Cmd+M / yellow button while the highlight
        // is still up), bail. Otherwise the raise/activate sequence below
        // would pull the window back out of the Dock — the user picked an
        // "empty rectangle" but a hidden window comes flying out.
        //
        // B11: same story when the window can't be resolved via AX at all —
        // it was closed between reveal() and confirm (stale entry from
        // WindowUtil's 100ms cache, or an auto-closing dialog). Activating
        // blindly with a dead wid would still front the owning app and pull
        // an arbitrary sibling window forward.
        guard let target = resolvedTarget, target.isMinimized != true else {
            NSSound.beep()
            Logger.log("FocusWindow: chosen wid \(info.id) is minimized or gone from AX, bail")
            return false  // Caller (Session.confirm) handles previousApp restore.
        }

        // Activation. Try the SkyLight private path first — it activates only
        // the chosen window and leaves sibling windows in their original
        // z-order, which is what we want for B5. If that fails (private
        // symbols missing, OS rejected the call), fall back to the public
        // NSRunningApplication.activate path. That fallback still has the B5
        // behavior, but it's better than not activating at all.
        let usedPrivate = SkyLightPrivate.focusWindowLikeClick(pid: resolvedPid,
                                                               windowId: info.id)
        if !usedPrivate, let runningApp = NSRunningApplication(processIdentifier: resolvedPid) {
            runningApp.activate(options: .activateIgnoringOtherApps)
        }

        _ = target.raise()
        target.setMain(true)
        return true
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
            }
        }

        private func confirm() {
            if dismissing { return }
            dismissing = true
            removeKeyMonitor()
            highlight.dismiss()
            let chosen = candidates[cursorIndex]
            let activated = FocusWindowManager.raiseAndActivate(chosen)
            if !activated {
                // B8 path: chosen window was minimized mid-session, so we
                // didn't activate anyone. Restore the pre-picker frontmost
                // app — same as cancel() does — otherwise Rectangle stays
                // frontmost and the next reveal() bails out at no front
                // window (B3 regression).
                restorePreviousFrontmost()
            }
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
            restorePreviousFrontmost()
            FocusWindowManager.sessionEnded()
        }

        /// Hands frontmost back to some other app so Rectangle (which has no
        /// visible window) doesn't stay topmost. Without this the next
        /// reveal() would bail at getFrontWindowElement() == nil.
        ///
        /// Preferred target: the app that was frontmost when reveal() captured
        /// `previousApp`. EC1 case: that capture returned nil because
        /// Rectangle itself was frontmost when picker was invoked (e.g. from
        /// the Preferences window). In that case fall back to any regular
        /// running app that isn't us — anything is better than leaving
        /// Rectangle on top.
        private func restorePreviousFrontmost() {
            if let prev = previousApp,
               prev.activate(options: .activateIgnoringOtherApps) {
                return
            }
            let myPid = getpid()
            let fallback = NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.processIdentifier != myPid
            }
            fallback?.activate(options: .activateIgnoringOtherApps)
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
