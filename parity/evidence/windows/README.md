# Windows visual parity evidence

The reference images in this directory were captured from the frozen Paseo
`0.2.0` checkout at commit
`7250009ab7ee72142a08344b8a0b7a12af666e53`.

## Workspace tab drag

- Viewport: `1200 x 800` logical pixels
- Theme: Paseo dark
- Workspace content origin: `(320, 84)`
- Workspace content size: `880 x 716`
- Source tab size: `200 x 35`
- External-drag source opacity: `0.3`
- Drag overlay frame: `200 x 35`
- Visible drag chip: `200 x 29`
- Chip padding: `12px 4px`
- Chip gap: `8px`
- Chip icon: `14px`
- Chip label: `14px`
- Chip radius: `6px`
- Chip border: `1px #2f3534`
- Chip background: `#1e2120`
- Chip foreground: `#fafafa`

Reference: `paseo-0.2.0-tab-drag-overlay-1200x800.png`.

## Flutter workspace tab row

- Frozen row height: `36px`
- Tab height: `35px`
- Tab width: equal, rounded, `60px` minimum and `200px` maximum
- Inline add slot/button: `36px / 28px`
- Close button: `18px`
- Row action button: `22px`
- Active indicator: `2px`
- Default currently supported pins: terminal

Flutter geometry golden:
`packages/app/test/goldens/workspace_tab_row_880x36.png`.
The Flutter test font is intentionally Ahem, so this golden verifies geometry,
palette, borders, and state placement; source-versus-Flutter text rendering is
reserved for the full Windows runtime comparison.

## Workspace tab body retention

- Newly active pane tabs mount in the same frame.
- Each pane retains the three most recently active tab bodies.
- The fourth activation evicts the least recently active body.
- Modified file panels remain mounted beyond the normal cap until clean.

Contract and widget evidence:
`packages/app/test/workspace_mounted_tab_set_test.dart` and
`packages/app/test/worktree_tabbed_pane_test.dart`.

## Workspace deck retention

- Selection identity is the stable `serverId:workspaceId` pair.
- The active workspace and two most recently inactive roots remain mounted.
- Render order is sorted by the composite key so retained roots do not move.
- Inactive entries survive hydration and are removed only after the hydrated
  workspace inventory confirms deletion.

Contract and shell integration evidence:
`packages/app/test/workspace_deck_retention_test.dart` and
`packages/app/test/home_shell_test.dart`.

## Canonical agent timeline wire

- Default v2 clients receive frozen `agent_stream` messages with provider,
  timestamp, string epoch, sequence, and canonical timeline/turn/permission
  events.
- Tool calls use `type/callId/name/detail/metadata/status/error`; running,
  completed, failed, and canceled enforce the frozen error invariant.
- All Paseo 0.2.0 tool detail variants, todo rows, compaction, and worktree
  setup command snapshots have typed canonical codecs.
- `fetch_agent_timeline_request` supports tail/before/after defaults, cursor
  resets, limits, canonical entry sequence ranges, and the frozen response
  envelope.
- The Flutter client no longer advertises `tinyrackLegacyTimelineV1`. It
  decodes native timeline, turn, and permission events into typed stream
  payloads and applies them to its projected replica. Permission resolutions
  preserve the request's tool name and detail.
- Remaining timeline gaps are the exact AgentSnapshot payload in fetch
  responses and projected-versus-canonical lifecycle collapsing.

Contract, daemon-boundary, and widget evidence:
`packages/protocol/test/paseo_timeline_codec_test.dart`,
`packages/daemon/test/ws_server_test.dart`,
`packages/daemon/test/daemon_agent_continuation_e2e_test.dart`,
`packages/app/test/daemon_client_test.dart`,
`packages/app/test/daemon_client_v2_e2e_test.dart`, and
`packages/app/test/timeline_item_tile_test.dart`.

## Canonical host/workspace route

- Flutter and custom-scheme links share
  `/h/:serverId/workspace/:workspaceId`.
- URL-safe opaque workspace IDs remain plain; path-shaped or reserved IDs use
  Paseo's marked `b64_` base64url form, including legacy unmarked decoding.
- `coding-agent://h/...` startup arguments restore the canonical GoRouter
  route and preserve the one-shot `open` query.
- The active host is selected from the persisted host registry, then the
  complete paginated v2 workspace catalog resolves the opaque ID to its
  `workspaceDirectory`.
