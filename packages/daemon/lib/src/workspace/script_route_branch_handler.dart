import 'service_proxy_route_registry.dart';

typedef WorkspaceBranchRouteChanged = void Function(String workspaceId);
typedef WorkspaceBranchRouteLog =
    void Function(String workspaceId, String? newBranch);

void Function(String workspaceId, String? oldBranch, String? newBranch)
createBranchChangeRouteHandler({
  required ServiceProxyRouteRegistry serviceProxy,
  required WorkspaceBranchRouteChanged onRoutesChanged,
  WorkspaceBranchRouteLog? log,
}) {
  return (workspaceId, _, newBranch) {
    final changed = serviceProxy.replaceWorkspaceBranchRoutes(
      workspaceId: workspaceId,
      newBranch: newBranch,
    );
    if (!changed) return;
    log?.call(workspaceId, newBranch);
    onRoutesChanged(workspaceId);
  };
}
