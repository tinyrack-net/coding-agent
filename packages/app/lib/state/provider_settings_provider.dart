import 'package:flutter_riverpod/flutter_riverpod.dart';

final class ProviderSettingsTarget {
  const ProviderSettingsTarget({
    required this.serverId,
    required this.provider,
  });

  final String serverId;
  final String provider;

  @override
  bool operator ==(Object other) =>
      other is ProviderSettingsTarget &&
      other.serverId == serverId &&
      other.provider == provider;

  @override
  int get hashCode => Object.hash(serverId, provider);
}

final class ProviderSettingsState {
  const ProviderSettingsState({this.target, this.visible = false});

  final ProviderSettingsTarget? target;
  final bool visible;
}

final class ProviderSettingsNotifier extends Notifier<ProviderSettingsState> {
  @override
  ProviderSettingsState build() => const ProviderSettingsState();

  void open({required String serverId, required String provider}) {
    state = ProviderSettingsState(
      target: ProviderSettingsTarget(serverId: serverId, provider: provider),
      visible: true,
    );
  }

  void close() {
    state = ProviderSettingsState(target: state.target);
  }
}

final providerSettingsProvider =
    NotifierProvider<ProviderSettingsNotifier, ProviderSettingsState>(
      ProviderSettingsNotifier.new,
    );
