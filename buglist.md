# Bug List

발견된 버그를 기록한다. 각 항목은 재현 조건, 관찰된 동작, 기대 동작, 상태를 포함.

---

## [x] B1. Focus Window Picker 동작 중 Reveal Stacked Windows를 실행하면 파란 테두리만 남는다

- **재현 조건**: Focus Window Picker가 활성화된 상태(파란 하이라이트 표시 중)에서
  Reveal Stacked Windows 액션을 호출.
- **관찰된 동작**: Focus Window Picker의 파란 테두리(`WindowHighlightWindow`)가
  화면에 남은 채로 키 입력/클릭 모니터가 정리되지 않은 듯한 상태가 된다.
  Stacked Windows picker가 정상적으로 떴는지 / 그 위에 겹쳐 떴는지도
  확인 필요.
- **기대 동작**: 둘 중 하나로 깔끔하게 정리되어야 함:
  (a) Reveal Stacked Windows 호출 시 진행 중인 Focus Window Picker가
      자동으로 cancel 되고 Stacked Windows picker만 뜬다, 또는
  (b) Focus Window Picker가 떠 있는 동안에는 Reveal Stacked Windows가
      차단되고 beep만 난다.
- **원인 추정**:
  - `FocusWindowManager.Session` 의 cleanup 경로 — `cancel()` / `confirm()` 만
    `removeKeyMonitor()` + `highlight.dismiss()` 를 호출함. 외부에서 다른
    multi-window 액션이 호출되면 이 cleanup 이 안 도는 듯.
  - `MultiWindowManager` 에서 `revealStackedWindows` / `focusWindowPicker`
    액션 간 상호 배타 처리 없음.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowManager.swift`
  - `Rectangle/MultiWindow/WindowHighlightWindow.swift`
  - `Rectangle/MultiWindow/StackedWindowsManager.swift`
  - `Rectangle/MultiWindow/MultiWindowManager.swift`
- **해결 방식**: 기대 동작 (b) 채택 — `MultiWindowManager.handleMultiWindow`에서
  두 picker 간 상호 배타 처리 추가. 다른 picker 활성 시 `NSSound.beep()` + 로그
  후 무시. `FocusWindowManager.isActive` / `StackedWindowsManager.isActive`
  정적 프로퍼티 신설.
- **상태**: 해결 완료 (Debug 빌드 수동 재현 검증 통과)
- **우선순위**: 미정

---

## [x] B2. Focus Window Picker로 맨 우측 Brave 창을 선택했는데 제일 좌측 Brave 창이 picker(활성)된다

- **재현 조건**: 같은 앱(Brave Browser)의 창이 여러 개 떠 있는 상태에서
  Focus Window Picker로 **맨 우측의 Brave 창**을 시각적으로 지목/확정.
- **관찰된 동작**: 확정 후 활성화되는 건 **제일 좌측의 다른 Brave 창**.
  즉 picker가 가리킨 wid 와 실제로 raise/activate 되는 wid 가 일치하지 않음.
- **기대 동작**: picker가 가리킨 그 wid 의 창이 그대로 raise/activate 되어야 함.
- **원인 추정**:
  - `FocusWindowManager.raiseAndActivate(_:)` 에서 `runningApp.activate(...)`
    호출 후 macOS 가 같은 앱의 "last-known-main" 창을 다시 promote 하는 패턴
    (Chromium/Electron 의 알려진 동작). 이미 `AXRaise` + `setMain(true)` 로
    방어했지만 같은 앱 내 여러 창이 있고 그중 우측 창의 AX 매칭이 다른
    창으로 잘못 잡히는 경우가 있을 수 있음.
  - `confirm()` 시 `chosen.id` (CGWindowID) 와 AX windowElements 의 매칭
    경로(`directApp(info.pid)` → `first(where: $0.windowId == info.id)`)에서
    Brave 의 wid 가 노출이 일관되지 않은 케이스에 fallback (frame 매칭) 으로
    엉뚱한 동일 frame 창이 잡힐 가능성. 동일 frame 의 다른 Brave 창이 있으면
    좌표 기반 fallback 이 좌측 창을 선택할 수 있음.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowManager.swift`
    (특히 `raiseAndActivate` 와 `confirm`)
- **확인 필요**: picker 확정 시점의 `[FW] confirm: chosen wid=...` 와
  실제로 활성화된 창의 wid 가 일치하는지 로그로 검증. 일치하지만 보이는 결과가
  다르면 macOS 의 activate 후 promote 문제, 일치 안 하면 매칭 로직 문제.
