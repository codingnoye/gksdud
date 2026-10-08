# CLI

`gksdud` 명령으로 실행 중인 gksdud의 설정을 바꾸고 입력 소스를 전환합니다.

Hammerspoon, Karabiner-Elements, skhd, Raycast, 셸 스크립트 등에서 쓸 수 있습니다.

```sh
gksdud pause                          # 일시정지 (특정 앱 사용중인 경우 등)
gksdud resume                         # 일시정지 재개
gksdud set long-press=on escape=on    # 설정(여러 개 가능) 바꾸고 적용
gksdud source ko                      # 입력 소스 전환
gksdud status --json                  # 현재 상태를 JSON으로
```

## 설치

설정 → `추가기능` → `CLI 설치`를 눌러 설치합니다.

`/usr/local/bin/gksdud`에 앱 안의 명령(`gksdud.app/Contents/Helpers/gksdud`)으로 가는 링크를 만듭니다. 제거 가능합니다.

수동 설치:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/gksdud.app/Contents/Helpers/gksdud /usr/local/bin/gksdud
```

- gksdud 앱이 실행 중이어야 합니다. 꺼져 있으면 `gksdud start`로 실행합니다.
- gksdud를 실행한 사용자 계정으로 실행해야 앱을 찾습니다.
- Hammerspoon·Karabiner 등은 `PATH`가 짧으니 `/usr/local/bin/gksdud` 전체 경로로 실행합니다.

## 명령

| 명령 | 설명 |
| --- | --- |
| `status` | 현재 상태 (활성화, 일시정지, 접근성 권한, 입력 소스, 키보드) |
| `get [<설정>...]` | 설정 조회. 하나만 조회하면 값만 출력 (`gksdud get keys` → `right-command`) |
| `set <설정>=<값>...` | 설정 변경 후 바로 적용. 목록은 `+=`로 추가, `-=`로 제거 |
| `toggle <설정>...` | on/off 설정 뒤집기 |
| `enable`, `disable` | 활성화 켜기/끄기 (설정 창의 `활성화`와 동일, `enable`은 일시정지도 해제) |
| `pause`, `resume` | 일시정지/재개 |
| `source [<입력 소스>]` | 입력 소스 전환. 생략하면 현재 입력 소스 출력 |
| `sources` | 켜져 있는 입력 소스 목록 (`*`가 현재) |
| `keyboards` | 키보드 목록과 키보드별 설정 |
| `start`, `quit` | 앱 실행/종료 |
| `help [settings]`, `version` | 도움말, 설정 목록, 버전 |

| 옵션 | 설명 |
| --- | --- |
| `-j`, `--json` | JSON으로 출력 |
| `-f`, `--force` | 설정 창에서 확인을 묻는 변경도 진행 |
| `-w`, `--wait` | `source` 전환이 끝날 때까지 대기 (최대 1초) |
| `--no-alert` | 오류를 창으로 띄우지 않고 결과로만 출력 |

### 일시정지와 끄기

`pause`는 키 매핑과 키 처리만 잠깐 끕니다. 한영 키가 원래 키(우측 ⌘ 등)로 돌아오고, Space 조합·길게 누르기·ESC·특수문자 처리도 멈춥니다.

시스템 단축키와 입력 메뉴는 건드리지 않아서 몇 ms 만에 끝납니다. 앱이나 창이 바뀔 때마다 불러도 괜찮습니다.

- 일시정지는 저장되지 않습니다. 앱을 다시 실행하거나 `resume`, `enable`하면 풀립니다.
- 일시정지 중에는 메뉴바 메뉴의 `활성화`가 꺼진 것으로 보이고, 누르면 재개됩니다.
- `disable`은 설정 창에서 `활성화`를 끄는 것과 같습니다. 단축키와 입력 메뉴까지 되돌리고 저장해서 수백 ms 걸립니다.

### 입력 소스 전환

```sh
gksdud source ko          # 한국어 (최근에 쓴 한국어 입력 소스)
gksdud source en          # 영어
gksdud source toggle      # 한영 키를 누른 것처럼
gksdud source com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese
gksdud source ABC         # 이름, ID 끝부분이나 일부도 가능
gksdud source             # 현재 입력 소스 ID
```

- gksdud가 켜져 있으면 한영 키와 같은 방식(시스템의 이전 입력 소스 단축키)으로 전환합니다. 일본어·중국어 같은 입력기도 쓰고 있는 앱에 바로 반영됩니다. 일시정지 중에도 됩니다.
- gksdud가 꺼져 있으면 입력 소스를 직접 선택합니다. 이 경우 입력기는 바로 반영되지 않을 수 있습니다.
- 입력 소스 추가를 쓰지 않을 때 `source`로 한국어나 영어로 바꾸면, 이후 한영 키는 한국어↔영어로 전환됩니다. 다른 입력 소스로 바꾸면 한영 키로 원래 입력 소스로 돌아옵니다.
- 전환 요청만 보내고 바로 끝납니다. 전환 직후 글자를 입력하는 스크립트라면 `--wait`를 붙여 주세요.

## 설정

`gksdud help settings`로도 볼 수 있습니다. 설정 창에서 바꿀 때와 똑같이 검사하고 적용합니다.

| 설정 | 값 | 설정 창 |
| --- | --- | --- |
| `active` | `on`, `off` | 활성화 |
| `paused` | `on`, `off` | (CLI 전용) 일시정지 |
| `login` | `on`, `off` | 로그인 시 시작 |
| `keys` | `<키>,...` | 한영 키 |
| `target` | `F13` ~ `F20` | 고급 설정 → 내부 전환 키 |
| `keyboard-default` | `on`, `off` | 고급 설정 → 기본값 |
| `menubar` | `on`, `off` | 메뉴바에 표시 |
| `replace-input-menu` | `on`, `off` | Mac 입력기 아이콘 대체 |
| `icon-case` | `on`, `off` | 대소문자를 영문 아이콘에 반영 |
| `icon` | `dud`, `a`, `ko-en`, `character` | 메뉴바 아이콘 |
| `long-press` | `on`, `off` | 길게 눌러 대소문자 전환 |
| `preserve-case` | `on`, `off` | 한영 전환시 대소문자 보존 |
| `korean-caps-lock` | `on`, `off` | 한글 상태에서도 Caps Lock으로 대소문자 전환 |
| `special-chars` | `off`, `english`, `block` | 특수문자 (끔, 영어처럼 특수문자 입력, Option 문자 입력 차단) |
| `added-sources` | `on`, `off` | 입력 소스 추가 → 활성화 |
| `added-mode` | `cycle`, `separate` | 입력 소스 추가 → 전환 방식 (순회, 분리) |
| `cycle` | `<입력 소스>,...` | 입력 소스 추가 → 순서 |
| `separate-key` | `<키>`, `none` | 입력 소스 추가 → 전환 키 |
| `separate-source` | `<입력 소스>`, `none` | 입력 소스 추가 → 입력 소스 |
| `compatibility` | `on`, `off` | 입력 소스 추가 → 호환성 모드 |
| `escape` | `on`, `off` | ESC 누를 시 영소문자로 변경 |
| `keyboard.<키보드>.mode` | `on`, `default`, `off` | 고급 설정 → 키보드별 적용 |
| `keyboard.<키보드>.keys` | `<키>,...`, `default` | 고급 설정 → 키보드별 한영 키 |

- `<키>`: `right-command`, `right-option`, `caps-lock`, `right-control`, `ctrl-space`, `cmd-space`, `opt-space`, `shift-space`. 키보드별 한영 키는 앞의 네 개(단일키)만 가능합니다.
- `<키보드>`: `gksdud keyboards`에 나오는 ID 앞부분(4자 이상), 이름, 이름 일부. `*`는 모든 키보드입니다. 이름이 같은 키보드는 함께 바뀝니다. 이름에 공백이 있으면 전체를 따옴표로 감싸 주세요: `"keyboard.Magic Keyboard.mode=off"`
- `<입력 소스>`: `gksdud sources`의 ID, 이름, ID 끝부분이나 일부. `ko`·`en`은 최근에 쓴 한국어·영어 입력 소스입니다.
- on/off 대신 `true`/`false`, `yes`/`no`, `1`/`0`도 가능합니다.

```sh
gksdud set keys=right-command,caps-lock      # 한영 키 두 개
gksdud set keys+=shift-space                  # 하나 추가
gksdud set keys-=caps-lock                    # 하나 제거
gksdud set added-sources=on added-mode=cycle cycle=ko,ABC,Japanese
gksdud set "keyboard.Magic Keyboard.mode=off"
gksdud set 'keyboard.*.keys=default'       # *는 셸이 해석하지 않게 따옴표로
```

### 여러 설정을 함께 바꿀 때

- 적은 순서대로 적용합니다. 다른 설정이 먼저 필요한 항목(예: `preserve-case`가 켜져 있어야 하는 `korean-caps-lock`)은 나머지를 적용한 뒤 다시 시도하니, 순서는 신경 쓰지 않아도 됩니다.
- 알 수 없는 설정, 형식이 틀린 값, 없는 키보드나 입력 소스가 하나라도 있으면 아무것도 바꾸지 않습니다. (종료 코드 2)
- 한영 키를 모두 빼거나 순회할 입력 소스가 2개보다 적어지는 것처럼 지금 설정에 따라 정해지는 문제는 그 항목만 실패합니다.
- 설정 창에서 확인을 묻는 변경은 `--force`를 붙여야 진행됩니다. `korean-caps-lock`이 켜진 채로 Caps Lock을 한영 키로 바꾸거나, 다른 앱이 매핑한 키를 한영 키로 쓰는 경우 등입니다. `--force`가 없으면 그 항목만 실패하고 이유를 알려줍니다.
- 설정 창에서 오류 창이 뜨는 경우(단축키 적용 실패, 분리 전환 키가 한영 키와 겹침 등)에는 결과와 함께 gksdud 창에도 띄웁니다. 창이 뜨지 않게 하려면 `--no-alert`를 붙입니다.
- 다른 설정이 함께 바뀌면 `함께 바뀜`(JSON `also`)으로 알려줍니다. 뒤 항목이 앞 항목을 되돌리면 앞 항목은 실패로 표시됩니다.
- 접근성 권한이 없으면 설정 창과 마찬가지로 대부분의 설정을 바꿀 수 없습니다.

## 결과

```text
$ gksdud set long-press=on keys=caps-lock --force
✓ long-press: off → on
✓ keys: right-command → caps-lock
    함께 바뀜 korean-caps-lock: on → off
    경고 진행: Caps Lock을 한영 키로 사용합니다. '한글 상태에서도 Caps Lock으로 대소문자 전환' 기능이 꺼집니다.
