# Spike: Driving Claude Code CLI (v2.1.216) from Dart in stream-json mode

Date: 2026-07-24. Platform: Windows 11, Dart 3.12, native `claude.exe` at
`C:\Users\winetree94\AppData\Local\Microsoft\WinGet\Links\claude.exe`.

Harness: `bin/claude_stream_json.dart`. Full transcript: `run1.log`.

## Verdict

| Capability | Result |
|---|---|
| (a) Streaming chat (stream-json in/out, partial deltas) | PASS |
| (b) Permission round-trip via stdin control protocol | PASS |
| (c) `--resume <session_id>` | PASS |
| (d) Interrupt via `control_request {subtype: interrupt}` | PASS |

All four worked on the first attempt. No MCP fallback needed.

## Exact CLI invocation

```
claude -p --input-format stream-json --output-format stream-json --verbose \
  --include-partial-messages --permission-prompt-tool stdio
```

- `--permission-prompt-tool stdio` is the key flag: it routes permission
  prompts to `control_request {subtype: can_use_tool}` messages on stdout
  instead of auto-denying. This matches what the TS Agent SDK passes when
  `canUseTool` is provided (the paseo reference drives the CLI through
  `@anthropic-ai/claude-agent-sdk` `query()`, which does this internally).
- Resume: append `--resume <session_id>`, same flags otherwise.
- Env: `CLAUDE_CODE_ENTRYPOINT=sdk-ts` set (the reference propagates this;
  worked with it set — untested without).
- `--verbose` is required for stream-json output in `-p` mode.
- cwd of the spawned process determines where relative files land.

## Wire protocol (JSONL over stdin/stdout, one JSON object per \n-terminated line)

### Client -> CLI (stdin)

Initialize handshake (TS SDK sends it first; CLI replies with a ~18 KB
capabilities payload listing slash commands etc.):

```json
{"type":"control_request","request_id":"req_1_...","request":{"subtype":"initialize","hooks":null}}
```

User message (`session_id` may be empty on the first message):

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]},
 "parent_tool_use_id":null,"session_id":""}
```

Permission response (allow). `request_id` echoes the CLI's id; the envelope
nests the payload under `response.response`; `updatedInput` is required for
allow (echo the original input):

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<echo>",
 "response":{"behavior":"allow","updatedInput":{...original input...}}}}
```

Deny: `{"behavior":"deny","message":"reason"}` in the same envelope.

Interrupt:

```json
{"type":"control_request","request_id":"req_4_...","request":{"subtype":"interrupt"}}
```

Other subtypes exist per the SDK (e.g. `set_permission_mode` with
`{"mode":"acceptEdits"}`) — not exercised here, same envelope.

### CLI -> client (stdout)

Every message carries `session_id` and a `uuid`. Observed types:

- `system/init` — first real message:
  `{"type":"system","subtype":"init","cwd":"...","session_id":"<uuid>","tools":[...],...}`.
  Capture `session_id` here.
- `system/status` (`{"status":"requesting"}`), `system/thinking_tokens`.
- `control_response/success` — reply to our initialize.
- `stream_event` — raw Anthropic streaming events under `event`:
  `message_start`, `content_block_start` (block types seen: `text`,
  `thinking`, `tool_use` with id/name/empty input), `content_block_delta`
  (delta types: `text_delta`, `thinking_delta`, `signature_delta`,
  `input_json_delta` with `partial_json` fragments), `content_block_stop`,
  `message_delta` (stop_reason + usage), `message_stop`. Only present with
  `--include-partial-messages`.
- `assistant` — complete message snapshot after each content block; tool_use
  appears here with fully-parsed `input`.
- `control_request/can_use_tool` — permission prompt, observed verbatim:

  ```json
  {"type":"control_request","request_id":"a7a654de-9bd9-4c1c-816f-0e24e75dae27",
   "request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write",
     "input":{"file_path":"C:\...\hello.txt","content":"spike-ok"}, ...}}
  ```

  After the allow response the tool executed and a `user` message with a
  `tool_result` block followed.
- `user` — echoed tool results
  (`content:[{"tool_use_id":...,"type":"tool_result","content":"File created successfully at: ..."}]`)
  and, on interrupt, a synthetic `[Request interrupted by user]` text message.
- `rate_limit_event` — telemetry, ignorable.
- `result` — terminal message per run:
  - success: `{"type":"result","subtype":"success","is_error":false,"duration_ms":...,"num_turns":...,"result":"<final text>","session_id":...,"total_cost_usd":...,"usage":{...}}`
  - after interrupt: `{"type":"result","subtype":"error_during_execution","is_error":true,...}`, then exit code 1.

### Interrupt semantics

Interrupt produced, in order: `control_response/success` ack
(`{"still_queued":[]}`), final `assistant` snapshot of partial text, synthetic
`user` "[Request interrupted by user]", `result/error_during_execution`,
stdout close, exit code 1 — all within ~600 ms. Clean wind-down, no kill
needed.

### Resume semantics

Phase 2 (`--resume d91e6815-3ee4-4e77-acdb-443bf9ca02d4`) answered
"I created `hello.txt` ... containing exactly `spike-ok`" — full context
retained. The resumed run's init reported the same session_id; treat the init
message's `session_id` as authoritative each run (the CLI can fork ids with
`--fork-session`).

## Gotchas

- The nested `control_response` envelope (`response.subtype` +
  `response.request_id` + `response.response`) is easy to get wrong; a flat
  reply is ignored and the tool call hangs.
- `allow` responses MUST include `updatedInput`.
- CLI-issued request_ids are UUIDs; client-issued ids can be any unique string.
- Process exits on its own after `result` once stdin closes; after interrupt
  it exits code 1 — treat `result` receipt, not exit code, as success signal.
- Windows: no .cmd shim issues (native exe). Temp cwd is echoed back
  8.3-shortened (`WINETR~1`) in payload paths — normalize before comparing.
- UTF-8 decoder + LineSplitter worked; no buffering issues. The initialize
  control_response is a single ~18 KB line — do not cap line length.
- stderr stayed empty during normal operation.
- ~2.5 s to first output; wait for `system/init` rather than sleeping.
