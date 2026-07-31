// Ports of the upstream Vitest suites for Paseo 0.2.0's four desktop-host
// feature modules — `features/app-update-rollout.test.ts`,
// `features/browser-profile.test.ts`,
// `features/editor-targets/registry.test.ts` and
// `settings/desktop-settings-commands.test.ts` — together with the edge cases
// those suites leave unpinned: JS truthiness on `line: 0` / `filePath: ""` /
// blank env vars, the unvalidated UUID reader behind the rollout bucket (ground
// truth captured by running the frozen module under Node), every Zod `.catch`
// arm of the rollout manifest schema, every rejection path of
// `openEditorTarget`, and the legacy browser-id cap.
import 'dart:async';

import 'package:coding_agent_app/desktop/paseo_desktop_features.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final class _FakeProfileSession implements BrowserProfileSession {
  final List<BrowserProfileStorageClearRequest> storageClears =
      <BrowserProfileStorageClearRequest>[];
  int cacheClears = 0;
  int authClears = 0;

  /// When set, `clearStorageData` blocks on it — the upstream suite uses a
  /// hand-resolved promise to prove no guest reloads before the wipe finishes.
  Completer<void>? storageClearGate;

  /// When set, `clearStorageData` fails with it.
  Object? storageClearError;

  @override
  Future<void> clearStorageData(
    BrowserProfileStorageClearRequest request,
  ) async {
    storageClears.add(request);
    final gate = storageClearGate;
    if (gate != null) await gate.future;
    final error = storageClearError;
    if (error != null) throw error;
  }

  @override
  Future<void> clearCache() async => cacheClears += 1;

  @override
  Future<void> clearAuthCache() async => authClears += 1;
}

final class _FakeGuest implements BrowserProfileGuest {
  _FakeGuest(this.id, {this.destroyed = false, this.reloadError});

  @override
  final int id;

  final bool destroyed;
  final Object? reloadError;
  int reloads = 0;

  @override
  bool isDestroyed() => destroyed;

  @override
  void reload() {
    final error = reloadError;
    if (error != null) throw error;
    reloads += 1;
  }
}

final class _FakeWebContents implements BrowserProfileWebContents {
  _FakeWebContents(this.id, this.session, this._type, {this.destroyed = false});

  @override
  final int id;

  @override
  final Object session;

  final String _type;
  final bool destroyed;
  int reloads = 0;

  @override
  String getType() => _type;

  @override
  bool isDestroyed() => destroyed;

  @override
  void reload() => reloads += 1;
}

final class _FakeSessions implements BrowserProfileSessions {
  final List<String> partitions = <String>[];
  final Map<String, _FakeProfileSession> created =
      <String, _FakeProfileSession>{};

  @override
  BrowserProfileSession fromPartition(String partition) {
    partitions.add(partition);
    return created[partition] = _FakeProfileSession();
  }
}

final class _RecordedLaunch {
  const _RecordedLaunch(this.command, this.args);

  final String command;
  final List<String> args;

  @override
  bool operator ==(Object other) =>
      other is _RecordedLaunch &&
      other.command == command &&
      other.args.length == args.length &&
      List.generate(
        args.length,
        (i) => other.args[i] == args[i],
      ).every((e) => e);

  @override
  int get hashCode => Object.hash(command, Object.hashAll(args));

  @override
  String toString() => '_RecordedLaunch($command, $args)';
}

final class _RecordedMacLaunch {
  const _RecordedMacLaunch(this.applicationName, this.paths);

  final String applicationName;
  final List<String> paths;

  @override
  bool operator ==(Object other) =>
      other is _RecordedMacLaunch &&
      other.applicationName == applicationName &&
      other.paths.length == paths.length &&
      List.generate(
        paths.length,
        (i) => other.paths[i] == paths[i],
      ).every((e) => e);

  @override
  int get hashCode => Object.hash(applicationName, Object.hashAll(paths));

  @override
  String toString() => '_RecordedMacLaunch($applicationName, $paths)';
}

/// Port of upstream's `FakeEditorTargets`, which stands in for `node:fs`,
/// `node:child_process` and Electron's `shell`.
final class _FakeEditorTargets implements EditorTargetRuntime {
  _FakeEditorTargets([
    this.platform = EditorTargetPlatform.linux,
    this.env = const <String, String>{},
  ]);

  final List<_RecordedLaunch> launches = <_RecordedLaunch>[];
  final List<String> openedPaths = <String>[];
  final List<String> revealedPaths = <String>[];
  final List<_RecordedMacLaunch> openedMacApplications = <_RecordedMacLaunch>[];
  final List<String> loadedIcons = <String>[];
  final List<List<String>> resolveCommandQueries = <List<String>>[];

  @override
  final EditorTargetPlatform platform;

  @override
  final Map<String, String> env;

  final Set<String> _paths = <String>{};
  final Map<String, String> _commands = <String, String>{};
  final Set<String> _macApplications = <String>{};

  void addPath(String targetPath) => _paths.add(targetPath);

  void installCommand(String command, [String? executable]) =>
      _commands[command] = executable ?? '/bin/$command';

  void installMacApplication(String applicationName) =>
      _macApplications.add(applicationName);

  @override
  bool pathExists(String path) => _paths.contains(path);

  @override
  bool isAbsolutePath(String path) =>
      path.startsWith('/') || RegExp(r'^[A-Z]:/').hasMatch(path);

  @override
  String? resolveCommand(List<String> commands) {
    resolveCommandQueries.add(List<String>.of(commands));
    for (final command in commands) {
      final executable = _commands[command];
      if (executable != null) return executable;
    }
    return null;
  }

  @override
  Future<void> spawnDetached({
    required String command,
    required List<String> args,
  }) async => launches.add(_RecordedLaunch(command, List<String>.of(args)));

  @override
  Future<void> openPath(String path) async => openedPaths.add(path);

  @override
  void revealPath(String path) => revealedPaths.add(path);

  @override
  Future<EditorTargetIcon> loadIcon(String fileName) async {
    loadedIcons.add(fileName);
    return EditorTargetImageIcon('data:image/png;base64,$fileName');
  }

  @override
  bool hasMacApplication(String applicationName) =>
      _macApplications.contains(applicationName);

  @override
  Future<void> openMacApplication({
    required String applicationName,
    required List<String> paths,
  }) async => openedMacApplications.add(
    _RecordedMacLaunch(applicationName, List<String>.of(paths)),
  );
}

final class _FakeSettingsStore implements PaseoDesktopSettingsStore {
  int getCalls = 0;
  final List<Object?> patchCalls = <Object?>[];
  final List<Object?> migrateCalls = <Object?>[];
  Object? failure;

  static const PaseoDesktopSettings _patched = PaseoDesktopSettings(
    releaseChannel: DesktopAppReleaseChannel.beta,
    daemon: PaseoDesktopDaemonSettings(
      manageBuiltInDaemon: true,
      keepRunningAfterQuit: true,
    ),
  );

  static const PaseoDesktopSettings _migrated = PaseoDesktopSettings(
    releaseChannel: DesktopAppReleaseChannel.beta,
    daemon: PaseoDesktopDaemonSettings(
      manageBuiltInDaemon: false,
      keepRunningAfterQuit: true,
    ),
  );

  @override
  Future<PaseoDesktopSettings> get() async {
    getCalls += 1;
    final error = failure;
    if (error != null) throw error;
    return defaultPaseoDesktopSettings;
  }

