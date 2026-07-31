/// Port of Paseo 0.2.0's *admission* rules — four frozen, dependency-free
/// modules that each decide whether some piece of input is allowed to act on
/// the app, and what it turns into. They live together because every one of
/// them is a pure decision a widget or controller delegates to, and none of
/// them owns any UI state of its own:
///
/// - `client-slash-commands/index.ts` — which typed `/…` messages the client
///   swallows and handles itself instead of forwarding to the provider, and
///   how the active agent's snapshot becomes the setup for the fresh draft
///   that `/clear` opens.
/// - `browser/new-tab-requests/index.ts` — whether a `window.open` escaping an
///   embedded browser tab is one this workspace should honour. The desktop
///   host broadcasts these to every window, so both the URL scheme and the
///   originating tab have to be vouched for before anything opens.
/// - `components/question-form-card-core.ts` — parsing the question payload an
///   agent sends, deciding when each question counts as answered, and shaping
///   the answers back into the record the agent expects.
/// - `components/ui/isolated-bottom-sheet-modal/visibility-tracker.ts` — the
///   present/dismiss handshake between React state and an imperative bottom
///   sheet, whose whole job is to not fight the sheet's own animations.
///
/// Everything here is synchronous and clock-free; nothing schedules a timer or
/// reads `DateTime.now()`.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../composer/agent_command_autocomplete.dart';
import '../widgets/composer.dart' show ComposerClientSlashCommand;
import '../workspace/workspace_tab_model.dart';

// ---------------------------------------------------------------------------
// client-slash-commands/index.ts
// ---------------------------------------------------------------------------

/// Whether a client command fires the moment it is picked, or is merely
/// inserted into the composer for the user to complete.
///
/// Upstream's `ClientSlashCommandExecution` union. Every command declared today
/// is [immediate]; [insert] is kept so the declaration table stays a faithful
/// copy of upstream rather than collapsing to a single-valued field.
enum ClientSlashCommandExecution { immediate, insert }

/// The i18n key a client command's description is looked up under.
///
/// Upstream types this as a closed union of two literal strings rather than a
/// free-form key, so a typo cannot ship. The enum reproduces that closure; the
/// literal upstream value is preserved on [translationKey] because those exact
/// keys already exist in this repo's `assets/i18n/*.json` bundles.
enum ClientSlashCommandDescriptionKey {
  archiveAgent('composer.clientCommands.archiveAgent'),
  freshDraft('composer.clientCommands.freshDraft');

  const ClientSlashCommandDescriptionKey(this.translationKey);

  /// The dotted i18n lookup key, byte-identical to upstream's literal.
  final String translationKey;
}

/// One command the client handles locally.
///
/// The name/description/argument-hint/alias quadruple is *not* redeclared here:
/// it is carried on a [CommandAutocompleteEntry] from
/// `composer/agent_command_autocomplete.dart`, which is the shape the composer's
/// autocomplete already ranks and renders. Upstream's `kind` union maps onto
/// the existing [ComposerClientSlashCommand] enum — `archive-agent` is
/// [ComposerClientSlashCommand.exit] and `replace-agent-with-draft` is
/// [ComposerClientSlashCommand.clear] — so the resolver hands callers the same
/// value the composer's own picker already emits.
final class ClientSlashCommand {
  const ClientSlashCommand({
    required this.entry,
    required this.descriptionKey,
    required this.kind,
    required this.execution,
  });

  /// The autocomplete-facing description of this command.
  final CommandAutocompleteEntry entry;

  final ClientSlashCommandDescriptionKey descriptionKey;

  /// Upstream's `ClientSlashCommandKind`, expressed as the app's existing
  /// client-command enum.
  final ComposerClientSlashCommand kind;

  final ClientSlashCommandExecution execution;

  /// The canonical name, without the leading slash.
  String get name => entry.command.name;

  /// Alternate spellings that resolve to this same command.
  List<String> get aliases => entry.aliases;

  /// The English fallback description; [descriptionKey] is the localized form.
  String get description => entry.command.description;

