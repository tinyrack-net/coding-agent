@TestOn('browser')
library;

import 'package:coding_agent_app/attachments/workspace_file_data_transfer.dart';
import 'package:coding_agent_app/attachments/workspace_file_data_transfer_web.dart';
import 'package:coding_agent_app/attachments/workspace_file_drag.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('real browser DataTransfer preserves the Paseo custom MIME', () {
    final delegate = web.DataTransfer();
    final dataTransfer = WebWorkspaceFileDataTransfer(delegate);
    final payload = WorkspaceFileDragPayload(
      serverId: 'server-1',
      workspaceId: 'workspace-1',
      attachment: ComposerWorkspaceFileAttachment(path: 'lib/app.dart'),
    );

    writeWorkspaceFileDragData(dataTransfer: dataTransfer, payload: payload);

    expect(dataTransfer.types, contains(workspaceFileDragMime));
    expect(dataTransfer.getData(workspaceFileDragMime), isNotEmpty);
    expect(readWorkspaceFileDragData(dataTransfer), payload);
  });
}
