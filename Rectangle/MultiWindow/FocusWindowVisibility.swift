//
//  FocusWindowVisibility.swift
//  Rectangle
//
//  Rectangle-difference based occlusion: given an ordered list of window
//  frames (front to back), compute which windows still have at least
//  `minVisibleRatio` of their area visible after the windows in front of
//  them have painted over them.
//

import CoreGraphics

enum FocusWindowVisibility {

    /// Returns indices of windows whose visible area / frame area >= `minVisibleRatio`.
    /// `windows` must be ordered front to back (windows[0] is the topmost).
    static func visibleIndices(in windows: [CGRect],
                               minVisibleRatio: CGFloat) -> Set<Int> {
        var result = Set<Int>()
        for i in windows.indices {
            let frame = windows[i]
            let total = frame.width * frame.height
            guard total > 0 else { continue }

            let covers = Array(windows[..<i])
            let remaining = remainingArea(of: frame, after: covers)
            if remaining / total >= minVisibleRatio {
                result.insert(i)
            }
        }
        return result
    }

    /// Area of `target` not covered by any of `covers`.
    /// Implemented via iterative rectangle subtraction — each cover splits
    /// every current fragment into up to four sub-rectangles.
    static func remainingArea(of target: CGRect, after covers: [CGRect]) -> CGFloat {
        var fragments: [CGRect] = [target]
        for cover in covers {
            var next: [CGRect] = []
            for f in fragments {
                next.append(contentsOf: subtract(f, cover))
            }
            fragments = next
            if fragments.isEmpty { break }
        }
        return fragments.reduce(0) { $0 + $1.width * $1.height }
    }

    /// a − b. Returns up to 4 rectangles that together cover the part of `a`
    /// that doesn't overlap `b`. If they don't overlap, returns [a].
    private static func subtract(_ a: CGRect, _ b: CGRect) -> [CGRect] {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return [a] }
        if inter == a { return [] } // a fully inside b

        var pieces: [CGRect] = []

        // top slab: above inter
        if inter.maxY < a.maxY {
            pieces.append(CGRect(x: a.minX,
                                 y: inter.maxY,
                                 width: a.width,
                                 height: a.maxY - inter.maxY))
        }
        // bottom slab: below inter
        if inter.minY > a.minY {
            pieces.append(CGRect(x: a.minX,
                                 y: a.minY,
                                 width: a.width,
                                 height: inter.minY - a.minY))
        }
        // left slab: same y range as inter, left of inter
        if inter.minX > a.minX {
            pieces.append(CGRect(x: a.minX,
                                 y: inter.minY,
                                 width: inter.minX - a.minX,
                                 height: inter.height))
        }
        // right slab
        if inter.maxX < a.maxX {
            pieces.append(CGRect(x: inter.maxX,
                                 y: inter.minY,
                                 width: a.maxX - inter.maxX,
                                 height: inter.height))
        }
        return pieces
    }
}
