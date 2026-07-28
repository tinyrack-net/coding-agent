import 'attachment_store.dart';

Future<AttachmentStore> createPlatformAttachmentStore() {
  throw UnsupportedError('Attachment storage is unavailable on this platform.');
}
