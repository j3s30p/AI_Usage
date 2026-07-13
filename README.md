<p align="center">
  <img src="docs/images/aiusage-app-icon.png" width="112" alt="AiUsage 앱 아이콘">
</p>

<h1 align="center">AiUsage</h1>

<p align="center">
  Codex와 Claude의 남은 사용량을 macOS 메뉴바에서 바로 확인하세요.
</p>

<p align="center">
  <a href="https://github.com/j3s30p/AI_Usage/releases/latest"><img src="https://img.shields.io/github/v/release/j3s30p/AI_Usage?display_name=tag&sort=semver" alt="최신 릴리스"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14 이상">
  <img src="https://img.shields.io/badge/Homebrew-Cask-FBB040?logo=homebrew&logoColor=000000" alt="Homebrew Cask">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
</p>

![AiUsage 실제 사용 화면](docs/images/aiusage-live-usage.png)

AiUsage는 Codex와 Claude가 제공하는 현재 사용 한도를 한곳에 보여 주는 네이티브 macOS
메뉴바 앱입니다. 앱을 전환하거나 명령어를 입력하지 않아도 남은 비율과 초기화 시각을 확인할
수 있습니다.

## 주요 기능

- **한눈에 보는 남은 사용량** — 메뉴바의 도넛 링과 선택 가능한 퍼센트로 현재 상태를 표시합니다.
- **5시간·주간 한도 확인** — 메뉴바는 5시간 한도를 우선하고, 제공되지 않으면 주간 한도를
  사용합니다. 팝오버에서는 두 한도를 각각 확인할 수 있습니다.
- **Codex와 Claude를 한곳에서** — 원하는 서비스만 표시하거나 두 서비스를 함께 표시할 수
  있습니다.
- **내 취향에 맞는 메뉴바** — 서비스 이름 또는 서비스 로고, 퍼센트 표시 여부를 선택할 수
  있습니다.
- **자동 갱신** — 기본 3분, 필요에 따라 1·3·5·15·30분 간격으로 변경할 수 있습니다.
- **마지막 정상값 유지** — 일시적인 조회 실패로 값이 갑자기 100%가 되거나 사라지지 않도록 유효한
  최근 정상값을 유지합니다.
- **로그인 시 자동 실행** — 별도 도우미나 터미널 명령 없이 macOS 로그인 항목에 등록합니다.

## 설치

### Homebrew

```bash
brew install --cask j3s30p/tap/aiusage
open -a AiUsage
```

기존 설치를 업데이트하려면 다음 명령을 실행하세요.

```bash
brew update
brew upgrade --cask aiusage
```

### 직접 설치

