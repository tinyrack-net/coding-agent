import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('checkout PR create request and response match Paseo wire shape', () {
    final request = CheckoutPrCreateRequest.fromJson({
      'type': 'checkout_pr_create_request',
      'cwd': '/repo',
      'title': 'Feature',
      'body': '',
      'baseRef': 'main',
      'requestId': 'create-1',
    });
    expect(request.toJson(), {
      'type': 'checkout_pr_create_request',
      'cwd': '/repo',
      'title': 'Feature',
      'body': '',
      'baseRef': 'main',
      'requestId': 'create-1',
    });

    const response = CheckoutPrCreateResponse(
      cwd: '/repo',
      url: 'https://github.com/acme/repo/pull/7',
      number: 7,
      error: null,
      requestId: 'create-1',
    );
    expect(CheckoutPrCreateResponse.fromJson(response.toJson()).number, 7);
    expect(response.toJson()['payload'], {
      'cwd': '/repo',
      'url': 'https://github.com/acme/repo/pull/7',
      'number': 7,
      'error': null,
      'requestId': 'create-1',
    });
  });

  test('checkout PR merge request, response, and errors are exact', () {
    final request = CheckoutPrMergeRequest.fromJson({
      'type': 'checkout_pr_merge_request',
      'cwd': '/repo',
      'mergeMethod': 'squash',
      'requestId': 'merge-1',
    });
    expect(request.mergeMethod, CheckoutPrMergeMethod.squash);
    expect(request.toJson()['mergeMethod'], 'squash');

    const response = CheckoutPrMergeResponse(
      cwd: '/repo',
      success: false,
      error: CheckoutError(
        code: CheckoutErrorCode.notAllowed,
        message: 'not ready',
      ),
      requestId: 'merge-1',
    );
    final parsed = CheckoutPrMergeResponse.fromJson(response.toJson());
    expect(parsed.success, isFalse);
    expect(parsed.error?.code, CheckoutErrorCode.notAllowed);
    expect(parsed.error?.message, 'not ready');
  });

  test('checkout PR schemas reject invalid enums and payload types', () {
    expect(
      () => CheckoutPrMergeRequest.fromJson({
        'type': 'checkout_pr_merge_request',
        'cwd': '/repo',
        'mergeMethod': 'octopus',
        'requestId': '1',
      }),
      throwsFormatException,
    );
    expect(
      () => CheckoutPrCreateResponse.fromJson({
        'type': 'checkout_pr_create_response',
        'payload': {'cwd': '/repo', 'url': null},
      }),
      throwsFormatException,
    );
    expect(
      () => CheckoutPrMergeResponse.fromJson({
        'type': 'checkout_pr_merge_response',
        'payload': {
          'cwd': '/repo',
          'success': true,
          'error': {'code': 'NOPE', 'message': 'bad'},
          'requestId': '1',
        },
      }),
      throwsFormatException,
    );
  });

  test('modern and legacy forge auto-merge envelopes stay paired', () {
    for (final type in const [
      CheckoutForgeSetAutoMergeRequest.modernType,
      CheckoutForgeSetAutoMergeRequest.legacyGithubType,
    ]) {
      final request = CheckoutForgeSetAutoMergeRequest.fromJson({
        'type': type,
        'cwd': '/repo',
        'enabled': true,
        'mergeMethod': 'rebase',
        'requestId': 'auto-1',
      });
      expect(request.mergeMethod, CheckoutPrMergeMethod.rebase);
      expect(request.toJson(), {
        'type': type,
        'cwd': '/repo',
        'enabled': true,
        'mergeMethod': 'rebase',
        'requestId': 'auto-1',
      });
      final response = CheckoutForgeSetAutoMergeResponse(
        type: request.responseType,
        cwd: request.cwd,
        enabled: request.enabled,
        success: true,
        error: null,
        requestId: request.requestId,
      );
      final parsed = CheckoutForgeSetAutoMergeResponse.fromJson(
        response.toJson(),
      );
      expect(parsed.type, request.responseType);
      expect(parsed.enabled, isTrue);
      expect(parsed.success, isTrue);
    }
  });

  test('forge auto-merge schemas reject unknown types and scalars', () {
    expect(
      () =>
          CheckoutForgeSetAutoMergeRequest.fromJson({'type': 'checkout.other'}),
      throwsFormatException,
    );
    expect(
      () => CheckoutForgeSetAutoMergeRequest.fromJson({
        'type': CheckoutForgeSetAutoMergeRequest.modernType,
        'cwd': '/repo',
        'enabled': 'yes',
        'requestId': '1',
      }),
      throwsFormatException,
    );
    expect(
      () => CheckoutForgeSetAutoMergeResponse.fromJson({
        'type': 'checkout.other',
        'payload': const {},
      }),
      throwsFormatException,
    );
  });
}
