import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'workspace_file_data_transfer.dart';

/// Browser adapter for Paseo's HTML5 workspace-file drag contract.
final class WebWorkspaceFileDataTransfer implements WorkspaceFileDataTransfer {
  const WebWorkspaceFileDataTransfer(this.delegate);

  final web.DataTransfer delegate;

  @override
  Iterable<String> get types =>
      delegate.types.toDart.map((type) => type.toDart);

  @override
  String get effectAllowed => delegate.effectAllowed;

  @override
  set effectAllowed(String value) => delegate.effectAllowed = value;

  @override
  String get dropEffect => delegate.dropEffect;

  @override
  set dropEffect(String value) => delegate.dropEffect = value;

  @override
  String getData(String format) => delegate.getData(format);

  @override
  void setData(String format, String data) => delegate.setData(format, data);
}
