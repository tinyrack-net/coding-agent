import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../server/daemon_config.dart';

const cliClientIdFileName = 'cli-client-id';

/// Process-scoped implementation of Paseo's persistent CLI client identity.
final class CliClientIdStore {
  CliClientIdStore({String Function()? generateUuid})
    : _generateUuid = generateUuid ?? const Uuid().v4;

  final String Function() _generateUuid;
  String? _cachedClientId;
  Future<String>? _pendingClientId;

  Future<String> getOrCreate({String? home, Map<String, String>? environment}) {
    final cached = _cachedClientId;
    if (cached != null) return Future.value(cached);
    final pending = _pendingClientId;
    if (pending != null) return pending;
    final resolvedHome =
        home ?? resolveTinyrackHome(environment ?? Platform.environment);
    final operation = _loadOrCreate(resolvedHome);
    _pendingClientId = operation;
    return operation.whenComplete(() {
      if (identical(_pendingClientId, operation)) _pendingClientId = null;
    });
  }

  Future<String> _loadOrCreate(String home) async {
    final file = File(p.join(home, cliClientIdFileName));
    try {
      final existing = _normalizeClientId(await file.readAsString());
      if (existing != null) {
        _cachedClientId = existing;
        return existing;
      }
    } on FileSystemException catch (error) {
      if (!_isMissingFile(error)) rethrow;
    }

    final nextValue = 'cid_${_generateUuid().replaceAll('-', '')}';
    await file.parent.create(recursive: true);
    await file.writeAsString(nextValue, flush: true);
    // coverage:ignore-start
    // Windows has no POSIX mode bits. Linux/macOS CI verifies this branch.
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Unable to restrict CLI client ID permissions',
          file.path,
        );
      }
    }
    // coverage:ignore-end
    _cachedClientId = nextValue;
    return nextValue;
  }
}

final CliClientIdStore _defaultCliClientIdStore = CliClientIdStore();

Future<String> getOrCreateCliClientId({
  String? home,
  Map<String, String>? environment,
}) =>
    _defaultCliClientIdStore.getOrCreate(home: home, environment: environment);

String? _normalizeClientId(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool _isMissingFile(FileSystemException error) =>
    error.osError?.errorCode == 2 || error.osError?.errorCode == 3;
