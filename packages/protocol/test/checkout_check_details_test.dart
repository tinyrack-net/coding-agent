import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('modern and legacy requests pair with their response types', () {
    for (final type in const [
      CheckoutForgeGetCheckDetailsRequest.modernType,
      CheckoutForgeGetCheckDetailsRequest.legacyGithubType,
    ]) {
      final request = CheckoutForgeGetCheckDetailsRequest(
        type: type,
        cwd: '/repo',
        repoOwner: 'acme',
        repoName: 'repo',
        checkRunId: 1,
        workflowRunId: 2,
        changeRequestNumber: 3,
        requestId: 'd1',
      );
      final decoded = CheckoutForgeGetCheckDetailsRequest.fromJson(
        request.toJson(),
      );
      expect(decoded.toJson(), request.toJson());
      expect(
        decoded.responseType,
        type == CheckoutForgeGetCheckDetailsRequest.modernType
            ? CheckoutForgeGetCheckDetailsResponse.modernType
            : CheckoutForgeGetCheckDetailsResponse.legacyGithubType,
      );
    }
  });

  test('details round-trip annotations, failed jobs, and pipeline tree', () {
    const details = CheckoutCheckDetails(
      checkRunId: 1,
      workflowRunId: 2,
      name: 'build',
      status: 'completed',
      conclusion: 'failure',
      url: 'u',
      detailsUrl: 'd',
      output: {'title': 'Failed', 'summary': 'summary', 'text': null},
      annotations: [
        CheckoutCheckAnnotation(
          path: 'lib/a.dart',
          startLine: 2,
          endLine: 3,
          annotationLevel: 'failure',
          message: 'bad',
          title: 'Lint',
          rawDetails: 'raw',
        ),
      ],
      failedJobs: [
        CheckoutCheckFailedJob(
          jobId: 3,
          name: 'test',
          status: 'completed',
          conclusion: 'failure',
          url: 'j',
          logTail: 'tail',
          logTruncated: true,
        ),
      ],
      truncated: true,
      pipeline: CheckoutPipeline(
        id: 4,
        status: 'failed',
        rawStatus: 'failed',
        url: 'p',
        ref: 'feature',
        sha: 'abc',
        stages: [
          CheckoutPipelineStage(
            name: 'test',
            status: 'failed',
            jobs: [
              CheckoutPipelineJob(
                id: 5,
                name: 'unit',
                stage: 'test',
                status: 'failed',
                rawStatus: 'failed',
                url: null,
                allowFailure: false,
                durationSeconds: 4.5,
              ),
            ],
          ),
        ],
      ),
    );
    const response = CheckoutForgeGetCheckDetailsResponse(
      type: CheckoutForgeGetCheckDetailsResponse.modernType,
      cwd: '/repo',
      success: true,
      details: details,
      error: null,
      requestId: 'd2',
    );
    expect(
      CheckoutForgeGetCheckDetailsResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
  });

  test('optional collections and pipeline fields apply frozen defaults', () {
    final details = CheckoutCheckDetails.fromJson({
      'checkRunId': 1,
      'name': 'check',
      'pipeline': {
        'id': 2,
        'status': 'success',
        'rawStatus': 'success',
        'stages': [
          {'name': 'build', 'status': 'success'},
        ],
      },
    });
    expect(details.annotations, isEmpty);
    expect(details.failedJobs, isEmpty);
    expect(details.truncated, isFalse);
    expect(details.pipeline?.url, isNull);
    expect(details.pipeline?.stages.single.jobs, isEmpty);
  });

  test('check output strips unknown fields and validates nullable strings', () {
    final details = CheckoutCheckDetails.fromJson({
      'checkRunId': 1,
      'name': 'check',
      'output': {
        'title': 'Title',
        'summary': null,
        'text': 'Text',
        'futureField': 'ignored',
      },
    });
    expect(details.output, {'title': 'Title', 'summary': null, 'text': 'Text'});
    expect(
      () => CheckoutCheckDetails.fromJson({
        'checkRunId': 1,
        'name': 'check',
        'output': {'title': 1},
      }),
      throwsFormatException,
    );
  });

  test('invalid types, ids, and repository segments are rejected', () {
    expect(
      () => CheckoutForgeGetCheckDetailsRequest.fromJson({'type': 'future'}),
      throwsFormatException,
    );
    expect(
      () => CheckoutForgeGetCheckDetailsRequest.fromJson({
        'type': CheckoutForgeGetCheckDetailsRequest.modernType,
        'cwd': '/repo',
        'repoOwner': 'bad/owner',
        'checkRunId': 0,
        'requestId': 'd',
      }),
      throwsFormatException,
    );
    expect(
      () => CheckoutForgeGetCheckDetailsResponse.fromJson({
        'type': CheckoutForgeGetCheckDetailsResponse.modernType,
        'payload': {
          'cwd': '/repo',
          'success': 'yes',
          'error': null,
          'requestId': 'd',
        },
      }),
      throwsFormatException,
    );
  });
}
