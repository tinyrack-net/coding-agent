import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/codex_command_catalog.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('combines builtins, app-server skills, and custom prompts', () async {
    final root = Directory.systemTemp.createTempSync('codex_commands_');
    addTearDown(() => root.deleteSync(recursive: true));
    final promptDirectory = Directory(p.join(root.path, 'prompts'))
      ..createSync(recursive: true);
    File(p.join(promptDirectory.path, 'review.md')).writeAsStringSync('''
---
description: Review the current changes
argument-hint: "<path>"
---
body
''');

    final commands = await listCodexCommands(
      cwd: root.path,
      environment: {'CODEX_HOME': root.path},
      request: (method, params) async {
        expect(method, 'skills/list');
        expect(params, {
          'cwd': [root.path],
        });
        return {
          'data': [
            {
              'skills': [
                {
                  'name': 'taste',
                  'description': 'Apply taste',
                  'path': p.join(root.path, 'taste', 'SKILL.md'),
                },
              ],
            },
          ],
        };
      },
    );

    expect(commands.map((command) => command.name), [
      'compact',
      'prompts:review',
      'taste',
    ]);
    expect(commands.last.kind, AgentSlashCommandKind.skill);
    expect(commands[1].argumentHint, '<path>');
  });

  test(
    'falls back to filesystem skills when app-server returns none',
    () async {
      final root = Directory.systemTemp.createTempSync('codex_skills_');
      addTearDown(() => root.deleteSync(recursive: true));
      final cwd = Directory(p.join(root.path, 'repo'))..createSync();
      Directory(p.join(cwd.path, '.git')).createSync();
      final skill = Directory(p.join(cwd.path, '.codex', 'skills', 'audit'))
        ..createSync(recursive: true);
      File(p.join(skill.path, 'SKILL.md')).writeAsStringSync('''
---
name: audit
description: Audit the implementation
---
''');

      final commands = await listCodexCommands(
        cwd: cwd.path,
        environment: {'CODEX_HOME': p.join(root.path, 'home')},
        request: (_, _) async => const {'data': []},
      );

      expect(commands.map((command) => command.name), ['audit', 'compact']);
      expect(commands.first.kind, AgentSlashCommandKind.skill);
    },
  );

  test(
    'normalizes alternate app-server descriptions and malformed rows',
    () async {
      final root = Directory.systemTemp.createTempSync('codex_skill_rows_');
      addTearDown(() => root.deleteSync(recursive: true));
      final commands = await listCodexCommands(
        cwd: root.path,
        environment: {'HOME': root.path},
        request: (_, _) async => {
          'data': [
            {
              'skills': [
                {'name': '', 'path': 'ignored'},
                {'name': 'missing-path'},
                {
                  'name': 'short',
                  'shortDescription': 'Short description',
                  'path': 'short/SKILL.md',
                },
                {
                  'name': 'snake',
                  'short_description': 'Snake description',
                  'path': 'snake/SKILL.md',
                },
                {'name': 'plain', 'path': 'plain/SKILL.md'},
              ],
            },
          ],
        },
      );

      expect(commands.map((command) => command.name), [
        'compact',
        'plain',
        'short',
        'snake',
      ]);
      expect(commands[1].description, 'Skill');
      expect(commands[2].description, 'Short description');
      expect(commands[3].description, 'Snake description');
    },
  );

  test('handles missing repositories and USERPROFILE Codex home', () async {
    final root = Directory.systemTemp.createTempSync('codex_no_repo_');
    addTearDown(() => root.deleteSync(recursive: true));
    final commands = await listCodexCommands(
      cwd: root.path,
      environment: {'USERPROFILE': root.path},
      request: (_, _) async => const {'data': []},
    );
    expect(commands.single.name, 'compact');
  });
}
