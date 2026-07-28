import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('file versions round-trip every Paseo status', () {
    const versions = <FileVersion>[
      ReadyFileVersion(
        cwd: '/repo',
        path: 'a.txt',
        size: 3,
        modifiedAt: '2026-01-01T00:00:00.000Z',
        revision: 'rev-1',
      ),
      MissingFileVersion(cwd: '/repo', path: 'missing.txt'),
      ErrorFileVersion(cwd: '/repo', path: 'bad.txt', error: 'denied'),
    ];

    for (final version in versions) {
      expect(FileVersion.fromJson(version.toJson()).toJson(), version.toJson());
    }
  });

  test('file write results round-trip every Paseo status', () {
    const results = <FileWriteResult>[
      WrittenFileResult(
        modifiedAt: '2026-01-01T00:00:00.000Z',
        size: 4,
        revision: 'rev-2',
      ),
      ConflictFileResult(MissingFileVersion(cwd: '/repo', path: 'a.txt')),
      FileWriteError('too large'),
    ];

    for (final result in results) {
      expect(
        FileWriteResult.fromJson(result.toJson()).toJson(),
        result.toJson(),
      );
    }
  });

  test('file editing models reject malformed payloads', () {
    expect(
      () => FileVersion.fromJson(const {'status': 'ready'}),
      throwsFormatException,
    );
    expect(
      () => FileWriteResult.fromJson(const {'status': 'written', 'size': -1}),
      throwsFormatException,
    );
    expect(
      () => FileWriteResult.fromJson(const {
        'status': 'conflict',
        'version': 'bad',
      }),
      throwsFormatException,
    );
    expect(
      () => FileWriteResult.fromJson(const {'status': 'error'}),
      throwsFormatException,
    );
  });
}
