import 'package:agent_daemon/src/server/agent_mcp_tools.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('curateAgentActivity', () {
    test('renders Paseo labels for messages, tools, tasks, and errors', () {
      final result = curateAgentActivity([
        const UserMessageItem(id: 'u', text: 'Fix it'),
        const ReasoningItem(id: 'r', text: 'Checking', complete: true),
        const ToolCallItem(
          id: 't',
          toolName: 'read',
          status: ToolCallStatus.success,
          detail: ReadDetail(path: 'lib/main.dart'),
        ),
        const TodoItem(
          id: 'todo',
          items: [
            TodoEntry(text: 'Inspect', completed: true),
            TodoEntry(text: 'Patch', completed: false),
          ],
        ),
        const AssistantMessageItem(id: 'a', text: 'Done', complete: true),
        const ErrorItem(id: 'e', message: 'boom'),
        const CompactionItem(id: 'c', status: CompactionStatus.completed),
      ]);

      expect(
        result,
        '[User] Fix it\n\n'
        '[Thought] Checking\n\n'
        '[Read] lib/main.dart\n\n'
        '[Tasks]\n- [x] Inspect\n- [ ] Patch\n\n'
        'Done\n\n'
        '[Error] boom\n\n'
        '[Compacted]',
      );
    });

    test('collapses tool lifecycle updates and handles empty activity', () {
      expect(curateAgentActivity(const []), 'No activity to display.');
      expect(
        curateAgentActivity(const [
          ToolCallItem(
            id: 'shell',
            toolName: 'bash',
            status: ToolCallStatus.running,
            detail: GenericDetail(input: {}),
          ),
          ToolCallItem(
            id: 'shell',
            toolName: 'bash',
            status: ToolCallStatus.success,
            detail: ShellDetail(command: 'dart test'),
          ),
        ]),
        '[Shell] dart test',
      );
    });
  });
}