  /// Upstream's `argumentHint`; empty for every command declared today because
  /// neither takes arguments.
  String get argumentHint => entry.command.argumentHint;
}

/// The complete, ordered table of client-handled slash commands.
///
/// Order is load-bearing: it is the order the composer's command palette lists
/// them in, and it is the order [resolveClientSlashCommand]'s lookup table is
/// built in (so a name/alias collision resolves to the *last* declaration, as
/// upstream's `Map.set` loop does).
const List<ClientSlashCommand> clientSlashCommands = [
  ClientSlashCommand(
    entry: CommandAutocompleteEntry(
      command: AgentSlashCommand(
        name: 'exit',
        description: 'Archive the current agent',
        argumentHint: '',
      ),
      aliases: ['quit', 'q'],
      isClient: true,
    ),
    descriptionKey: ClientSlashCommandDescriptionKey.archiveAgent,
    kind: ComposerClientSlashCommand.exit,
    execution: ClientSlashCommandExecution.immediate,
  ),
  ClientSlashCommand(
    entry: CommandAutocompleteEntry(
      command: AgentSlashCommand(
        name: 'clear',
        description: 'Archive this agent and start a fresh draft',
        argumentHint: '',
      ),
      aliases: ['new'],
      isClient: true,
    ),
    descriptionKey: ClientSlashCommandDescriptionKey.freshDraft,
    kind: ComposerClientSlashCommand.clear,
    execution: ClientSlashCommandExecution.immediate,
  ),
];

final Map<String, ClientSlashCommand> _clientCommandsByName = () {
  final byName = <String, ClientSlashCommand>{};
  for (final command in clientSlashCommands) {
    byName[command.name] = command;
    for (final alias in command.aliases) {
      byName[alias] = command;
    }
  }
  return byName;
}();

final RegExp _whitespaceInCommandName = RegExp(r'\s');

/// The client command a composer submission is, or `null` to send it onward.
///
/// This runs on *submit*, not on keystroke, so it has to be conservative: the
/// message is only intercepted when it is nothing but a bare command. Anything
/// carrying arguments (`/clear now`), anything with the slash mid-message
/// (`hello /quit`), and any name the table does not know (`/provider-command`,
/// which belongs to the provider) all fall through untouched.
///
/// [hasAttachments] short-circuits first: a submission with attachments is a
/// real message no matter what its text says, and archiving the agent would
/// silently drop the files.
///
/// Dart's `RegExp` is ECMA-262 compatible, so `\s` covers the same code points
/// as upstream's, and `String.trim` strips the same Unicode whitespace plus
/// U+FEFF that JavaScript's does — the two guards therefore agree character for
/// character.
ClientSlashCommand? resolveClientSlashCommand({
  required String text,
  required bool hasAttachments,
}) {
  if (hasAttachments) {
    return null;
  }

  final trimmed = text.trim();
  if (!trimmed.startsWith('/')) {
    return null;
  }

  final commandName = trimmed.substring(1);
  if (commandName.isEmpty || _whitespaceInCommandName.hasMatch(commandName)) {
    return null;
  }

  return _clientCommandsByName[commandName];
}

/// The runtime-reported half of an agent's configuration.
///
/// Upstream reads this off `Agent.runtimeInfo`, whose other fields
/// (`provider`, `sessionId`) [buildDraftAgentSetup] never touches.
final class DraftAgentRuntimeInfo {
  const DraftAgentRuntimeInfo({this.modeId, this.model, this.thinkingOptionId});

  final String? modeId;
  final String? model;
  final String? thinkingOptionId;
}

/// Exactly the slice of upstream's `Agent` that [buildDraftAgentSetup] reads.
///
/// The full `Agent` from `stores/session-store` is not ported, and this repo's
/// [AgentSummary] carries neither `runtimeInfo` nor `features`. Rather than
/// bend either type, the seven fields the rule actually consumes are named
/// here; [features] reuses the protocol's [AgentFeature] hierarchy so callers
/// can pass a live agent's feature list straight through.
final class DraftAgentSnapshot {
  const DraftAgentSnapshot({
    required this.provider,
    required this.cwd,
    this.currentModeId,
    this.model,
    this.thinkingOptionId,
    this.runtimeInfo,
    this.features,
  });