- Removed hosts recover to `/open-project` (or `/welcome` with no saved host);
  missing workspaces expose retry and project-navigation actions.
- Agent, file, restored terminal, draft, and setup open intents activate their
  matching workspace tabs after persisted layout hydration.
- A missing workspace reached through an agent intent runs the authoritative
  recovery inspection, distinguishes host upgrade/unavailable/inspection
  failure states, and restores the workspace before refreshing the selected
  archived agent and workspace catalog.
- Agent intents pin their tab through catalog/recovery gaps; closing the tab
  removes the pin. The pin set is part of the persisted workspace layout.
- A disconnected host retains its last authoritative workspace catalog, so a
  cached workspace remains visible while a genuinely missing route shows the
  host-offline recovery and host-management actions.
- Consumed open intents are removed from browser history with `replace`, and
  revisiting the canonical URL does not repeat the intent. Canonical routes use
  the same three-root retained workspace deck.

Contract, catalog, and widget evidence:
`packages/app/test/host_routes_test.dart`,
`packages/app/test/workspace_catalog_provider_test.dart`, and
`packages/app/test/host_workspace_route_screen_test.dart`,
`packages/app/test/workspace_recovery_provider_test.dart`,
`packages/app/test/app_router_test.dart`,
`packages/app/test/worktree_tabs_provider_test.dart`, and
`packages/app/test/terminal_pane_test.dart`.

## Workspace setup status and panel

- The Flutter client sends Paseo's root-level
  `workspace_setup_status_request` and correlates the payload request ID in
  `workspace_setup_status_response`.
- The daemon keeps the latest setup snapshot for its process lifetime and
  broadcasts `workspace_setup_progress` with the frozen status, detail,
  command, error, and nullable exit-code shape.
- Snapshot lookup is keyed by `serverId:workspaceId`; concurrent requests are
  deduplicated, while null, mismatched, unsupported, and failed responses stay
  retryable.
- The setup tab distinguishes waiting, completed-with-no-commands, running,
  and failed states. It auto-expands the running command (otherwise the last
  command), processes carriage-return progress logs, exposes duration and
  accessible status/log labels, and supports manual collapse.
- Newly created worktrees load `worktree.setup` from `tinyrack.json`, falling
  back to compatible `paseo.json`, and run commands sequentially through the
  platform shell. Output chunks update command logs, durations, and exit codes
  live; the first non-zero exit marks the setup failed.
- Setup commands receive Tinyrack runtime environment names and Paseo
  compatibility aliases for source checkout, worktree, branch, and an
  allocated worktree port. Later terminals opened at the worktree or a
  descendant inherit the same environment using longest-root matching.
- Worktree creation writes frozen v1 base metadata under the linked Git
  directory. The first setup upgrades it atomically to v2 with the allocated
  runtime port; later setup and terminal sessions reuse that port after an
  availability check.
- Command output strips ANSI control sequences, applies terminal-style
  carriage returns, and retains a bounded 64 KiB head/tail view with the
  frozen middle-truncation marker. Combined logs include the frozen command
  start and exit/duration framing.
- A configuration or runtime-environment preflight failure archives only the
  workspace record; a command failure keeps the active record and worktree so
  the user can inspect and recover it.
- New workspace creation now uses the v2 workspace contract with
  `firstAgentContext`. Worktree setup is held until the coupled agent exists,
  then the agent timeline receives Worktree Setup lifecycle updates followed
  by parallel configured-terminal creation, readiness waits, command input,
  and per-terminal results. A failed first-agent creation force-cleans the
  pending worktree.
- Remaining setup evidence gap is the source-versus-Flutter Windows golden
  comparison of the complete panel and lifecycle cards.
- The frozen upstream Playwright setup scenario can be started on Windows with
  `tool/paseo_windows_e2e_preload.cjs`, which normalizes its POSIX `which` and
  extensionless command-launch assumptions without editing Paseo. The current
  upstream scenario is not yet valid golden evidence on this machine: its
  fixture invokes `sh`, then its sidebar helper searches for the full project
  path even though the rendered row exposes only the basename. The installed
  Electron window also rejected direct Windows Graphics Capture with
  `GetCursorPos failed: Access is denied (0x80070005)`. Keep the visual item
  partial until a setup-panel frame is captured through an isolated oracle.

