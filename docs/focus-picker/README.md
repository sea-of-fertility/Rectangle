# Focus Picker — 작업 노트 모음

Focus Window Picker / Reveal Stacked Windows 기능의 설계·조사·회고 문서
모음. 실제 버그 트래커는 루트의 [`buglist.md`](../../buglist.md), 코드
변경은 git history 에 있다. 여기 문서들은 *왜 그렇게 고쳤는지* 와 *어떻게
재현했는지* 의 맥락 보관이다.

## 파일

- [`B5-Investigation.md`](B5-Investigation.md) — B5 (형제 Chromium 창
  동반 raise) 의 원인 추적과 SkyLight private API 채택까지의 조사.
  공식 API 로는 불가능하다는 결론에 도달한 과정과, 그 다음 비공식 경로
  (`_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo`) 로
  전환한 근거 정리.

- [`ChromiumFix.md`](ChromiumFix.md) — Focus Window Picker 의 초기
  Chromium/Brave 활성화 문제 (`feature/focus-window-picker` 브랜치 시점)
  분석. AXRaise + isMainWindow 조합으로 last-known-main 재promote 패턴을
  방어한 방식. B5 fix 이전 버전.

- [`EdgeCases.md`](EdgeCases.md) — 머지 완료된 fix (B3, B5, B6, B7, B8)
  들의 코드 분석에서 파생된 잠재적 엣지 케이스. 각 항목에 *어떻게
  재현할 수 있는지* 와 그때 나타날 증상 정리. 모두 가설 (미검증).

- [`StackedWindows-Design.md`](StackedWindows-Design.md) — Reveal
  Stacked Windows 의 의논 체크리스트. 같은 자리 / 같은 크기 창만이 아닌
  *활성 창과 겹치는 모든 창* 을 후보로 보여주는 설계 결정 과정.
