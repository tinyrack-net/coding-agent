import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import '../composer/provider_model_selection.dart';

enum CommandCenterContributionVisibility { always, query }

sealed class CommandCenterPresentation {
  const CommandCenterPresentation();
}

final class CommandCenterActionPresentation extends CommandCenterPresentation {
  const CommandCenterActionPresentation({
    required this.title,
    this.subtitle,
    this.sectionTitle,
    this.shortcutKeys = const [],
  });

  final String title;
  final String? subtitle;
  final String? sectionTitle;
  final List<List<String>> shortcutKeys;
}

final class CommandCenterChoicePresentation extends CommandCenterPresentation {
  const CommandCenterChoicePresentation({
    required this.path,
    this.selected = false,
    this.testId,
    this.providerIcon,
  });

  final List<String> path;
  final bool selected;
  final String? testId;
  final String? providerIcon;
}

final class CommandCenterContribution {
  const CommandCenterContribution({
    required this.id,
    required this.group,
    required this.groupRank,
    required this.rank,
    required this.presentation,
    required this.run,
    this.keywords = const [],
    this.visibility = CommandCenterContributionVisibility.always,
  });

  final String id;
  final String group;
  final int groupRank;
  final int rank;
  final List<String> keywords;
  final CommandCenterContributionVisibility visibility;
  final CommandCenterPresentation presentation;
  final FutureOr<void> Function() run;

  CommandCenterContribution withId(String value) => CommandCenterContribution(
    id: value,
    group: group,
    groupRank: groupRank,
    rank: rank,
    keywords: keywords,
    visibility: visibility,
    presentation: presentation,
    run: run,
  );
}

/// Builds the query-only model choices shared by active agents and drafts.
///
/// This mirrors Paseo 0.2.0's model contribution contract: unavailable
/// providers and synthetic empty-model rows are omitted, the selected row is
/// a no-op, and every selectable provider participates in one ranked group.
List<CommandCenterContribution> buildModelChoiceContributions({
  required String serverId,
  required List<ProviderSelectorProvider> providers,
  required String? selectedProvider,
  required String? selectedModelId,
  required String groupLabel,
  required String searchKeywords,
  required FutureOr<void> Function(String provider, String modelId) select,
}) {
  final contributions = <CommandCenterContribution>[];
  var rank = 0;
  for (final provider in providers) {
    final selection = provider.modelSelection;
    if (selection is! ProviderModelRows) continue;
    for (final model in selection.rows) {
      if (model.modelId.isEmpty) continue;
      final selected =
          selectedProvider == provider.id && selectedModelId == model.modelId;
      contributions.add(
        CommandCenterContribution(
          id: '$serverId:${provider.id}:${model.modelId}',
          group: 'models',
          groupRank: 1,
          rank: rank++,
          keywords: [model.modelId, searchKeywords],
          visibility: CommandCenterContributionVisibility.query,
          presentation: CommandCenterChoicePresentation(
            path: [groupLabel, provider.label, model.modelLabel],
            selected: selected,
            providerIcon: provider.id,
            testId:
                'command-center-model-$serverId:${provider.id}:${model.modelId}',
          ),
          run: () {
            if (!selected) return select(provider.id, model.modelId);
          },
        ),
      );
    }
  }
  return contributions;
}

final class CommandCenterRegistrationOwner {
  const CommandCenterRegistrationOwner({
    required this.sourceId,
    required this.token,
  });

  final String sourceId;
  final Object token;
}

final class CommandCenterRegistration {
  const CommandCenterRegistration({
    required this.owner,
    required this.contributions,
  });

  final CommandCenterRegistrationOwner owner;
  final List<CommandCenterContribution> contributions;
}

final class CommandCenterSnapshot {
  const CommandCenterSnapshot(this.contributions);

  final List<CommandCenterContribution> contributions;
}

typedef CommandCenterListener = void Function();

final class _ActiveRegistration {
  const _ActiveRegistration(this.owner, this.contributions);

  final CommandCenterRegistrationOwner owner;
  final List<CommandCenterContribution> contributions;
}

/// Owner-token registry with the same replacement and namespacing contract as
/// Paseo 0.2.0's Command Center registry.
final class CommandCenterRegistry {
  final Map<String, _ActiveRegistration> _registrations = {};
  final Set<CommandCenterListener> _listeners = {};
  CommandCenterSnapshot _snapshot = const CommandCenterSnapshot([]);

  CommandCenterSnapshot get snapshot => _snapshot;

  void Function() subscribe(CommandCenterListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void replace(CommandCenterRegistration registration) {
    final current = _registrations[registration.owner.sourceId];
    if (current != null &&
        identical(current.owner.token, registration.owner.token) &&
        _sameIdentityList(current.contributions, registration.contributions)) {
      return;
    }
    _validateUniqueIds(registration.owner.sourceId, registration.contributions);
    _registrations[registration.owner.sourceId] = _ActiveRegistration(
      registration.owner,
      registration.contributions,
    );
    _publish();
  }

  void remove(CommandCenterRegistrationOwner owner) {
    final current = _registrations[owner.sourceId];
    if (current == null || !identical(current.owner.token, owner.token)) return;
    _registrations.remove(owner.sourceId);
    _publish();
  }

  void _publish() {
    final contributions = <CommandCenterContribution>[];
    final ids = <String>{};
    for (final registration in _registrations.values) {
      for (final contribution in registration.contributions) {
        final id = '${registration.owner.sourceId}:${contribution.id}';
        if (!ids.add(id)) {
          throw StateError('Duplicate Command Center contribution id: $id');
        }
        contributions.add(contribution.withId(id));
      }
    }
    contributions.sort(compareCommandCenterContributions);
    _snapshot = contributions.isEmpty
        ? const CommandCenterSnapshot([])
        : CommandCenterSnapshot(List.unmodifiable(contributions));
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}

bool _sameIdentityList(List<Object?> left, List<Object?> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!identical(left[index], right[index])) return false;
  }
  return true;
}