- **상태**: 해결됨 — B5 fix (SLPS single-window activation) 의 부수
  효과로 자연 해결. B2 의 원인 추정 핵심이었던 *`NSRunningApplication
  .activate(...)` 후 macOS 의 last-known-main 재promote 패턴* 이 B5 fix
  로 차단됨. `_SLPSSetFrontProcessWithOptions(psn, wid, kCPSUserGenerated)`
  가 *특정 wid 를* frontmost 로 직접 지정하므로 같은 앱 내 다른 창이
  promote 될 여지가 없다. 별도 코드 변경 없이 B2 시나리오가 더 이상
  재현되지 않음을 사용자가 직접 확인. 가능한 잔여 케이스 (예: frame
  fallback 분기, 같은 frame 의 두 wid 구분) 는 docs/focus-picker/
  EdgeCases.md EC5 에 별도 기록되어 있음.
- **우선순위**: 미정

---

## [x] B3. Focus Window Picker를 Esc로 취소한 뒤 다시 호출하면 picker가 동작하지 않는다

- **재현 조건**:
  1. Focus Window Picker 단축키로 picker 호출 (파란 하이라이트 표시)
  2. Esc 키로 취소
  3. 다시 Focus Window Picker 단축키 호출
- **관찰된 동작**: 두 번째 호출에서 picker 가 뜨지 않음.
- **기대 동작**: 매번 호출할 때마다 정상적으로 picker 가 떠야 함.
- **원인 추정**:
  - 코드 검사 결과 `Session.cancel()` 은 `removeKeyMonitor()` +
    `highlight.dismiss()` + `FocusWindowManager.sessionEnded()` 를 모두
    호출함. 즉 `activeSession` 가드 누락은 아님.
  - **가설 A (유력)**: `reveal()` 첫 호출에서 `NSApp.activate(...)` 로
    Rectangle 앱을 frontmost 로 만든다. cancel 후에도 Rectangle 이 여전히
    frontmost 일 가능성이 있고, 그 상태에서 두 번째 reveal 호출 시
    `AccessibilityElement.getFrontWindowElement()` 가 Rectangle 자신의
    창(예: 환경설정/로그뷰어)을 반환하거나 nil 을 반환해서 곧장 bailout.
  - **가설 B**: `highlight.onResignKey` 콜백과 keyMonitor 의 Esc 가
    이중 발화되어 cancel() 이 두 번 호출. 두 번째 cancel 시점에는
    `dismissing == true` 라 early-return 되지만, 그 사이 새 reveal 호출이
    끼어들면 race 발생. NSEvent.removeMonitor 가 비동기일 수 있음.
  - **가설 C**: cancel 후 `NSApp` 활성화가 풀린 직후의 짧은 윈도에 keyMonitor
    이벤트가 한 번 더 dispatched 되면서 새 session 의 monitor 까지 영향.
