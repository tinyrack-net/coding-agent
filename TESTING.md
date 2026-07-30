# Test strategy

The porting loop uses three escalating gates. Do not run the entire workspace
after every small edit.

## 1. Smoke gate — every implementation slice

```powershell
pwsh tool/test.ps1 -Scope smoke
```

This runs a curated cross-package contract set with stable bounded
concurrency. For work limited to one package:

```powershell
pwsh tool/test.ps1 -Scope smoke -Package app
```

## 2. Feature gate — while implementing one feature

Pass only the directly affected regression files:

```powershell
pwsh tool/test.ps1 -Scope feature -Package app `
  -TestPath test/provider_model_selection_test.dart,test/draft_session_composer_test.dart
```

Use `-Repeat 3` while repairing a flaky test or concurrency-sensitive
behavior. A repeat is diagnostic evidence, not a substitute for a regression
assertion.

## 3. Core product gate — project to first conversation

After changing project registration, workspace creation, agent creation, or
conversation state, run the deterministic cross-package product gate:

```powershell
pwsh tool/test.ps1 -Scope core
```

This runs the real daemon WebSocket project/workspace and agent lifecycle
journeys together with the Flutter add-project, draft, and chat journeys. It
does not require an installed provider or API key. The protocol, daemon, and
app packages run in parallel, while Flutter and daemon tests retain their
stable worker caps. Relay and lifecycle packages stay in their own smoke and
integration gates because they are not on this product journey.

At any other large feature boundary, run every test in the affected package
without coverage:

```powershell
pwsh tool/test.ps1 -Scope integration -Package app
```

## 4. Full gate — milestones, release candidates, and CI

```powershell
pwsh tool/test.ps1 -Scope full
```

The full gate runs all five workspace packages concurrently. Each package also
uses bounded internal concurrency and independently enforces 95% coverage.
The CI matrix uses the same package-level coverage command. Worker counts scale
down automatically on smaller CI machines.

The Flutter cap is eight test processes. On the 32-logical-core reference
machine this avoids timer and socket starvation seen with the SDK's aggressive
default while completing the 802-test app suite in about one minute. The
daemon cap is four because its suite includes real subprocess and socket
tests. Other packages run with two to four workers while package-level
parallelism uses the remaining cores.

Never use `--concurrency=1` as a routine workaround. When a parallel run
stalls or flakes:

1. preserve the first failing test and output;
2. run that test alone once;
3. reproduce it three times through `-Repeat 3`;
4. fix shared ports, global state, unawaited work, or missing teardown;
5. rerun the affected feature gate and then its package integration gate.
