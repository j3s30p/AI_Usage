<p align="right"><a href="README.md">English</a> | 한국어</p>

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

- **Codex와 Claude를 한곳에서** — 두 서비스의 사용량을 하나의 메뉴바 앱에서 확인합니다.
- **5시간·주간 한도 확인** — 남은 비율과 초기화 시각을 한눈에 보여 줍니다.
- **내게 맞는 메뉴바** — 서비스 이름이나 로고, 퍼센트, 갱신 주기와 사용량별 도넛 색상을 선택할 수 있습니다.
- **안정적인 백그라운드 확인** — 일시적인 실패에도 최근 정상값을 유지하고 로그인 시 자동으로 실행할 수 있습니다.

![Codex와 Claude 남은 사용량을 표시하는 AiUsage 메뉴바](docs/images/aiusage-menubar.png)

## 설치

### Homebrew

```bash
brew install --cask j3s30p/tap/aiusage
open -a AiUsage
```

기존 설치를 업데이트하려면 다음 명령을 실행하세요.

```bash
brew upgrade --cask aiusage
```

### 직접 설치

[최신 GitHub Release](https://github.com/j3s30p/AI_Usage/releases/latest)에서 macOS universal ZIP을
내려받아 압축을 풀고 `AiUsage.app`을 응용 프로그램 폴더로 옮기세요.

배포 앱은 Developer ID Application으로 서명하고 Apple 공증을 완료합니다. Apple Silicon과
Intel Mac을 모두 지원합니다.

## 첫 실행

1. 메뉴바의 AiUsage를 눌러 **설정**을 엽니다.
2. **일반** 탭에서 앱 동작과 Claude 연결을 설정하고 현재 버전과 최신 버전을 확인합니다. **메뉴바** 탭에서는 표시할 서비스, 표시 방식, 갱신 주기와 사용량별 도넛 색상을 선택합니다.
3. Codex는 로컬 Codex CLI에 로그인되어 있으면 별도 연결 없이 조회합니다.
4. Claude는 기본값인 `statusLine 캐시`에서 **Claude statusLine 연결…**을 한 번 누르고 변경에
   동의하세요. 명령어 입력이나 설정 파일 직접 수정은 필요하지 않습니다.

Claude statusLine은 연결 후 Claude Code의 다음 응답부터 최신 사용량을 전달합니다. 기존
statusLine을 안전하게 보존하고 연결 해제 시 복원합니다. 호환되는 Claude Code 자격이 있다면
실험적 OAuth 모드도 사용할 수 있습니다.

AiUsage는 실행 시점과 이후 24시간마다 서명된 Sparkle appcast에서 최신 버전을 확인합니다. 새 버전이 있으면 메뉴바 팝오버에 업데이트 버튼이 나타나며, 버튼을 누르면 Sparkle의 검증된 업데이트 절차가 열립니다.

## 개인정보와 macOS 권한

AiUsage는 자체 서버나 분석 SDK를 사용하지 않습니다.

- Codex와 Claude statusLine 데이터는 로컬에서 읽습니다.
- 프롬프트, 대화 내용, 계정 이메일, 세션 ID와 작업 경로를 수집하거나 기록하지 않습니다.
- 화면 기록과 손쉬운 사용 권한은 필요하지 않습니다.

자세한 데이터 흐름과 보안 경계는 [기술 구조와 데이터 소스](docs/architecture.md)에서 확인할 수
있습니다.

## 요구 사항

- macOS 14 Sonoma 이상
- Codex 표시: Codex CLI 설치 및 로그인
- Claude 표시: Claude Code 설치 및 Claude.ai Pro 또는 Max 로그인

공유 구독 한도가 없는 Claude API 키 세션은 지원하지 않습니다.

## 문서

- [기술 구조와 데이터 소스](docs/architecture.md)
- [유지보수자 릴리스 절차](docs/releasing.md)
- [브랜드 자산과 출처](BRAND_ASSETS.md)

---

AiUsage는 OpenAI 또는 Anthropic이 제작하거나 보증하는 제품이 아닙니다. Codex, OpenAI, Claude와
Anthropic의 상표 및 로고는 각 소유자에게 귀속됩니다.
