import 'package:coding_agent_app/providers/acp_provider_catalog.dart';
import 'package:coding_agent_app/widgets/provider_catalog_list.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const amp = AcpProviderCatalogEntry(
    id: 'amp-acp',
    title: 'Amp',
    description: 'Frontier coding agent',
    version: '0.7.0',
    iconName: 'amp-acp',
    installLink: 'https://example.com/amp',
    command: ['amp-acp'],
  );
  const devin = AcpProviderCatalogEntry(
    id: 'devin',
    title: 'Devin CLI',
    description: 'Cognition terminal agent',
    version: 'manual',
    iconName: null,
    installLink: 'https://example.com/devin',
    command: ['devin', 'acp'],
  );

  testWidgets('filters installed providers and searches all catalog fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        home: SingleChildScrollView(
          child: ProviderCatalogList(
            entries: const [amp, devin],
            installedProviderIds: const {'amp-acp'},
            installingProviderId: null,
            onInstall: (_) {},
            onOpenInstallInstructions: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Amp'), findsNothing);
    expect(find.text('Devin CLI'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('provider-catalog-search')),
      'unknown',
    );
    await tester.pump();
    expect(find.text('No providers found'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('provider-catalog-search')),
      'cognition',
    );
    await tester.pump();
    expect(find.text('Devin CLI'), findsOneWidget);
  });

  testWidgets('dispatches install and instruction actions', (tester) async {
    AcpProviderCatalogEntry? installed;
    AcpProviderCatalogEntry? opened;
    await tester.pumpWidget(
      FluentApp(
        home: SingleChildScrollView(
          child: ProviderCatalogList(
            entries: const [amp],
            installedProviderIds: const {},
            installingProviderId: null,
            onInstall: (entry) => installed = entry,
            onOpenInstallInstructions: (entry) => opened = entry,
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('provider-install-link-amp-acp')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(opened, same(amp));
    await tester.tap(find.byKey(const ValueKey('install-provider-amp-acp')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(installed, same(amp));
  });

  testWidgets('shows progress and disables the active provider action', (
    tester,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        home: ProviderCatalogList(
          entries: const [amp],
          installedProviderIds: const {},
          installingProviderId: 'amp-acp',
          onInstall: (_) {},
          onOpenInstallInstructions: (_) {},
        ),
      ),
    );

    expect(find.text('Adding'), findsOneWidget);
    final button = tester.widget<Button>(
      find.byKey(const ValueKey('install-provider-amp-acp')),
    );
    expect(button.onPressed, isNull);
  });
}