[최신 GitHub Release](https://github.com/j3s30p/AI_Usage/releases/latest)에서 macOS universal ZIP을
내려받아 압축을 풀고 `AiUsage.app`을 응용 프로그램 폴더로 옮기세요.

배포 앱은 Developer ID Application으로 서명하고 Apple 공증을 완료합니다. Apple Silicon과
Intel Mac을 모두 지원합니다.

## 첫 실행

1. 메뉴바의 AiUsage를 눌러 **설정**을 엽니다.
2. 메뉴바에 표시할 서비스와 표시 방식을 선택합니다.
3. Codex는 로컬 Codex CLI에 로그인되어 있으면 별도 연결 없이 조회합니다.
4. Claude는 기본값인 `statusLine 캐시`에서 **Claude statusLine 연결…**을 한 번 누르고 변경에
   동의하세요. 명령어 입력이나 설정 파일 직접 수정은 필요하지 않습니다.

Claude statusLine은 연결 후 Claude Code가 다음 응답을 생성할 때부터 최신 사용량을 전달합니다.
안전하게 보존할 수 있는 기존 statusLine이 있다면 함께 동작하도록 연결하며, AiUsage 연결을
해제하면 원래 설정으로 복원합니다. Claude Desktop이나 claude.ai 웹 사용량을 조회하려면 유효한
Claude Code OAuth 자격이 있는 상태에서 `OAuth Keychain (실험적)`을 선택할 수 있습니다.

## 표시 방식

```text
Codex · [도넛 링] 23% │ Claude · [도넛 링] 48%
```

- 100%일 때 완전한 원이며, 남은 양이 줄수록 12시 방향부터 링이 사라집니다.
- 0%일 때는 빨간색 1° 호를 남겨 한도 소진 상태를 분명하게 표시합니다.
- 아직 연결되지 않은 서비스는 임의의 퍼센트 대신 연결 끊김 기호만 표시합니다.
- 메뉴바를 누르면 5시간·주간 남은 비율과 각 초기화 시각을 확인할 수 있습니다. 계정이 제공하지
  않는 한도는 `제공되지 않음`으로 표시합니다.

## 사용량은 어떻게 가져오나요?

| 서비스 | 조회 방식 | 알아둘 점 |
| --- | --- | --- |
| Codex | 로컬 `codex app-server`의 `account/rateLimits/read` | Codex CLI 설치와 로그인이 필요하며, 추가 로그인 창은 열지 않습니다. |
| Claude statusLine | `~/.claude/usage-cache.json` 로컬 캐시 | 권장 방식입니다. Claude Code가 응답할 때 최신 값으로 갱신됩니다. |
| Claude OAuth | Claude Code의 로컬 자격 저장소와 Anthropic 사용량 경로 | 사용자가 직접 선택할 때만 인증을 확인합니다. 비공개 API에 의존하는 실험적 기능입니다. |

OAuth 조회가 실패하거나 백그라운드에서 자격을 조용히 읽을 수 없으면 로그인 창을 반복해서 띄우지
않고 statusLine 캐시로 돌아갑니다.

## 개인정보와 macOS 권한

AiUsage는 자체 서버나 분석 SDK를 사용하지 않습니다. Codex와 Claude statusLine 데이터는
로컬에서 읽고, Claude OAuth 모드를 선택한 경우에만 Anthropic 사용량 경로로 요청을 보냅니다.

- 사용량 조회 과정에서 계정 이메일, 프롬프트, 대화 내용, 세션 ID, 작업 경로를 새로 수집하거나
  기록하지 않습니다.
- statusLine 캐시에는 사용률, 초기화 시각, 캡처 시각만 저장합니다.
- statusLine 연결 시 기존 Claude 설정을 복원하기 위한 백업을 권한 `0600`으로 로컬에 보관하며,
  사용량 데이터로 읽거나 전송하지 않습니다.
- OAuth 토큰과 서버 오류 본문을 앱 설정이나 로그에 저장하지 않습니다.
- 화면 기록과 손쉬운 사용 권한은 필요하지 않습니다.
- Keychain 승인 요청은 Claude OAuth 모드를 사용자가 직접 선택한 경우에만 시작합니다. 이후 자동
  갱신은 승인 팝업 없이 가능한 범위에서만 동작합니다.
- 로그인 시 자동 실행은 macOS의 `SMAppService`를 사용하며, macOS가 추가 승인을 요청하면 앱에서
  시스템 설정으로 안내합니다.

자세한 데이터 흐름과 보안 경계는 [기술 구조와 데이터 소스](docs/architecture.md)에서 확인할 수
있습니다.

## 문제 해결

### 메뉴바에 연결 끊김 기호가 표시됩니다

- **Codex:** Codex CLI 로그인을 확인한 뒤 팝오버의 새로고침 버튼을 누르세요.
- **Claude statusLine:** 설정에서 연결 상태를 확인하고 Claude Code에서 메시지를 한 번 보내세요.
- **Claude OAuth:** 설정에서 OAuth 모드를 다시 선택해 인증 상태를 확인하세요.

한 번 정상적으로 연결된 서비스는 일시적인 조회 실패 때 최근 값을 유지합니다. 저장된 값이
유효한 시간을 넘기면 잘못된 퍼센트를 추측하지 않고 연결 끊김 상태로 전환합니다.

### 로그인 시 자동 실행을 켤 수 없습니다

설정의 토글을 다시 켜 보세요. macOS 승인이 필요한 경우 표시되는 **시스템 설정 열기** 버튼을
누른 뒤 `일반 > 로그인 항목 및 확장 프로그램`에서 AiUsage를 허용하세요.

## 요구 사항

- macOS 14 Sonoma 이상
- Codex 표시: Codex CLI 설치 및 로그인
- Claude 표시: Claude Code 설치 및 Claude.ai Pro 또는 Max 로그인

공유 구독 한도가 없는 Claude API 키 세션은 지원하지 않습니다.

## 개발

AiUsage는 Swift 6, SwiftUI, AppKit으로 만들었으며 외부 패키지에 의존하지 않습니다.

```bash
xcodebuild -project AiUsage.xcodeproj -scheme AiUsage -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AiUsage.app
```

전체 테스트를 실행하려면 다음 명령을 사용하세요.

```bash
xcodebuild test -project AiUsage.xcodeproj -scheme AiUsage \
  -destination 'platform=macOS'
```

## 문서

- [기술 구조와 데이터 소스](docs/architecture.md)
- [유지보수자 릴리스 절차](docs/releasing.md)
- [브랜드 자산과 출처](BRAND_ASSETS.md)

---

AiUsage는 OpenAI 또는 Anthropic이 제작하거나 보증하는 제품이 아닙니다. Codex, OpenAI, Claude와
Anthropic의 상표 및 로고는 각 소유자에게 귀속됩니다.
