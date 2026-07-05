//
//  FocusWindowGeometryTests.swift
//  RectangleTests
//

import XCTest
@testable import Rectangle

final class FocusWindowGeometryTests: XCTestCase {

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func test_noCandidates_returnsNil() {
        let current = rect(0, 0, 200, 200)
        XCTAssertNil(FocusWindowGeometry.nextWindow(from: current, direction: .left, candidates: []))
    }

    func test_singleLeftCandidate_picked() {
        let current = rect(500, 100, 200, 200)
        let candidates = [rect(100, 100, 200, 200)]
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .left, candidates: candidates), 0)
    }

    func test_left_picksNearestOfTwoLeft() {
        let current = rect(500, 100, 200, 200)
        let far  = rect(0,   100, 200, 200) // midX=100
        let near = rect(200, 100, 200, 200) // midX=300
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .left, candidates: [far, near]), 1)
    }

    func test_left_quadrantGate_rejectsVerticallyDominantCandidate() {
        // 후보가 좌측에 있긴 하나 |dy| > |dx| 라 ← 사분면에서 탈락 (수직 성분 우세)
        let current = rect(500, 100, 100, 100) // midX=550, midY=150
        let belowRight = rect(540, 800, 100, 100) // midX=590 → dx=+40, midY=850 → dy=+700 (우측+아래)
        let mostlyBelow = rect(400, 1000, 100, 100) // midX=450, midY=1050 → dx=-100, dy=+900 → |dy|>|dx| → ← 후보 탈락
        XCTAssertNil(FocusWindowGeometry.nextWindow(from: current, direction: .left, candidates: [belowRight, mostlyBelow]))
    }

    func test_left_noLeftNeighbor_returnsNil() {
        let current = rect(100, 100, 200, 200)
        let right = rect(500, 100, 200, 200)
        XCTAssertNil(FocusWindowGeometry.nextWindow(from: current, direction: .left, candidates: [right]))
    }

    func test_right_symmetricToLeft() {
        let current = rect(100, 100, 200, 200)
        let right = rect(500, 100, 200, 200)
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .right, candidates: [right]), 0)
    }

    func test_up_picksUpperCandidate() {
        // CGWindowList/AX 좌표계 (top-origin): y 증가 = 아래.
        // 화면에서 위에 있는 창일수록 midY 가 작다.
        let current = rect(100, 500, 200, 200) // midY=600
        let upper = rect(100, 100, 200, 200)   // midY=200 → dy=-400 (시각적으로 위)
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .up, candidates: [upper]), 0)
        // 반대 방향으로는 선택되면 안 된다 (반전 회귀 방지).
        XCTAssertNil(FocusWindowGeometry.nextWindow(from: current, direction: .down, candidates: [upper]))
    }

    func test_down_picksLowerCandidate() {
        let current = rect(100, 100, 200, 200) // midY=200
        let lower = rect(100, 500, 200, 200)   // midY=600 → dy=+400 (시각적으로 아래)
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .down, candidates: [lower]), 0)
        XCTAssertNil(FocusWindowGeometry.nextWindow(from: current, direction: .up, candidates: [lower]))
    }

    func test_crossDisplay_leftPicksNeighborOnOtherDisplay() {
        // 모니터 경계 무시: 활성 창은 D2 (오른쪽 모니터) 에 있고, 후보는 D1 (왼쪽 모니터) 에 있음
        let current = rect(2000, 200, 400, 400) // midX=2200
        let leftDisplayWindow = rect(200, 200, 400, 400) // midX=400
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .left, candidates: [leftDisplayWindow]), 0)
    }

    func test_tieBreak_picksUpperWhenDistanceEqual() {
        // 좌상과 좌하가 완전 대칭 → 위쪽 (top-origin 에서 midY 작은 것) 우선
        let current = rect(500, 500, 200, 200) // midX=600, midY=600
        let upperLeft = rect(0, 200, 200, 200) // midX=100, midY=300  → dx=-500, dy=-300 (위)
        let lowerLeft = rect(0, 800, 200, 200) // midX=100, midY=900  → dx=-500, dy=+300 (아래)
        // 거리 동일 (sqrt(500²+300²))
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .left, candidates: [lowerLeft, upperLeft]), 1)
    }

    func test_tieBreak_picksLeftmostWhenAllElseTied() {
        // 거리, midY 모두 같지만 midX 다른 두 후보 → midX 작은 것 (왼쪽 우선)
        // 이 시나리오는 실제로 ↑ 방향에서 좌우 대칭일 때
        let current = rect(500, 500, 200, 200) // midX=600, midY=600
        let upRight = rect(800, 0, 200, 200) // midX=900, midY=100 → dx=+300, dy=-500
        let upLeft  = rect(200, 0, 200, 200) // midX=300, midY=100 → dx=-300, dy=-500
        // 둘 다 ↑ 사분면 (|dy|=500 > |dx|=300), 거리 동일 sqrt(300²+500²)
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .up, candidates: [upRight, upLeft]), 1)
    }

    func test_diagonalDominance_belongsToDominantAxis() {
        // 좌측이면서 약간 아래인 후보 (|dx| > |dy|): ← 후보 ✓, ↓ 후보 ✗
        let current = rect(500, 500, 100, 100) // midX=550, midY=550
        let leftish = rect(0, 600, 100, 100)   // midX=50,  midY=650 → dx=-500, dy=+100 → |dx|>|dy|
        XCTAssertEqual(FocusWindowGeometry.nextWindow(from: current, direction: .left, candidates: [leftish]), 0)
        XCTAssertNil(FocusWindowGeometry.nextWindow(from: current, direction: .down, candidates: [leftish]))
    }
}
