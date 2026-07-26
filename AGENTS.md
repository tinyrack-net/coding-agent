# AGENTS.md

coding-agent는 [Paseo](https://github.com/getpaseo/paseo)를 레퍼런스로 한 Flutter/Dart AI 코딩 에이전트 MVP입니다.
막히거나 설계를 결정할 때는 `~/Workspaces/learn/paseo`(Paseo 원본 소스, TS/Node 기반)를 참고하세요. 이 저장소는 Paseo의 아키텍처(데몬/클라이언트 분리, RPC 프로토콜, 권한 승인 흐름, 워크트리 관리 등)를 Dart/Flutter로 재구현한 것이므로, 기능의 의도나 엣지 케이스가 불명확할 때 Paseo 쪽 동등 구현을 먼저 찾아 대조하는 것이 가장 빠른 방법입니다.

## 구조 (pub workspace)

`pubspec.yaml`의 `workspace:`에 선언된 4개 패키지로 구성됩니다.

- `packages/protocol` (`agent_protocol`) — 데몬↔클라이언트 공유 와이어 프로토콜. RPC 봉투(`rpc_envelope.dart`), 메시지 모델(`src/messages/*.dart`: agent/diff/hello/provider/workspace), 타임라인 모델(`src/timeline/*.dart`), 터미널 바이너리 프레임(`src/binary/terminal_frames.dart`). 다른 패키지는 모두 이 패키지에 의존하므로 프로토콜 변경 시 daemon/app 양쪽을 함께 갱신해야 합니다.
- `packages/daemon` (`agent_daemon`) — 헤드리스 Dart 데몬. `src/server`(shelf 기반 WebSocket 서버, RPC 라우터), `src/agent`(에이전트 매니저/스토어, 타임라인 스토어), `src/providers/native`(자체 에이전트 하네스 — `LlmBackend`/`OpenAiCompatibleBackend`, `CredentialStore`, `NativeClient`/`NativeSession`, `tools/`의 fs/bash/search 툴 구현), `src/permission`(권한 승인 브로커), `src/git`(git runner/service, unified diff 파서, 워크스페이스 RPC), `src/terminal`(ConPTY 기반 터미널 매니저), `src/store`(프로젝트 스토어). 기본 포트 6868.
- `packages/daemon_lifecycle` — 데몬과 앱이 공유하는 데몬 생명주기 로직: pid lock, liveness probe(`hello_probe.dart`), spawn/stop(`daemon_spawner.dart`/`daemon_stopper.dart`), 버전 확인.
- `packages/app` (`coding_agent_app`) — Flutter 클라이언트(Windows/macOS/iOS/Android). `lib/screens`(채팅/새 에이전트/설정/상태 화면 — 설정 화면에 AI Providers API 키 관리 포함), `lib/state`(Riverpod providers), `lib/widgets`(composer, diff view, 타임라인 타일, 터미널 pane), `lib/core`(daemon client, desktop shell/tray, provider 표시 이름 헬퍼).
- `tool/` — 빌드/커버리지 스크립트 (`build_daemon.ps1`, `build_daemon_macos.sh`, `coverage.ps1`).

## 실행

```sh
flutter pub get   # 또는 dart pub get

# 데몬 (기본 ws://127.0.0.1:6868; 6767은 이 머신의 다른 Paseo 인스턴스가 점유)
dart run agent_daemon:daemon

# 앱
cd packages/app && flutter run -d windows
```

## 테스트

```sh
dart test packages/protocol packages/daemon   # 유닛 테스트
cd packages/app && flutter test               # 위젯 테스트
```

- CI(`.github/workflows/`)는 `pwsh tool/coverage.ps1`로 유닛 테스트 + **95% 커버리지 게이트**를 강제합니다. 커버리지를 낮추는 변경은 병합 전에 테스트를 보강하세요.
- E2E는 `packages/app/integration_test`(Windows 데스크톱, `flutter test integration_test -d windows`)로 실행되며, `tool/build_daemon.ps1`로 빌드한 데몬 실행 파일이 필요합니다.
- 수동 E2E 스모크(실제 API 키 필요, `packages/daemon`에서 실행):

  ```sh
  dart run agent_daemon:smoke_ws       # WebSocket + 권한 승인 (OPENAI_API_KEY 필요)
  dart run agent_daemon:smoke_git      # 프로젝트/worktree/diff
  dart run agent_daemon:smoke_terminal # ConPTY 터미널
  dart run agent_daemon:smoke_native <openai|claude|deepseek|openrouter> # 네이티브 하네스 E2E (프리셋 이름)
  ```

## 작업 시 유의사항

- 프로토콜(`packages/protocol`)을 변경하면 이를 사용하는 `daemon`과 `app` 양쪽의 직렬화/역직렬화 코드와 테스트를 함께 갱신해야 합니다.
- 에이전트는 CLI 서브프로세스가 아니라 데몬이 직접 LLM API를 호출하는 자체 하네스로 동작합니다. 지원 방언은 `ProviderKind` 두 가지 — OpenAI Chat Completions 호환(`openai_compatible_backend.dart`)과 Anthropic Messages API 호환(`anthropic_backend.dart`)입니다.
- 프로바이더는 하드코딩된 목록이 아니라 **사용자가 등록하는 데이터**입니다. 설정은 `packages/daemon/.../provider_config_store.dart`(`<dataDir>/providers.json`), API 키는 같은 id로 `credential_store.dart`(Windows DPAPI 암호화)에 저장됩니다. 앱의 Settings > AI Providers에서 추가/수정/삭제하며, RPC는 `provider.list/upsert/delete.request` + `provider.credential.set/clear/test.request`입니다. `provider_presets.dart`(daemon/app 양쪽)는 "추가" 폼을 채우는 템플릿일 뿐 존재하는 프로바이더의 출처가 아닙니다.
- 프로바이더 id는 불투명한 문자열이므로 표시 이름은 `provider.list` 결과에서 조회해야 합니다(`app/lib/core/provider_display.dart`). 백엔드는 `ProviderRegistry`가 id별로 지연 생성/캐시하고 수정·삭제 시 무효화하므로, 데몬 재시작 없이 반영됩니다.
- 새 기능을 구현하기 전 `~/Workspaces/learn/paseo`에서 대응하는 TS 구현(RPC 핸들러, 권한 모드, 워크트리 로직 등)을 먼저 찾아 동작 방식을 확인하세요. 1:1로 옮길 필요는 없지만 의도를 존중해야 합니다.
- 계획 문서: `~/.claude/plans/ai-coding-agent-polymorphic-blossom.md`, `~/.claude/plans/cli-dreamy-nest.md`