void _validateUniqueIds(
  String sourceId,
  List<CommandCenterContribution> contributions,
) {
  final ids = <String>{};
  for (final contribution in contributions) {
    final id = '$sourceId:${contribution.id}';
    if (!ids.add(id)) {
      throw StateError('Duplicate Command Center contribution id: $id');
    }
  }
}

int compareCommandCenterContributions(
  CommandCenterContribution left,
  CommandCenterContribution right,
) {
  var delta = left.groupRank.compareTo(right.groupRank);
  if (delta != 0) return delta;
  delta = left.group.compareTo(right.group);
  if (delta != 0) return delta;
  delta = left.rank.compareTo(right.rank);
  return delta != 0 ? delta : left.id.compareTo(right.id);
}

sealed class CommandCenterResult {
  const CommandCenterResult({
    required this.id,
    required this.title,
    required this.searchText,
    required this.run,
  });

  final String id;
  final String title;
  final String searchText;
  final FutureOr<void> Function() run;
}

final class CommandCenterWorkspaceResult extends CommandCenterResult {
  const CommandCenterWorkspaceResult({
    required super.id,
    required super.title,
    required super.searchText,
    required super.run,
    required this.subtitle,
  });

  final String subtitle;
}

final class CommandCenterAgentResult extends CommandCenterResult {
  const CommandCenterAgentResult({
    required super.id,
    required super.title,
    required super.searchText,
    required super.run,
    required this.subtitle,
    required this.agent,
  });

  final String subtitle;
  final AgentSummary agent;
}

final class CommandCenterContributionResult extends CommandCenterResult {
  const CommandCenterContributionResult({
    required super.id,
    required super.title,
    required super.searchText,
    required super.run,
    required this.contribution,
  });

  final CommandCenterContribution contribution;
}

final class CommandCenterResultSection {
  const CommandCenterResultSection({
    required this.id,
    required this.rank,
    required this.results,
    this.title,
  });

  final String id;
  final int rank;
  final String? title;
  final List<CommandCenterResult> results;
}

List<CommandCenterResultSection> buildContributionSections(
  List<CommandCenterContribution> contributions,
  String query,
) {
  final groups = <String, CommandCenterResultSection>{};
  final hasQuery = query.trim().isNotEmpty;
  final normalized = query.trim().toLowerCase();
  for (final contribution in contributions) {
    if (contribution.visibility == CommandCenterContributionVisibility.query &&
        !hasQuery) {
      continue;
    }
    final presentationText = switch (contribution.presentation) {
      CommandCenterActionPresentation(:final title, :final subtitle) => [
        title,
        subtitle ?? '',
      ],
      CommandCenterChoicePresentation(:final path) => path,
    };
    final searchText = [
      ...presentationText,
      ...contribution.keywords,
    ].join(' ').toLowerCase();
    if (normalized.isNotEmpty && !searchText.contains(normalized)) continue;
    final presentation = contribution.presentation;
    final title = switch (presentation) {
      CommandCenterActionPresentation(:final sectionTitle) => sectionTitle,
      CommandCenterChoicePresentation() => null,
    };
    final resultTitle = switch (presentation) {
      CommandCenterActionPresentation(:final title) => title,
      CommandCenterChoicePresentation(:final path) => path.last,
    };
    final result = CommandCenterContributionResult(
      id: contribution.id,
      title: resultTitle,
      searchText: searchText,
      run: contribution.run,
      contribution: contribution,
    );
    final existing = groups[contribution.group];
    groups[contribution.group] = CommandCenterResultSection(
      id: contribution.group,
      rank: existing?.rank ?? contribution.groupRank,
      title: existing?.title ?? title,
      results: [...?existing?.results, result],
    );
  }
  final sections = groups.values.toList()
    ..sort((left, right) {
      final delta = left.rank.compareTo(right.rank);
      return delta != 0 ? delta : left.id.compareTo(right.id);
    });
  return sections;
}

String? preserveActiveResultId(
  String? activeId,
  List<CommandCenterResult> results,
) {
  if (activeId != null && results.any((result) => result.id == activeId)) {
    return activeId;
  }
  return results.firstOrNull?.id;
}

String? moveActiveResultId(
  String? activeId,
  List<CommandCenterResult> results, {
  required bool next,
}) {
  if (results.isEmpty) return null;
  var current = results.indexWhere((result) => result.id == activeId);
  if (current < 0 && !next) current = 0;
  final delta = next ? 1 : -1;
  return results[(current + delta + results.length) % results.length].id;
}
