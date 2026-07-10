# AiUsage

Codex와 Claude의 **현재 5시간 사용 창에서 남은 비율**을 macOS 메뉴바에 표시하는 로컬 앱입니다.

```text
Codex [도넛 링] 23%   Claude [도넛 링] 48%
```

- 100%일 때 완전한 원이며, 남은 양이 줄수록 12시 방향부터 시계 방향으로 선이 사라집니다.
- 설정에서 Codex와 Claude를 각각 켜거나 끌 수 있습니다.
- 퍼센트 문구도 별도로 켜거나 끌 수 있습니다.
- 주간 사용량은 표시하거나 계산하지 않습니다.
- 5분마다 자동 갱신하며 메뉴에서 즉시 새로 고칠 수 있습니다.

## 요구 사항

- macOS 14 이상
- Codex CLI 설치 및 로그인
- Claude를 표시하려면 Claude Code 설치 및 로그인

## 빌드 및 실행

```bash
xcodebuild -project AiUsage.xcodeproj -scheme AiUsage -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AiUsage.app
```

처음 Claude 사용량을 읽을 때 macOS가 `Claude Code-credentials` 키체인 접근 허용 여부를 물을 수 있습니다. AiUsage는 access token을 메모리에서 요청에만 사용하며 로그나 파일에 저장하지 않습니다.

## Hidden Bar 사용 시

AiUsage는 표준 macOS 상태 항목(`NSStatusItem`)이라 Hidden Bar와 함께 사용할 수 있습니다. 처음 실행한 항목이 숨김 구역에 들어갔다면 Hidden Bar를 펼친 뒤 `⌘` 키를 누른 채 AiUsage 항목을 보이는 구역으로 드래그하세요.

## 데이터 경로

- Codex: 로컬 `codex app-server`의 `account/rateLimits/read`에서 300분 창만 선택합니다.
- Claude: Claude Code 키체인의 access token으로 Claude Code가 사용하는 usage endpoint에서 `five_hour`만 읽습니다.

Claude usage endpoint는 공개 외부 API로 문서화된 계약이 아니므로 Claude Code 업데이트에 따라 바뀔 수 있습니다. 인증 오류가 나면 Claude Code에서 다시 로그인한 뒤 새로 고침하세요.
