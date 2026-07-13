# AiUsage 릴리스 절차

이 문서는 유지보수자가 Developer ID로 서명하고 Apple 공증을 거친 macOS 앱을 GitHub Release와
Homebrew로 배포하는 절차를 설명합니다. 사용자 설치 방법은 [README](../README.md)를 참고하세요.

## 배포 원칙

- 이미 공개한 태그와 릴리스 자산은 교체하지 않습니다. `v0.1.1` unsigned 릴리스는 기록으로
  보존하고, 서명 배포는 새로운 버전에서 시작합니다.
- 릴리스 태그는 `origin/main`에 포함된 검증 완료 커밋에만 생성합니다.
- GitHub에는 최종 공증 티켓을 staple한 앱으로 다시 만든 ZIP만 공개합니다.
- Homebrew cask의 SHA-256은 GitHub에 공개된 최종 ZIP에서 계산한 값과 정확히 일치해야 합니다.
- 인증서, private key, 비밀번호와 API key 원문을 저장소, 로그, 릴리스 자산에 포함하지 않습니다.

## 최초 1회 Apple 준비

1. Apple Developer Program의 Account Holder가 `Developer ID Application` 인증서를 생성합니다.
2. 인증서와 private key를 Keychain Access에서 암호가 설정된 `.p12`로 내보냅니다.
3. App Store Connect에서 공증 전용 Team API key를 만들고 `.p8`, Key ID, Issuer ID를 안전하게
   보관합니다. 이 저장소의 워크플로는 Team API key와 Issuer ID 조합을 사용하도록 고정되어
   있습니다.
4. 인증서가 유효한 코드 서명 identity로 보이는지 로컬에서 확인합니다.

```bash
security find-identity -v -p codesigning
```

ZIP으로 `.app`을 배포하므로 `Developer ID Installer` 인증서는 필요하지 않습니다.

## GitHub Actions 자격 증명과 release environment

저장소에 `release` environment를 만들고 가능하면 required reviewer와 `v*` 태그 배포 제한을
설정합니다. 별도의 tag ruleset으로 `v*` 태그 생성, 삭제와 강제 갱신 권한도 제한합니다.

현재 `release` environment의 deployment branch policy는 `v*` 태그만 허용합니다.

다음 여섯 값을 저장소의 Actions secret으로 등록합니다. `release` environment는 배포 승인과
태그 보호에 사용하며, 저장소 secret은 해당 environment를 사용하는 릴리스 job에서도 읽을 수
있습니다. 조직 정책상 environment secret을 사용한다면 같은 이름으로 등록해도 됩니다.

| Secret | 내용 |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Developer ID Application `.p12`의 Base64 |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` 내보내기 암호 |
| `APPLE_TEAM_ID` | 인증서의 Apple Developer Team ID |
| `APPLE_API_KEY_P8_BASE64` | App Store Connect Team API `.p8`의 Base64 |
| `APPLE_API_KEY_ID` | Team API Key ID |
| `APPLE_API_ISSUER_ID` | Team API Issuer ID |

GitHub 웹 설정을 사용하면 값이 터미널 기록에 남지 않습니다. GitHub CLI를 사용할 때도 private
파일의 Base64를 화면에 출력하지 말고 표준 입력으로 바로 전달합니다.

```bash
/usr/bin/base64 -i DeveloperIDApplication.p12 \
  | gh secret set APPLE_CERTIFICATE_P12_BASE64 --repo j3s30p/AI_Usage
/usr/bin/base64 -i AuthKey.p8 \
  | gh secret set APPLE_API_KEY_P8_BASE64 --repo j3s30p/AI_Usage
