/// Port of Paseo 0.2.0's markdown-shaped decision rules, grouped because all
/// three are frozen pure predicates that the chat surface leans on:
///
/// - `utils/markdown-ast.ts` — decides whether a parsed markdown subtree
///   contains a node of some type (e.g. "does this paragraph hold an image?"),
///   which drives per-node rendering choices without re-walking the source.
/// - `utils/split-markdown-blocks.ts` — decides where one markdown block ends
///   and the next begins. The assistant message height estimate and the
///   incremental block renderer both key off these exact boundaries, so the
///   splitting rules are behaviourally load-bearing, not cosmetic.
/// - `screens/workspace/workspace-empty-draft-seed.ts` — decides whether a
///   workspace is confirmed empty enough to seed a starter draft. Every input
///   must be *known*, not merely falsy, so a mid-hydration workspace never
///   gets a spurious draft that would then race real restored content.
library;

/// A parsed markdown node reduced to what the containment check needs: its
/// type and its children. Upstream types this structurally; Dart needs a
/// concrete holder.
final class MarkdownAstNodeWithChildren {
  const MarkdownAstNodeWithChildren({
    required this.type,
    this.children = const [],
  });

  final String type;
  final List<MarkdownAstNodeWithChildren> children;
}

/// Whether [node] or any descendant has the given [type]. The node itself
/// counts, so a bare image node "contains" an image.
bool markdownNodeContainsType({
  required MarkdownAstNodeWithChildren node,
  required String type,
}) {
  if (node.type == type) return true;

  return node.children.any(
    (child) => markdownNodeContainsType(node: child, type: type),
  );
}

/// A run of three or more backticks or tildes, optionally indented by up to
/// three spaces. Four or more leading spaces makes it an indented code line
/// instead of a fence, which is why the indent is bounded.
final _fenceDelimiterPattern = RegExp(r'^( {0,3})(`{3,}|~{3,})');

/// The two characters a markdown code fence can be built from.
enum _FenceCharacter {
  backtick('`'),
  tilde('~');

  const _FenceCharacter(this.character);

  final String character;

  static _FenceCharacter? fromCharacter(String character) =>
      switch (character) {
        '`' => _FenceCharacter.backtick,
        '~' => _FenceCharacter.tilde,
        _ => null,
      };
}

/// The fence run opening or closing on a line: which character it is built
/// from and how long the run is. Length matters because a fence only closes
/// on a run at least as long as the one that opened it.
final class _FenceDelimiter {
  const _FenceDelimiter({required this.character, required this.length});

  final _FenceCharacter character;
  final int length;
}

_FenceDelimiter? _getFenceDelimiter(String line) {
  final match = _fenceDelimiterPattern.firstMatch(line);
  final run = match?.group(2);
  if (run == null) return null;

  final character = _FenceCharacter.fromCharacter(run[0]);
  if (character == null) return null;

  return _FenceDelimiter(character: character, length: run.length);
}

/// Splits [text] into markdown blocks on blank-line boundaries, while
/// treating a fenced code span as a single indivisible block so the blank
/// lines inside real code never fracture it.
///
/// Deliberately frozen details:
/// - Blank lines are dropped, never emitted, and any run of them is one
///   boundary; leading blank lines therefore start no block at all.
/// - A fence closes only on the same character with a run at least as long
///   as the opener, so ```` inside a ``` block stays code.
/// - An unterminated fence swallows the rest of the text as one block.
List<String> splitMarkdownBlocks(String text) {
  if (text.isEmpty) return [];

  final blocks = <String>[];
  var currentLines = <String>[];
  _FenceCharacter? activeFenceCharacter;
  var activeFenceLength = 0;
  var sawBlockSeparator = false;

  for (final line in text.split('\n')) {
    final isBlankLine = line.trim().isEmpty;

    if (activeFenceCharacter == null && isBlankLine) {
      // A blank line before any content is not a boundary — there is nothing
      // yet for it to close.
      if (currentLines.isNotEmpty) sawBlockSeparator = true;
      continue;
    }

    if (activeFenceCharacter == null && sawBlockSeparator) {
      blocks.add(currentLines.join('\n'));
      currentLines = <String>[];
      sawBlockSeparator = false;
    }

    currentLines.add(line);

    final fenceDelimiter = _getFenceDelimiter(line);
    if (fenceDelimiter == null) continue;

    if (activeFenceCharacter == null) {
      activeFenceCharacter = fenceDelimiter.character;
      activeFenceLength = fenceDelimiter.length;
      continue;
    }

    if (fenceDelimiter.character == activeFenceCharacter &&
        fenceDelimiter.length >= activeFenceLength) {
      activeFenceCharacter = null;
      activeFenceLength = 0;
    }
  }

  if (currentLines.isNotEmpty) blocks.add(currentLines.join('\n'));

  return blocks.where((block) => block.isNotEmpty).toList();
}

/// Whether a focused, fully hydrated workspace is empty enough to seed a
/// starter draft.
///
/// Every `has*` flag is a *knowledge* gate rather than a content check: until
/// the layout store, agents and terminals have all reported in, an empty
/// workspace is indistinguishable from one that simply has not loaded yet,
/// and seeding then would drop a draft on top of restored content.
bool shouldSeedEmptyWorkspaceDraft({
  required bool isRouteFocused,
  required bool hasPersistenceKey,
  required bool hasWorkspaceDirectory,
  required bool hasHydratedWorkspaceLayoutStore,
  required bool hasHydratedAgents,
  required bool hasLoadedTerminals,
  required int activeAgentCount,
  required int terminalCount,
  required int tabCount,
}) {
  if (!isRouteFocused ||
      !hasPersistenceKey ||
      !hasWorkspaceDirectory ||
      !hasHydratedWorkspaceLayoutStore ||
      !hasHydratedAgents ||
      !hasLoadedTerminals) {
    return false;
  }

  return activeAgentCount == 0 && terminalCount == 0 && tabCount == 0;
}
