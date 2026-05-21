//
//  FocusWindowVisibilityTests.swift
//  RectangleTests
//

import XCTest
@testable import Rectangle

final class FocusWindowVisibilityTests: XCTestCase {

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Rect subtraction helper sanity

    func test_subtract_noOverlap_returnsOriginalArea() {
        let a = rect(0, 0, 100, 100)
        let b = rect(200, 200, 100, 100)
        XCTAssertEqual(FocusWindowVisibility.remainingArea(of: a, after: [b]), 100 * 100, accuracy: 0.001)
    }

    func test_subtract_fullyCovered_returnsZero() {
        let a = rect(10, 10, 50, 50)
        let cover = rect(0, 0, 200, 200)
        XCTAssertEqual(FocusWindowVisibility.remainingArea(of: a, after: [cover]), 0, accuracy: 0.001)
    }

    func test_subtract_halfCovered_returnsHalf() {
        let a = rect(0, 0, 100, 100)
        let halfCover = rect(0, 0, 100, 50) // 아래쪽 절반 가림 (y 0~50)
        XCTAssertEqual(FocusWindowVisibility.remainingArea(of: a, after: [halfCover]), 100 * 50, accuracy: 0.001)
    }

    func test_subtract_twoOverlappingCovers_dedupesArea() {
        let a = rect(0, 0, 100, 100)
        let c1 = rect(0, 0, 60, 100)   // 좌측 60% 가림
        let c2 = rect(40, 0, 60, 100)  // 우측 60% 가림 (서로 20pt 겹침)
        // 합집합 가림 = 좌0~60 + 우40~100 = 0~100 → 전체 다 가림
        XCTAssertEqual(FocusWindowVisibility.remainingArea(of: a, after: [c1, c2]), 0, accuracy: 0.001)
    }

    func test_subtract_partialOverlap_correctRemaining() {
        let a = rect(0, 0, 100, 100)
        let cover = rect(50, 50, 100, 100) // 우상 50x50 만 겹침
        // 가려진 면적 = 50*50 = 2500. 남은 면적 = 10000 - 2500 = 7500
        XCTAssertEqual(FocusWindowVisibility.remainingArea(of: a, after: [cover]), 7500, accuracy: 0.001)
    }

    // MARK: - visibleIndices end-to-end

    func test_visibility_singleWindow_alwaysVisible() {
        let w = [rect(0, 0, 200, 200)]
        XCTAssertEqual(FocusWindowVisibility.visibleIndices(in: w, minVisibleRatio: 0.10), [0])
    }

    func test_visibility_twoNonOverlapping_bothVisible() {
        let w = [rect(0, 0, 200, 200), rect(500, 0, 200, 200)]
        XCTAssertEqual(FocusWindowVisibility.visibleIndices(in: w, minVisibleRatio: 0.10), [0, 1])
    }

    func test_visibility_smallWindowFullyCoveredByLargerFront_excluded() {
        // w[0] (front, 큰 창) 이 w[1] (small, 뒤) 을 완전히 덮음
        let w = [rect(0, 0, 500, 500), rect(100, 100, 100, 100)]
        XCTAssertEqual(FocusWindowVisibility.visibleIndices(in: w, minVisibleRatio: 0.10), [0])
    }

    func test_visibility_partiallyCovered_aboveThreshold_included() {
        // w[0] 이 w[1] 의 5% 만 가림 → w[1] 은 95% 가시 → 포함
        let w = [rect(0, 0, 100, 5), rect(0, 0, 100, 100)]
        // w[0] 이 w[1] 위에서 가려진 영역 = (0,0,100,5) ∩ (0,0,100,100) = 500
        // visible = 10000 - 500 = 9500 → 95% > 10%
        XCTAssertTrue(FocusWindowVisibility.visibleIndices(in: w, minVisibleRatio: 0.10).contains(1))
    }

    func test_visibility_almostFullyCovered_belowThreshold_excluded() {
        // w[0] 이 w[1] 의 95% 가림 → w[1] 은 5% 가시 → 제외
        let w = [rect(0, 0, 100, 95), rect(0, 0, 100, 100)]
        XCTAssertFalse(FocusWindowVisibility.visibleIndices(in: w, minVisibleRatio: 0.10).contains(1))
    }

    func test_visibility_threeStacked_middleCoveredByFront() {
        // 같은 자리에 3개 stack, 모두 같은 크기 → front 만 보임
        let w = [
            rect(0, 0, 100, 100), // 제일 앞
            rect(0, 0, 100, 100),
            rect(0, 0, 100, 100)
        ]
        XCTAssertEqual(FocusWindowVisibility.visibleIndices(in: w, minVisibleRatio: 0.10), [0])
    }
}
