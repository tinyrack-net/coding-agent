import 'provider_model_selection.dart';

bool shouldAllowEmptyDraftText({
  required bool allowsEmptyAutoSubmit,
  required List<Object?> attachments,
}) => allowsEmptyAutoSubmit || attachments.isNotEmpty;

String? validateDraftSubmission({
  required String text,
  required bool allowsEmptyAutoSubmit,
  required int providerCount,
  required String? selectedProvider,
  required bool isModelLoading,
  required String effectiveModelId,
  required List<Object?> availableModels,
  String? autoSubmitProvider,
  String? autoSubmitModel,
  required String? workspaceDirectory,
  required bool hasClient,
}) {
  final readiness = resolveSubmissionReadiness(
    text: text,
    allowsEmptyAutoSubmit: allowsEmptyAutoSubmit,
    providerCount: providerCount,
    provider: selectedProvider,
    modelId: effectiveModelId,
    availableModels: availableModels,
    isModelLoading: isModelLoading,
    autoSubmitProvider: autoSubmitProvider,
    autoSubmitModel: autoSubmitModel,
    workspaceDirectory: workspaceDirectory,
    hasClient: hasClient,
  );
  return readiness.ok ? null : readiness.reason;
}
