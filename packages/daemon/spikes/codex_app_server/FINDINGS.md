# codex app-server protocol findings (codex-cli 0.144.6, Windows)

Verified empirically with `probe.dart` (raw wire log in `probe-run1.log`) and
cross-checked against the Paseo reference (`codex-app-server-agent.ts` +
`codex/app-server-transport.ts`).

## Transport

- `codex app-server` speaks line-delimited JSON-RPC over stdio (one JSON
  object per line; no `jsonrpc` field required on client->server messages).
- Client requests: `{"id": <int>, "method": "...", "params": {...}}`.
- Server responses: `{"id": <int>, "result": {...}}` or `{"id", "error": {"message"}}`.
- Server -> client REQUESTS (have both `id` and `method`) are used for
  approvals and must be answered with `{"id": <same id>, "result": {...}}`.
- Notifications: `{"method": "...", "params": {...}}` (no id).

## Handshake (verified live)

1. request `initialize` with `{"clientInfo": {"name","title","version"}}`
   -> result carries `userAgent`, `codexHome`, `platformOs`.
2. notification `initialized` with `{}`.

## Thread lifecycle (verified live)

- `thread/start` params (verified accepted):
  `{cwd, approvalPolicy: "on-request"|"never", sandbox: "read-only"|"workspace-write"|"danger-full-access", model?}`.
  Result: `{thread: {id, sessionId, ...}, model, approvalPolicy, sandbox: {...}}`.
  A `thread/started` notification with the same thread is also emitted.
  `thread.id` == `sessionId` (UUID) and is the resume key.
- Resume: `thread/resume` with `{threadId}`.

## Turns (verified live)

- `turn/start` with
  `{threadId, input: [{type: "text", text}], approvalPolicy, sandboxPolicy, cwd, model?}`.
  - `sandboxPolicy` is the OBJECT form here (vs string for thread/start):
    `{type:"readOnly"} | {type:"workspaceWrite", networkAccess: bool} | {type:"dangerFullAccess"}`.
  - The request resolves quickly with `{turn: {id, status: "inProgress"}}`;
    completion arrives via notifications.
- Notifications:
  - `turn/started` `{threadId, turn: {id}}` — capture `turn.id` for interrupt.
  - `turn/completed` `{threadId, turn: {status: "completed"|"failed"|..., error: {message}|null}}`
    (verified live: usage-limit failure arrives as status:"failed" with
    `turn.error.message`; a top-level `error` notification also fires).
  - `item/started` / `item/updated` / `item/completed` with
    `{threadId, turnId, item}`. Item types (camelCase on 0.144.x):
    `userMessage` (verified live), `agentMessage {id, text}`,
    `reasoning {id, summary: [], content: []}`,
    `commandExecution {id, command, cwd, status, aggregatedOutput, exitCode}`,
    `fileChange {id, status, changes: [{path, kind, diff|content}]}`,
    `mcpToolCall {id, tool, arguments, status}`, `webSearch {id, query}`,
    `plan`, `contextCompaction`, `subAgentActivity`.
  - Streaming deltas: `item/agentMessage/delta` and
    `item/reasoning/summaryTextDelta`, both `{threadId, itemId, delta}`.
  - Noise to ignore: `mcpServer/startupStatus/updated`,
    `thread/status/changed`, `account/rateLimits/updated`,
    `remoteControl/status/changed`, `thread/tokenUsage/updated`,
    `turn/diff/updated`, `turn/plan/updated`.
  - Legacy `codex/event/*` shapes exist only for Codex < 0.143 — not needed.

## Approvals (server -> client requests)

- `item/commandExecution/requestApproval` `{itemId, threadId, turnId, command?, cwd?, reason?}`.
- `item/fileChange/requestApproval` `{itemId, threadId, turnId, reason?}`.
- Answer: `{"id": <request id>, "result": {"decision": "accept"|"decline"|"cancel"}}`.
- Other server requests (`item/tool/requestUserInput`,
  `mcpServer/elicitation/request`) are acked with an empty result.

## Interrupt / shutdown

- `turn/interrupt` with `{threadId, turnId}`.
- Shutdown: close stdin + kill the process tree (`taskkill /T /F` on Windows).

## Mode mapping used by the adapter

| AgentMode  | approvalPolicy | sandbox (thread/start) | sandboxPolicy (turn/start)                  |
|------------|----------------|------------------------|---------------------------------------------|
| plan       | on-request     | read-only              | {type: readOnly}                            |
| normal     | on-request     | workspace-write        | {type: workspaceWrite, networkAccess:false} |
| fullAccess | never          | danger-full-access     | {type: dangerFullAccess}                    |

## Auth / quota note

`codex login status` -> "Logged in using ChatGPT", but the account has hit its
usage limit (resets Jul 29 2026), so live turns currently fail with
`turn/completed status=failed, codexErrorInfo=usageLimitExceeded`. The
handshake/thread/turn wire format above was still fully exercised.