Contract, daemon, client, store, and widget evidence:
`packages/protocol/test/workspace_setup_test.dart`,
`packages/daemon/test/worktree_metadata_test.dart`,
`packages/daemon/test/workspace/workspace_setup_service_test.dart`,
`packages/daemon/test/workspace/worktree_terminal_bootstrap_service_test.dart`,
`packages/daemon/test/daemon_agent_continuation_e2e_test.dart`,
`packages/daemon/test/daemon_v2_workspace_e2e_test.dart`,
`packages/app/test/daemon_client_test.dart`,
`packages/app/test/new_workspace_screen_test.dart`,
`packages/app/test/timeline_item_tile_test.dart`,
`packages/app/test/workspace_setup_provider_test.dart`, and
`packages/app/test/worktree_tabbed_pane_test.dart`.

## Canonical and projected agent timeline windows

- Timeline persistence now retains every canonical lifecycle revision with its
  sequence and timestamp while separately preserving the complete latest item
  view needed by the temporary v1 adapter. Assistant and reasoning cumulative
  updates are stored as canonical text chunks and reconstruct correctly after
  restart.
- `fetch_agent_timeline_response` includes a frozen-shape AgentSnapshot with
  identity, runtime, mode, usage, persistence, attention, archive, and latest
  pending-permission fields.
- Canonical pages retain individual tool lifecycle rows. Projected pages
  collapse tool lifecycles, preserve typed detail over unknown updates, merge
  metadata and terminal error state, and merge contiguous assistant/reasoning
  chunks while emitting exact `sourceSeqRanges` and `collapsed` values.
- Tail, after, and before limits count projected entries. Wide,
  discontiguous tool lifecycles expand overlapping windows and after cursors
  advance only through canonical source rows covered without a gap.
- WebSocket conformance scenarios cover canonical and projected setup/tool
  lifecycle fetches, exhausted after/before cursors, stale epoch reset, and a
  retained-history gap reset with exact window and cursor metadata.
- Frozen built-in provider modes and capability differences are projected into
  AgentSnapshot. Claude/Codex fast-mode availability is model-aware, Codex
  plan mode and OpenCode auto-accept preserve stored values, and the flat-item
  MCP projected-limit helper returns the canonical rows spanning the selected
  projected entries.
- AgentSnapshot preserves last-user-message time, lifecycle-cleared last
  errors, string labels, and removed-provider availability across persistence
  and WebSocket fetch.
- AgentSnapshot remains partial at the live-runtime boundary: dynamic ACP
  features, Pi session-dependent MCP capability, and provider-specific
  runtimeInfo extra metadata are not yet projected.

Contract and runtime evidence:
`packages/protocol/test/paseo_agent_snapshot_codec_test.dart`,
`packages/protocol/test/paseo_timeline_codec_test.dart`,
`packages/daemon/test/timeline_store_test.dart`,
`packages/daemon/test/agent_store_test.dart`,
`packages/daemon/test/timeline_projection_test.dart`,
`packages/daemon/test/daemon_timeline_fetch_e2e_test.dart`, and
`packages/daemon/test/daemon_agent_continuation_e2e_test.dart`.

## Flutter projected timeline synchronization

- The Flutter client now issues the native Paseo
  `fetch_agent_timeline_request` instead of the temporary v1 fetch RPC. The
  typed boundary validates correlation, string epochs, window cursors,
  reset/stale/gap flags, projected entries, collapse metadata, and daemon
  errors.
- Initial loads request the projected 40-entry tail. Reconnect and sequence-gap
  recovery continue from the end cursor with recursive `after` pages until
  `hasNewer` is exhausted; epoch/reset responses replace the active window.
- Flutter state keeps authoritative tail and live head partitions, widens its
  cursor across merges, deduplicates canonical ids, and preserves optimistic
  user-message placement and rich local presentation through canonical
  `clientMessageId`, direct-id, and live FIFO reconciliation.
- Native `agent_stream` timeline, turn, and permission events now enter the
  same reducer without the temporary legacy capability adapter. A real
  Dart-daemon-to-Flutter-client E2E proves the boundary.
- Scrolling within 96 logical pixels of the oldest edge requests a guarded
  40-entry `before` page. Prepending preserves the visible viewport, displays
  an in-flight progress ring, and surfaces failures through the product toast
  flow.
- The root app now maintains one independently owned daemon client for every
  registered host. Switching the active host retains both transports and
  restores that host's agent directory, workspace catalog, and per-agent
  projected timeline replicas. Removing a host disposes only its client and
  clears only its retained directory/catalog/timeline state. A late agent-list
  response cannot recreate a removed host replica.
