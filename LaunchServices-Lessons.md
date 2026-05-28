# LaunchServices 정리 시 주의사항

Rectangle Debug 빌드를 여러 번 빌드하다 보면 LaunchServices DB에 여러
경로의 `Rectangle.app` 이 동시에 등록되어 단축키가 의도하지 않은
빌드를 깨우는 일이 생긴다. 이걸 정리하려고 LaunchServices DB 전체를
재구성하면 부작용으로 시스템 설정 패널들까지 사라진다. 그 교훈.

---

## 무엇을 하면 안 되는가

```sh
# ❌ DB 전체 재구성 — 부작용 큼
lsregister -kill -r -domain local -domain system -domain user
```

이 명령은 LaunchServices DB를 *전부* 비우고 처음부터 다시 채운다.
의도는 "옛 Rectangle 등록만 지우자"였지만, **시스템 설정 패널
(PreferencePane / ExtensionKit Extension)들도 같이 unregister 되어**
macOS 시스템 설정을 열면 General 과 Spotlight 만 남고 나머지 패널
(네트워크, 디스플레이, 손쉬운 사용 등)이 통째로 비어 보인다.

복구는 가능하지만(아래 참조) 사용자에게 혼란을 준다.

## 무엇을 해야 하는가

### 1. 보통은 그냥 옛 `.app` 만 지우거나 옮긴다

LaunchServices 는 존재하지 않는 경로의 등록을 자체적으로 정리한다.
그래서 가장 안전한 방법은:

```sh
# 옛 build artifact 디렉터리 삭제
rm -rf rectangle-src/build/Build
rm -rf ~/Library/Developer/Xcode/DerivedData/Rectangle-evbmwycdxmthpxeqmkveourvwogk

# 설치판은 삭제 대신 백업 위치로 이동 (검증 끝나면 복구 가능)
mv /Applications/Rectangle.app ~/Desktop/Rectangle.app.installed-backup
```

### 2. 특정 bundle 만 등록 해제하고 싶으면 `-u` (좁은 명령)

```sh
# 특정 경로의 등록만 제거
lsregister -u /path/to/old/Rectangle.app
```

### 3. 새 Debug 빌드만 등록

```sh
DEBUG_APP="rectangle-src/build/DerivedData/Build/Products/Debug/Rectangle.app"
lsregister -f -R -trusted "$DEBUG_APP"
```

이 정도면 단축키 트리거가 신버전을 깨운다.

## 만약 이미 전체 재구성을 해버렸다면 — 복구 절차

```sh
# 시스템 설정 종료
killall "System Settings"

# 시스템 패널들을 다시 등록
lsregister -R -f "/System/Applications/System Settings.app"
lsregister -R -f /System/Library/PreferencePanes
lsregister -R -f /System/Library/ExtensionKit/Extensions
```

그래도 시스템 설정 사이드바가 비어 보이면:

- `killall cfprefsd` 한 번 더 시도
- 그래도 안 되면 **재로그인**(Apple 메뉴 → 로그아웃) — 재부팅까진 불필요

## 별개 사항: TCC(손쉬운 사용 권한)는 LaunchServices 와 무관

`lsregister` 재구성으로는 TCC DB 가 정리되지 않는다. 옛 Rectangle 항목이
손쉬운 사용 목록에 남아 있으면 패널에서 직접 `-` 버튼으로 제거해야 한다.
권한은 bundle id + code signature 기준이므로 Debug 빌드는 별도로
권한을 다시 부여해야 한다.

---

## 빠른 참조: `lsregister` 경로

```
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
```

PATH에 없으니 절대 경로로 호출하거나 alias로 등록.