- **검증 방법**:
  - 두 번째 reveal 호출 시점에 `[FW] reveal: active wid=...` 로그가 찍히는지
    확인. 안 찍히면 `getFrontWindowElement()` 에서 bailout (가설 A).
  - 찍히면 어떤 active window 가 잡혔는지 확인 — Rectangle 자신이면 A 확정.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowManager.swift`
    (특히 `reveal()` 시작점, `Session.cancel()`)
- **상태**: 해결됨 — 가설 A 확정. `[FW] cancel: post-cancel frontmost
  app pid=… name=Rectangle` 로 cancel 후 Rectangle 자신이 frontmost 로
  남는 것이 로그로 검증되었고, 다음 reveal() 이 `getFrontWindowElement()
  == nil` 분기에서 bailout 되었다. `reveal()` 진입 시 직전 frontmost 앱을
  캡처하고 `cancel()` 에서 그 앱을 다시 activate 하도록 수정.
- **우선순위**: 미정

---

## [x] B4. Reveal Stacked Windows로 IntelliJ를 선택하면, 가려진 그 창이 아니라 다른 디스플레이의 IntelliJ가 활성화된다

- **재현 조건**:
  1. 디스플레이 A 에 IntelliJ 창 W_A 가 떠 있다 (현재 화면에 보이는 창의
     뒤쪽에 가려져 있다고 가정).
  2. 다른 디스플레이 B 에도 같은 IntelliJ 앱의 다른 창 W_B 가 떠 있다
     (직전에 main 으로 활성화돼 있던 창).
  3. 사용자가 Reveal Stacked Windows 액션으로 W_A 를 골라 확정.
- **관찰된 동작**: 사용자가 지목한 W_A 가 아니라 **다른 디스플레이의 W_B** 가
  화면에 떠오른다.
- **기대 동작**: picker 가 가리킨 정확히 그 창(W_A) 이 raise 되어 활성화된다.
- **원인 (코드 검사로 확인됨)**:
  - selection 핸들러: `StackedWindowsManager.swift:80-84`
    ```swift
    picker.onSelection = { selected in
        selected.bringToFront(force: true)
    }
    ```
  - `AccessibilityElement.bringToFront(force:)` (`AccessibilityElement.swift:294-301`):
    1. `isMainWindow = true`  ← `AXMain` setter, 단순 attribute write
    2. `NSRunningApplication.activate(...)` ← 앱 전체 activate
  - **`AXRaise` 액션을 호출하지 않음.** 같은 앱 안에 여러 창이 있을 때
    `app.activate(...)` 시점에 macOS 가 그 앱의 "last-known-main" 창을
    다시 promote 하는 동작이 있고, `isMainWindow = true` setter 만으론
    이 동작에 밀린다. picker 가 가리킨 W_A 가 last-known-main 이 아니라면
    activate 직후 W_B 가 다시 main 으로 promote 되어 화면에 떠오름.
- **대조 — Focus Window Picker 는 이 문제를 이미 해결했음**:
  - `FocusWindowManager.raiseAndActivate(_:)` 는 명시적 순서:
    1. `runningApp.activate(...)`
    2. `target.raise()`  (= `AXUIElementPerformAction(.., kAXRaiseAction)`)
    3. `target.setMain(true)`
  - 주석(`FocusWindowManager.swift:163-168`)에 Chromium/Electron 의 last-known-main
    재promote 패턴이 명시되어 있고, 그래서 activate → AXRaise 순서로 푼다고
    설명됨. IntelliJ(JetBrains) 도 같은 앱 내 다중 창 관리에서 유사한 패턴을
    보임.
- **수정 방향 (선택지)**:
  - **A. selection 핸들러를 `raiseAndActivate` 패턴으로 변경** —
    `StackedWindowsManager` 의 onSelection 에서 `bringToFront` 대신 명시적
    activate → raise → setMain 순서로 호출. 가장 표적 fix.
  - **B. `AccessibilityElement.bringToFront` 자체를 보강** — `AXRaise` 추가.
    호출자 전부가 혜택받지만 회귀 위험 검토 필요.
  - **C. 공통 유틸 추출** — `FocusWindowManager.raiseAndActivate` 와 새 코드를
    하나의 함수로 통합. 가장 깔끔하지만 리팩터링 범위가 큼. 권장.
- **관련 파일**:
  - `Rectangle/MultiWindow/StackedWindowsManager.swift` (onSelection)
  - `Rectangle/AccessibilityElement.swift` (`bringToFront`)
  - `Rectangle/MultiWindow/FocusWindowManager.swift` (`raiseAndActivate` 참고)
- **상태**: 해결됨 — 수정 방향 A 채택. `StackedWindowsManager.onSelection`
  의 `bringToFront(force: true)` 호출을 `FocusWindowManager.raiseAndActivate
  (WindowInfo)` 로 교체. `raiseAndActivate` 의 가시성은 `fileprivate` →
  `internal` 로 격상. Reveal Stacked Windows 가 picker 와 동일한 활성화
  시퀀스 (SLPS + AXRaise + setMain + B8 minimize 가드) 를 자동 상속한다.
  검증: Brave A (picker) → Claude (picker) → Brave B (Reveal) → Cmd+W
  시나리오에서 Brave B 에 탭이 정상적으로 작동 (fix 이전엔 Brave A 에 탭
  생성). wid 또는 pid 가 없는 AX element 의 경우 기존 `bringToFront`
  fallback 유지.
- **우선순위**: 미정

---

## [x] B5. Focus Window Picker로 한 디스플레이의 Chromium 창을 선택하면 다른 디스플레이의 같은 앱 창도 같이 맨 앞으로 올라온다

- **재현 조건**:
  1. 모니터 A, B, C 좌→우 나열.
  2. 모니터 A 에 Brave(또는 Chrome / Slack / VS Code 등 Chromium 계열) 창
     `W_A` 가 있고, 그 위를 *다른 앱*(예: 시스템 설정 창)이 덮고 있어
     `W_A` 가 z-order 상 가려진 상태.
  3. 모니터 C 에 같은 앱의 다른 창 `W_C` 가 보이고 있음.
  4. Focus Window Picker 로 `W_C` 를 지목/확정.
- **관찰된 동작**: `W_C` 가 활성화되는 건 맞다. 그런데 같은 시점에 모니터 A
  에서도 `W_A` 가 z-order 위로 올라와, 원래 `W_A` 를 덮고 있던 다른 앱의
  창이 가려진다. 즉 picker 가 지목한 wid 하나만 raise 한 게 아니라 같은
  앱의 *다른* 창까지 같이 raise 됨.
- **기대 동작**: 모니터 A 의 z-order 는 picker 이전과 동일하게 유지되어야
  한다 (W_A 는 원래대로 다른 앱 창 뒤에 남아 있어야 함). picker 가 지목한
  `W_C` 만 활성화된다.
- **원인 추정**:
  - `FocusWindowManager.raiseAndActivate(_:)` 의 시퀀스 중
    `NSRunningApplication.activate(options: .activateIgnoringOtherApps)`
    호출은 macOS 표준 동작상 **해당 앱의 모든 창을 다른 앱 창들 위로**
    올린다. 그래서 W_A 가 (다른 앱이 덮고 있던 자리에서) 같이 위로 떠오름.
  - 그 뒤의 `target.raise()` 는 같은 앱 내 z-order 만 정리하므로 다른
    디스플레이에 있는 W_A 까지 원래 자리로 되돌리지 않는다.
  - 이 동작은 Chromium / Electron / JetBrains 처럼 *앱 = 멀티창 묶음* 으로
    취급하는 앱 모델과 macOS activate 의 "앱 단위 promote" 의미가 결합되어
    나타나는 구조적 문제. B2 (잘못된 창 활성화)와 다르고, B4 (가려진 같은 앱
    창이 *대신* 활성화)와도 다른 별개 케이스다.
- **확인 필요**: picker 확정 직전 / 직후의 z-order 변화를 로그로 검증.
  `[FW] confirm: chosen wid=...` 와 raise 전·후 모든 Brave 창의 z-index
  (CGWindowList 의 front-to-back 순서) 변화 비교.
- **수정 방향 (선택지)**:
  - **A. activate 를 회피하고 AX 만으로 raise** — `runningApp.activate(...)`
    를 호출하지 않고 `target.raise()` + `target.setMain(true)` + 키 윈도우
    설정만 시도. 단, Chromium 은 activate 없이는 frontmost 가 안 바뀔 수
    있어 회귀 위험 큼.
  - **B. activate 후 같은 앱의 다른 창을 원래 z-order 로 되돌리기** —
    confirm 직전 동일 PID 의 다른 창 wid 와 그 z-index 를 캡처해 두고,
    activate/raise 후 그 창들을 원래 위에 있던 다른 앱 창 아래로 다시
    내려보낸다. AX 에는 "send to back" 이 표준으로 없으므로 우회 필요
    (예: 가렸던 앱을 잠깐 raise 해서 z-order 회복).
  - **C. macOS 한계 인정 — 동작 문서화** — Chromium 앱의 멀티창은 macOS
    상에서 단일 창 단위로 분리 raise 가 불가능하다고 보고 수용. 비권장.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowManager.swift` (`raiseAndActivate`)
