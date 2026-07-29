import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/schedule_form_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace lifecycle follows host and project capabilities', () {
    final git = resolveScheduleWorkspaceLifecycle(
      supportsWorkspaceMultiplicity: true,
      hasProject: true,
      projectIsGit: true,
      isolation: 'worktree',
      archiveOnFinish: false,
    );
    expect(git.showIsolation, isTrue);
    expect(git.showArchiveOnFinish, isTrue);
    expect(git.effectiveIsolation, 'worktree');
    expect(git.submitIsolation, 'worktree');
    expect(git.submitArchiveOnFinish, isFalse);

    final plain = resolveScheduleWorkspaceLifecycle(
      supportsWorkspaceMultiplicity: true,
      hasProject: true,
      projectIsGit: false,
      isolation: 'worktree',
      archiveOnFinish: true,
    );
    expect(plain.showIsolation, isFalse);
    expect(plain.showArchiveOnFinish, isTrue);
    expect(plain.effectiveIsolation, 'local');
    expect(plain.submitIsolation, 'local');
    expect(plain.submitArchiveOnFinish, isTrue);

    final legacy = resolveScheduleWorkspaceLifecycle(
      supportsWorkspaceMultiplicity: false,
      hasProject: true,
      projectIsGit: true,
      isolation: 'worktree',
      archiveOnFinish: true,
    );
    expect(legacy.showIsolation, isFalse);
    expect(legacy.showArchiveOnFinish, isFalse);
    expect(legacy.effectiveIsolation, 'local');
    expect(legacy.submitIsolation, isNull);
    expect(legacy.submitArchiveOnFinish, isNull);
  });

  test('provider selection resolves frozen defaults from ready entries', () {
    final selection = resolveScheduleProviderSelection(
      entries: const [
        ProviderSnapshotEntry(
          provider: 'disabled',
          status: ProviderCatalogStatus.ready,
          enabled: false,
        ),
        ProviderSnapshotEntry(
          provider: 'codex',
          status: ProviderCatalogStatus.ready,
          defaultModeId: 'plan',
          modes: [
            ProviderMode(id: 'agent', label: 'Agent'),
            ProviderMode(id: 'plan', label: 'Plan'),
          ],
          models: [
            ProviderModelDefinition(
              provider: 'codex',
              id: 'small',
              label: 'Small',
            ),
            ProviderModelDefinition(
              provider: 'codex',
              id: 'large',
              label: 'Large',
              isDefault: true,
              defaultThinkingOptionId: 'high',
              thinkingOptions: [
                ProviderSelectOption(id: 'medium', label: 'Medium'),
                ProviderSelectOption(id: 'high', label: 'High'),
              ],
            ),
          ],
        ),
      ],
    );

    expect(selection.providers.map((entry) => entry.provider), ['codex']);
    expect(selection.provider, 'codex');
    expect(selection.model, 'large');
    expect(selection.modeId, 'plan');
    expect(selection.thinkingOptionId, 'high');
    expect(selection.isAvailable, isTrue);
  });

  test('provider and model changes discard incompatible option ids', () {
    final selection = resolveScheduleProviderSelection(
      entries: const [
        ProviderSnapshotEntry(
          provider: 'codex',
          status: ProviderCatalogStatus.ready,
          defaultModeId: 'agent',
          modes: [ProviderMode(id: 'agent', label: 'Agent')],
          models: [
            ProviderModelDefinition(
              provider: 'codex',
              id: 'gpt',
              label: 'GPT',
              thinkingOptions: [
                ProviderSelectOption(
                  id: 'medium',
                  label: 'Medium',
                  isDefault: true,
                ),
              ],
            ),
          ],
        ),
      ],
      selectedProvider: 'missing',
      selectedModel: 'missing',
      selectedModeId: 'plan',
      selectedThinkingOptionId: 'high',
    );

    expect(selection.provider, 'codex');
    expect(selection.model, 'gpt');
    expect(selection.modeId, 'agent');
    expect(selection.thinkingOptionId, 'medium');
  });

  test('loading, unavailable, and disabled providers cannot submit', () {
    final selection = resolveScheduleProviderSelection(
      entries: const [
        ProviderSnapshotEntry(
          provider: 'loading',
          status: ProviderCatalogStatus.loading,
        ),
        ProviderSnapshotEntry(
          provider: 'offline',
          status: ProviderCatalogStatus.unavailable,
        ),
        ProviderSnapshotEntry(
          provider: 'disabled',
          status: ProviderCatalogStatus.ready,
          enabled: false,
        ),
      ],
    );

    expect(selection.isAvailable, isFalse);
    expect(selection.provider, isEmpty);
    expect(selection.model, isEmpty);
  });

  test('cadence presets match frozen Paseo options', () {
    expect(
      scheduleCadencePresets.map(
        (preset) => (preset.id, preset.label, preset.expression),
      ),
      const [
        ('every-minute', 'Every minute', '* * * * *'),
        ('every-hour', 'Every hour', '0 * * * *'),
        ('daily-9', 'Daily 9:00', '0 9 * * *'),
        ('weekdays-9', 'Weekdays 9:00', '0 9 * * 1-5'),
        ('mondays-9', 'Mondays 9:00', '0 9 * * 1'),
      ],
    );
    expect(
      resolveCronPresetId(
        const CronScheduleCadence(expression: ' 0 9 * * 1-5 '),
      ),
      'weekdays-9',
    );
    expect(
      resolveCronPresetLabel(
        const CronScheduleCadence(expression: '30 8 * * 1-5'),
      ),
      'Custom cron',
    );
  });

  test('rolling intervals normalize to frozen cron cadence semantics', () {
    CronScheduleCadence normalize(int everyMs) => normalizeScheduleFormCadence(
      EveryScheduleCadence(everyMs: everyMs),
      'Asia/Seoul',
    );

    expect(normalize(60000).expression, '* * * * *');
    expect(normalize(5 * 60000).expression, '*/5 * * * *');
    expect(normalize(3600000).expression, '0 * * * *');
    expect(normalize(3 * 3600000).expression, '0 */3 * * *');
    expect(normalize(24 * 3600000).expression, '0 9 * * *');
    expect(normalize(2 * 24 * 3600000).expression, '0 9 */2 * *');
    expect(normalize(61000).expression, '* * * * *');
    expect(normalize(60000).timezone, 'Asia/Seoul');
    expect(
      normalizeScheduleFormCadence(
        const CronScheduleCadence(expression: '0 9 * * *'),
        'Asia/Seoul',
      ).timezone,
      'Asia/Seoul',
    );
  });

  test('cron validation and preview use frozen reader-facing copy', () {
    expect(validateScheduleCron(''), 'Enter a cron expression');
    expect(validateScheduleCron('61 * * * *'), 'Invalid minute value');
    expect(validateScheduleCron('0 9 * * 1-5'), isNull);

    expect(
      describeScheduleCron(
        const CronScheduleCadence(
          expression: '* * * * *',
          timezone: 'Asia/Seoul',
        ),
      ),
      'Every minute',
    );
    expect(
      describeScheduleCron(
        const CronScheduleCadence(
          expression: '30 8 * * 1-5',
          timezone: 'Asia/Seoul',
        ),
      ),
      'Weekdays at 08:30 Asia/Seoul',
    );
    expect(
      describeScheduleCron(
        const CronScheduleCadence(expression: '*/5 * * * *'),
      ),
      isNull,
    );
  });
}
