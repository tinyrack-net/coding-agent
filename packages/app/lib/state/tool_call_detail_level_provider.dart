import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tool_calls/detail_level/tool_call_projection.dart';

ToolCallDetailLevel parseToolCallDetailLevel({
  Object? stored,
  Object? legacyCompactToolCalls,
}) {
  if (stored != null) {
    if (stored == ToolCallDetailLevel.detailed.name) {
      return ToolCallDetailLevel.detailed;
    }
    if (stored == ToolCallDetailLevel.overview.name) {
      return ToolCallDetailLevel.overview;
    }
    return ToolCallDetailLevel.overview;
  }
  if (legacyCompactToolCalls is bool) {
    return legacyCompactToolCalls
        ? ToolCallDetailLevel.overview
        : ToolCallDetailLevel.detailed;
  }
  return ToolCallDetailLevel.detailed;
}

class ToolCallDetailLevelNotifier extends Notifier<ToolCallDetailLevel> {
  static const preferenceKey = 'appearance.tool_call_detail_level';
  static const legacyPreferenceKey = 'appearance.compact_tool_calls';

  @override
  ToolCallDetailLevel build() {
    Future.microtask(_load);
    return ToolCallDetailLevel.detailed;
  }

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      state = parseToolCallDetailLevel(
        stored: preferences.get(preferenceKey),
        legacyCompactToolCalls: preferences.get(legacyPreferenceKey),
      );
    } catch (_) {
      // Keep the frozen detailed default when preferences are unavailable.
    }
  }

  Future<void> setLevel(ToolCallDetailLevel level) async {
    state = level;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(preferenceKey, level.name);
      await preferences.remove(legacyPreferenceKey);
    } catch (_) {
      // The in-memory selection still applies for this session.
    }
  }
}

final toolCallDetailLevelProvider =
    NotifierProvider<ToolCallDetailLevelNotifier, ToolCallDetailLevel>(
      ToolCallDetailLevelNotifier.new,
    );
