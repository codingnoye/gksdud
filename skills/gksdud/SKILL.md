---
name: gksdud
description: Control gksdud, the macOS Korean/English (한영) input switcher, through its `gksdud` command - read or change its settings, pause it while certain apps or windows are in front, and switch input sources from scripts. Use when the user wants gksdud to behave differently per app or window (for example off in a remote desktop or VM), wants hotkeys for input sources, or wants to automate gksdud with Hammerspoon, Karabiner-Elements, skhd, Raycast or shell scripts. 한영 전환, 입력 소스 전환, gksdud 일시정지·설정 자동화.
---

# gksdud CLI

gksdud는 한영 키를 F-키로 매핑하고 시스템 단축키로 전환하는 메뉴바 앱입니다. `gksdud` 명령은 실행 중인 앱에 요청을 보내고, 앱이 설정 창과 같은 경로로 검사·적용한 결과를 돌려줍니다. 전체 문서: https://github.com/codingnoye/gksdud/blob/main/docs/cli.md

## 먼저 확인

```sh
command -v gksdud || ls -l /usr/local/bin/gksdud /Applications/gksdud.app/Contents/Helpers/gksdud
gksdud status --json          # 종료 코드 3이면 앱이 꺼져 있음 → gksdud start
gksdud help settings --json   # 설정 이름, 값, 설명
gksdud get --json             # 지금 값
gksdud sources --json         # 켜져 있는 입력 소스 ID
gksdud keyboards --json       # 키보드 ID, 이름, 키보드별 설정
```

- 명령이 없으면 사용자에게 설정 → 추가기능 → `CLI 설치`를 안내하거나, 동의를 받아 `sudo mkdir -p /usr/local/bin && sudo ln -sf /Applications/gksdud.app/Contents/Helpers/gksdud /usr/local/bin/gksdud`를 실행합니다.
- gksdud를 실행한 사용자 계정으로 실행해야 앱을 찾습니다. 다른 계정에서는 종료 코드 3이 나옵니다.
- 추측하지 말고 `help settings --json`과 `get --json`으로 이름과 값을 확인합니다. 설정 이름을 문서에서 지어내지 않습니다.

## 명령 요약

| 명령 | 용도 |
| --- | --- |
| `get [<설정>...]` | 조회. 하나면 값만 출력 |
| `set <설정>=<값>... [--force]` | 바꾸고 바로 적용. 목록은 `+=`/`-=` |
| `toggle <설정>...` | on/off 반전 |
| `pause` / `resume` | 일시정지/재개. 몇 ms, 저장 안 됨 |
| `enable` / `disable` | 활성화 켜기/끄기. 저장됨, 수백 ms. `enable`은 일시정지도 해제 |
| `source <ko\|en\|toggle\|ID\|이름> [--wait]` | 입력 소스 전환 |
| `status`, `sources`, `keyboards` | 상태, 목록 |
| `start`, `quit` | 앱 실행, 종료 |

모든 명령에 `--json`을 붙이면 `{"ok": ..., ...}`를 출력합니다. 종료 코드: 0 성공, 1 실패 항목 있음, 2 잘못된 인자(아무것도 안 바뀜), 3 앱이 실행 중이 아님.

## 규칙

