import 'package:agent_daemon/src/agent/create_agent_mode.dart';
import 'package:test/test.dart';

void main() {
  const claudeModes = ['default', 'acceptEdits', 'plan', 'bypassPermissions'];
  const openCodeModes = ['build', 'plan'];
  const codexModes = ['auto', 'full-access'];

  AgentCreateModeParent parent(
    String provider,
    String? modeId, {
    bool isUnattended = false,
  }) => AgentCreateModeParent(
    provider: provider,
    modeId: modeId,
    isUnattended: isUnattended,
  );

  test('returns a valid explicitly requested mode', () {
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: 'plan',
        targetProvider: 'opencode',
        parent: null,
        unattended: false,
        availableModes: openCodeModes,
      ),
      'plan',
    );
  });

  test('rejects an explicit mode unavailable from the target provider', () {
    expect(
      () => resolveAndValidateCreateAgentMode(
        requestedMode: 'bypassPermissions',
        targetProvider: 'opencode',
        parent: null,
        unattended: false,
        availableModes: openCodeModes,
      ),
      throwsA(
        _stateError(
          "Invalid mode 'bypassPermissions' for provider 'opencode'. "
          'Available modes: build, plan',
        ),
      ),
    );
  });

  test('uses provider default without a requested mode or parent', () {
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'claude',
        parent: null,
        unattended: false,
        availableModes: claudeModes,
      ),
      isNull,
    );
  });

  test('inherits the same-provider parent mode including null', () {
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'claude',
        parent: parent('claude', 'bypassPermissions'),
        unattended: false,
        availableModes: claudeModes,
      ),
      'bypassPermissions',
    );
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'claude',
        parent: parent('claude', null),
        unattended: false,
        availableModes: claudeModes,
      ),
      isNull,
    );
  });

  test('refuses cross-provider inheritance with exact diagnostics', () {
    expect(
      () => resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'opencode',
        parent: parent('claude', 'bypassPermissions'),
        unattended: false,
        availableModes: openCodeModes,
      ),
      throwsA(
        _stateError(
          "cannot inherit mode 'bypassPermissions' from caller "
          "(provider 'claude') for new agent (provider 'opencode'). "
          "Pass an explicit mode. Available modes for 'opencode': build, plan",
        ),
      ),
    );
    expect(
      () => resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'codex',
        parent: parent('opencode', null),
        unattended: false,
        availableModes: codexModes,
      ),
      throwsA(
        _stateError(
          "cannot inherit mode '<none>' from caller (provider 'opencode') "
          "for new agent (provider 'codex'). Pass an explicit mode. "
          "Available modes for 'codex': auto, full-access",
        ),
      ),
    );
  });

  test('uses provider default for cross-provider targets with no modes', () {
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'pi',
        parent: parent('codex', 'auto'),
        unattended: false,
        availableModes: const [],
      ),
      isNull,
    );
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'pi',
        parent: parent('claude', 'bypassPermissions', isUnattended: true),
        unattended: false,
        availableModes: const [],
      ),
      isNull,
    );
  });

  test('passes explicit modes through when target modes are unknown', () {
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: 'default',
        targetProvider: 'zai-custom',
        parent: null,
        unattended: false,
        availableModes: null,
      ),
      'default',
    );
  });

  test('renders unknown for cross-provider targets with unknown modes', () {
    expect(
      () => resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'zai-custom',
        parent: parent('claude', 'default'),
        unattended: false,
        availableModes: null,
      ),
      throwsA(
        _stateError(
          "cannot inherit mode 'default' from caller (provider 'claude') "
          "for new agent (provider 'zai-custom'). Pass an explicit mode. "
          "Available modes for 'zai-custom': unknown",
        ),
      ),
    );
  });

  test('bridges unattended creation to the target unattended mode', () {
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'codex',
        parent: parent('claude', 'bypassPermissions', isUnattended: true),
        unattended: false,
        availableModes: codexModes,
        targetUnattendedMode: 'full-access',
      ),
      'full-access',
    );
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'codex',
        parent: null,
        unattended: true,
        availableModes: codexModes,
        targetUnattendedMode: 'full-access',
      ),
      'full-access',
    );
  });

  test('does not bridge attended parents or targets without a bridge', () {
    expect(
      () => resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'codex',
        parent: parent('claude', 'default'),
        unattended: false,
        availableModes: codexModes,
        targetUnattendedMode: 'full-access',
      ),
      throwsA(
        _stateError(
          "cannot inherit mode 'default' from caller (provider 'claude') "
          "for new agent (provider 'codex'). Pass an explicit mode. "
          "Available modes for 'codex': auto, full-access",
        ),
      ),
    );
    expect(
      () => resolveAndValidateCreateAgentMode(
        requestedMode: null,
        targetProvider: 'zai-custom',
        parent: parent('claude', 'bypassPermissions', isUnattended: true),
        unattended: false,
        availableModes: null,
      ),
      throwsA(
        _stateError(
          "cannot inherit mode 'bypassPermissions' from caller "
          "(provider 'claude') for new agent (provider 'zai-custom'). "
          "Pass an explicit mode. Available modes for 'zai-custom': unknown",
        ),
      ),
    );
  });

  test('explicit mode wins over unattended inheritance', () {
    expect(
      resolveAndValidateCreateAgentMode(
        requestedMode: 'auto',
        targetProvider: 'codex',
        parent: parent('claude', 'bypassPermissions', isUnattended: true),
        unattended: false,
        availableModes: codexModes,
        targetUnattendedMode: 'full-access',
      ),
      'auto',
    );
  });

  test('classifies only the selected unattended mode as unattended', () {
    const modes = {'default': false, 'bypassPermissions': true};
    expect(
      isDefaultAgentCreateConfigUnattended(
        modeId: null,
        unattendedModes: modes,
      ),
      isFalse,
    );
    expect(
      isDefaultAgentCreateConfigUnattended(
        modeId: 'default',
        unattendedModes: modes,
      ),
      isFalse,
    );
    expect(
      isDefaultAgentCreateConfigUnattended(
        modeId: 'bypassPermissions',
        unattendedModes: modes,
      ),
      isTrue,
    );
  });
}

Matcher _stateError(String message) =>
    isA<StateError>().having((error) => error.message, 'message', message);
