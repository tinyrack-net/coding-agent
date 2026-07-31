// Ports of the frozen Paseo 0.2.0 Vitest suites for the desktop browser /
// attachment / skills cluster — `browser-automation/trusted-input.test.ts`,
// `browser-webviews/window-open.test.ts`, `browser-keyboard/policy.test.ts`,
// `features/attachments.test.ts` and `integrations/skills/operations.test.ts` —
// plus the edge cases those suites leave unpinned.
//
// The unpinned cases worth naming, because each is a behaviour a reader would
// otherwise have to guess at:
//
//  * `dispatchTrustedKey` for a zero-length key, a non-BMP key (UTF-16 length 2,
//    so no `char` event on either side), every arrow alias, and the mouse /
//    drag / scroll / text helpers the upstream suite never touches at all.
//  * The keyboard policy's absent-versus-explicit-null distinction, which
//    upstream gets from `=== undefined` and this port reproduces with
//    `containsKey`, and its rejection of the *opposite* literal
//    (`codeFallback: false`, `editable: true`, `repeat: true`).
//  * Every rejection path and the exact validation ordering of the attachment
//    rules, the containment check against traversal / sibling-prefix / bare-
//    directory / case-differing paths under both POSIX and Win32 path
//    semantics, Node's lenient base64 decoder, Node's `path.parse().name`
//    carve-outs, and JS's `ToUint8` coercion. Ground truth for the last three
//    was captured by running the same inputs through Node.
//  * `window-open.test.ts` is re-run here against the pre-existing port in
//    `core/desktop/desktop_browser_window_open.dart` rather than being taken on
//    trust, together with the URL-allowlist cases upstream never wrote.
import 'dart:convert';
import 'dart:typed_data';

import 'package:coding_agent_app/desktop/paseo_desktop_browser.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records every CDP command the trusted-input helpers emit, in order.
final class _CdpRecorder {
  final List<String> commands = <String>[];
  final List<Map<String, Object?>?> params = <Map<String, Object?>?>[];

  Future<Object?> send(String command, [Map<String, Object?>? params]) async {
    commands.add(command);
    this.params.add(params);
    return null;
  }
}

