// Port of Paseo 0.2.0's `provider-selection/resolve-agent-form.test.ts`, plus a
// small "additional coverage" group for exported helpers and reducer actions the
// upstream suite exercises only indirectly.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/create_agent_preferences.dart';
import 'package:coding_agent_app/provider_selection/paseo_resolve_agent_form.dart';
import 'package:flutter_test/flutter_test.dart';

const testCodexModes = <ProviderMode>[
  ProviderMode(
    id: 'auto',
    label: 'Auto',
    icon: 'ShieldAlert',
    colorTier: 'moderate',
  ),
  ProviderMode(
    id: 'full-access',
    label: 'Full Access',
    icon: 'ShieldAlert',
    colorTier: 'dangerous',
  ),
];

const testCodexDefinition = AgentProviderDefinition(
  id: 'codex',
  label: 'Codex',
  description: 'Codex test provider',
  defaultModeId: 'auto',
  modes: testCodexModes,
);

const testClaudeDefinition = AgentProviderDefinition(
  id: 'claude',
  label: 'Claude',
  description: 'Claude test provider',
  defaultModeId: 'default',
  modes: [
    ProviderMode(
      id: 'default',
      label: 'Always Ask',
      icon: 'ShieldCheck',
      colorTier: 'safe',
    ),
    ProviderMode(
      id: 'acceptEdits',
      label: 'Accept File Edits',
      icon: 'ShieldAlert',
      colorTier: 'moderate',
    ),
    ProviderMode(
      id: 'plan',
      label: 'Plan Mode',
      icon: 'ShieldCheck',
      colorTier: 'planning',
    ),
    ProviderMode(
      id: 'bypassPermissions',
      label: 'Bypass',
      icon: 'ShieldAlert',
      colorTier: 'dangerous',
    ),
  ],
);

const codexModels = <ProviderModelDefinition>[
  ProviderModelDefinition(
    provider: 'codex',
    id: 'gpt-5.3-codex',
    label: 'gpt-5.3-codex',
    isDefault: true,
    defaultThinkingOptionId: 'xhigh',
    thinkingOptions: [
      ProviderSelectOption(id: 'low', label: 'low'),
      ProviderSelectOption(id: 'xhigh', label: 'xhigh', isDefault: true),
    ],
  ),
];

Map<String, AgentProviderDefinition> makeProviderMap(
  List<AgentProviderDefinition> definitions,
) => {for (final definition in definitions) definition.id: definition};

final codexProviderMap = makeProviderMap([testCodexDefinition]);
final claudeProviderMap = makeProviderMap([testClaudeDefinition]);
final bothProviderMap = makeProviderMap([
  testCodexDefinition,
  testClaudeDefinition,
]);

AgentFormReducerState makeState({
  String? serverId,
  String? provider,
  String modeId = '',
  String model = '',
  String thinkingOptionId = '',
  String workingDir = '',
  UserModifiedFields modified = initialUserModified,
  AgentFormResolutionState resolution = pendingAgentFormResolution,
}) => AgentFormReducerState(
  form: FormState(
    serverId: serverId,
    provider: provider,
    modeId: modeId,
    model: model,
    thinkingOptionId: thinkingOptionId,
    workingDir: workingDir,
  ),
  userModified: modified,
  resolution: resolution,
);

ProviderModelsByProvider makeProviderModelsByProvider(
  Map<String, List<ProviderModelDefinition>?> entries,
) => {...entries};

Map<String, Object?> definitionToJson(AgentProviderDefinition definition) => {
  'id': definition.id,
  'label': definition.label,
  'description': definition.description,
  'defaultModeId': definition.defaultModeId,
  'modes': [for (final mode in definition.modes) mode.toJson()],
};