```

나머지 네 값은 `gh secret set <NAME> --repo j3s30p/AI_Usage`의 비공개 입력 프롬프트나 GitHub 웹
설정으로 등록합니다. secret 값은 워크플로 로그로 출력하지 않습니다.

## 새 버전 준비

1. `MARKETING_VERSION`을 새 semantic version으로 올립니다.
2. `CURRENT_PROJECT_VERSION`을 이전보다 큰 정수로 올립니다.
3. README와 기술 문서가 실제 기능과 배포 상태를 설명하는지 확인합니다.
4. 전체 테스트와 유니버설 Release 빌드를 확인합니다.
5. PR을 `main`에 병합하고 로컬 `main`을 최신 상태로 동기화합니다.

`v1.0.0`의 프로젝트 값은 다음과 같습니다.

- `MARKETING_VERSION = 1.0.0`
- `CURRENT_PROJECT_VERSION = 3`

## 태그와 GitHub Release

병합 커밋이 `origin/main`에 있는지 확인한 뒤 그 커밋에 태그를 생성합니다.

```bash
git fetch origin main --tags
git switch main
git pull --ff-only origin main
git tag -a v1.0.0 -m "AiUsage v1.0.0"
git push origin v1.0.0
```

태그 push가 `.github/workflows/release.yml`을 실행합니다. 워크플로는 다음 순서를 강제합니다.

1. 태그 형식, 프로젝트 버전과 `origin/main` 포함 여부 검증
2. ad-hoc 서명으로 전체 테스트 실행
3. 임시 Keychain에 Developer ID Application 인증서 가져오기
4. 코드 커버리지 계측을 끈 unsigned arm64+x86_64 Release 앱 빌드
5. Hardened Runtime과 secure timestamp를 적용해 수동 Developer ID 서명
6. 서명, Team ID, bundle ID, 버전, helper, 아키텍처, LLVM 커버리지 계측과
   `get-task-allow` 부재 검증
7. 임시 ZIP을 `notarytool submit --wait`로 제출하고 결과와 공증 로그 확인
8. 승인된 앱에 공증 티켓 staple
9. stapled 앱으로 최종 ZIP 재생성
10. 최종 ZIP을 다시 풀어 `codesign`, `stapler`, `spctl`, 아키텍처, 버전과 helper 재검증
11. 최종 ZIP과 SHA-256 파일을 stable GitHub Release로 공개
12. 성공 여부와 관계없이 임시 Keychain, `.p12`와 `.p8` 삭제

공증이 `Accepted`가 아니거나 어느 검증 하나라도 실패하면 GitHub Release는 생성되지 않습니다.

## 공개 후 검증

GitHub Release에서 ZIP을 새 디렉터리에 받아 다음 검증을 다시 수행합니다.

```bash
ditto -x -k AiUsage-v1.0.0-macos-universal.zip verify
codesign --verify --deep --strict --verbose=2 verify/AiUsage.app
spctl --assess --type execute --verbose=4 verify/AiUsage.app
xcrun stapler validate verify/AiUsage.app
lipo verify/AiUsage.app/Contents/MacOS/AiUsage -verify_arch arm64 x86_64
```

서명 정보에는 Developer ID Application authority, 올바른 Team ID, Hardened Runtime과 secure
timestamp가 있어야 하며 `com.apple.security.get-task-allow` entitlement는 없어야 합니다.

## Homebrew 갱신

GitHub Release가 성공한 뒤 `j3s30p/homebrew-tap`의 `Casks/aiusage.rb`를 갱신합니다.

1. `version`을 새 버전으로 변경합니다.
2. `sha256`을 최종 GitHub ZIP의 SHA-256으로 변경합니다.
3. unsigned 또는 공증 전 배포를 설명하는 caveat를 제거합니다.
4. `brew audit --cask j3s30p/tap/aiusage`를 실행합니다.
5. 깨끗하게 재설치하고 `/Applications/AiUsage.app`을 대상으로 서명, Gatekeeper와 staple 검증을
   반복합니다.
6. 앱 실행, Codex·Claude 조회, OAuth 최초 승인과 로그인 시 자동 실행 등록·해제를 실제로
   확인합니다.

GitHub Release가 성공하기 전에는 Homebrew 버전과 SHA를 먼저 갱신하지 않습니다.

## 자격 증명 관리

- GitHub 로그나 이슈에 인증서 이름 외의 private key 내용을 붙이지 않습니다.
- 임시 Keychain과 key 파일은 워크플로의 `always()` cleanup 단계에서 삭제합니다.
- 인증서 또는 API key 유출이 의심되면 Apple에서 즉시 revoke하고 GitHub secrets를 교체합니다.
- 인증서 만료 전에 새 인증서로 시험 릴리스를 검증하고, 사용하지 않는 key는 폐기합니다.
