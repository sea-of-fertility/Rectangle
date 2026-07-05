//
//  FocusWindowGeometry.swift
//  Rectangle
//
//  Pure-function quadrant-based directional window selection.
//

import CoreGraphics

enum FocusDirection {
    case left, right, up, down
}

enum FocusWindowGeometry {

    /// Picks the next window to focus when the user presses a direction key.
    ///
    /// All rects are in CGWindowList/AX (top-origin) coordinates — y grows
    /// downward, so "up" means a *smaller* midY. This matches the frames
    /// FocusWindowManager feeds in from WindowUtil.getWindowList().
    ///
    /// Candidates pass the "quadrant gate" — they must be on the requested side
    /// of `current`, and the requested axis must be at least half the magnitude
    /// of the orthogonal axis. Among passing candidates, the one with the
    /// shortest Euclidean midpoint distance wins; ties are broken by preferring
    /// the upper / leftmost / lower index.
    ///
    /// The 0.5 axis ratio (vs. a strict > comparison) admits diagonal
    /// neighbours that are still mostly in the requested direction. The strict
    /// form silently dropped windows whose horizontal component was real but
    /// smaller than the vertical component — e.g. monitor B's window seeing
    /// monitor C's leftmost window across a vertical offset (B7).
    ///
    /// - Returns: index into `candidates`, or nil if no candidate qualifies.
    static func nextWindow(from current: CGRect,
                           direction: FocusDirection,
                           candidates: [CGRect]) -> Int? {

        struct Scored {
            let index: Int
            let distance: CGFloat
            let midX: CGFloat
            let midY: CGFloat
        }

        var scored: [Scored] = []
        let cx = current.midX
        let cy = current.midY
        let axisRatio: CGFloat = 0.5

        for (i, c) in candidates.enumerated() {
            let dx = c.midX - cx
            let dy = c.midY - cy
            let adx = abs(dx)
            let ady = abs(dy)

            let inQuadrant: Bool
            switch direction {
            case .left:  inQuadrant = dx < 0 && adx >= ady * axisRatio
            case .right: inQuadrant = dx > 0 && adx >= ady * axisRatio
            case .up:    inQuadrant = dy < 0 && ady >= adx * axisRatio
            case .down:  inQuadrant = dy > 0 && ady >= adx * axisRatio
            }
            guard inQuadrant else { continue }

            let distance = (dx * dx + dy * dy).squareRoot()
            scored.append(Scored(index: i, distance: distance, midX: c.midX, midY: c.midY))
        }

        guard !scored.isEmpty else { return nil }

        scored.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.midY != b.midY { return a.midY < b.midY }       // upper first (top-origin: smaller y = higher)
            if a.midX != b.midX { return a.midX < b.midX }       // leftmost first
            return a.index < b.index
        }
        return scored.first?.index
    }
}