  @override
  Future<PaseoDesktopSettings> patch(Object? patch) async {
    patchCalls.add(patch);
    return _patched;
  }

  @override
  Future<PaseoDesktopSettings> migrateLegacyRendererSettings(
    Object? legacySettings,
  ) async {
    migrateCalls.add(legacySettings);
    return _migrated;
  }
}

// ---------------------------------------------------------------------------

DateTime _at(String iso) => DateTime.parse(iso);

void main() {
  // -------------------------------------------------------------------------
  // app-update-rollout.ts
  // -------------------------------------------------------------------------

  group('shouldAdmitAppUpdate', () {
    test('keeps automatic stable updates behind the rollout window', () {
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 0.51,
        ),
        isFalse,
      );
    });

    test('lets manual stable checks bypass rollout admission', () {
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.manual,
          rolloutHours: 24,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
    });

    test('admits beta, missing rollout hours, zero-hour rollout, and missing '
        'release date', () {
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.beta,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-28T01:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: null,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-28T01:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 0,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-28T01:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: null,
          now: _at('2026-04-28T01:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
    });

    test('blocks future automatic releases and admits the same release '
        'manually', () {
      bool admit(DesktopAppUpdateCheckIntent intent) => shouldAdmitAppUpdate(
        channel: DesktopAppReleaseChannel.stable,
        intent: intent,
        rolloutHours: 24,
        releaseDate: '2026-04-28T02:00:00.000Z',
        now: _at('2026-04-28T01:00:00.000Z'),
        bucket: 0,
      );

      expect(admit(DesktopAppUpdateCheckIntent.automatic), isFalse);
      expect(admit(DesktopAppUpdateCheckIntent.manual), isTrue);
    });

    test(
      'blocks the bucket-zero client at exact release time, admits as soon as '
      'time advances',
      () {
        expect(
          shouldAdmitAppUpdate(
            channel: DesktopAppReleaseChannel.stable,
            intent: DesktopAppUpdateCheckIntent.automatic,
            rolloutHours: 24,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: _at('2026-04-28T00:00:00.000Z'),
            bucket: 0,
          ),
          isFalse,
        );
        expect(
          shouldAdmitAppUpdate(
            channel: DesktopAppReleaseChannel.stable,
            intent: DesktopAppUpdateCheckIntent.automatic,
            rolloutHours: 24,
            releaseDate: '2026-04-28T00:00:00.000Z',
            now: _at('2026-04-28T00:00:00.001Z'),
            bucket: 0,
          ),
          isTrue,
        );
      },
    );

    test('admits the highest-bucket automatic client at and past the rollout '
        'end', () {
      const maxBucket = (0x100000000 - 1) / 0x100000000;
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-29T00:00:00.000Z'),
          bucket: maxBucket,
        ),
        isTrue,
      );
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2027-04-28T00:00:00.000Z'),
          bucket: maxBucket,
        ),
        isTrue,
      );
    });

    test('admits when releaseDate is unparseable', () {
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: 'not a date',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('admits when releaseDate is the empty string (JS falsiness)', () {
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: '',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
    });

    test('compares the bucket strictly against the ramp percentage', () {
      bool admitAt(double bucket) => shouldAdmitAppUpdate(
        channel: DesktopAppReleaseChannel.stable,
        intent: DesktopAppUpdateCheckIntent.automatic,
        rolloutHours: 24,
        releaseDate: '2026-04-28T00:00:00.000Z',
        now: _at('2026-04-28T12:00:00.000Z'),
        bucket: bucket,
      );

      // Exactly 50% of the window has elapsed.
      expect(admitAt(0.4999), isTrue);
      expect(admitAt(0.5), isFalse, reason: 'strict `<`, not `<=`');
      expect(admitAt(0.5001), isFalse);
    });

    test('treats a bare YYYY-MM-DD release date as UTC midnight, like JS', () {
      // 12:00Z on the release day is halfway through a 24h ramp only if the
      // date parsed as UTC midnight; a local-midnight reading would shift it.
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: '2026-04-28',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 0.4999,
        ),
        isTrue,
      );
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: '2026-04-28',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 0.5,
        ),
        isFalse,
      );
    });

    test('handles fractional rollout windows', () {
      // A 30-minute ramp, 15 minutes in => 50%.
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 0.5,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-28T00:15:00.000Z'),
          bucket: 0.25,
        ),
        isTrue,
      );
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 0.5,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-28T00:15:00.000Z'),
          bucket: 0.75,
        ),
        isFalse,
      );
    });

    test('blocks everyone when a negative rollout window slips through', () {
      // The manifest schema can never produce this, but the gate is exported
      // separately and divides by whatever it is handed: a negative window
      // yields a negative percentage, which no bucket can beat.
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: -24,
          releaseDate: '2026-04-28T00:00:00.000Z',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 0,
        ),
        isFalse,
      );
    });

    test('checks intent before channel, and channel before the window', () {
      // A future beta release, checked automatically, is still admitted: the
      // channel short-circuit runs before the release date is ever read.
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.beta,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: 24,
          releaseDate: '2999-01-01T00:00:00.000Z',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 1,
        ),
        isTrue,
      );
      // And a manual beta check with garbage everywhere is admitted too.
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.beta,
          intent: DesktopAppUpdateCheckIntent.manual,
          rolloutHours: -1,
          releaseDate: 'nonsense',
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 1,
        ),
        isTrue,
      );
    });
  });

  group('bucketFromStagingUserId', () {
    test('maps the maximum 32-bit slot to a bucket strictly less than 1', () {
      const allOnes = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
      const allZeros = '00000000-0000-0000-0000-000000000000';

      expect(bucketFromStagingUserId(allOnes), lessThan(1));
      expect(bucketFromStagingUserId(allOnes), greaterThan(0.999));
      expect(bucketFromStagingUserId(allZeros), 0);
    });

    // --- edge cases: ground truth captured from the frozen module under Node ---

    test('reproduces the exact Node values for known ids', () {
      expect(
        bucketFromStagingUserId('ffffffff-ffff-ffff-ffff-ffffffffffff'),
        0.9999999997671694,
      );
      expect(
        bucketFromStagingUserId('123e4567-e89b-42d3-a456-426614174000'),
        0.07847976684570312,
      );
      expect(
        bucketFromStagingUserId('deadbeef-dead-beef-dead-beefdeadbeef'),
        0.8698386510368437,
      );
      expect(
        bucketFromStagingUserId('1b4e28ba-2fa1-11d2-883f-0016d3cca427'),
        0.8273413272108883,
      );
      expect(
        bucketFromStagingUserId('00000000-0000-0000-0000-000000000001'),
        2.3283064365386963e-10,
      );
      expect(
        bucketFromStagingUserId('00000000-0000-0000-0000-ffff80000000'),
        0.5,
      );
    });

    test('only the last four bytes of the id matter', () {
      // Everything before character 28 is ignored, so two ids that differ only
      // in their first three groups collide.
      expect(
        bucketFromStagingUserId('00000000-0000-0000-0000-800000000000'),
        0,
      );
      expect(
        bucketFromStagingUserId('ffffffff-ffff-4fff-bfff-fff000000000'),
        0,
      );
    });

    test('reads uppercase hex digits as zero, matching the frozen reader', () {
      // `builder-util-runtime`'s hex table is lowercase-only, so "FFFF0102"
      // parses as 0x00000102 rather than 0xFFFF0102.
      expect(
        bucketFromStagingUserId('AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0102'),
        0x102 / 0x100000000,
      );
    });

    test('never throws on malformed ids — it reads zeroes instead', () {
      expect(bucketFromStagingUserId('not-a-uuid'), 0);
      expect(bucketFromStagingUserId(''), 0);
      expect(bucketFromStagingUserId('12345'), 0);
      // Exactly one character short of byte 15.
      expect(bucketFromStagingUserId('00000000-0000-0000-0000-00000000000'), 0);
    });
  });

  group('parseRolloutManifest', () {
    test('reads well-formed rollout fields', () {
      final parsed = parseRolloutManifest(<String, Object?>{
        'rolloutHours': 24,
        'releaseDate': '2026-04-28T00:00:00.000Z',
      });

      expect(parsed.rolloutHours, 24);
      expect(parsed.releaseDate, '2026-04-28T00:00:00.000Z');
    });

    test('treats garbage manifest rollout fields as missing and admits', () {
      final parsed = parseRolloutManifest(<String, Object?>{
        'rolloutHours': 'not a number',
        'releaseDate': 12345,
      });

      expect(parsed.rolloutHours, isNull);
      expect(parsed.releaseDate, isNull);
      expect(
        shouldAdmitAppUpdate(
          channel: DesktopAppReleaseChannel.stable,
          intent: DesktopAppUpdateCheckIntent.automatic,
          rolloutHours: parsed.rolloutHours,
          releaseDate: parsed.releaseDate,
          now: _at('2026-04-28T12:00:00.000Z'),
          bucket: 0.99,
        ),
        isTrue,
      );
    });

    test('coerces numeric strings the way JS Number() does', () {
      double? hours(Object? value) => parseRolloutManifest(<String, Object?>{
        'rolloutHours': value,
      }).rolloutHours;

      expect(hours('24'), 24);
      expect(hours('  36  '), 36);
      expect(hours(''), 0, reason: 'Number("") is 0, not NaN');
      expect(hours('1e2'), 100);
      expect(hours('0x10'), 16, reason: 'Number() honours the hex prefix');
      expect(hours('0b101'), 5);
      expect(hours('0o17'), 15);
      expect(hours('1.5'), 1.5);
      expect(hours('0x-1'), isNull, reason: 'JS forbids a sign after 0x');
      expect(hours('12abc'), isNull);
    });

    test('drops values the piped number checks reject', () {
      double? hours(Object? value) => parseRolloutManifest(<String, Object?>{
        'rolloutHours': value,
      }).rolloutHours;

      expect(hours(-1), isNull, reason: 'nonnegative()');
      expect(hours('-1'), isNull);
      expect(hours(double.infinity), isNull, reason: 'finite()');
      expect(hours('Infinity'), isNull);
      expect(hours(double.nan), isNull);
      expect(hours('NaN'), isNull);
      expect(hours(null), isNull);
      expect(hours(true), isNull, reason: 'booleans are not numbers');
      expect(hours(<Object?>[]), isNull);
      expect(hours(<String, Object?>{}), isNull);
      expect(hours(0), 0, reason: 'zero is a valid instant rollout');
    });

    test('ignores unknown keys and tolerates missing ones', () {
      final parsed = parseRolloutManifest(<String, Object?>{
        'extra': 1,
        'rolloutHours': 3,
      });
      expect(parsed.rolloutHours, 3);
      expect(parsed.releaseDate, isNull);

      final empty = parseRolloutManifest(<String, Object?>{});
      expect(empty.rolloutHours, isNull);
      expect(empty.releaseDate, isNull);
      expect(empty, const RolloutManifest());
    });

    test('rejects a non-object manifest', () {
      for (final input in <Object?>[null, 'str', 5, <Object?>[]]) {
        expect(
          () => parseRolloutManifest(input),
          throwsA(isA<FormatException>()),
          reason: 'input: $input',
        );
      }
    });

    test('has value equality and a readable description', () {
      const a = RolloutManifest(rolloutHours: 4, releaseDate: 'x');
      const b = RolloutManifest(rolloutHours: 4, releaseDate: 'x');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const RolloutManifest(rolloutHours: 5)));
      expect(a.toString(), contains('rolloutHours: 4'));
    });
  });

  // -------------------------------------------------------------------------
  // browser-profile.ts
  // -------------------------------------------------------------------------

  group('listPaseoBrowserProfileGuests', () {
    test('returns every live webview and popup in the shared profile', () {
      final profileSession = Object();
      final firstWindowGuest = _FakeWebContents(1, profileSession, 'webview');
      final secondWindowGuest = _FakeWebContents(2, profileSession, 'webview');
      final foreignProfileGuest = _FakeWebContents(3, Object(), 'webview');
      final popupWindow = _FakeWebContents(4, profileSession, 'window');
      final destroyedGuest = _FakeWebContents(
        5,
        profileSession,
        'webview',
        destroyed: true,
      );

      final guests = listPaseoBrowserProfileGuests(
        profileSession: profileSession,
        webContents: <BrowserProfileWebContents>[
          firstWindowGuest,
          secondWindowGuest,
          foreignProfileGuest,
          popupWindow,
          destroyedGuest,
        ],
      );

      expect(guests, <BrowserProfileGuest>[
        firstWindowGuest,
        secondWindowGuest,
        popupWindow,
      ]);
    });

    test('drops contents types that are neither webview nor window', () {
      final profileSession = Object();
      final browserView = _FakeWebContents(1, profileSession, 'browserView');
      final backgroundPage = _FakeWebContents(
        2,
        profileSession,
        'backgroundPage',
      );
      final webview = _FakeWebContents(3, profileSession, 'webview');

      expect(
        listPaseoBrowserProfileGuests(
          profileSession: profileSession,
          webContents: <BrowserProfileWebContents>[
            browserView,
            backgroundPage,
            webview,
          ],
        ),
        <BrowserProfileGuest>[webview],
      );
    });

    test('compares sessions by identity, not equality', () {
      // Two distinct-but-equal session objects must not be confused.
      final profileSession = <String, Object?>{'partition': 'p'};
      final lookalike = <String, Object?>{'partition': 'p'};
      expect(profileSession, lookalike);

      final guest = _FakeWebContents(1, lookalike, 'webview');
      expect(
        listPaseoBrowserProfileGuests(
          profileSession: profileSession,
          webContents: <BrowserProfileWebContents>[guest],
        ),
        isEmpty,
      );
    });

    test('returns an empty list when nothing matches', () {
      expect(
        listPaseoBrowserProfileGuests(
          profileSession: Object(),
          webContents: const <BrowserProfileWebContents>[],
        ),
        isEmpty,
      );
    });
  });

  group('legacy browser profiles', () {
    test('accepts only unique saved browser ids and resolves their old '
        'partitions', () {
      const uuid = '123e4567-e89b-42d3-a456-426614174000';
      const fallbackId = '1700000000000-abcd';
      final browserIds = readLegacyPaseoBrowserIds(<Object?>[
        uuid,
        fallbackId,
        uuid,
        'not-a-browser-id',
        123,
      ]);
      final sessions = _FakeSessions();

      final resolved = getPaseoBrowserProfileSessions(sessions, browserIds);

      expect(sessions.partitions, <String>[
        'persist:paseo-browser',
        'persist:paseo-browser-$uuid',
        'persist:paseo-browser-$fallbackId',
      ]);
      expect(resolved, hasLength(3));
    });

    test('resolves one valid legacy profile for tab-close cleanup', () {
      final sessions = _FakeSessions();

      expect(
        getLegacyPaseoBrowserProfileSession(sessions, '1700000000000-abcd'),
        isNotNull,
      );
      expect(getLegacyPaseoBrowserProfileSession(sessions, 'invalid'), isNull);
      expect(sessions.partitions, <String>[
        'persist:paseo-browser-1700000000000-abcd',
      ]);
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('returns nothing for a non-list stored value', () {
      for (final input in <Object?>[
        null,
        'a-string',
        42,
        <String, Object?>{'0': 'x'},
      ]) {
        expect(readLegacyPaseoBrowserIds(input), isEmpty, reason: '$input');
      }
    });

    test('accepts only v4 UUIDs and the epoch-millis fallback shape', () {
      const accepted = <String>[
        '123e4567-e89b-42d3-a456-426614174000',
        '123E4567-E89B-42D3-A456-426614174000', // case-insensitive
        '00000000-0000-4000-8000-000000000000',
        '00000000-0000-4000-9000-000000000000',
        '00000000-0000-4000-a000-000000000000',
        '00000000-0000-4000-b000-000000000000',
        '1700000000000-a',
        '17000000000000000-deadbeef',
      ];
      for (final id in accepted) {
        expect(readLegacyPaseoBrowserIds(<Object?>[id]), <String>[id]);
      }

      const rejected = <String>[
        '123e4567-e89b-12d3-a456-426614174000', // version 1, not 4
        '123e4567-e89b-42d3-c456-426614174000', // variant not 8/9/a/b
        '123e4567-e89b-42d3-a456-42661417400', // one hex short
        '123e4567-e89b-42d3-a456-4266141740000', // one hex long
        '170000000000-abcd', // only 12 digits
        '1700000000000-', // no hex suffix
        '1700000000000-xyz', // suffix is not hex
        ' 1700000000000-abcd', // leading space
        '1700000000000-abcd\n', // trailing newline must not slip past `\$`
        '',
      ];
      for (final id in rejected) {
        expect(
          readLegacyPaseoBrowserIds(<Object?>[id]),
          isEmpty,
          reason: 'should reject ${id.trim()}',
        );
      }
    });

    test('caps the number of legacy profiles it will open', () {
      final ids = <Object?>[
        for (var i = 0; i < 1500; i++)
          '1700000000${i.toString().padLeft(3, '0')}-abcd',
      ];
      expect(readLegacyPaseoBrowserIds(ids), hasLength(1000));
    });

    test('returns only the shared profile when there are no legacy ids', () {
      final sessions = _FakeSessions();
      final resolved = getPaseoBrowserProfileSessions(
        sessions,
        const <String>[],
      );

      expect(resolved, hasLength(1));
      expect(sessions.partitions, <String>['persist:paseo-browser']);
      expect(
        getPaseoBrowserProfileSession(_FakeSessions()),
        isA<BrowserProfileSession>(),
      );
      expect(paseoBrowserProfilePartition, 'persist:paseo-browser');
    });

    test('never touches the session module for a rejected tab id', () {
      final sessions = _FakeSessions();
      expect(
        getLegacyPaseoBrowserProfileSession(sessions, '../../etc/passwd'),
        isNull,
      );
      expect(sessions.partitions, isEmpty);
    });
  });

  group('clearPaseoBrowserProfile', () {
    test('clears site data, HTTP cache, and auth before reloading live '
        'guests', () async {
      final profile = _FakeProfileSession();
      final legacyProfile = _FakeProfileSession();
      profile.storageClearGate = Completer<void>();
      final firstGuest = _FakeGuest(1);
      final secondGuest = _FakeGuest(2);

      final clearing = clearPaseoBrowserProfile(
        profileSessions: <BrowserProfileSession>[profile, legacyProfile],
        listGuests: () => <BrowserProfileGuest>[firstGuest, secondGuest],
        logReloadError: (_, _) {},
      );

      await pumpEventQueue();
      expect(firstGuest.reloads, 0);
      expect(secondGuest.reloads, 0);
      profile.storageClearGate!.complete();
      await clearing;

      expect(profile.storageClears, <BrowserProfileStorageClearRequest>[
        const BrowserProfileStorageClearRequest(
          storages: <BrowserProfileStorageType>[
            BrowserProfileStorageType.cookies,
            BrowserProfileStorageType.filesystem,
            BrowserProfileStorageType.indexdb,
            BrowserProfileStorageType.localstorage,
            BrowserProfileStorageType.serviceworkers,
            BrowserProfileStorageType.cachestorage,
            BrowserProfileStorageType.websql,
          ],
        ),
      ]);
      expect(profile.cacheClears, 1);
      expect(profile.authClears, 1);
      expect(legacyProfile.storageClears, profile.storageClears);
      expect(legacyProfile.cacheClears, 1);
      expect(legacyProfile.authClears, 1);
      expect(firstGuest.reloads, 1);
      expect(secondGuest.reloads, 1);
    });

    test(
      'skips destroyed guests and logs individual reload failures',
      () async {
        final profile = _FakeProfileSession();
        final destroyedGuest = _FakeGuest(1, destroyed: true);
        final reloadError = StateError('guest disappeared');
        final failedGuest = _FakeGuest(2, reloadError: reloadError);
        final survivor = _FakeGuest(3);
        final reloadErrors = <(int, Object)>[];

        await clearPaseoBrowserProfile(
          profileSessions: <BrowserProfileSession>[profile],
          listGuests: () => <BrowserProfileGuest>[
            destroyedGuest,
            failedGuest,
            survivor,
          ],
          logReloadError: (guestId, error) =>
              reloadErrors.add((guestId, error)),
        );

        expect(destroyedGuest.reloads, 0);
        expect(failedGuest.reloads, 0);
        expect(reloadErrors, <(int, Object)>[(2, reloadError)]);
        expect(
          survivor.reloads,
          1,
          reason: 'one failure must not abort the remaining reloads',
        );
      },
    );

    test('propagates clear failures without reloading guests', () async {
      final profile = _FakeProfileSession();
      final clearError = StateError('profile locked');
      profile.storageClearError = clearError;
      final guest = _FakeGuest(1);

      await expectLater(
        clearPaseoBrowserProfile(
          profileSessions: <BrowserProfileSession>[profile],
          listGuests: () => <BrowserProfileGuest>[guest],
          logReloadError: (_, _) {},
        ),
        throwsA(same(clearError)),
      );
      expect(guest.reloads, 0);
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('reloads guests even when there is nothing to clear', () async {
      final guest = _FakeGuest(1);
      await clearPaseoBrowserProfile(
        profileSessions: const <BrowserProfileSession>[],
        listGuests: () => <BrowserProfileGuest>[guest],
        logReloadError: (_, _) {},
      );
      expect(guest.reloads, 1);
    });

    test('lists guests only after every wipe has finished', () async {
      final profile = _FakeProfileSession();
      profile.storageClearGate = Completer<void>();
      var listed = 0;

      final clearing = clearPaseoBrowserProfile(
        profileSessions: <BrowserProfileSession>[profile],
        listGuests: () {
          listed += 1;
          return const <BrowserProfileGuest>[];
        },
        logReloadError: (_, _) {},
      );

      await pumpEventQueue();
      expect(listed, 0, reason: 'guests are discovered after the wipe');
      profile.storageClearGate!.complete();
      await clearing;
      expect(listed, 1);
    });

    test('storage clear requests compare by value', () {
      expect(
        const BrowserProfileStorageClearRequest(
          storages: <BrowserProfileStorageType>[
            BrowserProfileStorageType.cookies,
          ],
        ),
        const BrowserProfileStorageClearRequest(
          storages: <BrowserProfileStorageType>[
            BrowserProfileStorageType.cookies,
          ],
        ),
      );
      expect(
        const BrowserProfileStorageClearRequest(
          storages: <BrowserProfileStorageType>[
            BrowserProfileStorageType.cookies,
          ],
        ),
        isNot(
          const BrowserProfileStorageClearRequest(
            storages: <BrowserProfileStorageType>[
              BrowserProfileStorageType.websql,
            ],
          ),
        ),
      );
      expect(
        paseoBrowserProfileStorageTypes
            .map((type) => type.wireName)
            .toList(growable: false),
        <String>[
          'cookies',
          'filesystem',
          'indexdb',
          'localstorage',
          'serviceworkers',
          'cachestorage',
          'websql',
        ],
      );
    });
  });

  // -------------------------------------------------------------------------
  // editor-targets/registry.ts
  // -------------------------------------------------------------------------

  group('editor target registry', () {
    test(
      'lists installed target implementations in registration order',
      () async {
        final runtime = _FakeEditorTargets();
        runtime.installCommand('code');
        runtime.installCommand('webstorm');

        final targets = await listAvailableEditorTargets(
          runtime,
          <EditorTarget>[
            cursorTarget,
            vscodeTarget,
            webstormTarget,
            fileManagerTarget,
          ],
        );

        expect(targets, <EditorTargetDescriptor>[
          const EditorTargetDescriptor(
            id: 'vscode',
            label: 'VS Code',
            kind: EditorTargetKind.editor,
            icon: EditorTargetImageIcon('data:image/png;base64,vscode.png'),
          ),
          const EditorTargetDescriptor(
            id: 'webstorm',
            label: 'WebStorm',
            kind: EditorTargetKind.editor,
            icon: EditorTargetImageIcon('data:image/png;base64,webstorm.png'),
          ),
          const EditorTargetDescriptor(
            id: 'file-manager',
            label: 'Files',
            kind: EditorTargetKind.fileManager,
            icon: EditorTargetSymbolIcon(EditorTargetSymbol.folder),
          ),
        ]);
      },
    );

    test('opens a selected file at its position through the target '
        'implementation', () async {
      final runtime = _FakeEditorTargets();
      runtime.installCommand('code');
      runtime.addPath('/repo');
      runtime.addPath('/repo/src/app.ts');

      await openEditorTarget(
        const EditorTargetOpenInput(
          editorId: 'vscode',
          workspacePath: '/repo',
          filePath: '/repo/src/app.ts',
          line: 12,
          column: 4,
        ),
        runtime,
        <EditorTarget>[vscodeTarget],
      );

      expect(runtime.launches, <_RecordedLaunch>[
        const _RecordedLaunch('/bin/code', <String>[
          '/repo',
          '--goto',
          '/repo/src/app.ts:12:4',
        ]),
      ]);
    });

    test('lets each target choose its own command and arguments', () async {
      final runtime = _FakeEditorTargets();
      runtime.installCommand('zeditor');
      runtime.installCommand('webstorm');
      runtime.installCommand('idea');

      await zedTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: '/repo',
          filePath: '/repo/src/app.ts',
          line: 7,
          column: 2,
        ),
        runtime,
      );
      await webstormTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: '/repo',
          filePath: '/repo/src/app.ts',
          line: 7,
          column: 2,
        ),
        runtime,
      );
      await intellijIdeaTarget.launch(
        const EditorTargetLaunchInput(workspacePath: '/repo'),
        runtime,
      );

      expect(runtime.launches, <_RecordedLaunch>[
        const _RecordedLaunch('/bin/zeditor', <String>[
          '/repo',
          '/repo/src/app.ts:7:2',
        ]),
        const _RecordedLaunch('/bin/webstorm', <String>[
          '--line',
          '7',
          '--column',
          '2',
          '/repo',
          '/repo/src/app.ts',
        ]),
        const _RecordedLaunch('/bin/idea', <String>['/repo']),
      ]);
    });

    test('recognizes Windows 64-bit project IDE launchers', () async {
      final runtime = _FakeEditorTargets(EditorTargetPlatform.win32);
      runtime.installCommand('pycharm64', 'C:/Tools/PyCharm/bin/pycharm64.exe');

      expect(await pycharmTarget.isInstalled(runtime), isTrue);
      await pycharmTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: 'C:/repo',
          filePath: 'C:/repo/src/app.py',
          line: 6,
        ),
        runtime,
      );

      expect(runtime.launches, <_RecordedLaunch>[
        const _RecordedLaunch('C:/Tools/PyCharm/bin/pycharm64.exe', <String>[
          '--line',
          '6',
          'C:/repo',
          'C:/repo/src/app.py',
        ]),
      ]);
    });

    test('detects and launches the macOS application when the command is '
        'absent', () async {
      final runtime = _FakeEditorTargets(EditorTargetPlatform.darwin);
      runtime.installMacApplication('Cursor');

      expect(await cursorTarget.isInstalled(runtime), isTrue);
      await cursorTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: '/repo',
          filePath: '/repo/src/app.ts',
        ),
        runtime,
      );

      expect(runtime.openedMacApplications, <_RecordedMacLaunch>[
        const _RecordedMacLaunch('Cursor', <String>[
          '/repo',
          '/repo/src/app.ts',
        ]),
      ]);
    });

    test("uses Cursor's bundled macOS command so file positions survive "
        'application detection', () async {
      final runtime = _FakeEditorTargets(EditorTargetPlatform.darwin);
      const bundledCommand =
          '/Applications/Cursor.app/Contents/Resources/app/bin/cursor';
      runtime.installCommand(bundledCommand, bundledCommand);

      expect(await cursorTarget.isInstalled(runtime), isTrue);
      await cursorTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: '/repo',
          filePath: '/repo/src/app.ts',
          line: 18,
          column: 3,
        ),
        runtime,
      );

      expect(runtime.launches, <_RecordedLaunch>[
        const _RecordedLaunch(bundledCommand, <String>[
          '/repo',
          '--goto',
          '/repo/src/app.ts:18:3',
        ]),
      ]);
    });

    test("detects Cursor's installed Windows command when it is absent from "
        'PATH', () async {
      final runtime = _FakeEditorTargets(
        EditorTargetPlatform.win32,
        const <String, String>{'LOCALAPPDATA': 'C:/Users/me/AppData/Local'},
      );
      const installedCommand =
          'C:/Users/me/AppData/Local/Programs/cursor/resources/app/bin/'
          'cursor.cmd';
      runtime.installCommand(installedCommand, installedCommand);

      expect(await cursorTarget.isInstalled(runtime), isTrue);
      await cursorTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: 'C:/repo',
          filePath: 'C:/repo/src/app.ts',
          line: 9,
        ),
        runtime,
      );

      expect(runtime.launches, <_RecordedLaunch>[
        const _RecordedLaunch(installedCommand, <String>[
          'C:/repo',
          '--goto',
          'C:/repo/src/app.ts:9',
        ]),
      ]);
    });

    test('delegates folder opening and file reveal to the system file '
        'manager', () async {
      final runtime = _FakeEditorTargets(EditorTargetPlatform.win32);

      expect(
        await explorerTarget.describe(runtime),
        const EditorTargetDescriptor(
          id: 'explorer',
          label: 'Explorer',
          kind: EditorTargetKind.fileManager,
          icon: EditorTargetSymbolIcon(EditorTargetSymbol.folder),
        ),
      );
      await explorerTarget.launch(
        const EditorTargetLaunchInput(workspacePath: 'C:/repo'),
        runtime,
      );
      await explorerTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: 'C:/repo',
          filePath: 'C:/repo/src/app.ts',
        ),
        runtime,
      );

      expect(runtime.openedPaths, <String>['C:/repo']);
      expect(runtime.revealedPaths, <String>['C:/repo/src/app.ts']);
    });

    test(
      'keeps the platform file-manager ids used by stored preferences',
      () async {
        const fileManagers = <EditorTarget>[
          finderTarget,
          explorerTarget,
          fileManagerTarget,
        ];
        final macTargets = await listAvailableEditorTargets(
          _FakeEditorTargets(EditorTargetPlatform.darwin),
          fileManagers,
        );
        final windowsTargets = await listAvailableEditorTargets(
          _FakeEditorTargets(EditorTargetPlatform.win32),
          fileManagers,
        );

        expect(
          macTargets.map((target) => target.id).toList(growable: false),
          <String>['finder'],
        );
        expect(
          windowsTargets.map((target) => target.id).toList(growable: false),
          <String>['explorer'],
        );
      },
    );

    // --- edge cases the upstream suite leaves unpinned ---

    test('registers all 23 targets in the documented order', () {
      expect(
        editorTargets.map((target) => target.id).toList(growable: false),
        <String>[
          'cursor',
          'trae',
          'kiro',
          'vscode',
          'vscode-insiders',
          'vscodium',
          'zed',
          'antigravity',
          'intellij-idea',
          'aqua',
          'clion',
          'datagrip',
          'dataspell',
          'goland',
          'phpstorm',
          'pycharm',
          'rider',
          'rubymine',
          'rustrover',
          'webstorm',
          'finder',
          'explorer',
          'file-manager',
        ],
      );
    });

    test('every registered id resolves back to its own target', () {
      for (final target in editorTargets) {
        expect(identical(getEditorTarget(target.id), target), isTrue);
      }
    });

    test('rejects an unknown editor id by name', () {
      expect(
        () => getEditorTarget('emacs'),
        throwsA(
          isA<EditorTargetError>().having(
            (error) => error.message,
            'message',
            'Unknown editor target: emacs',
          ),
        ),
      );
      expect(
        const EditorTargetError('boom').toString(),
        'EditorTargetError: boom',
      );
    });

    test('validates paths before it ever looks up the target', () async {
      final runtime = _FakeEditorTargets();
      runtime.installCommand('code');

      Future<void> open({
        String workspacePath = '/repo',
        String? filePath,
        String editorId = 'vscode',
      }) => openEditorTarget(
        EditorTargetOpenInput(
          editorId: editorId,
          workspacePath: workspacePath,
          filePath: filePath,
        ),
        runtime,
        <EditorTarget>[vscodeTarget],
      );

      // Relative workspace path — checked before existence.
      await expectLater(
        open(workspacePath: 'repo'),
        throwsA(
          isA<EditorTargetError>().having(
            (error) => error.message,
            'message',
            'Editor target workspace path must be an absolute local path',
          ),
        ),
      );

      // Absolute but missing.
      await expectLater(
        open(),
        throwsA(
          isA<EditorTargetError>().having(
            (error) => error.message,
            'message',
            'Path does not exist: /repo',
          ),
        ),
      );

      runtime.addPath('/repo');

      await expectLater(
        open(filePath: 'src/app.ts'),
        throwsA(
          isA<EditorTargetError>().having(
            (error) => error.message,
            'message',
            'Editor target file path must be an absolute local path',
          ),
        ),
      );
      await expectLater(
        open(filePath: '/repo/src/app.ts'),
        throwsA(
          isA<EditorTargetError>().having(
            (error) => error.message,
            'message',
            'Path does not exist: /repo/src/app.ts',
          ),
        ),
      );

      // A bad editor id is only reported once the paths check out.
      await expectLater(
        open(editorId: 'emacs'),
        throwsA(
          isA<EditorTargetError>().having(
            (error) => error.message,
            'message',
            'Unknown editor target: emacs',
          ),
        ),
      );

      expect(runtime.launches, isEmpty);
    });

    test('reports an uninstalled target by its human label', () async {
      final runtime = _FakeEditorTargets();
      runtime.addPath('/repo');

      await expectLater(
        openEditorTarget(
          const EditorTargetOpenInput(
            editorId: 'vscode',
            workspacePath: '/repo',
          ),
          runtime,
          <EditorTarget>[vscodeTarget],
        ),
        throwsA(
          isA<EditorTargetError>().having(
            (error) => error.message,
            'message',
            'Editor target unavailable: VS Code',
          ),
        ),
      );
      expect(runtime.launches, isEmpty);
    });

    test('treats an empty filePath as no file at all (JS falsiness)', () async {
      final runtime = _FakeEditorTargets();
      runtime.installCommand('code');
      runtime.addPath('/repo');

      // An empty string skips file validation entirely — a `!= null` check
      // would have demanded an absolute, existing path here.
      await openEditorTarget(
        const EditorTargetOpenInput(
          editorId: 'vscode',
          workspacePath: '/repo',
          filePath: '',
          line: 5,
        ),
        runtime,
        <EditorTarget>[vscodeTarget],
      );

      expect(runtime.launches, <_RecordedLaunch>[
        const _RecordedLaunch('/bin/code', <String>['/repo']),
      ]);
    });

    test('treats line 0 and column 0 as no position (JS falsiness)', () async {
      final runtime = _FakeEditorTargets();
      runtime.installCommand('code');
      runtime.installCommand('webstorm');
      runtime.installCommand('zeditor');

      const input = EditorTargetLaunchInput(
        workspacePath: '/repo',
        filePath: '/repo/src/app.ts',
        line: 0,
        column: 0,
      );
      await vscodeTarget.launch(input, runtime);
      await webstormTarget.launch(input, runtime);
      await zedTarget.launch(input, runtime);

      expect(runtime.launches, <_RecordedLaunch>[
        const _RecordedLaunch('/bin/code', <String>[
          '/repo',
          '/repo/src/app.ts',
        ]),
        const _RecordedLaunch('/bin/webstorm', <String>[
          '/repo',
          '/repo/src/app.ts',
        ]),
        const _RecordedLaunch('/bin/zeditor', <String>[
          '/repo',
          '/repo/src/app.ts',
        ]),
      ]);
    });

    test('drops a column that has no line for the VS Code family, keeps it '
        'for JetBrains', () async {
      final runtime = _FakeEditorTargets();
      runtime.installCommand('code');
      runtime.installCommand('webstorm');

      const input = EditorTargetLaunchInput(
        workspacePath: '/repo',
        filePath: '/repo/src/app.ts',
        column: 4,
      );
      await vscodeTarget.launch(input, runtime);
      await webstormTarget.launch(input, runtime);

      expect(runtime.launches, <_RecordedLaunch>[
        // `--goto` is only emitted when a line exists, so the column is lost.
        const _RecordedLaunch('/bin/code', <String>[
          '/repo',
          '/repo/src/app.ts',
        ]),
        // JetBrains flags are independent, so `--column` survives alone.
        const _RecordedLaunch('/bin/webstorm', <String>[
          '--column',
          '4',
          '/repo',
          '/repo/src/app.ts',
        ]),
      ]);
    });

    test('prefixes the Kiro CLI with its ide subcommand', () async {
      final runtime = _FakeEditorTargets();
      runtime.installCommand('kiro');

      await kiroTarget.launch(
        const EditorTargetLaunchInput(workspacePath: '/repo'),
        runtime,
      );
      await kiroTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: '/repo',
          filePath: '/repo/a.ts',
        ),
        runtime,
      );
      await kiroTarget.launch(
        const EditorTargetLaunchInput(
          workspacePath: '/repo',
          filePath: '/repo/a.ts',
          line: 3,
          column: 1,
        ),
        runtime,
      );

      expect(runtime.launches, <_RecordedLaunch>[
        const _RecordedLaunch('/bin/kiro', <String>['ide', '/repo']),
        const _RecordedLaunch('/bin/kiro', <String>[
          'ide',
          '/repo',
          '/repo/a.ts',
        ]),
        const _RecordedLaunch('/bin/kiro', <String>[
          'ide',
          '/repo',
          '--goto',
          '/repo/a.ts:3:1',
        ]),
      ]);
    });

    test(
      'every target family refuses to launch when it is not installed',
      () async {
        final runtime = _FakeEditorTargets();

        for (final target in <EditorTarget>[
          vscodeTarget, // _CodeStyleTarget
          traeTarget, // _SimpleGotoTarget
          zedTarget, // _ZedTarget
          webstormTarget, // _JetBrainsTarget
        ]) {
          expect(await target.isInstalled(runtime), isFalse, reason: target.id);
          await expectLater(
            target.launch(
              const EditorTargetLaunchInput(workspacePath: '/repo'),
              runtime,
            ),
            throwsA(
              isA<EditorTargetError>().having(
                (error) => error.message,
                'message',
                endsWith(' is not installed'),
              ),
            ),
            reason: target.id,
          );
        }
      },
    );

    test(
      'falls back to the macOS bundle for Zed and drops the position',
      () async {
        final runtime = _FakeEditorTargets(EditorTargetPlatform.darwin);
        runtime.installMacApplication('Zed');

        expect(await zedTarget.isInstalled(runtime), isTrue);
        await zedTarget.launch(
          const EditorTargetLaunchInput(
            workspacePath: '/repo',
            filePath: '/repo/a.ts',
            line: 4,
            column: 2,
          ),
          runtime,
        );
        await zedTarget.launch(
          const EditorTargetLaunchInput(workspacePath: '/repo'),
          runtime,
        );

        expect(runtime.openedMacApplications, <_RecordedMacLaunch>[
          // `open -a` cannot express a line, so 4:2 is lost here.
          const _RecordedMacLaunch('Zed', <String>['/repo', '/repo/a.ts']),
          const _RecordedMacLaunch('Zed', <String>['/repo']),
        ]);
        expect(runtime.launches, isEmpty);
      },
    );

    test('probes macOS bundle paths only with a non-blank HOME', () async {
      final withoutHome = _FakeEditorTargets(
        EditorTargetPlatform.darwin,
        const <String, String>{'HOME': ''},
      );
      await vscodeTarget.isInstalled(withoutHome);

      final withHome = _FakeEditorTargets(
        EditorTargetPlatform.darwin,
        const <String, String>{'HOME': '/Users/me'},
      );
      await vscodeTarget.isInstalled(withHome);

      const bundled =
          '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/'
          'code';
      expect(withoutHome.resolveCommandQueries.single, <String>[
        'code',
        bundled,
      ]);
      expect(withHome.resolveCommandQueries.single, <String>[
        'code',
        bundled,
        '/Users/me$bundled',
      ]);
    });

    test('probes Windows install locations only for the env vars that are '
        'set', () async {
      final none = _FakeEditorTargets(EditorTargetPlatform.win32);
      await cursorTarget.isInstalled(none);
      expect(none.resolveCommandQueries.single, <String>['cursor']);

      final both = _FakeEditorTargets(
        EditorTargetPlatform.win32,
        const <String, String>{
          'LOCALAPPDATA': 'C:/Local',
          'ProgramFiles': 'C:/Program Files',
        },
      );
      await cursorTarget.isInstalled(both);
      expect(both.resolveCommandQueries.single, <String>[
        'cursor',
        'C:/Local/Programs/cursor/resources/app/bin/cursor.cmd',
        'C:/Local/Programs/cursor/Cursor.exe',
        'C:/Program Files/Cursor/resources/app/bin/cursor.cmd',
        'C:/Program Files/Cursor/Cursor.exe',
      ]);

      // Linux never consults either variable.
      final linux = _FakeEditorTargets(
        EditorTargetPlatform.linux,
        const <String, String>{'LOCALAPPDATA': 'C:/Local'},
      );
      await cursorTarget.isInstalled(linux);
      expect(linux.resolveCommandQueries.single, <String>['cursor']);
    });

    test(
      'falls back to the VS Code macOS bundle when no command resolves',
      () async {
        final runtime = _FakeEditorTargets(EditorTargetPlatform.darwin);
        runtime.installMacApplication('Visual Studio Code');

        expect(await vscodeTarget.isInstalled(runtime), isTrue);
        await vscodeTarget.launch(
          const EditorTargetLaunchInput(workspacePath: '/repo'),
          runtime,
        );

        expect(runtime.openedMacApplications, <_RecordedMacLaunch>[
          const _RecordedMacLaunch('Visual Studio Code', <String>['/repo']),
        ]);
      },
    );

    test(
      'uses a glyph instead of loading an icon where upstream does',
      () async {
        final runtime = _FakeEditorTargets();

        expect(
          (await vscodeInsidersTarget.describe(runtime)).icon,
          const EditorTargetSymbolIcon(EditorTargetSymbol.terminal),
        );
        expect(
          (await vscodiumTarget.describe(runtime)).icon,
          const EditorTargetSymbolIcon(EditorTargetSymbol.terminal),
        );
        expect(
          (await intellijIdeaTarget.describe(runtime)).icon,
          const EditorTargetSymbolIcon(EditorTargetSymbol.terminal),
        );
        expect(runtime.loadedIcons, isEmpty);

        expect(
          (await antigravityTarget.describe(runtime)).icon,
          const EditorTargetImageIcon('data:image/png;base64,antigravity.png'),
        );
        expect(
          (await finderTarget.describe(runtime)).icon,
          const EditorTargetImageIcon('data:image/png;base64,finder.png'),
        );
        expect(runtime.loadedIcons, <String>['antigravity.png', 'finder.png']);
      },
    );

    test('offers the generic file manager on every non-mac, non-Windows '
        'platform', () async {
      for (final platform in <EditorTargetPlatform>[
        EditorTargetPlatform.linux,
        EditorTargetPlatform.other,
      ]) {
        final runtime = _FakeEditorTargets(platform);
        expect(await fileManagerTarget.isInstalled(runtime), isTrue);
        expect(await finderTarget.isInstalled(runtime), isFalse);
        expect(await explorerTarget.isInstalled(runtime), isFalse);
      }
    });

    test('maps Node platform strings onto the enum', () {
      expect(
        EditorTargetPlatform.fromNodePlatform('darwin'),
        EditorTargetPlatform.darwin,
      );
      expect(
        EditorTargetPlatform.fromNodePlatform('win32'),
        EditorTargetPlatform.win32,
      );
      expect(
        EditorTargetPlatform.fromNodePlatform('linux'),
        EditorTargetPlatform.linux,
      );
      expect(
        EditorTargetPlatform.fromNodePlatform('freebsd'),
        EditorTargetPlatform.other,
      );
      expect(EditorTargetKind.fileManager.wireName, 'file-manager');
      expect(EditorTargetKind.editor.wireName, 'editor');
    });

    test('descriptors and icons compare by value', () {
      const descriptor = EditorTargetDescriptor(
        id: 'zed',
        label: 'Zed',
        kind: EditorTargetKind.editor,
        icon: EditorTargetSymbolIcon(EditorTargetSymbol.terminal),
      );
      expect(
        descriptor,
        const EditorTargetDescriptor(
          id: 'zed',
          label: 'Zed',
          kind: EditorTargetKind.editor,
          icon: EditorTargetSymbolIcon(EditorTargetSymbol.terminal),
        ),
      );
      expect(
        descriptor.hashCode,
        const EditorTargetDescriptor(
          id: 'zed',
          label: 'Zed',
          kind: EditorTargetKind.editor,
          icon: EditorTargetSymbolIcon(EditorTargetSymbol.terminal),
        ).hashCode,
      );
      expect(
        descriptor,
        isNot(
          const EditorTargetDescriptor(
            id: 'zed',
            label: 'Zed',
            kind: EditorTargetKind.editor,
            icon: EditorTargetSymbolIcon(EditorTargetSymbol.folder),
          ),
        ),
      );
      expect(descriptor.toString(), contains('id: zed'));
      expect(
        const EditorTargetImageIcon('a'),
        isNot(const EditorTargetImageIcon('b')),
      );
      expect(
        const EditorTargetImageIcon('a').hashCode,
        const EditorTargetImageIcon('a').hashCode,
      );
      expect(const EditorTargetImageIcon('a').toString(), contains('a'));
      expect(
        const EditorTargetSymbolIcon(EditorTargetSymbol.folder).toString(),
        contains('folder'),
      );
    });

    test('an empty target list yields no descriptors', () async {
      expect(
        await listAvailableEditorTargets(
          _FakeEditorTargets(),
          const <EditorTarget>[],
        ),
        isEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  // settings/desktop-settings-commands.ts
  // -------------------------------------------------------------------------

  group('desktop-settings-commands', () {
    test('exposes get and patch handlers through the desktop command bus '
        'shape', () async {
      final store = _FakeSettingsStore();
      final handlers = createDesktopSettingsCommandHandlers(
        settingsStore: store,
      );

      expect(
        await handlers[getDesktopSettingsCommand]!(),
        defaultPaseoDesktopSettings,
      );
      expect(
        await handlers[patchDesktopSettingsCommand]!(<String, Object?>{
          'daemon': <String, Object?>{'keepRunningAfterQuit': false},
        }),
        const PaseoDesktopSettings(
          releaseChannel: DesktopAppReleaseChannel.beta,
          daemon: PaseoDesktopDaemonSettings(
            manageBuiltInDaemon: true,
            keepRunningAfterQuit: true,
          ),
        ),
      );

      expect(store.getCalls, 1);
      expect(store.patchCalls, <Object?>[
        <String, Object?>{
          'daemon': <String, Object?>{'keepRunningAfterQuit': false},
        },
      ]);
    });

    test('accepts legacy renderer settings migration payloads', () async {
      final store = _FakeSettingsStore();
      final handlers = createDesktopSettingsCommandHandlers(
        settingsStore: store,
      );

      final result =
          await handlers[migrateLegacyDesktopSettingsCommand]!(
                <String, Object?>{
                  'releaseChannel': 'beta',
                  'manageBuiltInDaemon': false,
                },
              )
              as PaseoDesktopSettings;

      expect(
        result,
        const PaseoDesktopSettings(
          releaseChannel: DesktopAppReleaseChannel.beta,
          daemon: PaseoDesktopDaemonSettings(
            manageBuiltInDaemon: false,
            keepRunningAfterQuit: true,
          ),
        ),
      );
      expect(store.migrateCalls, <Object?>[
        <String, Object?>{
          'releaseChannel': 'beta',
          'manageBuiltInDaemon': false,
        },
      ]);
    });

    // --- edge cases the upstream suite leaves unpinned ---

    test('registers exactly the three settings commands', () {
      final handlers = createDesktopSettingsCommandHandlers(
        settingsStore: _FakeSettingsStore(),
      );
      expect(handlers.keys, <String>[
        'get_desktop_settings',
        'patch_desktop_settings',
        'migrate_legacy_desktop_settings',
      ]);
    });

    test('the read handler ignores whatever args the bus hands it', () async {
      final store = _FakeSettingsStore();
      final handlers = createDesktopSettingsCommandHandlers(
        settingsStore: store,
      );

      expect(
        await handlers[getDesktopSettingsCommand]!(<String, Object?>{
          'ignored': true,
        }),
        defaultPaseoDesktopSettings,
      );
      expect(store.getCalls, 1);
      expect(store.patchCalls, isEmpty);
    });

    test('passes a missing payload through untouched', () async {
      final store = _FakeSettingsStore();
      final handlers = createDesktopSettingsCommandHandlers(
        settingsStore: store,
      );

      await handlers[patchDesktopSettingsCommand]!();
      await handlers[migrateLegacyDesktopSettingsCommand]!();

      // The store, not the handler, owns validation — so `null` reaches it.
      expect(store.patchCalls, <Object?>[null]);
      expect(store.migrateCalls, <Object?>[null]);
    });

    test('lets store failures propagate to the caller', () async {
      final store = _FakeSettingsStore()..failure = StateError('disk gone');
      final handlers = createDesktopSettingsCommandHandlers(
        settingsStore: store,
      );

      await expectLater(
        handlers[getDesktopSettingsCommand]!(),
        throwsA(isA<StateError>()),
      );
    });

    test('the settings value types compare by value and copy sanely', () {
      expect(
        defaultPaseoDesktopSettings,
        const PaseoDesktopSettings(
          releaseChannel: DesktopAppReleaseChannel.stable,
          daemon: PaseoDesktopDaemonSettings(
            manageBuiltInDaemon: true,
            keepRunningAfterQuit: true,
          ),
        ),
      );
      expect(
        defaultPaseoDesktopSettings.hashCode,
        const PaseoDesktopSettings(
          releaseChannel: DesktopAppReleaseChannel.stable,
          daemon: PaseoDesktopDaemonSettings(
            manageBuiltInDaemon: true,
            keepRunningAfterQuit: true,
          ),
        ).hashCode,
      );

      final betaChannel = defaultPaseoDesktopSettings.copyWith(
        releaseChannel: DesktopAppReleaseChannel.beta,
      );
      expect(betaChannel.releaseChannel, DesktopAppReleaseChannel.beta);
      expect(betaChannel.daemon, defaultPaseoDesktopSettings.daemon);
      expect(betaChannel, isNot(defaultPaseoDesktopSettings));
      expect(
        defaultPaseoDesktopSettings.copyWith(),
        defaultPaseoDesktopSettings,
      );

      final unmanaged = defaultPaseoDesktopSettings.daemon.copyWith(
        manageBuiltInDaemon: false,
      );
      expect(unmanaged.manageBuiltInDaemon, isFalse);
      expect(unmanaged.keepRunningAfterQuit, isTrue);
      expect(
        unmanaged.hashCode,
        isNot(defaultPaseoDesktopSettings.daemon.hashCode),
      );
      expect(
        defaultPaseoDesktopSettings.toString(),
        contains('releaseChannel:'),
      );
      expect(unmanaged.toString(), contains('manageBuiltInDaemon: false'));
    });
  });
}
