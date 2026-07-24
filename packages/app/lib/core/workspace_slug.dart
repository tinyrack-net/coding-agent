import 'dart:math';

/// Adjective-animal word lists for auto-generated worktree branch names
/// (Paseo's `createNameId()`-style `"lucky-otter"` slugs).
const _adjectives = [
  'lucky', 'brave', 'calm', 'eager', 'gentle', 'quiet', 'swift', 'bold',
  'bright', 'clever', 'fuzzy', 'nimble', 'proud', 'sunny', 'witty', 'zesty',
];

const _animals = [
  'otter', 'falcon', 'panda', 'fox', 'heron', 'lynx', 'raven', 'wolf',
  'badger', 'gecko', 'ibis', 'koala', 'marten', 'newt', 'owl', 'sparrow',
];

/// Generates a random `"adjective-animal"` slug for a new worktree branch.
String generateWorkspaceSlug([Random? random]) {
  final rng = random ?? Random();
  final adjective = _adjectives[rng.nextInt(_adjectives.length)];
  final animal = _animals[rng.nextInt(_animals.length)];
  return '$adjective-$animal';
}
