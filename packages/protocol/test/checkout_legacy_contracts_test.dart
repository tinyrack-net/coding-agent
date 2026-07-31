import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('legacy checkout contracts', () {
    test('checkout commit request and response round-trip', () {
      final request = CheckoutCommitRequest(
        cwd: r'C:\repo',
        message: 'save changes',
        addAll: true,
        requestId: 'req-1',
      );
      expect(
        CheckoutCommitRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );

      final response = CheckoutCommitResponse(
        cwd: r'C:\repo',
        success: false,
        error: const CheckoutError(
          code: CheckoutErrorCode.mergeConflict,
          message: 'conflict',
        ),
        requestId: 'req-1',
      );
      expect(
        CheckoutCommitResponse.fromJson(response.toJson()).toJson(),
        response.toJson(),
      );
    });

    test('branch validation and suggestions preserve optional metadata', () {
      final validate = ValidateBranchRequest(
        cwd: '/repo',
        branchName: 'origin/feature',
        requestId: 'req-2',
      );
      expect(
        ValidateBranchRequest.fromJson(validate.toJson()).toJson(),
        validate.toJson(),
      );

      final suggestions = BranchSuggestionsResponse(
        branches: const ['main', 'feature'],
        branchDetails: const [
          BranchSuggestionDetail(
            name: 'main',
            committerDate: 1710000000,
            hasLocal: true,
            hasRemote: true,
          ),
        ],
        error: null,
        requestId: 'req-3',
      );
      expect(
        BranchSuggestionsResponse.fromJson(suggestions.toJson()).toJson(),
        suggestions.toJson(),
      );
      expect(
        () => BranchSuggestionsRequest.fromJson({
          'type': BranchSuggestionsRequest.type,
          'cwd': '/repo',
          'limit': 201,
          'requestId': 'req',
        }),
        throwsFormatException,
      );
    });

    test('stash request and response variants round-trip', () {
      final save = StashSaveRequest(
        cwd: '/repo',
        branch: 'feature',
        requestId: 'req-4',
      );
      final pop = StashPopRequest(
        cwd: '/repo',
        stashIndex: 0,
        requestId: 'req-5',
      );
      final list = StashListRequest(
        cwd: '/repo',
        paseoOnly: false,
        requestId: 'req-6',
      );
      expect(StashSaveRequest.fromJson(save.toJson()).toJson(), save.toJson());
      expect(StashPopRequest.fromJson(pop.toJson()).toJson(), pop.toJson());
      expect(StashListRequest.fromJson(list.toJson()).toJson(), list.toJson());

      final response = StashListResponse(
        cwd: '/repo',
        entries: const [
          StashEntry(
            index: 0,
            message: 'paseo: feature',
            branch: 'feature',
            isPaseo: true,
          ),
        ],
        error: null,
        requestId: 'req-6',
      );
      expect(
        StashListResponse.fromJson(response.toJson()).toJson(),
        response.toJson(),
      );
      expect(
        () => StashPopRequest.fromJson({
          'type': StashPopRequest.type,
          'cwd': '/repo',
          'stashIndex': -1,
          'requestId': 'req',
        }),
        throwsFormatException,
      );
    });
  });

  group('legacy editor bridge', () {
    test('editor listing and open request round-trip', () {
      final list = ListAvailableEditorsResponse(
        requestId: 'req-7',
        editors: const [AvailableEditor(id: 'vscode', label: 'VS Code')],
        error: null,
      );
      final open = OpenInEditorRequest(
        path: '/repo/lib/main.dart',
        editorId: 'vscode',
        mode: EditorOpenMode.reveal,
        cwd: '/repo',
        requestId: 'req-8',
      );
      final opened = OpenInEditorResponse(requestId: 'req-8', error: null);
      expect(
        ListAvailableEditorsResponse.fromJson(list.toJson()).toJson(),
        list.toJson(),
      );
      expect(
        OpenInEditorRequest.fromJson(open.toJson()).toJson(),
        open.toJson(),
      );
      expect(
        OpenInEditorResponse.fromJson(opened.toJson()).toJson(),
        opened.toJson(),
      );
      expect(
        () => OpenInEditorRequest.fromJson({
          'type': OpenInEditorRequest.type,
          'path': '/repo',
          'editorId': ' ',
          'requestId': 'req',
        }),
        throwsFormatException,
      );
    });
  });

  group('lifecycle and file-transfer contracts', () {
    test('resume, restart, and shutdown round-trip', () {
      final resume = ResumeAgentRequest(
        handle: const AgentPersistenceHandle(
          provider: 'claude',
          sessionId: 'session-1',
          nativeHandle: 'native-1',
          metadata: {'source': 'import'},
        ),
        overrides: const AgentSessionConfigOverrides(
          title: null,
          hasTitle: true,
          networkAccess: true,
        ),
        requestId: 'req-9',
      );
      final restart = RestartServerRequest(
        reason: 'config changed',
        requestId: 'req-10',
      );
      final shutdown = ShutdownServerRequest(requestId: 'req-11');
      expect(
        ResumeAgentRequest.fromJson(resume.toJson()).toJson(),
        resume.toJson(),
      );
      expect(
        RestartServerRequest.fromJson(restart.toJson()).toJson(),
        restart.toJson(),
      );
      expect(
        ShutdownServerRequest.fromJson(shutdown.toJson()).toJson(),
        shutdown.toJson(),
      );

      final status = RestartRequestedStatus(
        clientId: 'client-1',
        reason: 'config changed',
        requestId: 'req-10',
      );
      expect(
        RestartRequestedStatus.fromJson(status.toJson()).toJson(),
        status.toJson(),
      );

      final resumed = AgentResumedStatus(
        agentId: 'agent-1',
        agent: AgentSummary(
          agentId: 'agent-1',
          title: 'Resumed',
          cwd: '/repo',
          provider: 'claude',
          model: 'sonnet',
          mode: AgentMode.normal,
          runState: AgentRunState.idle,
          createdAtMs: 1710000000000,
          sessionId: 'session-1',
        ),
        requestId: 'req-9',
        timelineSize: 4,
      );
      final resumedDecoded = AgentResumedStatus.fromJson(resumed.toJson());
      expect(resumedDecoded.agentId, resumed.agentId);
      expect(resumedDecoded.agent.agentId, resumed.agent.agentId);
      expect(resumedDecoded.timelineSize, resumed.timelineSize);
    });

    test('file download token request and response round-trip', () {
      final request = FileDownloadTokenRequest(
        cwd: '/repo',
        path: 'build/app.zip',
        requestId: 'req-12',
      );
      final response = FileDownloadTokenResponse(
        cwd: '/repo',
        path: 'build/app.zip',
        token: 'token',
        fileName: 'app.zip',
        mimeType: 'application/zip',
        size: 42,
        error: null,
        requestId: 'req-12',
      );
      expect(
        FileDownloadTokenRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );
      expect(
        FileDownloadTokenResponse.fromJson(response.toJson()).toJson(),
        response.toJson(),
      );
    });
  });

  test('workspace update preserves project removal metadata', () {
    final update = WorkspaceRemoveUpdate(
      id: 'workspace-1',
      removedProjectId: 'project-1',
    );
    expect(WorkspaceUpdate.fromJson(update.toJson()).toJson(), update.toJson());
  });
}
