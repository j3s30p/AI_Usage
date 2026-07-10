# AiUsage

Codex와 Claude의 **현재 5시간 사용 창에서 남은 비율**을 macOS 메뉴바에 표시하는 로컬 앱입니다.

```text
Codex · [도넛 링] 23% │ Claude · [도넛 링] 48%
```

![AiUsage 실제 사용 화면](docs/images/aiusage-live-usage.png)

- 100%일 때 완전한 원이며, 남은 양이 줄수록 12시 방향부터 시계 방향으로 선이 사라집니다.
- 설정에서 Codex와 Claude를 각각 켜거나 끌 수 있습니다.
- 퍼센트 문구도 별도로 켜거나 끌 수 있습니다.
- 메뉴바는 현재 5시간 창만 표시하고, 팝오버는 5시간·주간 한도를 함께 보여 줍니다.
- 표시상 0%가 되면 원형 링에만 빨간 1° 호를 남깁니다.
- 5분마다 자동 갱신하며 메뉴에서 즉시 새로 고칠 수 있습니다.
- 메뉴를 열면 5시간 한도와 주간 한도를 함께 표시합니다.
- 이름/공식 로고 표시 방식을 설정에서 바꿀 수 있습니다.

## 요구 사항

- macOS 14 이상
- Codex CLI 설치 및 로그인
- Claude를 표시하려면 Claude Code 설치와 Claude.ai Pro/Max 로그인

Claude의 `rate_limits`는 Pro/Max 구독 세션의 첫 응답 이후 제공됩니다. API 키 세션에는
공유 구독 한도가 없어 Claude 사용량 표시를 지원하지 않습니다.

## 빌드 및 실행

```bash
xcodebuild -project AiUsage.xcodeproj -scheme AiUsage -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AiUsage.app
```

## Claude 공식 statusLine 연동

Claude Code는 구독 사용량을 비대화식 CLI 명령으로 제공하지 않습니다. AiUsage는 공식
`statusLine` JSON의 `rate_limits.five_hour`와 `rate_limits.seven_day`만 로컬 캐시에 저장해
읽습니다. Keychain 토큰이나 비공개 usage endpoint는 사용하지 않습니다.

```bash
install -m 700 Scripts/claude-statusline-aiusage.sh ~/.claude/statusline-aiusage.sh
```

기존 `statusLine` 설정이 없다면 `~/.claude/settings.json`에 다음 항목을 추가합니다.

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline-aiusage.sh",
    "refreshInterval": 10
  }
}
```

기존 statusLine이 있다면 덮어쓰지 말고 기존 명령을 감싸도록 스크립트를 병합해야 합니다.
Claude Code에서 첫 응답을 받은 뒤 `~/.claude/usage-cache.json`이 생성됩니다. 캐시에는
사용률·초기화 시각·캡처 시각만 저장하며 세션 ID, 프롬프트, 작업 경로는 저장하지 않습니다.
Claude Code가 실행되지 않으면 마지막 값이 유지됩니다. 15분이 지난 캐시나 초기화 시각이
지난 캐시는 메뉴바에서 미확인 상태로 바꾸고, 팝오버에는 마지막 값과 `오래된 캐시` 안내를
함께 표시합니다.

## 데이터 경로

- Codex: 로컬 `codex app-server`의 공식 `account/rateLimits/read`에서 300분·10,080분 창을 읽습니다.
- Claude: Claude Code 공식 statusLine 캐시에서 `five_hour`·`seven_day`를 읽습니다.

메뉴바에는 5시간 값만 사용하며 팝오버에서 주간 값과 초기화 시각을 함께 보여줍니다.

## 브랜드 자산

Codex에는 별도로 배포된 공식 제품 로고가 없어 OpenAI 공식 Blossom을 사용합니다. Claude는
`claude.com`의 공식 제품 SVG를 사용합니다. 출처, 원본 해시, 상표 조건은
[`BRAND_ASSETS.md`](BRAND_ASSETS.md)에 기록했습니다.
