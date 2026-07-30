import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart' as lifecycle;
import 'package:fluent_ui/fluent_ui.dart';

import '../core/daemon_client.dart';

abstract interface class DaemonUpdateTransport {
  ServerInfoStatus? get serverInfo;
  DaemonConnectionState get currentState;
  Stream<DaemonConnectionState> get connectionStates;
  Stream<DaemonUpdateProgress> get progress;

  Future<DaemonUpdateResponse> update(String requestId);
}

final class ClientDaemonUpdateTransport implements DaemonUpdateTransport {
  ClientDaemonUpdateTransport(this.client);

  final DaemonClient client;

  @override
  ServerInfoStatus? get serverInfo => client.serverInfo;

  @override
  DaemonConnectionState get currentState => client.currentState;

  @override
  Stream<DaemonConnectionState> get connectionStates => client.connectionState;

  @override
  Stream<DaemonUpdateProgress> get progress => client.daemonUpdateProgress;

  @override
  Future<DaemonUpdateResponse> update(String requestId) =>
      client.updateDaemon(requestId: requestId);
}

String? normalizeDaemonVersion(String? version) {
  final value = version?.trim();
  if (value == null || value.isEmpty) return null;
  return value.replaceFirst(RegExp('^v', caseSensitive: false), '');
}

bool daemonVersionsMismatch(String? appVersion, String? daemonVersion) {
  final app = normalizeDaemonVersion(appVersion);
  final daemon = normalizeDaemonVersion(daemonVersion);
  return app != null && daemon != null && app != daemon;
}

String daemonUpdatePhaseLabel(DaemonUpdatePhase phase) => switch (phase) {
  DaemonUpdatePhase.starting => 'Preparing update...',
  DaemonUpdatePhase.downloading => 'Downloading packages...',
  DaemonUpdatePhase.installing => 'Installing...',
  DaemonUpdatePhase.complete => 'Update complete, restarting...',
};

sealed class DaemonUpdateViewState {
  const DaemonUpdateViewState();
}

final class DaemonUpdateIdle extends DaemonUpdateViewState {
  const DaemonUpdateIdle();
}

final class DaemonUpdateWorking extends DaemonUpdateViewState {
  const DaemonUpdateWorking(this.phase);

  final String phase;
}

final class DaemonUpdateFailed extends DaemonUpdateViewState {
  const DaemonUpdateFailed(this.title, this.message);

  final String title;
  final String message;
}

class HostDaemonUpdateCard extends StatefulWidget {
  const HostDaemonUpdateCard({
    super.key,
    required this.hostLabel,
    required this.transport,
    this.appVersion = lifecycle.daemonVersion,
    this.reconnectTimeout = const Duration(minutes: 2),
  });

  final String hostLabel;
  final DaemonUpdateTransport transport;
  final String appVersion;
  final Duration reconnectTimeout;

  @override
  State<HostDaemonUpdateCard> createState() => _HostDaemonUpdateCardState();
}

class _HostDaemonUpdateCardState extends State<HostDaemonUpdateCard> {
  static int _requestSequence = 0;

  DaemonUpdateViewState _state = const DaemonUpdateIdle();
  StreamSubscription<DaemonUpdateProgress>? _progressSubscription;
  String? _activeRequestId;

  @override
  void dispose() {
    _progressSubscription?.cancel();
    super.dispose();
  }

  Future<void> _requestUpdate() async {
    if (widget.transport.currentState != DaemonConnectionState.connected) {
      setState(
        () => _state = const DaemonUpdateFailed(
          'Host offline',
          'This host is offline. Wait until it is back online before updating.',
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('Update ${widget.hostLabel}'),
        content: const Text(
          'This will update the daemon to the latest version and restart it. '
          'Running agents will be briefly interrupted.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _state = const DaemonUpdateWorking('Preparing update...'));
    await _progressSubscription?.cancel();
    final requestId =
        'settings_daemon_update_${DateTime.now().microsecondsSinceEpoch}_${_requestSequence++}';
    _activeRequestId = requestId;
    _progressSubscription = widget.transport.progress.listen((progress) {
      if (progress.requestId != _activeRequestId) return;
      if (!mounted) return;
      setState(
        () => _state = DaemonUpdateWorking(
          daemonUpdatePhaseLabel(progress.phase),
        ),
      );
    });

    try {
      final response = await widget.transport.update(requestId);
      if (!mounted) return;
      if (!response.success) {
        setState(
          () => _state = DaemonUpdateFailed(
            'Update failed',
            'Failed to update the daemon: ${response.error ?? 'Unknown error'}',
          ),
        );
        return;
      }
      final reconnected = await _waitForReconnect();
      if (!mounted) return;
      setState(
        () => _state = reconnected
            ? const DaemonUpdateIdle()
            : DaemonUpdateFailed(
                'Unable to reconnect',
                '${widget.hostLabel} did not come back online after updating. '
                    'Please verify the daemon restarted.',
              ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _state = DaemonUpdateFailed(
          'Update failed',
          'Failed to update the daemon: ${_errorMessage(error)}',
        ),
      );
    } finally {
      await _progressSubscription?.cancel();
      _progressSubscription = null;
      if (_activeRequestId == requestId) _activeRequestId = null;
    }
  }

  Future<bool> _waitForReconnect() async {
    try {
      await widget.transport.connectionStates
          .firstWhere((state) => state == DaemonConnectionState.connected)
          .timeout(widget.reconnectTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.transport.serverInfo;
    if (info == null ||
        !daemonVersionsMismatch(widget.appVersion, info.version) ||
        (info.features['daemonSelfUpdate'] != true && !info.desktopManaged)) {
      return const SizedBox.shrink();
    }
    final desktopManaged = info.desktopManaged;
    final working = _state is DaemonUpdateWorking;
    final label = switch (_state) {
      DaemonUpdateWorking(:final phase) => phase,
      _ => 'Update',
    };

    return Card(
      key: const ValueKey('host-page-update-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Update daemon'),
                    const SizedBox(height: 4),
                    Text(
                      desktopManaged
                          ? 'This daemon is managed by Tinyrack Desktop. '
                                'Update Tinyrack Desktop on the host.'
                          : 'Update the daemon to the latest version and '
                                'restart it',
                      style: FluentTheme.of(context).typography.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Button(
                key: const ValueKey('host-page-update-button'),
                onPressed:
                    desktopManaged ||
                        working ||
                        widget.transport.currentState !=
                            DaemonConnectionState.connected
                    ? null
                    : _requestUpdate,
                child: Text(label),
              ),
            ],
          ),
          if (_state case DaemonUpdateFailed(:final title, :final message)) ...[
            const SizedBox(height: 12),
            InfoBar(
              key: const ValueKey('host-page-update-error'),
              title: Text(title),
              content: Text(message),
              severity: InfoBarSeverity.error,
            ),
          ],
        ],
      ),
    );
  }
}

String _errorMessage(Object error) {
  if (error is DaemonRpcException) return error.error.message;
  final text = error.toString();
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}
