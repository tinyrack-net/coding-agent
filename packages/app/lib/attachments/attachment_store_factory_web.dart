import 'attachment_store.dart';
import 'preferences_attachment_store.dart';

Future<AttachmentStore> createPlatformAttachmentStore() async =>
    PreferencesAttachmentStore();
