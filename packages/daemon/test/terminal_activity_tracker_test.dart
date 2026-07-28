import 'package:agent_daemon/src/terminal/terminal_activity_tracker.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late int now;
  late TerminalActivityTracker tracker;

  setUp(() {
    now = 100;
    tracker = TerminalActivityTracker(now: () => now);
  });

  tearDown(() => tracker.dispose());

  test('starts unknown and clear is an unchanged no-op', () {
    expect(tracker.activity, isNull);
    expect(tracker.clear(), isFalse);
  });

  test('working to idle becomes durable finished attention', () {
    expect(tracker.set(TerminalActivityState.working), isTrue);
    expect(tracker.activity?.toJson(), {'state': 'working', 'changedAt': 100});

    now = 200;
    expect(tracker.set(TerminalActivityState.idle), isTrue);
    expect(tracker.activity?.toJson(), {
      'state': 'idle',
      'attentionReason': 'finished',
      'changedAt': 200,
    });

    now = 300;
    expect(tracker.set(TerminalActivityState.idle), isFalse);
    expect(tracker.activity?.changedAt, 200);
  });

  test('attention becomes needs-input and clears to idle', () {
    expect(tracker.set(TerminalActivityState.attention), isTrue);
    expect(tracker.activity?.state, TerminalActivityState.idle);
    expect(
      tracker.activity?.attentionReason,
      TerminalActivityAttentionReason.needsInput,
    );

    now = 200;
    expect(tracker.clearAttention(), isTrue);
    expect(tracker.activity?.toJson(), {'state': 'idle', 'changedAt': 200});
    expect(tracker.clearAttention(), isFalse);
  });

  test('listeners receive exact previous values and can unsubscribe', () {
    final transitions = <(TerminalActivity?, TerminalActivity?)>[];
    final unsubscribe = tracker.onChange(
      (activity, previous) => transitions.add((activity, previous)),
    );

    tracker.set(TerminalActivityState.working);
    now = 200;
    tracker.clear();
    unsubscribe();
    tracker.set(TerminalActivityState.attention);

    expect(transitions, hasLength(2));
    expect(transitions[0].$1?.state, TerminalActivityState.working);
    expect(transitions[0].$2, isNull);
    expect(transitions[1].$1, isNull);
    expect(transitions[1].$2, same(transitions[0].$1));
  });

  test('dispose removes listeners without disabling state changes', () {
    var changes = 0;
    tracker.onChange((_, __) => changes++);
    tracker.dispose();

    expect(tracker.set(TerminalActivityState.working), isTrue);
    expect(changes, 0);
  });
}
