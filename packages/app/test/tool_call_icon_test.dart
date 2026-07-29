import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/tool_calls/tool_call_icon.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps every canonical detail kind to the frozen semantic icon', () {
    expect(
      resolveToolCallIconName('shell', const ShellDetail(command: 'pwd')),
      ToolCallIconName.squareTerminal,
    );
    expect(
      resolveToolCallIconName('read', const ReadDetail(path: 'README.md')),
      ToolCallIconName.eye,
    );
    expect(
      resolveToolCallIconName('edit', const EditDetail(path: 'README.md')),
      ToolCallIconName.pencil,
    );
    expect(
      resolveToolCallIconName('write', const WriteDetail(path: 'README.md')),
      ToolCallIconName.pencil,
    );
    expect(
      resolveToolCallIconName('grep', const SearchDetail(query: 'TODO')),
      ToolCallIconName.search,
    );
    expect(
      resolveToolCallIconName(
        'fetch',
        const FetchDetail(url: 'https://example.com'),
      ),
      ToolCallIconName.search,
    );
    expect(
      resolveToolCallIconName(
        'setup',
        const WorktreeSetupToolDetail(
          worktreePath: '',
          branchName: '',
          log: '',
          commands: [],
        ),
      ),
      ToolCallIconName.squareTerminal,
    );
    expect(
      resolveToolCallIconName('subagent', const SubAgentDetail()),
      ToolCallIconName.bot,
    );
    expect(
      resolveToolCallIconName('plain', const PlainTextDetail()),
      ToolCallIconName.wrench,
    );
    expect(
      resolveToolCallIconName('plan', const PlanDetail(text: 'ship')),
      ToolCallIconName.brain,
    );
    expect(
      resolveToolCallIconName('unknown', const GenericDetail(input: {})),
      ToolCallIconName.wrench,
    );
    expect(resolveToolCallIconName('unknown', null), ToolCallIconName.wrench);
  });

  test('applies frozen tool-name and custom icon overrides in order', () {
    expect(
      resolveToolCallIconName('Task', const GenericDetail(input: {})),
      ToolCallIconName.bot,
    );
    expect(resolveToolCallIconName('Task', null), ToolCallIconName.bot);
    expect(
      resolveToolCallIconName('thinking', const GenericDetail(input: {})),
      ToolCallIconName.brain,
    );
    expect(
      resolveToolCallIconName('thinking', const ReadDetail(path: 'a')),
      ToolCallIconName.eye,
    );
    expect(
      resolveToolCallIconName('speak', const ReadDetail(path: 'a')),
      ToolCallIconName.micVocal,
    );
    expect(
      resolveToolCallIconName(
        'custom_tool',
        const PlainTextDetail(icon: 'sparkles'),
      ),
      ToolCallIconName.sparkles,
    );
    expect(
      resolveToolCallIconName(
        'skill',
        const PlainTextDetail(label: 'Skill output'),
      ),
      ToolCallIconName.wrench,
    );
    expect(
      resolveToolCallIconName(
        'custom_tool',
        const PlainTextDetail(icon: 'not-an-icon'),
      ),
      ToolCallIconName.wrench,
    );
  });

  test('recognizes frozen Paseo wire tool names as Tinyrack branded tools', () {
    expect(
      resolveToolCallIconName('paseo.workspace.list', null),
      ToolCallIconName.tinyrack,
    );
    expect(
      resolveToolCallIconName('mcp__paseo__create_agent', null),
      ToolCallIconName.tinyrack,
    );
    expect(
      resolveToolCallIconName('speak', null),
      isNot(ToolCallIconName.tinyrack),
    );
  });

  test('maps semantic names to stable Fluent icons', () {
    expect(iconDataForToolCallIcon(ToolCallIconName.wrench), FluentIcons.build);
    expect(
      iconDataForToolCallIcon(ToolCallIconName.squareTerminal),
      FluentIcons.command_prompt,
    );
    expect(iconDataForToolCallIcon(ToolCallIconName.eye), FluentIcons.view);
    expect(iconDataForToolCallIcon(ToolCallIconName.pencil), FluentIcons.edit);
    expect(
      iconDataForToolCallIcon(ToolCallIconName.search),
      FluentIcons.search,
    );
    expect(iconDataForToolCallIcon(ToolCallIconName.bot), FluentIcons.robot);
    expect(
      iconDataForToolCallIcon(ToolCallIconName.sparkles),
      FluentIcons.starburst,
    );
    expect(
      iconDataForToolCallIcon(ToolCallIconName.brain),
      FluentIcons.processing,
    );
    expect(
      iconDataForToolCallIcon(ToolCallIconName.micVocal),
      FluentIcons.microphone,
    );
    expect(iconDataForToolCallIcon(ToolCallIconName.tinyrack), isNull);
  });

  testWidgets('renders the Tinyrack branded asset for internal wire tools', (
    tester,
  ) async {
    await tester.pumpWidget(
      const FluentApp(
        home: ToolCallIconView(name: ToolCallIconName.tinyrack, size: 18),
      ),
    );

    expect(find.bySemanticsLabel('Tinyrack'), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 18);
    expect(image.height, 18);
    expect((image.image as AssetImage).assetName, 'assets/tray/tray_icon.png');
  });
}
