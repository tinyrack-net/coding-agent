import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('checkout refresh request matches the frozen wire contract', () {
    const request = CheckoutRefreshRequest(
      cwd: '/repo',
      requestId: 'refresh-1',
    );

    expect(request.toJson(), {
      'type': 'checkout.refresh.request',
      'cwd': '/repo',
      'requestId': 'refresh-1',
    });
    expect(
      CheckoutRefreshRequest.fromJson(request.toJson()).toJson(),
      request.toJson(),
    );
    expect(
      () => CheckoutRefreshRequest.fromJson({
        ...request.toJson(),
        'type': 'checkout_refresh_request',
      }),
      throwsFormatException,
    );
    expect(
      () => CheckoutRefreshRequest.fromJson({
        'type': CheckoutRefreshRequest.type,
        'cwd': 7,
        'requestId': 'refresh-2',
      }),
      throwsFormatException,
    );
  });

  test('checkout refresh response preserves success and checkout errors', () {
    const success = CheckoutRefreshResponse(
      cwd: '/repo',
      success: true,
      error: null,
      requestId: 'refresh-1',
    );
    const failure = CheckoutRefreshResponse(
      cwd: '/repo',
      success: false,
      error: CheckoutError(
        code: CheckoutErrorCode.notGitRepo,
        message: 'not a git repository',
      ),
      requestId: 'refresh-2',
    );

    expect(
      CheckoutRefreshResponse.fromJson(success.toJson()).toJson(),
      success.toJson(),
    );
    expect(
      CheckoutRefreshResponse.fromJson(failure.toJson()).toJson(),
      failure.toJson(),
    );
    expect(
      () => CheckoutRefreshResponse.fromJson({
        'type': CheckoutRefreshResponse.type,
        'payload': {
          'cwd': '/repo',
          'success': 'yes',
          'error': null,
          'requestId': 'refresh-3',
        },
      }),
      throwsFormatException,
    );
    expect(
      () => CheckoutRefreshResponse.fromJson({
        'type': CheckoutRefreshResponse.type,
        'payload': const [],
      }),
      throwsFormatException,
    );
    expect(
      () => CheckoutRefreshResponse.fromJson({
        'type': CheckoutRefreshResponse.type,
        'payload': {'cwd': '/repo', 'success': true, 'requestId': 'refresh-4'},
      }),
      throwsFormatException,
    );
  });
}
