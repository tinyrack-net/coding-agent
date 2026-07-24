# coding-agent

Paseo(https://github.com/getpaseo/paseo)를 레퍼런스로 한 Flutter/Dart AI 코딩 에이전트 MVP.

## 구조 (pub workspace)

- `packages/protocol` — 데몬↔클라이언트 공유 와이어 프로토콜 (RPC 봉투, 메시지 모델)
- `packages/daemon` — 헤드리스 Dart 데몬: WebSocket API, 에이전트 CLI(Claude Code/Codex) 오케스트레이션
- `packages/app` — Flutter 클라이언트 (Windows/macOS/iOS/Android)
- `spikes/` — 리스크 검증 스파이크 (claude stream-json 제어 프로토콜 등)

## 실행

```sh
dart pub get

# 데몬 (기본 ws://127.0.0.1:6868)
dart run agent_daemon:daemon

# 앱
cd packages/app && flutter run -d windows
```

## 기능 (MVP)

- Claude Code / Codex 에이전트 채팅 (스트리밍 타임라인, 마크다운, 툴콜 카드, resume)
- 권한 승인 흐름 (인라인 Allow/Always/Deny 카드, plan/normal/fullAccess 모드)
- 멀티 에이전트 병렬 실행 (사이드바 + run-state 배지)
- 프로젝트/워크트리 관리, Diff 리뷰 탭
- 내장 터미널 (ConPTY 기반, xterm 렌더링)
- 모바일/원격 접속 (설정 화면에서 host:port + 토큰, 데몬은 `--host 0.0.0.0 --token <secret>`)

## 테스트

```sh
dart test packages/protocol packages/daemon   # 71 tests
cd packages/app && flutter test               # 6 tests
```

수동 E2E 스모크 (실제 CLI 필요, packages/daemon에서 실행):

```sh
dart run agent_daemon:smoke_ws        # Claude 채팅 + 권한 승인 E2E
dart run agent_daemon:smoke_git      # 프로젝트/worktree/diff E2E
dart run agent_daemon:smoke_terminal # ConPTY 터미널 E2E
dart run agent_daemon:smoke_codex    # Codex E2E (계정 한도 필요)
```

계획 문서: `C:\Users\winetree94\.claude\plans\ai-coding-agent-polymorphic-blossom.md`
