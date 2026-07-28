import 'dart:io';

import 'package:agent_daemon/src/server/directory_suggestions.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('directory-search-');
    Directory(
      p.join(root.path, 'projects', 'paseo-desktop'),
    ).createSync(recursive: true);
    Directory(
      p.join(root.path, 'src', 'components'),
    ).createSync(recursive: true);
    Directory(
      p.join(root.path, '.hidden', 'secret'),
    ).createSync(recursive: true);
    File(
      p.join(root.path, 'src', 'components', 'message-renderer.tsx'),
    ).writeAsStringSync('');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<List<DirectorySuggestionEntry>> workspaceSearch(
    String query, {
    bool? includeFiles,
    bool? includeDirectories,
    DirectorySuggestionMatchMode? matchMode,
    int? limit,
    int? maxDepth,
    int? maxEntriesScanned,
  }) => searchDirectoryEntries(
    SearchDirectoryEntriesOptions(
      root: root.path,
      query: query,
      pathFormat: DirectorySuggestionPathFormat.relative,
      includeFiles: includeFiles,
      includeDirectories: includeDirectories,
      matchMode: matchMode,
      pathQueryPolicy: PathQueryPolicy.slashes,
      blankQueryBehavior: BlankQueryBehavior.children,
      traversableHiddenDirectoryNames: workspaceSearchHiddenDirectories,
      limit: limit,
      maxDepth: maxDepth,
      maxEntriesScanned: maxEntriesScanned,
    ),
  );

  test('fuzzy searches files and directories with relative kinds', () async {
    final directories = await workspaceSearch(
      'pso',
      includeFiles: false,
      includeDirectories: true,
    );
    final files = await workspaceSearch(
      'msgrndr',
      includeFiles: true,
      includeDirectories: false,
    );

    expect(directories.map((entry) => entry.toJson()), [
      {'path': 'projects/paseo-desktop', 'kind': 'directory'},
    ]);
    expect(files.map((entry) => entry.toJson()), [
      {'path': 'src/components/message-renderer.tsx', 'kind': 'file'},
    ]);
  });

  test('blank workspace query browses root children', () async {
    expect(
      (await workspaceSearch(
        '',
        includeFiles: false,
        includeDirectories: true,
      )).map((entry) => entry.path),
      ['projects', 'src'],
    );
    expect(
      await searchDirectoryEntries(
        SearchDirectoryEntriesOptions(
          root: root.path,
          query: '',
          pathFormat: DirectorySuggestionPathFormat.relative,
          includeFiles: false,
          includeDirectories: true,
          blankQueryBehavior: BlankQueryBehavior.none,
        ),
      ),
      isEmpty,
    );
  });

  test('slash queries search only the addressed parent', () async {
    Directory(
      p.join(root.path, 'other', 'component-noise'),
    ).createSync(recursive: true);

    expect(
      (await workspaceSearch(
        'src/com',
        includeFiles: false,
        includeDirectories: true,
      )).map((entry) => entry.path),
      ['src/components'],
    );
    expect(
      await workspaceSearch(
        'node_modules/pkg',
        includeFiles: true,
        includeDirectories: true,
      ),
      isEmpty,
    );
  });

  test(
    'depth, scan, kind, and limit controls match the frozen bounds',
    () async {
      Directory(
        p.join(root.path, 'kind-budget', 'z-projects', 'paseo-target'),
      ).createSync(recursive: true);
      for (var index = 0; index < 10; index += 1) {
        File(
          p.join(root.path, 'kind-budget', 'a-noise-$index.txt'),
        ).writeAsStringSync('');
      }

      expect(
        await workspaceSearch(
          'message-renderer',
          includeFiles: true,
          includeDirectories: false,
          maxDepth: 2,
        ),
        isEmpty,
      );
      expect(
        (await searchDirectoryEntries(
          SearchDirectoryEntriesOptions(
            root: p.join(root.path, 'kind-budget'),
            query: 'paseo-target',
            pathFormat: DirectorySuggestionPathFormat.relative,
            includeFiles: false,
            includeDirectories: true,
            maxEntriesScanned: 2,
          ),
        )).single.path,
        'z-projects/paseo-target',
      );
      expect(
        await workspaceSearch(
          '',
          includeFiles: false,
          includeDirectories: false,
        ),
        isEmpty,
      );
      expect(
        await workspaceSearch(
          '',
          includeFiles: false,
          includeDirectories: true,
          limit: 1,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'ignored trees stay hidden while approved tool roots are traversed',
    () async {
      for (final ignored in [
        'node_modules',
        'venv',
        'env',
        'virtualenv',
        'dist',
        'build',
        'target',
        'out',
        'coverage',
        'vendor',
        '__pycache__',
        '.git',
      ]) {
        final target = File(p.join(root.path, ignored, 'search-target.ts'));
        target.parent.createSync(recursive: true);
        target.writeAsStringSync('');
      }
      File(p.join(root.path, 'src', 'search-target.ts')).writeAsStringSync('');
      final skill = File(p.join(root.path, '.codex', 'skills', 'review.md'));
      skill.parent.createSync(recursive: true);
      skill.writeAsStringSync('');

      expect(
        (await workspaceSearch(
          'search-target.ts',
          includeFiles: true,
          includeDirectories: false,
        )).map((entry) => entry.path),
        ['src/search-target.ts'],
      );
      expect(
        (await workspaceSearch(
          'review.md',
          includeFiles: true,
          includeDirectories: false,
        )).map((entry) => entry.path),
        ['.codex/skills/review.md'],
      );
      expect(
        await workspaceSearch(
          'secret',
          includeFiles: false,
          includeDirectories: true,
        ),
        isEmpty,
      );
    },
  );

  test(
    'ranking prefers exact, prefix, substring, then fuzzy matches',
    () async {
      for (final name in [
        'chat',
        'chat-panel',
        'my-chat-view',
        'character-tool',
      ]) {
        Directory(p.join(root.path, name)).createSync();
      }

      expect(
        (await workspaceSearch(
          'chat',
          includeFiles: false,
          includeDirectories: true,
        )).map((entry) => entry.path).take(4),
        ['chat', 'chat-panel', 'my-chat-view', 'character-tool'],
      );
    },
  );

  test('suffix matching and exact entries obey selection controls', () async {
    expect(
      (await workspaceSearch(
        'components/message-renderer.tsx',
        includeFiles: true,
        includeDirectories: false,
        matchMode: DirectorySuggestionMatchMode.suffix,
      )).map((entry) => entry.path),
      ['src/components/message-renderer.tsx'],
    );
    expect(
      await workspaceSearch(
        'components',
        includeFiles: true,
        includeDirectories: false,
        matchMode: DirectorySuggestionMatchMode.suffix,
      ),
      isEmpty,
    );
  });

  test('root aliases and absolute paths browse only their parent', () async {
    final common = (String query) => searchDirectoryEntries(
      SearchDirectoryEntriesOptions(
        root: root.path,
        query: query,
        pathFormat: DirectorySuggestionPathFormat.relative,
        includeFiles: false,
        includeDirectories: true,
        pathQueryPolicy: PathQueryPolicy.rooted,
        rootAliases: const ['~'],
        blankQueryBehavior: BlankQueryBehavior.none,
      ),
    );

    expect((await common('~/projects/pa')).map((entry) => entry.path), [
      'projects/paseo-desktop',
    ]);
    expect((await common('./src/co')).map((entry) => entry.path), [
      'src/components',
    ]);
    expect(
      (await common(
        '${p.join(root.path, 'projects')}${p.separator}',
      )).map((entry) => entry.path),
      ['projects/paseo-desktop'],
    );
    final outside = Directory.systemTemp.createTempSync('outside-search-');
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    });
    expect(await common(p.join(outside.path, 'nope')), isEmpty);
  });

  test('weak fuzzy results do not stop a stronger late exact match', () async {
    final large = Directory(p.join(root.path, 'large'))..createSync();
    for (var index = 0; index < 8; index += 1) {
      Directory(
        p.join(
          large.path,
          'a-${index.toString().padLeft(2, '0')}-project-search-output',
        ),
      ).createSync();
    }
    Directory(p.join(large.path, 'pso')).createSync();

    final entries = await searchDirectoryEntries(
      SearchDirectoryEntriesOptions(
        root: large.path,
        query: 'pso',
        pathFormat: DirectorySuggestionPathFormat.absolute,
        includeFiles: false,
        includeDirectories: true,
        limit: 1,
        maxEntriesScanned: 20,
        confidentResultScanThreshold: 5,
      ),
    );
    expect(
      Directory(entries.single.path).resolveSymbolicLinksSync(),
      Directory(p.join(large.path, 'pso')).resolveSymbolicLinksSync(),
    );
  });

  test('round-robin traversal shares a tight nested scan budget', () async {
    final budget = Directory(p.join(root.path, 'nested-budget'))..createSync();
    final target = Directory(
      p.join(budget.path, 'work', 'client', 'team', 'paseo-desktop'),
    )..createSync(recursive: true);
    for (var index = 0; index < 10; index += 1) {
      Directory(
        p.join(
          budget.path,
          'work',
          'archive',
          'noise-${index.toString().padLeft(2, '0')}',
        ),
      ).createSync(recursive: true);
    }

    final entries = await searchDirectoryEntries(
      SearchDirectoryEntriesOptions(
        root: budget.path,
        query: 'paseo-desktop',
        pathFormat: DirectorySuggestionPathFormat.absolute,
        includeFiles: false,
        includeDirectories: true,
        maxEntriesScanned: 8,
      ),
    );
    expect(
      Directory(entries.single.path).resolveSymbolicLinksSync(),
      target.resolveSymbolicLinksSync(),
    );
  });

  test('suffix exact path resolves hidden files before traversal', () async {
    final hidden = File(p.join(root.path, '.dev', 'paseo-home', 'daemon.log'));
    hidden.parent.createSync(recursive: true);
    hidden.writeAsStringSync('log');

    final entries = await workspaceSearch(
      '.dev/paseo-home/daemon.log',
      includeFiles: true,
      includeDirectories: false,
      matchMode: DirectorySuggestionMatchMode.suffix,
      maxEntriesScanned: 1,
    );
    expect(entries.single.toJson(), {
      'path': '.dev/paseo-home/daemon.log',
      'kind': 'file',
    });
  });

  test(
    'suffix mode matches whole basename and path segment suffixes',
    () async {
      final nested = File(
        p.join(root.path, 'packages', 'app', 'src', 'file.ts'),
      );
      nested.parent.createSync(recursive: true);
      nested.writeAsStringSync('');
      File(p.join(root.path, 'src', 'file.ts')).writeAsStringSync('');
      File(
        p.join(root.path, 'src', 'paseo-config-file.ts'),
      ).writeAsStringSync('');

      for (final query in ['file.ts', 'src/file.ts']) {
        expect(
          (await workspaceSearch(
            query,
            includeFiles: true,
            includeDirectories: false,
            matchMode: DirectorySuggestionMatchMode.suffix,
          )).map((entry) => entry.path),
          ['src/file.ts', 'packages/app/src/file.ts'],
        );
      }
    },
  );

  test(
    'fuzzy basename tiers use exact prefix substring then subsequence',
    () async {
      final components = Directory(p.join(root.path, 'src', 'components'));
      for (final name in [
        'msgrndr',
        'msgrndr-panel.tsx',
        'use-msgrndr.ts',
        'message-renderer.tsx',
      ]) {
        File(p.join(components.path, name)).writeAsStringSync('');
      }

      expect(
        (await workspaceSearch(
          'msgrndr',
          includeFiles: true,
          includeDirectories: false,
        )).map((entry) => entry.path).take(4),
        [
          'src/components/msgrndr',
          'src/components/msgrndr-panel.tsx',
          'src/components/use-msgrndr.ts',
          'src/components/message-renderer.tsx',
        ],
      );
    },
  );
}
