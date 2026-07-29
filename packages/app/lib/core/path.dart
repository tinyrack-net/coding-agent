/// Returns whether [value] uses one of Paseo's supported absolute path forms:
/// a Unix root, a Windows UNC prefix, or a drive letter plus separator.
bool isAbsolutePath(String value) =>
    value.startsWith('/') ||
    value.startsWith(r'\\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
