import 'package:coding_agent_app/attachments/workspace_file_data_transfer.dart';
import 'package:coding_agent_app/attachments/workspace_file_drag.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';

WorkspaceFileDragPayload _payload() => WorkspaceFileDragPayload(
  serverId: 'server-1',
  workspaceId: 'workspace-1',
  attachment: ComposerWorkspaceFileAttachment(
    path: 'src/app.dart',
    selection: ComposerWorkspaceFileSelection.lineRange(
      startLine: 12,
      endLine: 24,
    ),
  ),
);

void main() {
  test('writes the frozen MIME payload with copy source semantics', () {
    final dataTransfer = _FakeDataTransfer();

    writeWorkspaceFileDragData(dataTransfer: dataTransfer, payload: _payload());

    expect(dataTransfer.effectAllowed, 'copy');
    expect(dataTransfer.types, [workspaceFileDragMime]);
    expect(readWorkspaceFileDragData(dataTransfer), _payload());
  });

  test('does not read an absent, empty, or malformed custom payload', () {
    final absent = _FakeDataTransfer();
    final empty = _FakeDataTransfer()..setData(workspaceFileDragMime, '');
    final malformed = _FakeDataTransfer()
      ..setData(workspaceFileDragMime, 'not json');

    expect(readWorkspaceFileDragData(absent), isNull);
    expect(readWorkspaceFileDragData(empty), isNull);
    expect(readWorkspaceFileDragData(malformed), isNull);
  });

  test('advertises copy only for an accepted workspace-file drop', () {
    final dataTransfer = _FakeDataTransfer()
      ..setData(workspaceFileDragMime, 'payload');

    updateWorkspaceFileDropEffect(dataTransfer: dataTransfer, canAccept: true);
    expect(dataTransfer.dropEffect, 'copy');

    updateWorkspaceFileDropEffect(dataTransfer: dataTransfer, canAccept: false);
    expect(dataTransfer.dropEffect, 'none');

    dataTransfer.clear();
    updateWorkspaceFileDropEffect(dataTransfer: dataTransfer, canAccept: true);
    expect(dataTransfer.dropEffect, 'none');
  });
}

final class _FakeDataTransfer implements WorkspaceFileDataTransfer {
  final Map<String, String> _data = {};

  @override
  String effectAllowed = 'uninitialized';

  @override
  String dropEffect = 'none';

  @override
  Iterable<String> get types => _data.keys;

  @override
  String getData(String format) => _data[format] ?? '';

  @override
  void setData(String format, String data) => _data[format] = data;

  void clear() => _data.clear();
}
