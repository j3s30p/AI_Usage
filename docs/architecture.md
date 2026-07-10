# AiUsage 기술 구조와 데이터 소스

이 문서는 AiUsage의 구현 구조, Codex·Claude 사용량 조회 방식, Keychain과 개인정보 처리 경계를
설명합니다. 일반적인 설치와 사용법은 프로젝트 루트의 [README](../README.md)를 참고하세요.

## 기술 스택

- macOS 14 이상, Swift 6
- SwiftUI 설정 화면과 팝오버
- AppKit `NSStatusItem` 기반 메뉴바 표시
- Observation 기반 앱 상태와 설정 전달
- Foundation `URLSession`, `Process`, Swift Concurrency
- macOS Security·LocalAuthentication 기반 Keychain 조회
- ServiceManagement `SMAppService.mainApp` 기반 로그인 시 자동 실행
- 외부 패키지 의존성 없음

주요 흐름은 다음과 같습니다.

```text
AppPreferences → AppDelegate → AppModel → UsageRepository
                                           ├─ CodexUsageProvider
                                           └─ ClaudeUsageProvider
```

설정값이 바뀌면 기존 모니터를 취소하고 선택한 주기와 Claude 조회 모드로 다시 시작합니다. Claude
조회 모드가 바뀌면 이전 데이터 소스의 snapshot을 즉시 비워, 더 최신이라는 이유만으로 이전
OAuth 값이 새 statusLine 결과를 가리지 않게 합니다.

로그인 시 자동 실행 구현은 별도 도우미나 셸 스크립트 없이 `SMAppService.mainApp`을 사용합니다.
다만 현재 unsigned preview에서는 안정적인 코드 정체성을 보장할 수 없어 설정 토글을 비활성화합니다.
Developer ID 서명과 Apple 공증을 적용한 배포부터 시스템 상태 확인과 등록 기능을 활성화할 예정입니다.

## Codex

Codex가 선택되어 있는 동안 로컬 `codex app-server` 연결 하나를 유지합니다. 선택한 주기마다 공식
`account/rateLimits/read`를 호출해 300분·10,080분 창을 읽고, 연결이 끊기면 백오프로
재연결합니다.

응답에 기본 Codex와 모델별 한도가 함께 있으면 명시적인 `codex` 한도만 사용합니다. 다중 한도
응답에서 기본 Codex 값이 순간적으로 누락되면 Spark 등 다른 모델의 100% 값을 대신 표시하지 않고
조회 실패로 처리합니다. 이때 최근 정상값은 설정한 갱신 주기의 허용 시간 안에서 계속 표시됩니다.

## Claude 조회 모드

두 모드는 사용자가 선택하며, OAuth 모드가 실패했을 때만 statusLine 캐시로 폴백합니다. 기본값은
`statusLine 캐시 (권장)`입니다.

### statusLine 캐시 (권장)

