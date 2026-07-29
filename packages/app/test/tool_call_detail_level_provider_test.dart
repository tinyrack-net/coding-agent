import 'package:coding_agent_app/state/tool_call_detail_level_provider.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_projection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'parses frozen defaults, valid values, invalid values, and legacy flag',
    () {
      expect(parseToolCallDetailLevel(), ToolCallDetailLevel.detailed);
      expect(
        parseToolCallDetailLevel(stored: 'detailed'),
        ToolCallDetailLevel.detailed,
      );
      expect(
        parseToolCallDetailLevel(stored: 'overview'),
        ToolCallDetailLevel.overview,
      );
      expect(
        parseToolCallDetailLevel(stored: 'concise'),
        ToolCallDetailLevel.overview,
      );
      expect(
        parseToolCallDetailLevel(legacyCompactToolCalls: true),
        ToolCallDetailLevel.overview,
      );
      expect(
        parseToolCallDetailLevel(legacyCompactToolCalls: false),
        ToolCallDetailLevel.detailed,
      );
    },
  );

  test('loads, updates, and migrates the persisted detail level', () async {
    SharedPreferences.setMockInitialValues({
      ToolCallDetailLevelNotifier.legacyPreferenceKey: true,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(toolCallDetailLevelProvider),
      ToolCallDetailLevel.detailed,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(toolCallDetailLevelProvider),
      ToolCallDetailLevel.overview,
    );

    await container
        .read(toolCallDetailLevelProvider.notifier)
        .setLevel(ToolCallDetailLevel.detailed);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(ToolCallDetailLevelNotifier.preferenceKey),
      'detailed',
    );
    expect(
      preferences.containsKey(ToolCallDetailLevelNotifier.legacyPreferenceKey),
      isFalse,
    );
  });
}
