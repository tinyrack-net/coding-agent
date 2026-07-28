import 'dart:math';

abstract interface class HubRelationshipRetryPolicy {
  Duration delay(int attempt);
}

final class BoundedExponentialHubRetryPolicy
    implements HubRelationshipRetryPolicy {
  BoundedExponentialHubRetryPolicy({double Function()? random})
    : _random = random ?? Random.secure().nextDouble;

  final double Function() _random;

  @override
  Duration delay(int attempt) {
    final exponent = attempt.clamp(0, 30);
    final baseMs = min(30000, 500 * pow(2, exponent).toInt());
    final jitter = 0.75 + _random() * 0.5;
    return Duration(milliseconds: max(1, (baseMs * jitter).round()));
  }
}
