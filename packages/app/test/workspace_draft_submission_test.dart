import 'package:coding_agent_app/composer/workspace_draft_submission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'allows a ready provider with no models and rejects a missing model',
    () {
      expect(
        validateDraftSubmission(
          text: 'hello',
          allowsEmptyAutoSubmit: false,
          providerCount: 1,
          selectedProvider: 'codewhale',
          isModelLoading: false,
          effectiveModelId: '',
          availableModels: const [],
          workspaceDirectory: '/repo',
          hasClient: true,
        ),
        isNull,
      );
      expect(
        validateDraftSubmission(
          text: 'hello',
          allowsEmptyAutoSubmit: false,
          providerCount: 1,
          selectedProvider: 'codex',
          isModelLoading: false,
          effectiveModelId: '',
          availableModels: const [Object()],
          workspaceDirectory: '/repo',
          hasClient: true,
        ),
        'No model is available for the selected provider',
      );
    },
  );

  test('attachment and auto-submit drafts may have empty text', () {
    expect(
      shouldAllowEmptyDraftText(
        allowsEmptyAutoSubmit: false,
        attachments: const [Object()],
      ),
      isTrue,
    );
    expect(
      shouldAllowEmptyDraftText(
        allowsEmptyAutoSubmit: true,
        attachments: const [],
      ),
      isTrue,
    );
    expect(
      shouldAllowEmptyDraftText(
        allowsEmptyAutoSubmit: false,
        attachments: const [],
      ),
      isFalse,
    );
  });
}
