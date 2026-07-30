import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('provider usage list round-trips the frozen Paseo wire shape', () {
    const response = ProviderUsageListResponse(
      requestId: 'usage-1',
      fetchedAt: '2026-07-22T12:00:00.000Z',
      providers: [
        ProviderUsage(
          providerId: 'codex',
          displayName: 'Codex',
          status: ProviderUsageStatus.available,
          planLabel: 'Plus',
          sourceLabel: 'ChatGPT',
          fetchedAt: '2026-07-22T11:59:00.000Z',
          windows: [
            ProviderUsageWindow(
              id: 'weekly',
              label: 'Weekly',
              usedPct: 96,
              remainingPct: 4,
              resetsAt: '2026-07-29T12:00:00.000Z',
              tone: ProviderUsageTone.danger,
            ),
          ],
          balances: [
            ProviderUsageBalance(
              id: 'credits',
              label: 'Credits',
              remaining: 3,
              unit: ProviderUsageBalanceUnit.credits,
              tone: ProviderUsageTone.ok,
            ),
          ],
          details: [
            ProviderUsageDetail(
              id: 'account',
              label: 'Account',
              value: 'Personal',
            ),
          ],
        ),
      ],
    );

    final json = response.toJson();
    expect(json['type'], ProviderUsageListResponse.type);
    expect((json['payload'] as Map)['providers'], hasLength(1));
    final decoded = ProviderUsageListResponse.fromJson(json);
    expect(decoded.requestId, 'usage-1');
    expect(decoded.providers.single.windows.single.label, 'Weekly');
    expect(
      decoded.providers.single.windows.single.tone,
      ProviderUsageTone.danger,
    );
    expect(
      decoded.providers.single.balances.single.unit,
      ProviderUsageBalanceUnit.credits,
    );
  });

  test('provider usage rejects unknown states and non-finite numbers', () {
    final base = <String, Object?>{
      'providerId': 'claude',
      'displayName': 'Claude',
      'status': 'available',
      'planLabel': null,
      'windows': <Object?>[],
    };

    expect(
      () => ProviderUsage.fromJson({...base, 'status': 'ready'}),
      throwsFormatException,
    );
    expect(
      () => ProviderUsageWindow.fromJson({
        'id': 'session',
        'label': 'Session',
        'usedPct': double.infinity,
      }),
      throwsFormatException,
    );
    expect(() => ProviderUsageTone.fromWire('critical'), throwsFormatException);
  });
}
