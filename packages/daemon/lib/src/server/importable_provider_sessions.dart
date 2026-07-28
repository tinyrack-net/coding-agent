/// Frozen Paseo 0.2.0 recent provider-session discovery semantics.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../agent/agent_manager.dart';
import '../utils/path_identity.dart';

const _metadataGenerationPromptPrefix =
    'Generate metadata for a coding agent based on the user prompt.';

final class ImportSessionsRequestException implements Exception {
  const ImportSessionsRequestException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

final class ImportableProviderSessionsResult {
  const ImportableProviderSessionsResult({
    required this.entries,
    required this.filteredAlreadyImportedCount,
  });

  final List<RecentProviderSessionDescriptor> entries;
  final int filteredAlreadyImportedCount;
}

Future<ImportableProviderSessionsResult> listImportableProviderSessions({
  required FetchRecentProviderSessionsRequest request,
  required AgentManager manager,
  required String Function(String provider) providerLabel,
}) async {
  final limit = request.limit ?? 20;
  final since = _parseSince(request.since);
  final providerFilter = request.providers?.toSet();
  final importedHandles = <String>{};
  final importedSessions = <String>{};
  for (final agent in manager.list()) {
    if (providerFilter != null && !providerFilter.contains(agent.provider)) {
      continue;
    }
    final handle = agent.sessionId;
    if (handle == null) continue;
    final key = _handleKey(agent.provider, handle);
    importedSessions.add(key);
    importedHandles.add(key);
  }

  final sessions = await manager.listImportableSessions(
    limit: limit + importedSessions.length,
    providerFilter: providerFilter,
    cwd: request.cwd,
  );
  final matchesCwd = request.cwd == null
      ? null
      : realpathAwarePathMatcher(request.cwd!);
  var filteredAlreadyImportedCount = 0;
  final candidates = <ManagedImportableProviderSession>[];
  for (final managed in sessions) {
    final session = managed.session;
    if (matchesCwd != null && !matchesCwd(session.cwd)) continue;
    if (since != null && session.lastActivityAt.isBefore(since)) continue;
    if (session.firstPromptPreview?.trimLeft().startsWith(
          _metadataGenerationPromptPrefix,
        ) ==
        true) {
      continue;
    }
    if (importedHandles.contains(
      _handleKey(managed.provider, session.providerHandleId),
    )) {
      filteredAlreadyImportedCount++;
      continue;
    }
    candidates.add(managed);
  }
  candidates.sort(
    (left, right) =>
        right.session.lastActivityAt.compareTo(left.session.lastActivityAt),
  );
  return ImportableProviderSessionsResult(
    entries: [
      for (final managed in candidates.take(limit))
        RecentProviderSessionDescriptor(
          providerId: managed.provider,
          providerLabel: providerLabel(managed.provider),
          providerHandleId: managed.session.providerHandleId,
          cwd: managed.session.cwd,
          title: managed.session.title,
          firstPromptPreview: managed.session.firstPromptPreview,
          lastPromptPreview: managed.session.lastPromptPreview,
          lastActivityAt: managed.session.lastActivityAt
              .toUtc()
              .toIso8601String(),
        ),
    ],
    filteredAlreadyImportedCount: filteredAlreadyImportedCount,
  );
}

DateTime? _parseSince(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    return DateTime.parse(value);
  } on FormatException {
    throw const ImportSessionsRequestException(
      'invalid_since',
      'Invalid recent provider sessions since',
    );
  }
}

String _handleKey(String provider, String handle) => '$provider\u0000$handle';
