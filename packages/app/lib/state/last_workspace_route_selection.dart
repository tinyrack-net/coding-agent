import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/host_routes.dart';

const lastWorkspaceRouteSelectionStorageKey =
    'tinyrack:last-workspace-route-selection';

HostWorkspaceRoute? parseLastWorkspaceRouteSelection(String? stored) {
  if (stored == null || stored.isEmpty) return null;
  try {
    final decoded = jsonDecode(stored);
    if (decoded is! Map<String, Object?>) return null;
    final serverId = decoded['serverId'];
    final workspaceId = decoded['workspaceId'];
    if (serverId is! String || workspaceId is! String) return null;
    final normalizedServerId = serverId.trim();
    final normalizedWorkspaceId = workspaceId.trim();
    if (normalizedServerId.isEmpty || normalizedWorkspaceId.isEmpty) {
      return null;
    }
    return HostWorkspaceRoute(
      serverId: normalizedServerId,
      workspaceId: normalizedWorkspaceId,
    );
  } on FormatException {
    return null;
  }
}

String encodeLastWorkspaceRouteSelection(HostWorkspaceRoute selection) =>
    jsonEncode({
      'serverId': selection.serverId,
      'workspaceId': selection.workspaceId,
    });

class LastWorkspaceRouteSelectionNotifier
    extends AsyncNotifier<HostWorkspaceRoute?> {
  HostWorkspaceRoute? _latest;
  var _revision = 0;

  @override
  Future<HostWorkspaceRoute?> build() async {
    final hydrationRevision = _revision;
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getString(
        lastWorkspaceRouteSelectionStorageKey,
      );
      if (_revision == hydrationRevision) {
        _latest = parseLastWorkspaceRouteSelection(stored);
      }
    } on Object {
      if (_revision == hydrationRevision) {
        _latest = null;
      }
    }
    return _latest;
  }

  Future<void> remember(HostWorkspaceRoute selection) async {
    final normalized = parseLastWorkspaceRouteSelection(
      encodeLastWorkspaceRouteSelection(selection),
    );
    if (normalized == null) return;
    if (_latest?.serverId == normalized.serverId &&
        _latest?.workspaceId == normalized.workspaceId) {
      return;
    }
    _revision += 1;
    _latest = normalized;
    state = AsyncData(normalized);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        lastWorkspaceRouteSelectionStorageKey,
        encodeLastWorkspaceRouteSelection(normalized),
      );
    } on Object {
      // Keep the in-memory selection when persistence is unavailable.
    }
  }
}

final lastWorkspaceRouteSelectionProvider =
    AsyncNotifierProvider<
      LastWorkspaceRouteSelectionNotifier,
      HostWorkspaceRoute?
    >(LastWorkspaceRouteSelectionNotifier.new);

/// Thin route hook that remembers only successfully matched workspace routes.
class LastWorkspaceRouteSelectionRecorder extends ConsumerStatefulWidget {
  const LastWorkspaceRouteSelectionRecorder({
    super.key,
    required this.serverId,
    required this.workspaceId,
    required this.child,
  });

  final String serverId;
  final String workspaceId;
  final Widget child;

  @override
  ConsumerState<LastWorkspaceRouteSelectionRecorder> createState() =>
      _LastWorkspaceRouteSelectionRecorderState();
}

class _LastWorkspaceRouteSelectionRecorderState
    extends ConsumerState<LastWorkspaceRouteSelectionRecorder> {
  String? _scheduledServerId;
  String? _scheduledWorkspaceId;

  void _rememberAfterBuild() {
    if (_scheduledServerId == widget.serverId &&
        _scheduledWorkspaceId == widget.workspaceId) {
      return;
    }
    _scheduledServerId = widget.serverId;
    _scheduledWorkspaceId = widget.workspaceId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(lastWorkspaceRouteSelectionProvider.notifier)
          .remember(
            HostWorkspaceRoute(
              serverId: widget.serverId,
              workspaceId: widget.workspaceId,
            ),
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    _rememberAfterBuild();
    return widget.child;
  }
}
