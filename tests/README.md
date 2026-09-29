# 테스트 도구

`build.sh`의 자동 테스트와 별도로 실제 입력 경로를 확인하는 로컬 전용 도구입니다.

## 가상 키보드 (`virtual-keyboard/`)

Karabiner-Elements의 가상 키보드로 키를 눌러, 실행 중인 gksdud를 물리 키보드와 같은 경로로 확인합니다. Caps Lock 대소문자 보존, 한글 상태 Caps Lock, ESC 영문 전환을 입력 소스, Caps Lock 상태, 입력된 글자로 판정합니다.

Karabiner-Elements가 설치되어 있고 gksdud가 활성화된 상태로 실행 중이어야 합니다. 한영 키는 우측 Command, Option, Control 중 하나여야 합니다.

```sh
bash tests/virtual-keyboard/build.sh
# 다른 터미널에서 켜둡니다. 끝나면 Ctrl+C
sudo tests/virtual-keyboard/build/vhid-keys tests/virtual-keyboard/build/vhid.sock
bash tests/virtual-keyboard/run.sh
```

- 실행하는 30초 동안 테스트 창이 포커스를 가져갑니다. 키보드와 마우스를 만지지 마세요.
- gksdud의 현재 설정으로 확인하고, 끝나면 입력 소스와 영어 대소문자를 되돌립니다. 중간에 멈췄다면 `run.sh --reset`으로 영어 소문자를 되돌립니다.

sudo 없이 ESC 경로만 확인하려면 `build.sh`가 마지막에 출력하는 테스트용 앱으로 `open -n -W --stdout <파일> <테스트용 앱> --args --probe-escape`를 실행합니다. 테스트 코드는 이 테스트용 앱에만 들어가고 배포 앱에는 포함되지 않습니다.
