import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../layout/desktop_sidebar_layout.dart';

const sidebarWidthStorageKey = 'tinyrack.panel.sidebar-width';

double clampSidebarWidth(double width) {
  if (!width.isFinite) return minSidebarWidth;
  return width.clamp(minSidebarWidth, maxSidebarWidth);
}

abstract interface class SidebarWidthStorage {
  Future<double?> load();

  Future<void> save(double width);
}

class SharedPreferencesSidebarWidthStorage implements SidebarWidthStorage {
  const SharedPreferencesSidebarWidthStorage();

  @override
  Future<double?> load() async {
    final value = (await SharedPreferences.getInstance()).get(
      sidebarWidthStorageKey,
    );
    return value is num ? value.toDouble() : null;
  }

  @override
  Future<void> save(double width) async {
    await (await SharedPreferences.getInstance()).setDouble(
      sidebarWidthStorageKey,
      width,
    );
  }
}

final sidebarWidthStorageProvider = Provider<SidebarWidthStorage>(
  (_) => const SharedPreferencesSidebarWidthStorage(),
);

class SidebarWidthNotifier extends Notifier<double> {
  var _changedSinceBuild = false;

  @override
  double build() {
    _changedSinceBuild = false;
    scheduleMicrotask(_hydrate);
    return defaultSidebarWidth;
  }

  Future<void> _hydrate() async {
    double? stored;
    try {
      stored = await ref.read(sidebarWidthStorageProvider).load();
    } catch (_) {
      return;
    }
    if (!ref.mounted || _changedSinceBuild || stored == null) return;
    state = clampSidebarWidth(stored);
  }

  void setWidth(double width) {
    _changedSinceBuild = true;
    final next = clampSidebarWidth(width);
    state = next;
    unawaited(
      ref.read(sidebarWidthStorageProvider).save(next).catchError((_) {}),
    );
  }
}

final sidebarWidthProvider = NotifierProvider<SidebarWidthNotifier, double>(
  SidebarWidthNotifier.new,
);
