import 'dart:math';

/// Generates the same adjective-animal shape used by Paseo's `mnemonic-id`
/// `createNameId()` placeholder.
///
/// The word lists are from mnemonic-id 3.2.7 (MIT), authored by
/// Mattias E. O. Andersson:
/// https://github.com/Adelost/mnemonic-id
String generateMnemonicWorktreeSlug() {
  final random = Random.secure();
  return '${_adjectives[random.nextInt(_adjectives.length)]}-'
      '${_nouns[random.nextInt(_nouns.length)]}';
}

final List<String> _adjectives = _adjectiveWords.split(' ');
final List<String> _nouns = _nounWords.split(' ');

const String _adjectiveWords =
    'absurd admiring adoring afraid agitated alert aloof amazing amiable '
    'ancient angry animated anxious aquatic average awesome awful bad bawdy '
    'beefy big bitter black blissful blue blushing bold boring bouncy brave '
    'brawny breezy bright brown busy calm charming chatty cheerful chilly '
    'chosen civil clean clever clingy clumsy cold colorful colossal cowardly '
    'cranky crazy creepy cruel cuddly curly curvy cute dazzling decent demonic '
    'deranged devilish dirty dreamy drunk dry dull durable eager eatable '
    'elastic elderly electric elegant eloquent empty enhanced epic evil '
    'excited exciting exotic fabulous faded famed famous fancy fast fat '
    'fearless feeble festive fierce filthy finicky flaky flashy flawless '
    'flimsy fluffy flying focused foolish forlorn fragile frail frank frantic '
    'freezing fresh friendly frosty funny furry fuzzy gallant gentle giant '
    'gifted gigantic glorious glowing golden goofy gorgeous graceful gracious '
    'grand grateful gray greasy great greedy green grey groovy grumpy gullible '
    'hallowed handsome hanging hapless happy hard hardcore hardy harsh hateful '
    'heavy hellish helpful helpless heroic hesitant hideous hip holy homeless '
    'homely honest hopeful horrible hot huge hulking human humane humble '
    'humorous hungry hypnotic icky icy ideal idiotic ignorant illegal immense '
    'impolite infamous innocent itchy jaded jazzy jealous jittery jobless '
    'jolly jovial joyful joyous jubilant juicy jumpy just juvenile kind large '
    'laughing lavish lawful lazy lean learned legal legit lethal lewd light '
    'little long loud lousy loved lovely loyal lucid lucky lumpy lying macabre '
    'macho mad magical majestic maniacal married massive mean meaty meek '
    'mellow melodic melted merciful merry mighty military mindless modern '
    'modest moldy money moody moonlit moving mundane mushy musing mute naive '
    'nasty naughty neat needy nervous new nice nifty nimble noble noisy normal '
    'noxious obscene odd old orange ordinary organic outgoing pale paltry '
    'panicky parched peaceful peachy perfect pink placid plain plant plastic '
    'pleasant poetic polite poor popular potent powerful precious premium '
    'pretty prime prolific proud pumped punchy puny pure purple puzzled quaint '
    'quick quiet quirky rabid rad radical ragged rainy rampant rapid rare real '
    'rebel red regal regular relaxed relieved resolute rich rigid ripe roasted '
    'robust romantic rotten rough round royal rude rugged rural rustic '
    'ruthless salty sassy scared scary scrawny selfish serene serious shaggy '
    'shaky shallow sharp shiny shocking short showy shrewd shy silent silly '
    'simple sincere skillful skinny sleek sleepy slick slim slimy slippery slow '
    'small smart smelly smiling smooth snappy sneaky snobbish snotty snowy '
    'social soft soggy solid solitary somber sordid sour special spicy spiffy '
    'spiky spiteful splendid spooky spotless spotted spotty squalid stale '
    'sticky stiff stingy stoic strange striped strong stunning stupid suave '
    'subdued subtle sudden sulky supreme sweet swift talented tall tame tasty '
    'tearful tedious tender terrible terrific thankful thin thirsty tidy tiny '
    'tired torpid tough towering tranquil tricky ugly unarmed unbiased uneven '
    'unique unkempt unknown unlucky unruly unusual upbeat vengeful venomous '
    'vigorous violent warm wasteful weak wealthy wet white wicked wiggly wild '
    'wise witty wizardly worried worthy wrathful wretched yellow young '
    'youthful zealous';

const String _nounWords =
    'albatross alpacka anaconda ape armadillo baboon badger bat bear beaver '
    'bedbug bird blobfish blowfish bobcat buffalo bulldog bullfrog bumblebee '
    'camel cat catfish cheetah chicken chipmunk cobra cougar cow crab crocodile '
    'deer dingo dinosaur dodo dog dolphin donkey dragon dragonfly duck dugong '
    'eagle eel elephant elk emu falcon ferret fireant fish flamingo fly fox '
    'frog gecko giraffe goat goose gopher gorilla hamster hedgehog hippo horse '
    'hound husky hyena impala insect jaguar jellyfish kangaroo kiwi koala '
    'kolibri ladybug lamprey leopard liger lion lionfish lizard llama lynx '
    'manatee mantis mayfly meerkat mole monkey moose moth mouse mule narwhal '
    'newt octopus ostrich otter owl panda panther parrot peacock pelican '
    'penguin pig piranha platypus pony porcupine pug puma quail rabbit racoon '
    'rat rhino robin scorpion seahorse seal shark sheep shrimp skunk sloth '
    'snail snake spider squid squirrel starfish stingray swan termite tiger '
    'toad turkey turtle unicorn vampirebat vulture walrus warthog wasp whale '
    'wolf wolverine wombat yak zebra';
