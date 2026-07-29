import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('builds summaries from every canonical detail kind', () {
    ToolCallDisplayModel build(
      ToolCallDetail detail, {
      String name = 'tool',
      String? cwd,
    }) => buildToolCallDisplayModel(
      ToolCallDisplayInput(
        name: name,
        status: ToolCallStatus.running,
        detail: detail,
        cwd: cwd,
      ),
    );

    expect(build(const ShellDetail(command: 'dart test')).displayName, 'Shell');
    expect(
      build(
        const ReadDetail(path: '/tmp/repo/src/main.dart'),
        cwd: '/tmp/repo',
      ).summary,
      'src/main.dart',
    );
    expect(
      build(
        const EditDetail(path: '/tmp/repo/a.dart'),
        cwd: '/tmp/repo',
      ).summary,
      'a.dart',
    );
    expect(
      build(
        const WriteDetail(path: '/tmp/repo/b.dart'),
        cwd: '/tmp/repo',
      ).summary,
      'b.dart',
    );
    expect(build(const SearchDetail(query: 'needle')).summary, 'needle');
    expect(
      build(const FetchDetail(url: 'https://paseo.dev')).summary,
      'https://paseo.dev',
    );
    expect(
      build(
        const WorktreeSetupToolDetail(
          worktreePath: '/tmp/w',
          branchName: 'feature',
          log: '',
          commands: [],
        ),
      ),
      isA<ToolCallDisplayModel>()
          .having((model) => model.displayName, 'displayName', 'Worktree Setup')
          .having((model) => model.summary, 'summary', 'feature'),
    );
    expect(
      build(
        const SubAgentDetail(
          subAgentType: 'Explore',
          description: 'Inspect repository',
          log: '',
        ),
      ),
      isA<ToolCallDisplayModel>()
          .having((model) => model.displayName, 'displayName', 'Explore')
          .having((model) => model.summary, 'summary', 'Inspect repository'),
    );
    expect(
      build(const PlainTextDetail(label: 'npm test'), name: 'terminal'),
      isA<ToolCallDisplayModel>()
          .having((model) => model.displayName, 'displayName', 'Terminal')
          .having((model) => model.summary, 'summary', 'npm test'),
    );
    expect(build(const PlanDetail(text: '# Plan')).displayName, 'Plan');
  });

  test('does not infer a summary from unknown raw input', () {
    final display = buildToolCallDisplayModel(
      const ToolCallDisplayInput(
        name: 'exec_command',
        status: ToolCallStatus.running,
        detail: GenericDetail(input: {'command': 'npm test'}),
      ),
    );
    expect(display.displayName, 'Exec Command');
    expect(display.summary, isNull);
  });

  test('matches task, thinking, terminal, and Paseo name overrides', () {
    ToolCallDisplayModel build(
      String name, {
      ToolCallDetail detail = const GenericDetail(input: {}),
      Map<String, Object?> metadata = const {},
    }) => buildToolCallDisplayModel(
      ToolCallDisplayInput(
        name: name,
        status: ToolCallStatus.running,
        detail: detail,
        metadata: metadata,
      ),
    );

    expect(
      build('Task', metadata: const {'subAgentActivity': 'Inspect files'}),
      isA<ToolCallDisplayModel>()
          .having((model) => model.displayName, 'displayName', 'Task')
          .having((model) => model.summary, 'summary', 'Inspect files'),
    );
    expect(build('thinking').displayName, 'Thinking');
    expect(build('terminal').displayName, 'Terminal');
    expect(build('mcp__paseo__create_agent').displayName, 'Create Agent');
    expect(build('paseo.create_agent').displayName, 'Create Agent');
    expect(build('mcp__paseo__list_agents').displayName, 'List Agents');
    expect(build('speak').displayName, 'Speak');
    expect(build('mcp__github__search').displayName, 'mcp__github__search');
  });

  test('formats errors only for failed calls', () {
    ToolCallDisplayModel build(ToolCallStatus status, Object? error) =>
        buildToolCallDisplayModel(
          ToolCallDisplayInput(
            name: 'shell',
            status: status,
            error: error,
            detail: const GenericDetail(input: {}),
          ),
        );

    expect(build(ToolCallStatus.error, 'boom').errorText, 'boom');
    expect(
      build(ToolCallStatus.error, const {'content': 'denied'}).errorText,
      'denied',
    );
    expect(
      build(ToolCallStatus.error, const {'message': 'boom'}).errorText,
      '{\n  "message": "boom"\n}',
    );
    expect(
      build(ToolCallStatus.running, const {'message': 'boom'}).errorText,
      isNull,
    );
  });

  test('keeps legacy wire names while removing the Paseo UI brand prefix', () {
    expect(
      tinyrackToolCallDisplayName(
        'paseo_worktree_terminals',
        humanizeToolCallName('paseo_worktree_terminals'),
      ),
      'Worktree Terminals',
    );
    expect(
      tinyrackToolCallDisplayName('external', 'Paseo External'),
      'Paseo External',
    );
  });
}
