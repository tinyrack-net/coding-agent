# Paseo 0.2.0 parity

This directory is the acceptance source of truth for the Flutter/Dart port.
The reference is frozen in `baseline.json`; upstream `main` is not a moving
target.

`upstream_inventory.json` is generated from the frozen Paseo checkout. It
contains every runtime source unit plus separately extracted public routes,
wire message names, CLI command modules, keyboard actions, release features,
and product documentation.

`ledger.json` records implementation status for every inventory item:

- `not-started`: no equivalent implementation exists.
- `partial`: some behavior exists, but parity has not been demonstrated.
- `verified`: implementation and evidence both exist.

An item may only be marked `verified` when `implementation` and `evidence` are
non-empty. The final release gate requires every item to be verified.

## Commands

```powershell
# Refresh from the frozen local reference checkout.
dart run tool/parity.dart --write `
  --upstream C:\Users\winetree94\Workspaces\learn\paseo

# Validate committed inventory and ledger coverage (works in CI without Paseo).
dart run tool/parity.dart --check

# Record evidence for a completed item.
dart run tool/parity.dart --mark source-unit:packages/protocol/src/example.ts `
  --status verified `
  --implementation packages/protocol/lib/src/example.dart `
  --evidence packages/protocol/test/example_test.dart

# Also prove that a local checkout still matches the frozen inventory.
dart run tool/parity.dart --check `
  --upstream C:\Users\winetree94\Workspaces\learn\paseo