키보드 2대 적용
성공 2, 실패 0
```

키보드 줄은 현재 키보드 매핑 상태입니다. 실패한 키보드가 있으면 이름과 이유가 함께 나옵니다. 키보드는 1초마다 다시 시도하기 때문에 종료 코드에는 반영하지 않습니다.

| 종료 코드 | 의미 |
| --- | --- |
| 0 | 모두 성공 |
| 1 | 실패한 항목이 있음 |
| 2 | 잘못된 명령이나 인자 (아무것도 바꾸지 않음) |
| 3 | gksdud가 꺼져 있거나 응답 없음 |

`--json`을 붙이면 모든 결과에 `ok`(성공 여부)가 들어가고, 실패하면 `error`도 붙습니다.

```json
{
  "ok": true,
  "succeeded": 2,
  "failed": 0,
  "results": [
    { "setting": "long-press", "ok": true, "changed": true, "before": false, "after": true },
    { "setting": "keys", "ok": true, "changed": true, "before": ["right-command"], "after": ["caps-lock"],
      "also": [{ "setting": "korean-caps-lock", "before": true, "after": false }],
      "warnings": ["Caps Lock을 한영 키로 사용합니다. ..."] }
  ],
  "keyboards": { "selected": 2, "applied": 2, "failed": 0, "failures": [] }
}
```

- 값은 on/off는 `true`/`false`, 목록은 배열, `none`·`default`는 `null`로 나옵니다.
- 키보드 설정 결과에는 `keyboard: { id, name }`, 실패한 항목에는 `error`가 붙습니다.
- `gksdud help settings --json`으로 설정 목록을 JSON으로 볼 수 있습니다.

| 명령 | 담기는 필드 |
| --- | --- |
| `get` | `settings` |
| `status` | `version`, `active`, `paused`, `accessibility`, `source`, `keyboards`, `issues` |
| `sources` | `sources` |
| `keyboards` | `keyboards` |
| `source` | `from`, `to`, `switched`, `method`(`shortcut`·`select`), `landed`(`--wait`일 때) |

## 예

### Hammerspoon: 특정 앱을 쓰는 동안 일시정지

원격 데스크톱이나 가상 머신에 한영 키를 그대로 넘기고 싶을 때 유용합니다. `~/.hammerspoon/init.lua`에 추가합니다.

```lua
local gksdud = "/usr/local/bin/gksdud"
-- 일시정지할 앱의 번들 ID. osascript -e 'id of app "앱 이름"'으로 확인할 수 있습니다.
local pauseIn = {
  ["com.apple.ScreenSharing"] = true,
  ["com.microsoft.rdc.macos"] = true,
  ["com.utmapp.UTM"] = true,
}
-- 앞의 명령이 끝난 뒤 마지막으로 원한 상태만 보내서, 앱을 빠르게 오가도 순서가 뒤바뀌지 않습니다.
local wantPaused, sentPaused, sending = false, false, false

