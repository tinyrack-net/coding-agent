import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('diagnostics messages match the Paseo envelope', () {
    const request = DiagnosticsRequest(requestId: 'diagnostic-1');
    expect(
      DiagnosticsRequest.fromJson(request.toJson()).requestId,
      'diagnostic-1',
    );

    const response = DiagnosticsResponse(
      requestId: 'diagnostic-1',
      diagnostic: 'Tinyrack diagnostics\n  PID: 1',
    );
    expect(
      DiagnosticsResponse.fromJson(response.toJson()).diagnostic,
      contains('PID: 1'),
    );
  });

  test('diagnostics messages reject malformed boundaries', () {
    expect(
      () => DiagnosticsRequest.fromJson({
        'type': DiagnosticsRequest.type,
        'requestId': 1,
      }),
      throwsFormatException,
    );
    expect(
      () => DiagnosticsResponse.fromJson({
        'type': DiagnosticsResponse.type,
        'payload': {'requestId': 'id', 'diagnostic': null},
      }),
      throwsFormatException,
    );
  });
}
