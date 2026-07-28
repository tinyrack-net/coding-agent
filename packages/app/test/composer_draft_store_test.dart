import 'dart:convert';

import 'package:coding_agent_app/attachments/attachment_store.dart';
import 'package:coding_agent_app/composer/composer_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('builds frozen agent, workspace draft, and new-workspace keys', () {
    expect(
      buildComposerDraftKey(serverId: ' local ', agentId: ' a1 '),
      'agent:local:a1',
    );
    expect(
      buildComposerDraftKey(
        serverId: 'host',
        agentId: 'ignored',
        draftId: ' draft-1 ',
      ),
      'draft:host:draft-1',
    );
    expect(buildNewWorkspaceComposerDraftKey(), 'new-workspace');
    expect(
      buildNewWorkspaceComposerDraftKey(' fork-1 '),
      'new-workspace:draft:fork-1',
    );
    expect(
      () => buildComposerDraftKey(serverId: ' ', agentId: 'a1'),
      throwsArgumentError,
    );
    expect(
      () => buildComposerDraftKey(serverId: 'host', agentId: ' '),
      throwsArgumentError,
    );
  });

  test('round-trips an active draft and attachment metadata', () async {
    final store = PreferencesComposerDraftStore();
    final draft = ComposerDraft(
      text: 'keep this',
      images: const [
        AttachmentMetadata(
          id: 'image-1',
          mimeType: 'image/png',
          storageType: AttachmentStorageType.desktopFile,
          storageKey: r'C:\attachments\image-1',
          createdAt: 10,
          fileName: 'image.png',
          byteSize: 3,
        ),
      ],
      updatedAt: 20,
    );

    await store.save('agent:a/1', draft);
    final restored = await store.load('agent:a/1');

    expect(restored?.text, 'keep this');
    expect(restored?.images.single.toJson(), draft.images.single.toJson());
    expect(restored?.lifecycle, ComposerDraftLifecycle.active);
  });

  test('finalized drafts are hidden and pruned after the frozen TTL', () async {
    var now = DateTime.fromMillisecondsSinceEpoch(1000);
    final store = PreferencesComposerDraftStore(clock: () => now);

    await store.save(
      'agent',
      ComposerDraft(
        text: 'active',
        images: const [],
        updatedAt: now.millisecondsSinceEpoch,
      ),
    );
    await store.clear('agent', lifecycle: ComposerDraftLifecycle.sent);
    expect(await store.load('agent'), isNull);

    now = now.add(composerFinalizedDraftTtl);
    expect(await store.load('agent'), isNull);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('invalid or version-mismatched records are removed', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'tinyrack.composer-draft.v1.YWdlbnQ',
      jsonEncode({
        'text': '',
        'images': const [],
        'lifecycle': 'active',
        'updatedAt': 0,
        'version': 99,
      }),
    );
    final store = PreferencesComposerDraftStore();

    expect(await store.load('agent'), isNull);
    expect(preferences.getKeys(), isEmpty);

    await preferences.setString(
      'tinyrack.composer-draft.v1.YWdlbnQ',
      'not-json',
    );
    expect(await store.load('agent'), isNull);
    expect(preferences.getKeys(), isEmpty);
  });

  test(
    'collects references from every active draft and prunes finalized rows',
    () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000);
      final store = PreferencesComposerDraftStore(clock: () => now);
      const first = AttachmentMetadata(
        id: 'first',
        mimeType: 'image/png',
        storageType: AttachmentStorageType.desktopFile,
        storageKey: 'first',
        createdAt: 1,
      );
      const second = AttachmentMetadata(
        id: 'second',
        mimeType: 'image/png',
        storageType: AttachmentStorageType.desktopFile,
        storageKey: 'second',
        createdAt: 2,
      );
      await Future.wait([
        store.save(
          'agent:local:a1',
          ComposerDraft(text: '', images: const [first], updatedAt: 1000),
        ),
        store.save(
          'draft:local:d1',
          ComposerDraft(text: '', images: const [second], updatedAt: 1000),
        ),
      ]);

      expect(await store.collectActiveAttachmentIds(), {'first', 'second'});
      await store.clear(
        'agent:local:a1',
        lifecycle: ComposerDraftLifecycle.sent,
      );
      expect(await store.collectActiveAttachmentIds(), {'second'});

      now = now.add(composerFinalizedDraftTtl);
      expect(await store.collectActiveAttachmentIds(), {'second'});
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getKeys(), hasLength(2));
    },
  );
}
