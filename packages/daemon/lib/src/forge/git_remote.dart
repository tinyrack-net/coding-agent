export 'package:agent_protocol/agent_protocol.dart'
    show
        GitHubRemoteIdentity,
        GitRemoteLocation,
        isCompleteGitRemote,
        isGitHubHost,
        normalizeGitRemoteHost,
        parseGitHubRemoteIdentity,
        parseGitHubRemoteUrl,
        parseGitRemoteLocation;

import 'package:agent_protocol/agent_protocol.dart';

String? forgeForKnownHost(String host) =>
    switch (normalizeGitRemoteHost(host)) {
      'github.com' => 'github',
      'gitlab.com' => 'gitlab',
      'gitea.com' => 'gitea',
      'codeberg.org' => 'codeberg',
      _ => null,
    };
