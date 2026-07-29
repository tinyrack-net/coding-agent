/// Converts a thrown Dart value into the user-facing message used by the CLI.
///
/// Dart has no shared `message` interface across [Error] and [Exception], so
/// the property is read dynamically only for thrown error types. Arbitrary
/// values retain their normal string representation.
String getErrorMessage(Object? error) {
  if (error is Error || error is Exception) {
    try {
      final message = (error as dynamic).message;
      if (message != null) return '$message';
    } on Object {
      // The thrown type has no message property.
    }
  }
  return '$error';
}
