final class ResolvedProviderModel {
  const ResolvedProviderModel({required this.provider, required this.model});

  final String provider;
  final String? model;
}

final class ProviderModelFormatException extends FormatException {
  const ProviderModelFormatException(this.code, String message, {this.details})
    : super(message);

  final String code;
  final String? details;
}

ResolvedProviderModel resolveProviderAndModel({
  String? provider,
  String? model,
  String? defaultProvider,
}) {
  final providerInput = _nonEmpty(provider) ?? defaultProvider;
  final modelInput = _nonEmpty(model);

  if (providerInput == null || providerInput.isEmpty) {
    throw const ProviderModelFormatException(
      'MISSING_PROVIDER',
      'Provider is required',
      details:
          'Pass --provider <provider> or --provider <provider>/<model>. '
          'Use `coding-agent provider ls` to see providers and '
          '`coding-agent provider models <provider>` to see models.',
    );
  }

  if (model != null && modelInput == null) {
    throw const ProviderModelFormatException(
      'INVALID_MODEL',
      '--model cannot be empty',
    );
  }

  final slashIndex = providerInput.indexOf('/');
  if (slashIndex == -1) {
    return ResolvedProviderModel(provider: providerInput, model: modelInput);
  }

  final resolvedProvider = providerInput.substring(0, slashIndex).trim();
  final modelFromProvider = providerInput.substring(slashIndex + 1).trim();
  if (resolvedProvider.isEmpty || modelFromProvider.isEmpty) {
    throw const ProviderModelFormatException(
      'INVALID_PROVIDER',
      'Invalid --provider value',
      details: 'Use --provider <provider> or --provider <provider>/<model>',
    );
  }

  if (modelInput != null && modelInput != modelFromProvider) {
    throw ProviderModelFormatException(
      'CONFLICTING_MODEL_OPTIONS',
      'Conflicting model values provided',
      details:
          '--provider specifies model $modelFromProvider, '
          'but --model specifies $modelInput',
    );
  }

  return ResolvedProviderModel(
    provider: resolvedProvider,
    model: modelInput ?? modelFromProvider,
  );
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
