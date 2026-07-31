import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../composer/composer_image_attachments.dart';
import '../composer/composer_image_attachment_service.dart';
import '../composer/composer_clipboard_reader.dart';
import '../composer/composer_draft_store.dart';
import '../composer/agent_command_autocomplete.dart';
import '../composer/dictation_shortcut_controller.dart';
import '../composer/file_mention_autocomplete.dart';
import '../attachments/attachment_store.dart';
import '../keyboard/keyboard_action_dispatcher.dart';
import '../keyboard/keyboard_ime.dart';
import '../keyboard/shortcut_engine.dart';
import '../keyboard/shortcut_focus_scope.dart';
import '../core/provider_notice_toast.dart';
import '../state/agents_provider.dart';
import '../state/agent_commands_provider.dart';
import '../state/create_flow_provider.dart';
import '../state/daemon_providers.dart';
import '../state/directory_suggestions_provider.dart';
import '../state/host_registry_provider.dart';
import '../state/queued_messages_provider.dart';
import '../state/review_draft_provider.dart';
import '../state/timeline_provider.dart';
import '../state/workspace_attachments_provider.dart';
import '../providers/agent_commands.dart';
import '../widgets/fluent/toast.dart';

enum ComposerClientSlashCommand { exit, clear }

const _clientCommandEntries = <CommandAutocompleteEntry>[
  CommandAutocompleteEntry(
    command: AgentSlashCommand(
      name: 'exit',
      description: 'Archive the current agent',
      argumentHint: '',
    ),
    aliases: ['quit', 'q'],
    isClient: true,
  ),
  CommandAutocompleteEntry(
    command: AgentSlashCommand(
      name: 'clear',
      description: 'Archive this agent and start a fresh draft',
      argumentHint: '',
    ),
    aliases: ['new'],
    isClient: true,
  ),
];
const _clientCommandNames = {'exit', 'clear'};

/// Prompt input: Enter sends, Shift+Enter inserts a newline. The send button
/// turns into a stop (interrupt) button while the agent is busy.
class Composer extends ConsumerStatefulWidget {
  const Composer({
    super.key,
    required this.agentId,
    this.serverId = 'local',
    this.onInputFocus,
    this.onPromptSend,
    this.keyboardActionsEnabled = true,
    this.imageAttachmentService,
    this.clipboardReader = const SystemComposerClipboardReader(),
    this.draftStore,
    this.onClientSlashCommand,
    this.showVoiceOverlay = false,
    this.voiceOverlay,
    this.dictationShortcutController,
  }) : assert(!showVoiceOverlay || voiceOverlay != null);

  final String agentId;
  final String serverId;
  final VoidCallback? onInputFocus;
  final VoidCallback? onPromptSend;
  final bool keyboardActionsEnabled;
  final ComposerImageAttachmentService? imageAttachmentService;
  final ComposerClipboardReader clipboardReader;
  final ComposerDraftStore? draftStore;
  final ValueChanged<ComposerClientSlashCommand>? onClientSlashCommand;
  final bool showVoiceOverlay;
  final Widget? voiceOverlay;
  final DictationShortcutController? dictationShortcutController;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final List<PendingComposerImage> _images = [];
  late final ComposerImageAttachmentService _imageAttachmentService;
  late final ComposerDraftStore _draftStore;
  late final void Function() _disposeKeyboardHandler;
  var _dropActive = false;
  var _addingImages = false;
  var _draftRevision = 0;
  var _suspendDraftPersistence = false;
  var _sendingQueued = false;
  var _queuedDrainScheduled = false;
  var _autocompleteSelectedIndex = 0;
  var _debouncedFileFilterQuery = '';
  Timer? _fileFilterDebounce;
  Future<void> _draftWrite = Future.value();

  String get _draftKey =>
      buildComposerDraftKey(serverId: widget.serverId, agentId: widget.agentId);

