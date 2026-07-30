/// Canonical identity and capability tuple for one Paseo explorer checkout.
final class ExplorerCheckoutContext {
  const ExplorerCheckoutContext({
    required this.serverId,
    required this.cwd,
    required this.isGit,
  });

  final String serverId;
  final String cwd;
  final bool isGit;
}
