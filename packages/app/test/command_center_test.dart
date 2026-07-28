import 'package:coding_agent_app/command_center/command_center.dart';
import 'package:coding_agent_app/composer/provider_model_selection.dart';
import 'package:flutter_test/flutter_test.dart';

CommandCenterContribution action(
  String id, {
  String group = 'actions',
  int groupRank = 0,
  int rank = 0,
  String? subtitle,
  CommandCenterContributionVisibility visibility =
      CommandCenterContributionVisibility.always,
}) => CommandCenterContribution(
  id: id,
  group: group,
  groupRank: groupRank,
  rank: rank,
  keywords: const ['needle'],
  visibility: visibility,
  presentation: CommandCenterActionPresentation(
    title: id,
    subtitle: subtitle,
    sectionTitle: 'Actions',
  ),
  run: () {},
);

void main() {
  test(
    'model choices include every available provider and skip no-op rows',
    () {
      final selections = <String>[];
      const providers = [
        ProviderSelectorProvider(
          id: 'claude',
          label: 'Claude',
          modelSelection: ProviderModelRows([
            ProviderSelectionModelRow(
              favoriteKey: 'claude:sonnet',
              provider: 'claude',
              providerLabel: 'Claude',
              modelId: 'sonnet',
              modelLabel: 'Sonnet',
            ),
          ]),
        ),
        ProviderSelectorProvider(
          id: 'codex',
          label: 'Codex',
          modelSelection: ProviderModelRows([
            ProviderSelectionModelRow(
              favoriteKey: 'codex:',
              provider: 'codex',
              providerLabel: 'Codex',
              modelId: '',
              modelLabel: 'Default',
            ),
            ProviderSelectionModelRow(
              favoriteKey: 'codex:gpt-5',
              provider: 'codex',
              providerLabel: 'Codex',
              modelId: 'gpt-5',
              modelLabel: 'GPT-5',
            ),
          ]),
        ),
        ProviderSelectorProvider(
          id: 'offline',
          label: 'Offline',
          modelSelection: ProviderModelsError('Unavailable'),
        ),
      ];

      final choices = buildModelChoiceContributions(
        serverId: 'host',
        providers: providers,
        selectedProvider: 'codex',
        selectedModelId: 'gpt-5',
        groupLabel: 'Model',
        searchKeywords: 'model switch',
        select: (provider, modelId) => selections.add('$provider:$modelId'),
      );

      expect(choices.map((choice) => choice.id), [
        'host:claude:sonnet',
        'host:codex:gpt-5',
      ]);
      expect(
        choices.map(
          (choice) =>
              (choice.presentation as CommandCenterChoicePresentation).selected,
        ),
        [false, true],
      );
      expect(
        choices.map(
          (choice) => (choice.presentation as CommandCenterChoicePresentation)
              .providerIcon,
        ),
        ['claude', 'codex'],
      );
      choices.first.run();
      choices.last.run();
      expect(selections, ['claude:sonnet']);
    },
  );

  test('registry namespaces, sorts, notifies, and protects owner tokens', () {
    final registry = CommandCenterRegistry();
    final firstToken = Object();
    final secondToken = Object();
    var notifications = 0;
    final unsubscribe = registry.subscribe(() => notifications++);
    final late = action('late', rank: 2);
    final early = action('early', rank: 1);

    registry.replace(
      CommandCenterRegistration(
        owner: CommandCenterRegistrationOwner(
          sourceId: 'root',
          token: firstToken,
        ),
        contributions: [late, early],
      ),
    );
    expect(registry.snapshot.contributions.map((item) => item.id), [
      'root:early',
      'root:late',
    ]);
    expect(notifications, 1);

    registry.replace(
      CommandCenterRegistration(
        owner: CommandCenterRegistrationOwner(
          sourceId: 'root',
          token: firstToken,
        ),
        contributions: [late, early],
      ),
    );
    expect(notifications, 1);
    registry.remove(
      CommandCenterRegistrationOwner(sourceId: 'root', token: secondToken),
    );
    expect(registry.snapshot.contributions, hasLength(2));
    registry.remove(
      CommandCenterRegistrationOwner(sourceId: 'root', token: firstToken),
    );
    expect(registry.snapshot.contributions, isEmpty);
    expect(notifications, 2);
    unsubscribe();
  });

  test('registry rejects duplicate ids from one source', () {
    final registry = CommandCenterRegistry();
    expect(
      () => registry.replace(
        CommandCenterRegistration(
          owner: CommandCenterRegistrationOwner(
            sourceId: 'models',
            token: Object(),
          ),
          contributions: [action('same'), action('same')],
        ),
      ),
      throwsStateError,
    );
  });

  test('contribution sections apply query visibility and search text', () {
    final sections = buildContributionSections([
      action('always'),
      action(
        'model',
        group: 'models',
        groupRank: 1,
        visibility: CommandCenterContributionVisibility.query,
      ),
    ], '');
    expect(sections, hasLength(1));
    expect(sections.single.results.single.id, 'always');

    final queried = buildContributionSections([
      action('always'),
      action(
        'model',
        group: 'models',
        groupRank: 1,
        visibility: CommandCenterContributionVisibility.query,
      ),
    ], 'needle');
    expect(queried.map((section) => section.id), ['actions', 'models']);
  });

  test('active result preservation and movement wrap exactly', () {
    final results = [
      CommandCenterWorkspaceResult(
        id: 'one',
        title: 'One',
        subtitle: '',
        searchText: 'one',
        run: () {},
      ),
      CommandCenterWorkspaceResult(
        id: 'two',
        title: 'Two',
        subtitle: '',
        searchText: 'two',
        run: () {},
      ),
    ];
    expect(preserveActiveResultId('two', results), 'two');
    expect(preserveActiveResultId('missing', results), 'one');
    expect(moveActiveResultId('two', results, next: true), 'one');
    expect(moveActiveResultId(null, results, next: false), 'two');
    expect(moveActiveResultId(null, const [], next: true), isNull);
  });
}