- **상태**: 해결됨 — Carbon-era 비공개 SkyLight 함수
  `_SLPSSetFrontProcessWithOptions` 로 *특정 wid* 를 지정해 활성화한다.
  마우스 클릭 경로가 내부적으로 호출하는 동일 API. `SLPSPostEventRecordTo`
  로 합성 key/focus 이벤트 한 쌍을 더 보내 Chromium/Electron 도 새 main
  window 로 인식하도록 한다. 비공개 심볼은 dlsym 으로 lazy 로드하므로
  미래 macOS 가 심볼을 제거하면 기존 `NSRunningApplication.activate` 경로로
  자동 fallback. 검증: Brave 두 창(모니터 A 가려진 W_A + 모니터 C 보이는 W_C)
  + System Settings 가 W_A 를 덮은 시나리오에서 W_C 확정 후 *post-raise
  z-order 가 W_A 와 System Settings 의 상대 순서를 보존*. 참고:
  [docs/focus-picker/B5-Investigation.md](docs/focus-picker/B5-Investigation.md).
- **우선순위**: 미정

---

## [x] B6. Picker 의 파란 사각형이 화면에 보이지 않는(다른 창에 가려진) 창을 가리키고 확정 시 그 창이 활성화된다

- **재현 조건**:
  1. 화면 어느 영역에 앞쪽 창 `F` (예: Claude 데스크탑 앱) 가 떠 있어 그
     아래의 다른 창 `B` (예: Brave 또는 다른 앱) 를 z-order 상 *완전히*
     또는 *대부분* 가리고 있다.
  2. Focus Window Picker 호출.
  3. 화살표로 cursor 를 그 영역 쪽으로 이동.
  4. **파란 하이라이트가 `F` 위치에 그려지는데** (사용자 눈에는 F 가
     선택된 것처럼 보임) Return 으로 확정하면 사실 picker 는 가려진 `B`
     를 골라 활성화한다.
- **관찰된 동작**: 사용자가 시각적으로 지목한 것은 화면에 보이는 `F`
  지만, picker 가 candidate 로 들고 있던 건 z-order 뒤쪽의 `B`. 결과:
  잘못된 창이 frontmost 가 됨.
- **기대 동작**:
  (a) 가려진 창은 picker candidate 에서 제외되어야 하거나,
  (b) 파란 하이라이트가 *실제 선택될 wid 의 frame* 으로 그려져야 한다
      (그러면 가려진 창을 가리킨다는 것이 사용자에게 보임). (a) 가 자연.
- **원인 추정**:
  - `FocusWindowManager.reveal()` 의 가시성 필터 (`FocusWindowVisibility
    .visibleIndices(in:minVisibleRatio:)`, 임계 0.10) 가 occlusion 을
    잘못 계산해 가려진 창을 visible 로 분류했을 가능성. 또는 `visibleSet`
    체크는 통과시키되 candidate 의 frame 자체가 가린 창의 frame 과
    동일하거나 거의 같아 시각적으로 구분 안 되는 케이스.
  - 같은 frame 의 다른 wid 가 z 상 뒤에 있는 경우 picker 는 둘 다
    candidate 로 들고 가는데, 화살표 이동 알고리즘이 z 가 뒤쪽인 wid
    를 먼저 선택하는 경향이 있을 수 있음.
  - B2 ("Brave 같은 frame 중 좌측 활성화") 와 닮은 메커니즘이지만,
    이번은 *같은 frame* 이 아니라 *다른 앱이 같은 영역을 덮은* 케이스.
