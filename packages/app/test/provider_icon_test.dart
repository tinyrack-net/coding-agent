import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/assets/acp_provider_icons.dart';
import 'package:coding_agent_app/providers/provider_icon_name.dart';
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
            ProviderIcon(provider: 'agy', size: 16, color: Colors.white),
            ProviderIcon(provider: 'CLAUDE', size: 16, color: Colors.white),
          ],
        ),
      ),
    );

    expect(find.byIcon(FluentIcons.package), findsOneWidget);
    expect(find.byIcon(FluentIcons.robot), findsNWidgets(3));
  });

  testWidgets('renders every frozen ACP provider catalog SVG', (tester) async {
    expect(acpProviderIconNames, hasLength(33));
    expect(acpProviderIconSvgs, hasLength(38));
    expect(acpProviderIconNames.every(acpProviderIconSvgs.containsKey), isTrue);

    for (final provider in acpProviderIconNames) {
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

  test(
    'resolves built-in, catalog, terminal-only, and unknown names exactly',
    () {
      for (final provider in builtinProviderIconNames) {
        final resolved = resolveProviderIconName(provider);
        expect(resolved.kind, ProviderIconNameKind.builtin, reason: provider);
        expect(resolved.id, provider, reason: provider);
      }
      for (final provider in acpProviderIconNames) {
        final resolved = resolveProviderIconName(provider);
        expect(resolved.kind, ProviderIconNameKind.catalog, reason: provider);
        expect(resolved.id, provider, reason: provider);
      }

      expect(resolveProviderIconName('agy').kind, ProviderIconNameKind.catalog);
      expect(resolveProviderIconName('custom').kind, ProviderIconNameKind.bot);
      expect(resolveProviderIconName('CLAUDE').kind, ProviderIconNameKind.bot);
    },
  );
}
