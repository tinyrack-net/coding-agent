import 'package:agent_protocol/agent_protocol.dart';

int compareCheckoutDiffPaths(String left, String right) {
  if (left == right) return 0;
  return left.compareTo(right);
}

List<CheckoutDiffFile> orderCheckoutDiffFiles(List<CheckoutDiffFile> files) {
  if (files.length < 2) return files;
  final indexed = files.indexed.toList()
    ..sort((left, right) {
      final pathOrder = compareCheckoutDiffPaths(left.$2.path, right.$2.path);
      return pathOrder != 0 ? pathOrder : left.$1.compareTo(right.$1);
    });
  return indexed.map((entry) => entry.$2).toList(growable: false);
}

List<DiffFile> orderLegacyDiffFiles(List<DiffFile> files) {
  if (files.length < 2) return files;
  final indexed = files.indexed.toList()
    ..sort((left, right) {
      final pathOrder = compareCheckoutDiffPaths(left.$2.path, right.$2.path);
      return pathOrder != 0 ? pathOrder : left.$1.compareTo(right.$1);
    });
  return indexed.map((entry) => entry.$2).toList(growable: false);
}