  final String provider;
  final String cwd;
  final String? currentModeId;
  final String? model;
  final String? thinkingOptionId;
  final DraftAgentRuntimeInfo? runtimeInfo;

  /// Nullable because upstream's `agent.features ?? []` tolerates the field
  /// being absent on agents whose provider reports no features.
  final List<AgentFeature>? features;
}

/// Carries an agent's configuration into the draft tab that replaces it.
///
/// `/clear` archives the current agent and opens a fresh draft; without this
/// the user would lose their provider, working directory, model, mode and
/// feature toggles and have to re-pick them all. Each field prefers the value
/// the user explicitly chose (`currentModeId`, `model`, `thinkingOptionId`) and
/// falls back to what the runtime reported, so an agent that never had an
/// explicit override still reproduces faithfully.
///
/// The fallbacks are null-coalescing, not truthiness-coalescing: an explicit
/// empty-string model is kept rather than replaced by the runtime's, matching
/// upstream's `??`.
///
/// Feature values are keyed by feature id in declaration order, and a repeated
/// id keeps the last occurrence — Dart's `Map` literal insertion order and
/// overwrite semantics match JavaScript object key ordering for the string keys
/// used here.
WorkspaceDraftTabSetup buildDraftAgentSetup(DraftAgentSnapshot agent) {
  final featureValues = <String, Object?>{};
  for (final feature in agent.features ?? const <AgentFeature>[]) {
    featureValues[feature.id] = feature.value;
  }

  return WorkspaceDraftTabSetup(
    provider: agent.provider,
    cwd: agent.cwd,
    modeId: agent.currentModeId ?? agent.runtimeInfo?.modeId,
    model: agent.model ?? agent.runtimeInfo?.model,
    thinkingOptionId:
        agent.thinkingOptionId ?? agent.runtimeInfo?.thinkingOptionId,
    featureValues: featureValues,
  );
}

// ---------------------------------------------------------------------------
// browser/new-tab-requests/index.ts
// ---------------------------------------------------------------------------

/// A vetted request from the desktop host to open a URL in a new tab.
///
/// Upstream aliases this to `DesktopBrowserNewTabRequestEvent`; the two fields
/// below are that event in full.
final class BrowserNewTabRequest {
  const BrowserNewTabRequest({
    required this.sourceBrowserId,
    required this.url,
  });

  /// The embedded browser tab that asked. Deliberately the *raw* payload value,
  /// not a trimmed one — see [resolveBrowserNewTabRequest].
  final String sourceBrowserId;

  /// The raw payload URL, passed through unmodified so the opened tab lands on
  /// exactly the string the page asked for rather than a normalized rewrite.
  final String url;

  @override
  bool operator ==(Object other) =>
      other is BrowserNewTabRequest &&
      other.sourceBrowserId == sourceBrowserId &&
      other.url == url;

  @override
  int get hashCode => Object.hash(sourceBrowserId, url);

  @override
  String toString() =>
      'BrowserNewTabRequest(sourceBrowserId: $sourceBrowserId, url: $url)';
}

