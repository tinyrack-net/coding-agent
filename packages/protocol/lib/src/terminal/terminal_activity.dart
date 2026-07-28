enum TerminalActivityState {
  idle,
  working,
  attention;

  static TerminalActivityState fromWire(Object? value) => switch (value) {
    'working' => working,
    'attention' => attention,
    _ => idle,
  };
}

enum TerminalActivityAttentionReason {
  finished('finished'),
  needsInput('needs_input');

  const TerminalActivityAttentionReason(this.wireValue);
  final String wireValue;

  static TerminalActivityAttentionReason? fromWire(Object? value) =>
      switch (value) {
        'finished' => finished,
        'needs_input' => needsInput,
        _ => null,
      };
}

enum TerminalActivityStatusBucket {
  running('running'),
  needsInput('needs_input'),
  attention('attention');

  const TerminalActivityStatusBucket(this.wireValue);
  final String wireValue;
}

final class TerminalActivity {
  const TerminalActivity({
    required this.state,
    required this.changedAt,
    this.attentionReason,
  });

  final TerminalActivityState state;
  final TerminalActivityAttentionReason? attentionReason;
  final num changedAt;

  factory TerminalActivity.fromJson(Map<String, Object?> json) {
    final changedAt = json['changedAt'];
    if (changedAt is! num) {
      throw const FormatException('changedAt must be a number');
    }
    return TerminalActivity(
      state: TerminalActivityState.fromWire(json['state']),
      changedAt: changedAt,
      attentionReason: TerminalActivityAttentionReason.fromWire(
        json['attentionReason'],
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'state': state.name,
    if (attentionReason != null) 'attentionReason': attentionReason!.wireValue,
    'changedAt': changedAt,
  };
}

TerminalActivityStatusBucket? deriveTerminalActivityStatusBucket(
  TerminalActivity? activity,
) {
  if (activity == null) return null;
  if (activity.attentionReason == TerminalActivityAttentionReason.needsInput) {
    return TerminalActivityStatusBucket.needsInput;
  }
  if (activity.attentionReason == TerminalActivityAttentionReason.finished) {
    return TerminalActivityStatusBucket.attention;
  }
  if (activity.state == TerminalActivityState.working) {
    return TerminalActivityStatusBucket.running;
  }
  if (activity.state == TerminalActivityState.attention) {
    return TerminalActivityStatusBucket.needsInput;
  }
  return null;
}