- **확인 필요**:
  1. picker 호출 시점의 `[FW] candidate[i]` 로그에서 가려진 창이
     포함되어 있는지 확인 (포함됐다면 visibility 필터 누락).
  2. cursor 이동 시 `[FW] move dir=… wid=…` 가 어떤 wid 를 가리키는지
     화면에 보이는 창의 wid 와 비교.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowManager.swift` (`reveal()` 의 후보
    수집, 파란 사각형 frame 설정)
  - `Rectangle/MultiWindow/FocusWindowVisibility.swift` (occlusion 계산)
- **상태**: 해결됨 — 두 단계 수정.
  1. **Space 필터 추가**: `SkyLightPrivate.filterToCurrentSpace` 로
     active Space 에 속하지 않는 wid 를 candidate 에서 제거. 다른
     Space 의 parking 좌표 (`{{-4890, ...}}` 등) 가 NSScreen union 안에
     있어 frame intersect 만으론 못 거르던 케이스 해결.
  2. **visibility 임계 상향**: `FocusWindowManager.minVisibleRatio`
     0.10 → 0.30. 활성 창이 candidate 의 70% 이상을 덮으면 candidate
     에서 제외. 사용자 보고의 *Brave 뒤 FortiClient* 시나리오에서
     FortiClient 가 Brave 에 의해 ~93% 덮였지만 가장자리가 보여 10%
     임계를 통과하던 false positive 를 차단.
  관련 커밋: 0399aaa, 02c0798, 8fb01b3, a82ccf8
  (브랜치 `fix/focus-picker-occluded-window`, 머지 4306af9).
- **우선순위**: 미정

---

## [x] B7. 모니터 B → C 로 →/← 이동 시 C 모니터의 좌측 창을 건너뛰고 우측 창으로 점프

- **재현 조건**:
  1. 모니터 A/B/C 가 좌→우로 배열되어 있다.
  2. 모니터 B 의 어떤 창에서 picker cursor 가 있고 사용자가 `→` 키를 누른다.
  3. 모니터 C 에 두 창이 있다: 좌측 `Amaranth10` frame `{{0,25},{480,875}}`,
     우측 `Brave wid=1500` frame `{{480,25},{960,875}}`.
- **관찰된 동작**: cursor 가 모니터 C 의 *좌측* 창(Amaranth10) 을 건너뛰고
  바로 *우측* 창(Brave) 으로 점프한다. 사용자가 의도한 "다음 칸" 보다 멀리
  넘어간다. 대칭적으로 그 반대 방향(`←`)에서는 정상.
- **기대 동작**: `→` 한 번 누르면 다음 candidate (모니터 C 좌측 Amaranth10)
  로 한 칸씩 이동.
- **원인 (코드 검사로 확정)**:
  - `FocusWindowGeometry.nextWindow(direction:)` 의 quadrant gate:
    ```swift
    case .right: inQuadrant = dx > 0 && adx > ady
    ```
  - 현재 cursor 가 모니터 B 의 Chrome `{{-1050,-1415},{1280,1415}}`
    (midY=-707.5) 일 때 `→` 누르면 후보들의 (dx, dy):
    - Amaranth10: dx=650, dy=1170 → adx(650) < ady(1170) → **quadrant
      에서 떨어짐**
    - Brave wid=1500: dx=1370, dy=1170 → adx(1370) > ady(1170) → 통과
  - 모니터 B 와 C 가 *수직으로도 차이* 가 있는 배치라 Amaranth10 은 우측이
    아니라 *우상 대각선* 으로 분류된다. `adx > ady` 가 너무 엄격해
    대각선 후보를 제외, 결과적으로 더 멀리 있는 Brave 가 통과한다.
- **B6 수정 (visibility 임계 0.30) 과의 관계**: 무관. B6 수정 후 처음
  눈에 띄었지만 원인은 임계가 아니라 quadrant 알고리즘 자체.
- **수정 방향 (선택지)**:
  - **A. quadrant gate 완화** — `adx > ady` → `adx >= ady * 0.5` 등.
    수평 성분이 1/2 이상이면 우측 후보로 인정. 단순, 직관적. 임계값 튜닝
    필요.
  - **B. 두 단계 fallback** — 1차 엄격 quadrant 후보 없으면 2차 완화.
    회귀 위험 작음.
  - **C. distance 가중치 변경** — 방향 성분 비례 가중치.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowGeometry.swift`
    (`nextWindow(from:direction:candidates:)`)
