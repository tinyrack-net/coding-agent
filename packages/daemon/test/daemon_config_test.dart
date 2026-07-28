import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/server/daemon_auth.dart';
import 'package:agent_daemon/src/server/daemon_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('tinyrack-config-');
  });

  tearDown(() {
    home.deleteSync(recursive: true);
  });

  test('uses Tinyrack defaults from an empty home', () {
    final config = loadDaemonRuntimeConfig(home: home.path, environment: {});

    expect(config.home, p.normalize(p.absolute(home.path)));
    expect(config.listen, defaultTinyrackListen);
    expect(config.host, '127.0.0.1');
    expect(config.port, 6868);
    expect(config.auth, isNull);
    expect(config.relay.enabled, isTrue);
    expect(config.relay.endpoint, defaultTinyrackRelayEndpoint);
    expect(config.relay.useTls, isTrue);
    expect(config.serviceProxy.publicBaseUrl, isNull);
    expect(config.serviceProxy.standaloneListen, isNull);
    expect(config.appBaseUrl, defaultTinyrackAppBaseUrl);
    expect(config.trustedProxies, ['loopback']);
    expect(config.hostnames, isEmpty);
    expect(config.corsAllowedOrigins, [defaultTinyrackAppBaseUrl]);
    expect(config.webUiEnabled, isFalse);
    expect(p.basename(config.webUiDistDir), 'web-ui');
    expect(config.enableTerminalAgentHooks, isFalse);
    expect(File(p.join(home.path, 'config.json')).existsSync(), isTrue);
  });

  test('loads v1 config and merges CORS environment origins', () {
    _writeConfig(home, {
      'version': 1,
      'daemon': {
        'listen': '[::1]:7000',
        'cors': {
          'allowedOrigins': ['https://saved.test', 'https://same.test'],
        },
        'trustedProxies': ['loopback', '10.0.0.0/8'],
        'relay': {
          'enabled': false,
          'endpoint': 'relay.saved.test:443',
          'useTls': false,
        },
      },
      'features': {
        'webUi': {'enabled': true},
      },
      'app': {'baseUrl': 'https://app.saved.test'},
      'log': {'level': 'warn', 'format': 'json'},
    });

    final config = loadDaemonRuntimeConfig(
      home: home.path,
      environment: {
        'TINYRACK_CORS_ORIGINS': 'https://same.test, https://environment.test',
      },
    );

    expect(config.host, '::1');
    expect(config.port, 7000);
    expect(config.corsAllowedOrigins, [
      'https://saved.test',
      'https://same.test',
      'https://environment.test',
    ]);
    expect(config.relay.enabled, isFalse);
    expect(config.relay.useTls, isFalse);
    expect(config.webUiEnabled, isTrue);
    expect(config.logLevel, 'warn');
    expect(config.logFormat, 'json');
  });

  test('loads frozen speech provider and language configuration', () {
    _writeConfig(home, {
      'version': 1,
      'speech': {
        'providers': {
          'dictationStt': {
            'provider': 'openai',
            'explicit': true,
            'enabled': false,
          },
        },
        'sttLanguages': {'voice': 'ko', 'dictation': 'ja'},
      },
    });

    final config = loadDaemonRuntimeConfig(home: home.path, environment: {});

    expect(config.speech.providers.dictationStt.provider.wireName, 'openai');
    expect(config.speech.providers.dictationStt.enabled, isFalse);
    expect(config.speech.providers.voiceStt.provider.wireName, 'local');
    expect(config.speech.providers.voiceStt.explicit, isFalse);
    expect(config.speech.voiceSttLanguage, 'ko');
    expect(config.speech.dictationSttLanguage, 'ja');
  });

  test('resolves frozen OpenAI speech config into daemon runtime', () {
    _writeConfig(home, {
      'version': 1,
      'speech': {
        'providers': {
          'dictationStt': {'provider': 'openai', 'explicit': true},
          'voiceStt': {'provider': 'openai', 'explicit': true},
          'voiceTts': {'provider': 'openai', 'explicit': true},
        },
      },
      'providers': {
        'openai': {
          'stt': {'apiKey': 'saved-stt', 'baseUrl': 'https://stt.test/v1'},
        },
      },
    });

    final config = loadDaemonRuntimeConfig(
      home: home.path,
      environment: const {'OPENAI_TTS_API_KEY': 'env-tts', 'TTS_VOICE': 'nova'},
    );

    expect(config.openAiSpeech?.stt?.apiKey, 'saved-stt');
    expect(config.openAiSpeech?.stt?.baseUrl, 'https://stt.test/v1');
    expect(config.openAiSpeech?.tts?.apiKey, 'env-tts');
    expect(config.openAiSpeech?.tts?.voice, 'nova');
  });

  test('speech config defaults and malformed boundaries match Paseo', () {
    final defaults = loadDaemonRuntimeConfig(
      home: home.path,
      environment: {},
    ).speech;
    expect(defaults.providers.voiceTts.enabled, isTrue);
    expect(defaults.voiceSttLanguage, 'en');
    expect(defaults.dictationSttLanguage, 'en');

    for (final speech in [
      <String, Object?>{'providers': false},
      <String, Object?>{
        'providers': {
          'voiceStt': {'provider': 'invalid', 'explicit': true},
        },
      },
      <String, Object?>{
        'providers': {
          'voiceStt': {'provider': 'local', 'explicit': 'yes'},
        },
      },
      <String, Object?>{
        'sttLanguages': {'voice': ' '},
      },
    ]) {
      _writeConfig(home, {'version': 1, 'speech': speech});
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );
    }
  });

  test('applies CLI over env over persisted precedence', () {
    _writeConfig(home, {
      'version': 1,
      'daemon': {
        'listen': 'saved.test:1',
        'relay': {'enabled': false, 'useTls': false},
      },
      'features': {
        'webUi': {'enabled': false},
      },
    });

    final config = loadDaemonRuntimeConfig(
      home: home.path,
      environment: {
        'TINYRACK_LISTEN': 'environment.test:2',
        'TINYRACK_RELAY_ENABLED': 'false',
        'TINYRACK_RELAY_USE_TLS': 'false',
        'TINYRACK_WEB_UI_ENABLED': 'false',
      },
      cliListen: 'cli.test:3',
      cliRelayEnabled: true,
      cliRelayUseTls: true,
      cliWebUiEnabled: true,
      cliWebUiDistDir: 'cli-web',
    );

    expect(config.listen, 'cli.test:3');
    expect(config.relay.enabled, isTrue);
    expect(config.relay.useTls, isTrue);
    expect(config.webUiEnabled, isTrue);
    expect(config.webUiDistDir, p.join(home.path, 'cli-web'));
  });

  test('resolves optional service proxy layers with compatibility shim', () {
    _writeConfig(home, {
      'version': 1,
      'daemon': {
        'serviceProxy': {
          'enabled': true,
          'listen': '127.0.0.1:7001',
          'publicBaseUrl': 'https://saved.example.test/',
        },
      },
    });

    final persisted = loadDaemonRuntimeConfig(
      home: home.path,
      environment: const {},
    );
    expect(persisted.serviceProxy.publicBaseUrl, 'https://saved.example.test');
    expect(persisted.serviceProxy.standaloneListen, '127.0.0.1:7001');

    final environment = loadDaemonRuntimeConfig(
      home: home.path,
      environment: const {
        'TINYRACK_SERVICE_PROXY_PUBLIC_BASE_URL':
            'http://proxy.example.test:8080/',
        'TINYRACK_SERVICE_PROXY_LISTEN': '127.0.0.1:7002',
      },
    );
    expect(
      environment.serviceProxy.publicBaseUrl,
      'http://proxy.example.test:8080',
    );
    expect(environment.serviceProxy.standaloneListen, '127.0.0.1:7002');

    final disabled = loadDaemonRuntimeConfig(
      home: home.path,
      environment: const {'TINYRACK_SERVICE_PROXY_ENABLED': 'false'},
    );
    expect(disabled.serviceProxy.publicBaseUrl, isNull);
    expect(disabled.serviceProxy.standaloneListen, isNull);
  });

  test('rejects an invalid service proxy public URL', () {
    expect(
      () => loadDaemonRuntimeConfig(
        home: home.path,
        environment: const {
          'TINYRACK_SERVICE_PROXY_PUBLIC_BASE_URL': 'not-a-url',
        },
      ),
      throwsFormatException,
    );
  });

  test('merges persisted, legacy environment, and CLI hostnames', () {
    _writeConfig(home, {
      'version': 1,
      'daemon': {
        'allowedHosts': ['.saved.test', 'same.test'],
      },
    });

    final config = loadDaemonRuntimeConfig(
      home: home.path,
      environment: {'TINYRACK_ALLOWED_HOSTS': 'same.test,.environment.test'},
      cliHostnames: '.cli.test',
    );
    expect(config.hostnames, [
      '.saved.test',
      'same.test',
      '.environment.test',
      '.cli.test',
    ]);

    final allowAny = loadDaemonRuntimeConfig(
      home: home.path,
      environment: const {'TINYRACK_HOSTNAMES': 'true'},
    );
    expect(allowAny.hostnames, isTrue);
  });

  test('environment password overrides persisted hash', () {
    _writeConfig(home, {
      'version': 1,
      'daemon': {
        'auth': {'password': hashDaemonPassword('persisted')},
      },
    });

    final config = loadDaemonRuntimeConfig(
      home: home.path,
      environment: {'TINYRACK_PASSWORD': 'environment'},
    );

    expect(
      isBearerTokenValid(
        passwordHash: config.auth!.passwordHash,
        token: 'environment',
      ),
      isTrue,
    );
    expect(
      isBearerTokenValid(
        passwordHash: config.auth!.passwordHash,
        token: 'persisted',
      ),
      isFalse,
    );
  });

  test('loads terminal agent hooks with environment precedence', () {
    _writeConfig(home, {
      'version': 1,
      'daemon': {'enableTerminalAgentHooks': true},
    });

    expect(
      loadDaemonRuntimeConfig(
        home: home.path,
        environment: const {},
      ).enableTerminalAgentHooks,
      isTrue,
    );
    expect(
      loadDaemonRuntimeConfig(
        home: home.path,
        environment: const {'TINYRACK_ENABLE_TERMINAL_AGENT_HOOKS': 'false'},
      ).enableTerminalAgentHooks,
      isFalse,
    );
    expect(
      loadDaemonRuntimeConfig(
        home: home.path,
        environment: const {'TINYRACK_ENABLE_TERMINAL_AGENT_HOOKS': 'true'},
      ).enableTerminalAgentHooks,
      isTrue,
    );
  });

  test('retains a valid persisted password hash without an env override', () {
    final hash = hashDaemonPassword('persisted');
    _writeConfig(home, {
      'version': 1,
      'daemon': {
        'auth': {'password': hash},
      },
    });

    final config = loadDaemonRuntimeConfig(home: home.path, environment: {});

    expect(config.auth!.passwordHash, hash);
  });

  test('resolves Tinyrack home and trusted proxy environment forms', () {
    expect(resolveTinyrackHome({'TINYRACK_HOME': 'explicit'}), 'explicit');
    expect(
      resolveTinyrackHome({'USERPROFILE': 'profile'}),
      p.join('profile', '.tinyrack-agent'),
    );
    expect(
      resolveTinyrackHome({'HOME': 'home'}),
      p.join('home', '.tinyrack-agent'),
    );

    final enabled = loadDaemonRuntimeConfig(
      home: home.path,
      environment: {'TINYRACK_TRUSTED_PROXIES': 'true'},
    );
    expect(enabled.trustedProxies, isTrue);
    final disabled = loadDaemonRuntimeConfig(
      home: home.path,
      environment: {'TINYRACK_TRUSTED_PROXIES': 'false'},
    );
    expect(disabled.trustedProxies, isEmpty);
    final ranges = loadDaemonRuntimeConfig(
      home: home.path,
      environment: {
        'TINYRACK_TRUSTED_PROXIES': 'loopback, 10.0.0.0/8',
        'TINYRACK_RELAY_ENABLED': 'not-a-boolean',
      },
    );
    expect(ranges.trustedProxies, ['loopback', '10.0.0.0/8']);
    expect(ranges.relay.enabled, isTrue);
  });

  test('TINYRACK_HUB_URL configures public and private relay endpoints', () {
    final config = loadDaemonRuntimeConfig(
      home: home.path,
      environment: const {'TINYRACK_HUB_URL': 'http://127.0.0.1:8787/ws'},
    );

    expect(config.relay.endpoint, '127.0.0.1:8787');
    expect(config.relay.publicEndpoint, '127.0.0.1:8787');
    expect(config.relay.useTls, isFalse);
    expect(config.relay.publicUseTls, isFalse);
  });

  test('explicit relay endpoint overrides the Hub transport endpoint', () {
    final config = loadDaemonRuntimeConfig(
      home: home.path,
      environment: const {
        'TINYRACK_HUB_URL': 'https://hub.tinyrack.dev',
        'TINYRACK_RELAY_ENDPOINT': 'relay.internal:9000',
        'TINYRACK_RELAY_USE_TLS': 'false',
      },
    );

    expect(config.relay.endpoint, 'relay.internal:9000');
    expect(config.relay.useTls, isFalse);
    expect(config.relay.publicEndpoint, 'hub.tinyrack.dev:443');
    expect(config.relay.publicUseTls, isTrue);
  });

  test('rejects malformed TINYRACK_HUB_URL', () {
    expect(
      () => loadDaemonRuntimeConfig(
        home: home.path,
        environment: const {'TINYRACK_HUB_URL': 'ftp://hub.invalid/path'},
      ),
      throwsFormatException,
    );
  });

  test(
    'rejects invalid schema versions, password hashes, and listen values',
    () {
      _writeConfig(home, {'version': 2});
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );

      _writeConfig(home, {
        'version': 1,
        'daemon': {'trustedProxies': false},
      });
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );

      _writeConfig(home, {
        'version': 1,
        'daemon': {
          'auth': {'password': 'plaintext'},
        },
      });
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );

      _writeConfig(home, {
        'version': 1,
        'daemon': {'listen': 'missing-port'},
      });
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );

      _writeConfig(home, {
        'version': 1,
        'daemon': {'listen': '[missing-bracket:10'},
      });
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );

      _writeConfig(home, {'version': 1, 'daemon': 'invalid'});
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );

      _writeConfig(home, {
        'version': 1,
        'daemon': {
          'cors': {
            'allowedOrigins': [1],
          },
        },
      });
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );

      _writeConfig(home, {
        'version': 1,
        'daemon': {'hostnames': false},
      });
      expect(
        () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
        throwsFormatException,
      );
    },
  );

  test('wraps filesystem failures while reading config', () {
    Directory(p.join(home.path, 'config.json')).createSync();

    expect(
      () => loadDaemonRuntimeConfig(home: home.path, environment: {}),
      throwsFormatException,
    );
  });
}

void _writeConfig(Directory home, Map<String, Object?> config) {
  File(p.join(home.path, 'config.json')).writeAsStringSync(jsonEncode(config));
}