void main() {
  group('resolveDefaultModel', () {
    test('returns null for empty or null input', () {
      expect(resolveDefaultModel(null), isNull);
      expect(resolveDefaultModel(const []), isNull);
    });

    test('returns the model marked isDefault', () {
      const models = <ProviderModelDefinition>[
        ProviderModelDefinition(
          provider: 'codex',
          id: 'a',
          label: 'A',
          isDefault: false,
        ),
        ProviderModelDefinition(
          provider: 'codex',
          id: 'b',
          label: 'B',
          isDefault: true,
        ),
      ];
      expect(resolveDefaultModel(models)?.id, 'b');
    });

    test('falls back to the first model when none is marked default', () {
      const models = <ProviderModelDefinition>[
        ProviderModelDefinition(
          provider: 'codex',
          id: 'a',
          label: 'A',
          isDefault: false,
        ),
        ProviderModelDefinition(
          provider: 'codex',
          id: 'b',
          label: 'B',
          isDefault: false,
        ),
      ];
      expect(resolveDefaultModel(models)?.id, 'a');
    });
  });

  group('resolveThinkingOptionId', () {
    test('returns empty string when model has no thinking options', () {
      const modelsWithoutThinking = <ProviderModelDefinition>[
        ProviderModelDefinition(
          provider: 'claude',
          id: 'claude-sonnet-4-6',
          label: 'Sonnet 4.6',
          isDefault: true,
        ),
      ];
      expect(
        resolveThinkingOptionId(
          availableModels: modelsWithoutThinking,
          modelId: 'claude-sonnet-4-6',
          requestedThinkingOptionId: '',
        ),
        '',
      );
    });

    test('returns the requested option when it is valid', () {
      expect(
        resolveThinkingOptionId(
          availableModels: codexModels,
          modelId: 'gpt-5.3-codex',
          requestedThinkingOptionId: 'low',
        ),
        'low',
      );
    });

    test(
      'falls back to defaultThinkingOptionId when requested option is invalid',
      () {
        expect(
          resolveThinkingOptionId(
            availableModels: codexModels,
            modelId: 'gpt-5.3-codex',
            requestedThinkingOptionId: 'invalid',
          ),
          'xhigh',
        );
      },
    );

    test(
      'falls back to first option when no default and requested is invalid',
      () {
        const modelsNoDefault = <ProviderModelDefinition>[
          ProviderModelDefinition(
            provider: 'codex',
            id: 'm',
            label: 'M',
            isDefault: true,
            thinkingOptions: [
              ProviderSelectOption(id: 'low', label: 'Low'),
              ProviderSelectOption(id: 'high', label: 'High'),
            ],
          ),
        ];
        expect(
          resolveThinkingOptionId(
            availableModels: modelsNoDefault,
            modelId: 'm',
            requestedThinkingOptionId: '',
          ),
          'low',
        );
      },
    );
  });

  group('combineInitialValues', () {
    test(
      'returns undefined when no initial values and no initial server id',
      () {
        expect(combineInitialValues(null, null), isNull);
      },
    );

    test(
      'does not inject a null serverId override when initialValues are present '
      'but serverId is absent',
      () {
        final combined = combineInitialValues(const FormInitialValues(), null);
        expect(combined, const FormInitialValues());
        expect(combined!.hasServerId, isFalse);
      },
    );

    test('injects serverId from options when provided', () {
      expect(
        combineInitialValues(const FormInitialValues(), 'daemon-1'),
        const FormInitialValues.withServerId('daemon-1'),
      );
    });

    test('keeps other initial values without forcing serverId', () {
      final combined = combineInitialValues(
        const FormInitialValues(workingDir: '/repo'),
        null,
      );
      expect(combined, const FormInitialValues(workingDir: '/repo'));
      expect(combined!.hasServerId, isFalse);
    });

    test('respects an explicit serverId override (including null) over '
        'initialServerId', () {
      expect(
        combineInitialValues(
          const FormInitialValues.withServerId(null),
          'daemon-1',
        ),
        const FormInitialValues.withServerId(null),
      );
      expect(
        combineInitialValues(
          const FormInitialValues.withServerId('daemon-2'),
          'daemon-1',
        ),
        const FormInitialValues.withServerId('daemon-2'),
      );
    });
  });

  group('mergeSelectedComposerPreferences', () {
    test('stores the selected model for the selected provider', () {
      expect(
        mergeSelectedComposerPreferences(
          preferences: const CreateAgentPreferences(),
          provider: 'codex',
          model: 'gpt-5.4',
        ).toJson(),
        {
          'provider': 'codex',
          'providerPreferences': {
            'codex': {'model': 'gpt-5.4'},
          },
        },
      );
    });

    test(
      'preserves existing provider preferences when the selected model changes',
      () {
        expect(
          mergeSelectedComposerPreferences(
            preferences: const CreateAgentPreferences(
              provider: 'claude',
              providerPreferences: {
                'codex': ProviderCreateAgentPreferences(
                  mode: 'full-access',
                  thinkingByModel: {'gpt-5.4-mini': 'medium'},
                  featureValues: {'fast_mode': true},
                ),
                'claude': ProviderCreateAgentPreferences(
                  model: 'claude-sonnet-4-6',
                ),
              },
              favoriteModels: [
                FavoriteModelPreference(
                  provider: 'codex',
                  modelId: 'gpt-5.4-mini',
                ),
              ],
            ),
            provider: 'codex',
            model: 'gpt-5.4',
          ).toJson(),
          {
            'provider': 'codex',
            'providerPreferences': {
              'codex': {
                'model': 'gpt-5.4',
                'mode': 'full-access',
                'thinkingByModel': {'gpt-5.4-mini': 'medium'},
                'featureValues': {'fast_mode': true},
              },
              'claude': {'model': 'claude-sonnet-4-6'},
            },
            'favoriteModels': [
              {'provider': 'codex', 'modelId': 'gpt-5.4-mini'},
            ],
          },
        );
      },
    );

    test(
      'stores mode and thinking preferences without dropping the selected model',
      () {
        expect(
          mergeSelectedComposerPreferences(
            preferences: const CreateAgentPreferences(
              provider: 'codex',
              providerPreferences: {
                'codex': ProviderCreateAgentPreferences(
                  model: 'gpt-5.4',
                  mode: 'auto',
                  thinkingByModel: {'gpt-5.4-mini': 'low'},
                ),
              },
            ),
            provider: 'codex',
            mode: 'full-access',
            thinkingByModel: {'gpt-5.4': 'xhigh'},
          ).toJson(),
          {
            'provider': 'codex',
            'providerPreferences': {
              'codex': {
                'model': 'gpt-5.4',
                'mode': 'full-access',
                'thinkingByModel': {'gpt-5.4-mini': 'low', 'gpt-5.4': 'xhigh'},
              },
            },
          },
        );
      },
    );
  });

  group('buildProviderDefinitions', () {
    test('returns empty array when snapshot data is unavailable', () {
      expect(buildProviderDefinitions(null), isEmpty);
      expect(buildProviderDefinitions(const []), isEmpty);
    });

    test('builds provider definitions from snapshot metadata', () {
      const entries = <ProviderSnapshotEntry>[
        ProviderSnapshotEntry(
          provider: 'zai',
          status: ProviderCatalogStatus.ready,
          label: 'ZAI',
          description: 'Claude with ZAI config',
          defaultModeId: 'default',
          modes: [
            ProviderMode(
              id: 'default',
              label: 'Default',
              description: 'Safe mode',
              icon: 'ShieldCheck',
              colorTier: 'safe',
            ),
          ],
        ),
      ];

      expect(buildProviderDefinitions(entries).map(definitionToJson).toList(), [
        {
          'id': 'zai',
          'label': 'ZAI',
          'description': 'Claude with ZAI config',
          'defaultModeId': 'default',
          'modes': [
            {
              'id': 'default',
              'label': 'Default',
              'description': 'Safe mode',
              'icon': 'ShieldCheck',
              'colorTier': 'safe',
            },
          ],
        },
      ]);
    });
  });

  group('resolveFormState', () {
    test(
      'keeps provider, mode, and model unset on first open without preferences '
      'or explicit values',
      () {
        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(),
          null,
          initialUserModified,
          makeState().form,
          bothProviderMap,
        );

        expect(resolved.provider, isNull);
        expect(resolved.modeId, '');
        expect(resolved.model, '');
        expect(resolved.thinkingOptionId, '');
      },
    );

    test(
      'does not auto-select a model on fresh drafts without preferences',
      () {
        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(provider: 'codex'),
          codexModels,
          initialUserModified,
          makeState(provider: 'codex').form,
          codexProviderMap,
        );

        expect(resolved.model, '');
        expect(resolved.thinkingOptionId, '');
      },
    );

    test(
      'auto-selects the model default thinking option when model is preferred '
      'but thinking is not',
      () {
        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(
            provider: 'codex',
            providerPreferences: {
              'codex': ProviderCreateAgentPreferences(model: 'gpt-5.3-codex'),
            },
          ),
          codexModels,
          initialUserModified,
          makeState(provider: 'codex').form,
          codexProviderMap,
        );

        expect(resolved.model, 'gpt-5.3-codex');
        expect(resolved.thinkingOptionId, 'xhigh');
      },
    );

    test(
      'falls back to model default when saved thinking preference is invalid',
      () {
        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(
            provider: 'codex',
            providerPreferences: {
              'codex': ProviderCreateAgentPreferences(model: 'gpt-5.3-codex'),
            },
          ),
          codexModels,
          initialUserModified,
          makeState(provider: 'codex').form,
          codexProviderMap,
        );

        expect(resolved.thinkingOptionId, 'xhigh');
      },
    );

    test(
      "normalizes legacy model id 'default' from initial values to the provider "
      'default model',
      () {
        final resolved = resolveFormState(
          const FormInitialValues(model: 'default'),
          const CreateAgentPreferences(provider: 'codex'),
          codexModels,
          initialUserModified,
          makeState(provider: 'codex').form,
          codexProviderMap,
        );

        expect(resolved.model, 'gpt-5.3-codex');
      },
    );

    test('keeps an explicit initial thinking option when it is valid', () {
      final resolved = resolveFormState(
        const FormInitialValues(
          model: 'gpt-5.3-codex',
          thinkingOptionId: 'low',
        ),
        const CreateAgentPreferences(provider: 'codex'),
        codexModels,
        initialUserModified,
        makeState(provider: 'codex').form,
        codexProviderMap,
      );

      expect(resolved.model, 'gpt-5.3-codex');
      expect(resolved.thinkingOptionId, 'low');
    });

    test('falls back to the first thinking option when model exposes options '
        'without a provider default', () {
      const claudeWithThinking = <ProviderModelDefinition>[
        ProviderModelDefinition(
          provider: 'claude',
          id: 'default',
          label: 'Default (Sonnet 4.6)',
          isDefault: true,
          thinkingOptions: [
            ProviderSelectOption(id: 'low', label: 'Low'),
            ProviderSelectOption(id: 'medium', label: 'Medium'),
          ],
        ),
      ];

      final resolved = resolveFormState(
        null,
        const CreateAgentPreferences(
          provider: 'claude',
          providerPreferences: {
            'claude': ProviderCreateAgentPreferences(model: 'default'),
          },
        ),
        claudeWithThinking,
        initialUserModified,
        makeState(provider: 'claude').form,
        claudeProviderMap,
      );

      expect(resolved.model, 'default');
      expect(resolved.thinkingOptionId, 'low');
    });

    test(
      'clears an invalid provider instead of falling back to the first allowed '
      'provider',
      () {
        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(provider: 'codex'),
          null,
          initialUserModified,
          makeState(provider: 'codex').form,
          claudeProviderMap,
        );

        expect(resolved.provider, isNull);
      },
    );

    test('preserves a user-selected provider and model while that provider is '
        'loading during refresh', () {
      const loadingEntries = <ProviderSnapshotEntry>[
        ProviderSnapshotEntry(
          provider: 'codex',
          status: ProviderCatalogStatus.loading,
          label: 'Codex',
          description: 'Codex test provider',
          defaultModeId: 'auto',
          modes: [
            ProviderMode(
              id: 'auto',
              label: 'Auto',
              icon: 'ShieldAlert',
              colorTier: 'moderate',
            ),
            ProviderMode(
              id: 'full-access',
              label: 'Full Access',
              icon: 'ShieldAlert',
              colorTier: 'dangerous',
            ),
          ],
        ),
        ProviderSnapshotEntry(
          provider: 'claude',
          status: ProviderCatalogStatus.ready,
          label: 'Claude',
          description: 'Claude test provider',
          defaultModeId: 'default',
          modes: [
            ProviderMode(
              id: 'default',
              label: 'Always Ask',
              icon: 'ShieldCheck',
              colorTier: 'safe',
            ),
          ],
          models: [
            ProviderModelDefinition(
              provider: 'claude',
              id: 'default',
              label: 'Default',
              isDefault: true,
            ),
          ],
        ),
      ];
      final providerDefinitions = buildProviderDefinitions(loadingEntries);
      final resolvableProviderMap = buildProviderDefinitionMapForStatuses(
        snapshotEntries: loadingEntries,
        providerDefinitions: providerDefinitions,
        statuses: const {
          ProviderCatalogStatus.ready,
          ProviderCatalogStatus.loading,
        },
      );

      final resolved = resolveFormState(
        null,
        const CreateAgentPreferences(),
        null,
        const UserModifiedFields(
          provider: true,
          modeId: true,
          model: true,
          thinkingOptionId: true,
        ),
        makeState(
          provider: 'codex',
          modeId: 'full-access',
          model: 'gpt-5.3-codex',
          thinkingOptionId: 'xhigh',
        ).form,
        resolvableProviderMap,
      );

      expect(resolved.provider, 'codex');
      expect(resolved.modeId, 'full-access');
      expect(resolved.model, 'gpt-5.3-codex');
      expect(resolved.thinkingOptionId, 'xhigh');
    });

    test(
      'preserves the saved mode while provider modes are absent from a loading '
      'snapshot',
      () {
        const loadingEntries = <ProviderSnapshotEntry>[
          ProviderSnapshotEntry(
            provider: 'codex',
            status: ProviderCatalogStatus.loading,
            label: 'Codex',
            description: 'Codex test provider',
            defaultModeId: 'auto',
          ),
        ];
        final providerDefinitions = buildProviderDefinitions(loadingEntries);
        final resolvableProviderMap = buildProviderDefinitionMapForStatuses(
          snapshotEntries: loadingEntries,
          providerDefinitions: providerDefinitions,
          statuses: const {
            ProviderCatalogStatus.ready,
            ProviderCatalogStatus.loading,
          },
        );

        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(
            provider: 'codex',
            providerPreferences: {
              'codex': ProviderCreateAgentPreferences(
                mode: 'full-access',
                model: 'gpt-5.3-codex',
              ),
            },
          ),
          null,
          initialUserModified,
          makeState(
            provider: 'codex',
            modeId: 'full-access',
            model: 'gpt-5.3-codex',
          ).form,
          resolvableProviderMap,
        );

        expect(resolved.provider, 'codex');
        expect(resolved.modeId, 'full-access');
      },
    );

    test('preserves a saved mode that is not in the current mode list', () {
      final resolved = resolveFormState(
        null,
        const CreateAgentPreferences(
          provider: 'codex',
          providerPreferences: {
            'codex': ProviderCreateAgentPreferences(
              mode: 'workspace-write',
              model: 'gpt-5.3-codex',
            ),
          },
        ),
        codexModels,
        initialUserModified,
        makeState(provider: 'codex').form,
        codexProviderMap,
      );

      expect(resolved.provider, 'codex');
      expect(resolved.modeId, 'workspace-write');
    });

    test(
      'falls back when the provider cannot advertise its preferred default mode',
      () {
        final providerMap = makeProviderMap([
          const AgentProviderDefinition(
            id: 'codex',
            label: 'Codex',
            description: 'Codex test provider',
            defaultModeId: 'auto-review',
            modes: testCodexModes,
          ),
        ]);

        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(provider: 'codex'),
          codexModels,
          initialUserModified,
          makeState(provider: 'codex').form,
          providerMap,
        );

        expect(resolved.modeId, 'auto');
      },
    );

    test(
      'ignores disabled ready providers when resolving selectable defaults',
      () {
        const entries = <ProviderSnapshotEntry>[
          ProviderSnapshotEntry(
            provider: 'codex',
            status: ProviderCatalogStatus.ready,
            label: 'Codex',
            description: 'Codex test provider',
            defaultModeId: 'auto',
            modes: [
              ProviderMode(
                id: 'auto',
                label: 'Auto',
                icon: 'ShieldAlert',
                colorTier: 'moderate',
              ),
              ProviderMode(
                id: 'full-access',
                label: 'Full Access',
                icon: 'ShieldAlert',
                colorTier: 'dangerous',
              ),
            ],
          ),
          ProviderSnapshotEntry(
            provider: 'claude',
            status: ProviderCatalogStatus.ready,
            enabled: false,
            label: 'Claude',
            description: 'Claude test provider',
            defaultModeId: 'default',
            modes: [
              ProviderMode(
                id: 'default',
                label: 'Always Ask',
                icon: 'ShieldCheck',
                colorTier: 'safe',
              ),
            ],
          ),
        ];
        final providerDefinitions = buildProviderDefinitions(entries);
        final selectableProviderMap = buildProviderDefinitionMapForStatuses(
          snapshotEntries: entries,
          providerDefinitions: providerDefinitions,
          statuses: const {ProviderCatalogStatus.ready},
        );

        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(provider: 'claude'),
          null,
          initialUserModified,
          makeState(provider: 'codex').form,
          selectableProviderMap,
        );

        expect(resolved.provider, 'codex');
        expect(resolved.modeId, 'auto');
      },
    );

    test('excludes disabled providers from the selectable provider map without '
        'removing them from snapshot definitions', () {
      const entries = <ProviderSnapshotEntry>[
        ProviderSnapshotEntry(
          provider: 'codex',
          status: ProviderCatalogStatus.ready,
          label: 'Codex',
          description: 'Codex test provider',
          defaultModeId: 'auto',
        ),
        ProviderSnapshotEntry(
          provider: 'claude',
          status: ProviderCatalogStatus.ready,
          enabled: false,
          label: 'Claude',
          description: 'Claude test provider',
          defaultModeId: 'default',
        ),
      ];
      final providerDefinitions = buildProviderDefinitions(entries);

      final selectableProviderMap = buildProviderDefinitionMapForStatuses(
        snapshotEntries: entries,
        providerDefinitions: providerDefinitions,
        statuses: const {ProviderCatalogStatus.ready},
      );

      expect(selectableProviderMap.keys.toList(), ['codex']);
      expect(providerDefinitions.map((d) => d.id).toList(), [
        'codex',
        'claude',
      ]);
    });

    test('clears a user-selected provider when the refreshed snapshot marks it '
        'unavailable', () {
      const unavailableEntries = <ProviderSnapshotEntry>[
        ProviderSnapshotEntry(
          provider: 'codex',
          status: ProviderCatalogStatus.unavailable,
          label: 'Codex',
          description: 'Codex test provider',
          defaultModeId: 'auto',
        ),
        ProviderSnapshotEntry(
          provider: 'claude',
          status: ProviderCatalogStatus.ready,
          label: 'Claude',
          description: 'Claude test provider',
          defaultModeId: 'default',
          models: [
            ProviderModelDefinition(
              provider: 'claude',
              id: 'default',
              label: 'Default',
              isDefault: true,
            ),
          ],
        ),
      ];
      final providerDefinitions = buildProviderDefinitions(unavailableEntries);
      final resolvableProviderMap = buildProviderDefinitionMapForStatuses(
        snapshotEntries: unavailableEntries,
        providerDefinitions: providerDefinitions,
        statuses: const {
          ProviderCatalogStatus.ready,
          ProviderCatalogStatus.loading,
        },
      );

      final resolved = resolveFormState(
        null,
        const CreateAgentPreferences(),
        null,
        const UserModifiedFields(provider: true),
        makeState(
          provider: 'codex',
          modeId: 'full-access',
          model: 'gpt-5.3-codex',
          thinkingOptionId: 'xhigh',
        ).form,
        resolvableProviderMap,
      );

      expect(resolved.provider, isNull);
      expect(resolved.modeId, '');
      expect(resolved.model, '');
      expect(resolved.thinkingOptionId, '');
    });

    test(
      'does not force fallback provider when allowed provider map is empty',
      () {
        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(provider: 'codex'),
          null,
          initialUserModified,
          makeState(provider: 'codex').form,
          <String, AgentProviderDefinition>{},
        );

        expect(resolved.provider, 'codex');
      },
    );
  });

  group('resolveAgentForm', () {
    group('resolution state', () {
      test('requests resolution without changing the current form values', () {
        final state = makeState(
          provider: 'codex',
          modeId: 'auto',
          model: 'gpt-5.3-codex',
          modified: const UserModifiedFields(provider: true, model: true),
          resolution: AgentFormResolutionState.completed,
        );
        final next = resolveAgentForm(
          state,
          const AgentFormRequestResolution(),
        );

        expect(next.form, state.form);
        expect(next.userModified, initialUserModified);
        expect(next.resolution, AgentFormResolutionState.pending);
      });

      test(
        'completes a pending open resolution when snapshot models arrive late',
        () {
          final state = resolveAgentForm(
            makeState(serverId: 'host-1'),
            const AgentFormRequestResolution(),
          );
          final next = resolveAgentForm(
            state,
            AgentFormCompleteResolution(
              preferences: const CreateAgentPreferences(
                provider: 'codex',
                providerPreferences: {
                  'codex': ProviderCreateAgentPreferences(
                    model: 'gpt-5.3-codex',
                  ),
                },
              ),
              providerModelsByProvider: makeProviderModelsByProvider({
                'codex': codexModels,
              }),
              allowedProviderMap: codexProviderMap,
            ),
          );

          expect(next.form.provider, 'codex');
          expect(next.form.modeId, 'auto');
          expect(next.form.model, 'gpt-5.3-codex');
          expect(next.form.thinkingOptionId, 'xhigh');
          expect(next.resolution, AgentFormResolutionState.completed);
        },
      );

      test('does not change settled selection when a background snapshot has '
          'different defaults', () {
        final settled = resolveAgentForm(
          makeState(serverId: 'host-1'),
          AgentFormCompleteResolution(
            preferences: const CreateAgentPreferences(
              provider: 'codex',
              providerPreferences: {
                'codex': ProviderCreateAgentPreferences(model: 'gpt-5.3-codex'),
              },
            ),
            providerModelsByProvider: makeProviderModelsByProvider({
              'codex': codexModels,
            }),
            allowedProviderMap: codexProviderMap,
          ),
        );
        const backgroundModels = <ProviderModelDefinition>[
          ProviderModelDefinition(
            provider: 'codex',
            id: 'gpt-5.4-codex',
            label: 'gpt-5.4-codex',
            isDefault: true,
          ),
        ];
        final next = resolveAgentForm(
          settled,
          AgentFormCompleteResolution(
            preferences: const CreateAgentPreferences(
              provider: 'codex',
              providerPreferences: {
                'codex': ProviderCreateAgentPreferences(model: 'gpt-5.4-codex'),
              },
            ),
            providerModelsByProvider: makeProviderModelsByProvider({
              'codex': backgroundModels,
            }),
            allowedProviderMap: codexProviderMap,
          ),
        );

        expect(next, same(settled));
        expect(next.form.provider, 'codex');
        expect(next.form.model, 'gpt-5.3-codex');
      });

      test('prefills edit hydration from initial values', () {
        final state = makeState(serverId: 'host-1');
        final next = resolveAgentForm(
          state,
          AgentFormCompleteResolution(
            initialValues: const FormInitialValues(
              provider: 'codex',
              modeId: 'full-access',
              model: 'gpt-5.3-codex',
              thinkingOptionId: 'low',
              workingDir: '/repo',
            ),
            preferences: const CreateAgentPreferences(provider: 'claude'),
            providerModelsByProvider: makeProviderModelsByProvider({
              'codex': codexModels,
            }),
            allowedProviderMap: bothProviderMap,
          ),
        );

        expect(next.form.provider, 'codex');
        expect(next.form.modeId, 'full-access');
        expect(next.form.model, 'gpt-5.3-codex');
        expect(next.form.thinkingOptionId, 'low');
        expect(next.form.workingDir, '/repo');
      });

      test('keeps a user model change after resolution has completed', () {
        const alternateModels = <ProviderModelDefinition>[
          ...codexModels,
          ProviderModelDefinition(
            provider: 'codex',
            id: 'gpt-5.4-codex',
            label: 'gpt-5.4-codex',
          ),
        ];
        final settled = resolveAgentForm(
          makeState(serverId: 'host-1'),
          AgentFormCompleteResolution(
            preferences: const CreateAgentPreferences(
              provider: 'codex',
              providerPreferences: {
                'codex': ProviderCreateAgentPreferences(model: 'gpt-5.3-codex'),
              },
            ),
            providerModelsByProvider: makeProviderModelsByProvider({
              'codex': alternateModels,
            }),
            allowedProviderMap: codexProviderMap,
          ),
        );
        final userChanged = resolveAgentForm(
          settled,
          const AgentFormSetModelFromUser(
            modelId: 'gpt-5.4-codex',
            availableModels: alternateModels,
          ),
        );
        final next = resolveAgentForm(
          userChanged,
          AgentFormCompleteResolution(
            preferences: const CreateAgentPreferences(
              provider: 'codex',
              providerPreferences: {
                'codex': ProviderCreateAgentPreferences(model: 'gpt-5.3-codex'),
              },
            ),
            providerModelsByProvider: makeProviderModelsByProvider({
              'codex': codexModels,
            }),
            allowedProviderMap: codexProviderMap,
          ),
        );

        expect(next, same(userChanged));
        expect(next.form.model, 'gpt-5.4-codex');
        expect(next.userModified.model, isTrue);
      });

      test('does not override user-modified provider while completing', () {
        final state = makeState(
          provider: 'codex',
          modeId: 'auto',
          modified: const UserModifiedFields(provider: true),
        );
        final next = resolveAgentForm(
          state,
          AgentFormCompleteResolution(
            preferences: const CreateAgentPreferences(provider: 'claude'),
            providerModelsByProvider: makeProviderModelsByProvider({}),
            allowedProviderMap: bothProviderMap,
          ),
        );

        expect(next.form.provider, 'codex');
      });
    });

    group('SET_SERVER_ID', () {
      test('updates serverId without marking it user-modified', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetServerId('host-1'),
        );

        expect(next.form.serverId, 'host-1');
        expect(next.userModified.serverId, isFalse);
      });
    });

    group('SET_SERVER_ID_FROM_USER', () {
      test('updates serverId and marks it user-modified', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetServerIdFromUser('host-2'),
        );

        expect(next.form.serverId, 'host-2');
        expect(next.userModified.serverId, isTrue);
      });
    });

    group('SET_PROVIDER_FROM_USER', () {
      test('switches provider, picks preferred model and mode, marks provider '
          'modified', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetProviderFromUser(
            provider: 'codex',
            providerModels: codexModels,
            providerDef: testCodexDefinition,
            providerPrefs: ProviderCreateAgentPreferences(
              model: 'gpt-5.3-codex',
              mode: 'full-access',
            ),
          ),
        );

        expect(next.form.provider, 'codex');
        expect(next.form.model, 'gpt-5.3-codex');
        expect(next.form.modeId, 'full-access');
        expect(next.userModified.provider, isTrue);
        expect(next.userModified.model, isFalse);
      });

      test('falls back to provider defaults when no prefs', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetProviderFromUser(
            provider: 'codex',
            providerModels: codexModels,
            providerDef: testCodexDefinition,
          ),
        );

        expect(next.form.modeId, 'auto');
        expect(next.form.model, 'gpt-5.3-codex');
      });
    });

    group('SET_PROVIDER_AND_MODEL_FROM_USER', () {
      test('sets provider, model, and default mode; marks both modified', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetProviderAndModelFromUser(
            provider: 'codex',
            modelId: 'gpt-5.3-codex',
            providerDef: testCodexDefinition,
            providerModels: codexModels,
          ),
        );

        expect(next.form.provider, 'codex');
        expect(next.form.model, 'gpt-5.3-codex');
        expect(next.form.modeId, 'auto');
        expect(next.userModified.provider, isTrue);
        expect(next.userModified.model, isTrue);
      });

      test('preserves the current preferred mode when selecting a provider and '
          'model', () {
        final state = makeState(provider: 'codex', modeId: 'full-access');
        final next = resolveAgentForm(
          state,
          const AgentFormSetProviderAndModelFromUser(
            provider: 'codex',
            modelId: 'gpt-5.3-codex',
            providerDef: testCodexDefinition,
            providerModels: codexModels,
          ),
        );

        expect(next.form.provider, 'codex');
        expect(next.form.model, 'gpt-5.3-codex');
        expect(next.form.modeId, 'full-access');
      });

      test('falls back to provider default model when modelId is empty', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetProviderAndModelFromUser(
            provider: 'codex',
            modelId: '',
            providerDef: testCodexDefinition,
            providerModels: codexModels,
          ),
        );

        expect(next.form.model, 'gpt-5.3-codex');
      });

      test('selects default thinking option for the chosen model', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetProviderAndModelFromUser(
            provider: 'codex',
            modelId: 'gpt-5.3-codex',
            providerDef: testCodexDefinition,
            providerModels: codexModels,
          ),
        );

        expect(next.form.thinkingOptionId, 'xhigh');
      });
    });

    group('SET_MODE_FROM_USER', () {
      test('updates modeId and marks it modified', () {
        final state = makeState(provider: 'codex', modeId: 'auto');
        final next = resolveAgentForm(
          state,
          const AgentFormSetModeFromUser('full-access'),
        );

        expect(next.form.modeId, 'full-access');
        expect(next.userModified.modeId, isTrue);
      });
    });

    group('SET_MODEL_FROM_USER', () {
      test(
        'updates model and resets thinking to model default when thinking is '
        'not user-modified',
        () {
          final state = makeState(provider: 'codex');
          final next = resolveAgentForm(
            state,
            const AgentFormSetModelFromUser(
              modelId: 'gpt-5.3-codex',
              availableModels: codexModels,
            ),
          );

          expect(next.form.model, 'gpt-5.3-codex');
          expect(next.form.thinkingOptionId, 'xhigh');
          expect(next.userModified.model, isTrue);
        },
      );

      test(
        'preserves user-chosen thinking option when switching to same model',
        () {
          final state = makeState(
            provider: 'codex',
            model: 'gpt-5.3-codex',
            thinkingOptionId: 'low',
            modified: const UserModifiedFields(thinkingOptionId: true),
          );
          final next = resolveAgentForm(
            state,
            const AgentFormSetModelFromUser(
              modelId: 'gpt-5.3-codex',
              availableModels: codexModels,
            ),
          );

          expect(next.form.thinkingOptionId, 'low');
        },
      );

      test('falls back to provider default model when modelId is blank', () {
        final state = makeState(provider: 'codex');
        final next = resolveAgentForm(
          state,
          const AgentFormSetModelFromUser(
            modelId: '  ',
            availableModels: codexModels,
          ),
        );

        expect(next.form.model, 'gpt-5.3-codex');
      });
    });

    group('SET_THINKING_OPTION_FROM_USER', () {
      test('updates thinkingOptionId and marks it modified', () {
        final state = makeState(thinkingOptionId: 'xhigh');
        final next = resolveAgentForm(
          state,
          const AgentFormSetThinkingOptionFromUser('low'),
        );

        expect(next.form.thinkingOptionId, 'low');
        expect(next.userModified.thinkingOptionId, isTrue);
      });
    });

    group('SET_WORKING_DIR', () {
      test('updates workingDir without marking it modified', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetWorkingDir('/home/user/proj'),
        );

        expect(next.form.workingDir, '/home/user/proj');
        expect(next.userModified.workingDir, isFalse);
      });
    });

    group('SET_WORKING_DIR_FROM_USER', () {
      test('updates workingDir and marks it modified', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormSetWorkingDirFromUser('/home/user/proj'),
        );

        expect(next.form.workingDir, '/home/user/proj');
        expect(next.userModified.workingDir, isTrue);
      });
    });

    group('AUTO_SELECT_SERVER', () {
      test('sets serverId when currently null', () {
        final state = makeState();
        final next = resolveAgentForm(
          state,
          const AgentFormAutoSelectServer('host-1'),
        );

        expect(next.form.serverId, 'host-1');
      });

      test('does not override an already-set serverId', () {
        final state = makeState(serverId: 'existing');
        final next = resolveAgentForm(
          state,
          const AgentFormAutoSelectServer('host-1'),
        );

        expect(next, same(state));
      });
    });

    group('RESET', () {
      test('keeps form values but marks them unresolved for the next open', () {
        final state = makeState(
          provider: 'codex',
          modeId: 'full-access',
          model: 'gpt-5.3-codex',
          modified: const UserModifiedFields(
            provider: true,
            modeId: true,
            model: true,
          ),
          resolution: AgentFormResolutionState.completed,
        );
        final next = resolveAgentForm(state, const AgentFormReset());

        expect(next.userModified, initialUserModified);
        expect(next.form, state.form);
        expect(next.resolution, AgentFormResolutionState.pending);
      });
    });

    group('buildProviderDefinitionMap', () {
      test('builds a map from provider id to definition', () {
        final map = buildProviderDefinitionMap([
          testCodexDefinition,
          testClaudeDefinition,
        ]);
        expect(map['codex'], same(testCodexDefinition));
        expect(map['claude'], same(testClaudeDefinition));
      });
    });

    group('buildProviderDefinitionMapForStatuses', () {
      test('returns all definitions when no snapshot entries', () {
        final map = buildProviderDefinitionMapForStatuses(
          snapshotEntries: null,
          providerDefinitions: [testCodexDefinition],
          statuses: const {ProviderCatalogStatus.ready},
        );
        expect(map.keys.toList(), ['codex']);
      });

      test('filters to only matching-status enabled providers', () {
        const entries = <ProviderSnapshotEntry>[
          ProviderSnapshotEntry(
            provider: 'codex',
            status: ProviderCatalogStatus.ready,
            label: 'Codex',
            description: '',
            defaultModeId: 'auto',
            modes: [],
          ),
          ProviderSnapshotEntry(
            provider: 'claude',
            status: ProviderCatalogStatus.loading,
            label: 'Claude',
            description: '',
            defaultModeId: 'default',
            modes: [],
          ),
        ];
        final map = buildProviderDefinitionMapForStatuses(
          snapshotEntries: entries,
          providerDefinitions: [testCodexDefinition, testClaudeDefinition],
          statuses: const {ProviderCatalogStatus.ready},
        );

        expect(map.keys.toList(), ['codex']);
      });
    });
  });

  // Cases the upstream suite reaches only through other exports, kept explicit
  // here so every branch of the Dart port is observed directly.
  group('additional coverage', () {
    test('exposes the resolvable and selectable status sets', () {
      expect(resolvableProviderStatuses, {
        ProviderCatalogStatus.ready,
        ProviderCatalogStatus.loading,
      });
      expect(selectableProviderStatuses, {ProviderCatalogStatus.ready});
    });

    test('normalizeSelectedModelId trims and treats a missing id as empty', () {
      expect(normalizeSelectedModelId(null), '');
      expect(normalizeSelectedModelId('  gpt-5.3-codex '), 'gpt-5.3-codex');
    });

    test('resolveDefaultModelId is empty without a catalog', () {
      expect(resolveDefaultModelId(null), '');
      expect(resolveDefaultModelId(codexModels), 'gpt-5.3-codex');
    });

    test('resolveEffectiveModel falls back to the default for unknown ids', () {
      expect(resolveEffectiveModel(null, 'gpt-5.3-codex'), isNull);
      expect(resolveEffectiveModel(const [], 'gpt-5.3-codex'), isNull);
      expect(resolveEffectiveModel(codexModels, '   '), isNull);
      expect(
        resolveEffectiveModel(codexModels, 'gpt-5.3-codex')?.id,
        'gpt-5.3-codex',
      );
      expect(resolveEffectiveModel(codexModels, 'ghost')?.id, 'gpt-5.3-codex');
    });

    test('hasFormStateChanged compares every field', () {
      const base = FormState(
        serverId: 'host-1',
        provider: 'codex',
        modeId: 'auto',
        model: 'gpt-5.3-codex',
        thinkingOptionId: 'xhigh',
        workingDir: '/repo',
      );
      expect(hasFormStateChanged(base, base), isFalse);
      expect(
        hasFormStateChanged(base, base.copyWith(serverId: 'host-2')),
        isTrue,
      );
      expect(
        hasFormStateChanged(base, base.copyWith(provider: 'claude')),
        isTrue,
      );
      expect(hasFormStateChanged(base, base.copyWith(modeId: 'x')), isTrue);
      expect(hasFormStateChanged(base, base.copyWith(model: 'x')), isTrue);
      expect(
        hasFormStateChanged(base, base.copyWith(thinkingOptionId: 'low')),
        isTrue,
      );
      expect(
        hasFormStateChanged(base, base.copyWith(workingDir: '/x')),
        isTrue,
      );
    });

    test('combineInitialValues promotes a bare route server id', () {
      expect(
        combineInitialValues(null, 'daemon-1'),
        const FormInitialValues.withServerId('daemon-1'),
      );
    });

    test('FormInitialValues distinguishes absent from explicitly null', () {
      expect(
        const FormInitialValues() == const FormInitialValues.withServerId(null),
        isFalse,
      );
      expect(
        const FormInitialValues(model: 'a').hashCode,
        const FormInitialValues(model: 'a').hashCode,
      );
      expect(const FormInitialValues().toString(), contains('hasServerId'));
    });

    test('FormState and UserModifiedFields expose value equality', () {
      expect(const FormState().hashCode, const FormState().hashCode);
      expect(const FormState().toString(), contains('serverId'));
      expect(initialUserModified.hashCode, const UserModifiedFields().hashCode);
      expect(initialUserModified.toString(), contains('serverId'));
      expect(
        const UserModifiedFields(serverId: true),
        isNot(initialUserModified),
      );
    });

    test('buildProviderDefinitions fills in default mode visuals', () {
      const entries = <ProviderSnapshotEntry>[
        ProviderSnapshotEntry(
          provider: 'zai',
          status: ProviderCatalogStatus.ready,
          modes: [ProviderMode(id: 'default', label: 'Default')],
        ),
      ];

      expect(buildProviderDefinitions(entries).map(definitionToJson).toList(), [
        {
          'id': 'zai',
          // No label or description in the entry, so both fall back.
          'label': 'zai',
          'description': '',
          'defaultModeId': null,
          'modes': [
            {
              'id': 'default',
              'label': 'Default',
              'icon': 'ShieldCheck',
              'colorTier': 'moderate',
            },
          ],
        },
      ]);
    });

    test(
      'AgentProviderDefinition carries the optional enabledByDefault flag',
      () {
        const definition = AgentProviderDefinition(
          id: 'codex',
          label: 'Codex',
          description: '',
          defaultModeId: null,
          enabledByDefault: true,
        );
        expect(definition.enabledByDefault, isTrue);
        expect(definition.modes, isEmpty);
      },
    );

    test('CLEAR_PROVIDER_SELECTION_FROM_USER blanks the whole selection', () {
      final state = makeState(
        serverId: 'host-1',
        provider: 'codex',
        modeId: 'full-access',
        model: 'gpt-5.3-codex',
        thinkingOptionId: 'xhigh',
        workingDir: '/repo',
      );
      final next = resolveAgentForm(
        state,
        const AgentFormClearProviderSelectionFromUser(),
      );

      expect(next.form.provider, isNull);
      expect(next.form.modeId, '');
      expect(next.form.model, '');
      expect(next.form.thinkingOptionId, '');
      // Untouched fields survive.
      expect(next.form.serverId, 'host-1');
      expect(next.form.workingDir, '/repo');
      expect(next.userModified.provider, isTrue);
      expect(next.userModified.model, isTrue);
      expect(next.userModified.modeId, isTrue);
      expect(next.userModified.thinkingOptionId, isTrue);
    });

    test(
      'SET_PROVIDER_FROM_USER ignores a saved model the new catalog dropped',
      () {
        final next = resolveAgentForm(
          makeState(),
          const AgentFormSetProviderFromUser(
            provider: 'codex',
            providerModels: codexModels,
            providerDef: testCodexDefinition,
            providerPrefs: ProviderCreateAgentPreferences(model: 'ghost'),
          ),
        );

        expect(next.form.model, 'gpt-5.3-codex');
      },
    );

    test(
      'SET_PROVIDER_FROM_USER keeps a saved model while the catalog is loading',
      () {
        final next = resolveAgentForm(
          makeState(),
          const AgentFormSetProviderFromUser(
            provider: 'codex',
            providerModels: null,
            providerDef: testCodexDefinition,
            providerPrefs: ProviderCreateAgentPreferences(
              model: 'gpt-5.3-codex',
            ),
          ),
        );

        expect(next.form.model, 'gpt-5.3-codex');
        // No catalog means no thinking options to resolve against.
        expect(next.form.thinkingOptionId, '');
      },
    );

    test('SET_PROVIDER_FROM_USER honours a saved thinking level', () {
      final next = resolveAgentForm(
        makeState(),
        const AgentFormSetProviderFromUser(
          provider: 'codex',
          providerModels: codexModels,
          providerDef: testCodexDefinition,
          providerPrefs: ProviderCreateAgentPreferences(
            model: 'gpt-5.3-codex',
            thinkingByModel: {'gpt-5.3-codex': 'low'},
          ),
        ),
      );

      expect(next.form.thinkingOptionId, 'low');
    });

    test(
      'SET_PROVIDER_AND_MODEL_FROM_USER re-derives the mode when the provider '
      'changes',
      () {
        final next = resolveAgentForm(
          makeState(provider: 'claude', modeId: 'plan'),
          const AgentFormSetProviderAndModelFromUser(
            provider: 'codex',
            modelId: 'gpt-5.3-codex',
            providerDef: testCodexDefinition,
            providerModels: codexModels,
            providerPrefs: ProviderCreateAgentPreferences(mode: 'full-access'),
          ),
        );

        expect(next.form.modeId, 'full-access');
      },
    );

    test(
      'resolveFormStateFromProviderModels picks the resolved provider catalog',
      () {
        final resolved = resolveFormStateFromProviderModels(
          null,
          const CreateAgentPreferences(
            provider: 'codex',
            providerPreferences: {
              'codex': ProviderCreateAgentPreferences(model: 'gpt-5.3-codex'),
            },
          ),
          makeProviderModelsByProvider({'codex': codexModels}),
          initialUserModified,
          const FormState(),
          codexProviderMap,
        );

        expect(resolved.provider, 'codex');
        expect(resolved.model, 'gpt-5.3-codex');
        expect(resolved.thinkingOptionId, 'xhigh');
      },
    );

    test(
      'resolveFormStateFromProviderModels tolerates an unresolved provider',
      () {
        final resolved = resolveFormStateFromProviderModels(
          null,
          const CreateAgentPreferences(),
          makeProviderModelsByProvider({'codex': codexModels}),
          initialUserModified,
          const FormState(),
          codexProviderMap,
        );

        expect(resolved.provider, isNull);
        expect(resolved.model, '');
      },
    );

    test('resolveFormState applies initial serverId and workingDir', () {
      final resolved = resolveFormState(
        const FormInitialValues.withServerId(null, workingDir: '/repo'),
        const CreateAgentPreferences(),
        null,
        initialUserModified,
        const FormState(serverId: 'host-1', workingDir: '/old'),
        codexProviderMap,
      );

      expect(resolved.serverId, isNull);
      expect(resolved.workingDir, '/repo');
    });

    test(
      'resolveFormState leaves user-modified serverId and workingDir alone',
      () {
        final resolved = resolveFormState(
          const FormInitialValues.withServerId('host-2', workingDir: '/repo'),
          const CreateAgentPreferences(),
          null,
          const UserModifiedFields(serverId: true, workingDir: true),
          const FormState(serverId: 'host-1', workingDir: '/old'),
          codexProviderMap,
        );

        expect(resolved.serverId, 'host-1');
        expect(resolved.workingDir, '/old');
      },
    );

    test(
      'resolveFormState invalidates a preferred model against an empty catalog',
      () {
        final resolved = resolveFormState(
          null,
          const CreateAgentPreferences(
            provider: 'codex',
            providerPreferences: {
              'codex': ProviderCreateAgentPreferences(model: 'gpt-5.3-codex'),
            },
          ),
          const [],
          initialUserModified,
          makeState(provider: 'codex').form,
          codexProviderMap,
        );

        // An empty-but-present catalog is "loaded and offers nothing", so the
        // saved id is dropped rather than passed through.
        expect(resolved.model, '');
      },
    );

    test('resolveFormState keeps a user-modified model and thinking level', () {
      final resolved = resolveFormState(
        null,
        const CreateAgentPreferences(provider: 'codex'),
        null,
        const UserModifiedFields(model: true, thinkingOptionId: true),
        makeState(
          provider: 'codex',
          model: 'gpt-9',
          thinkingOptionId: 'ultra',
        ).form,
        codexProviderMap,
      );

      expect(resolved.model, 'gpt-9');
      expect(resolved.thinkingOptionId, 'ultra');
    });

    test('AUTO_SELECT_SERVER treats an empty server id as unset', () {
      final next = resolveAgentForm(
        makeState(serverId: ''),
        const AgentFormAutoSelectServer('host-1'),
      );

      expect(next.form.serverId, 'host-1');
    });

    test('AgentFormReducerState.copyWith replaces only what it is given', () {
      final state = makeState(provider: 'codex');
      final next = state.copyWith(
        resolution: AgentFormResolutionState.completed,
      );

      expect(next.form, same(state.form));
      expect(next.userModified, same(state.userModified));
      expect(next.resolution, AgentFormResolutionState.completed);
    });
  });
}
