# Focus Picker — Chromium/Brave Window-Activation Fix

Focus Window Picker가 Brave(또는 다른 Chromium/Electron 계열: Chrome, Edge, Slack, VS Code 등)에서 **다른 디스플레이/창을 골랐는데도 좌측(또는 마지막으로 main이었던) 창이 활성화되는** 버그에 대한 원인 분석 및 해결 기록.

브랜치: `feature/focus-window-picker`
관련 커밋: `b7774a0` — *fix: focus picker reliably switches to picked window in Chromium apps*
관련 파일:
- `Rectangle/MultiWindow/FocusWindowManager.swift`
- `Rectangle/AccessibilityElement.swift`

---

## 1. 증상

두 개의 Brave 창이 다른 디스플레이에 있을 때 (좌측 = `New Tab`, 우측 = `Google Gemini`):

1. 사용자가 좌측 Brave 창에서 포커스 픽커를 켠다.
2. 우측 화살표로 우측 Brave 창을 선택하고 Enter.
3. 픽커는 정상 종료되고, Brave가 frontmost 앱이 된다.
4. **그런데 키 입력이 들어가는 곳은 우측이 아니라 여전히 좌측 Brave 창**이다.

로그상으로는 모두 정상이었다:

```
[FW] confirm: chosen wid=89030 pid=97826 proc=Brave Browser frame={{480, 25}, {960, 875}}
[FW] confirm: directApp(pid=97826) has 2 AX windowElements
[FW]   directAxwin[0] wid=89036 title=New Tab - Brave        ← 좌측
[FW]   directAxwin[1] wid=89030 title=Google Gemini - Brave  ← 우측 (picked)
[FW] confirm: matched directly via PID
[FW] confirm: AXRaise result=OK
[FW] confirm: activated app pid=97826
```

`AXRaise`도 OK, `activate`도 OK인데 입력은 다른 창으로 간다.

---

## 2. 원인

**Chromium/Electron 앱은 `NSRunningApplication.activate(...)` 호출 시점에 자신이 마지막으로 main이었던 윈도우를 다시 main으로 복원**한다. 즉, 다음과 같은 순서로 호출하면:

```
1) AXRaise on target window   ← 우측 창을 raise
2) NSRunningApplication.activate(...)   ← Brave 앱 activate
```

2번째 단계에서 macOS의 일반적인 동작 + Chromium의 자체 main-window 추적이 결합되면서, 직전에 raise했던 우측 창의 main 상태가 **앱의 "마지막으로 main이었던 창"(= 좌측)으로 덮어쓰여진다**. 그래서 화면상 Brave가 frontmost가 되긴 하지만 key window는 좌측이 된다.

검증 단서:
- 우측 창 선택 → 좌측 창에서 작업이 진행되는 현상 (좌측 창의 탭이 `New Tab` → `Remote Ceph Admin`으로 바뀌는 등)
- 동일한 코드가 비-Chromium 앱(IntelliJ, Finder 등) 사이의 전환에선 잘 동작
- `isMainWindow = true` 단독 설정 + activate 조합도 Chromium에선 무시됨 (코드 주석에 이미 기록되어 있던 사실)

---

## 3. 해결

**호출 순서를 바꾸고, `AXMain`을 명시적으로 다시 세팅한다.**

```
1) NSRunningApplication.activate(...)   ← 앱을 먼저 frontmost로 만들고
2) AXRaise on target window             ← 그 다음에 raise
3) Set AXMain = true on target window   ← 그리고 main을 못박는다
```

이 순서면 Chromium이 activate 시점에 main을 복원하더라도, 그 *이후의* AXRaise + AXMain이 최종 상태로 남는다.

### 핵심 코드 (FocusWindowManager.swift)

```swift
// Order matters here for Chromium/Electron apps (Brave, Chrome, VS Code,
// Slack, ...). If we AXRaise *before* activating the app, macOS often
// re-promotes the app's last-known-main window during the subsequent
// activate, undoing our raise. So: activate first, then AXRaise, then
// set AXMain — that order survives Chromium's habit of resetting main
// window state.
if let runningApp = NSRunningApplication(processIdentifier: resolvedPid) {
    runningApp.activate(options: .activateIgnoringOtherApps)
}

if let target = resolvedTarget {
    let raiseOK = target.raise()
    target.setMain(true)
}
```