- **상태**: 해결됨 — 수정 방향 A 채택. quadrant gate 를
  `adx > ady` → `adx >= ady * 0.5` 로 완화 (좌/우/상/하 대칭).
  Amaranth10 처럼 `adx < ady` 지만 *수평 성분이 수직의 절반 이상* 인
  대각선 후보가 `→` 검사에 통과해, 더 가까운 후보가 정상적으로
  선택된다. 부수 효과로 *정확히 45도* (`adx == ady`) 의 후보 — 원래
  코드에선 어느 방향으로도 도달 불가능했던 사각지대 — 도 두 인접
  방향 모두에서 통과한다. 도달성 분석: 어떤 (dx, dy) 후보든 최소 한
  방향에서 통과 보장 (수학적으로 증명, fix/focus-picker-diagonal-skip
  브랜치 커밋 메시지 참고).
- **우선순위**: 미정

---

## [x] B8. Picker 가 떠 있는 동안 candidate 창을 minimize 시키고 Enter 하면 dock 의 그 창이 un-minimize 되며 활성화된다

- **재현 조건**:
  1. 어떤 창을 dock 에서 꺼내(un-minimize) 활성 상태로 둠.
  2. Focus Window Picker 호출 — 그 창이 candidate 로 잡힘.
  3. **확정(Enter) 전에** picker 가 떠 있는 상태에서 그 창을 다시
     minimize (Cmd+M, 노란 - 버튼 등). picker 의 파란 사각형은
     캡처된 frame 그대로 화면에 남음.
  4. **Enter** 로 확정.
- **관찰된 동작**: picker 가 가리키던 (지금은 minimize 되어 화면에 없는)
  창이 dock 에서 *un-minimize* 되며 frontmost 로 올라온다. 사용자
  입장에선 "안 보이는 / 빈 자리의 사각형을 골랐는데 minimize 된 창이
  꺼내졌다" 로 느낌.
- **기대 동작**: picker 확정 시점에 chosen 창이 더 이상 visible 이
  아니면 (minimize 또는 hidden) 동작하지 말고 beep 후 종료하거나,
  candidate 리스트에서 그 wid 를 제외하고 다음 후보로 이동.
- **원인 (코드 검사로 확정)**:
  - `FocusWindowManager.reveal()` 가 candidate 리스트를 *호출 시점*
    스냅샷으로 잡고 picker session 동안 갱신하지 않는다. session 도중
    창이 minimize 되어도 picker 의 highlight frame 과 chosen wid 는
    그대로 유지.
  - `Session.confirm()` → `raiseAndActivate(chosen)` 는
    `_SLPSSetFrontProcessWithOptions` + `AXRaise` + `setMain(true)` 를
    실행. macOS 의 표준 동작상 이 조합은 *minimize 된 창도
    un-minimize* 시키고 frontmost 로 올린다. dock 의 미니어처를
    클릭한 것과 같은 효과.
  - 검증된 로그상 minimize 된 *이후* picker 재호출 시에는 candidate
    에서 정상적으로 빠짐 (B8 아님). 문제는 picker 가 *이미 떠 있는
    상태에서* minimize 가 일어난 경우뿐.
- **수정 방향 (선택지)**:
  - **A. confirm 시점에 chosen.isMinimized 검사** —
    `AccessibilityElement.isMinimized == true` 면 beep + 종료, 또는
    다음 candidate 로 이동. 가장 단순.
  - **B. session 도중 candidate 변경 감지 + UI 동기화** — AX
    notification (kAXWindowMiniaturizedNotification) 구독해 picker
    candidate 에서 즉시 제거 + highlight 재계산. 복잡, race 위험.
  - **C. 현재 동작 수용 + 설명** — "minimize 된 candidate 를 확정하면
    꺼낸다" 가 의도된 동작이라고 문서화. 비권장.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowManager.swift`
    (`Session.confirm()`, `raiseAndActivate(_:)`)
  - `Rectangle/AccessibilityElement.swift` (`isMinimized`)
- **상태**: 해결됨 — 3단 fix.
  1. `raiseAndActivate` 가 `resolvedTarget.isMinimized == true` 면 beep
     후 `false` 반환. activate/raise sequence 건너뜀.
  2. `Session.confirm` 이 `false` 받으면 `previousApp.activate(...)` 로
     pre-picker frontmost 복원 (cancel 과 동일). 안 그러면 Rectangle 이
     frontmost 로 남아 다음 reveal 이 B3 와 같은 패턴으로 죽음.
  3. `reveal()` 의 synthetic-active fallback 가드: minimize 직후엔 AX
     `getFrontWindowElement()` 가 stale 한 minimize 창을 잠시 반환하고
     그 wid 는 이미 CGWindowList 에 없어 `activeIndex == -1`. 이때
     synthetic 을 만들면 stale frame 으로 picker 가 빈 영역을 가리킴.
     대신 `candidateInfos[0]` (front-most 정상 창) 을 cursor 시작
     위치로 사용. candidateInfos 가 비어있을 때만 bail.
