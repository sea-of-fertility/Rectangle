//
//  StackedWindowsOverlapTests.swift
//  RectangleTests
//
//  Tests for the D-max overlap predicate used by Reveal Stacked Windows.
//  overlapRatio(A, B) = max(A∩B / area(A), A∩B / area(B))
//  A window pair is considered "overlapping enough" when the ratio is
//  >= StackedWindowsManager.overlapThreshold (0.25).
//

import XCTest
@testable import Rectangle

final class StackedWindowsOverlapTests: XCTestCase {

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - overlapRatio basic behavior

    func test_overlapRatio_identicalFrames_isOne() {
        let a = rect(0, 0, 100, 100)
        XCTAssertEqual(StackedWindowsManager.overlapRatio(a, a), 1.0, accuracy: 0.0001)
    }

    func test_overlapRatio_disjoint_isZero() {
        let a = rect(0, 0, 100, 100)
        let b = rect(200, 200, 100, 100)
        XCTAssertEqual(StackedWindowsManager.overlapRatio(a, b), 0.0, accuracy: 0.0001)
    }

    func test_overlapRatio_touchingEdgesOnly_isZero() {
        // a 와 b 가 x=100 변에서 모서리만 접촉 → 교차 면적 0
        let a = rect(0, 0, 100, 100)
        let b = rect(100, 0, 100, 100)
        XCTAssertEqual(StackedWindowsManager.overlapRatio(a, b), 0.0, accuracy: 0.0001)
    }

    func test_overlapRatio_smallContainedInLarge_isOneFromSmallSide() {
        // 큰 창 A(1000x1000) 안에 작은 창 B(100x100) 가 완전히 포함됨
        // A∩B / area(A) = 10000 / 1_000_000 = 0.01
        // A∩B / area(B) = 10000 / 10000     = 1.00
        // max = 1.00
        let a = rect(0, 0, 1000, 1000)
        let b = rect(100, 100, 100, 100)
        XCTAssertEqual(StackedWindowsManager.overlapRatio(a, b), 1.0, accuracy: 0.0001)
    }

    func test_overlapRatio_smallHalfOverlapsLarge_isHalfFromSmallSide() {
        // 큰 창 A(1000x1000), 작은 창 B(100x100) 의 좌측 절반(50x100)이 A 와 겹침
        // A∩B = 50 * 100 = 5000
        // / area(A) = 5000 / 1_000_000 = 0.005
        // / area(B) = 5000 / 10_000    = 0.5
        // max = 0.5
        let a = rect(0, 0, 1000, 1000)
        let b = rect(950, 0, 100, 100)   // 우반쪽이 A 밖으로 50pt 삐져나감
        XCTAssertEqual(StackedWindowsManager.overlapRatio(a, b), 0.5, accuracy: 0.0001)
    }

    func test_overlapRatio_zeroAreaInputs_returnsZero() {
        // 면적 0 케이스 (가드)
        let a = rect(0, 0, 100, 100)
        let degenerate = rect(50, 50, 0, 0)
        XCTAssertEqual(StackedWindowsManager.overlapRatio(a, degenerate), 0.0, accuracy: 0.0001)
        XCTAssertEqual(StackedWindowsManager.overlapRatio(degenerate, a), 0.0, accuracy: 0.0001)
    }

    // MARK: - Threshold semantics (D-max, 25%)

    func test_overlapThreshold_isExposedAndQuarter() {
        XCTAssertEqual(StackedWindowsManager.overlapThreshold, 0.25, accuracy: 0.0001)
    }

    func test_threshold_aboveBoundary_passes() {
        // 작은 창 B 의 26% 가 A 와 겹침 → max ≥ 0.26 ≥ 0.25 → 통과
        // A(1000x1000), B(100x100), B의 26%만 A 안 (26x100)
        let a = rect(0, 0, 1000, 1000)
        let b = rect(974, 0, 100, 100)
        XCTAssertGreaterThanOrEqual(StackedWindowsManager.overlapRatio(a, b),
                                    StackedWindowsManager.overlapThreshold)
    }

    func test_threshold_belowBoundary_fails() {
        // 작은 창 B 의 24% 가 A 와 겹침 → max = 0.24 < 0.25 → 불통과
        let a = rect(0, 0, 1000, 1000)
        let b = rect(976, 0, 100, 100)
        XCTAssertLessThan(StackedWindowsManager.overlapRatio(a, b),
                          StackedWindowsManager.overlapThreshold)
    }

