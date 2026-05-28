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

## [ ] B2. Focus Window Picker로 맨 우측 Brave 창을 선택했는데 제일 좌측 Brave 창이 picker(활성)된다

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
- **상태**: 미해결
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

## [ ] B4. Reveal Stacked Windows로 IntelliJ를 선택하면, 가려진 그 창이 아니라 다른 디스플레이의 IntelliJ가 활성화된다

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
- **상태**: 미해결
- **우선순위**: 미정

---

## [ ] B5. Focus Window Picker로 한 디스플레이의 Chromium 창을 선택하면 다른 디스플레이의 같은 앱 창도 같이 맨 앞으로 올라온다

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
- **상태**: 미해결
- **우선순위**: 미정
