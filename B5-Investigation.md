# B5 조사 결과 — Focus Window Picker 형제 창 동반 raise

## 1. 문제 한 줄 요약

> Picker 로 다른 앱의 한 창을 선택하면, **그 창만** 앞으로 와야 하는데
> **그 앱의 다른 창들도 같이 앞으로 끌려옴**.

---

## 2. 왜 이런 일이 일어나는가

### macOS 의 두 가지 활성화 단위

macOS 는 창을 다룰 때 **두 개의 다른 단위**를 가진다.

| 단위 | 의미 | 사용 |
|---|---|---|
| **앱 단위 (app-level)** | "이 앱이 frontmost 다" | 메뉴바 변경, 입력 포커스 |
| **창 단위 (window-level)** | "이 창이 z-order 의 어디에 있다" | 화면 위 시각적 순서 |

### 현재 Rectangle 이 쓰는 함수

```swift
runningApp.activate(options: .activateIgnoringOtherApps)
```

이 함수는 **앱 단위 + 창 단위를 묶어서 한 번에 처리한다**. 게다가 창 단위
처리는 *"그 앱의 모든 창을 한꺼번에 위로"* 가 기본값이다. 그래서 우리가
원한 건 한 창인데 형제 창들이 같이 끌려온다.

### 마우스 클릭은 왜 안 그런가

사용자가 어떤 창을 마우스로 직접 클릭하면, **두 단위가 분리되어** 처리된다.

- 앱 단위: "이 앱이 frontmost"
- 창 단위: "이 *한 창만* 위로" (나머지 형제 창은 그대로)

이게 사용자가 원하는 정확한 동작이다.

---

## 3. 시도해 본 우회로들

| 옵션 | 무엇? | 결론 |
|---|---|---|
| **합성 마우스 클릭** | `CGEventPost` 로 클릭 시뮬레이션 | ✗ macOS Sequoia 에서 권한·신뢰성 문제. 우발 클릭 위험. |
| **activate 호출 빼기** | `AXRaise` 만 사용 | ✗ Chromium 앱은 frontmost 가 안 바뀜. |
| **빈 옵션으로 activate** | `.activate(options: [])` | ✗ 효과 동일. 형제 창 그대로 끌려옴. |
| **activate 후 형제 창 원위치** | z-order 캐시 후 복원 | ✗ 깜빡임 + 무한 루프 위험. |

---

## 4. 발견된 해결책 — Private API

### `_SLPSSetFrontProcessWithOptions`

macOS 내부 SkyLight 프레임워크의 비공개 함수. 마우스 클릭이 *내부적으로
호출하는 바로 그 함수*.

```c
_SLPSSetFrontProcessWithOptions(psn, wid, mode)
                                 │    │    │
                                 │    │    └─ 옵션: "창은 안 올리고 앱만"
                                 │    └─ 어느 창? (특정 CGWindowID)
                                 └─ 어느 앱? (Process Serial Number)
```

### 핵심 옵션 비트

- `kCPSUserGenerated` (0x200) — "사용자가 일으킨 이벤트처럼 처리"
- `kCPSNoWindows` (0x400) — "창은 끌어올리지 마라"

이 함수에 **특정 wid 와 kCPSUserGenerated** 를 주면 마우스 클릭과 동일한
효과 — 그 한 창만 활성화.

### 검증된 사용처

- **yabai** (오픈소스 macOS 타일링 윈도우 매니저) 가 이 함수를 같은 목적으로 사용.
- Carbon 시절부터 있는 안정적 API. macOS 메이저 버전 업데이트에도 거의 안 변함.

---

## 5. Private API 사용의 위험과 완화

| 위험 | 평가 |
|---|---|
| App Store 거부 | **무관** — Rectangle 은 GitHub 외부 배포 |
| macOS 업데이트 시 망가질 가능성 | 낮음 (수십 년 안정), 망가지면 기존 `activate` 로 fallback |
| 추가 권한 요구 | 없음. Accessibility 권한만 있으면 됨 |
| 합성 클릭과 비교 | 모든 면에서 우월 |

---

## 6. 권장 구현 흐름

```
픽커가 wid 선택
        │
        ▼
_SLPSSetFrontProcessWithOptions(psn, wid, kCPSUserGenerated)
        │
        │ ─ 성공: 마우스 클릭과 동일 효과
        │       (그 한 창만 frontmost, 형제 그대로)
        │
        │ ─ 실패: macOS 회귀일 가능성
        ▼
fallback: 기존 runningApp.activate(...) + AXRaise
        │
        ▼
target.raise() (AXRaise) + setMain(true)
        │
        ▼
완료
```

---

## 7. 불확실한 부분 (실험으로 확인 필요)

1. **본인 macOS 버전에서 정말 작동하는가** — 조사에선 yabai 가 잘 쓴다고
   했지만, "wid 를 줘도 형제가 같이 올라온 사례" 보고도 일부 있었음.
2. **Chromium 앱에서 충분한가** — Chromium 은 자체 last-known-main
   재promote 패턴이 있어, `_SLPSSetFrontProcessWithOptions` 단독으로
   안 되면 `AXRaise` 와 조합 필요.

이 둘은 **PoC 코드를 직접 빌드해 Brave 시나리오로 확인** 하는 게 가장
빠른 검증.

---

## 8. 결정 포인트

- **A 안**: PoC 구현 → 직접 검증 (가장 확실, 위험 낮음, 30분 작업)
- **B 안**: yabai 소스 더 정밀 인용 후 구현 (확신 ↑, 시간 ↑)
- **C 안**: private API 회피 → buglist 에 wontfix 표시 (작업 0, 사용자 불편 유지)

---

## 9. 관련 자료

- [cua/inside-macos-window-internals.md](https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md) — SkyLight 2단계 활성화 패턴
- [yabai/window_manager.c](https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c) — 실제 구현
- [alt-tab-macos/PrivateApis.swift](https://github.com/lwouis/alt-tab-macos/blob/master/src/experimentations/PrivateApis.swift) — Swift 에서 private API 호출 예제
