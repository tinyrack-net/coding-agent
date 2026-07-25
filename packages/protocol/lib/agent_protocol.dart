/// Shared wire protocol between the coding-agent daemon and its clients.
library;

export 'src/binary/terminal_frames.dart';
export 'src/messages/agent.dart';
export 'src/messages/diff.dart';
export 'src/messages/hello.dart';
export 'src/messages/terminal.dart';
export 'src/messages/workspace.dart';
export 'src/messages/provider.dart';
export 'src/rpc_envelope.dart';
export 'src/timeline/timeline_item.dart';
export 'src/timeline/tool_call_detail.dart';

/// Bumped on breaking wire changes; clients refuse to talk across versions.
const int protocolVersion = 2;