/// Whether a URL is one an embedded browser may hand to a new tab.
///
/// Only `http:`/`https:` and the literal `about:blank` are allowed: this is the
/// boundary that stops a page from talking the desktop shell into opening
/// `file:///…`, `javascript:…` or a custom-scheme handler.
///
/// **Deviation.** Upstream leans on `new URL()` throwing, which is a full
/// WHATWG parse; Dart's `Uri.parse` accepts relative references and does not
/// enforce that a special scheme has a host, so it cannot stand in directly.
/// This reimplements the slice of WHATWG parsing the decision depends on:
///
/// - leading/trailing C0-or-space is stripped and interior tab/LF/CR removed,
///   as the WHATWG parser does, so `" about:blank "` still resolves;
/// - the scheme must match `[A-Za-z][A-Za-z0-9+-.]*` and is lowercased, so
///   `HTTPS://…` passes and `ABOUT:BLANK` (whose `href` keeps the uppercase
///   opaque path) does not;
/// - for `http`/`https` any run of `/` or `\` after the colon is skipped and a
///   non-empty host is required, matching `new URL` accepting `http:example.com`
///   and `http:\\a.b` while throwing on `https:` and `http://`;
/// - every other scheme is allowed only when the normalized input is exactly
///   `about:blank`, standing in for upstream's `href === "about:blank"`.
///
/// The one behaviour not reproduced is host *validity*: a host containing
/// characters WHATWG forbids (an interior space, say) is accepted here and
/// rejected upstream. That only ever loosens the check for strings no browser
/// would resolve anyway, and never admits a disallowed scheme.
///
/// Upstream keeps this module-private; it is public here because the emulation
/// above is substantial enough to deserve direct test coverage.
bool isAllowedBrowserNewTabUrl(String value) {
  final normalized = _stripUrlWhitespace(value);
  final schemeMatch = _urlSchemePattern.firstMatch(normalized);
  if (schemeMatch == null) {
    return false;
  }

  final scheme = schemeMatch.group(1)!.toLowerCase();
  final rest = normalized.substring(schemeMatch.end);

  if (scheme == 'http' || scheme == 'https') {
    var index = 0;
    while (index < rest.length &&
        (rest.codeUnitAt(index) == 0x2f || rest.codeUnitAt(index) == 0x5c)) {
      index++;
    }
    var end = rest.length;
    for (var scan = index; scan < rest.length; scan++) {
      final unit = rest.codeUnitAt(scan);
      if (unit == 0x2f || unit == 0x5c || unit == 0x3f || unit == 0x23) {
        end = scan;
        break;
      }
    }
    final authority = rest.substring(index, end);
    final atIndex = authority.lastIndexOf('@');
    final host = atIndex == -1 ? authority : authority.substring(atIndex + 1);
    return host.isNotEmpty;
  }

  return '$scheme:$rest' == 'about:blank';
}

final RegExp _urlSchemePattern = RegExp(r'^([A-Za-z][A-Za-z0-9+\-.]*):');

/// Whether a code unit is one the WHATWG parser strips from anywhere in the
/// input rather than only from its ends: tab (U+0009), LF (U+000A), CR
/// (U+000D).
bool _isStrippableUrlWhitespace(int unit) =>
    unit == 0x09 || unit == 0x0a || unit == 0x0d;

