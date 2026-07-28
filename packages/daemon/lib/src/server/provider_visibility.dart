const _legacyProviderIds = {'claude', 'codex', 'opencode'};
const _minimumAllProvidersVersion = '0.1.45';

bool clientSupportsAllProviders(String? appVersion) =>
    isAppVersionAtLeast(appVersion, _minimumAllProvidersVersion);

bool isProviderVisibleToClient(String provider, String? appVersion) =>
    clientSupportsAllProviders(appVersion) ||
    _legacyProviderIds.contains(provider);

bool isAppVersionAtLeast(String? appVersion, String minimumVersion) {
  if (appVersion == null) return false;
  final base = appVersion.replaceFirst(RegExp(r'-.*$'), '');
  final parts = base.split('.');
  final minimum = minimumVersion.split('.').map(double.parse).toList();
  for (var index = 0; index < minimum.length; index++) {
    final current = index < parts.length
        ? _parseJavaScriptNumber(parts[index])
        : 0;
    // The frozen code uses Number(). A malformed component becomes NaN and
    // both ordered comparisons are false, so comparison continues.
    if (current == null) continue;
    final expected = minimum[index];
    if (current > expected) return true;
    if (current < expected) return false;
  }
  return true;
}

double? _parseJavaScriptNumber(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return 0;
  return double.tryParse(normalized);
}
