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
- Claude 조회는 안전한 `statusLine` 캐시가 기본이며, OAuth와 CLI 방식은 사용자가 설정에서
  직접 선택하는 실험 기능입니다.

## 설치

```bash
brew install --cask j3s30p/tap/aiusage
open -a AiUsage
```

현재 `0.1.0`은 Developer ID 서명·Apple 공증 전의 프리뷰입니다. Homebrew 설치는 가능하지만
macOS가 첫 실행을 막으면 앱 실행을 한 번 시도한 뒤 `시스템 설정 → 개인정보 보호 및 보안 →
확인 없이 열기`를 선택해야 합니다. 자세한 절차는 [Apple 안내](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)를
참고하세요. AiUsage나 Homebrew가 Gatekeeper를 자동으로 우회하지는 않습니다.

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

- `statusLine 캐시 (권장)`: Keychain이나 로그인 절차 없이 로컬 캐시만 읽습니다.
- `OAuth Keychain (실험적)`: 무팝업 OAuth 조회 후 실패하면 statusLine으로 돌아갑니다.
- `CLI /usage (실험적)`: 로그인 상태를 먼저 확인한 뒤 `/usage`를 실행하고, 실패하면
  statusLine으로 돌아갑니다.

기본값은 statusLine입니다. Claude Desktop·웹만 사용하면 이 캐시는 실시간으로 갱신되지 않을 수
있습니다. 각 모드의 정확한 데이터 흐름, Keychain 정책, 서명 제한과 개인정보 처리 방식은
[`docs/architecture.md`](docs/architecture.md)에 정리했습니다.

## statusLine 캐시 설정

기본 모드와 실험 모드의 폴백을 사용하려면 다음 statusLine 연동을 설정합니다. Homebrew로
설치했다면 함께 배포되는 도우미를 복사합니다.

```bash
install -m 700 "$(brew --prefix)/bin/aiusage-claude-statusline" \
  ~/.claude/statusline-aiusage.sh
```

소스 체크아웃에서 직접 빌드했다면 저장소의 스크립트를 복사합니다.

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

## 문서

- [기술 구조와 데이터 소스](docs/architecture.md)
- [브랜드 자산과 출처](BRAND_ASSETS.md)

## 브랜드 자산

Codex에는 별도로 배포된 공식 제품 로고가 없어 OpenAI 공식 Blossom을 사용합니다. Claude는
`claude.com`의 공식 제품 SVG를 사용합니다. 출처, 원본 해시, 상표 조건은
[`BRAND_ASSETS.md`](BRAND_ASSETS.md)에 기록했습니다.