# Final release gate: no partial or unstarted items.
dart run tool/parity.dart --check --require-complete
```

Never hand-edit `upstream_inventory.json`. `ledger.json` is merge-preserved by
`--write`, so implementation status and evidence survive inventory refreshes.

## Latest verified slice

- Agent directory pagination uses Paseo's exact JSON/base64url cursor contract,
  stable sortable values, id tie-breaks, and `invalid_cursor` errors.
- Active and historical agent rows resolve project/workspace placement only
  from the authoritative registries and preserve unavailable providers.
- Client-version provider visibility and response-ordered `agent_update`
  bootstrap buffering/deduplication match the frozen session behavior.
- Internal system agents remain runtime-addressable but are excluded from
  global lists, identifier lookup, stream/state/attention events, provider
  subagent replicas, and persistence.
- Recent provider-session discovery now matches the frozen request/response
  contract, including native Claude history and Codex thread discovery,
  active-import filtering, archived-session visibility, and structured errors.
- Provider-session import now matches the frozen current and legacy requests,
  serialized duplicate protection, provider resume/history hydration, archived
  reactivation and rollback, workspace provisioning, and status/error events.
- `coding-agent import` now matches the frozen CLI contract for provider/session
  validation, repeated labels, cwd and host selection, daemon errors, and
  table/JSON/YAML/quiet output; `coding-agent agent import` is also accepted as
  an additive compatibility alias.
- The frozen `paseo.parent-agent-id` label is normalized as part of the public
  protocol and is cleared or reassigned correctly when an archived provider
  session is imported again.
- The import-session sheet view model matches host capability gating, provider
  aggregation/filtering, descriptor fallbacks, and empty/error state rules.
- The Flutter import-session surface now covers the frozen host gates,
  per-provider loading and partial failures, refresh/filter/empty states,
  import navigation, responsive bounds, and both workspace entry points.
- Provider snapshot updates now use a typed frozen wire event from daemon
  refresh through the Flutter client, with cwd-scoped durable cache state,
  refresh/error/loading transitions, and import-session reuse.
- Provider-native resume command templates match Codex, Claude, Pi, OMP, and
  OpenCode exactly; the consuming workspace tab menu remains tracked
  separately until its full action surface is ported.
- `coding-agent provider ls` now prefers the live daemon snapshot, falls back
  to the frozen static provider catalog when the daemon is unavailable, and
  matches the table, JSON, and quiet output contracts.
- `coding-agent provider models` now matches provider normalization, disabled
  provider errors, model/thinking metadata, empty results, and
  table/JSON/YAML/quiet output without falling back when the daemon is absent.
- Provider/model resolution is shared across CLI consumers and matches the
  frozen trimming, default-provider, slash shorthand, conflict detection, and
  structured validation contract.
- `list_commands_request` and `list_commands_response` now cross the typed
  protocol, daemon live/draft agent runtime, and Flutter client boundary with
  frozen command/skill metadata and future-kind fallback behavior.
- Flutter agent-command replicas now use exact session and draft identities,
  60-second session freshness, infinite draft freshness, connection/enabled
  gates, reconnect repair, and structured daemon errors.
- Claude initialize and commands-changed traffic now maintains the frozen
  root/skill slash-command catalog with rewind fallback, while Codex combines
  its compact builtin with app-server skills, filesystem fallback skills, and
  custom prompt metadata.
- Composer slash autocomplete now matches the frozen token discovery, scoring,
  client-first merge, inline skill filtering, keyboard/pointer selection, and
  immediate `/exit` and `/clear` state transitions. Workspace `@` mentions
  now take precedence, debounce daemon-owned workspace search for 180ms,
  retain previous results while fetching, expose loading/error/empty states,
  and insert safely quoted relative paths.
- Workspace draft composers no longer use the conflicting API-key provider
  enum. They consume the cwd-scoped provider snapshot, reconcile provider
  defaults for model, mode, and thinking, submit the v2 configuration, and
  expose the same provider-command and workspace-file autocomplete branch.
- Draft provider features now cross the typed
  `list_provider_features_request/response` boundary with the frozen
  no-model short circuit, availability errors, request correlation, and
  90-second client timeout. Flutter keys discovery by provider, cwd, mode,
  model, and thinking; caches for five minutes; repairs on reconnect; resolves
  provider-scoped persisted preferences with local choices taking precedence;
  keeps untouched provider defaults out of create requests; renders
  toggle/select controls; and propagates selected values into command
  discovery and agent creation.
- Create-agent preferences now use one Tinyrack-branded JSON document with
  validated provider/model/mode/thinking/feature/isolation fields, a singleton
  load cache, and a serialized update queue. Workspace drafts restore and
  persist feature selections independently for each provider.
- Daemon feature discovery now crosses a provider-owned probe boundary:
  capable clients answer directly, session-dependent providers use a
  disposable temporary session, and the catalog service no longer owns the
  runtime result. Generic ACP/custom provider process probing remains tracked
  as a separate partial item.
- `directory_suggestions_request/response` now cross the typed protocol,
  daemon, Flutter client, and real v2 WebSocket boundary. The daemon ports the
  frozen relative/absolute, fuzzy/suffix, path-query, hidden-directory,
  depth/scan-budget, round-robin, ranking, and legacy-directory behavior.
- Provider snapshots now complete the frozen connection and feature gates,
  connected-host home prefetch, scoped push application, agent-command
  invalidation, and home-scope root invalidation contracts.
- The combined model selector now preserves the frozen single-provider versus
  all-provider opening rule, cross-provider drilldown, synthetic Default model,
  stale labels, favorites, loading/error/retry states, and multi-field fuzzy
  ranking across both New Workspace and workspace draft creation.
- Provider/model/mode/thinking/favorite choices now persist per provider from
  both Flutter creation surfaces without late preference hydration overwriting
  a user's current selection.
- Workspace draft submission now uses the frozen readiness priority and exact
  observable reasons for prompt, provider, model loading, missing model,
  workspace directory, and host connection failures; attachment-only and
  prepared empty auto-submit attempts retain their upstream behavior.
- `coding-agent run` and `coding-agent agent run` now match the frozen
  foreground/background command, workspace precedence and creation policy,
  provider/model/thinking/mode selection, images, labels, per-agent environment
  overlays, structured-output validation/retry, errors, and output formats.
  The typed create-agent status and real WebSocket lifecycle are covered
  end-to-end, including caller-owned child placement.
- Frozen create-agent legacy `git` and `worktreeName` inputs now preserve
  branch-only and worktree placement, while `outputSchema` reaches the Codex
  provider turn boundary.
- Schedule CLI create/list/inspect/logs/pause/resume/run-once/update/delete now
  matches frozen action-specific options, validation order, stable table/JSON
  projections, structured errors, help, and the real daemon lifecycle.
- Ledger status: 419 verified, 239 partial, and 1262 not-started out of 1920.
- Validation: protocol 332 tests, daemon 898 tests, Flutter 802 tests, root
  analysis, frozen
  inventory validation, and package coverage of protocol 95.24%, relay 95.17%,
  daemon lifecycle 100%, daemon 95.02%, and app 95.05% passed on 2026-07-28.
  The current daemon coverage run completed all 898 tests cleanly and serially.
