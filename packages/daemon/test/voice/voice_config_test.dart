import 'package:agent_daemon/src/voice/voice_config.dart';
import 'package:test/test.dart';

void main() {
  test('builds exact stdio MCP config without mutating caller values', () {
    final baseArgs = ['/tmp/mcp-stdio-socket-bridge-cli.mjs'];
    final env = {
      'ELECTRON_RUN_AS_NODE': '1',
      'TINYRACK_HOME': '/tmp/tinyrack-home',
    };
    final config = buildVoiceAgentMcpServerConfig(
      command: '/usr/local/bin/node',
      baseArgs: baseArgs,
      socketPath: '/tmp/tinyrack-voice.sock',
      env: env,
    );

    expect(config, {
      'type': 'stdio',
      'command': '/usr/local/bin/node',
      'args': [
        '/tmp/mcp-stdio-socket-bridge-cli.mjs',
        '--socket',
        '/tmp/tinyrack-voice.sock',
      ],
      'env': {
        'ELECTRON_RUN_AS_NODE': '1',
        'TINYRACK_HOME': '/tmp/tinyrack-home',
      },
    });
    (config['args']! as List).add('changed');
    (config['env']! as Map)['CHANGED'] = 'true';
    expect(baseArgs, ['/tmp/mcp-stdio-socket-bridge-cli.mjs']);
    expect(env, isNot(contains('CHANGED')));
  });

  test('omits absent stdio environment', () {
    expect(
      buildVoiceAgentMcpServerConfig(
        command: 'dart',
        baseArgs: const [],
        socketPath: 'voice.sock',
      ),
      {
        'type': 'stdio',
        'command': 'dart',
        'args': ['--socket', 'voice.sock'],
      },
    );
  });

  test('builds enabled voice instructions and preserves base prompt', () {
    final prompt = buildVoiceModeSystemPrompt('Base system prompt', true);

    expect(prompt, contains('Base system prompt'));
    expect(prompt, contains('<paseo_voice_mode>'));
    expect(prompt, contains('Tinyrack voice mode is now on.'));
    expect(
      prompt,
      contains('Always use the speak tool for all user-facing communication.'),
    );
    expect(prompt, contains('</paseo_voice_mode>'));
  });

  test('disabled instructions supersede every previous voice block', () {
    final existing = [
      'Base system prompt',
      '<paseo_voice_mode>',
      'legacy voice instruction',
      '</paseo_voice_mode>',
      '<paseo_voice_mode>',
      'second legacy instruction',
      '</paseo_voice_mode>',
    ].join('\n\n');

    final prompt = buildVoiceModeSystemPrompt(existing, false);
    expect(prompt, contains('Base system prompt'));
    expect(prompt, contains('Tinyrack voice mode is now off.'));
    expect(
      prompt,
      contains(
        'Ignore any earlier Tinyrack voice mode instructions in this thread.',
      ),
    );
    expect(RegExp('<paseo_voice_mode>').allMatches(prompt), hasLength(1));
    expect(prompt, isNot(contains('legacy instruction')));
  });

  test('strips persisted voice blocks and normalizes empty prompts', () {
    final existing = [
      'Base system prompt',
      '<paseo_voice_mode>',
      'legacy voice instruction',
      '</paseo_voice_mode>',
    ].join('\n\n');
    expect(stripVoiceModeSystemPrompt(existing), 'Base system prompt');
    expect(
      stripVoiceModeSystemPrompt(
        [
          '<paseo_voice_mode>',
          'legacy voice instruction',
          '</paseo_voice_mode>',
        ].join('\n\n'),
      ),
      isNull,
    );
    expect(stripVoiceModeSystemPrompt(null), isNull);
    expect(stripVoiceModeSystemPrompt('   '), isNull);
  });

  test('wraps transcribed speech in the frozen instruction envelope', () {
    expect(
      wrapSpokenInput('Open the project'),
      '<spoken-input>\n'
      'Open the project\n'
      '</spoken-input>\n'
      '<instruction>This message was spoken by the user. Respond using the '
      'speak tool only, not normal messages, because the user may not be '
      'looking at the chat.</instruction>',
    );
  });
}