- `~/.claude/usage-cache.json`만 로컬에서 읽습니다.
- AiUsage가 Keychain에 접근하거나 로그인·브라우저 절차를 시작하지 않습니다.
- Claude Code의 공식 [statusLine](https://code.claude.com/docs/en/statusline)이 실행될 때 캐시가
  갱신됩니다.
- Claude Code를 사용하지 않거나 Claude Desktop·웹만 사용하면 마지막 값이 유지되므로 완전한
  실시간 조회 방식은 아닙니다.

데이터 흐름은 다음과 같습니다.

```text
Claude Code → ~/.claude/aiusage/statusline-wrapper.sh
            → statusline-cache.sh
            → ~/.claude/usage-cache.json → AiUsage
```

캐시에는 사용률, 초기화 시각, 캡처 시각만 저장합니다. 세션 ID, 프롬프트, 작업 경로는 저장하지
않습니다.

#### 앱 내부 연결

설정의 `Claude statusLine 연결…` 버튼을 누르고 확인창에서 동의하면 다음 작업을 앱이 수행합니다.

1. 현재 `~/.claude/settings.json`을 읽고 안전하게 보존할 수 있는 형식인지 확인합니다.
2. 변경 전 설정을 권한 `0600`의 전용 백업으로 저장합니다.
3. 앱 번들에 포함된 수집기와 래퍼를 `~/.claude/aiusage/`에 설치합니다.
4. 다른 Claude 설정은 유지하고 `statusLine.command`만 AiUsage 래퍼로 연결합니다.

기존 statusLine 명령이 있으면 권한 `0600`의 전용 파일에 보존하고, 래퍼가 같은 JSON 입력을 기존
명령에도 전달해 기존 표시와 종료 상태를 유지합니다. 연결 해제 시 현재 설정이 AiUsage가 설치한
값과 정확히 일치할 때만 원래 statusLine을 복원합니다. 손상된 JSON, 알 수 없는 statusLine 형식,
심볼릭 링크 또는 연결 후 외부 변경이 감지되면 자동으로 덮어쓰지 않습니다.

### OAuth Keychain (실험적)

- `~/.claude/.credentials.json`이 있으면 먼저 확인하고, 없으면 macOS의
  `Claude Code-credentials` Keychain 항목을 확인합니다.
- 자동 갱신은 `LAContext.interactionNotAllowed`와 명시적인 Keychain UI-fail 정책을 함께 사용해
  승인 창을 금지합니다. 이미 접근 가능한 경우에만 자격을 메모리에서 읽습니다.
- `https://api.anthropic.com/api/oauth/usage` 조회에 실패하거나 Keychain을 조용히 읽을 수 없으면
  statusLine 캐시만 확인하며 로그인 절차를 시작하지 않습니다.
- 사용자가 설정에서 OAuth 모드를 직접 선택하거나 현재 OAuth 항목을 다시 선택하면 사용자 동작
  경계에서 macOS Keychain 승인을 요청합니다. 승인이 성공한 뒤에만 OAuth 모드를 확정하고,
  취소하거나 실패하면 이전 조회 모드를 유지합니다.

`/api/oauth/usage`는 Anthropic의 공개 API 문서에 포함되지 않은 비공개 호환 경로입니다. 응답
형식이 바뀌거나 지원이 중단될 수 있으며 공개 배포 앱의 안정적인 계약으로 간주하지 않습니다.
Anthropic의 현재 [인증·자격증명 정책](https://code.claude.com/docs/en/legal-and-compliance)도 함께
확인해야 합니다.

## Claude Desktop·웹

Claude Desktop과 claude.ai 웹은 AiUsage의 statusLine 캐시를 직접 갱신하지 않습니다. OAuth
실험 모드는 호환되는 Claude Code 자격을 읽을 수 있을 때 계정 사용량을 반영할 수 있지만 비공개
API에 의존합니다. AiUsage는 브라우저 쿠키나 Claude Desktop 내부 저장소를 읽지 않습니다.

## Keychain과 코드 서명

현재 프리뷰와 로컬 개발 빌드는 ad-hoc 서명입니다. Homebrew로 파일을 설치할 수는 있지만
Apple 공증 전이므로 첫 실행을 시도한 뒤 `시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기`를
사용자가 직접 승인해야 할 수 있습니다. OAuth Keychain 실험 모드에서는 앱을 다시 빌드해 코드
서명이 달라질 때 macOS가 접근 승인을 다시 요구할 수도 있습니다. 고정된 Developer ID로 서명하고
공증하면 앱의 코드 정체성과 승인 경험은 안정되지만, 사용자가 OAuth 모드를 선택할 때 필요한 최초
승인 자체를 없애지는 않습니다.

## 저장하거나 기록하지 않는 정보

AiUsage가 저장하는 앱 설정은 다음뿐입니다.

- 서비스 표시 여부
- 이름·로고와 퍼센트 표시 방식
- 갱신 주기
- Claude 조회 모드

statusLine 연결에 동의한 경우 `~/.claude/aiusage/`에는 연결용 스크립트, 연결 메타데이터, 변경 전
설정 백업과 기존 statusLine 명령을 저장합니다. 이 파일은 기존 표시 보존과 정확한 연결 해제에만
사용하며 권한을 `0600` 또는 `0700`으로 제한합니다.

계정 이메일, 세션 ID, 프롬프트, 작업 경로, OAuth 토큰과 서버 오류 본문은 앱 설정이나
로그에 저장하지 않습니다. OAuth 자격은 요청을 만드는 동안 메모리에서만 사용합니다.