- **우선순위**: 미정

---

## [x] B9. Focus Window Picker 의 ↑/↓ 이동이 상하 반전되어 있다

- **재현 조건**: 활성 창 위/아래에 다른 창이 있는 상태에서 picker 를 열고
  ↑ 또는 ↓ 를 누른다.
- **관찰된 동작**: ↑ 를 누르면 시각적으로 *아래* 창이 선택되고, ↓ 를
  누르면 *위* 창이 선택된다. 해당 방향에 창이 하나뿐이면 반대 키에서만
  이동하고 기대한 키에서는 무반응.
- **기대 동작**: ↑ = 위 창, ↓ = 아래 창.
- **원인**: 좌표계 불일치. `FocusWindowGeometry.nextWindow` 의 사분면
  게이트가 bottom-origin(Cocoa, y 증가 = 위) 가정으로 작성됨
  (`.up: dy > 0`). 하지만 런타임에 들어오는 프레임은
  `WindowUtil.getWindowList()` → `kCGWindowBounds` 의 **top-origin**
  (y 증가 = 아래) 좌표다 — `reveal()` 이 NSScreen 프레임을
  `.screenFlipped` 로 뒤집어 창 프레임과 비교하는 것이 그 증거.
  실측: 화면 맨 위 메뉴바의 CG bounds 가 `y = 0`.
  단위 테스트도 같은 bottom-origin 가정으로 작성되어 있어서
  ("macOS 좌표계: y 증가 = 위" 주석) 통과해 왔음. 좌/우는 부호 영향이
  없어 정상이었고, B7 까지의 수동 테스트가 전부 좌/우 위주라 발견이
  늦었다. tie-break 의 "upper first" (`midY` 큰 것 우선) 도 같은
  이유로 실제로는 아래쪽 우선이었음.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowGeometry.swift`
  - `RectangleTests/FocusWindowGeometryTests.swift`
- **상태**: 해결됨 — TDD. 테스트를 top-origin 의미로 먼저 교정해 6개
  단언 실패(반전 증명)를 확인한 뒤, `.up`/`.down` 게이트 부호와
  tie-break 부등호를 교환. 12/12 통과.
- **우선순위**: 미정

---

## [x] B10. Stacked Windows picker 가 key window 가 되지 못해 focus 이탈 시 dismiss 가 안 된다

- **재현 조건**: Reveal Stacked Windows HUD 가 뜬 상태에서 Cmd+Tab 으로
  다른 앱으로 전환 (클릭 없이).
- **관찰된 동작**: HUD 가 dismiss 되지 않고 화면에 남는다.
  `canJoinAllSpaces` 라 Space 를 옮겨도 따라다닌다. Rectangle 이
  비활성이 되어 로컬 키 모니터가 이벤트를 못 받으므로 Esc 도 안 먹고,
  글로벌 *클릭* 모니터로만 해제 가능. 잔존하는 동안
  `StackedWindowsManager.isActive == true` 라 B1 의 상호 배타 가드가
  Focus Window Picker 호출까지 beep 으로 차단한다.
- **기대 동작**: focus 가 picker 를 떠나면 (다른 창 클릭, Cmd+Tab 등)
  HUD 가 스스로 닫힌다 — `resignKey()` override 의 원래 의도.
- **원인**: borderless `NSWindow` 는 기본적으로 `canBecomeKey == false`
  (실측 확인). `makeKeyAndOrderFront` 가 orderFront 만 수행하고 key 는
  되지 못해 `resignKey()` override 가 죽은 코드였음. 같은 borderless 인
  `WindowHighlightWindow` 는 `canBecomeKey` 를 override 해 두어서 focus
  picker 쪽은 정상이었다.
- **관련 파일**:
  - `Rectangle/MultiWindow/StackedWindowsPickerWindow.swift`
  - `RectangleTests/StackedWindowsOverlapTests.swift`
    (`StackedWindowsPickerWindowTests`)
- **상태**: 해결됨 — TDD. `canBecomeKey` 단언 테스트로 false 를 먼저
  확인한 뒤 `WindowHighlightWindow` 와 동일하게
  `canBecomeKey = true` / `canBecomeMain = false` override 추가.
- **우선순위**: 미정

---

## [x] B11. Picker 확정 시점에 이미 닫힌 창을 고르면 엉뚱한 형제 창이 활성화된다

- **재현 조건**: picker 후보 스냅샷에 있던 창이 확정(Enter) 전에
  닫힌 경우. 세션 중 키 입력은 Rectangle 이 가로채므로 사용자가 직접
  닫는 경로는 없고, 현실적 경로는 (a) `WindowUtil` 100ms 캐시(EC7)에
  남은, reveal 직전에 닫힌 창이 후보에 들어간 경우, (b) 자동으로 닫히는
  다이얼로그/알림 창.
- **관찰된 동작**: `raiseAndActivate` 의 AX 재해석(resolve)이 전부
  실패해 `resolvedTarget == nil` 인데도 B8 의 minimized 검사만 통과하고
  죽은 wid 로 SLPS activate 를 수행 → 소유 앱이 앞으로 나오며 임의의
  형제 창이 활성화. 반환값도 `true` 라 previousApp 복원 경로도 안 탐.
- **기대 동작**: B8 (minimized) 과 동일 — beep 후 activate 전체를
  건너뛰고 `false` 반환, `Session.confirm` 이 pre-picker frontmost 복원.
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowManager.swift` (`raiseAndActivate`)
- **상태**: 해결됨 — `resolvedTarget == nil` 이면 beep + 로그 후 `false`
  반환하는 guard 추가. AX 의존이라 단위 테스트 불가, 수동 검증 필요
  (Debug 빌드에서 자동 닫힘 다이얼로그 또는 reveal 직전 창 닫기로 재현).