local function sendGksdudPaused()
  if sending or wantPaused == sentPaused then return end
  sending, sentPaused = true, wantPaused
  hs.task.new(gksdud, function() sending = false; sendGksdudPaused() end, { sentPaused and "pause" or "resume" }):start()
end

local function setGksdudPaused(paused)
  wantPaused = paused
  sendGksdudPaused()
end

-- 전역 변수로 둬야 가비지 컬렉션되지 않습니다.
gksdudWatcher = hs.application.watcher.new(function(_, event, app)
  if event == hs.application.watcher.activated then
    setGksdudPaused(pauseIn[app:bundleID()] == true)
  end
end):start()
```

### Hammerspoon: 특정 창에서만 일시정지

창 제목으로 고르는 방법입니다. 위의 `setGksdudPaused`를 그대로 씁니다.

```lua
gksdudWindows = hs.window.filter.new(function(win)
  local title = win:title() or ""
  return title:find("Remote Desktop") ~= nil or title:find("원격") ~= nil
end)
gksdudWindows:subscribe(hs.window.filter.windowFocused, function() setGksdudPaused(true) end)
gksdudWindows:subscribe(hs.window.filter.windowUnfocused, function() setGksdudPaused(false) end)
```

### Hammerspoon: 단축키로 일시정지 토글

```lua
hs.hotkey.bind({ "ctrl", "alt" }, "G", function()
  hs.task.new("/usr/local/bin/gksdud", function(_, out) hs.alert.show(out) end, { "toggle", "paused" }):start()
end)
```

### Karabiner-Elements: 입력 소스별 단축키

`⌘⌥1`·`⌘⌥2`·`⌘⌥3`으로 한국어·영어·일본어로 바꿉니다. Complex Modifications에 규칙으로 추가합니다.

```json
{
  "description": "⌘⌥1/2/3: 한국어/영어/일본어 (gksdud)",
  "manipulators": [
    { "type": "basic", "from": { "key_code": "1", "modifiers": { "mandatory": ["command", "option"] } },
      "to": [{ "shell_command": "/usr/local/bin/gksdud source ko" }] },
    { "type": "basic", "from": { "key_code": "2", "modifiers": { "mandatory": ["command", "option"] } },
      "to": [{ "shell_command": "/usr/local/bin/gksdud source en" }] },
    { "type": "basic", "from": { "key_code": "3", "modifiers": { "mandatory": ["command", "option"] } },
      "to": [{ "shell_command": "/usr/local/bin/gksdud source com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese" }] }
  ]
}
```

### 셸

```sh
gksdud get active                              # on
gksdud status --json | jq -r .source.id        # 현재 입력 소스
gksdud set escape=on --json | jq .ok           # true
```
