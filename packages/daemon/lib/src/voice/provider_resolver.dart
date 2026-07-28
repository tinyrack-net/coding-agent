typedef ProviderResolver<T> = T Function();

/// Normalizes Paseo's `T | (() => T)` provider boundary.
///
/// Dart has no union type for a value and a zero-argument function, so the
/// boundary accepts [Object?] and retains the requested result type on the
/// returned resolver. A mismatched direct value fails when it is resolved.
ProviderResolver<T> toResolver<T>(Object? value) {
  if (value is ProviderResolver<T>) return value;
  return () => value as T;
}