- **우선순위**: 미정

---

## [x] B12. Stacked Windows HUD 가 후보가 많으면 화면 폭을 넘어간다

- **재현 조건**: 활성 창이 최대화(또는 화면 대부분 차지) 상태에서
  Reveal Stacked Windows 호출. D-max overlap 특성상 같은 화면의 거의
  모든 창이 후보가 되므로 (각 창이 자기 면적의 100% 를 활성 창과 공유)
  후보 10개 이상이 쉽게 나온다.
- **관찰된 동작**: 카드 한 줄 폭이 `16*2 + N*140 + (N-1)*12` 로 무제한
  증가. 10개 = 1,540pt 로 1512pt MacBook 화면 초과. 넘친 카드는 클릭
  불가, 숫자 단축키는 1–9 까지만, 화살표로 이동하면 하이라이트가 화면
  밖이라 보이지 않음.
- **기대 동작**: HUD 가 대상 화면 안에 들어오고 모든 카드가 보인다.
- **관련 파일**:
  - `Rectangle/MultiWindow/StackedWindowsPickerWindow.swift` (`gridLayout`)
  - `RectangleTests/StackedWindowsOverlapTests.swift`
- **상태**: 해결됨 — TDD. 순수 함수 `gridLayout(count:maxContentWidth:)`
  를 추출해 화면 visibleFrame 의 90% 를 최대 폭으로 열 수를 계산하고,
  넘치는 후보는 다음 줄로 wrap. 15개 후보 통합 테스트로 HUD 폭이
  화면 폭 이하임을 검증. 선택 이동(←/→/Tab)은 기존 선형 순서 유지.
- **우선순위**: 미정

---

## [x] B13. 마지막으로 쓰던 창을 닫으면 Focus Window Picker 가 동작하지 않는다

- **재현 조건**: frontmost 앱의 *마지막* 창을 닫은 직후 picker 호출.
  (같은 앱에 다른 창이 남아 있거나, 마지막 창과 함께 앱이 종료되는
  경우는 해당 없음 — 그땐 anchor 가 정상적으로 잡힌다.)
- **관찰된 동작**: beep 만 나고 picker 가 열리지 않음. macOS 는 창이
  0개여도 그 앱을 frontmost 로 유지하므로 `getFrontWindowElement()` 가
  nil 을 반환하고, `reveal()` 진입 가드가 후보 수집 전에 bail.
  EC1 fallback 은 *닫을 때*(frontmost 복원), B8 fallback 은 *minimized*
  일 때만 동작해서 이 경로엔 아무 fallback 도 없었다.
- **기대 동작**: 직전에 쓰던(그 전 최근) 창에 커서를 앵커한 채 picker
  가 열린다.
- **해결 방식 (A안)**: 진입 가드를 완화 — front window/wid 를 못 얻어도
  후보 수집까지 진행하고, `activeIndex == -1` 이면 B8 과 같은 경로로
  `candidateInfos[0]` 에 앵커. CGWindowList 는 전역(모니터 구분 없는)
  z-order = MRU 순서이므로 후보 0번이 곧 "닫힌 창 이전에 쓰던 창"이다.
  듀얼 모니터에서도 모호하지 않음 — 스택이 하나라서 직전 창이 다른
  모니터에 있으면 그 창이 맨 앞에 온다. 후보가 정말 0개일 때만
  beep-bail. 부수 효과: `windowId == nil` 인 특수 앱(A4 케이스)도 이제
  같은 앵커 경로로 picker 가 열린다.
  (B안 — AX 옵저버로 자체 focus 이력 추적 — 은 상시 옵저버 비용 대비
  과해서 기각.)
- **관련 파일**:
  - `Rectangle/MultiWindow/FocusWindowManager.swift` (`reveal()`)
- **상태**: 해결됨 — AX/CGWindowList 의존이라 단위 테스트 불가, 전체
  스위트 회귀 통과. 수동 검증 필요: 마지막 창 닫기 → hotkey → 직전
  창에 하이라이트가 앵커되는지.
- **우선순위**: 미정