/// A path-keyed in-memory filesystem shared by the attachment and skills
/// suites. Paths are compared verbatim, so the tests must use whichever
/// separator the [DesktopBrowserPathOps] under test emits.
final class _MemoryFileSystem
    implements DesktopAttachmentFileSystem, PaseoSkillsFileSystem {
  _MemoryFileSystem({this.separator = '/'});

  final String separator;
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Set<String> directories = <String>{};

  /// Every mutating call, in order, so ordering-sensitive rules can be pinned.
  final List<String> log = <String>[];

  void seedText(String path, String content) {
    files[path] = Uint8List.fromList(utf8.encode(content));
    _addAncestors(path);
  }

  void seedDirectory(String path) {
    directories.add(path);
    _addAncestors('$path$separator.');
  }

  String textAt(String path) => utf8.decode(files[path]!);

  bool exists(String path) => files.containsKey(path) || isDirectorySync(path);

  bool isDirectorySync(String path) =>
      directories.contains(path) ||
      files.keys.any((candidate) => candidate.startsWith('$path$separator'));

  List<String> listRecursiveSync(String rootDir) {
    final prefix = '$rootDir$separator';
    return <String>[
      for (final path in files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ]..sort();
  }

  void removeTreeSync(String rootDir) {
    files.removeWhere(
      (path, _) => path == rootDir || path.startsWith('$rootDir$separator'),
    );
    directories.removeWhere(
      (path) => path == rootDir || path.startsWith('$rootDir$separator'),
    );
  }

  @override
  Future<void> createDirectory(String path) async {
    log.add('mkdir $path');
    seedDirectory(path);
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    log.add('write $path');
    files[path] = bytes;
    _addAncestors(path);
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final bytes = files[path];
    if (bytes == null) throw StateError('ENOENT: $path');
    return bytes;
  }

  @override
  Future<void> copyFile(String source, String destination) async {
    log.add('copy $source -> $destination');
    final bytes = files[source];
    if (bytes == null) throw StateError('ENOENT: $source');
    files[destination] = bytes;
    _addAncestors(destination);
  }

  @override
  Future<int> fileByteSize(String path) async {
    final bytes = files[path];
    if (bytes == null) throw StateError('ENOENT: $path');
    return bytes.length;
  }

  @override
  Future<void> removeFile(String path) async {
    log.add('rm $path');
    files.remove(path);
  }

  @override
  Future<bool> isDirectory(String path) async => isDirectorySync(path);

  @override
  Future<List<DesktopDirectoryEntry>> readDirectory(String path) async {
    final prefix = '$path$separator';
    final fileNames = <String>{};
    final dirNames = <String>{};
    for (final candidate in files.keys) {
      if (!candidate.startsWith(prefix)) continue;
      final rest = candidate.substring(prefix.length);
      final index = rest.indexOf(separator);
      if (index == -1) {
        fileNames.add(rest);
      } else {
        dirNames.add(rest.substring(0, index));
      }
    }
    for (final candidate in directories) {
      if (!candidate.startsWith(prefix)) continue;
      final rest = candidate.substring(prefix.length);
      final index = rest.indexOf(separator);
      dirNames.add(index == -1 ? rest : rest.substring(0, index));
    }
    dirNames.removeWhere(fileNames.contains);
    final names = <String>[...fileNames, ...dirNames]..sort();
    return <DesktopDirectoryEntry>[
      for (final name in names)
        DesktopDirectoryEntry(
          name: name,
          isFile: fileNames.contains(name),
          isDirectory: dirNames.contains(name),
        ),
    ];
  }

  void _addAncestors(String path) {
    var index = path.lastIndexOf(separator);
    while (index > 0) {
      directories.add(path.substring(0, index));
      index = path.lastIndexOf(separator, index - 1);
    }
  }
}

/// Stands in for `skills/sync.ts`: mirrors bundle files into all three targets
/// without touching files the user added, and deletes a skill subtree outright.
final class _FakeSkillsSync implements PaseoSkillsSyncGateway {
  _FakeSkillsSync(this.fs);

  final _MemoryFileSystem fs;
  final List<List<String>> syncCalls = <List<String>>[];
  final List<String> removedSkills = <String>[];

  @override
  Future<void> syncSkills({
    required String sourceDir,
    required String agentsDir,
    required String claudeDir,
    required String codexDir,
    required List<String> skillNames,
  }) async {
    syncCalls.add(List<String>.of(skillNames));
    for (final name in skillNames) {
      final skillSource = '$sourceDir/$name';
      if (!fs.isDirectorySync(skillSource)) continue;
      for (final targetDir in <String>[agentsDir, claudeDir, codexDir]) {
        for (final relative in fs.listRecursiveSync(skillSource)) {
          fs.files['$targetDir/$name/$relative'] =
              fs.files['$skillSource/$relative']!;
        }
        fs.seedDirectory('$targetDir/$name');
      }
    }
  }

  @override
  Future<void> removeSkill(
    String skillName, {
    required String agentsDir,
    required String claudeDir,
    required String codexDir,
  }) async {
    removedSkills.add(skillName);
    for (final targetDir in <String>[agentsDir, claudeDir, codexDir]) {
      fs.removeTreeSync('$targetDir/$skillName');
    }
  }
}

/// A content-addressed "digest" that is injective, which is all the drift diff
/// needs — it only ever compares digests for equality.
String _fakeHash(Uint8List bytes) => 'sha:${base64Encode(bytes)}';

final class _SkillsSandbox {
  _SkillsSandbox()
    : fs = _MemoryFileSystem(),
      targets = const PaseoSkillTargets(
        sourceDir: '/root/bundle',
        agentsDir: '/root/home/.agents/skills',
        claudeDir: '/root/home/.claude/skills',
        codexDir: '/root/home/.codex/skills',
      ) {
    sync = _FakeSkillsSync(fs);
    operations = PaseoSkillsOperations(
      fileSystem: fs,
      syncGateway: sync,
      hashContent: _fakeHash,
    );
    fs.seedDirectory(targets.sourceDir);
  }

  final _MemoryFileSystem fs;
  final PaseoSkillTargets targets;
  late final _FakeSkillsSync sync;
  late final PaseoSkillsOperations operations;

  void writeBundleSkill(String name, Map<String, String> files) {
    files.forEach((relative, content) {
      fs.seedText('${targets.sourceDir}/$name/$relative', content);
    });
  }

  void writeCurrentBundle() {
    writeBundleSkill('paseo', <String, String>{'SKILL.md': 'paseo-v1'});
    writeBundleSkill('paseo-loop', <String, String>{'SKILL.md': 'loop-v1'});
  }

  void writeOnDiskSkill(
    String targetDir,
    String name,
    Map<String, String> files,
  ) {
    files.forEach((relative, content) {
      fs.seedText('$targetDir/$name/$relative', content);
    });
  }

  void writeOnDiskSkillToAllTargets(String name, Map<String, String> files) {
    for (final dir in targets.installDirs) {
      writeOnDiskSkill(dir, name, files);
    }
  }
}

// ---------------------------------------------------------------------------
// browser-automation/trusted-input.ts
// ---------------------------------------------------------------------------

void main() {
  group('trusted browser keyboard input', () {
    // Upstream `test.each` table.
    for (final row in <({String key, String keyCode, List<String> types})>[
      (key: 'a', keyCode: 'a', types: <String>['keyDown', 'char', 'keyUp']),
      (key: 'Z', keyCode: 'Z', types: <String>['keyDown', 'char', 'keyUp']),
      (key: 'ArrowDown', keyCode: 'Down', types: <String>['keyDown', 'keyUp']),
    ]) {
      test(
        'sends ${row.key} as Electron key code ${row.keyCode} with unhandled '
        'redispatch disabled',
        () {
          final events = <IsolatedKeyboardInputEvent>[];

          dispatchTrustedKey(events.add, row.key);

          expect(
            events.map((event) => event.type.wireName).toList(),
            row.types,
          );
          for (final event in events) {
            expect(event.skipIfUnhandled, isTrue);
            if (event.type != IsolatedKeyboardInputEventType.char) {
              expect(event.keyCode, row.keyCode);
            }
          }
        },
      );
    }

    test('inserts a named Space keypress', () {
      final events = <IsolatedKeyboardInputEvent>[];

      dispatchTrustedKey(events.add, 'Space');

      expect(events, <IsolatedKeyboardInputEvent>[
        const IsolatedKeyboardInputEvent(
          type: IsolatedKeyboardInputEventType.keyDown,
          keyCode: 'Space',
        ),
        const IsolatedKeyboardInputEvent(
          type: IsolatedKeyboardInputEventType.char,
          keyCode: ' ',
        ),
        const IsolatedKeyboardInputEvent(
          type: IsolatedKeyboardInputEventType.keyUp,
          keyCode: 'Space',
        ),
      ]);
    });

    test('carries the character itself on the char event for a letter', () {
      final events = <IsolatedKeyboardInputEvent>[];

      dispatchTrustedKey(events.add, 'a');

      expect(events[1].type, IsolatedKeyboardInputEventType.char);
      expect(events[1].keyCode, 'a');
    });

    test('aliases every arrow key to its Electron name', () {
      final aliases = <String, String>{
        'ArrowUp': 'Up',
        'ArrowDown': 'Down',
        'ArrowLeft': 'Left',
        'ArrowRight': 'Right',
      };
      aliases.forEach((key, expected) {
        final events = <IsolatedKeyboardInputEvent>[];
        dispatchTrustedKey(events.add, key);
        expect(events.map((event) => event.keyCode).toList(), <String>[
          expected,
          expected,
        ]);
      });
    });

    test('passes an unaliased named key through untouched', () {
      final events = <IsolatedKeyboardInputEvent>[];

      dispatchTrustedKey(events.add, 'Enter');

      expect(events.length, 2);
      expect(events.every((event) => event.keyCode == 'Enter'), isTrue);
    });

    test('emits no char event for an empty key', () {
      final events = <IsolatedKeyboardInputEvent>[];

      dispatchTrustedKey(events.add, '');

      expect(events.map((event) => event.type.wireName).toList(), <String>[
        'keyDown',
        'keyUp',
      ]);
      expect(events.every((event) => event.keyCode.isEmpty), isTrue);
    });

    test('emits no char event for a non-BMP key', () {
      // Deliberate parity with upstream: `"\u{1F600}".length === 2` in JS and
      // in Dart, so neither side types an emoji through this path.
      final events = <IsolatedKeyboardInputEvent>[];

      dispatchTrustedKey(events.add, '\u{1F600}');

      expect(events.map((event) => event.type.wireName).toList(), <String>[
        'keyDown',
        'keyUp',
      ]);
    });

    test('emits a char event for a single-code-unit accented key', () {
      final events = <IsolatedKeyboardInputEvent>[];

      dispatchTrustedKey(events.add, 'é');

      expect(events.length, 3);
      expect(events[1].keyCode, 'é');
    });
  });

  group('trusted browser pointer input', () {
    test('moves before pressing so hover-revealed targets exist', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedClick(
        recorder.send,
        const DesktopBrowserInputPoint(x: 12.5, y: 30),
      );

      expect(
        recorder.commands,
        List<String>.filled(3, 'Input.dispatchMouseEvent'),
      );
      expect(recorder.params, <Map<String, Object?>>[
        <String, Object?>{
          'type': 'mouseMoved',
          'x': 12.5,
          'y': 30.0,
          'button': 'none',
          'modifiers': 0,
        },
        <String, Object?>{
          'type': 'mousePressed',
          'x': 12.5,
          'y': 30.0,
          'button': 'left',
          'buttons': 1,
          'clickCount': 1,
          'modifiers': 0,
        },
        <String, Object?>{
          'type': 'mouseReleased',
          'x': 12.5,
          'y': 30.0,
          'button': 'left',
          'buttons': 0,
          'clickCount': 1,
          'modifiers': 0,
        },
      ]);
    });

    test('sends clickCount 1 then 2 for a double click', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedClick(
        recorder.send,
        const DesktopBrowserInputPoint(x: 1, y: 2),
        const DesktopBrowserClickOptions(doubleClick: true),
      );

      expect(recorder.params.length, 5);
      expect(
        recorder.params.map((params) => params!['clickCount']).toList(),
        <Object?>[null, 1, 1, 2, 2],
      );
    });

    test('uses the right and middle button masks', () async {
      for (final row
          in <({DesktopBrowserMouseButton button, String name, int mask})>[
            (button: DesktopBrowserMouseButton.right, name: 'right', mask: 2),
            (button: DesktopBrowserMouseButton.middle, name: 'middle', mask: 4),
          ]) {
        final recorder = _CdpRecorder();
        await dispatchTrustedClick(
          recorder.send,
          const DesktopBrowserInputPoint(x: 0, y: 0),
          DesktopBrowserClickOptions(button: row.button),
        );
        expect(recorder.params[1]!['button'], row.name);
        expect(recorder.params[1]!['buttons'], row.mask);
        // Release always reports no buttons held.
        expect(recorder.params[2]!['buttons'], 0);
      }
    });

    test('ors the modifier masks together', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedClick(
        recorder.send,
        const DesktopBrowserInputPoint(x: 0, y: 0),
        const DesktopBrowserClickOptions(
          modifiers: <DesktopBrowserInputModifier>[
            DesktopBrowserInputModifier.alt,
            DesktopBrowserInputModifier.control,
            DesktopBrowserInputModifier.meta,
            DesktopBrowserInputModifier.shift,
          ],
        ),
      );

      expect(
        recorder.params.map((params) => params!['modifiers']).toList(),
        <Object?>[15, 15, 15],
      );
    });

    test('ignores a repeated modifier rather than doubling its bit', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedClick(
        recorder.send,
        const DesktopBrowserInputPoint(x: 0, y: 0),
        const DesktopBrowserClickOptions(
          modifiers: <DesktopBrowserInputModifier>[
            DesktopBrowserInputModifier.shift,
            DesktopBrowserInputModifier.shift,
          ],
        ),
      );

      expect(recorder.params.first!['modifiers'], 8);
    });

    test('hovers without a modifiers field at all', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedHover(
        recorder.send,
        const DesktopBrowserInputPoint(x: 4, y: 8),
      );

      expect(recorder.params, <Map<String, Object?>>[
        <String, Object?>{
          'type': 'mouseMoved',
          'x': 4.0,
          'y': 8.0,
          'button': 'none',
        },
      ]);
      expect(recorder.params.first!.containsKey('modifiers'), isFalse);
    });

    test('drags through the midpoint so drag libraries commit', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedDrag(
        recorder.send,
        const DesktopBrowserInputPoint(x: 0, y: 10),
        const DesktopBrowserInputPoint(x: 100, y: 30),
      );

      expect(
        recorder.params
            .map(
              (params) => <Object?>[
                params!['type'],
                params['x'],
                params['y'],
                params['buttons'],
              ],
            )
            .toList(),
        <List<Object?>>[
          <Object?>['mouseMoved', 0.0, 10.0, null],
          <Object?>['mousePressed', 0.0, 10.0, 1],
          <Object?>['mouseMoved', 50.0, 20.0, 1],
          <Object?>['mouseMoved', 100.0, 30.0, 1],
          <Object?>['mouseReleased', 100.0, 30.0, 0],
        ],
      );
    });

    test('scrolls with signed deltas and no button field', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedScroll(
        recorder.send,
        const DesktopBrowserInputPoint(x: 5, y: 6),
        -20,
        120,
      );

      expect(recorder.params, <Map<String, Object?>>[
        <String, Object?>{
          'type': 'mouseWheel',
          'x': 5.0,
          'y': 6.0,
          'deltaX': -20.0,
          'deltaY': 120.0,
        },
      ]);
    });

    test('inserts text as one atomic command', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedText(recorder.send, 'hello');

      expect(recorder.commands, <String>['Input.insertText']);
      expect(recorder.params, <Map<String, Object?>>[
        <String, Object?>{'text': 'hello'},
      ]);
    });

    test('sends nothing for empty text', () async {
      final recorder = _CdpRecorder();

      await dispatchTrustedText(recorder.send, '');

      expect(recorder.commands, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // browser-keyboard/policy.ts
  // -------------------------------------------------------------------------

  group('browser keyboard policy', () {
    BrowserReservedShortcutInput reserved({
      String type = 'keyDown',
      String key = 't',
      bool meta = false,
      bool control = false,
      bool alt = false,
      bool shift = false,
    }) => BrowserReservedShortcutInput(
      alt: alt,
      control: control,
      key: key,
      meta: meta,
      shift: shift,
      type: type,
    );

    test('classifies shell-owned browser shortcuts for the current platform '
        'modifier', () {
      final macInputs = <BrowserReservedShortcutInput>[
        reserved(key: 't', meta: true),
        reserved(key: 'l', meta: true),
        reserved(key: 'r', meta: true),
        reserved(key: 'r', meta: true, shift: true),
      ];
      final nonMacInputs = <BrowserReservedShortcutInput>[
        reserved(key: 't', control: true),
        reserved(key: 'l', control: true),
        reserved(key: 'r', control: true),
        reserved(key: 'r', control: true, shift: true),
      ];

      expect(
        macInputs
            .map((input) => classifyBrowserReservedShortcut(input, isMac: true))
            .toList(),
        <BrowserReservedShortcut?>[
          null,
          BrowserReservedShortcut.focusUrl,
          BrowserReservedShortcut.reload,
          BrowserReservedShortcut.forceReload,
        ],
      );
      expect(
        nonMacInputs
            .map(
              (input) => classifyBrowserReservedShortcut(input, isMac: false),
            )
            .toList(),
        <BrowserReservedShortcut?>[
          null,
          BrowserReservedShortcut.focusUrl,
          BrowserReservedShortcut.reload,
          BrowserReservedShortcut.forceReload,
        ],
      );
    });

    test('rejects the wrong or ambiguous command modifier for reserved '
        'shortcuts', () {
      expect(
        classifyBrowserReservedShortcut(reserved(control: true), isMac: true),
        isNull,
      );
      expect(
        classifyBrowserReservedShortcut(reserved(meta: true), isMac: false),
        isNull,
      );
      expect(
        classifyBrowserReservedShortcut(
          reserved(meta: true, control: true),
          isMac: true,
        ),
        isNull,
      );
      expect(
        classifyBrowserReservedShortcut(
          reserved(meta: true, control: true),
          isMac: false,
        ),
        isNull,
      );
      expect(
        classifyBrowserReservedShortcut(
          reserved(key: 'r', meta: true, alt: true),
          isMac: true,
        ),
        isNull,
      );
      expect(
        classifyBrowserReservedShortcut(
          reserved(meta: true, shift: true),
          isMac: true,
        ),
        isNull,
      );
    });

    test('ignores anything that is not a keyDown', () {
      expect(
        classifyBrowserReservedShortcut(
          reserved(key: 'r', type: 'keyUp', meta: true),
          isMac: true,
        ),
        isNull,
      );
      expect(
        classifyBrowserReservedShortcut(
          reserved(key: 'r', type: 'char', meta: true),
          isMac: true,
        ),
        isNull,
      );
    });

    test('matches the reserved key case-insensitively', () {
      expect(
        classifyBrowserReservedShortcut(
          reserved(key: 'R', meta: true, shift: true),
          isMac: true,
        ),
        BrowserReservedShortcut.forceReload,
      );
      expect(
        classifyBrowserReservedShortcut(
          reserved(key: 'L', meta: true),
          isMac: true,
        ),
        BrowserReservedShortcut.focusUrl,
      );
    });

    test('never treats Shift+L as focus-url', () {
      expect(
        classifyBrowserReservedShortcut(
          reserved(key: 'l', meta: true, shift: true),
          isMac: true,
        ),
        isNull,
      );
    });

    test('accepts only complete modifier prefixes from the host renderer', () {
      expect(
        parseBrowserKeyboardPolicy(<String, Object?>{
          'menuPrefixes': <Object?>[
            <String, Object?>{
              'code': 'KeyB',
              'control': true,
              'meta': false,
              'alt': false,
              'repeat': false,
              'shift': false,
            },
          ],
          'prefixes': <Object?>[
            <String, Object?>{
              'code': 'KeyB',
              'control': true,
              'meta': false,
              'alt': false,
              'repeat': false,
              'shift': false,
            },
          ],
        }),
        const BrowserKeyboardPolicy(
          menuPrefixes: <BrowserShortcutPrefix>[
            BrowserShortcutPrefix(
              alt: false,
              code: 'KeyB',
              control: true,
              meta: false,
              shift: false,
              excludesRepeat: true,
            ),
          ],
          prefixes: <BrowserShortcutPrefix>[
            BrowserShortcutPrefix(
              alt: false,
              code: 'KeyB',
              control: true,
              meta: false,
              shift: false,
              excludesRepeat: true,
            ),
          ],
        ),
      );
      expect(
        parseBrowserKeyboardPolicy(<String, Object?>{
          'prefixes': <Object?>[
            <String, Object?>{'code': 'KeyB', 'control': true},
          ],
        }),
        isNull,
      );
    });

    test('rejects a false code fallback instead of treating it as absent', () {
      expect(
        parseBrowserKeyboardPolicy(<String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': <Object?>[
            <String, Object?>{
              'alt': false,
              'code': 'KeyB',
              'codeFallback': false,
              'control': true,
              'meta': false,
              'shift': false,
            },
          ],
        }),
        isNull,
      );
    });

    test('rejects a true repeat flag instead of treating it as absent', () {
      expect(
        parseBrowserKeyboardPolicy(<String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': <Object?>[
            <String, Object?>{
              'alt': false,
              'code': 'KeyB',
              'control': true,
              'meta': false,
              'repeat': true,
              'shift': false,
            },
          ],
        }),
        isNull,
      );
    });

    test('rejects an optional field present but null', () {
      // Upstream distinguishes `undefined` from `null`: `{key: null}` fails
      // both the `=== undefined` and the `typeof === "string"` checks.
      for (final field in <String>[
        'key',
        'shiftedKey',
        'codeFallback',
        'editable',
        'repeat',
      ]) {
        expect(
          parseBrowserKeyboardPolicy(<String, Object?>{
            'menuPrefixes': <Object?>[],
            'prefixes': <Object?>[
              <String, Object?>{
                'alt': false,
                'code': 'KeyB',
                'control': true,
                'meta': false,
                'shift': false,
                field: null,
              },
            ],
          }),
          isNull,
          reason: 'explicit null for $field must be rejected',
        );
      }
    });

    test('preserves editable exclusions and rejects permissive values', () {
      final policy = parseBrowserKeyboardPolicy(<String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[
          <String, Object?>{
            'alt': false,
            'code': 'ArrowLeft',
            'control': false,
            'editable': false,
            'meta': true,
            'shift': true,
          },
        ],
      });
      expect(
        policy,
        const BrowserKeyboardPolicy(
          menuPrefixes: <BrowserShortcutPrefix>[],
          prefixes: <BrowserShortcutPrefix>[
            BrowserShortcutPrefix(
              alt: false,
              code: 'ArrowLeft',
              control: false,
              excludesEditable: true,
              meta: true,
              shift: true,
            ),
          ],
        ),
      );
      expect(
        parseBrowserKeyboardPolicy(<String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': <Object?>[
            <String, Object?>{
              'alt': false,
              'code': 'ArrowLeft',
              'control': false,
              'editable': true,
              'meta': true,
              'shift': true,
            },
          ],
        }),
        isNull,
      );

      BrowserShortcutMatchInput input({bool? editable}) =>
          BrowserShortcutMatchInput(
            alt: false,
            code: 'ArrowLeft',
            control: false,
            key: 'ArrowLeft',
            meta: true,
            repeat: false,
            shift: true,
            editable: editable,
          );
      expect(
        matchesBrowserShortcutPolicy(policy!, input(editable: false)),
        isTrue,
      );
      expect(
        matchesBrowserShortcutPolicy(policy, input(editable: true)),
        isFalse,
      );
      // An unknown editable state is treated as not-editable, matching
      // upstream's `input.editable === true` test.
      expect(matchesBrowserShortcutPolicy(policy, input()), isTrue);
    });

    test('keeps browser identities exact', () {
      final input = parseBrowserShortcutInput(<String, Object?>{
        'alt': false,
        'browserId': ' browser-1 ',
        'code': 'KeyB',
        'control': true,
        'key': 'b',
        'meta': false,
        'shift': false,
      });

      expect(input, isNotNull);
      expect(input!.browserId, ' browser-1 ');
      expect(input.repeat, isFalse);
    });

    test('rejects a shortcut input with an empty or missing browser id', () {
      Map<String, Object?> base() => <String, Object?>{
        'alt': false,
        'browserId': 'browser-1',
        'code': 'KeyB',
        'control': true,
        'key': 'b',
        'meta': false,
        'shift': false,
      };

      expect(parseBrowserShortcutInput(base()), isNotNull);
      expect(parseBrowserShortcutInput(base()..['browserId'] = ''), isNull);
      expect(parseBrowserShortcutInput(base()..remove('browserId')), isNull);
      expect(parseBrowserShortcutInput(base()..['alt'] = 'no'), isNull);
      expect(parseBrowserShortcutInput(base()..['code'] = 3), isNull);
      expect(parseBrowserShortcutInput(<Object?>[]), isNull);
      expect(parseBrowserShortcutInput(null), isNull);
      expect(parseBrowserShortcutInput('policy'), isNull);
    });

    test('treats a non-boolean repeat as not a repeat', () {
      final input = parseBrowserShortcutInput(<String, Object?>{
        'alt': false,
        'browserId': 'browser-1',
        'code': 'KeyB',
        'control': true,
        'key': 'b',
        'meta': false,
        'repeat': 'yes',
        'shift': false,
      });

      expect(input!.repeat, isFalse);
    });

    test('rejects a policy that is not an object, or whose prefixes are not '
        'a list', () {
      expect(parseBrowserKeyboardPolicy(null), isNull);
      expect(parseBrowserKeyboardPolicy(<Object?>[]), isNull);
      expect(parseBrowserKeyboardPolicy('prefixes'), isNull);
      expect(
        parseBrowserKeyboardPolicy(<String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': 'KeyB',
        }),
        isNull,
      );
    });

    test('rejects the whole policy when a single prefix is malformed', () {
      expect(
        parseBrowserKeyboardPolicy(<String, Object?>{
          'menuPrefixes': <Object?>[],
          'prefixes': <Object?>[
            <String, Object?>{
              'alt': false,
              'code': 'KeyB',
              'control': true,
              'meta': false,
              'shift': false,
            },
            <String, Object?>{'code': ''},
          ],
        }),
        isNull,
      );
    });

    test('lowercases key and shiftedKey while parsing', () {
      final policy = parseBrowserKeyboardPolicy(<String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[
          <String, Object?>{
            'alt': false,
            'code': 'Digit1',
            'control': true,
            'key': 'B',
            'meta': false,
            'shift': false,
            'shiftedKey': 'EXCLAM',
          },
        ],
      });

      expect(policy!.prefixes.single.key, 'b');
      expect(policy.prefixes.single.shiftedKey, 'exclam');
    });

    test('matches digit shortcuts for the top row and numeric keypad', () {
      final policy = parseBrowserKeyboardPolicy(<String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[
          <String, Object?>{
            'alt': false,
            'code': 'Digit',
            'control': true,
            'meta': false,
            'repeat': false,
            'shift': false,
          },
        ],
      });
      expect(policy, isNotNull);

      BrowserShortcutMatchInput digit(String code, String key) =>
          BrowserShortcutMatchInput(
            alt: false,
            code: code,
            control: true,
            key: key,
            meta: false,
            repeat: false,
            shift: false,
          );

      expect(
        matchesBrowserShortcutPolicy(policy!, digit('Digit3', '3')),
        isTrue,
      );
      expect(
        matchesBrowserShortcutPolicy(policy, digit('Numpad3', '3')),
        isTrue,
      );
      expect(
        matchesBrowserShortcutPolicy(policy, digit('Digit0', '0')),
        isFalse,
      );
      expect(
        matchesBrowserShortcutPolicy(policy, digit('Numpad0', '0')),
        isFalse,
      );
      expect(
        matchesBrowserShortcutPolicy(policy, digit('KeyDigit3', '3')),
        isFalse,
      );
    });

    test('suppresses a repeat-excluded prefix on auto-repeat only', () {
      final policy = parseBrowserKeyboardPolicy(<String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[
          <String, Object?>{
            'alt': false,
            'code': 'KeyB',
            'control': true,
            'meta': false,
            'repeat': false,
            'shift': false,
          },
        ],
      });

      BrowserShortcutMatchInput input({required bool repeat}) =>
          BrowserShortcutMatchInput(
            alt: false,
            code: 'KeyB',
            control: true,
            key: 'b',
            meta: false,
            repeat: repeat,
            shift: false,
          );

      expect(
        matchesBrowserShortcutPolicy(policy!, input(repeat: false)),
        isTrue,
      );
      expect(
        matchesBrowserShortcutPolicy(policy, input(repeat: true)),
        isFalse,
      );
    });

    test('falls back to the physical code for an Alt prefix, but not for a '
        'plain one', () {
      BrowserKeyboardPolicy policyFor({
        required bool alt,
        bool codeFallback = false,
      }) => parseBrowserKeyboardPolicy(<String, Object?>{
        'menuPrefixes': <Object?>[],
        'prefixes': <Object?>[
          <String, Object?>{
            'alt': alt,
            'code': 'KeyL',
            'control': true,
            'key': 'l',
            'meta': false,
            'shift': false,
            if (codeFallback) 'codeFallback': true,
          },
        ],
      })!;

      // macOS rewrites `key` under Alt; only the code still identifies the key.
      final altered = BrowserShortcutMatchInput(
        alt: true,
        code: 'KeyL',
        control: true,
        key: '¬',
        meta: false,
        repeat: false,
        shift: false,
      );
      expect(
        matchesBrowserShortcutPolicy(policyFor(alt: true), altered),
        isTrue,
      );

      final mismatchedKey = BrowserShortcutMatchInput(
        alt: false,
        code: 'KeyL',
        control: true,
        key: 'ל',
        meta: false,
        repeat: false,
        shift: false,
      );
      expect(
        matchesBrowserShortcutPolicy(policyFor(alt: false), mismatchedKey),
        isFalse,
      );
      expect(
        matchesBrowserShortcutPolicy(
          policyFor(alt: false, codeFallback: true),
          mismatchedKey,
        ),
        isTrue,
      );
    });

    test('accepts the shifted key only when the prefix itself wants shift', () {
      BrowserKeyboardPolicy policyFor({required bool shift}) =>
          parseBrowserKeyboardPolicy(<String, Object?>{
            'menuPrefixes': <Object?>[],
            'prefixes': <Object?>[
              <String, Object?>{
                'alt': false,
                'code': 'Digit1',
                'control': true,
                'key': '1',
                'meta': false,
                'shift': shift,
                'shiftedKey': '!',
              },
            ],
          })!;

      BrowserShortcutMatchInput input({required bool shift}) =>
          BrowserShortcutMatchInput(
            alt: false,
            code: 'Digit1',
            control: true,
            key: '!',
            meta: false,
            repeat: false,
            shift: shift,
          );

      expect(
        matchesBrowserShortcutPolicy(
          policyFor(shift: true),
          input(shift: true),
        ),
        isTrue,
      );
      // Without shift the prefix does not match the shifted key, and the code
      // fallback is not enabled, so nothing claims it.
      expect(
        matchesBrowserShortcutPolicy(
          policyFor(shift: false),
          input(shift: false),
        ),
        isFalse,
      );
    });

    test('matchesBrowserShortcutPrefixes works on the menu list too', () {
      final policy = parseBrowserKeyboardPolicy(<String, Object?>{
        'menuPrefixes': <Object?>[
          <String, Object?>{
            'alt': false,
            'code': 'KeyN',
            'control': true,
            'meta': false,
            'shift': false,
          },
        ],
        'prefixes': <Object?>[],
      })!;

      const input = BrowserShortcutMatchInput(
        alt: false,
        code: 'KeyN',
        control: true,
        key: 'n',
        meta: false,
        repeat: false,
        shift: false,
      );

      expect(
        matchesBrowserShortcutPrefixes(policy.menuPrefixes, input),
        isTrue,
      );
      expect(matchesBrowserShortcutPolicy(policy, input), isFalse);
      expect(
        matchesBrowserShortcutPrefixes(<BrowserShortcutPrefix>[], input),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // node:path subset
  // -------------------------------------------------------------------------

  group('node path subset', () {
    test('reproduces path.parse().name including Node carve-outs', () {
      const ops = DesktopBrowserPathOps.posix;
      final cases = <String, String>{
        'att_1.md': 'att_1',
        '.bashrc': '.bashrc',
        '..': '..',
        'a.': 'a',
        'noext': 'noext',
        'a.b.c': 'a.b',
        '...': '..',
        '.': '.',
        'a.tar.gz': 'a.tar',
        '': '',
        '.x.': '.x',
      };
      cases.forEach((input, expected) {
        expect(ops.fileStem(input), expected, reason: 'stem of "$input"');
      });
    });

    test('collapses . and .. and never climbs above a root', () {
      const ops = DesktopBrowserPathOps.posix;
      expect(ops.resolve('/cwd', '/home/a/../b'), '/home/b');
      expect(ops.resolve('/cwd', '/home/./a/'), '/home/a');
      expect(ops.resolve('/cwd', 'rel/../other'), '/cwd/other');
      expect(ops.resolve('/cwd', '/../../etc/passwd'), '/etc/passwd');
    });

    test('normalises Win32 paths onto backslashes', () {
      const ops = DesktopBrowserPathOps.windows;
      expect(ops.resolve(r'C:\cwd', 'C:/a/b/../c'), r'C:\a\c');
      expect(ops.resolve(r'C:\cwd', r'sub\file.md'), r'C:\cwd\sub\file.md');
      expect(ops.separator, r'\');
      expect(ops.toPosix(r'a\b\c'), 'a/b/c');
    });

    test('joins and takes basenames the way node:path does', () {
      const ops = DesktopBrowserPathOps.posix;
      expect(ops.join(<String>['/a', 'b', 'c.md']), '/a/b/c.md');
      expect(ops.join(<String>['', '']), '.');
      expect(ops.basename('/a/b/c.md'), 'c.md');
      expect(ops.basename('/a/b/'), 'b');
      expect(ops.basename('/'), '');
    });
  });

  // -------------------------------------------------------------------------
  // features/attachments.ts
  // -------------------------------------------------------------------------

  group('desktop attachment files', () {
    late _MemoryFileSystem fs;
    late DesktopManagedAttachments attachments;
    const paseoHome = '/home/paseo';
    const managedDir = '/home/paseo/desktop-attachments';

    setUp(() {
      fs = _MemoryFileSystem();
      attachments = DesktopManagedAttachments(
        fileSystem: fs,
        paseoHome: paseoHome,
        workingDirectory: '/cwd',
      );
    });

    test('accepts dot-prefixed picker extensions for managed copies', () async {
      fs.seedText('$paseoHome/report.md', '# Report\n');

      final result = await attachments.copyAttachmentFileToManagedStorage(
        attachmentId: 'att_markdown',
        sourcePath: '$paseoHome/report.md',
        extension: '.md',
      );

      expect(
        result,
        const DesktopManagedAttachmentFileResult(
          path: '$managedDir/att_markdown.md',
          byteSize: 9,
        ),
      );
      expect(fs.textAt(result.path), '# Report\n');
    });

    test('normalizes legacy bare extensions for managed copies', () async {
      fs.seedText('$paseoHome/report.md', '# Report\n');

      final result = await attachments.copyAttachmentFileToManagedStorage(
        attachmentId: 'att_markdown_legacy',
        sourcePath: '$paseoHome/report.md',
        extension: 'md',
      );

      expect(
        result,
        const DesktopManagedAttachmentFileResult(
          path: '$managedDir/att_markdown_legacy.md',
          byteSize: 9,
        ),
      );
      expect(fs.textAt(result.path), '# Report\n');
    });

    test('lowercases the extension and falls back to .bin', () async {
      expect(DesktopManagedAttachments.normalizeExtension('.MD'), '.md');
      expect(DesktopManagedAttachments.normalizeExtension('  PNG '), '.png');
      // Surrounding whitespace is trimmed before the pattern is applied, so a
      // padded extension is normalised rather than refused.
      expect(DesktopManagedAttachments.normalizeExtension('.md '), '.md');
      expect(DesktopManagedAttachments.normalizeExtension(null), '.bin');
      expect(DesktopManagedAttachments.normalizeExtension(''), '.bin');
    });

    test('rejects extensions that could smuggle a second segment', () {
      for (final bad in <Object?>[
        '.tar.gz',
        '/etc',
        '.',
        '   ',
        '.abcdefghijklmnopq',
        '..',
        '.a b',
      ]) {
        expect(
          () => DesktopManagedAttachments.normalizeExtension(bad),
          throwsA(isA<DesktopManagedAttachmentError>()),
          reason: 'extension $bad must be rejected',
        );
      }
      expect(
        () => DesktopManagedAttachments.normalizeExtension(7),
        throwsA(
          isA<DesktopManagedAttachmentError>().having(
            (error) => error.message,
            'message',
            'Attachment extension must be a string.',
          ),
        ),
      );
    });

    test('accepts a 16-character extension but not a 17-character one', () {
      expect(
        DesktopManagedAttachments.normalizeExtension('.abcdefghijklmnop'),
        '.abcdefghijklmnop',
      );
      expect(
        () =>
            DesktopManagedAttachments.normalizeExtension('.abcdefghijklmnopq'),
        throwsA(isA<DesktopManagedAttachmentError>()),
      );
    });

    test('trims and validates attachment ids', () {
      expect(
        DesktopManagedAttachments.normalizeAttachmentId('  att_1  '),
        'att_1',
      );
      expect(DesktopManagedAttachments.normalizeAttachmentId('a-B_9'), 'a-B_9');
      for (final bad in <Object?>[
        '',
        '  ',
        '../escape',
        'att.1',
        'att/1',
        r'att\1',
        'att 1',
      ]) {
        expect(
          () => DesktopManagedAttachments.normalizeAttachmentId(bad),
          throwsA(isA<DesktopManagedAttachmentError>()),
          reason: 'id $bad must be rejected',
        );
      }
      expect(
        () => DesktopManagedAttachments.normalizeAttachmentId(null),
        throwsA(
          isA<DesktopManagedAttachmentError>().having(
            (error) => error.message,
            'message',
            'Attachment id is required.',
          ),
        ),
      );
    });

    test('creates the managed directory before validating the id', () async {
      await expectLater(
        attachments.writeAttachmentBytes(
          attachmentId: '../escape',
          bytes: Uint8List.fromList(<int>[1]),
        ),
        throwsA(isA<DesktopManagedAttachmentError>()),
      );

      // Upstream mkdirs first and validates second; the empty directory it
      // leaves behind is observable, so it is pinned rather than tidied up.
      expect(fs.log, <String>['mkdir $managedDir']);
    });

    test('rejects an empty base64 payload before touching the disk', () async {
      for (final payload in <Object?>[null, '', '   ', 42]) {
        await expectLater(
          attachments.writeAttachmentBase64(
            attachmentId: 'att_1',
            base64: payload,
          ),
          throwsA(
            isA<DesktopManagedAttachmentError>().having(
              (error) => error.message,
              'message',
              'Attachment base64 payload is required.',
            ),
          ),
        );
      }
      expect(fs.log, isEmpty);
    });

    test('writes decoded base64 bytes and reports the stored size', () async {
      final result = await attachments.writeAttachmentBase64(
        attachmentId: 'att_1',
        base64: '  SGVsbG8=  ',
        extension: 'txt',
      );

      expect(result.path, '$managedDir/att_1.txt');
      expect(result.byteSize, 5);
      expect(fs.textAt(result.path), 'Hello');
    });

    test('writes raw bytes through the unknown-payload normaliser', () async {
      final result = await attachments.writeAttachmentBytes(
        attachmentId: 'att_bytes',
        bytes: <Object?>[72, 'a', 300, -1, 1.7, null, true],
      );

      expect(result.path, '$managedDir/att_bytes.bin');
      expect(
        fs.files[result.path],
        Uint8List.fromList(<int>[72, 0, 44, 255, 1, 0, 1]),
      );
    });

    test('accepts every typed-data flavour of a byte payload', () {
      final list = Uint8List.fromList(<int>[1, 2, 3]);
      expect(
        DesktopManagedAttachments.normalizeAttachmentBytes(list),
        same(list),
      );
      expect(
        DesktopManagedAttachments.normalizeAttachmentBytes(list.buffer),
        Uint8List.fromList(<int>[1, 2, 3]),
      );
      expect(
        DesktopManagedAttachments.normalizeAttachmentBytes(
          Int8List.fromList(<int>[1, 2]),
        ),
        Uint8List.fromList(<int>[1, 2]),
      );
      for (final bad in <Object?>[null, 'bytes', 42]) {
        expect(
          () => DesktopManagedAttachments.normalizeAttachmentBytes(bad),
          throwsA(
            isA<DesktopManagedAttachmentError>().having(
              (error) => error.message,
              'message',
              'Attachment byte payload is required.',
            ),
          ),
        );
      }
    });

    test('rejects a missing source path before resolving anything', () async {
      for (final bad in <Object?>[null, '', '   ', 5]) {
        await expectLater(
          attachments.copyAttachmentFileToManagedStorage(
            attachmentId: 'att_1',
            sourcePath: bad,
          ),
          throwsA(
            isA<DesktopManagedAttachmentError>().having(
              (error) => error.message,
              'message',
              'Attachment source path is required.',
            ),
          ),
        );
      }
      expect(fs.log, isEmpty);
    });

    test(
      'skips the copy when the source already is the managed file',
      () async {
        fs.seedText('$managedDir/att_same.bin', 'abc');

        final result = await attachments.copyAttachmentFileToManagedStorage(
          attachmentId: 'att_same',
          sourcePath: '$managedDir/./att_same.bin',
        );

        expect(result.byteSize, 3);
        expect(fs.log.where((entry) => entry.startsWith('copy ')), isEmpty);
      },
    );

    test(
      'resolves a relative source path against the working directory',
      () async {
        fs.seedText('/cwd/inbox/report.md', 'hi');

        final result = await attachments.copyAttachmentFileToManagedStorage(
          attachmentId: 'att_rel',
          sourcePath: 'inbox/report.md',
          extension: 'md',
        );

        expect(result.path, '$managedDir/att_rel.md');
        expect(fs.textAt(result.path), 'hi');
      },
    );

    test('reads a managed file back as base64', () async {
      fs.seedText('$managedDir/att_1.txt', 'Hello');

      expect(
        await attachments.readManagedFileBase64(path: '$managedDir/att_1.txt'),
        'SGVsbG8=',
      );
    });

    test(
      'reports success when deleting an already-missing managed file',
      () async {
        expect(
          await attachments.deleteManagedAttachmentFile(
            path: '$managedDir/gone.bin',
          ),
          isTrue,
        );
        expect(fs.log, <String>['rm $managedDir/gone.bin']);
      },
    );

    test('confines managed paths to strict descendants of the store', () {
      expect(
        attachments.resolveManagedAttachmentPath('$managedDir/ok.bin'),
        '$managedDir/ok.bin',
      );
      expect(
        attachments.resolveManagedAttachmentPath('  $managedDir/ok.bin  '),
        '$managedDir/ok.bin',
      );
      expect(
        attachments.resolveManagedAttachmentPath('$managedDir/nested/ok.bin'),
        '$managedDir/nested/ok.bin',
      );

      for (final bad in <String>[
        // Traversal out of the store.
        '$managedDir/../../.ssh/id_rsa',
        '$managedDir/..',
        // A sibling that merely shares the prefix.
        '$paseoHome/desktop-attachments-stolen/x.bin',
        // The store directory itself is not a file inside the store.
        managedDir,
        '$managedDir/',
        // Somewhere else entirely.
        '/etc/passwd',
      ]) {
        expect(
          () => attachments.resolveManagedAttachmentPath(bad),
          throwsA(
            isA<DesktopManagedAttachmentError>().having(
              (error) => error.message,
              'message',
              'Attachment path must stay within desktop-managed storage.',
            ),
          ),
          reason: '$bad must be refused',
        );
      }
    });

    test('rejects a missing managed path outright', () {
      for (final bad in <Object?>[null, '', '   ', 12]) {
        expect(
          () => attachments.resolveManagedAttachmentPath(bad),
          throwsA(
            isA<DesktopManagedAttachmentError>().having(
              (error) => error.message,
              'message',
              'Attachment path is required.',
            ),
          ),
        );
      }
    });

    test('confines managed paths under Win32 path semantics too', () {
      final windowsFs = _MemoryFileSystem(separator: r'\');
      final windows = DesktopManagedAttachments(
        fileSystem: windowsFs,
        paseoHome: r'C:\Users\me\.paseo',
        workingDirectory: r'C:\cwd',
        pathOps: DesktopBrowserPathOps.windows,
      );
      const dir = r'C:\Users\me\.paseo\desktop-attachments';

      expect(windows.directoryPath, dir);
      expect(windows.resolveManagedAttachmentPath('$dir\\a.md'), '$dir\\a.md');
      // Forward slashes are a legal Win32 separator and normalise in.
      expect(
        windows.resolveManagedAttachmentPath(
          'C:/Users/me/.paseo/desktop-attachments/a.md',
        ),
        '$dir\\a.md',
      );
      expect(
        () => windows.resolveManagedAttachmentPath('$dir\\..\\..\\secret.txt'),
        throwsA(isA<DesktopManagedAttachmentError>()),
      );
      // Deliberately stricter-looking than a Windows user might expect, and
      // identical to Node: the prefix test is case-sensitive, so a
      // differently-cased path is refused rather than admitted.
      expect(
        () => windows.resolveManagedAttachmentPath(
          r'c:\users\me\.paseo\desktop-attachments\a.md',
        ),
        throwsA(isA<DesktopManagedAttachmentError>()),
      );
    });

    test('garbage-collects every unreferenced managed file', () async {
      fs.seedText('$managedDir/att_keep.md', 'keep');
      fs.seedText('$managedDir/att_drop.png', 'drop');
      fs.seedText('$managedDir/att_noext', 'drop too');
      fs.seedDirectory('$managedDir/subdir');
      fs.seedText('$managedDir/subdir/inner.bin', 'untouched');

      final removed = await attachments.garbageCollectManagedAttachmentFiles(
        referencedIds: <Object?>['  att_keep  ', 42, null, '../escape'],
      );

      expect(removed, 2);
      expect(fs.files.containsKey('$managedDir/att_keep.md'), isTrue);
      expect(fs.files.containsKey('$managedDir/att_drop.png'), isFalse);
      expect(fs.files.containsKey('$managedDir/att_noext'), isFalse);
      // Directories are never entered or removed.
      expect(fs.files.containsKey('$managedDir/subdir/inner.bin'), isTrue);
    });

    test(
      'treats a non-list reference set as "nothing is referenced"',
      () async {
        fs.seedText('$managedDir/att_a.bin', 'a');
        fs.seedText('$managedDir/att_b.bin', 'b');

        expect(
          await attachments.garbageCollectManagedAttachmentFiles(
            referencedIds: 'att_a',
          ),
          2,
        );
        expect(
          fs.files.keys.where((path) => path.startsWith(managedDir)),
          isEmpty,
        );
      },
    );

    test('cannot keep a file whose stem is not a legal attachment id', () async {
      // `path.parse` gives `.bashrc` the stem `.bashrc` and `x.tar.gz` the stem
      // `x.tar`; neither can ever appear in the referenced set, because the set
      // is filtered through the id pattern. Both are therefore always collected.
      fs.seedText('$managedDir/.bashrc', 'x');
      fs.seedText('$managedDir/x.tar.gz', 'y');

      expect(
        await attachments.garbageCollectManagedAttachmentFiles(
          referencedIds: <Object?>['.bashrc', 'x.tar'],
        ),
        2,
      );
    });

    test(
      'creates the managed directory even when it collects nothing',
      () async {
        expect(
          await attachments.garbageCollectManagedAttachmentFiles(
            referencedIds: <Object?>[],
          ),
          0,
        );
        expect(fs.log, <String>['mkdir $managedDir']);
      },
    );
  });

  group('Node-compatible base64 decoding', () {
    // Every expectation below was produced by running the same string through
    // `Buffer.from(value, "base64")` under Node.
    test('matches Node for padded, unpadded and dirty input', () {
      final cases = <String, List<int>>{
        'SGVsbG8=': <int>[72, 101, 108, 108, 111],
        'SGVsbG8': <int>[72, 101, 108, 108, 111],
        'SG Vs bG8=': <int>[72, 101, 108, 108, 111],
        'SGVsbG8!': <int>[72, 101, 108, 108, 111],
        '\n\tSGVsbG8=': <int>[72, 101, 108, 108, 111],
        '-_': <int>[251],
        'a': <int>[],
        'ab': <int>[105],
        'abc': <int>[105, 183],
        'abcd': <int>[105, 183, 29],
        '****': <int>[],
        '': <int>[],
      };
      cases.forEach((input, expected) {
        expect(
          decodeNodeBase64(input),
          Uint8List.fromList(expected),
          reason: 'decode of ${jsonEncode(input)}',
        );
      });
    });

    test('stops at the first padding character, as Node does', () {
      expect(
        decodeNodeBase64('SGVsbG8=extra'),
        Uint8List.fromList(<int>[72, 101, 108, 108, 111]),
      );
      expect(
        decodeNodeBase64('SGVs=bG8'),
        Uint8List.fromList(<int>[72, 101, 108]),
      );
      expect(decodeNodeBase64('=abc'), Uint8List(0));
      expect(decodeNodeBase64('a=bc'), Uint8List(0));
    });

    test('round-trips whatever dart:convert produced', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(256, (index) => index),
      );
      expect(decodeNodeBase64(base64Encode(bytes)), bytes);
    });
  });

  // -------------------------------------------------------------------------
  // browser-webviews/window-open.ts — re-verifying the pre-existing port
  // -------------------------------------------------------------------------

  group('browser webview window-open requests', () {
    DesktopBrowserWindowOpenDecision decide({
      required String url,
      required DesktopBrowserWindowOpenDisposition disposition,
      String frameName = '',
      String features = '',
      bool hasPostBody = false,
    }) => decideDesktopBrowserWindowOpen(
      DesktopBrowserWindowOpenRequest(
        url: url,
        disposition: disposition,
        frameName: frameName,
        features: features,
        hasPostBody: hasPostBody,
      ),
    );

    void expectWorkspaceTab(
      DesktopBrowserWindowOpenDecision decision,
      String url,
    ) {
      expect(decision, isA<OpenDesktopBrowserWorkspaceTab>());
      expect((decision as OpenDesktopBrowserWorkspaceTab).url, url);
    }

    test('routes foreground tabs to a Paseo workspace tab', () {
      expectWorkspaceTab(
        decide(
          url: 'https://example.com/target',
          disposition: DesktopBrowserWindowOpenDisposition.foregroundTab,
          frameName: '_blank',
        ),
        'https://example.com/target',
      );
    });

    test('keeps script-opened windows as real popups', () {
      expect(
        decide(
          url: 'https://login.example.com/signin',
          disposition: DesktopBrowserWindowOpenDisposition.newWindow,
          frameName: 'oauth',
          features: 'width=500,height=600',
        ),
        isA<AllowDesktopBrowserPopup>(),
      );
    });

    test('keeps named windows as real popups without a feature string', () {
      expect(
        decide(
          url: 'https://login.example.com/signin',
          disposition: DesktopBrowserWindowOpenDisposition.newWindow,
          frameName: 'oauth',
        ),
        isA<AllowDesktopBrowserPopup>(),
      );
    });

    test(
      'routes a named target that disowns its opener to a workspace tab',
      () {
        for (final features in <String>['noopener', 'noreferrer']) {
          expectWorkspaceTab(
            decide(
              url: 'https://example.com/target',
              disposition: DesktopBrowserWindowOpenDisposition.newWindow,
              frameName: 'secure-target',
              features: features,
            ),
            'https://example.com/target',
          );
        }
      },
    );

    test('routes Shift-clicked links to a Paseo workspace tab', () {
      expectWorkspaceTab(
        decide(
          url: 'https://example.com/target',
          disposition: DesktopBrowserWindowOpenDisposition.newWindow,
        ),
        'https://example.com/target',
      );
    });

    test('routes non-popup features to a Paseo workspace tab', () {
      for (final features in <String>[
        'noopener',
        'noreferrer',
        'attributionsrc=https://example.com/register',
        'popup=false',
      ]) {
        expectWorkspaceTab(
          decide(
            url: 'https://example.com/target',
            disposition: DesktopBrowserWindowOpenDisposition.newWindow,
            frameName: '_blank',
            features: features,
          ),
          'https://example.com/target',
        );
      }
    });

    test('keeps an explicitly requested popup as a real popup', () {
      expect(
        decide(
          url: 'https://login.example.com/signin',
          disposition: DesktopBrowserWindowOpenDisposition.newWindow,
          frameName: '_blank',
          features: 'noopener,popup=yes',
        ),
        isA<AllowDesktopBrowserPopup>(),
      );
    });

    test('keeps legacy browser-chrome features as a real popup', () {
      expect(
        decide(
          url: 'https://login.example.com/signin',
          disposition: DesktopBrowserWindowOpenDisposition.newWindow,
          frameName: '_blank',
          features: 'menubar=no,toolbar=no,status=no,scrollbars=no',
        ),
        isA<AllowDesktopBrowserPopup>(),
      );
    });

    test('keeps unknown window features as a real popup', () {
      expect(
        decide(
          url: 'https://login.example.com/signin',
          disposition: DesktopBrowserWindowOpenDisposition.newWindow,
          frameName: '_blank',
          features: 'dialog=yes',
        ),
        isA<AllowDesktopBrowserPopup>(),
      );
    });

    test('routes an all-enabled browser-chrome request to a workspace tab', () {
      expectWorkspaceTab(
        decide(
          url: 'https://example.com/target',
          disposition: DesktopBrowserWindowOpenDisposition.newWindow,
          frameName: '_blank',
          features:
              'toolbar=yes,location=yes,menubar=yes,status=yes,scrollbars=yes,'
              'resizable=yes,noopener',
        ),
        'https://example.com/target',
      );
    });

    test('keeps POST-backed foreground tabs as real popups', () {
      expect(
        decide(
          url: 'https://example.com/submit',
          disposition: DesktopBrowserWindowOpenDisposition.foregroundTab,
          frameName: '_blank',
          hasPostBody: true,
        ),
        isA<AllowDesktopBrowserPopup>(),
      );
    });

    test('denies unsupported window-open requests', () {
      expect(
        decide(
          url: 'file:///etc/passwd',
          disposition: DesktopBrowserWindowOpenDisposition.newWindow,
          frameName: 'oauth',
          features: 'width=500,height=600',
        ),
        isA<DenyDesktopBrowserWindowOpen>(),
      );
    });

    test('allows only http, https and about:blank', () {
      for (final allowed in <String>[
        '',
        'about:blank',
        'http://example.com',
        'https://example.com/a?b=c#d',
      ]) {
        expect(
          isAllowedDesktopBrowserUrl(allowed),
          isTrue,
          reason: '$allowed should be allowed',
        );
      }
      for (final denied in <String>[
        'file:///etc/passwd',
        'javascript:alert(1)',
        'data:text/html,<script>',
        'chrome://settings',
        'not a url',
        // Stricter than upstream's WHATWG parser on purpose: `new URL` would
        // normalise this to `http://example.com/`, while this port refuses a
        // scheme without an authority. A tighter allowlist on a window-open
        // gate is the safe direction.
        'http:example.com',
      ]) {
        expect(
          isAllowedDesktopBrowserUrl(denied),
          isFalse,
          reason: '$denied should be denied',
        );
      }
    });
  });

  group('pending browser window-open requests', () {
    test('holds early workspace-tab requests until identity registration', () {
      final pending = PendingDesktopBrowserWindowOpens();
      pending.add(101, 'https://example.com/first');
      pending.add(101, 'file:///etc/passwd');
      pending.add(101, 'https://example.com/second');

      expect(pending.take(101), <String>[
        'https://example.com/first',
        'https://example.com/second',
      ]);
      expect(pending.take(101), isEmpty);
    });

    test('drops pending requests when an unregistered guest is destroyed', () {
      final pending = PendingDesktopBrowserWindowOpens();
      pending.add(202, 'https://example.com/target');
      pending.delete(202);

      expect(pending.take(202), isEmpty);
    });

    test('caps a single guest at twenty pending requests', () {
      final pending = PendingDesktopBrowserWindowOpens();
      for (var index = 0; index < 25; index++) {
        pending.add(303, 'https://example.com/$index');
      }

      expect(pending.take(303).length, 20);
    });
  });

  // -------------------------------------------------------------------------
  // integrations/skills/operations.ts
  // -------------------------------------------------------------------------

  group('getSkillsStatus', () {
    late _SkillsSandbox sandbox;

    setUp(() => sandbox = _SkillsSandbox());

    test('returns not-installed with add ops for every bundled skill when '
        'nothing is on disk', () async {
      sandbox.writeCurrentBundle();

      final status = await sandbox.operations.getStatus(sandbox.targets);

      expect(status.state, PaseoSkillsState.notInstalled);
      expect(status.ops, <PaseoSkillOp>[
        const AddPaseoSkillOp('paseo'),
        const AddPaseoSkillOp('paseo-loop'),
      ]);
    });

    test(
      'returns not-installed when only user-personal skill dirs exist',
      () async {
        sandbox.writeCurrentBundle();
        for (final name in <String>['unslop', 'tdd', 'devbox']) {
          sandbox.writeOnDiskSkill(
            sandbox.targets.agentsDir,
            name,
            <String, String>{'SKILL.md': 'user-$name'},
          );
        }

        final status = await sandbox.operations.getStatus(sandbox.targets);

        expect(status.state, PaseoSkillsState.notInstalled);
        expect(status.ops, <PaseoSkillOp>[
          const AddPaseoSkillOp('paseo'),
          const AddPaseoSkillOp('paseo-loop'),
        ]);
      },
    );

    test(
      'returns up-to-date when every bundled skill matches on disk',
      () async {
        sandbox.writeCurrentBundle();
        sandbox.writeOnDiskSkillToAllTargets('paseo', <String, String>{
          'SKILL.md': 'paseo-v1',
        });
        sandbox.writeOnDiskSkillToAllTargets('paseo-loop', <String, String>{
          'SKILL.md': 'loop-v1',
        });

        expect(
          await sandbox.operations.getStatus(sandbox.targets),
          const PaseoSkillsStatus(
            state: PaseoSkillsState.upToDate,
            ops: <PaseoSkillOp>[],
          ),
        );
      },
    );

    test(
      'ignores user-added files inside managed skill dirs in every target',
      () async {
        sandbox.writeCurrentBundle();
        sandbox.writeOnDiskSkillToAllTargets('paseo', <String, String>{
          'SKILL.md': 'paseo-v1',
        });
        sandbox.writeOnDiskSkillToAllTargets('paseo-loop', <String, String>{
          'SKILL.md': 'loop-v1',
        });
        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          'paseo',
          <String, String>{'my-context.md': 'user context'},
        );
        sandbox.writeOnDiskSkill(
          sandbox.targets.claudeDir,
          'paseo',
          <String, String>{'commands/local.md': 'user command'},
        );
        sandbox.writeOnDiskSkill(
          sandbox.targets.codexDir,
          'paseo',
          <String, String>{'hooks/guard.sh': 'user guard'},
        );

        expect(
          await sandbox.operations.getStatus(sandbox.targets),
          const PaseoSkillsStatus(
            state: PaseoSkillsState.upToDate,
            ops: <PaseoSkillOp>[],
          ),
        );
      },
    );

    test(
      'ignores the sync manifest at a skill root but not a nested copy',
      () async {
        sandbox.writeCurrentBundle();
        sandbox.writeOnDiskSkillToAllTargets('paseo', <String, String>{
          'SKILL.md': 'paseo-v1',
        });
        sandbox.writeOnDiskSkillToAllTargets('paseo-loop', <String, String>{
          'SKILL.md': 'loop-v1',
        });
        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          'paseo',
          <String, String>{paseoManagedFilesManifestName: '{"version":1}'},
        );

        // A manifest at the root is bookkeeping, so it must not make the skill
        // look drifted.
        expect(
          (await sandbox.operations.getStatus(sandbox.targets)).state,
          PaseoSkillsState.upToDate,
        );

        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          'paseo',
          <String, String>{
            'nested/$paseoManagedFilesManifestName': 'user file',
          },
        );

        // A nested file of the same name is the user's, and extra user files are
        // still ignored by the bundle-only comparison.
        expect(
          (await sandbox.operations.getStatus(sandbox.targets)).state,
          PaseoSkillsState.upToDate,
        );
      },
    );

    test('returns drift with a single update op when one bundled file '
        'diverges', () async {
      sandbox.writeCurrentBundle();
      sandbox.writeOnDiskSkill(
        sandbox.targets.agentsDir,
        'paseo',
        <String, String>{'SKILL.md': 'stale'},
      );
      sandbox.writeOnDiskSkill(
        sandbox.targets.claudeDir,
        'paseo',
        <String, String>{'SKILL.md': 'paseo-v1'},
      );
      sandbox.writeOnDiskSkill(
        sandbox.targets.codexDir,
        'paseo',
        <String, String>{'SKILL.md': 'paseo-v1'},
      );
      sandbox.writeOnDiskSkillToAllTargets('paseo-loop', <String, String>{
        'SKILL.md': 'loop-v1',
      });

      final status = await sandbox.operations.getStatus(sandbox.targets);

      expect(status.state, PaseoSkillsState.drift);
      expect(status.ops, <PaseoSkillOp>[const UpdatePaseoSkillOp('paseo')]);
    });

    test('returns drift when a secondary agent target is stale', () async {
      sandbox.writeCurrentBundle();
      for (final dir in sandbox.targets.installDirs) {
        sandbox.writeOnDiskSkill(dir, 'paseo', <String, String>{
          'SKILL.md': dir == sandbox.targets.claudeDir ? 'stale' : 'paseo-v1',
        });
        sandbox.writeOnDiskSkill(dir, 'paseo-loop', <String, String>{
          'SKILL.md': 'loop-v1',
        });
      }

      final status = await sandbox.operations.getStatus(sandbox.targets);

      expect(status.state, PaseoSkillsState.drift);
      expect(status.ops, <PaseoSkillOp>[const UpdatePaseoSkillOp('paseo')]);
    });

    test(
      'returns drift with add ops for bundled skills missing from disk',
      () async {
        sandbox.writeCurrentBundle();
        sandbox.writeOnDiskSkillToAllTargets('paseo', <String, String>{
          'SKILL.md': 'paseo-v1',
        });

        final status = await sandbox.operations.getStatus(sandbox.targets);

        expect(status.state, PaseoSkillsState.drift);
        expect(status.ops, <PaseoSkillOp>[const AddPaseoSkillOp('paseo-loop')]);
      },
    );

    test(
      'prefers add over update when a skill is both stale and missing',
      () async {
        sandbox.writeCurrentBundle();
        sandbox.writeOnDiskSkillToAllTargets('paseo-loop', <String, String>{
          'SKILL.md': 'loop-v1',
        });
        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          'paseo',
          <String, String>{'SKILL.md': 'stale'},
        );

        final status = await sandbox.operations.getStatus(sandbox.targets);

        expect(status.ops, <PaseoSkillOp>[const AddPaseoSkillOp('paseo')]);
      },
    );

    test(
      'returns drift with a delete op for a legacy skill name on disk',
      () async {
        sandbox.writeCurrentBundle();
        sandbox.writeOnDiskSkillToAllTargets('paseo', <String, String>{
          'SKILL.md': 'paseo-v1',
        });
        sandbox.writeOnDiskSkillToAllTargets('paseo-loop', <String, String>{
          'SKILL.md': 'loop-v1',
        });
        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          'paseo-chat',
          <String, String>{'SKILL.md': 'chat-old'},
        );

        final status = await sandbox.operations.getStatus(sandbox.targets);

        expect(status.state, PaseoSkillsState.drift);
        expect(status.ops, <PaseoSkillOp>[
          const DeletePaseoSkillOp('paseo-chat'),
        ]);
      },
    );

    test(
      'emits add + update + delete ops sorted by name when state is mixed',
      () async {
        sandbox.writeCurrentBundle();
        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          'paseo',
          <String, String>{'SKILL.md': 'stale'},
        );
        sandbox.writeOnDiskSkill(
          sandbox.targets.claudeDir,
          'paseo',
          <String, String>{'SKILL.md': 'paseo-v1'},
        );
        sandbox.writeOnDiskSkill(
          sandbox.targets.codexDir,
          'paseo',
          <String, String>{'SKILL.md': 'paseo-v1'},
        );
        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          'paseo-chat',
          <String, String>{'SKILL.md': 'chat-old'},
        );

        final status = await sandbox.operations.getStatus(sandbox.targets);

        expect(status.state, PaseoSkillsState.drift);
        expect(status.ops, <PaseoSkillOp>[
          const UpdatePaseoSkillOp('paseo'),
          const DeletePaseoSkillOp('paseo-chat'),
          const AddPaseoSkillOp('paseo-loop'),
        ]);
      },
    );

    test(
      'reports no ops at all when the bundle is empty and disk is clean',
      () async {
        expect(
          await sandbox.operations.getStatus(sandbox.targets),
          const PaseoSkillsStatus(
            state: PaseoSkillsState.notInstalled,
            ops: <PaseoSkillOp>[],
          ),
        );
      },
    );
  });

  group('installSkills / updateSkills', () {
    late _SkillsSandbox sandbox;

    setUp(() => sandbox = _SkillsSandbox());

    test('installs from a clean machine, populates all three targets, and '
        'leaves user dirs alone', () async {
      sandbox.writeCurrentBundle();
      sandbox.writeOnDiskSkill(
        sandbox.targets.agentsDir,
        'unslop',
        <String, String>{'SKILL.md': 'user-unslop'},
      );

      final status = await sandbox.operations.install(sandbox.targets);

      expect(
        status,
        const PaseoSkillsStatus(
          state: PaseoSkillsState.upToDate,
          ops: <PaseoSkillOp>[],
        ),
      );
      for (final entry in <String, String>{
        'paseo': 'paseo-v1',
        'paseo-loop': 'loop-v1',
      }.entries) {
        for (final dir in sandbox.targets.installDirs) {
          expect(sandbox.fs.textAt('$dir/${entry.key}/SKILL.md'), entry.value);
        }
      }
      expect(
        sandbox.fs.textAt('${sandbox.targets.agentsDir}/unslop/SKILL.md'),
        'user-unslop',
      );
    });

    test('converges to up-to-date when state has missing + edited + legacy '
        'skills', () async {
      sandbox.writeCurrentBundle();
      sandbox.writeOnDiskSkill(
        sandbox.targets.agentsDir,
        'paseo',
        <String, String>{'SKILL.md': 'stale'},
      );
      sandbox.writeOnDiskSkillToAllTargets('paseo-chat', <String, String>{
        'SKILL.md': 'chat-old',
      });

      final status = await sandbox.operations.update(sandbox.targets);

      expect(
        status,
        const PaseoSkillsStatus(
          state: PaseoSkillsState.upToDate,
          ops: <PaseoSkillOp>[],
        ),
      );
      expect(
        sandbox.fs.textAt('${sandbox.targets.agentsDir}/paseo/SKILL.md'),
        'paseo-v1',
      );
      expect(
        sandbox.fs.textAt('${sandbox.targets.agentsDir}/paseo-loop/SKILL.md'),
        'loop-v1',
      );
      for (final dir in sandbox.targets.installDirs) {
        expect(sandbox.fs.exists('$dir/paseo-chat'), isFalse);
      }
    });

    test(
      'defines updated as the state reached after preserving user files',
      () async {
        sandbox.writeCurrentBundle();
        sandbox.writeOnDiskSkillToAllTargets('paseo', <String, String>{
          'SKILL.md': 'paseo-v1',
        });
        sandbox.writeOnDiskSkillToAllTargets('paseo-loop', <String, String>{
          'SKILL.md': 'loop-v1',
        });
        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          'paseo',
          <String, String>{'SKILL.md': 'stale', 'hooks/guard.sh': 'user guard'},
        );
        sandbox.writeOnDiskSkill(
          sandbox.targets.claudeDir,
          'paseo',
          <String, String>{'notes/local.md': 'claude notes'},
        );
        sandbox.writeOnDiskSkill(
          sandbox.targets.codexDir,
          'paseo',
          <String, String>{'prompts/local.md': 'codex prompt'},
        );

        final status = await sandbox.operations.update(sandbox.targets);

        expect(
          status,
          const PaseoSkillsStatus(
            state: PaseoSkillsState.upToDate,
            ops: <PaseoSkillOp>[],
          ),
        );
        expect(
          await sandbox.operations.getStatus(sandbox.targets),
          const PaseoSkillsStatus(
            state: PaseoSkillsState.upToDate,
            ops: <PaseoSkillOp>[],
          ),
        );
        expect(
          sandbox.fs.textAt(
            '${sandbox.targets.agentsDir}/paseo/hooks/guard.sh',
          ),
          'user guard',
        );
        expect(
          sandbox.fs.textAt(
            '${sandbox.targets.claudeDir}/paseo/notes/local.md',
          ),
          'claude notes',
        );
        expect(
          sandbox.fs.textAt(
            '${sandbox.targets.codexDir}/paseo/prompts/local.md',
          ),
          'codex prompt',
        );
      },
    );

    test('repairs secondary agent targets even when agents skills are '
        'current', () async {
      sandbox.writeCurrentBundle();
      sandbox.writeOnDiskSkill(
        sandbox.targets.agentsDir,
        'paseo',
        <String, String>{'SKILL.md': 'paseo-v1'},
      );
      sandbox.writeOnDiskSkill(
        sandbox.targets.agentsDir,
        'paseo-loop',
        <String, String>{'SKILL.md': 'loop-v1'},
      );
      sandbox.writeOnDiskSkill(
        sandbox.targets.claudeDir,
        'paseo',
        <String, String>{'SKILL.md': 'paseo-v1'},
      );
      sandbox.writeOnDiskSkill(
        sandbox.targets.codexDir,
        'paseo',
        <String, String>{'SKILL.md': 'paseo-v1'},
      );
      sandbox.writeOnDiskSkill(
        sandbox.targets.codexDir,
        'paseo-loop',
        <String, String>{'SKILL.md': 'loop-v1'},
      );

      final status = await sandbox.operations.update(sandbox.targets);

      expect(
        status,
        const PaseoSkillsStatus(
          state: PaseoSkillsState.upToDate,
          ops: <PaseoSkillOp>[],
        ),
      );
      expect(
        sandbox.fs.textAt('${sandbox.targets.claudeDir}/paseo-loop/SKILL.md'),
        'loop-v1',
      );
    });

    test('auto-updates drifted installed skills', () async {
      sandbox.writeCurrentBundle();
      sandbox.writeOnDiskSkill(
        sandbox.targets.agentsDir,
        'paseo',
        <String, String>{'SKILL.md': 'stale', 'hooks/guard.sh': 'user guard'},
      );

      final status = await sandbox.operations.autoUpdateInstalled(
        sandbox.targets,
      );

      expect(
        status,
        const PaseoSkillsStatus(
          state: PaseoSkillsState.upToDate,
          ops: <PaseoSkillOp>[],
        ),
      );
      expect(
        sandbox.fs.textAt('${sandbox.targets.agentsDir}/paseo/SKILL.md'),
        'paseo-v1',
      );
      expect(
        sandbox.fs.textAt('${sandbox.targets.agentsDir}/paseo/hooks/guard.sh'),
        'user guard',
      );
    });

    test('does not auto-install skills on a clean machine', () async {
      sandbox.writeCurrentBundle();

      final status = await sandbox.operations.autoUpdateInstalled(
        sandbox.targets,
      );

      expect(
        status,
        const PaseoSkillsStatus(
          state: PaseoSkillsState.notInstalled,
          ops: <PaseoSkillOp>[
            AddPaseoSkillOp('paseo'),
            AddPaseoSkillOp('paseo-loop'),
          ],
        ),
      );
      for (final dir in sandbox.targets.installDirs) {
        expect(sandbox.fs.exists('$dir/paseo'), isFalse);
      }
      expect(sandbox.sync.syncCalls, isEmpty);
      expect(sandbox.sync.removedSkills, isEmpty);
    });

    test('leaves an already up-to-date install completely untouched', () async {
      sandbox.writeCurrentBundle();
      sandbox.writeOnDiskSkillToAllTargets('paseo', <String, String>{
        'SKILL.md': 'paseo-v1',
      });
      sandbox.writeOnDiskSkillToAllTargets('paseo-loop', <String, String>{
        'SKILL.md': 'loop-v1',
      });

      await sandbox.operations.autoUpdateInstalled(sandbox.targets);

      expect(sandbox.sync.syncCalls, isEmpty);
      expect(sandbox.sync.removedSkills, isEmpty);
    });

    test(
      'is idempotent — running install twice keeps state at up-to-date',
      () async {
        sandbox.writeCurrentBundle();

        final first = await sandbox.operations.install(sandbox.targets);
        final second = await sandbox.operations.install(sandbox.targets);

        const expected = PaseoSkillsStatus(
          state: PaseoSkillsState.upToDate,
          ops: <PaseoSkillOp>[],
        );
        expect(first, expected);
        expect(second, expected);
      },
    );

    test('syncs only the add and update ops, and deletes the rest', () async {
      sandbox.writeCurrentBundle();
      sandbox.writeOnDiskSkill(
        sandbox.targets.agentsDir,
        'paseo-chat',
        <String, String>{'SKILL.md': 'chat-old'},
      );

      await sandbox.operations.install(sandbox.targets);

      expect(sandbox.sync.syncCalls, <List<String>>[
        <String>['paseo', 'paseo-loop'],
      ]);
      expect(sandbox.sync.removedSkills, <String>['paseo-chat']);
    });
  });

  group('uninstallSkills', () {
    late _SkillsSandbox sandbox;

    setUp(() => sandbox = _SkillsSandbox());

    test('removes every Paseo skill from all three targets and preserves '
        'user dirs', () async {
      sandbox.writeCurrentBundle();
      await sandbox.operations.install(sandbox.targets);
      for (final name in <String>['unslop', 'tdd', 'devbox']) {
        sandbox.writeOnDiskSkill(
          sandbox.targets.agentsDir,
          name,
          <String, String>{'SKILL.md': 'user-$name'},
        );
      }

      final status = await sandbox.operations.uninstall(sandbox.targets);

      expect(status.state, PaseoSkillsState.notInstalled);
      for (final name in paseoSkillNames) {
        for (final dir in sandbox.targets.installDirs) {
          expect(sandbox.fs.exists('$dir/$name'), isFalse);
        }
      }
      for (final name in <String>['unslop', 'tdd', 'devbox']) {
        expect(
          sandbox.fs.textAt('${sandbox.targets.agentsDir}/$name/SKILL.md'),
          'user-$name',
        );
      }
    });

    test('is a no-op when nothing is installed', () async {
      sandbox.writeCurrentBundle();

      final status = await sandbox.operations.uninstall(sandbox.targets);

      expect(status.state, PaseoSkillsState.notInstalled);
    });

    test('cleans up legacy skill names that linger in every target', () async {
      sandbox.writeCurrentBundle();
      for (final dir in sandbox.targets.installDirs) {
        sandbox.writeOnDiskSkill(dir, 'paseo-chat', <String, String>{
          'SKILL.md': 'chat-old',
        });
      }

      final status = await sandbox.operations.uninstall(sandbox.targets);

      expect(status.state, PaseoSkillsState.notInstalled);
      for (final dir in sandbox.targets.installDirs) {
        expect(sandbox.fs.exists('$dir/paseo-chat'), isFalse);
      }
    });

    test('attempts removal of every current and retired skill name', () async {
      sandbox.writeCurrentBundle();

      await sandbox.operations.uninstall(sandbox.targets);

      expect(sandbox.sync.removedSkills, paseoSkillNames);
    });
  });
}
