/// Dispatches a model tool call by name to its implementation, and maps the
/// result onto the protocol's [ToolCallDetail] for timeline display.
library;

import 'package:agent_protocol/agent_protocol.dart';

import 'bash_tool.dart';
import 'fs_tools.dart';
import 'search_tools.dart';
import 'tool_exception.dart';

const _previewLimit = 500;
const _shellOutputPreviewLimit = 4000;

class ToolExecutionResult {
  const ToolExecutionResult({
    required this.content,
    required this.detail,
    required this.isError,
  });

  /// Plain text fed back to the model as the tool result.
  final String content;
  final ToolCallDetail detail;
  final bool isError;
}

class ToolExecutor {
  ToolExecutor({required this.cwd});

  final String cwd;

  /// Tools that change state (filesystem or process); gated by [AgentMode]
  /// in `NativeSession`. Read-only tools always auto-execute.
  static const mutatingTools = {'write_file', 'edit_file', 'bash'};

  Future<ToolExecutionResult> execute(
    String name,
    Map<String, Object?> args,
  ) async {
    try {
      return await switch (name) {
        'read_file' => _readFile(args),
        'write_file' => _writeFile(args),
        'edit_file' => _editFile(args),
        'bash' => _bash(args),
        'grep' => _grep(args),
        'glob' => _glob(args),
        _ => ToolExecutionResult(
            content: 'unknown tool "$name"',
            detail: GenericDetail(input: args),
            isError: true,
          ),
      };
    } on ToolExecutionException catch (e) {
      return ToolExecutionResult(
        content: 'error: ${e.message}',
        detail: GenericDetail(input: args),
        isError: true,
      );
    } catch (e) {
      return ToolExecutionResult(
        content: 'error: $e',
        detail: GenericDetail(input: args),
        isError: true,
      );
    }
  }

  Future<ToolExecutionResult> _readFile(Map<String, Object?> args) async {
    final path = _requireStr(args, 'path');
    final content = await readFile(cwd, path);
    return ToolExecutionResult(
      content: content,
      detail: ReadDetail(path: path),
      isError: false,
    );
  }

  Future<ToolExecutionResult> _writeFile(Map<String, Object?> args) async {
    final path = _requireStr(args, 'path');
    final content = _requireStr(args, 'content', allowEmpty: true);
    await writeFile(cwd, path, content);
    return ToolExecutionResult(
      content: 'wrote ${content.length} bytes to $path',
      detail: WriteDetail(path: path, contentPreview: _preview(content)),
      isError: false,
    );
  }

  Future<ToolExecutionResult> _editFile(Map<String, Object?> args) async {
    final path = _requireStr(args, 'path');
    final oldString = _requireStr(args, 'old_string');
    final newString = _requireStr(args, 'new_string', allowEmpty: true);
    await editFile(cwd, path, oldString, newString);
    return ToolExecutionResult(
      content: 'edited $path',
      detail: EditDetail(path: path, diff: simpleDiff(oldString, newString)),
      isError: false,
    );
  }

  Future<ToolExecutionResult> _bash(Map<String, Object?> args) async {
    final command = _requireStr(args, 'command');
    final timeoutSeconds = (args['timeout_seconds'] as num?)?.toInt();
    final result = await runBash(
      cwd,
      command,
      timeout: timeoutSeconds == null
          ? const Duration(seconds: 120)
          : Duration(seconds: timeoutSeconds),
    );
    final content = result.timedOut
        ? '${result.output}\n[timed out]'
        : 'exit code: ${result.exitCode}\n${result.output}';
    return ToolExecutionResult(
      content: content,
      detail: ShellDetail(
        command: command,
        output: _preview(result.output, limit: _shellOutputPreviewLimit),
        exitCode: result.exitCode,
      ),
      isError: result.timedOut || result.exitCode != 0,
    );
  }

  Future<ToolExecutionResult> _grep(Map<String, Object?> args) async {
    final pattern = _requireStr(args, 'pattern');
    final path = args['path'] as String?;
    final content = await grepSearch(cwd, pattern, path: path);
    return ToolExecutionResult(
      content: content,
      detail: SearchDetail(query: pattern, path: path),
      isError: false,
    );
  }

  Future<ToolExecutionResult> _glob(Map<String, Object?> args) async {
    final pattern = _requireStr(args, 'pattern');
    final content = await globSearch(cwd, pattern);
    return ToolExecutionResult(
      content: content,
      detail: SearchDetail(query: pattern),
      isError: false,
    );
  }

  static String _requireStr(
    Map<String, Object?> args,
    String key, {
    bool allowEmpty = false,
  }) {
    final value = args[key];
    if (value is! String || (!allowEmpty && value.isEmpty)) {
      throw ToolExecutionException('"$key" is required');
    }
    return value;
  }

  static String _preview(String content, {int limit = _previewLimit}) =>
      content.length <= limit ? content : '${content.substring(0, limit)}…';
}