- Flutter advertises the frozen client capability set and decodes typed
  `agent_update`, `agent_deleted`, `agent_archived`, `workspace_update`, and
  `project.update` messages. Agent deltas arriving during a list refresh are
  committed after the authoritative snapshot; workspace/project deltas enter
  the subscribed host catalog without a second snapshot overwrite. The Dart
  daemon emits canonical agent snapshots to v2 clients, and a real
  daemon-to-Flutter E2E covers agent and project directory updates.
- Agent directory hydration now uses the frozen `fetch_agents_request` and
  `fetch_agents_response` envelopes. Flutter exhausts every cursor page while
  subscribing only on the first request; the daemon enforces the 200-row
  boundary, deterministic sorting, project/status/attention/thinking filters,
  cursor errors, generated/caller-supplied subscription ids, per-connection
  filter replacement, and connection-targeted v2 updates. Protocol boundary
  tests, a two-client subscription isolation test, and real
  daemon-to-Flutter pagination/filter/replacement E2E cover the slice.
- Archived agents now persist and restore the frozen `closed` run state and
  `archivedAt` timestamp. The typed `fetch_agent_history_request` and
  `fetch_agent_history_response` envelopes cross the real daemon/client
  boundary with two-page pagination. Flutter merges per-host history and
  cursors, tolerates partial host failure, reacts to reconnects, preserves
  loaded pages after incremental failure, and exposes the Sessions route with
  all-host/per-host filtering plus loading, error, empty, active, archived, and
  load-more states. Numeric cursors, synthesized placement, exact visual
  geometry, and provider-unavailable history remain parity gaps.
- Single-agent detail now uses the frozen `fetch_agent_request` and
  `fetch_agent_response` envelopes. Resolution follows Paseo's exact id,
  unique id prefix, then exact full-title order, includes archived records,
  preserves the frozen ambiguity and not-found messages, and returns nullable
  project placement. Protocol, manager, synthetic-client, and real
  daemon-to-Flutter tests cover success, archived title lookup, id-prefix
  lookup, nullable results, and server errors. Internal-agent exclusion,
  client-scoped provider visibility, and authoritative persisted placement
  remain.
- Remaining session-store and host-runtime gaps include exact connection
  probing/failover, socket and pipe Flutter transports, empty-project and
  exact archived/history placement retention, bootstrap update timestamp
  deduplication and abort-epoch handling, full snapshot-owned
  permission/capability state, and host-scoping of the remaining session
  domains.

Contract and UI evidence:
`packages/protocol/test/agent_timeline_test.dart`,
`packages/protocol/test/paseo_timeline_codec_test.dart`,
`packages/protocol/test/directory_updates_test.dart`,
`packages/app/test/daemon_client_test.dart`,
`packages/app/test/daemon_client_v2_e2e_test.dart`,
`packages/app/test/timeline_provider_test.dart`, and
`packages/app/test/agent_chat_screen_test.dart`.

## Claude Code stream-json runtime

- The daemon now registers a real `claude` provider client instead of exposing
  Claude only through the provider catalog.
- Claude launches with the frozen SDK's bidirectional stream-json contract:
  partial messages, stdio permission prompts, exact permission mode, model,
  thinking effort, resume id, setting sources, dangerous-mode capability,
  checkpointing environment, MCP timeouts, and fast-mode settings.
- The session sends the SDK initialization control request and structured user
  blocks, normalizes init/session id, partial text and thinking, tool starts,
  usage, success/failure, process exit, and emits provider-neutral daemon
  events.
- `can_use_tool` requests round-trip through the existing permission broker as
  Claude `control_response` allow/deny results with the original tool input and
  tool-use id.
- Exact provider configuration now survives agent creation, persistence, and
  session startup. Codex also receives the exact `modeId` and thinking option
  instead of reconstructing them from the legacy three-value enum. Claude
  live mode, model, and fast-mode controls use the SDK control surface.
  Thinking changes defer recreation until the next prompt, dispose the old
  connection, and resume the observed Claude session with the exact updated
  configuration.
