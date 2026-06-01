# Focus Picker 엣지 케이스 재현 가이드

머지 완료된 fix (B3, B5, B6, B7, B8) 들의 코드 분석에서 파생된 잠재적
엣지 케이스 시나리오. 각 항목은 *어떻게 재현할 수 있는지* 와 그때
나타날 증상을 정리한다.

상태: 모두 *코드 분석 기반 가설*. 실제 재현 여부는 미검증.

---

## EC1. [높음] picker 호출 시점에 Rectangle 자신이 frontmost → previousApp 이 nil → B8/cancel 경로에서 회귀

### 원인 코드

- `FocusWindowManager.reveal()` L226-230:
  ```swift
  let previousApp: NSRunningApplication? = {
      guard let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != getpid() else { return nil }
      return app
  }()
  ```
  Rectangle 자신이 frontmost 면 `previousApp = nil` 로 캡처.

- `Session.confirm()` L462 / `Session.cancel()` L475:
  ```swift
  previousApp?.activate(options: .activateIgnoringOtherApps)
  ```
  옵셔널 체인 — `nil` 이면 no-op. Rectangle 이 frontmost 인 채로 유지됨.

- 다음 `reveal()` 호출 시 L233:
  ```swift
  guard let active = AccessibilityElement.getFrontWindowElement(), ...
  ```
  Rectangle 자신 (창 없음) 이 frontmost → nil 반환 → bailout. **B3 와
  같은 패턴**.

### 재현 절차

1. Rectangle 의 환경설정 / 설정 / 로그 창 열기 (메뉴바 → Open
   Preferences). Rectangle 이 frontmost 가 됨.
2. picker 단축키 호출.
   - **EC1a (cancel 경로)**: Esc 로 취소 → 다음 picker 호출이 안 됨.
   - **EC1b (B8 경로)**: candidate 선택 → 확정 직전 minimize → Enter
     (beep) → 다음 picker 호출이 안 됨.
3. 다른 앱 창 클릭 등 *수동* frontmost 변경 후에야 picker 복구.

### 기대 증상

- 2번 직후의 *두 번째* picker 호출에서 아무 반응 없음 (beep 만).
- Console.app: `FocusWindow: no front window` 로그.

### 수정 방향 (참고)

`previousApp?.activate` 가 `nil` 이거나 실패하면 fallback 으로 *임의의
regular activationPolicy 앱* 하나를 activate. 예:

```swift
let restored = previousApp?.activate(options: .activateIgnoringOtherApps) ?? false
if !restored {
    NSWorkspace.shared.runningApplications
        .first { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }?
        .activate(options: .activateIgnoringOtherApps)
}
```

---

## EC2. [중간] visibility 임계 0.30 false negative — 70%+ 가려진 정상 창이 candidate 누락

### 원인 코드

- `FocusWindowManager.swift` L21: `minVisibleRatio: CGFloat = 0.30`
- `FocusWindowVisibility.visibleIndices`: visible 영역 비율이 0.30 미만인
  창은 candidate 에서 제외.

### 재현 절차

1. 모니터 어느 영역에 큰 모달 / 다이얼로그 창 띄우기 (예: 시스템 설정
   다이얼로그 풀스크린).
2. 그 다이얼로그 *뒤에* 작업 창을 일부만 노출시킴 (다이얼로그가 70%+
   를 덮도록).
3. picker 호출.
4. 작업 창이 candidate 에 *안 보임* — 화살표 이동으로 도달 불가.

### 기대 증상

- picker candidate 가 다이얼로그만 잡고, 그 뒤 작업 창은 picker 에서
  접근 불가.
- 사용자는 *분명 화면에 보이는데* picker 가 무시함.

### Trade-off

B6 원래 false positive (Brave 뒤 FortiClient 7% 노출) 차단을 위해
임계를 올림. 0.30 → 0.20 으로 낮추면 EC2 완화되지만 B6 회귀 위험.

### 수정 방향 (참고)

- 옵션 A: 0.30 → 0.20 으로 완화.
- 옵션 B: visible 영역의 *연속된 큰 사각형 비율* 로 변경 (가장자리에
  흩어진 픽셀은 무시). 알고리즘 변경 범위 ↑.

---

## EC3. [중간] Sidecar / 가상 디스플레이의 active Space 매핑 실패

### 원인 코드

- `SkyLightPrivate.currentSpaceIds()` L120-138:
  ```swift
  guard let nsNum = screen.deviceDescription[key] as? NSNumber else { continue }
  let displayID = CGDirectDisplayID(nsNum.uint32Value)
  guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { continue }
  ```
  - `NSScreenNumber` 가 nil 이면 skip.
  - `CGDisplayCreateUUIDFromDisplayID` 가 nil 이면 skip.

