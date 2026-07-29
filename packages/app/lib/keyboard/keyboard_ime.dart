import 'package:flutter/services.dart';

/// Matches Paseo's browser IME guard. Chromium may report composition either
/// explicitly or through the legacy keyCode 229 fallback.
bool isImeComposingKeyboardEvent({bool? isComposing, int? keyCode}) =>
    (isComposing ?? false) || keyCode == 229;

/// Flutter bridge for the same contract. An active composing range means the
/// next key confirms an IME candidate rather than invoking an app shortcut.
bool isImeComposingTextEditingValue(TextEditingValue value) =>
    isImeComposingKeyboardEvent(
      isComposing: value.composing.isValid && !value.composing.isCollapsed,
    );
