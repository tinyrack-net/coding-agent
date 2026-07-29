import 'dart:io';

import 'package:agent_daemon/src/cli/cli_client_id.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cli-client-id-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('reads, trims, and caches an existing client ID', () async {
    final file = File(p.join(temp.path, cliClientIdFileName));
    await file.writeAsString('  cid_existing  \n');
    final store = CliClientIdStore(
      generateUuid: () => fail('existing IDs must not be regenerated'),
    );

    expect(await store.getOrCreate(home: temp.path), 'cid_existing');
    await file.writeAsString('cid_changed');
    expect(await store.getOrCreate(home: temp.path), 'cid_existing');
  });

  test('creates the frozen cid UUID shape and persists it', () async {
    final store = CliClientIdStore(
      generateUuid: () => '12345678-90ab-cdef-1234-567890abcdef',
    );

    final value = await store.getOrCreate(home: temp.path);

    expect(value, 'cid_1234567890abcdef1234567890abcdef');
    expect(
      await File(p.join(temp.path, cliClientIdFileName)).readAsString(),
      value,
    );
    if (!Platform.isWindows) {
      final stat = await File(p.join(temp.path, cliClientIdFileName)).stat();
      expect(stat.mode & 0x1ff, 0x180);
    }
  });

  test('coalesces concurrent creation into one generated identity', () async {
    var generated = 0;
    final store = CliClientIdStore(
      generateUuid: () {
        generated++;
        return 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      },
    );

    final values = await Future.wait([
      for (var index = 0; index < 20; index++)
        store.getOrCreate(home: temp.path),
    ]);

    expect(values.toSet(), {'cid_aaaaaaaabbbbccccddddeeeeeeeeeeee'});
    expect(generated, 1);
  });

  test(
    'replaces an empty file but preserves non-missing read failures',
    () async {
      final file = File(p.join(temp.path, cliClientIdFileName));
      await file.writeAsString(' \n');
      final store = CliClientIdStore(
        generateUuid: () => '00000000-0000-0000-0000-000000000000',
      );
      expect(
        await store.getOrCreate(home: temp.path),
        'cid_00000000000000000000000000000000',
      );

      final blockedHome = await Directory.systemTemp.createTemp(
        'cli-client-id-blocked-',
      );
      addTearDown(() async {
        if (await blockedHome.exists()) {
          await blockedHome.delete(recursive: true);
        }
      });
      await Directory(p.join(blockedHome.path, cliClientIdFileName)).create();
      final blocked = CliClientIdStore();
      await expectLater(
        blocked.getOrCreate(home: blockedHome.path),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('resolves the Tinyrack home from an injected environment', () async {
    final profile = Directory(p.join(temp.path, 'profile'));
    final store = CliClientIdStore(
      generateUuid: () => '11111111-2222-3333-4444-555555555555',
    );

    await store.getOrCreate(environment: {'USERPROFILE': profile.path});

    expect(
      await File(
        p.join(profile.path, '.tinyrack-agent', cliClientIdFileName),
      ).readAsString(),
      'cid_11111111222233334444555555555555',
    );
  });
}