String _stripUrlWhitespace(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && value.codeUnitAt(start) <= 0x20) {
    start++;
  }
  while (end > start && value.codeUnitAt(end - 1) <= 0x20) {
    end--;
  }
  final buffer = StringBuffer();
  for (var index = start; index < end; index++) {
    final unit = value.codeUnitAt(index);
    if (_isStrippableUrlWhitespace(unit)) continue;
    buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

/// Reads a host payload into a request, or `null` if it is not one.
///
/// The payload arrives untyped over the desktop bridge, so both fields are
/// checked rather than trusted. `sourceBrowserId` must be a string that is
/// non-empty *after trimming* — but the value carried forward is the untrimmed
/// original, exactly as upstream does, which is why a padded id fails the
/// workspace-membership check downstream.
///
/// **Deviation.** Upstream's `typeof payload !== "object"` also rejects `null`
/// explicitly and accepts arrays (which then fail the field checks). Here a
/// non-`Map` payload — including a `List` — is rejected outright, which lands
/// on the same `null` result for every value that can survive JSON decoding.
BrowserNewTabRequest? readDesktopBrowserNewTabRequest(Object? payload) {
  if (payload is! Map) {
    return null;
  }
  final candidate = payload.cast<Object?, Object?>();

  final sourceBrowserId = candidate['sourceBrowserId'];
  if (sourceBrowserId is! String || sourceBrowserId.trim().isEmpty) {
    return null;
  }

  final url = candidate['url'];
  if (url is! String || !isAllowedBrowserNewTabUrl(url)) {
    return null;
  }

  return BrowserNewTabRequest(sourceBrowserId: sourceBrowserId, url: url);
}

/// Whether [workspaceTabs] currently holds the browser tab [browserId].
///
/// **Deviation.** Upstream walks a `WorkspaceLayout` tree with
/// `collectAllTabs(layout.root)`; that layout store is not ported, so the
/// already-flattened tab list is taken instead. `collectAllTabs` is a pure
/// flatten, so the two are the same input in different shapes. A `null` list
/// stands in for upstream's `null | undefined` layout and is never a match.
bool workspaceContainsBrowser({
  required Iterable<WorkspaceTab>? workspaceTabs,
  required String browserId,
}) {
  if (workspaceTabs == null) {
    return false;
  }
  return workspaceTabs.any((tab) {
    final target = tab.target;
    return target is WorkspaceBrowserTabTarget && target.browserId == browserId;
  });
}

/// Admits a desktop new-tab request, or `null` to ignore it.
///
/// Two independent gates, both required. The URL gate is a security boundary
/// (see [isAllowedBrowserNewTabUrl]). The workspace gate is a routing one: the
/// host broadcasts the event to every window, so without it a link clicked in
/// one workspace would open a tab in all of them.
BrowserNewTabRequest? resolveBrowserNewTabRequest({
  required Object? payload,
  required Iterable<WorkspaceTab>? workspaceTabs,
}) {
  final request = readDesktopBrowserNewTabRequest(payload);
  if (request == null) {
    return null;
  }
  if (!workspaceContainsBrowser(
    workspaceTabs: workspaceTabs,
    browserId: request.sourceBrowserId,
  )) {
    return null;
  }
  return request;
}

// ---------------------------------------------------------------------------
// components/question-form-card-core.ts
// ---------------------------------------------------------------------------

/// One pickable answer.
final class QuestionOption {
  const QuestionOption({required this.label, this.description});

  final String label;

  /// Absent rather than empty when the payload omits it, or supplies a
  /// non-string, because upstream's `readOptionalString`-style guard yields
  /// `undefined` in both cases.
  final String? description;
}

/// A single question in an agent-issued question form.
final class QuestionFormQuestion {
  const QuestionFormQuestion({
    required this.question,
    required this.header,
    required this.options,
    required this.multiSelect,
    required this.allowOther,
    required this.allowEmpty,
    this.placeholder,
    this.dismissLabel,
  });

  /// The prompt shown to the user.
  final String question;

  /// The key this question's answer is filed under in the answer record.
  final String header;

  final List<QuestionOption> options;
  final bool multiSelect;

  /// True when the user may type a free-form answer. Upstream folds two
  /// spellings — `allowOther` and the older `isOther` — into this one flag.
  final bool allowOther;

  /// True when submitting nothing is a valid answer.
  final bool allowEmpty;

  final String? placeholder;

  /// Label for the dismiss affordance, e.g. `"Skip"`.
  final String? dismissLabel;
}

/// Which option indices the user has picked, keyed by question index.
///
/// Upstream's `Record<number, ReadonlySet<number>>`. A missing entry and an
/// empty set both mean "nothing picked".
typedef QuestionSelections = Map<int, Set<int>>;

/// The free-form text typed per question, keyed by question index.
typedef QuestionOtherTexts = Map<int, String>;

/// Parses an agent's raw question payload, or `null` if it is not usable.
///
/// This is strict on purpose and all-or-nothing: one malformed question voids
/// the whole form rather than silently rendering a partial one the agent will
/// not recognise the answers to. A payload whose `questions` array is empty is
/// also `null`, since an empty form has nothing to ask.
///
/// `multiSelect`, `allowEmpty`, `allowOther` and `isOther` are compared against
/// `true` identically rather than coerced, so a truthy non-boolean (`1`,
/// `"yes"`) reads as `false` — Dart's `== true` on an `Object?` reproduces
/// upstream's `=== true` exactly.
///
/// **Deviation.** Upstream's entry guard is
/// `typeof input !== "object" || input === null || !("questions" in input)`;
/// here the payload must be a `Map` with a `'questions'` key. Both reject
/// every non-object and every object lacking the key; the JS form additionally
/// accepts an array as an "object", which then fails the `Array.isArray` check
/// on the missing property anyway.
List<QuestionFormQuestion>? parseQuestionFormQuestions(Object? input) {
  if (input is! Map) {
    return null;
  }
  final record = input.cast<Object?, Object?>();
  if (!record.containsKey('questions')) {
    return null;
  }
  final raw = record['questions'];
  if (raw is! List) {
    return null;
  }

  final questions = <QuestionFormQuestion>[];
  for (final item in raw) {
    if (item is! Map) return null;
    final q = item.cast<Object?, Object?>();
    final question = q['question'];
    final header = q['header'];
    if (question is! String || header is! String) return null;
    final rawOptions = q['options'];
    if (rawOptions is! List) return null;

    final options = <QuestionOption>[];
    for (final opt in rawOptions) {
      if (opt is! Map) return null;
      final o = opt.cast<Object?, Object?>();
      final label = o['label'];
      if (label is! String) return null;
      final description = o['description'];
      options.add(
        QuestionOption(
          label: label,
          description: description is String ? description : null,
        ),
      );
    }

    questions.add(
      QuestionFormQuestion(
        question: question,
        header: header,
        options: options,
        multiSelect: q['multiSelect'] == true,
        allowOther: q['allowOther'] == true || q['isOther'] == true,
        allowEmpty: q['allowEmpty'] == true,
        placeholder: _optionalStringField(q, 'placeholder'),
        dismissLabel: _optionalStringField(q, 'dismissLabel'),
      ),
    );
  }

  return questions.isNotEmpty ? questions : null;
}

String? _optionalStringField(Map<Object?, Object?> record, String key) {
  final value = record[key];
  return value is String ? value : null;
}

/// Whether this question offers a free-text field.
///
/// Either it has no options at all — so typing is the only way to answer — or
/// it explicitly permits an "other" answer alongside its options.
bool questionShowsTextInput(QuestionFormQuestion question) =>
    question.options.isEmpty || question.allowOther;

/// Whether question [qIndex] has an answer good enough to submit.
///
/// A selection always counts. Failing that, an option-only question is simply
/// unanswered — free text cannot answer it, so stray text in [otherTexts] is
/// ignored. For a question that does take text, non-blank text counts, and if
/// even that is missing the question is answered only when it opted into
/// [QuestionFormQuestion.allowEmpty].
///
/// Whitespace-only text does not count: upstream trims and then tests
/// truthiness, which rejects the resulting empty string.
bool isQuestionAnswered(
  QuestionFormQuestion question,
  int qIndex,
  QuestionSelections selections,
  QuestionOtherTexts otherTexts,
) {
  final selected = selections[qIndex];
  if (selected != null && selected.isNotEmpty) {
    return true;
  }

  if (!questionShowsTextInput(question)) {
    return false;
  }

  final otherText = otherTexts[qIndex]?.trim();
  if (otherText != null && otherText.isNotEmpty) {
    return true;
  }

  return question.allowEmpty;
}

/// Whether every question is answered, gating the form's submit button.
///
/// A `null` list — the form never parsed — is not submittable. An empty list
/// is, vacuously, matching JavaScript's `Array.prototype.every` on an empty
/// array; [parseQuestionFormQuestions] never produces one, but a caller holding
/// a hand-built list can.
bool areQuestionsAnswered(
  List<QuestionFormQuestion>? questions,
  QuestionSelections selections,
  QuestionOtherTexts otherTexts,
) {
  if (questions == null) {
    return false;
  }
  for (var index = 0; index < questions.length; index++) {
    if (!isQuestionAnswered(questions[index], index, selections, otherTexts)) {
      return false;
    }
  }
  return true;
}

/// Shapes the user's picks into the `header -> answer` record the agent reads.
///
/// Typed text wins over selections when the question takes text at all, since
/// the user typing is the more recent, more specific intent. A text-only
/// question that allows empty answers contributes an explicit empty string —
/// that is what tells the agent the user consciously skipped it rather than
/// leaving it out. Questions with neither text nor a selection are omitted
/// entirely; the record is sparse by design.
///
/// Multiple selections join with `", "`, in selection order — Dart's default
/// `Set` iterates in insertion order, matching JavaScript's `Set`.
///
/// **Deviation.** A selected index outside the question's options throws here
/// (`RangeError`) where upstream throws `TypeError` reading `.label` of
/// `undefined`. Both fail loudly on the same corrupt state; only the exception
/// type differs.
Map<String, String> buildQuestionFormAnswers(
  List<QuestionFormQuestion> questions,
  QuestionSelections selections,
  QuestionOtherTexts otherTexts,
) {
  final answers = <String, String>{};
  for (var i = 0; i < questions.length; i++) {
    final q = questions[i];
    final selected = selections[i];
    final otherText = otherTexts[i]?.trim();

    if (questionShowsTextInput(q)) {
      if (otherText != null && otherText.isNotEmpty) {
        answers[q.header] = otherText;
        continue;
      }
      if (q.allowEmpty && q.options.isEmpty) {
        answers[q.header] = '';
        continue;
      }
    }

    if (selected != null && selected.isNotEmpty) {
      answers[q.header] = [
        for (final index in selected) q.options[index].label,
      ].join(', ');
    }
  }
  return answers;
}

/// Whether dismissing the form should submit blank answers instead of closing.
///
/// True only when every question is a pure optional free-text prompt: then
/// "dismiss" and "skip them all" are the same user intent, and submitting keeps
/// the agent unblocked. If any question offers options, dismissing has to stay
/// a real cancel.
bool shouldSubmitEmptyOnDismiss(List<QuestionFormQuestion> questions) =>
    questions.isNotEmpty &&
    questions.every(
      (question) => question.allowEmpty && question.options.isEmpty,
    );

/// The label for the dismiss button, e.g. `"Skip"` for optional prompts.
///
/// The first question that supplies one wins, so an agent can relabel the whole
/// form from any question. Falls back to [fallbackLabel] when none does.
///
/// **Deviation worth naming.** Upstream's `questions.find((q) => q.dismissLabel)`
/// is a *truthiness* test, so a question whose `dismissLabel` is the empty
/// string is skipped and the search continues — an empty label never reaches
/// the button. That is reproduced here with an explicit non-empty check; a
/// plain null check would have shipped a blank button.
String resolveDismissLabel(
  List<QuestionFormQuestion> questions, [
  String fallbackLabel = 'Dismiss',
]) {
  for (final question in questions) {
    final dismissLabel = question.dismissLabel;
    if (dismissLabel != null && dismissLabel.isNotEmpty) {
      return dismissLabel;
    }
  }
  return fallbackLabel;
}

// ---------------------------------------------------------------------------
// components/ui/isolated-bottom-sheet-modal/visibility-tracker.ts
// ---------------------------------------------------------------------------

/// The imperative half of a bottom sheet: the handle the tracker drives.
abstract interface class BottomSheetController {
  void present();
  void dismiss();
}

enum _BottomSheetPhase { closed, presenting, presented, dismissing }

/// Mediates between declarative "should this sheet be visible" state and a
/// bottom sheet that animates on its own schedule.
///
/// The problem it solves: the sheet reports index `-1` both when it has been
/// closed *and* when it has merely been pushed behind another stacked sheet, and
/// it can be re-mounted (a fresh controller attached) at any point mid-flight.
/// Treating either of those as a close would fire spurious `onClose` callbacks
/// and, worse, immediately re-present a sheet the user just swiped away. So the
/// tracker keeps its own four-phase view of where the sheet is and only ever
/// calls `present`/`dismiss` on a transition that phase actually permits.
///
/// Nothing here is timed: every transition is driven by a call from the sheet
/// or from parent state, so there is no timer to inject.
final class BottomSheetVisibilityTracker {
  BottomSheetVisibilityTracker({required this.onClose});

  /// Invoked at most once per open cycle, when the sheet genuinely closed and
  /// parent state still believes it is visible — i.e. the user dismissed it and
  /// the parent needs to catch up.
  final void Function() onClose;

  BottomSheetController? _controller;
  bool _visible = false;

  /// Tri-state on purpose. Upstream's `isEnabled?: boolean` is only ever
  /// consulted as `isEnabled !== false`, so "unset" and "true" behave alike but
  /// are not the same value; `null` here is upstream's `undefined`.
  bool? _isEnabled;
  _BottomSheetPhase _phase = _BottomSheetPhase.closed;
  bool _hasNotifiedClose = false;

  void _present() {
    final controller = _controller;
    if (controller == null || _phase != _BottomSheetPhase.closed) return;
    _phase = _BottomSheetPhase.presenting;
    _hasNotifiedClose = false;
    controller.present();
  }

  void _dismiss() {
    final controller = _controller;
    if (controller == null ||
        _phase == _BottomSheetPhase.closed ||
        _phase == _BottomSheetPhase.dismissing) {
      return;
    }
    _phase = _BottomSheetPhase.dismissing;
    controller.dismiss();
  }

  void _notifyClose() {
    if (_hasNotifiedClose) return;
    _hasNotifiedClose = true;
    onClose();
  }

  /// Attaches (or with `null`, detaches) the sheet handle.
  ///
  /// Presents immediately if the sheet was already wanted while no controller
  /// existed — that is how a sheet asked to open before mount still opens. The
  /// `_phase` guard inside [_present] is what stops a re-attach from re-opening
  /// a sheet the user is in the middle of dismissing.
  void attachController(BottomSheetController? next) {
    _controller = next;
    if (next != null && _visible && _isEnabled != false) {
      _present();
    }
  }

  /// Pushes parent state's intent into the tracker.
  ///
  /// While disabled nothing happens at all — not even a dismiss — so a sheet
  /// switched off mid-animation is left exactly as it is.
  ///
  /// The `dismissing` branch is the acknowledgement path: the sheet already
  /// went away on its own and parent state has now agreed it is hidden, so the
  /// phase resets to `closed` and the close latch is released, arming the next
  /// open. Skipping the [_dismiss] call there avoids telling an already-closed
  /// sheet to close again.
  void syncDesired({required bool visible, bool? isEnabled}) {
    _visible = visible;
    _isEnabled = isEnabled;
    if (isEnabled == false) return;
    if (visible) {
      _present();
      return;
    }
    if (_phase == _BottomSheetPhase.dismissing) {
      _phase = _BottomSheetPhase.closed;
      _hasNotifiedClose = false;
      return;
    }
    _dismiss();
  }

  /// Records the sheet's own index changes.
  ///
  /// Any index other than `-1` means the sheet settled open. `-1` is
  /// deliberately *not* a close: stacked sheets report it when hidden behind a
  /// sibling. It only moves the phase to `dismissing`, which is a "might be
  /// closing" marker; [handleSheetDismiss] is what confirms it.
  void handleSheetIndexChange(int index) {
    if (index != -1) {
      if (_phase == _BottomSheetPhase.presenting ||
          _phase == _BottomSheetPhase.dismissing) {
        _phase = _BottomSheetPhase.presented;
      }
      return;
    }
    if (_phase == _BottomSheetPhase.presenting ||
        _phase == _BottomSheetPhase.presented) {
      _phase = _BottomSheetPhase.dismissing;
    }
  }

  /// Records the sheet actually finishing its dismissal.
  ///
  /// If parent state still thinks the sheet is visible, this was a user-driven
  /// dismiss and the parent is told once. If parent state already knows it is
  /// hidden, this is the tail of a programmatic close: the phase resets and the
  /// latch releases so the next open can notify again.
  void handleSheetDismiss() {
    if (_visible) {
      _phase = _BottomSheetPhase.dismissing;
      _notifyClose();
      return;
    }
    _phase = _BottomSheetPhase.closed;
    _hasNotifiedClose = false;
  }
}
