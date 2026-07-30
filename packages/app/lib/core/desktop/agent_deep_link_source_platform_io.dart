import 'dart:io';

import 'agent_deep_link_source.dart';
import 'windows_agent_deep_link_source.dart';

AgentDeepLinkSource? createPlatformAgentDeepLinkSource() =>
    Platform.isWindows ? WindowsAgentDeepLinkSource() : null;
