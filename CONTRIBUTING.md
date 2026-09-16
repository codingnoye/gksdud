# 기여 안내

## 개발 환경과 빌드

Xcode Command Line Tools가 설치된 macOS에서 빌드합니다. 외부 패키지는 필요하지 않습니다.

```sh
GKSDUD_SIGN_MODE=ad-hoc bash build.sh
```

빌드 과정에서 자체 테스트를 실행하고 `outputs/`에 Universal ZIP을 만듭니다. ad-hoc 개발 빌드로 기존 설치본을 교체하면 접근성 권한을 다시 허용해야 할 수 있습니다.

## 검증

자동 테스트는 매핑 보존, 복구, 전환 이벤트, 길게 누르기 상태 처리를 검사합니다. 실제 입력 조합, 다른 Mac에서의 최초 설치, Intel 기기, 로그인 및 잠자기 복귀는 별도의 수동 검증이 필요합니다.

## 관련 문서

- [변경 기록](CHANGELOG.md)
