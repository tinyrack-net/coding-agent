import 'package:fluent_ui/fluent_ui.dart';

import '../composer/composer_image_attachments.dart';

class ComposerImagePreview extends StatelessWidget {
  const ComposerImagePreview({
    super.key,
    required this.image,
    required this.onRemove,
  });

  final PendingComposerImage image;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Container(
    width: 112,
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
      border: Border.all(
        color: FluentTheme.of(context).resources.cardStrokeColorDefault,
      ),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(
            image.bytes,
            width: 100,
            height: 64,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox(
              width: 100,
              height: 64,
              child: Icon(FluentIcons.file_image),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: image.fileName,
                child: Text(
                  image.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(FluentIcons.chrome_close, size: 12),
              onPressed: onRemove,
            ),
          ],
        ),
      ],
    ),
  );
}
