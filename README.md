# AiUsage

Codex와 Claude의 **현재 5시간 사용 창에서 남은 비율**을 macOS 메뉴바에서 확인하는 로컬 앱입니다.

```text
Codex · [도넛 링] 23% │ Claude · [도넛 링] 48%
```

![AiUsage 실제 사용 화면](docs/images/aiusage-live-usage.png)

- 메뉴바에는 현재 5시간 사용량을, 팝오버에는 5시간·주간 한도를 함께 표시합니다.
- 100%일 때 완전한 원이며, 남은 양이 줄수록 12시 방향부터 링이 사라집니다.
- 0%가 되면 원형 링에만 빨간 1° 호를 남깁니다.
- Codex와 Claude, 이름과 공식 로고, 퍼센트 표시를 각각 설정할 수 있습니다.
- 기본 3분마다 갱신하며 1·3·5·15·30분 중 선택할 수 있습니다.

## 설치

```bash
brew install --cask j3s30p/tap/aiusage
open -a AiUsage
```

현재 `0.1.1`은 Developer ID 서명과 Apple 공증 전의 프리뷰입니다. macOS가 첫 실행을 막으면
앱 실행을 한 번 시도한 뒤 `시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기`를 선택하세요.
자세한 내용은 [Apple 안내](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)를
참고하세요.

> 프리뷰 빌드에서는 `로그인 시 AiUsage 자동 실행`을 잠시 비활성화했습니다. Developer ID 서명과
> 공증을 적용한 배포부터 다시 제공할 예정입니다.

## 요구 사항

- macOS 14 이상
- Codex CLI 설치 및 로그인
- Claude를 표시하려면 Claude Code 설치와 Claude.ai Pro/Max 로그인

Claude의 5시간·주간 구독 한도는 Claude.ai Pro/Max 계정에서 제공됩니다. 공유 구독 한도가 없는
API 키 세션은 지원하지 않습니다.

## 사용 방법

Codex는 CLI에 로그인되어 있으면 별도 설정 없이 조회합니다.

Claude는 설정에서 다음 두 방식 중 하나를 선택할 수 있습니다.

- `statusLine 캐시 (권장)`: `Claude statusLine 연결…`을 한 번 누르고 변경에 동의하면 AiUsage가
  필요한 연결을 자동으로 구성합니다. 터미널 명령을 실행하거나 설정 파일을 직접 수정할 필요가
  없습니다. 기존 statusLine은 유지하며 연결 해제 시 원래 설정으로 복원합니다.
- `OAuth Keychain (실험적)`: Claude Desktop·웹 사용량까지 주기적으로 조회해야 할 때 선택할 수
  있습니다. 사용자가 직접 선택한 경우에만 Keychain 승인을 요청하며, 비공개 API이므로 향후
  중단될 수 있습니다.

statusLine 방식은 Claude Code가 응답할 때 갱신됩니다. Claude Desktop이나 웹만 사용한다면 OAuth
방식을 선택하세요.

## 개인정보와 보안

statusLine 캐시에는 사용률·초기화 시각·캡처 시각만 저장합니다. 세션 ID, 프롬프트, 작업 경로는
저장하지 않습니다. OAuth 실험 모드는 Claude Code의 로컬 자격 저장소를 먼저 확인하고 필요할 때만
macOS Keychain을 사용합니다. Keychain 승인은 사용자가 OAuth 모드를 직접 선택할 때만 요청합니다.

정확한 데이터 흐름과 Keychain 정책은 [기술 구조 문서](docs/architecture.md)에서 확인할 수 있습니다.

## 빌드 및 실행

```bash
xcodebuild -project AiUsage.xcodeproj -scheme AiUsage -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AiUsage.app
```

## 문서

- [기술 구조와 데이터 소스](docs/architecture.md)
- [브랜드 자산과 출처](BRAND_ASSETS.md)
