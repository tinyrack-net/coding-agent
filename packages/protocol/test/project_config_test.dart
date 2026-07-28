import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('project config requests preserve passthrough fields and revisions', () {
    final read = ReadProjectConfigRequest.fromJson({
      'requestId': 'read',
      'repoRoot': '/repo',
    });
    expect(read.repoRoot, '/repo');
    final write = WriteProjectConfigRequest.fromJson({
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
        'requestId': 1,
        'repoRoot': '/repo',
      }),
      throwsFormatException,
    );
    expect(
      () => WriteProjectConfigRequest.fromJson({
        'requestId': 'w',
        'repoRoot': '/repo',
        'config': <String, Object?>{},
        'expectedRevision': {'mtimeMs': 'bad', 'size': 1},
      }),
      throwsFormatException,
    );
    expect(
      () => WriteProjectConfigRequest.fromJson({
        'requestId': 'w',
        'repoRoot': '/repo',
        'config': 1,
        'expectedRevision': null,
      }),
      throwsFormatException,
    );
  });
}