    // MARK: - Regression: stacked-equal-frame case still qualifies

    func test_regression_sameFrameStack_qualifies() {
        // 기존 Reveal Stacked Windows 가 잡던 케이스 — 동일 frame 두 창
        let a = rect(100, 100, 800, 600)
        let b = rect(100, 100, 800, 600)
        XCTAssertGreaterThanOrEqual(StackedWindowsManager.overlapRatio(a, b),
                                    StackedWindowsManager.overlapThreshold)
    }

    func test_regression_sameFrameWithinTolerance_qualifies() {
        // Rectangle gap / 반올림으로 frame 이 1~3pt 어긋난 경우도 25% 훨씬 넘게
        // 겹치므로 자연스럽게 후보로 잡힌다.
        let a = rect(100, 100, 800, 600)
        let b = rect(102, 101, 798, 599)
        XCTAssertGreaterThanOrEqual(StackedWindowsManager.overlapRatio(a, b),
                                    StackedWindowsManager.overlapThreshold)
    }

    // MARK: - Realistic display-spanning case

    func test_displaySpanning_largeWindowOverlapsSmallActive_qualifiesFromSmallSide() {
        // 디스플레이 경계에 걸친 큰 창 B(두 모니터에 걸침, 2560x1415)
        // 활성 창 A 는 한 모니터 안에 있는 작은 창 (1280x800)
        // A 가 B 안에 완전히 들어가는 모양: A∩B = area(A)
        // / area(A) = 1.0, / area(B) = (1280*800) / (2560*1415) ≈ 0.28
        // max = 1.0 → 통과
        let a = rect(0, 25, 1280, 800)
        let b = rect(-1280, -615, 2560, 1415)
        XCTAssertGreaterThanOrEqual(StackedWindowsManager.overlapRatio(a, b),
                                    StackedWindowsManager.overlapThreshold)
    }
}

// MARK: - Picker window key-ability (B10)
//
// Borderless NSWindows return false for canBecomeKey by default, which made
// the picker's resignKey()-based dismissal dead code: after Cmd+Tab the HUD
// stayed on screen (across all Spaces) and, via the picker-vs-picker mutual
// exclusion in MultiWindowManager, blocked the focus picker too.
final class StackedWindowsPickerWindowTests: XCTestCase {

    func test_pickerWindow_canBecomeKey() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let picker = StackedWindowsPickerWindow(activeWindow: AccessibilityElement(getpid()),
                                                candidates: [],
                                                onScreen: screen)
        XCTAssertTrue(picker.canBecomeKey)
    }

    // MARK: - Grid layout (B12)
    //
    // Card layout constants: cardWidth 140, cardSpacing 12, horizontalPadding
    // 16. One row of N cards needs 16*2 + N*140 + (N-1)*12 points, so a
    // maximized active window with 10+ overlapping candidates used to produce
    // a HUD wider than the screen with unreachable cards.

    func test_gridLayout_fitsInOneRow_whenWidthAllows() {
        // 3 cards need 16*2 + 3*140 + 2*12 = 476pt
        let grid = StackedWindowsPickerWindow.gridLayout(count: 3, maxContentWidth: 1000)
        XCTAssertEqual(grid.columns, 3)
        XCTAssertEqual(grid.rows, 1)
    }

    func test_gridLayout_wrapsIntoRows_whenWidthExceeded() {
        // maxContentWidth 800 → max columns = (800 - 32 + 12) / 152 = 5
        let grid = StackedWindowsPickerWindow.gridLayout(count: 12, maxContentWidth: 800)
        XCTAssertEqual(grid.columns, 5)
        XCTAssertEqual(grid.rows, 3)
    }

    func test_gridLayout_neverBelowOneColumn() {
        let grid = StackedWindowsPickerWindow.gridLayout(count: 4, maxContentWidth: 50)
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 4)
    }

    func test_gridLayout_zeroCount_isOneByOne() {
        let grid = StackedWindowsPickerWindow.gridLayout(count: 0, maxContentWidth: 1000)
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 1)
    }

    func test_pickerWindow_manyCandidates_staysWithinScreenWidth() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let me = AccessibilityElement(getpid())
        let picker = StackedWindowsPickerWindow(activeWindow: me,
                                                candidates: Array(repeating: me, count: 15),
                                                onScreen: screen)
        XCTAssertLessThanOrEqual(picker.frame.width, screen.visibleFrame.width)
    }
}
