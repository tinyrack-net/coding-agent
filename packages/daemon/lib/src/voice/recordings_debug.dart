import 'package:path/path.dart' as p;

bool isTinyrackDictationDebugEnabled(Map<String, String> environment) {
  final normalized = (environment['TINYRACK_DICTATION_DEBUG'] ?? '')
      .trim()
      .toLowerCase();
  return const {'1', 'true', 'yes', 'on'}.contains(normalized);
}

String? resolveRecordingsDebugDir({
  required String explicitEnvironmentName,
  required Map<String, String> environment,
  required String cwd,
}) {
  final explicit = environment[explicitEnvironmentName];
  if (explicit != null && explicit.trim().isNotEmpty) {
    return p.normalize(p.absolute(explicit.trim()));
  }
  if (!isTinyrackDictationDebugEnabled(environment)) return null;
  return p.normalize(p.absolute(p.join(cwd, '.debug', 'recordings')));
}
