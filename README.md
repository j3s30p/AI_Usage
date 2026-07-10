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
- 기본 3분마다 자동 갱신하며 설정에서 1·3·5·15·30분 중 선택할 수 있습니다.
- 메뉴를 열면 5시간 한도와 주간 한도를 함께 표시합니다.
- 이름/공식 로고 표시 방식을 설정에서 바꿀 수 있습니다.

## 요구 사항

- macOS 14 이상
- Codex CLI 설치 및 로그인
- Claude를 표시하려면 Claude Code 설치와 Claude.ai Pro/Max 로그인

Claude의 5시간·주간 구독 한도는 Claude.ai Pro/Max 로그인에서 제공됩니다. API 키 세션에는
공유 구독 한도가 없어 이 화면의 구독 사용량 표시를 지원하지 않습니다.

## 빌드 및 실행

```bash
xcodebuild -project AiUsage.xcodeproj -scheme AiUsage -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AiUsage.app
```

## Claude 사용량 조회

AiUsage는 다음 순서로 Claude 사용량을 조회합니다.

1. 기존 Claude Code OAuth 자격으로 `api.anthropic.com/api/oauth/usage` 조회
2. OAuth를 사용할 수 없으면 도구 권한을 끈 안전 모드의 Claude CLI에서 `/usage` 조회
3. CLI도 사용할 수 없으면 공식 `statusLine` 캐시 사용

OAuth 자격은 `~/.claude/.credentials.json`을 먼저 확인하고, 없으면 macOS의
`Claude Code-credentials` 키체인 항목을 **팝업 없는 비대화식 모드**로 확인합니다. 이미
접근이 허용된 경우에만 OAuth를 사용하며, macOS 승인이 필요한 상태라면 창을 띄우지 않고 즉시
CLI/statusLine으로 넘어갑니다. 따라서 자동 갱신 때문에 키체인 확인 창이 반복되지 않습니다.

OAuth usage 경로는 Anthropic의 공개 API 문서에 포함된 엔드포인트가 아니므로 향후 변경될 수
있습니다. 이 경우에도 CLI와 statusLine 폴백은 계속 동작합니다. 토큰, 계정 이메일, CLI 원문은
로그나 캐시에 저장하지 않습니다.

### statusLine 폴백 설정

OAuth와 CLI를 사용할 수 없는 환경에서도 표시하려면 다음 공식 statusLine 연동을 사용할 수
있습니다.

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
Claude Code가 실행되지 않으면 마지막 값이 유지됩니다. 마지막 성공 조회가 선택한 갱신 주기를
충분히 넘기거나 초기화 시각이 지나면 메뉴바에서 미확인 상태로 바꾸고, 팝오버에는 마지막 값과
`업데이트 지연` 안내를 함께 표시합니다.

## 데이터 경로

- Codex: 선택되어 있는 동안 로컬 `codex app-server` 연결 하나를 유지하고, 선택한 주기마다 공식
  `account/rateLimits/read`에서 300분·10,080분 창을 읽습니다. 연결이 끊기면 백오프로 재연결합니다.
- Claude: Claude Code OAuth usage API를 우선 사용하고, Claude CLI `/usage`, 공식 statusLine 캐시
  순으로 폴백해 `five_hour`·`seven_day`를 읽습니다.

메뉴바에는 5시간 값만 사용하며 팝오버에서 주간 값과 초기화 시각을 함께 보여줍니다.

## 브랜드 자산

Codex에는 별도로 배포된 공식 제품 로고가 없어 OpenAI 공식 Blossom을 사용합니다. Claude는
`claude.com`의 공식 제품 SVG를 사용합니다. 출처, 원본 해시, 상표 조건은
[`BRAND_ASSETS.md`](BRAND_ASSETS.md)에 기록했습니다.
