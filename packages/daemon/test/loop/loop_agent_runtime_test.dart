import 'package:agent_daemon/src/loop/loop_agent_runtime.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('curates every frozen single-item activity kind', () {
    expect(
      renderLoopTimelineActivity(
        const UserMessageItem(id: 'u', text: '  hello  '),
      ),
      '[User] hello',
    );
    expect(
      renderLoopTimelineActivity(
        const AssistantMessageItem(id: 'a', text: ' answer ', complete: true),
      ),
      'answer',
    );
    expect(
      renderLoopTimelineActivity(
        const ReasoningItem(id: 'r', text: ' think ', complete: true),
      ),
      '[Thought] think',
    );
    expect(
      renderLoopTimelineActivity(
        const TodoItem(
          id: 'todo',
          items: [
            TodoEntry(text: 'one', completed: false),
            TodoEntry(text: 'two', completed: true),
          ],
        ),
      ),
      '[Tasks]\n- [ ] one\n- [x] two',
    );
    expect(
      renderLoopTimelineActivity(const ErrorItem(id: 'e', message: 'bad')),
      '[Error] bad',
    );
    expect(
      renderLoopTimelineActivity(
        const CompactionItem(id: 'c', status: CompactionStatus.completed),
      ),
      '[Compacted]',
    );
    expect(
      renderLoopTimelineActivity(
        const TurnItem(id: 'turn', phase: TurnPhase.completed),
      ),
      isNull,
    );
  });

  test('matches canonical, external, and subagent tool display rules', () {
    expect(
      renderLoopTimelineActivity(
        const ToolCallItem(
          id: 'shell',
          toolName: 'bash',
          status: ToolCallStatus.success,
          detail: ShellDetail(command: 'dart test'),
        ),
      ),
      '[Shell] dart test',
    );
    expect(
      renderLoopTimelineActivity(
        const ToolCallItem(
          id: 'external',
          toolName: 'mcp__github__search',
          status: ToolCallStatus.running,
          detail: GenericDetail(input: {'query': 'paseo'}),
        ),
      ),
      '[mcp__github__search] {"query":"paseo"}',
    );
    expect(
      renderLoopTimelineActivity(
        const ToolCallItem(
          id: 'paseo',
          toolName: 'mcp__paseo__create_workspace',
          status: ToolCallStatus.success,
          detail: GenericDetail(input: {}),
        ),
      ),
      '[Create Workspace] {}',
    );
    expect(
      renderLoopTimelineActivity(
        const ToolCallItem(
          id: 'task',
          toolName: 'Task',
          status: ToolCallStatus.success,
          detail: SubAgentDetail(
            subAgentType: 'Explore',
            description: 'Find files',
            log: 'read a.dart',
          ),
        ),
      ),
      '[Explore] Find files\nread a.dart',
    );
    expect(
      renderLoopTimelineActivity(
        const ToolCallItem(
          id: 'thinking',
          toolName: 'thinking',
          status: ToolCallStatus.running,
          detail: GenericDetail(input: {}),
        ),
      ),
      '[Thinking]',
    );
  });

  test('normalizes and truncates tool summaries at frozen limits', () {
    final rendered = renderLoopTimelineActivity(
      ToolCallItem(
        id: 'search',
        toolName: 'search',
        status: ToolCallStatus.success,
        detail: SearchDetail(
          query:
              '${List.filled(100, 'x').join()}\n'
              '${List.filled(110, 'y').join()}',
        ),
      ),
    )!;

    expect(rendered, startsWith('[Search] '));
    expect(rendered.substring('[Search] '.length), hasLength(200));
    expect(rendered, endsWith('...'));
    expect(rendered, isNot(contains('\n')));
  });
}