- **창·앱 포커스에 따라 끄고 켤 때는 `pause`/`resume`**을 씁니다. `disable`/`enable`은 시스템 단축키와 입력 메뉴까지 되돌리고 저장하므로 느리고, 사용자의 저장된 설정을 바꿉니다. 일시정지는 `resume`, `enable`, 앱 재실행, 메뉴바 메뉴의 `활성화`로 풀립니다.
- 비동기로 보낼 때는 앞의 명령이 끝난 뒤 다음을 보냅니다. 따로 띄운 프로세스는 순서가 뒤바뀔 수 있습니다. 같은 상태는 반복해서 보내지 않습니다.
- 셸에서 `keyboard.*`처럼 `*`가 든 인자는 따옴표로 감쌉니다.
- 설정 여러 개는 한 번의 `set`에 모읍니다. 서로 필요한 순서는 앱이 알아서 맞춥니다.
- 결과의 `results[].ok`, `also`(함께 바뀐 설정), `warnings`(--force로 넘긴 경고)를 확인해 사용자에게 알립니다. `keyboards.failures`는 키보드 매핑 실패이며 앱이 1초마다 다시 시도합니다.
- 실패한 변경 중 설정 창이라면 오류 창이 뜨는 것은 기본으로 gksdud 창도 띄웁니다. 사용자가 보고 있지 않은 자동화(포커스 감시 등)에서는 `--no-alert`로 창을 띄우지 않고 결과의 `error`를 확인합니다.
- 설정 창이 확인을 묻는 변경은 `--force` 없이는 실패하고 `error`에 이유가 나옵니다. 이유를 사용자에게 보여주고, 동의를 받은 뒤에만 `--force`로 다시 실행합니다.
- 접근성 권한이 없으면(`status`의 `accessibility: false`) 대부분 바꿀 수 없습니다. 사용자에게 gksdud 설정의 `접근성 권한 허용`을 안내합니다.
- Hammerspoon·Karabiner·skhd 등은 `PATH`가 짧으니 `/usr/local/bin/gksdud` 전체 경로를 씁니다. Hammerspoon에서는 메인 스레드를 막지 않도록 `hs.execute` 대신 `hs.task`를 씁니다.
- `source`는 gksdud가 켜져 있으면 한영 키와 같은 시스템 단축키 경로로 전환해 입력기도 앞 앱에 반영됩니다. 전환 직후 글자를 보내야 하면 `--wait`를 붙이고 `landed`를 확인합니다.
- 사용자 설정 파일(`~/.hammerspoon/init.lua`, `~/.config/karabiner/karabiner.json` 등)은 덮어쓰지 말고 필요한 부분만 추가하며, 바꾸기 전에 내용을 보여주거나 백업합니다.

## 예: 특정 앱이나 창이 앞에 있는 동안 gksdud 끄기

원격 데스크톱·가상 머신·게임처럼 한영 키를 그 안으로 넘겨야 하는 앱에서 씁니다. 번들 ID는 `osascript -e 'id of app "앱 이름"'`으로 확인합니다.

```lua
-- ~/.hammerspoon/init.lua
local gksdud = "/usr/local/bin/gksdud"
local pauseIn = { ["com.apple.ScreenSharing"] = true, ["com.microsoft.rdc.macos"] = true }
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

gksdudWatcher = hs.application.watcher.new(function(_, event, app)
  if event == hs.application.watcher.activated then
    setGksdudPaused(pauseIn[app:bundleID()] == true)
  end
end):start()
```

창 제목으로 고르려면 `hs.window.filter`를 씁니다.

```lua
gksdudWindows = hs.window.filter.new(function(win) return (win:title() or ""):find("Remote") ~= nil end)
gksdudWindows:subscribe(hs.window.filter.windowFocused, function() setGksdudPaused(true) end)
gksdudWindows:subscribe(hs.window.filter.windowUnfocused, function() setGksdudPaused(false) end)
```

적용 후 확인:

1. Hammerspoon 설정을 다시 불러옵니다(`hs.reload()` 또는 메뉴의 Reload Config).
2. 대상 앱을 앞으로 가져온 뒤 `gksdud get paused`가 `on`인지, 다른 앱으로 돌아오면 `off`인지 봅니다.
3. 일시정지 중에는 한영 키(예: 우측 ⌘)가 원래 키로 동작합니다.

## 예: 입력 소스 단축키 (Karabiner-Elements)

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

입력 소스 ID는 `gksdud sources`로 확인합니다. Karabiner의 `select_input_source`는 입력기가 앞 앱에 반영되지 않는 경우가 있어, gksdud가 켜져 있다면 `gksdud source`가 낫습니다.

## 예: 설정 바꾸기

```sh
gksdud set long-press=on preserve-case=on korean-caps-lock=on
gksdud set keys+=shift-space
gksdud set added-sources=on added-mode=cycle cycle=ko,en,com.apple.inputmethod.SCIM.ITABC
gksdud set "keyboard.Magic Keyboard.mode=off"   # 이 키보드에는 적용하지 않음
gksdud toggle escape --json
```