- 결과적으로 *그 디스플레이의 active Space ID 가 activeSpaces set 에서
  빠짐* → 그 디스플레이에 있는 wid 가 `filterToCurrentSpace` 에서 drop.

### 재현 절차

1. iPad 를 Sidecar 로 연결, 또는 외부 가상 디스플레이 어댑터 사용.
2. Sidecar 화면에 어떤 창을 띄움.
3. Mac 본체 화면에서 picker 호출.
4. Sidecar 의 그 창이 candidate 에 *없음*.

### 기대 증상

- Sidecar 또는 가상 디스플레이의 창이 picker 에 안 잡힘.
- 로그: `[FW] reveal: space-filter kept X of Y` — X < Y 가 평소보다
  많이 차이남.

### 확인 방법

`CGDisplayCreateUUIDFromDisplayID` 반환값을 진단 NSLog 로 찍어 nil
여부 확인. nil 이면 그 디스플레이가 매핑 실패.

---

## EC4. [낮음] SLPS partial success — setFront 성공, postEvent 실패 시 wrong main window

### 원인 코드

- `SkyLightPrivate.focusWindowLikeClick()` L75-108:
  ```swift
  let status1 = setFront(&psn, windowId, kCPSUserGenerated)
  if status1 != noErr { return false }
  // ...
  _ = bytes.withUnsafeMutableBufferPointer { buf in
      postEvent(&psn, buf.baseAddress!)  // OSStatus 무시
  }
  ```
  `postEvent` 의 OSStatus 를 검사하지 않음.

### 재현 절차

이 경로는 macOS private API 의 내부 상태에 의존하므로 *의도적 재현이
어렵다*. 다음 환경에서 발생 가능성 ↑:

1. macOS Sequoia 의 권한 변경 / 보안 강화 패치 직후.
2. 시스템 부하가 매우 높을 때 (SkyLight 큐 backlog).
3. Chromium 앱이 매우 많은 창을 가질 때 (창 수 ~50개+).

### 기대 증상

- picker 가 Brave wid_X 를 골랐는데 *다른 Brave 창* 이 활성화됨
  (B2 / B5 본래 증상 재현).
- 로그상 `confirm: chosen wid=X` 이지만 post-raise 에서 다른 wid 가
  frontmost.

### 수정 방향 (참고)

`postEvent` 결과를 검사해 실패 시 `NSRunningApplication.activate`
fallback. 단, partial success 의 OSStatus 가 noErr 이면 검사 효과 없음.

---

## EC5. [낮음] B7 quadrant 0.5 — 같은 midpoint 두 candidate 도달 불가

### 원인 코드

- `FocusWindowGeometry.nextWindow()` L48-51:
  ```swift
  case .right: inQuadrant = dx > 0 && adx >= ady * axisRatio
  ```
  `dx > 0` 가 strict 부등호라 `dx == 0` 인 candidate 는 어느 방향에서도
  탈락. dx=dy=0 (정확히 같은 midpoint) 도 마찬가지.

### 재현 절차

1. 같은 frame 의 두 창을 stack (Brave 두 창을 정확히 같은 위치에
   배치). 이는 B2 시나리오와 유사.
2. picker 호출, cursor 가 둘 중 한 창에 있을 때 다른 창으로 이동
   시도.
3. 어느 방향키도 다른 창에 도달 못 함.

### 기대 증상

- 화살표 키 어느 방향으로도 같은 midpoint 의 다른 wid 에 못 감.
- B2 의 일부 영역.

### 비고

별개 이슈 (B2 영역). B7 fix 의 책임 아님.

---

## EC6. [낮음] B8 isMinimized 검사가 *raise-only* 시나리오를 막을 수 있음

### 원인 코드

- `raiseAndActivate()` L380-383:
  ```swift
  if resolvedTarget?.isMinimized == true {
      NSSound.beep()
      return false
  }
  ```
  *어떤 이유에서든* AX 가 isMinimized = true 면 무조건 beep.

### 재현 절차

1. *Stage Manager* 활성화. Stage Manager 는 일부 창을 AX 관점에서
   minimize 와 유사한 상태로 둘 수 있다.
2. picker 호출 → Stage 의 *side card* 창을 cursor 로 지목.
3. Enter → beep, 아무 동작 안 함.

### 기대 증상

- Stage Manager / Mission Control 환경에서 일부 정상 창이 minimize 로
  잘못 분류되어 picker confirm 이 실패.

### 비고

