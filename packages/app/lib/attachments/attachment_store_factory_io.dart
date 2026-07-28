import 'dart:io';

import 'attachment_store.dart';
import 'file_attachment_store.dart';

Future<AttachmentStore> createPlatformAttachmentStore() async =>
    FileAttachmentStore(
      storageType: ioAttachmentStorageType(
        isMobile: Platform.isAndroid || Platform.isIOS,
      ),
    );

AttachmentStorageType ioAttachmentStorageType({required bool isMobile}) =>
    isMobile
    ? AttachmentStorageType.nativeFile
    : AttachmentStorageType.desktopFile;
