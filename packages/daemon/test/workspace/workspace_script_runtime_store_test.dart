import 'package:agent_daemon/src/workspace/workspace_script_runtime_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  WorkspaceScriptRuntimeEntry entry({
    String workspaceId = 'workspace',
    String scriptName = 'web',
    WorkspaceScriptLifecycle lifecycle = WorkspaceScriptLifecycle.running,
  }) => WorkspaceScriptRuntimeEntry(
    workspaceId: workspaceId,
    scriptName: scriptName,
    type: WorkspaceScriptType.service,
    lifecycle: lifecycle,
    terminalId: '$workspaceId-$scriptName',
    exitCode: null,
  );

  test('set, get, replace, and running state match the frozen store', () {
    final store = WorkspaceScriptRuntimeStore();
    expect(store.get(workspaceId: 'workspace', scriptName: 'web'), isNull);
    store.set(entry());
    expect(
      store.get(workspaceId: 'workspace', scriptName: 'web')!.terminalId,
      'workspace-web',
    );
    expect(
      store.isRunning(workspaceId: 'workspace', scriptName: 'web'),
      isTrue,
    );

    store.set(
      entry().copyWith(
        lifecycle: WorkspaceScriptLifecycle.stopped,
        exitCode: 2,
      ),
    );
    final stopped = store.get(workspaceId: 'workspace', scriptName: 'web')!;
    expect(stopped.lifecycle, WorkspaceScriptLifecycle.stopped);
    expect(stopped.exitCode, 2);
    expect(
      store.isRunning(workspaceId: 'workspace', scriptName: 'web'),
      isFalse,
    );
    final copied = stopped.copyWith(
      workspaceId: 'other',
      scriptName: 'api',
      type: WorkspaceScriptType.script,
      terminalId: 'terminal',
      exitCode: null,
    );
    expect(copied.workspaceId, 'other');
    expect(copied.scriptName, 'api');
    expect(copied.type, WorkspaceScriptType.script);
    expect(copied.lifecycle, WorkspaceScriptLifecycle.stopped);
    expect(copied.terminalId, 'terminal');
    expect(copied.exitCode, isNull);
  });

  test('workspace index isolates entries and preserves insertion order', () {
    final store = WorkspaceScriptRuntimeStore()
      ..set(entry(scriptName: 'api'))
      ..set(entry(scriptName: 'web'))
      ..set(entry(workspaceId: 'other', scriptName: 'worker'));
    expect(
      store.listForWorkspace('workspace').map((value) => value.scriptName),
      ['api', 'web'],
    );
    expect(store.listForWorkspace('missing'), isEmpty);
  });

  test('remove and removeForWorkspace clean both indexes', () {
    final store = WorkspaceScriptRuntimeStore()
      ..set(entry(scriptName: 'api'))
      ..set(entry(scriptName: 'web'))
      ..set(entry(workspaceId: 'other', scriptName: 'web'));
    store.remove(workspaceId: 'workspace', scriptName: 'missing');
    store.remove(workspaceId: 'workspace', scriptName: 'api');
    expect(store.listForWorkspace('workspace').single.scriptName, 'web');

    store.removeForWorkspace('workspace');
    expect(store.listForWorkspace('workspace'), isEmpty);
    expect(store.listForWorkspace('other'), hasLength(1));
    store.removeForWorkspace('missing');
  });
}
