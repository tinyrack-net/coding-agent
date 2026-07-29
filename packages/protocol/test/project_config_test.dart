import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('project config requests preserve passthrough fields and revisions', () {
    final read = ReadProjectConfigRequest.fromJson({
      'type': ReadProjectConfigRequest.type,
      'requestId': 'read',
      'repoRoot': '/repo',
    });
    expect(read.repoRoot, '/repo');
    expect(read.toJson(), {
      'type': 'read_project_config_request',
      'requestId': 'read',
      'repoRoot': '/repo',
    });
    final write = WriteProjectConfigRequest.fromJson({
      'type': WriteProjectConfigRequest.type,
      'requestId': 'write',
      'repoRoot': '/repo',
      'config': {
        'worktree': {
          'setup': ['one', 'two'],
          'servicePorts': {'range': ' 3000-3010 '},
          'future': true,
        },
        'scripts': {
          'dev': {'type': 'terminal', 'command': 'run', 'future': 1},
        },
        'futureTopLevel': 'kept',
      },
      'expectedRevision': {'mtimeMs': 1.5, 'size': 10},
    });
    expect(write.config['futureTopLevel'], 'kept');
    expect(
      ((write.config['worktree'] as Map)['servicePorts'] as Map)['range'],
      '3000-3010',
    );
    expect(write.expectedRevision!.toJson(), {'mtimeMs': 1.5, 'size': 10});
    expect(write.toJson()['type'], 'write_project_config_request');
  });

  test('validates raw worktree, scripts, and service port constraints', () {
    expect(
      validateProjectConfigRaw({
        'worktree': {
          'teardown': 'stop',
          'terminals': {'anything': true},
          'servicePorts': {'portScript': ' echo 3000 '},
        },
        'metadataGeneration': {
          'title': {'instructions': 'title'},
        },
      }),
      isNotEmpty,
    );
    for (final config in <Map<String, Object?>>[
      {'worktree': 1},
      {
        'worktree': {
          'setup': [1],
        },
      },
      {
        'worktree': {'servicePorts': <String, Object?>{}},
      },
      {
        'worktree': {
          'servicePorts': {'range': '0-1'},
        },
      },
      {
        'worktree': {
          'servicePorts': {'range': '10-1'},
        },
      },
      {
        'worktree': {
          'servicePorts': {'range': '1-70000'},
        },
      },
      {
        'worktree': {
          'servicePorts': {'portScript': ' '},
        },
      },
      {
        'worktree': {
          'servicePorts': {'unknown': true},
        },
      },
      {
        'scripts': <String, Object?>{'bad': 1},
      },
    ]) {
      expect(() => validateProjectConfigRaw(config), throwsFormatException);
    }
    expect(
      validateProjectConfigRaw({
        'metadataGeneration': {
          'title': {'instructions': 1},
          'future': true,
        },
      })['metadataGeneration'],
      {'title': <String, Object?>{}, 'future': true},
    );
    expect(
      validateProjectConfigRaw({'metadataGeneration': 1})['metadataGeneration'],
      <String, Object?>{},
    );
  });

  test('rejects malformed request and revision boundaries', () {
    expect(
      () => ReadProjectConfigRequest.fromJson({
        'type': ReadProjectConfigRequest.type,
        'requestId': 1,
        'repoRoot': '/repo',
      }),
      throwsFormatException,
    );
    expect(
      () => WriteProjectConfigRequest.fromJson({
        'type': WriteProjectConfigRequest.type,
        'requestId': 'w',
        'repoRoot': '/repo',
        'config': <String, Object?>{},
        'expectedRevision': {'mtimeMs': 'bad', 'size': 1},
      }),
      throwsFormatException,
    );
    expect(
      () => WriteProjectConfigRequest.fromJson({
        'type': WriteProjectConfigRequest.type,
        'requestId': 'w',
        'repoRoot': '/repo',
        'config': 1,
        'expectedRevision': null,
      }),
      throwsFormatException,
    );
    expect(
      () => WriteProjectConfigRequest.fromJson({
        'type': WriteProjectConfigRequest.type,
        'requestId': 'w',
        'repoRoot': '/repo',
        'config': <String, Object?>{},
      }),
      throwsFormatException,
    );
  });

  test('parses and serializes successful project config responses', () {
    final read = ReadProjectConfigResponse.fromJson({
      'type': ReadProjectConfigResponse.type,
      'payload': {
        'requestId': 'read',
        'repoRoot': '/repo',
        'ok': true,
        'config': {
          'worktree': {'setup': 'npm install'},
          'future': true,
        },
        'revision': {'mtimeMs': 10, 'size': 20},
      },
    });
    expect(read, isA<ReadProjectConfigSuccess>());
    final readSuccess = read as ReadProjectConfigSuccess;
    expect(readSuccess.config?['future'], true);
    expect(readSuccess.revision?.size, 20);
    expect(readSuccess.toJson()['payload'], {
      'requestId': 'read',
      'repoRoot': '/repo',
      'ok': true,
      'config': {
        'worktree': {'setup': 'npm install'},
        'future': true,
      },
      'revision': {'mtimeMs': 10, 'size': 20},
    });

    final missing =
        ReadProjectConfigResponse.fromJson({
              'type': ReadProjectConfigResponse.type,
              'payload': {
                'requestId': 'missing',
                'repoRoot': '/repo',
                'ok': true,
                'config': null,
                'revision': null,
              },
            })
            as ReadProjectConfigSuccess;
    expect(missing.config, isNull);
    expect(missing.revision, isNull);

    final write = WriteProjectConfigResponse.fromJson({
      'type': WriteProjectConfigResponse.type,
      'payload': {
        'requestId': 'write',
        'repoRoot': '/repo',
        'ok': true,
        'config': {'scripts': <String, Object?>{}},
        'revision': {'mtimeMs': 11, 'size': 21},
      },
    });
    expect(write, isA<WriteProjectConfigSuccess>());
    expect((write as WriteProjectConfigSuccess).revision.mtimeMs, 11);
    expect(
      WriteProjectConfigResponse.fromJson(write.toJson()).toJson(),
      write.toJson(),
    );
  });

  test('parses every inline project config failure variant', () {
    final errors = <Map<String, Object?>>[
      {'code': 'project_not_found'},
      {'code': 'invalid_project_config'},
      {
        'code': 'stale_project_config',
        'currentRevision': {'mtimeMs': 11, 'size': 21},
      },
      {'code': 'stale_project_config', 'currentRevision': null},
      {'code': 'write_failed'},
    ];
    for (final error in errors) {
      final read = ReadProjectConfigResponse.fromJson({
        'type': ReadProjectConfigResponse.type,
        'payload': {
          'requestId': 'read',
          'repoRoot': '/repo',
          'ok': false,
          'error': error,
        },
      });
      expect(read, isA<ReadProjectConfigFailure>());
      expect((read as ReadProjectConfigFailure).error.toJson(), error);

      final write = WriteProjectConfigResponse.fromJson({
        'type': WriteProjectConfigResponse.type,
        'payload': {
          'requestId': 'write',
          'repoRoot': '/repo',
          'ok': false,
          'error': error,
        },
      });
      expect(write, isA<WriteProjectConfigFailure>());
      expect(
        WriteProjectConfigResponse.fromJson(write.toJson()).toJson(),
        write.toJson(),
      );
    }
  });

  test('rejects malformed project config response boundaries', () {
    for (final response in <Map<String, Object?>>[
      {
        'type': ReadProjectConfigResponse.type,
        'payload': {'requestId': 'read', 'repoRoot': '/repo', 'ok': 'true'},
      },
      {
        'type': WriteProjectConfigResponse.type,
        'payload': {
          'requestId': 'write',
          'repoRoot': '/repo',
          'ok': true,
          'config': <String, Object?>{},
          'revision': null,
        },
      },
      {
        'type': ReadProjectConfigResponse.type,
        'payload': {
          'requestId': 'read',
          'repoRoot': '/repo',
          'ok': false,
          'error': {'code': 'future_error'},
        },
      },
      {
        'type': ReadProjectConfigResponse.type,
        'payload': {'requestId': 'read', 'repoRoot': '/repo', 'ok': true},
      },
      {
        'type': ReadProjectConfigResponse.type,
        'payload': {
          'requestId': 'read',
          'repoRoot': '/repo',
          'ok': false,
          'error': {'code': 'stale_project_config'},
        },
      },
    ]) {
      expect(
        () => response['type'] == ReadProjectConfigResponse.type
            ? ReadProjectConfigResponse.fromJson(response)
            : WriteProjectConfigResponse.fromJson(response),
        throwsFormatException,
      );
    }
    expect(
      () => ReadProjectConfigRequest.fromJson({
        'type': 'wrong',
        'requestId': 'read',
        'repoRoot': '/repo',
      }),
      throwsFormatException,
    );
  });
}