- Existing Claude JSONL history is loaded from the frozen encoded project
  directory and projected as conversation, reasoning, tool result, and
  compaction timeline items. Recursive persisted sidechains are correlated
  with their parent Task or Agent tool result and restored through the daemon's
  provider-subagent store. Frozen synthetic, compact-summary, interrupt,
  no-response, and local-command noise rows are excluded. Live streamed tool
  inputs and successful or failed `tool_result` messages retain their stable
  call id and payload.
- Prompt images cross the protocol as the frozen separate base64 image array.
  Claude receives chat-history text before the prompt, supported JPEG/PNG/GIF/
  WebP native blocks after it, and ordinary context last. Live and restored
  tool-result images are content-hash materialized under the Tinyrack
  attachment directory and exposed as assistant markdown; base64 is excluded
  from tool output and timeline JSON.
- The Flutter composer accepts desktop/mobile-web drop items and native file
  picker selections, recognizes the frozen raster MIME and extension surface,
  persists bytes behind the frozen attachment metadata contract, previews
  images with removal controls, re-encodes each image independently, submits
  image-only prompts, and deletes temporary bytes after removal or successful
  send. Ctrl/Cmd+V and context-menu Paste use the same guarded path; native
  clipboard image formats are normalized to PNG, while a missing or unreadable
  image falls back to selection-aware text insertion. Agent, workspace-tab, and
  new-workspace text/image metadata persist under the frozen draft keys, restore
  attachment bytes independently after remount, serialize storage operations,
  and finalize with the frozen sent/abandoned lifecycle and five-minute TTL.
  Indexed active drafts and active pending-create attempts contribute attachment
  ids to GC. New-workspace messages now prepare the frozen create-flow and
  workspace-draft submission records, navigate to their draft tab, display an
  optimistic creating state, consume auto-submit once, and preserve the original
  client message id through atomic `agent.create`. Empty submissions omit
  `firstAgentContext` and open only the workspace. Worktree setup and configured
  terminal bootstrap finish before the prepared first prompt starts. After
  creation, the handed-off message enters the same timeline projection as normal
  prompts. It enriches the first canonical user row if one already exists or
  appends optimistically otherwise. Canonical echoes reconcile by
  `clientMessageId`, then direct id, with live FIFO fallback for provider echoes;
  the authoritative server id replaces the pending id while local text,
  timestamp, images, and semantic attachments survive. Restored timeline images
  and attachment pills render from pending and acknowledged rows, and their ids
  remain owned for attachment GC. Running-agent Enter submissions move into an
  ordered queue with Edit, Send now, failed-send front restoration, and mounted-
  composer idle drain. Direct, send-now, and drained prompts all use the same
  optimistic append/rollback path. Workspace browser-element screenshots have
  their own scope owner, are submitted alongside semantic element context
  through the image payload, and transfer to timeline ownership after success.
  Browser multi-item clipboard events, heterogeneous attachments, acknowledged-
  exact Web IndexedDB/object URLs, the global per-host queue drain, actual
  browser-pane capture UI, full per-host queue ownership, draft setup
  overrides, and complete provider feature/thinking readiness remain.
- Remaining Claude parity includes complete typed tool details, questions and
  plan actions, live sidechain/subagent routing, rewind, complete command
  semantics, MCP injection, dynamic catalog/runtime info, cross-platform
  history-path conformance, authenticated real-CLI smoke, browser multi-item
  clipboard ingestion, complete heterogeneous attachment ownership, and
  acknowledged-timeline image-reference garbage collection.

Runtime evidence:
`packages/daemon/test/agent_client_test.dart`,
`packages/daemon/test/agent_manager_test.dart`,
`packages/daemon/test/providers/paseo/claude_agent_client_test.dart`,
`packages/daemon/test/providers/paseo/claude_history_test.dart`, and
`packages/daemon/test/providers/paseo/codex_agent_client_test.dart`.
Composer attachment evidence additionally includes
`packages/app/test/composer_clipboard_reader_test.dart`,
`packages/app/test/composer_draft_store_test.dart`,
`packages/app/test/composer_image_attachment_service_test.dart`, and
`packages/app/test/composer_test.dart`,
`packages/app/test/create_flow_provider_test.dart`,
`packages/app/test/draft_session_composer_test.dart`, and
`packages/app/test/new_workspace_screen_test.dart`, and
`packages/app/test/agent_chat_screen_test.dart`, and
`packages/app/test/queued_messages_provider_test.dart`,
`packages/app/test/timeline_provider_test.dart`, and
`packages/app/test/timeline_item_tile_test.dart`.

