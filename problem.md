# fix.md — 시스템 설정 패널이 사라진 문제와 해결

## 증상

macOS 시스템 설정(System Settings)을 열면 사이드바에 **General 과 Spotlight 두 항목만** 남고, 네트워크 / 디스플레이 / 손쉬운 사용(Accessibility) 등 나머지 패널이 통째로 비어 보였다. 결과적으로 Rectangle Debug 빌드에 Accessibility 권한을 부여할 방법이 없어 검증 자체가 막혔다.

## 원인

LaunchServices DB 전체 재구성 명령을 실행한 것이 원인이다.

```sh
# ❌ 부작용 큰 명령
lsregister -kill -r -domain local -domain system -domain user
```

원래 의도는 "여러 경로에 중복 등록된 옛 `Rectangle.app` 만 정리"였지만, 이 명령은 LaunchServices DB를 *전부* 비우고 처음부터 다시 채운다. 그 과정에서:

- macOS 시스템 설정 패널들은 PreferencePane / ExtensionKit Extension 형태로 LaunchServices 에 등록되어 있다.
- DB 가 비워지면 이들이 **같이 unregister 되어** 시스템 설정에서 표시되지 않는다.

즉, Rectangle 빌드 정리 → LaunchServices 전체 재구성 → 시스템 패널까지 같이 날아감, 이 연쇄로 발생했다.

## 해결 방법

시스템을 **재시작** 했다. 재부팅 과정에서 macOS 가 PreferencePane / ExtensionKit Extension 들을 다시 등록하므로, 시스템 설정의 모든 패널이 정상적으로 복원되었다.

확인 결과:
- 재시작 후 시스템 설정 사이드바에 모든 항목 정상 표시
- 손쉬운 사용 패널 진입 가능 → Rectangle Debug 빌드에 권한 부여 가능

## 재발 방지 (LaunchServices-Lessons.md 와 일치)

옛 Rectangle 등록만 정리하고 싶을 때는 **좁은 명령** 만 쓴다.

```sh
# 특정 경로 등록만 해제
lsregister -u /path/to/old/Rectangle.app

# 새 Debug 빌드만 재등록
DEBUG_APP="rectangle-src/build/DerivedData/Build/Products/Debug/Rectangle.app"
lsregister -f -R -trusted "$DEBUG_APP"
```

또한 설치판은 삭제하지 말고 백업 위치로 옮긴다.

```sh
mv /Applications/Rectangle.app ~/Desktop/Rectangle.app.installed-backup
```

LaunchServices 는 존재하지 않는 경로의 등록을 자체적으로 정리하므로, 보통은 이것만으로 충분하다.

## 관련 문서

- [LaunchServices-Lessons.md](LaunchServices-Lessons.md) — 같은 사고에 대한 더 상세한 회고 및 복구 절차
