import 'dart:typed_data';

import 'package:coding_agent_app/attachments/attachment_store.dart';
import 'package:coding_agent_app/composer/composer_image_attachments.dart';
import 'package:coding_agent_app/state/queued_messages_provider.dart';
import 'package:coding_agent_app/state/workspace_attachments_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('queue preserves order, supports take/restore, and owns image ids', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(queuedMessagesProvider.notifier);
    final image = PendingComposerImage(
      id: 'image-1',
      fileName: 'one.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList(const [1]),
      metadata: const AttachmentMetadata(
        id: 'image-1',
        mimeType: 'image/png',
        storageType: AttachmentStorageType.desktopFile,
        storageKey: 'image-1',
        byteSize: 1,
        createdAt: 1,
      ),
    );
    final screenshot = const AttachmentMetadata(
      id: 'browser-shot',
      mimeType: 'image/png',
      storageType: AttachmentStorageType.desktopFile,
      storageKey: 'browser-shot',
      byteSize: 1,
      createdAt: 1,
    );

    expect(
      notifier.enqueue(
        serverId: 'server-1',
        agentId: 'a1',
        text: '   ',
        messageId: 'empty',
      ),
      isNull,
    );
    final first = notifier.enqueue(
      serverId: 'server-1',
      agentId: 'a1',
      text: ' first ',
      images: [image],
      attachments: [
        WorkspaceContextAttachment(
          kind: 'browser_element',
          id: 'element-1',
          title: 'Button',
          subtitle: 'button',
          text: '<button>',
          url: null,
          screenshot: screenshot,
        ),
      ],
      messageId: 'first',
    )!;
    notifier.enqueue(
      serverId: 'server-1',
      agentId: 'a1',
      text: 'second',
      messageId: 'second',
    );
    notifier.enqueue(
      serverId: 'server-2',
      agentId: 'a1',
      text: 'other host',
      messageId: 'other',
    );

    expect(first.text, 'first');
    expect(notifier.attachmentIds(), {'image-1', 'browser-shot'});
    expect(
      notifier.takeFirst(serverId: 'server-1', agentId: 'a1')?.id,
      'first',
    );
    notifier.restoreFirst(serverId: 'server-1', agentId: 'a1', message: first);
    expect(
      container
          .read(queuedMessagesProvider)['server-1']!['a1']!
          .map((message) => message.id),
      ['first', 'second'],
    );
    expect(
      notifier.take(serverId: 'server-1', agentId: 'a1', messageId: 'missing'),
      isNull,
    );
    expect(
      notifier
          .take(serverId: 'server-1', agentId: 'a1', messageId: 'second')
          ?.id,
      'second',
    );
    notifier.clearAgent(serverId: 'server-1', agentId: 'a1');
    expect(
      container.read(queuedMessagesProvider)['server-2']!['a1']!.single.id,
      'other',
    );
    notifier.clearAgent(serverId: 'server-2', agentId: 'a1');
    expect(container.read(queuedMessagesProvider), isEmpty);
    expect(notifier.takeFirst(serverId: 'server-1', agentId: 'a1'), isNull);
  });

  test(
    'workspace browser screenshot owners follow add, replace, and clear',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final scope = container.read(
        workspaceAttachmentsProvider('/workspace').notifier,
      );

      scope.add(
        const WorkspaceContextAttachment(
          kind: 'browser_element',
          id: 'element-1',
          title: 'First',
          subtitle: 'first',
          text: '<div>',
          url: null,
          screenshot: AttachmentMetadata(
            id: 'shot-1',
            mimeType: 'image/png',
            storageType: AttachmentStorageType.desktopFile,
            storageKey: 'shot-1',
            byteSize: 10,
            createdAt: 1,
          ),
        ),
      );
      scope.add(
        const WorkspaceContextAttachment(
          kind: 'review',
          id: 'review-1',
          title: 'Review',
          subtitle: 'review',
          text: 'review',
          url: null,
          screenshot: AttachmentMetadata(
            id: 'ignored',
            mimeType: 'image/png',
            storageType: AttachmentStorageType.desktopFile,
            storageKey: 'ignored',
            byteSize: 10,
            createdAt: 1,
          ),
        ),
      );
      expect(
        container
            .read(workspaceScreenshotOwnersProvider.notifier)
            .attachmentIds(),
        {'shot-1'},
      );

      scope.add(
        const WorkspaceContextAttachment(
          kind: 'browser_element',
          id: 'element-1',
          title: 'Updated',
          subtitle: 'updated',
          text: '<button>',
          url: null,
          screenshot: AttachmentMetadata(
            id: 'shot-2',
            mimeType: 'image/png',
            storageType: AttachmentStorageType.desktopFile,
            storageKey: 'shot-2',
            byteSize: 12,
            createdAt: 1,
          ),
        ),
      );
      expect(
        container
            .read(workspaceScreenshotOwnersProvider.notifier)
            .attachmentIds(),
        {'shot-2'},
      );

      scope.remove('browser_element', 'element-1');
      expect(
        container
            .read(workspaceScreenshotOwnersProvider.notifier)
            .attachmentIds(),
        isEmpty,
      );
      scope.clear();
    },
  );
}
