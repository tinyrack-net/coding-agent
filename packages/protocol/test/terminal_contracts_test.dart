import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('terminal activity', () {
    test('degrades unknown future states and reasons', () {
      final activity = TerminalActivity.fromJson(const {
        'state': 'compacting',
        'attentionReason': 'future',
        'changedAt': 1718000000000,
      });
      expect(activity.state, TerminalActivityState.idle);
      expect(activity.attentionReason, isNull);
      expect(activity.changedAt, 1718000000000);
      expect(activity.toJson(), {'state': 'idle', 'changedAt': 1718000000000});
      expect(
        () => TerminalActivity.fromJson(const {
          'state': 'idle',
          'changedAt': 'now',
        }),
        throwsFormatException,
      );
    });

    test('derives workspace status buckets', () {
      expect(
        deriveTerminalActivityStatusBucket(
          const TerminalActivity(
            state: TerminalActivityState.working,
            changedAt: 1,
          ),
        ),
        TerminalActivityStatusBucket.running,
      );
      expect(
        deriveTerminalActivityStatusBucket(
          const TerminalActivity(
            state: TerminalActivityState.idle,
            attentionReason: TerminalActivityAttentionReason.finished,
            changedAt: 1,
          ),
        ),
        TerminalActivityStatusBucket.attention,
      );
      expect(
        deriveTerminalActivityStatusBucket(
          const TerminalActivity(
            state: TerminalActivityState.idle,
            attentionReason: TerminalActivityAttentionReason.needsInput,
            changedAt: 1,
          ),
        ),
        TerminalActivityStatusBucket.needsInput,
      );
      expect(
        deriveTerminalActivityStatusBucket(
          const TerminalActivity(
            state: TerminalActivityState.attention,
            changedAt: 1,
          ),
        ),
        TerminalActivityStatusBucket.needsInput,
      );
      expect(deriveTerminalActivityStatusBucket(null), isNull);
      expect(
        const TerminalActivity(
          state: TerminalActivityState.attention,
          attentionReason: TerminalActivityAttentionReason.needsInput,
          changedAt: 1,
        ).toJson(),
        {
          'state': 'attention',
          'attentionReason': 'needs_input',
          'changedAt': 1,
        },
      );
    });
  });

  group('terminal profiles', () {
    test('uses Paseo defaults only when profiles are absent', () {
      expect(resolveTerminalProfiles(null).map((profile) => profile.id), [
        'claude',
        'codex',
        'opencode',
      ]);
      expect(resolveTerminalProfiles(const []), isEmpty);
    });

    test('guesses provider icons from cross-platform commands', () {
      expect(guessTerminalProfileIcon('Claude'), 'claude');
      expect(guessTerminalProfileIcon('/usr/local/bin/gemini'), 'gemini');
      expect(
        guessTerminalProfileIcon(r'C:\Program Files\Codex\codex.exe'),
        'codex',
      );
      expect(guessTerminalProfileIcon('zsh'), isNull);
    });

    test('explicit icons override guesses', () {
      expect(
        getTerminalProfileIcon(
          const TerminalProfile(
            id: 'custom',
            name: 'Custom',
            command: 'zsh',
            icon: 'claude',
          ),
        ),
        'claude',
      );
    });

    test('profile JSON round-trips with and without icons', () {
      final profile = TerminalProfile.fromJson(const {
        'id': 'zsh',
        'name': 'Zsh',
        'command': 'zsh',
      });
      expect(profile.toJson(), {'id': 'zsh', 'name': 'Zsh', 'command': 'zsh'});
      expect(
        const TerminalProfile(
          id: 'codex',
          name: 'Codex',
          command: 'codex',
          icon: 'codex',
        ).toJson(),
        {'id': 'codex', 'name': 'Codex', 'command': 'codex', 'icon': 'codex'},
      );
    });
  });

  test('terminal subscription is scoped by workspace when present', () {
    expect(terminalSubscriptionKey('/repo', null), '/repo');
    expect(terminalSubscriptionKey('/repo', 'wks_123'), 'wks_123::/repo');
  });
}