  @override
  void initState() {
    super.initState();
    _imageAttachmentService =
        widget.imageAttachmentService ?? ComposerImageAttachmentService();
    _draftStore = widget.draftStore ?? PreferencesComposerDraftStore();
    _controller.addListener(_onDraftTextChanged);
    unawaited(_hydrateDraft());
    _focusNode.addListener(_onFocusChanged);
    _disposeKeyboardHandler = keyboardActionDispatcher.registerHandler(
      KeyboardActionHandler(
        handlerId: 'composer:${widget.agentId}',
        actions: {
          'message-input.focus',
          'message-input.send',
          'message-input.mode-cycle',
          if (widget.dictationShortcutController != null)
            'message-input.dictation-toggle',
        },
        enabled: true,
        priority: 100,
        isActive: () => mounted && widget.keyboardActionsEnabled,
        handle: _handleKeyboardAction,
      ),
    );
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) widget.onInputFocus?.call();
  }

  @override
  void dispose() {
    _disposeKeyboardHandler();
    _controller.removeListener(_onDraftTextChanged);
    _fileFilterDebounce?.cancel();
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onDraftTextChanged() {
    _scheduleFileFilterQuery();
    if (!_suspendDraftPersistence) {
      _draftRevision += 1;
      _persistDraft();
    }
    if (mounted) {
      setState(() => _autocompleteSelectedIndex = 0);
    }
  }

  void _scheduleFileFilterQuery() {
    final selection = _controller.selection;
    final mention = findActiveFileMention(
      text: _controller.text,
      cursorIndex: selection.isValid
          ? selection.extentOffset
          : _controller.text.length,
    );
    final query = mention?.query ?? '';
    _fileFilterDebounce?.cancel();
    if (query == _debouncedFileFilterQuery) return;
    _fileFilterDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      setState(() => _debouncedFileFilterQuery = query);
    });
  }

  Future<void> _hydrateDraft() async {
    final revision = _draftRevision;
    final draft = await _draftStore.load(_draftKey);
    if (!mounted || revision != _draftRevision) return;
    if (draft == null) {
      _scheduleAttachmentGc();
      return;
    }
    final images = await _imageAttachmentService.restore(draft.images);
    if (!mounted || revision != _draftRevision) return;
    final attachmentNotifier = ref.read(
      workspaceAttachmentsProvider(_draftKey).notifier,
    );
    for (final file in draft.workspaceFiles) {
      attachmentNotifier.add(
        workspaceFileContextAttachment(file.path, selection: file.selection),
      );
    }
    _suspendDraftPersistence = true;
    _controller.text = draft.text;
    _suspendDraftPersistence = false;
    setState(() => _images.addAll(images));
    _scheduleAttachmentGc();
  }

  void _persistDraft() {
    final metadata = _images
        .map((image) => image.metadata)
        .whereType<AttachmentMetadata>()
        .toList(growable: false);
    final draft = ComposerDraft(
      text: _controller.text,
      images: metadata,
      workspaceFiles: [
        for (final attachment in ref.read(
          workspaceAttachmentsProvider(_draftKey),
        ))
          if (attachment.isWorkspaceFile)
            ComposerWorkspaceFileAttachment(
              path: attachment.workspaceFile?.path ?? attachment.id,
              selection:
                  attachment.workspaceFile?.selection ??
                  ComposerWorkspaceFileSelection.wholeFileSelection,
            ),
      ],
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _draftWrite = _draftWrite
        .then((_) async {
          if (draft.hasContent) {
            await _draftStore.save(_draftKey, draft);
          } else {
            await _draftStore.clear(
              _draftKey,
              lifecycle: ComposerDraftLifecycle.abandoned,
            );
          }
          await _garbageCollectDraftAttachments();
        })
        .catchError((_) {
          // Draft persistence is best effort and must not block composing.
        });
  }

  void _clearVisibleDraft() {
    _suspendDraftPersistence = true;
    _controller.clear();
    _suspendDraftPersistence = false;
    setState(_images.clear);
  }

  bool _handleKeyboardAction(KeyboardActionDefinition action) {
    switch (action.id) {
      case 'message-input.focus':
        _focusNode.requestFocus();
        return true;
      case 'message-input.send':
        unawaited(_send());
        return true;
      case 'message-input.mode-cycle':
        unawaited(_cycleMode());
        return true;
      case 'message-input.dictation-toggle':
        return widget.dictationShortcutController?.toggle() ?? false;
      default:
        return false;
    }
  }

  Future<void> _cycleMode() async {
    final agent = ref.read(agentSummaryProvider(widget.agentId));
    if (agent == null) return;
    const modes = [AgentMode.plan, AgentMode.normal, AgentMode.fullAccess];
    final index = modes.indexOf(agent.mode);
    final next = modes[(index + 1) % modes.length];
    try {
      final notice = await ref
          .read(daemonClientProvider)
          .setAgentMode(widget.agentId, next.name);
      if (mounted) showProviderNoticeToast(context, notice);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Failed to change mode: $e',
        severity: InfoBarSeverity.error,
      );
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final agent = ref.read(agentSummaryProvider(widget.agentId));
    final cwd = agent?.cwd;
    final attachments = mergeWorkspaceContextAttachments(
      cwd == null
          ? const <WorkspaceContextAttachment>[]
          : ref.read(workspaceAttachmentsProvider(cwd)),
      ref.read(workspaceAttachmentsProvider(_draftKey)),
    );
    if (text.isEmpty && attachments.isEmpty && _images.isEmpty) return;
    final images = List<PendingComposerImage>.of(_images);
    if (agent?.runState == AgentRunState.running) {
      final queued = ref
          .read(queuedMessagesProvider.notifier)
          .enqueue(
            serverId: widget.serverId,
            agentId: widget.agentId,
            text: text,
            images: images,
            attachments: attachments,
          );
      if (queued == null) return;
      widget.onPromptSend?.call();
      _clearVisibleDraft();
      if (cwd != null) {
        _clearReviewDrafts(attachments);
        ref.read(workspaceAttachmentsProvider(cwd).notifier).clear();
      }
      ref.read(workspaceAttachmentsProvider(_draftKey).notifier).clear();
      _draftWrite = _draftWrite
          .then(
            (_) => _draftStore.clear(
              _draftKey,
              lifecycle: ComposerDraftLifecycle.abandoned,
            ),
          )
          .then((_) => _garbageCollectDraftAttachments());
      return;
    }
    final promptImages = [
      ...await _imageAttachmentService.encodeForSend(images),
      ...await _imageAttachmentService.encodeMetadataForSend(
        _browserScreenshots(attachments),
      ),
    ];
    if (text.isEmpty && attachments.isEmpty && promptImages.isEmpty) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Failed to read attached images.',
        severity: InfoBarSeverity.error,
      );
      return;
    }
    final clientMessageId = const Uuid().v4();
    final semanticAttachments = attachments
        .map((attachment) => attachment.toAgentAttachment())
        .toList(growable: false);
    ref
        .read(timelineProvider(widget.agentId).notifier)
        .appendOptimisticUserMessage(
          OptimisticUserMessage(
            id: clientMessageId,
            text: text,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            images: [
              for (final image in images) ?image.metadata,
              ..._browserScreenshots(attachments),
            ],
            attachments: semanticAttachments,
          ),
        );
    widget.onPromptSend?.call();
    _clearVisibleDraft();
    try {
      await ref
          .read(agentActionsProvider)
          .prompt(
            widget.agentId,
            text,
            images: promptImages,
            attachments: semanticAttachments,
            clientMessageId: clientMessageId,
          );
      if (cwd != null) {
        _clearReviewDrafts(attachments);
        ref.read(workspaceAttachmentsProvider(cwd).notifier).clear();
      }
      ref.read(workspaceAttachmentsProvider(_draftKey).notifier).clear();
      _draftWrite = _draftWrite
          .then(
            (_) => _draftStore.clear(
              _draftKey,
              lifecycle: ComposerDraftLifecycle.sent,
            ),
          )
          .then((_) => _garbageCollectDraftAttachments());
    } catch (e) {
      ref
          .read(timelineProvider(widget.agentId).notifier)
          .removeOptimisticUserMessage(clientMessageId);
      if (!mounted) return;
      _suspendDraftPersistence = true;
      _controller.text = text;
      _suspendDraftPersistence = false;
      setState(() => _images.insertAll(0, images));
      _persistDraft();
      AppToast.show(
        context,
        'Failed to send prompt: $e',
        severity: InfoBarSeverity.error,
      );
    }
  }

  void _clearReviewDrafts(Iterable<WorkspaceContextAttachment> attachments) {
    final notifier = ref.read(reviewDraftProvider.notifier);
    for (final attachment in attachments) {
      final key = attachment.reviewDraftKey;
      if (key != null) notifier.clear(key);
    }
  }

  void _scheduleAttachmentGc() {
    _draftWrite = _draftWrite.then((_) => _garbageCollectDraftAttachments());
  }

  Future<void> _garbageCollectDraftAttachments() async {
    try {
      final referencedIds = await _draftStore.collectActiveAttachmentIds()
        ..addAll(ref.read(createFlowProvider.notifier).activeAttachmentIds())
        ..addAll(
          ref.read(timelineAttachmentOwnersProvider.notifier).attachmentIds(),
        )
        ..addAll(ref.read(queuedMessagesProvider.notifier).attachmentIds())
        ..addAll(
          ref.read(workspaceScreenshotOwnersProvider.notifier).attachmentIds(),
        );
      await _imageAttachmentService.garbageCollectReferenced(referencedIds);
    } catch (_) {
      // GC is best effort and must never interrupt the composer.
    }
  }

  Future<void> _addDroppedImages(List<DropItem> files) async {
    if (_addingImages) return;
    setState(() {
      _addingImages = true;
      _dropActive = false;
    });
    try {
      final images = await _imageAttachmentService.persistDropped(files);
      if (!mounted || images.isEmpty) return;
      setState(() => _images.addAll(images));
      _persistDraft();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Failed to attach image: $error',
        severity: InfoBarSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _addingImages = false);
    }
  }

  Future<void> _pickImages() async {
    if (_addingImages) return;
    setState(() => _addingImages = true);
    try {
      final images = await _imageAttachmentService.pick();
      if (!mounted || images.isEmpty) return;
      setState(() => _images.addAll(images));
      _persistDraft();
    } catch (error) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Failed to attach image: $error',
        severity: InfoBarSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _addingImages = false);
    }
  }

  Future<void> _pasteClipboard() async {
    if (_addingImages) return;
    setState(() => _addingImages = true);
    try {
      final images = await _imageAttachmentService.paste(
        widget.clipboardReader,
      );
      if (!mounted) return;
      if (images == null) {
        final text = await widget.clipboardReader.readText();
        if (mounted) _insertPastedText(text);
      } else if (images.isNotEmpty) {
        setState(() => _images.addAll(images));
        _persistDraft();
      }
    } catch (_) {
      if (!mounted) return;
      try {
        final text = await widget.clipboardReader.readText();
        if (mounted) _insertPastedText(text);
      } catch (_) {
        // Pasteboard failures remain silent like Paseo's browser handler.
      }
    } finally {
      if (mounted) setState(() => _addingImages = false);
    }
  }

  void _insertPastedText(String? text) {
    if (text == null || text.isEmpty) return;
    final value = _controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(start, value.text.length);
    final next = value.text.replaceRange(start, end, text);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  Widget _buildTextContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    return WindowsTextSelectionToolbar(
      buttonItems: [
        for (final item in editableTextState.contextMenuButtonItems)
          item.type == ContextMenuButtonType.paste
              ? item.copyWith(
                  onPressed: () {
                    editableTextState.hideToolbar();
                    unawaited(_pasteClipboard());
                  },
                )
              : item,
      ],
      anchors: editableTextState.contextMenuAnchors,
    );
  }

  void _removeImage(PendingComposerImage image) {
    setState(() => _images.remove(image));
    _persistDraft();
    unawaited(_imageAttachmentService.delete(image));
  }

  Future<void> _interrupt() async {
    try {
      await ref.read(agentActionsProvider).interrupt(widget.agentId);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Failed to interrupt: $e',
        severity: InfoBarSeverity.error,
      );
    }
  }

  Future<void> _editQueued(String messageId) async {
    final message = ref
        .read(queuedMessagesProvider.notifier)
        .take(
          serverId: widget.serverId,
          agentId: widget.agentId,
          messageId: messageId,
        );
    if (message == null) return;
    final cwd = ref.read(agentSummaryProvider(widget.agentId))?.cwd;
    _suspendDraftPersistence = true;
    _controller.text = message.text;
    _suspendDraftPersistence = false;
    setState(() {
      _images
        ..clear()
        ..addAll(message.images);
    });
    for (final attachment in message.attachments) {
      final scope = attachment.isWorkspaceFile ? _draftKey : cwd;
      if (scope != null) {
        ref.read(workspaceAttachmentsProvider(scope).notifier).add(attachment);
      }
    }
    _persistDraft();
  }

  Future<void> _sendQueuedNow(String messageId) async {
    final message = ref
        .read(queuedMessagesProvider.notifier)
        .take(
          serverId: widget.serverId,
          agentId: widget.agentId,
          messageId: messageId,
        );
    if (message == null) return;
    await _submitQueuedMessage(message);
  }

  Future<void> _submitQueuedMessage(QueuedComposerMessage message) async {
    if (_sendingQueued) {
      ref
          .read(queuedMessagesProvider.notifier)
          .restoreFirst(
            serverId: widget.serverId,
            agentId: widget.agentId,
            message: message,
          );
      return;
    }
    _sendingQueued = true;
    final clientMessageId = const Uuid().v4();
    final semanticAttachments = message.attachments
        .map((attachment) => attachment.toAgentAttachment())
        .toList(growable: false);
    ref
        .read(timelineProvider(widget.agentId).notifier)
        .appendOptimisticUserMessage(
          OptimisticUserMessage(
            id: clientMessageId,
            text: message.text,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            images: [
              for (final image in message.images) ?image.metadata,
              ..._browserScreenshots(message.attachments),
            ],
            attachments: semanticAttachments,
          ),
        );
    widget.onPromptSend?.call();
    try {
      final promptImages = [
        ...await _imageAttachmentService.encodeForSend(message.images),
        ...await _imageAttachmentService.encodeMetadataForSend(
          _browserScreenshots(message.attachments),
        ),
      ];
      if (message.images.isNotEmpty && promptImages.isEmpty) {
        throw StateError('Failed to read attached images.');
      }
      await ref
          .read(agentActionsProvider)
          .prompt(
            widget.agentId,
            message.text,
            images: promptImages,
            attachments: semanticAttachments,
            clientMessageId: clientMessageId,
          );
      await _garbageCollectDraftAttachments();
    } catch (error) {
      ref
          .read(timelineProvider(widget.agentId).notifier)
          .removeOptimisticUserMessage(clientMessageId);
      ref
          .read(queuedMessagesProvider.notifier)
          .restoreFirst(
            serverId: widget.serverId,
            agentId: widget.agentId,
            message: message,
          );
      if (mounted) {
        AppToast.show(
          context,
          'Failed to send queued prompt: $error',
          severity: InfoBarSeverity.error,
        );
      }
    } finally {
      _sendingQueued = false;
    }
  }

  void _scheduleQueuedDrain(List<QueuedComposerMessage> queue) {
    if (_queuedDrainScheduled || _sendingQueued || queue.isEmpty) return;
    _queuedDrainScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queuedDrainScheduled = false;
      if (!mounted || _sendingQueued) return;
      final runState = ref.read(
        agentSummaryProvider(widget.agentId).select((agent) => agent?.runState),
      );
      if (runState == AgentRunState.running) return;
      final message = ref
          .read(queuedMessagesProvider.notifier)
          .takeFirst(serverId: widget.serverId, agentId: widget.agentId);
      if (message != null) unawaited(_submitQueuedMessage(message));
    });
  }

  Iterable<AttachmentMetadata> _browserScreenshots(
    Iterable<WorkspaceContextAttachment> attachments,
  ) sync* {
    for (final attachment in attachments) {
      if (attachment.kind == 'browser_element' &&
          attachment.screenshot != null) {
        yield attachment.screenshot!;
      }
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (isImeComposingTextEditingValue(_controller.value)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) &&
        !HardwareKeyboard.instance.isAltPressed) {
      unawaited(_pasteClipboard());
      return KeyEventResult.handled;
    }
    final autocomplete = _autocompleteSnapshot();
    if (autocomplete.fileMention != null) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (autocomplete.fileEntries.isEmpty) return KeyEventResult.handled;
        final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
        setState(() {
          _autocompleteSelectedIndex =
              (_autocompleteSelectedIndex + delta) %
              autocomplete.fileEntries.length;
        });
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.tab ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        if (autocomplete.fileEntries.isNotEmpty) {
          _applyFileAutocompleteEntry(
            autocomplete.fileEntries[_autocompleteSelectedIndex.clamp(
              0,
              autocomplete.fileEntries.length - 1,
            )],
            autocomplete.fileMention!,
          );
        }
        return KeyEventResult.handled;
      }
    } else if (autocomplete.commandRange != null) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (autocomplete.commandEntries.isEmpty) {
          return KeyEventResult.handled;
        }
        final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
        setState(() {
          _autocompleteSelectedIndex =
              (_autocompleteSelectedIndex + delta) %
              autocomplete.commandEntries.length;
        });
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (autocomplete.commandRange!.position == SlashCommandPosition.start) {
          _controller.clear();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.tab ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        if (autocomplete.commandEntries.isNotEmpty) {
          _applyAutocompleteEntry(
            autocomplete.commandEntries[_autocompleteSelectedIndex.clamp(
              0,
              autocomplete.commandEntries.length - 1,
            )],
            autocomplete.commandRange!,
          );
        }
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (shift) return KeyEventResult.ignored; // let TextField insert newline
    _send();
    return KeyEventResult.handled;
  }

  ({
    SlashCommandRange? commandRange,
    FileMentionRange? fileMention,
    List<CommandAutocompleteEntry> commandEntries,
    List<DirectorySuggestionEntry> fileEntries,
  })
  _autocompleteSnapshot() {
    final selection = _controller.selection;
    final cursor = selection.isValid
        ? selection.extentOffset
        : _controller.text.length;
    final fileMention = findActiveFileMention(
      text: _controller.text,
      cursorIndex: cursor,
    );
    final commandRange = fileMention == null
        ? findActiveSlashCommand(text: _controller.text, cursorIndex: cursor)
        : null;
    final serverId = ref.read(activeHostProvider)?.serverId ?? 'local';
    final commandState = ref.read(
      agentCommandsProvider(
        AgentCommandsScope(
          client: ref.read(daemonClientProvider),
          serverId: serverId,
          agentId: widget.agentId,
          enabled: commandRange != null,
        ),
      ),
    );
    final cwd =
        ref.read(agentSummaryProvider(widget.agentId))?.cwd.trim() ?? '';
    final fileState = ref.read(
      directorySuggestionsProvider(
        DirectorySuggestionsScope(
          client: ref.read(daemonClientProvider),
          serverId: serverId,
          cwd: cwd,
          query: _debouncedFileFilterQuery,
          enabled: fileMention != null,
        ),
      ),
    );
    return (
      commandRange: commandRange,
      fileMention: fileMention,
      commandEntries: _buildAutocompleteEntries(
        commandRange,
        commandState.commands,
      ),
      fileEntries: fileState.entries,
    );
  }

  List<CommandAutocompleteEntry> _buildAutocompleteEntries(
    SlashCommandRange? range,
    List<AgentSlashCommand> providerCommands,
  ) {
    if (range == null) return const [];
    final providerEntries = [
      for (final command in providerCommands)
        CommandAutocompleteEntry(command: command),
    ];
    final available = range.position == SlashCommandPosition.inline
        ? filterInlineSkillCommandEntries(providerEntries)
        : <CommandAutocompleteEntry>[
            ..._clientCommandEntries,
            ...providerEntries.where(
              (entry) => !_clientCommandNames.contains(entry.command.name),
            ),
          ];
    return filterAndRankCommandAutocompleteEntries(available, range.query);
  }

  void _applyAutocompleteEntry(
    CommandAutocompleteEntry entry,
    SlashCommandRange range,
  ) {
    if (entry.isClient && widget.onClientSlashCommand != null) {
      widget.onClientSlashCommand!(
        entry.command.name == 'exit'
            ? ComposerClientSlashCommand.exit
            : ComposerClientSlashCommand.clear,
      );
      return;
    }
    final appendsTrailingSpace = range.end == _controller.text.length;
    final next = applySlashCommandReplacement(
      text: _controller.text,
      command: range,
      commandName: entry.command.name,
    );
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset:
            range.start +
            entry.command.name.length +
            1 +
            (appendsTrailingSpace ? 1 : 0),
      ),
    );
    _focusNode.requestFocus();
  }

  void _applyFileAutocompleteEntry(
    DirectorySuggestionEntry entry,
    FileMentionRange mention,
  ) {
    final quotedPath = formatQuotedFileMentionPath(entry.path);
    final next = applyFileMentionReplacement(
      text: _controller.text,
      mention: mention,
      relativePath: entry.path,
    );
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: mention.start + quotedPath.length,
      ),
    );
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final runState = ref.watch(
      agentSummaryProvider(widget.agentId).select((a) => a?.runState),
    );
    final usage = ref.watch(
      agentSummaryProvider(widget.agentId).select((a) => a?.lastUsage),
    );
    final cwd = ref.watch(
      agentSummaryProvider(widget.agentId).select((agent) => agent?.cwd),
    );
    final attachments = mergeWorkspaceContextAttachments(
      cwd == null
          ? const <WorkspaceContextAttachment>[]
          : ref.watch(workspaceAttachmentsProvider(cwd)),
      ref.watch(workspaceAttachmentsProvider(_draftKey)),
    );
    ref.listen<int>(composerAttachmentFocusRequestProvider(_draftKey), (
      previous,
      next,
    ) {
      if (previous == null || previous == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    });
    final queuedMessages =
        ref.watch(queuedMessagesProvider)[widget.serverId]?[widget.agentId] ??
        const [];
    final selection = _controller.selection;
    final fileMentionRange = findActiveFileMention(
      text: _controller.text,
      cursorIndex: selection.isValid
          ? selection.extentOffset
          : _controller.text.length,
    );
    final autocompleteRange = fileMentionRange == null
        ? findActiveSlashCommand(
            text: _controller.text,
            cursorIndex: selection.isValid
                ? selection.extentOffset
                : _controller.text.length,
          )
        : null;
    final serverId = ref.watch(activeHostProvider)?.serverId ?? 'local';
    final autocompleteState = ref.watch(
      agentCommandsProvider(
        AgentCommandsScope(
          client: ref.watch(daemonClientProvider),
          serverId: serverId,
          agentId: widget.agentId,
          enabled: autocompleteRange != null,
        ),
      ),
    );
    final autocompleteEntries = _buildAutocompleteEntries(
      autocompleteRange,
      autocompleteState.commands,
    );
    final fileAutocompleteState = ref.watch(
      directorySuggestionsProvider(
        DirectorySuggestionsScope(
          client: ref.watch(daemonClientProvider),
          serverId: serverId,
          cwd: cwd?.trim() ?? '',
          query: _debouncedFileFilterQuery,
          enabled: fileMentionRange != null,
        ),
      ),
    );
    final visibleAutocompleteLength = fileMentionRange != null
        ? fileAutocompleteState.entries.length
        : autocompleteEntries.length;
    final selectedAutocompleteIndex = visibleAutocompleteLength == 0
        ? -1
        : _autocompleteSelectedIndex.clamp(0, visibleAutocompleteLength - 1);
    final busy =
        runState == AgentRunState.running ||
        runState == AgentRunState.awaitingPermission;
    if (!busy && queuedMessages.isNotEmpty) {
      _scheduleQueuedDrain(queuedMessages);
    }

    final composer = DropTarget(
      onDragEntered: (_) {
        if (!_dropActive) setState(() => _dropActive = true);
      },
      onDragExited: (_) {
        if (_dropActive) setState(() => _dropActive = false);
      },
      onDragDone: (details) => unawaited(_addDroppedImages(details.files)),
      child: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (queuedMessages.isNotEmpty) ...[
                    for (final message in queuedMessages)
                      _QueuedMessageRow(
                        message: message,
                        onEdit: () => unawaited(_editQueued(message.id)),
                        onSendNow: () => unawaited(_sendQueuedNow(message.id)),
                      ),
                    const SizedBox(height: 8),
                  ],
                  if (_images.isNotEmpty) ...[
                    SizedBox(
                      height: 68,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _images.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final image = _images[index];
                          return _ImageAttachmentPreview(
                            image: image,
                            onRemove: () => _removeImage(image),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (attachments.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final attachment in attachments)
                          ContextAttachmentPill(
                            attachment: attachment,
                            onRemove: () {
                              final scope = attachment.isWorkspaceFile
                                  ? _draftKey
                                  : cwd;
                              if (scope == null) return;
                              ref
                                  .read(
                                    workspaceAttachmentsProvider(
                                      scope,
                                    ).notifier,
                                  )
                                  .removeAttachment(attachment);
                              _persistDraft();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (fileMentionRange != null) ...[
                    ComposerFileAutocompletePopup(
                      key: const ValueKey('composer-file-autocomplete'),
                      entries: fileAutocompleteState.entries,
                      selectedIndex: selectedAutocompleteIndex,
                      isLoading:
                          fileAutocompleteState.isLoading &&
                          fileAutocompleteState.entries.isEmpty,
                      error: fileAutocompleteState.error,
                      onSelected: (entry) =>
                          _applyFileAutocompleteEntry(entry, fileMentionRange),
                    ),
                    const SizedBox(height: 8),
                  ] else if (autocompleteRange != null) ...[
                    ComposerCommandAutocompletePopup(
                      key: const ValueKey('composer-command-autocomplete'),
                      entries: autocompleteEntries,
                      selectedIndex: selectedAutocompleteIndex,
                      isLoading: autocompleteState.isLoading,
                      error: autocompleteState.error,
                      onSelected: (entry) =>
                          _applyAutocompleteEntry(entry, autocompleteRange),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Tooltip(
                        message: 'Attach images',
                        child: IconButton(
                          key: const ValueKey('composer-image-picker'),
                          icon: const Icon(FluentIcons.photo_collection),
                          onPressed: _addingImages ? null : _pickImages,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ShortcutFocusScope(
                          scope: KeyboardFocusScope.messageInput,
                          child: Focus(
                            onKeyEvent: _onKeyEvent,
                            child: TextBox(
                              controller: _controller,
                              focusNode: _focusNode,
                              minLines: 1,
                              maxLines: 8,
                              keyboardType: TextInputType.multiline,
                              textInputAction: TextInputAction.newline,
                              contextMenuBuilder: _buildTextContextMenu,
                              placeholder: 'Message the agent… (Enter to send)',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (usage case final usage?)
                        _ContextWindowMeter(usage: usage),
                      if (usage != null) const SizedBox(width: 8),
                      Tooltip(
                        message: busy ? 'Stop' : 'Send',
                        child: FilledButton(
                          onPressed: busy ? _interrupt : _send,
                          child: Icon(
                            busy ? FluentIcons.stop : FluentIcons.send,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: const ValueKey('composer-image-drop-overlay'),
                opacity: _dropActive ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: Container(
                  decoration: BoxDecoration(
                    color: FluentTheme.of(
                      context,
                    ).accentColor.withValues(alpha: 0.08),
                    border: Border.all(
                      color: FluentTheme.of(context).accentColor,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: const Text('Drop images to attach'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return ComposerVoiceSurface(
      showOverlay: widget.showVoiceOverlay,
      composer: composer,
      overlay: widget.voiceOverlay ?? const SizedBox.shrink(),
    );
  }
}

/// Keeps the input and voice overlay presentation derived from one synchronous
/// state, matching Paseo's dictation/resume behavior without an exit animation.
class ComposerVoiceSurface extends StatelessWidget {
  const ComposerVoiceSurface({
    super.key,
    required this.showOverlay,
    required this.composer,
    required this.overlay,
  });

  final bool showOverlay;
  final Widget composer;
  final Widget overlay;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      IgnorePointer(
        key: const ValueKey('composer-input-pointer-state'),
        ignoring: showOverlay,
        child: Opacity(
          key: const ValueKey('composer-input-surface'),
          opacity: showOverlay ? 0 : 1,
          child: composer,
        ),
      ),
      Positioned.fill(
        child: IgnorePointer(
          key: const ValueKey('composer-voice-overlay-pointer-state'),
          ignoring: !showOverlay,
          child: Opacity(
            key: const ValueKey('composer-voice-overlay-surface'),
            opacity: showOverlay ? 1 : 0,
            child: overlay,
          ),
        ),
      ),
    ],
  );
}

class ComposerFileAutocompletePopup extends StatelessWidget {
  const ComposerFileAutocompletePopup({
    super.key,
    required this.entries,
    required this.selectedIndex,
    required this.isLoading,
    required this.error,
    required this.onSelected,
  });

  final List<DirectorySuggestionEntry> entries;
  final int selectedIndex;
  final bool isLoading;
  final Object? error;
  final ValueChanged<DirectorySuggestionEntry> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border.all(color: theme.resources.controlStrokeColorDefault),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: isLoading
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Searching workspace…'),
            )
          : error != null
          ? Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Error: $error'),
            )
          : entries.isEmpty
          ? const Padding(padding: EdgeInsets.all(12), child: Text('No files'))
          : ListView.builder(
              shrinkWrap: true,
              reverse: true,
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile.selectable(
                  key: ValueKey(
                    'composer-file-autocomplete-'
                    '${entry.kind.name}-${entry.path}',
                  ),
                  selected: index == selectedIndex,
                  leading: Icon(
                    entry.kind == DirectorySuggestionKind.directory
                        ? FluentIcons.folder
                        : FluentIcons.page,
                    size: 16,
                  ),
                  title: Text(
                    entry.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: () => onSelected(entry),
                );
              },
            ),
    );
  }
}

class ComposerCommandAutocompletePopup extends StatelessWidget {
  const ComposerCommandAutocompletePopup({
    super.key,
    required this.entries,
    required this.selectedIndex,
    required this.isLoading,
    required this.error,
    required this.onSelected,
  });

  final List<CommandAutocompleteEntry> entries;
  final int selectedIndex;
  final bool isLoading;
  final Object? error;
  final ValueChanged<CommandAutocompleteEntry> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final selected = selectedIndex >= 0 ? entries[selectedIndex] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selected != null && selected.command.description.isNotEmpty) ...[
          Container(
            key: const ValueKey('composer-command-autocomplete-detail'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.cardColor,
              border: Border.all(color: theme.accentColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('/${selected.command.name}'),
                const SizedBox(height: 4),
                Text(
                  selected.command.description,
                  style: theme.typography.caption,
                ),
                if (selected.command.argumentHint.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    selected.command.argumentHint,
                    style: theme.typography.caption,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
        Container(
          constraints: const BoxConstraints(maxHeight: 220),
          decoration: BoxDecoration(
            color: theme.cardColor,
            border: Border.all(
              color: theme.resources.controlStrokeColorDefault,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: isLoading
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Loading commands…'),
                )
              : error != null
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Error: $error'),
                )
              : entries.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No commands'),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  reverse: true,
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return ListTile.selectable(
                      key: ValueKey(
                        'composer-command-autocomplete-${entry.command.name}',
                      ),
                      selected: index == selectedIndex,
                      title: Text('/${entry.command.name}'),
                      subtitle: entry.command.description.isEmpty
                          ? null
                          : Text(
                              entry.command.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      onPressed: () => onSelected(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _QueuedMessageRow extends StatelessWidget {
  const _QueuedMessageRow({
    required this.message,
    required this.onEdit,
    required this.onSendNow,
  });

  final QueuedComposerMessage message;
  final VoidCallback onEdit;
  final VoidCallback onSendNow;

  @override
  Widget build(BuildContext context) {
    final attachmentCount = message.images.length + message.attachments.length;
    return Container(
      key: ValueKey('queued-message-${message.id}'),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        border: Border.all(
          color: FluentTheme.of(context).resources.dividerStrokeColorDefault,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message.text.isEmpty
                  ? '$attachmentCount attachment${attachmentCount == 1 ? '' : 's'}'
                  : message.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Tooltip(
            message: 'Edit queued message',
            child: IconButton(
              key: ValueKey('edit-queued-${message.id}'),
              icon: const Icon(FluentIcons.edit, size: 14),
              onPressed: onEdit,
            ),
          ),
          Tooltip(
            message: 'Send queued message now',
            child: IconButton(
              key: ValueKey('send-queued-${message.id}'),
              icon: const Icon(FluentIcons.up, size: 14),
              onPressed: onSendNow,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageAttachmentPreview extends StatelessWidget {
  const _ImageAttachmentPreview({required this.image, required this.onRemove});

  final PendingComposerImage image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: image.fileName,
      child: SizedBox(
        width: 68,
        height: 68,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(image.bytes, fit: BoxFit.cover),
              ),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: IconButton(
                icon: const Icon(FluentIcons.chrome_close, size: 10),
                onPressed: onRemove,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ContextAttachmentPill extends StatelessWidget {
  const ContextAttachmentPill({
    super.key,
    required this.attachment,
    required this.onRemove,
  });

  final WorkspaceContextAttachment attachment;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: attachment.subtitle,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
        decoration: BoxDecoration(
          color: FluentTheme.of(context).cardColor,
          border: Border.all(
            color: FluentTheme.of(context).resources.dividerStrokeColorDefault,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(FluentIcons.message, size: 12),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                attachment.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(FluentIcons.chrome_close, size: 10),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextWindowMeter extends StatelessWidget {
  const _ContextWindowMeter({required this.usage});

  final AgentUsage usage;

  @override
  Widget build(BuildContext context) {
    final used = usage.contextWindowUsedTokens;
    final max = usage.contextWindowMaxTokens;
    if (used == null || max == null || max <= 0) {
      return const SizedBox.shrink();
    }
    final percent = (used / max * 100).clamp(0, 100).toDouble();
    final label =
        'Context: ${_formatTokens(used)} of ${_formatTokens(max)} tokens '
        '(${percent.round()}%)';
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: SizedBox(
          width: 24,
          height: 24,
          child: ProgressRing(value: percent, strokeWidth: 3),
        ),
      ),
    );
  }
}

String _formatTokens(int value) {
  if (value >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)}M';
  }
  if (value >= 1000) {
    return '${(value / 1000).toStringAsFixed(1)}K';
  }
  return '$value';
}