검증 안 됨. Stage Manager 가 AX `kAXMinimizedAttribute` 를 어떻게
보고하는지에 따라 다름.

---

## EC7. [낮음] WindowUtil 100ms 캐시로 인한 stale candidate

### 원인 코드

- `WindowUtil.swift` L11: `windowListCache = TimeoutCache<...>(timeout: 100)` — 100ms.

### 재현 절차 (이론)

1. 키보드 매크로 / 자동화 도구로 picker 호출 → 어떤 동작 → picker
   재호출을 *100ms 이내* 에 연속 수행.
2. 두 번째 호출의 candidate 가 첫 번째 호출 시점 스냅샷과 동일.

### 느린 PC / 고부하 시나리오 (현실적 트리거 경로)

사람 입력 속도 자체는 100ms 안에 두 번 못 누르지만, **시스템이 느려져
있을 때** 다른 경로로 트리거 가능:

- `AccessibilityElement.getFrontWindowElement()` (AX 호출) 가 부하 중
  수~수십 ms 지연.
- 그 사이 사용자가 창을 minimize / 닫기.
- macOS AX state lag 가 *동시에* 발생 → 그 wid 를 여전히 active 로 보고.
- 직후 `WindowUtil.getWindowList()` 호출 — 부하로 *직전 호출과 같은
  caller 가 100ms 안에 다시 들어와* 캐시 데이터 반환.

확인된 사용자 환경 (M2 / 16GB / load average 6.38/8 코어 ~ 80% 부하)
에선 이 경로가 비현실이 아니다. B8 디버깅 중 "마지막에만 재현되었다"
케이스 일부가 이 패턴이었을 가능성 — 다만 명확히 EC7 으로 단정된
재현은 없음.

### 기대 증상

- 빠른 연속 호출 시 *변화한 창 상태가 반영 안 됨*.
- 화면에 안 보이는 창에 picker highlight 가 그려지거나, 확정 시 dock
  의 minimize 창이 다시 꺼내질 수 있음 (B8 와 증상 겹침).

### 수정 방향 (보류, 향후 명확한 보고 시 적용)

**옵션 C — 캐시 명시 invalidate (권장)**

`WindowUtil` 에 `invalidateCache()` public 메서드를 추가하고
`FocusWindowManager.reveal()` / `StackedWindowsManager.reveal()` 진입
시 호출:

```swift
// WindowUtil.swift
static func invalidateCache() {
    windowListCache[nil] = nil
}

// FocusWindowManager.swift, reveal() 진입부
WindowUtil.invalidateCache()
let rawInfos = WindowUtil.getWindowList()...
```

- **장점**: 사용자 체감 지연 0ms. picker 호출마다 fresh CGWindowList.
  다른 caller (`AccessibilityElement`, `StageUtil`) 의 캐시 효과는
  유지.
- **위험**: 매우 낮음. picker 진입은 사용자 단축키 단발 호출이라
  부하 영향 미미.

대안 — **옵션 A** (reveal 시 100ms wait):
- DispatchQueue.main.asyncAfter 로 비동기화 필요 (메인 스레드 블로킹
  금지). 코드 흐름이 두 단계로 쪼개짐.
- 사용자 체감 100ms (Jakob Nielsen 기준 "즉각 반응" 의 상한선) —
  허용 가능하지만 옵션 C 가 더 깔끔.

### 상태

**보류**. 현재 명확한 사용자 보고 없음. B3/B5/B6/B7/B8 fix 들이 같은
증상 영역을 이미 커버하므로 EC7 이 단독으로 트리거되는 케이스가 와야
재검토.

---

## 요약

| # | 우선순위 | 핵심 조건 | 영향 |
|---|---|---|---|
| EC1 | 높음 | Rectangle 자신이 frontmost 일 때 picker 호출 → cancel/B8 bail | picker 사용 불가 |
| EC2 | 중간 | 70%+ 가린 다이얼로그 뒤 작업 창 | 그 창 도달 불가 |
| EC3 | 중간 | Sidecar / 가상 디스플레이 사용 | 그 화면 창 누락 |
| EC4 | 낮음 | SLPS postEvent 부분 실패 | 잘못된 main window 활성화 |
| EC5 | 낮음 | 같은 midpoint 두 candidate | 화살표로 못 감 (B2 영역) |
| EC6 | 낮음 | Stage Manager 환경에서 isMinimized 오보고 | Enter 무반응 |
| EC7 | 낮음 | 100ms 이내 연속 자동화 호출 | stale candidate |

EC1 만 *일반 사용자가 자연스럽게 만들 수 있는* 시나리오. 우선순위 높음.
나머지는 특수 환경 / 미발생 가능성.
