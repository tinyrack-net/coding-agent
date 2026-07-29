abstract interface class HostRouteBrowserAdapter {
  bool get available;

  String? getCurrentRoute();

  void replaceRoute(String route);

  void scheduleAfterCommit(void Function() callback);
}