### 신규 헬퍼 (AccessibilityElement.swift)

```swift
/// Sets AXMain on this window element. Pairs with `raise()` after the
/// owning app has been activated to coerce Chromium/Electron apps into
/// keeping the picked window as the key/main window.
func setMain(_ value: Bool) {
    windowElement?.wrappedElement.setValue(.main, value)
}
```

---

## 4. 검증

테스트 시나리오 (실제로 확인한 경로):

1. 좌측 디스플레이 Brave 창, 우측 디스플레이 Brave 창 두 개를 준비
2. 좌측 Brave에서 포커스 픽커 트리거
3. → 키로 우측 Brave 창 선택 후 Enter
4. 키보드 입력이 **우측 Brave 창의 주소창/내용**에 들어가는지 확인

로그에 `[FW] confirm: AXRaise result=OK (post-activate)` 메시지가 찍히면 새 순서로 동작 중이라는 신호.

`Chrome / Edge / Slack / VS Code` 등 다른 Chromium 계열 앱에도 동일하게 적용될 것으로 기대됨 (별도 검증 권장).

---

## 5. 디버깅 노하우

조사 과정에서 다음 두 함정에 빠졌었음 — 향후 같은 패턴의 버그를 만날 때 빨리 거르기 위해 기록:

### 5-1. AX windowId vs CGWindowList

Chromium은 헬퍼 프로세스를 띄우기 때문에 `WindowInfo.pid`(CGWindowList 기준)와 AX API가 다루는 PID가 다를 수 있다. PID로 `AccessibilityElement`를 만들었을 때 윈도우 리스트가 비면, **모든 running app을 스캔해서 `windowId`로 매칭**하는 폴백이 필요하다 (`FocusWindowManager.raiseAndActivate`에 구현됨).

### 5-2. "빌드 = 설치 = 실행"이 아니다

`xcodebuild ... build`가 `BUILD SUCCEEDED`를 찍어도, **실행 중인 `/Applications/Rectangle.app`은 갱신되지 않는다**. DerivedData의 산출물을 `/Applications`에 복사하거나 Xcode에서 Run해야 변경이 적용된다.

증상: 코드에 추가한 새 NSLog가 로그에 안 보이면 = 옛날 바이너리가 실행 중. 새 로그 메시지가 보이는지를 "변경된 코드가 실제로 돌고 있는지"의 카나리아로 쓸 수 있다.

설치+재시작 절차:

```bash
# 1. 빌드
xcodebuild -project Rectangle.xcodeproj -scheme Rectangle -configuration Debug build

# 2. 실행 중인 앱 종료
osascript -e 'tell application "Rectangle" to quit'

# 3. /Applications의 앱을 새 빌드로 교체
rm -rf /Applications/Rectangle.app
cp -R ~/Library/Developer/Xcode/DerivedData/Rectangle-*/Build/Products/Debug/Rectangle.app /Applications/Rectangle.app

# 4. 재실행
open /Applications/Rectangle.app
```

---

## 6. 남은 리스크 / 향후 개선

- 일부 Chromium 빌드/버전에서는 activate → raise → setMain 순서로도 안 되는 경우가 보고된다. 만약 회귀하면 다음을 시도:
  - `activate` 후 짧은 딜레이(~50ms) 두고 `AXRaise + setMain` 재호출
  - 좌측 창을 일시 minimize → 우측 raise → 좌측 unminimize
  - Brave에 한해 좌측 창에 `AXCancel` 보내고 우측 raise
- `setMain`은 silent failure가 가능(반환값 없음). 필요 시 `getValue(.main)`로 read-back 검증 추가.
- 이 fix는 포커스 픽커 경로에만 적용되어 있다. `bringToFront(force:)` (AccessibilityElement.swift)는 여전히 `isMainWindow → activate` 순서를 쓰므로, 다른 멀티윈도우 액션에서 같은 증상이 나면 같은 순서 뒤집기를 검토할 것.