Validation snapshot (2026-07-28):

- `pwsh tool/coverage.ps1 -MinCoverage 95`: protocol, relay, lifecycle, and
  daemon passed; the first app pass exposed a 94.80% create-flow branch gap,
  which was closed by picker/removal, missing-image, and provider/model boundary
  tests. 299 protocol tests, 41 relay tests, 65 daemon-lifecycle tests, 810
  daemon tests, and the refreshed 669 Flutter tests passed.
- Protocol line coverage is 95.47% (5,268/5,518), relay coverage is 95.17%
  (591/621), and daemon-lifecycle coverage is 100% (220/220).
- Excluding the CI platform/composition files, daemon line coverage is 95.17%
  (13,564/14,252), and the refreshed app line coverage is 95.13%
  (11,868/12,475).
- `flutter analyze`, `dart run tool/parity.dart --check`, and
  `git diff --check` passed. The frozen source checkout remained clean at
  `7250009ab7ee72142a08344b8a0b7a12af666e53`.
- The complete all-package gate now includes the Claude runtime/history
  attachment and image-result tests; no projected coverage substitution is
  used in this snapshot.
- The projected timeline refresh added 3 protocol tests and 6 Flutter tests:
  302 protocol and 675 Flutter tests now pass. Refreshed protocol coverage is
  95.20% (5,400/5,672) and refreshed app coverage is 95.11%
  (12,010/12,628); relay remains 95.17% (591/621), daemon-lifecycle remains
  100% (220/220), and this slice did not change daemon source lines.
- The multi-host runtime refresh retains one client plus agent-directory,
  workspace-catalog, and timeline replicas per registered host, restores them
  across active-host selection, disposes only removed host clients, and clears
  only removed host replicas. The final all-package gate passes with protocol
  95.20% (5,400/5,672), relay 95.17% (591/621), daemon-lifecycle 100%
  (220/220), daemon 95.17% (13,571/14,260), and the refreshed app 95.04%
  (12,162/12,797). The daemon coverage run also proved shutdown waits for
  in-flight workspace Git polling before temporary workspaces are removed.
  Dart protocol/daemon tests pass 1,112 cases serially and Flutter passes 681
  cases.
- Native directory synchronization raises the serial protocol/daemon suite to
  1,117 passing cases and Flutter to 689. Changed-package gates pass at
  protocol 95.20% (5,578/5,859) and app 95.00% (12,285/12,932); the earlier
  unchanged relay, lifecycle, and daemon gates remain green. Root analysis,
  frozen parity validation, and diff validation are rerun for each ledger
  update.
- Native paginated agent hydration raises the serial protocol/daemon suite to
  1,124 passing cases and Flutter to 691. Refreshed changed-package gates pass
  at protocol 95.19% (5,722/6,011) and app 95.00% (12,298/12,945). The real
  daemon/client E2E covers cursor pagination and project/status filtering;
  targeted WebSocket tests prove directory updates reach only subscribed v2
  connections.
- Native archived history raises the serial protocol/daemon suite to 1,125
  passing cases and Flutter to 703. Refreshed changed-package gates pass at
  protocol 95.22% (5,763/6,052) and app 95.01% (12,485/13,141). The real
  daemon/client E2E covers archive, frozen closed snapshots, two history pages,
  and archived ids; focused state and widget tests cover multi-host merge,
  reconnect invalidation, partial failure, cached-page preservation, host
  filtering, retry, empty, and paging UI.
- Frozen single-agent detail raises the serial protocol/daemon suite to 1,127
  passing cases and Flutter to 704. Refreshed changed-package gates pass at
  protocol 95.25% (5,790/6,079) and app 95.02% (12,496/13,151). One full
  serial run exposed the pre-existing selected-WebSocket-broadcast timing
  test; its single diagnostic rerun passed immediately, and a complete daemon
  rerun then passed all 812 daemon cases.

## Split drop center preview

- Preview bounds: `(328, 92)`, `864 x 700`
- Content inset: `8px`
- Overlay: `#20744a`, opacity `0.6`
- Frame: `2px #20744a`
- Radius: `6px`
- Drop target id: `split-pane-drop:<paneId>`

Reference: `paseo-0.2.0-split-drop-center-1200x800.png`.

The images were captured directly from the Electron renderer through its
isolated development CDP endpoint, so unrelated Windows dialogs and desktop
occlusion are not present in the evidence.
