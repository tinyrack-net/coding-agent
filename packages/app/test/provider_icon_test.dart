import 'package:coding_agent_app/widgets/provider_icon.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders every frozen built-in provider SVG', (tester) async {
    for (final provider in const [
      'claude',
      'codex',
      'copilot',
      'minimax',
      'omp',
      'opencode',
      'pi',
    ]) {
      await tester.pumpWidget(
        FluentApp(
          home: Center(
            child: ProviderIcon(
              provider: provider,
              size: 16,
              color: Colors.white,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SvgPicture), findsOneWidget, reason: provider);
      expect(tester.takeException(), isNull, reason: provider);
    }
  });

  testWidgets('uses package and bot fallbacks for kiro and custom providers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const FluentApp(
        home: Row(
          children: [
            ProviderIcon(provider: 'kiro', size: 16, color: Colors.white),
            ProviderIcon(
              provider: 'custom-provider',
              size: 16,
              color: Colors.white,
            ),
          ],
        ),
      ),
    );

    expect(find.byIcon(FluentIcons.package), findsOneWidget);
    expect(find.byIcon(FluentIcons.robot), findsOneWidget);
  });
}
