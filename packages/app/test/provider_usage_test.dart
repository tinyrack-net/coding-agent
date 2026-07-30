import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/widgets/provider_usage.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('usage formatting and frozen fallback thresholds match Paseo', () {
    expect(deriveProviderUsageTone(null), ProviderUsageTone.defaultTone);
    expect(deriveProviderUsageTone(69.9), ProviderUsageTone.defaultTone);
    expect(deriveProviderUsageTone(70), ProviderUsageTone.warning);
    expect(deriveProviderUsageTone(90), ProviderUsageTone.warning);
    expect(deriveProviderUsageTone(90.1), ProviderUsageTone.danger);
    expect(formatProviderUsagePct(-2), '0%');
    expect(formatProviderUsagePct(75.6), '76%');
    expect(formatProviderUsagePct(120), '100%');
    expect(
      formatProviderUsageReset(
        '2026-07-22T14:30:00.000Z',
        now: DateTime.utc(2026, 7, 22, 12),
      ),
      'resets 2h',
    );
  });

  test('window and balance percentages use frozen precedence', () {
    expect(
      resolveProviderUsageWindowPct(
        const ProviderUsageWindow(
          id: 'session',
          label: 'Session',
          usedPct: 75,
          remainingPct: 2,
        ),
      ),
      75,
    );
    expect(
      resolveProviderUsageWindowPct(
        const ProviderUsageWindow(
          id: 'weekly',
          label: 'Weekly',
          remainingPct: 4,
        ),
      ),
      96,
    );
    expect(
      resolveProviderUsageBalancePct(
        const ProviderUsageBalance(
          id: 'credits',
          label: 'Credits',
          remaining: 4,
          limit: 100,
          unit: ProviderUsageBalanceUnit.credits,
        ),
      ),
      96,
    );
  });

  testWidgets('warning and danger usage bars use semantic status colors', (
    tester,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: Column(
            children: const [
              ProviderUsageWindowBar(
                window: ProviderUsageWindow(
                  id: 'session',
                  label: 'Session',
                  usedPct: 70,
                ),
              ),
              ProviderUsageWindowBar(
                window: ProviderUsageWindow(
                  id: 'weekly',
                  label: 'Weekly',
                  usedPct: 91,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Color fillColor(String label) {
      final container = tester.widget<Container>(
        find.byKey(ValueKey('provider-usage-fill-$label')),
      );
      return (container.decoration! as BoxDecoration).color!;
    }

    final context = tester.element(find.byType(ScaffoldPage));
    expect(fillColor('Session'), context.statusColors.warning);
    expect(fillColor('Weekly'), context.statusColors.danger);
    expect(find.text('70%'), findsOneWidget);
    expect(find.text('91%'), findsOneWidget);
  });

  testWidgets('card preserves labels, status, risk, and reset copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      FluentApp(
        home: ScaffoldPage(
          content: ProviderUsageCard(
            usage: ProviderUsage(
              providerId: 'codex',
              displayName: 'Codex',
              status: ProviderUsageStatus.available,
              planLabel: 'Plus',
              sourceLabel: 'ChatGPT',
              windows: [
                ProviderUsageWindow(
                  id: 'weekly',
                  label: 'Weekly',
                  usedPct: 96,
                  resetsAt: DateTime.now()
                      .toUtc()
                      .add(const Duration(days: 2))
                      .toIso8601String(),
                  tone: ProviderUsageTone.danger,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Plus'), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.textContaining('96% · resets'), findsOneWidget);
    expect(find.text('ChatGPT'), findsOneWidget);
  });
}
