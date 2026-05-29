# 개발 환경 노트

Rectangle 빌드 / 권한 / LaunchServices 관련 사고 및 회복 절차 모음.

## 파일

- [`LaunchServices-Lessons.md`](LaunchServices-Lessons.md) —
  Debug 빌드를 여러 번 빌드하다 보면 LaunchServices DB 에 여러 경로의
  `Rectangle.app` 이 중복 등록되어 단축키가 의도하지 않은 빌드를
  활성화하는 문제. 이걸 정리하려고 `lsregister -kill -r` 같은 광범위
  명령을 쓰면 시스템 설정 패널까지 unregister 된다. 안전한 좁은 명령
  (`lsregister -u`, `lsregister -f -R -trusted`) 사용 가이드.

- [`SystemSettings-Disappearance.md`](SystemSettings-Disappearance.md) —
  위 사고가 실제로 일어났을 때 (시스템 설정에 General/Spotlight 만
  남음) 의 회복 절차 회고. 시스템 재시작으로 PreferencePane /
  ExtensionKit Extension 들이 다시 등록되며 복구된 흐름.
