import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/tool_calls/extract_tool_call_file_path.dart';
import 'package:coding_agent_app/tool_calls/tool_call_detail_state.dart';
import 'package:coding_agent_app/tool_calls/tool_call_presentation.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  IconData icon(String toolName, ToolCallDetail? detail) => switch (detail) {
    PlanDetail() => FluentIcons.processing,
    ReadDetail() => FluentIcons.view,
    _ => FluentIcons.build,
  };

  test('builds badge, detail, icon, and file-open policy in one model', () {
    final presentation = buildToolCallPresentation(
      toolName: 'read_file',
      status: ToolCallStatus.success,
      error: null,
      cwd: '/tmp/repo',
      detail: const ReadDetail(
        path: '/tmp/repo/src/index.ts',
        content: "console.log('hi');",
      ),
      resolveIcon: icon,
    );

    expect(presentation.displayName, 'Read');
    expect(presentation.summary, 'src/index.ts');
    expect(presentation.icon, FluentIcons.view);
    expect(presentation.isLoadingDetails, isFalse);
    expect(presentation.hasDetails, isTrue);
    expect(presentation.canOpenDetails, isTrue);
    expect(presentation.openFilePath, '/tmp/repo/src/index.ts');
    expect(presentation.isPlan, isFalse);
  });

  test('marks running calls without meaningful detail as loading', () {
    final presentation = buildToolCallPresentation(
      toolName: 'exec_command',
      status: ToolCallStatus.running,
      error: null,
      detail: const GenericDetail(input: {}),
      resolveIcon: icon,
    );

    expect(presentation.displayName, 'Exec Command');
    expect(presentation.icon, FluentIcons.build);
    expect(presentation.isLoadingDetails, isTrue);
    expect(presentation.hasDetails, isFalse);
    expect(presentation.canOpenDetails, isTrue);
    expect(presentation.openFilePath, isNull);
    expect(presentation.isPlan, isFalse);
  });

  test('keeps plan calls out of the expandable badge path', () {
    final presentation = buildToolCallPresentation(
      toolName: 'ExitPlanMode',
      status: ToolCallStatus.success,
      error: null,
      detail: const PlanDetail(text: '1. Do the thing'),
      resolveIcon: icon,
    );

    expect(presentation.isPlan, isTrue);
    expect(presentation.icon, FluentIcons.processing);
  });

  test('detects meaningful values for every detail kind', () {
    expect(hasMeaningfulToolCallDetail(null), isFalse);
    expect(hasMeaningfulToolCallDetail(const ShellDetail(command: '')), isTrue);
    expect(
      hasMeaningfulToolCallDetail(const ReadDetail(path: 'a.dart')),
      isTrue,
    );
    expect(hasMeaningfulToolCallDetail(const ReadDetail(path: '')), isFalse);
    expect(
      hasMeaningfulToolCallDetail(const EditDetail(path: '', diff: '+x')),
      isTrue,
    );
    expect(hasMeaningfulToolCallDetail(const WriteDetail(path: '')), isFalse);
    expect(
      hasMeaningfulToolCallDetail(const SearchDetail(query: '  ')),
      isFalse,
    );
    expect(
      hasMeaningfulToolCallDetail(
        const SearchDetail(query: '', filePaths: ['a.dart']),
      ),
      isTrue,
    );
    expect(
      hasMeaningfulToolCallDetail(const FetchDetail(url: '', codeText: 'ok')),
      isTrue,
    );
    expect(
      hasMeaningfulToolCallDetail(
        const WorktreeSetupToolDetail(
          worktreePath: '',
          branchName: '',
          log: '',
          commands: [],
        ),
      ),
      isFalse,
    );
    expect(
      hasMeaningfulToolCallDetail(const SubAgentDetail(description: 'work')),
      isTrue,
    );
    expect(
      hasMeaningfulToolCallDetail(const PlainTextDetail(text: 'note')),
      isTrue,
    );
    expect(hasMeaningfulToolCallDetail(const PlanDetail(text: '  ')), isFalse);
    expect(
      hasMeaningfulToolCallDetail(
        const GenericDetail(
          input: {
            'empty': [null, '  '],
            'meaningful': {'count': 0},
          },
        ),
      ),
      isTrue,
    );
  });

  test('pending detail requires a running call without error or content', () {
    expect(
      isPendingToolCallDetail(
        detail: const GenericDetail(input: {}),
        status: ToolCallStatus.running,
        error: null,
      ),
      isTrue,
    );
    expect(
      isPendingToolCallDetail(
        detail: const GenericDetail(input: {}),
        status: ToolCallStatus.error,
        error: 'failed',
      ),
      isFalse,
    );
  });

  test('extracts conservative read-like and shell file paths', () {
    expect(
      extractToolCallFilePath(const ReadDetail(path: 'lib/main.dart')),
      'lib/main.dart',
    );
    expect(
      extractToolCallFilePath(const EditDetail(path: 'lib/main.dart')),
      'lib/main.dart',
    );
    expect(
      extractToolCallFilePath(const WriteDetail(path: 'lib/main.dart')),
      'lib/main.dart',
    );
    expect(
      extractToolCallFilePath(const ShellDetail(command: 'cat lib/main.dart')),
      'lib/main.dart',
    );
    expect(
      extractToolCallFilePath(
        const ShellDetail(command: 'head -n 10 lib/main.dart'),
      ),
      'lib/main.dart',
    );
    expect(
      extractToolCallFilePath(
        const ShellDetail(command: 'head -n lib/main.dart'),
      ),
      'lib/main.dart',
    );
    expect(
      extractToolCallFilePath(const ShellDetail(command: 'cat a.dart | head')),
      isNull,
    );
    expect(
      extractToolCallFilePath(const ShellDetail(command: 'dart test')),
      isNull,
    );
  });
}
