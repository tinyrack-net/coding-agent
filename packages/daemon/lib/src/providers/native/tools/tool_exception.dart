/// Thrown by native tool implementations for expected failures (bad args,
/// missing files, sandbox violations); caught by [ToolExecutor] and turned
/// into a plain-text error the model can see and react to.
library;

class ToolExecutionException implements Exception {
  ToolExecutionException(this.message);

  final String message;

  @override
  String toString() => message;
}
