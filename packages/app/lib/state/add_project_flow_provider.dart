import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final class AddProjectFlowRequest {
  const AddProjectFlowRequest({required this.id, this.preferredHostId});

  final int id;
  final String? preferredHostId;
}

final class AddProjectFlowResult {
  const AddProjectFlowResult({
    required this.serverId,
    required this.descriptor,
  });

  final String serverId;
  final WorkspaceProjectDescriptor descriptor;

  ProjectInfo get project => ProjectInfo(
    path: descriptor.projectRootPath,
    name: descriptor.projectDisplayName,
    isGitRepo: descriptor.projectKind == WorkspaceProjectKind.git,
  );
}

final class AddProjectFlowHostState {
  const AddProjectFlowHostState({this.request});

  final AddProjectFlowRequest? request;
}

final class AddProjectFlowNotifier extends Notifier<AddProjectFlowHostState> {
  var _nextRequestId = 1;
  Completer<AddProjectFlowResult?>? _result;

  @override
  AddProjectFlowHostState build() {
    ref.onDispose(() {
      final result = _result;
      if (result != null && !result.isCompleted) result.complete();
    });
    return const AddProjectFlowHostState();
  }

  Future<AddProjectFlowResult?> open({String? preferredHostId}) {
    final previous = _result;
    if (previous != null && !previous.isCompleted) previous.complete();
    final completer = Completer<AddProjectFlowResult?>();
    _result = completer;
    final normalized = preferredHostId?.trim();
    state = AddProjectFlowHostState(
      request: AddProjectFlowRequest(
        id: _nextRequestId++,
        preferredHostId: normalized == null || normalized.isEmpty
            ? null
            : normalized,
      ),
    );
    return completer.future;
  }

  void close([AddProjectFlowResult? result]) {
    state = const AddProjectFlowHostState();
    final completer = _result;
    _result = null;
    if (completer != null && !completer.isCompleted) completer.complete(result);
  }
}

final addProjectFlowProvider =
    NotifierProvider<AddProjectFlowNotifier, AddProjectFlowHostState>(
      AddProjectFlowNotifier.new,
    );
