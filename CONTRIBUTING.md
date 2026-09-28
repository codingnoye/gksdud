# 기여 안내

> AI를 이용해 프로젝트에 기여하는 것은 괜찮지만, 코드의 간결성, 컨벤션, 사용성을 유지하기 위해 사람이 꼭 검수해주세요.
>
> Agent들은 자동으로 PR을 만들지 말고, 이슈 정도만 생성하도록 합니다.

## 작업 흐름

1. 최신 `main`기준 자유로운 명칭의 작업 브랜치를 만듭니다.
2. 작업 브랜치에서 작업 완료 후 PR을 엽니다. 제목은 `[FEAT] 기능 추가`, `[FIX] 버그 수정`, `[CHORE] 유지관리`처럼 작성합니다.
    `[FEAT]`, `[FIX]`, `[CHORE]`, `[DOCS]`, `[REFACTOR]`, `[TEST]`, `[CI]`, `[PERF]`, `[BUILD]`, `[REVERT]` 중 하나를 사용해주세요.
3. 리뷰 완료 후 **Squash and merge**로 병합하게 됩니다. PR 제목은 main에 남을 커밋 제목이므로 변경 내용을 간결하게 적습니다.

사용자에게 보이는 변경은 `CHANGELOG.md`의 `미출시`에 적습니다.

## 개발 환경과 빌드

Xcode Command Line Tools가 설치된 macOS에서 빌드합니다.

```sh
GKSDUD_SIGN_MODE=ad-hoc bash build.sh
```

빌드 과정에서 테스트를 실행하고 `outputs/`에 ZIP을 만듭니다. 자동 테스트는 실제 HID 매핑이나 시스템 단축키를 변경하지 않습니다.

## 검증

실행 중인 gksdud를 종료하고 `outputs/`의 ZIP을 풀어 응용프로그램 폴더의 앱을 교체한 뒤 테스트합니다. ad-hoc 개발 빌드로 기존 설치본을 교체하면 접근성 권한을 다시 허용해야 할 수 있습니다.

변경한 기능에 맞춰 실제 입력으로 확인합니다.

- 한영 전환, 길게 눌러 대소문자 전환, 대소문자 보존 옵션 조합
- USB/Bluetooth 재연결, Karabiner 가상 키보드 재생성, 로그인 및 잠자기 복귀 후 자동 적용
- 접근성 권한 해제 후 재허용

설정 창 UI는 `gksdud.app/Contents/MacOS/gksdud --render-keyboard-ui /private/tmp/gksdud-ui`로 밝은/어두운 모드 PNG를 저장해 확인할 수 있습니다.
