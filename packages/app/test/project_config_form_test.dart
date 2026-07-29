import 'package:coding_agent_app/projects/project_config_form.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('configToDraft', () {
    test('returns an empty draft for null config', () {
      final draft = configToDraft(null);

      expect(draft.setupText, isEmpty);
      expect(draft.setupOriginalKind, LifecycleOriginalKind.missing);
      expect(draft.teardownText, isEmpty);
      expect(draft.teardownOriginalKind, LifecycleOriginalKind.missing);
      expect(draft.scripts, isEmpty);
      expect(draft.metadataPrompts, {
        'branchName': '',
        'commitMessage': '',
        'pullRequest': '',
      });
      expect(draft.metadataGenerationBase, isNull);
    });

    test('projects string and array lifecycle values and remembers kinds', () {
      final draft = configToDraft({
        'worktree': {
          'setup': 'npm install',
          'teardown': ['docker compose down', 'rm -rf .cache'],
        },
      });

      expect(draft.setupText, 'npm install');
      expect(draft.setupOriginalKind, LifecycleOriginalKind.string);
      expect(draft.teardownText, 'docker compose down\nrm -rf .cache');
      expect(draft.teardownOriginalKind, LifecycleOriginalKind.array);
    });

    test('converts scripts to stable distinct local rows', () {
      final draft = configToDraft({
        'scripts': {
          'dev': {
            'type': 'long-running',
            'command': 'npm run dev',
            'port': 3000.0,
          },
          'build': {
            'command': ['npm', 'run', 'build'],
          },
        },
      });

      expect(draft.scripts, hasLength(2));
      final dev = draft.scripts[0];
      final build = draft.scripts[1];
      expect(dev.name, 'dev');
      expect(dev.commandText, 'npm run dev');
      expect(dev.commandOriginalKind, LifecycleOriginalKind.string);
      expect(dev.type, 'long-running');
      expect(dev.portText, '3000');
      expect(dev.id, matches(RegExp(r'^script-draft-\d+$')));
      expect(build.name, 'build');
      expect(build.commandText, 'npm\nrun\nbuild');
      expect(build.commandOriginalKind, LifecycleOriginalKind.array);
      expect(build.portText, isEmpty);
      expect(build.id, isNot(dev.id));
    });

    test('reads only the three visible metadata prompt instructions', () {
      final draft = configToDraft({
        'metadataGeneration': {
          'agentTitle': {'instructions': 'legacy'},
          'branchName': {'instructions': 'feat/<slug>'},
          'commitMessage': {'instructions': 'Conventional commits.'},
          'pullRequest': {'instructions': 'Include risk notes.'},
        },
      });

      expect(draft.metadataPrompts, {
        'branchName': 'feat/<slug>',
        'commitMessage': 'Conventional commits.',
        'pullRequest': 'Include risk notes.',
      });
    });
  });

  group('applyDraftToConfig', () {
    test('preserves existing lifecycle kinds and infers new ones', () {
      final stringBase = <String, Object?>{
        'worktree': {'setup': 'npm install'},
      };
      final stringDraft = configToDraft(stringBase)
        ..setupText = 'npm install\nnpm run prepare';
      expect(
        (applyDraftToConfig(draft: stringDraft, base: stringBase)['worktree']
            as Map)['setup'],
        'npm install\nnpm run prepare',
      );

      final arrayBase = <String, Object?>{
        'worktree': {
          'teardown': ['docker compose down'],
        },
      };
      final arrayDraft = configToDraft(arrayBase)
        ..teardownText = 'docker compose down\nrm -rf .cache';
      expect(
        (applyDraftToConfig(draft: arrayDraft, base: arrayBase)['worktree']
            as Map)['teardown'],
        ['docker compose down', 'rm -rf .cache'],
      );

      final newDraft = configToDraft(null)
        ..setupText = 'npm install\nnpm run prepare';
      expect(
        (applyDraftToConfig(draft: newDraft, base: null)['worktree']
            as Map)['setup'],
        ['npm install', 'npm run prepare'],
      );
    });

    test('removes lifecycle fields whose text becomes empty', () {
      final base = <String, Object?>{
        'worktree': {'setup': 'npm install', 'keep': true},
      };
      final draft = configToDraft(base)..setupText = '';

      expect(applyDraftToConfig(draft: draft, base: base), {
        'worktree': {'keep': true},
      });
    });

    test('preserves unknown top-level, worktree, and script fields', () {
      final base = <String, Object?>{
        'worktree': {
          'setup': 'npm install',
          'terminals': [
            {'name': 'dev', 'command': 'npm run dev'},
          ],
          'customWorktreeField': 'keep',
        },
        'scripts': {
          'dev': {
            'type': 'long-running',
            'command': 'npm run dev',
            'port': 3000,
            'customScriptField': {'nested': true},
          },
        },
        'customTopLevel': 'preserved',
      };

      expect(applyDraftToConfig(draft: configToDraft(base), base: base), base);
    });

    test('preserves untouched scripts while editing one command', () {
      final base = <String, Object?>{
        'scripts': {
          'dev': {
            'type': 'long-running',
            'command': 'npm run dev',
            'port': 3000,
            'customDevField': 'keep',
          },
          'build': {
            'command': ['npm', 'run', 'build'],
            'customBuildField': {'nested': 1},
          },
          'lint': {'command': 'npm run lint', 'type': 'task'},
        },
      };
      final draft = configToDraft(base);
      draft.scripts.first.commandText = 'npm run dev -- --watch';

      final scripts =
          applyDraftToConfig(draft: draft, base: base)['scripts'] as Map;
      expect(scripts.keys, ['dev', 'build', 'lint']);
      expect(scripts['dev'], {
        'type': 'long-running',
        'command': 'npm run dev -- --watch',
        'port': 3000,
        'customDevField': 'keep',
      });
      expect(scripts['build'], {
        'command': ['npm', 'run', 'build'],
        'customBuildField': {'nested': 1},
      });
      expect(scripts['lint'], {'command': 'npm run lint', 'type': 'task'});
    });

    test('normalizes commands to original kind and parses ports', () {
      final base = <String, Object?>{
        'scripts': {
          'build': {
            'command': ['npm', 'run', 'build'],
          },
        },
      };
      final draft = configToDraft(base);
      draft.scripts.first
        ..commandText = 'npm run build'
        ..portText = '3000';
      draft.scripts.add(
        ProjectScriptDraft(
          id: 'tunnel',
          name: 'tunnel',
          commandText: 'ngrok',
          commandOriginalKind: LifecycleOriginalKind.missing,
          type: 'long-running',
          portText: 'auto',
          rawEntry: const {},
        ),
      );

      final scripts =
          applyDraftToConfig(draft: draft, base: base)['scripts'] as Map;
      expect((scripts['build'] as Map)['command'], ['npm run build']);
      expect((scripts['build'] as Map)['port'], 3000);
      expect((scripts['tunnel'] as Map)['command'], 'ngrok');
      expect((scripts['tunnel'] as Map)['port'], 'auto');
    });

    test('writes only non-empty metadata prompts', () {
      final draft = configToDraft(null);
      draft.metadataPrompts['branchName'] = 'Use mb/.';
      draft.metadataPrompts['commitMessage'] = 'Conventional commits.';

      expect(applyDraftToConfig(draft: draft, base: null), {
        'metadataGeneration': {
          'branchName': {'instructions': 'Use mb/.'},
          'commitMessage': {'instructions': 'Conventional commits.'},
        },
      });
    });

    test('preserves metadata siblings and unknown prompt fields', () {
      final base = <String, Object?>{
        'metadataGeneration': {
          'agentTitle': {'instructions': 'Legacy.'},
          'futureField': 42,
          'branchName': {'instructions': 'Old.', 'model': 'haiku'},
        },
      };
      final draft = configToDraft(base);
      draft.metadataPrompts['branchName'] = 'Updated.';

      expect(applyDraftToConfig(draft: draft, base: base), {
        'metadataGeneration': {
          'agentTitle': {'instructions': 'Legacy.'},
          'futureField': 42,
          'branchName': {'instructions': 'Updated.', 'model': 'haiku'},
        },
      });
    });

    test('clears instructions but preserves prompt siblings', () {
      final base = <String, Object?>{
        'metadataGeneration': {
          'branchName': {'instructions': 'Old.', 'model': 'haiku'},
        },
      };
      final draft = configToDraft(base);
      draft.metadataPrompts['branchName'] = '';

      expect(applyDraftToConfig(draft: draft, base: base), {
        'metadataGeneration': {
          'branchName': {'model': 'haiku'},
        },
      });
    });

    test('drops empty metadata and removed or unnamed scripts', () {
      final base = <String, Object?>{
        'metadataGeneration': {
          'branchName': {'instructions': 'Old.'},
        },
        'scripts': {
          'dev': {'command': 'npm run dev'},
          'build': {'command': 'npm run build'},
        },
      };
      final draft = configToDraft(base);
      draft.metadataPrompts['branchName'] = '';
      draft.scripts = [
        draft.scripts.first,
        ProjectScriptDraft(
          id: 'empty',
          name: '   ',
          commandText: 'echo hi',
          commandOriginalKind: LifecycleOriginalKind.missing,
          type: '',
          portText: '',
          rawEntry: const {},
        ),
      ];

      expect(applyDraftToConfig(draft: draft, base: base), {
        'scripts': {
          'dev': {'command': 'npm run dev'},
        },
      });
    });
  });
}
