import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('normalizes and tokenizes provider tool names', () {
    expect(
      normalizeToolName('  MCP__Paseo__Create_Agent  '),
      'mcp__paseo__create_agent',
    );
    expect(tokenizeToolName(' MCP__Paseo.Voice/SPEAK '), [
      'mcp',
      'paseo',
      'voice',
      'speak',
    ]);
    expect(tokenizeToolName('___'), isEmpty);
    expect(getToolLeafName('paseo.create_agent'), 'agent');
    expect(getToolLeafName('---'), isNull);
  });

  test('detects speak leaf names across provider conventions', () {
    expect(isSpeakToolName('speak'), isTrue);
    expect(isSpeakToolName(' paseo_voice.speak '), isTrue);
    expect(isSpeakToolName('mcp__paseo_voice__speak'), isTrue);
    expect(isSpeakToolName('speaker'), isFalse);
  });

  test(
    'recognizes likely namespace formats without broad double underscore',
    () {
      for (final name in [
        'paseo.create_agent',
        'paseo:create_agent',
        'paseo/create_agent',
        'mcp__paseo__create_agent',
        'paseo__create_agent',
      ]) {
        expect(isLikelyNamespacedToolName(name), isTrue, reason: name);
      }
      for (final name in ['Bash', 'foo__bar', '__foo__']) {
        expect(isLikelyNamespacedToolName(name), isFalse, reason: name);
      }
    },
  );

  test('detects frozen Paseo tool namespaces and excludes speak', () {
    for (final name in [
      'mcp__paseo__create_agent',
      'mcp__paseo__list_agents',
      'mcp__paseo_voice__create_agent',
      'paseo.create_agent',
      'paseo_voice.create_agent',
    ]) {
      expect(isPaseoToolName(name), isTrue, reason: name);
    }
    for (final name in [
      'mcp__paseo_voice__speak',
      'mcp__paseo__speak',
      'paseo.speak',
      'Bash',
      'Read',
      'mcp__other_server__some_tool',
      'other.create_agent',
      'paseo_create_agent',
    ]) {
      expect(isPaseoToolName(name), isFalse, reason: name);
    }
  });

  test('extracts only valid Paseo namespace leaves', () {
    expect(getPaseoToolLeafName('mcp__paseo__create_agent'), 'create_agent');
    expect(
      getPaseoToolLeafName('mcp__paseo_voice__browser__open'),
      'browser__open',
    );
    expect(getPaseoToolLeafName('paseo.create_agent'), 'create_agent');
    expect(getPaseoToolLeafName('paseo_voice.browser.open'), 'browser.open');
    for (final name in [
      'Bash',
      'mcp__other__create_agent',
      'other.create_agent',
      'paseo_create_agent',
    ]) {
      expect(getPaseoToolLeafName(name), isNull, reason: name);
    }
  });

  test('classifies external tools from speak or conservative namespaces', () {
    for (final name in [
      'speak',
      'paseo.speak',
      'mcp__server__tool',
      'server/tool',
    ]) {
      expect(isLikelyExternalToolName(name), isTrue, reason: name);
    }
    for (final name in ['', '   ', 'Bash', 'foo__bar']) {
      expect(isLikelyExternalToolName(name), isFalse, reason: name);
    }
  });
}
