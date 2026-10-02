import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = await AppStore.load();
  final content = await ContentPack.load();

  runApp(
    NihonGoMaster(
      store: store,
      content: content,
    ),
  );
}

class AppStore extends ChangeNotifier {
  final SharedPreferences prefs;

  int xp = 0;
  int streak = 1;
  int lessons = 0;
  int correct = 0;
  int questions = 0;

  bool dark = false;

  final Set<String> learned = {};
  final Set<String> favorites = {};
  final List<Map<String, String>> chats = [];
  final Map<String, SrsCard> srs = {};
  final Map<String, int> mistakes = {};

  String apiKey = '';
  String endpoint = 'https://api.openai.com/v1/chat/completions';
  String model = 'gpt-4o-mini';

  AppStore._(this.prefs) {
    xp = prefs.getInt('xp') ?? 0;
    streak = prefs.getInt('streak') ?? 1;
    lessons = prefs.getInt('lessons') ?? 0;
    correct = prefs.getInt('correct') ?? 0;
    questions = prefs.getInt('questions') ?? 0;
    dark = prefs.getBool('dark') ?? false;

    apiKey = prefs.getString('apiKey') ?? '';
    endpoint = prefs.getString('endpoint') ?? endpoint;
    model = prefs.getString('model') ?? model;

    learned.addAll(
      prefs.getStringList('learned') ?? [],
    );

    favorites.addAll(
      prefs.getStringList('favorites') ?? [],
    );

    final rawChats = prefs.getString('chats') ?? '[]';
    chats.addAll(
      (jsonDecode(rawChats) as List)
          .map((e) => Map<String, String>.from(e)),
    );

    final rawSrs = prefs.getString('srs') ?? '{}';
    final s = jsonDecode(rawSrs) as Map;

    for (final e in s.entries) {
      srs[e.key.toString()] = SrsCard.fromJson(
        Map<String, dynamic>.from(e.value),
      );
    }

    final rawMistakes = prefs.getString('mistakes') ?? '{}';
    final m = jsonDecode(rawMistakes) as Map;

    for (final e in m.entries) {
      mistakes[e.key.toString()] = (e.value as num).toInt();
    }
  }

  static Future<AppStore> load() async {
    return AppStore._(
      await SharedPreferences.getInstance(),
    );
  }

  Future<void> save() async {
    await prefs.setInt('xp', xp);
    await prefs.setInt('streak', streak);
    await prefs.setInt('lessons', lessons);
    await prefs.setInt('correct', correct);
    await prefs.setInt('questions', questions);
    await prefs.setBool('dark', dark);

    await prefs.setString('apiKey', apiKey);
    await prefs.setString('endpoint', endpoint);
    await prefs.setString('model', model);

    await prefs.setStringList(
      'learned',
      learned.toList(),
    );

    await prefs.setStringList(
      'favorites',
      favorites.toList(),
    );

    await prefs.setString(
      'chats',
      jsonEncode(chats),
    );

    await prefs.setString(
      'srs',
      jsonEncode(
        srs.map(
          (k, v) => MapEntry(k, v.toJson()),
        ),
      ),
    );

    await prefs.setString(
      'mistakes',
      jsonEncode(mistakes),
    );

    notifyListeners();
  }

  Future<void> award(int n) async {
    xp += n;
    await save();
  }

  Future<void> answer(String id, bool ok) async {
    questions++;

    if (ok) {
      correct++;
    } else {
      mistakes[id] = (mistakes[id] ?? 0) + 1;
    }

    final card = srs[id] ?? SrsCard.newCard(id);

    card.review(ok);
    srs[id] = card;

    xp += ok ? 10 : 2;

    await save();
  }

  List<String> weakest(int n) {
    final list = mistakes.entries.toList()
      ..sort(
        (a, b) => b.value.compareTo(a.value),
      );

    return list.take(n).map((e) => e.key).toList();
  }
}

class SrsCard {
  final String id;

  int repetitions;
  double ease;
  int interval;
  DateTime due;
  int lapses;

  SrsCard(
    this.id,
    this.repetitions,
    this.ease,
    this.interval,
    this.due,
    this.lapses,
  );

  factory SrsCard.newCard(String id) {
    return SrsCard(
      id,
      0,
      2.5,
      0,
      DateTime.now(),
      0,
    );
  }

  factory SrsCard.fromJson(Map<String, dynamic> j) {
    return SrsCard(
      j['id'],
      (j['repetitions'] ?? 0).toInt(),
      (j['ease'] ?? 2.5).toDouble(),
      (j['interval'] ?? 0).toInt(),
      DateTime.tryParse(j['due'] ?? '') ?? DateTime.now(),
      (j['lapses'] ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'repetitions': repetitions,
      'ease': ease,
      'interval': interval,
      'due': due.toIso8601String(),
      'lapses': lapses,
    };
  }

  bool get isDue => !due.isAfter(DateTime.now());

  void review(bool good) {
    if (!good) {
      repetitions = 0;
      interval = 0;
      ease = max(1.3, ease - .2);
      lapses++;

      due = DateTime.now().add(
        const Duration(minutes: 10),
      );

      return;
    }

    repetitions++;

    if (repetitions == 1) {
      interval = 1;
    } else if (repetitions == 2) {
      interval = 3;
    } else {
      interval = max(
        1,
        (interval * ease).round(),
      );
    }

    ease = min(
      3.0,
      ease + .05,
    );

    due = DateTime.now().add(
      Duration(days: interval),
    );
  }
}

class ContentPack {
  final List<Vocab> vocab;
  final List<Kanji> kanji;
  final List<GrammarPoint> grammar;

  ContentPack(
    this.vocab,
    this.kanji,
    this.grammar,
  );

  static Future<ContentPack> load() async {
    final v = jsonDecode(
      await rootBundle.loadString(
        'assets/data/vocab.json',
      ),
    ) as List;

    final k = jsonDecode(
      await rootBundle.loadString(
        'assets/data/kanji.json',
      ),
    ) as List;

    final g = jsonDecode(
      await rootBundle.loadString(
        'assets/data/grammar.json',
      ),
    ) as List;

    return ContentPack(
      v
          .map(
            (e) => Vocab.fromJson(
              Map<String, dynamic>.from(e),
            ),
          )
          .toList(),
      k
          .map(
            (e) => Kanji.fromJson(
              Map<String, dynamic>.from(e),
            ),
          )
          .toList(),
      g
          .map(
            (e) => GrammarPoint.fromJson(
              Map<String, dynamic>.from(e),
            ),
          )
          .toList(),
    );
  }
}

class Vocab {
  final String id;
  final String jp;
  final String romaji;
  final String meaning;
  final String level;
  final String reading;

  final List<ExampleSentence> examples;

  Vocab({
    required this.id,
    required this.jp,
    required this.romaji,
    required this.meaning,
    required this.level,
    required this.reading,
    this.examples = const [],
  });

  factory Vocab.fromJson(Map<String, dynamic> j) {
    return Vocab(
      id: '${j['id'] ?? j['jp']}',
      jp: '${j['word'] ?? j['jp']}',
      reading: '${j['reading'] ?? ''}',
      romaji: '${j['romaji'] ?? ''}',
      meaning: (j['meanings'] is List)
          ? (j['meanings'] as List).join('; ')
          : '${j['meaning'] ?? ''}',
      level: '${j['level'] ?? 'JP'}',
      examples: ((j['examples'] as List?) ?? [])
          .map(
            (e) => ExampleSentence.fromJson(
              Map<String, dynamic>.from(e),
            ),
          )
          .toList(),
    );
  }
}

class ExampleSentence {
  final String ja;
  final String en;
  final String furigana;

  ExampleSentence(
    this.ja,
    this.en,
    this.furigana,
  );

  factory ExampleSentence.fromJson(
    Map<String, dynamic> j,
  ) {
    return ExampleSentence(
      '${j['ja'] ?? ''}',
      '${j['en'] ?? ''}',
      '${j['furigana'] ?? ''}',
    );
  }
}

class Kanji {
  final String id;
  final String char;
  final String reading;
  final String meaning;
  final String level;
  final String radical;

  final int strokes;

  final List<String> onyomi;
  final List<String> kunyomi;
  final List<String> words;

  Kanji({
    required this.id,
    required this.char,
    required this.reading,
    required this.meaning,
    required this.level,
    required this.radical,
    required this.strokes,
    this.onyomi = const [],
    this.kunyomi = const [],
    this.words = const [],
  });

  factory Kanji.fromJson(
    Map<String, dynamic> j,
  ) {
    return Kanji(
      id: '${j['id'] ?? j['character'] ?? j['char']}',
      char: '${j['character'] ?? j['char']}',
      reading: [
        ...((j['onyomi'] as List?) ?? []),
        ...((j['kunyomi'] as List?) ?? []),
      ].join(' / '),
      meaning: (j['meanings'] is List)
          ? (j['meanings'] as List).join('; ')
          : '${j['meaning'] ?? ''}',
      level: '${j['level'] ?? 'JP'}',
      radical: '${j['radical'] ?? ''}',
      strokes: (j['strokes'] ?? j['stroke_count'] ?? 0).toInt(),
      onyomi: ((j['onyomi'] as List?) ?? [])
          .map((e) => '$e')
          .toList(),
      kunyomi: ((j['kunyomi'] as List?) ?? [])
          .map((e) => '$e')
          .toList(),
      words: ((j['words'] as List?) ?? [])
          .map((e) => '$e')
          .toList(),
    );
  }
}

class GrammarPoint {
  final String id;
  final String pattern;
  final String romaji;
  final String level;
  final String meaning;
  final String formation;
  final String notes;

  final List<ExampleSentence> examples;

  GrammarPoint({
    required this.id,
    required this.pattern,
    required this.romaji,
    required this.level,
    required this.meaning,
    required this.formation,
    required this.notes,
    required this.examples,
  });

  factory GrammarPoint.fromJson(
    Map<String, dynamic> j,
  ) {
    return GrammarPoint(
      id: '${j['id']}',
      pattern: '${j['pattern']}',
      romaji: '${j['romaji'] ?? ''}',
      level: '${j['level']}',
      meaning: '${j['meaning'] ?? ''}',
      formation: '${j['formation'] ?? ''}',
      notes: '${j['notes'] ?? ''}',
      examples: ((j['examples'] as List?) ?? [])
          .map(
            (e) => ExampleSentence.fromJson(
              Map<String, dynamic>.from(e),
            ),
          )
          .toList(),
    );
  }
}

class NihonGoMaster extends StatelessWidget {
  final AppStore store;
  final ContentPack content;

  const NihonGoMaster({
    super.key,
    required this.store,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (_, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'NihonGo Master Ultimate',
        themeMode:
            store.dark ? ThemeMode.dark : ThemeMode.light,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xffe63946),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xffff5964),
        ),
        home: Home(
          store: store,
          content: content,
        ),
      ),
    );
  }
}

class Home extends StatefulWidget {
  final AppStore store;
  final ContentPack content;

  const Home({
    super.key,
    required this.store,
    required this.content,
  });

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;

  @override
  Widget build(BuildContext c) {
    final pages = [
      Dashboard(
        store: widget.store,
        content: widget.content,
        onGo: (i) => setState(() => tab = i),
      ),
      LearnHub(
        store: widget.store,
        content: widget.content,
      ),
      ReviewPage(
        store: widget.store,
        content: widget.content,
      ),
      AiTutor(
        store: widget.store,
        content: widget.content,
      ),
      Profile(
        store: widget.store,
        content: widget.content,
      ),
    ];

    return Scaffold(
      body: IndexedStack(
        index: tab,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) =>
            setState(() => tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Beranda',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: 'Belajar',
          ),
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style),
            label: 'SRS',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'AI',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}

class Dashboard extends StatelessWidget {
  final AppStore store;
  final ContentPack content;
  final ValueChanged<int> onGo;

  const Dashboard({
    super.key,
    required this.store,
    required this.content,
    required this.onGo,
  });

  @override
  Widget build(BuildContext c) {
    final acc = store.questions == 0
        ? 0
        : (store.correct / store.questions * 100).round();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      'おかえりなさい！',
                      style:
                          Theme.of(c).textTheme.titleMedium,
                    ),
                    Text(
                      'NihonGo Master',
                      style: Theme.of(c)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                    const Text(
                      'Dari nol sampai JLPT N1',
                    ),
                  ],
                ),
              ),
              const CircleAvatar(
                radius: 28,
                child: Text(
                  '日',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Card(
            color: Theme.of(c)
                .colorScheme
                .primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.local_fire_department,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${store.streak} hari streak',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${store.xp} XP',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  LinearProgressIndicator(
                    value: (store.xp % 500) / 500,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Level ${store.xp ~/ 500 + 1} • $acc% akurasi',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Pusat belajar',
            style: Theme.of(c)
                .textTheme
                .titleLarge
                ?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 10),
          GridView.count(
            shrinkWrap: true,
            physics:
                const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.02,
            children: [
              HubCard(
                'Kosakata',
                '${content.vocab.length} kata',
                Icons.library_books,
                () => onGo(1),
              ),
              HubCard(
                'Kanji',
                '${content.kanji.length} kanji',
                Icons.brush,
                () => onGo(1),
              ),
              HubCard(
                'Grammar',
                '${content.grammar.length} pola',
                Icons.rule,
                () => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => GrammarPage(
                      content: content,
                    ),
                  ),
                ),
              ),
              HubCard(
                'Speaking',
                'Pronunciation + mic',
                Icons.mic,
                () => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => SpeakingPage(
                      store: store,
                      content: content,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.headphones,
              ),
              title: const Text(
                'Listening & pronunciation',
              ),
              subtitle: const Text(
                'Dengarkan native-like TTS dan ulangi dengan mikrofon.',
              ),
              onTap: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => SpeakingPage(
                    store: store,
                    content: content,
                  ),
                ),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.gesture),
              title: const Text(
                'Stroke order + menulis',
              ),
              subtitle: const Text(
                'Lihat urutan goresan KanjiVG dan latihan dengan jari.',
              ),
              onTap: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => KanjiPracticePage(
                    store: store,
                    content: content,
                  ),
                ),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.auto_awesome,
              ),
              title: const Text(
                'AI Sensei personal',
              ),
              subtitle: const Text(
                'AI melihat pola kesalahan SRS dan membuat latihan khusus.',
              ),
              onTap: () => onGo(3),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'JLPT',
            style: Theme.of(c)
                .textTheme
                .titleLarge
                ?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          for (final level
              in ['N5', 'N4', 'N3', 'N2', 'N1'])
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(level),
                ),
                title: Text(level),
                subtitle: Text(
                  '${content.vocab.where((v) => v.level == level).length} kata • '
                  '${content.kanji.where((k) => k.level == level).length} kanji • '
                  '${content.grammar.where((g) => g.level == level).length} grammar',
                ),
                onTap: () => Navigator.push(
                  c,
                  MaterialPageRoute(
                    builder: (_) => LevelPage(
                      level: level,
                      content: content,
                      store: store,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class HubCard extends StatelessWidget {
  final String a;
  final String b;
  final IconData icon;
  final VoidCallback onTap;

  const HubCard(
    this.a,
    this.b,
    this.icon,
    this.onTap, {
    super.key,
  });

  @override
  Widget build(BuildContext c) {
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 32,
              ),
              const Spacer(),
              Text(
                a,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              Text(
                b,
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class LearnHub extends StatefulWidget {
  final AppStore store;
  final ContentPack content;

  const LearnHub({
    super.key,
    required this.store,
    required this.content,
  });

  @override
  State<LearnHub> createState() => _LearnHubState();
}

class _LearnHubState extends State<LearnHub> {
  int mode = 0;
  String q = '';

  @override
  Widget build(BuildContext c) {
    final tabs = [
      'Kata',
      'Kanji',
      'Grammar',
      'Speaking',
    ];

    final vocab = widget.content.vocab
        .where(
          (v) =>
              q.isEmpty ||
              v.jp.contains(q) ||
              v.reading.contains(q) ||
              v.romaji
                  .toLowerCase()
                  .contains(q.toLowerCase()) ||
              v.meaning
                  .toLowerCase()
                  .contains(q.toLowerCase()),
        )
        .take(500)
        .toList();

    final kanji = widget.content.kanji
        .where(
          (k) =>
              q.isEmpty ||
              k.char.contains(q) ||
              k.meaning
                  .toLowerCase()
                  .contains(q.toLowerCase()) ||
              k.reading
                  .toLowerCase()
                  .contains(q.toLowerCase()),
        )
        .take(500)
        .toList();

    final grammar = widget.content.grammar
        .where(
          (g) =>
              q.isEmpty ||
              g.pattern.contains(q) ||
              g.meaning
                  .toLowerCase()
                  .contains(q.toLowerCase()),
        )
        .take(300)
        .toList();

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(18, 18, 18, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Perpustakaan',
                    style: Theme.of(c)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => KanjiPracticePage(
                        store: widget.store,
                        content: widget.content,
                      ),
                    ),
                  ),
                  icon: const Icon(
                    Icons.gesture,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 18),
            child: TextField(
              onChanged: (v) =>
                  setState(() => q = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText:
                    'Cari kata, kanji, grammar...',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 18),
              itemCount: tabs.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: 8),
              itemBuilder: (_, i) => ChoiceChip(
                label: Text(tabs[i]),
                selected: mode == i,
                onSelected: (_) =>
                    setState(() => mode = i),
              ),
            ),
          ),
          Expanded(
            child: mode == 0
                ? ListView.builder(
                    itemCount: vocab.length,
                    itemBuilder: (_, i) => VocabTile(
                      v: vocab[i],
                      store: widget.store,
                      content: widget.content,
                    ),
                  )
                : mode == 1
                    ? ListView.builder(
                        itemCount: kanji.length,
                        itemBuilder: (_, i) =>
                            KanjiTile(
                          k: kanji[i],
                          store: widget.store,
                          content: widget.content,
                        ),
                      )
                    : mode == 2
                        ? ListView.builder(
                            itemCount: grammar.length,
                            itemBuilder: (_, i) =>
                                GrammarTile(
                              g: grammar[i],
                            ),
                          )
                        : SpeakingPage(
                            store: widget.store,
                            content: widget.content,
                            embedded: true,
                          ),
          ),
        ],
      ),
    );
  }
}

class VocabTile extends StatelessWidget {
  final Vocab v;
  final AppStore store;
  final ContentPack content;

  const VocabTile({
    super.key,
    required this.v,
    required this.store,
    required this.content,
  });

  @override
  Widget build(BuildContext c) {
    final fav = store.favorites.contains(v.id);

    return Card(
      margin:
          const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 5,
      ),
      child: ListTile(
        title: Text(
          v.jp,
          style: const TextStyle(
            fontSize: 21,
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          '${v.reading} • ${v.romaji} • ${v.meaning} • ${v.level}',
        ),
        trailing: Wrap(
          children: [
            IconButton(
              icon: Icon(
                fav
                    ? Icons.star
                    : Icons.star_border,
              ),
              onPressed: () async {
                if (fav) {
                  store.favorites.remove(v.id);
                } else {
                  store.favorites.add(v.id);
                }

                await store.save();
              },
            ),
            IconButton(
              icon: const Icon(
                Icons.volume_up,
              ),
              onPressed: () => speak(v.jp),
            ),
          ],
        ),
        onTap: () => Navigator.push(
          c,
          MaterialPageRoute(
            builder: (_) => VocabDetail(
              v: v,
              store: store,
              content: content,
            ),
          ),
        ),
      ),
    );
  }
}

class KanjiTile extends StatelessWidget {
  final Kanji k;
  final AppStore store;
  final ContentPack content;

  const KanjiTile({
    super.key,
    required this.k,
    required this.store,
    required this.content,
  });

  @override
  Widget build(BuildContext c) {
    return Card(
      margin:
          const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 5,
      ),
      child: ListTile(
        leading: Text(
          k.char,
          style: const TextStyle(
            fontSize: 42,
            fontWeight: FontWeight.w900,
          ),
        ),
        title: Text(k.meaning),
        subtitle: Text(
          '${k.reading} • ${k.strokes} strokes • ${k.level}',
        ),
        trailing: IconButton(
          icon: const Icon(
            Icons.brush,
          ),
          onPressed: () => Navigator.push(
            c,
            MaterialPageRoute(
              builder: (_) => KanjiPracticePage(
                store: store,
                content: content,
                initial: k,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VocabDetail extends StatelessWidget {
  final Vocab v;
  final AppStore store;
  final ContentPack content;

  const VocabDetail({
    super.key,
    required this.v,
    required this.store,
    required this.content,
  });

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: Text(v.jp),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            v.jp,
            style: const TextStyle(
              fontSize: 64,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            v.reading,
            style: Theme.of(c)
                .textTheme
                .titleLarge,
          ),
          Text(v.romaji),
          const SizedBox(height: 8),
          Text(
            v.meaning,
            style: Theme.of(c)
                .textTheme
                .titleMedium,
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: () => speak(v.jp),
            icon: const Icon(
              Icons.volume_up,
            ),
            label: const Text(
              'Dengarkan',
            ),
          ),
          if (v.examples.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text(
              'Contoh kalimat',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            ...v.examples.map(
              (e) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.ja,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight:
                              FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(e.en),
                      if (e.furigana.isNotEmpty)
                        Text(
                          e.furigana,
                          style: const TextStyle(
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> speak(String text) async {
  final tts = FlutterTts();

  await tts.setLanguage('ja-JP');
  await tts.setSpeechRate(.42);
  await tts.speak(text);
}

class GrammarTile extends StatelessWidget {
  final GrammarPoint g;

  const GrammarTile({
    super.key,
    required this.g,
  });

  @override
  Widget build(BuildContext c) {
    return Card(
      margin:
          const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 5,
      ),
      child: ListTile(
        title: Text(
          '${g.pattern}  ${g.level}',
          style: const TextStyle(
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          '${g.meaning}\n${g.formation}',
        ),
        onTap: () => Navigator.push(
          c,
          MaterialPageRoute(
            builder: (_) => GrammarDetail(
              g: g,
            ),
          ),
        ),
      ),
    );
  }
}

class GrammarPage extends StatelessWidget {
  final ContentPack content;

  const GrammarPage({
    super.key,
    required this.content,
  });

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Grammar N5–N1',
        ),
      ),
      body: ListView(
        padding:
            const EdgeInsets.symmetric(
          vertical: 8,
        ),
        children: [
          for (final l in [
            'N5',
            'N4',
            'N3',
            'N2',
            'N1',
          ]) ...[
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(
                18,
                16,
                18,
                4,
              ),
              child: Text(
                l,
                style: Theme.of(c)
                    .textTheme
                    .titleLarge
                    ?.copyWith(
                      fontWeight:
                          FontWeight.bold,
                    ),
              ),
            ),
            ...content.grammar
                .where((g) => g.level == l)
                .map(
                  (g) => GrammarTile(g: g),
                ),
          ],
        ],
      ),
    );
  }
}

class GrammarDetail extends StatelessWidget {
  final GrammarPoint g;

  const GrammarDetail({
    super.key,
    required this.g,
  });

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: Text(g.pattern),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            g.pattern,
            style: const TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(g.romaji),
          const SizedBox(height: 10),
          Text(
            g.meaning,
            style: Theme.of(c)
                .textTheme
                .titleLarge,
          ),
          const SizedBox(height: 14),
          Text(
            'Pembentukan',
            style: Theme.of(c)
                .textTheme
                .titleMedium
                ?.copyWith(
                  fontWeight:
                      FontWeight.bold,
                ),
          ),
          Text(g.formation),
          const SizedBox(height: 14),
          Text(
            'Catatan',
            style: Theme.of(c)
                .textTheme
                .titleMedium
                ?.copyWith(
                  fontWeight:
                      FontWeight.bold,
                ),
          ),
          Text(g.notes),
          const SizedBox(height: 14),
          for (final e in g.examples)
            Card(
              child: Padding(
                padding:
                    const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.ja,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                    Text(e.en),
                    const SizedBox(height: 6),
                    IconButton(
                      onPressed: () =>
                          speak(e.ja),
                      icon: const Icon(
                        Icons.volume_up,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ReviewPage extends StatefulWidget {
  final AppStore store;
  final ContentPack content;

  const ReviewPage({
    super.key,
    required this.store,
    required this.content,
  });

  @override
  State<ReviewPage> createState() =>
      _ReviewPageState();
}

class _ReviewPageState
    extends State<ReviewPage> {
  int index = 0;
  bool revealed = false;
  late List<Vocab> deck;

  @override
  void initState() {
    super.initState();
    _buildDeck();
  }

  void _buildDeck() {
    final due = widget.content.vocab
        .where(
          (v) =>
              widget.store.srs[v.id]?.isDue ??
              true,
        )
        .toList()
      ..shuffle();

    deck = due.take(40).toList();

    if (deck.isEmpty) {
      deck = (List.of(widget.content.vocab)
            ..shuffle())
          .take(20)
          .toList();
    }
  }

  @override
  Widget build(BuildContext c) {
    if (deck.isEmpty) {
      return const Center(
        child: Text(
          'Belum ada kartu.',
        ),
      );
    }

    final v = deck[index % deck.length];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(
              'SRS / Anki',
              style: Theme.of(c)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(
                    fontWeight:
                        FontWeight.w900,
                  ),
            ),
            Text(
              '${deck.length} kartu • kartu salah akan diprioritaskan lagi',
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Card(
                color: Theme.of(c)
                    .colorScheme
                    .primaryContainer,
                child: InkWell(
                  onTap: () => setState(
                    () => revealed = true,
                  ),
                  child: Center(
                    child: Padding(
                      padding:
                          const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment:
                            MainAxisAlignment
                                .center,
                        children: [
                          Text(
                            v.jp,
                            style:
                                const TextStyle(
                              fontSize: 56,
                              fontWeight:
                                  FontWeight.w900,
                            ),
                          ),
                          const SizedBox(
                            height: 10,
                          ),
                          Text(
                            v.reading,
                            style:
                                const TextStyle(
                              fontSize: 20,
                            ),
                          ),
                          if (revealed) ...[
                            const SizedBox(
                              height: 18,
                            ),
                            Text(
                              v.meaning,
                              textAlign:
                                  TextAlign.center,
                              style:
                                  const TextStyle(
                                fontSize: 20,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                            const SizedBox(
                              height: 8,
                            ),
                            if (v.examples
                                .isNotEmpty)
                              Text(
                                v.examples
                                    .first
                                    .ja,
                                textAlign:
                                    TextAlign.center,
                              ),
                          ] else
                            const Padding(
                              padding:
                                  EdgeInsets.only(
                                top: 18,
                              ),
                              child: Text(
                                'Tap kartu untuk melihat arti',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (revealed)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          _rate(false),
                      child: const Text(
                        'Lupa',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () =>
                          _rate(true),
                      child: const Text(
                        'Ingat',
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _rate(bool ok) async {
    final v = deck[index % deck.length];

    await widget.store.answer(
      v.id,
      ok,
    );

    if (!mounted) return;

    setState(() {
      index++;
      revealed = false;
    });
  }
}

class KanjiPracticePage
    extends StatefulWidget {
  final AppStore store;
  final ContentPack content;
  final Kanji? initial;

  const KanjiPracticePage({
    super.key,
    required this.store,
    required this.content,
    this.initial,
  });

  @override
  State<KanjiPracticePage> createState() =>
      _KanjiPracticePageState();
}

class _KanjiPracticePageState
    extends State<KanjiPracticePage> {
  late Kanji k;

  final List<List<Offset>> strokes = [];
  List<Offset> current = [];

  @override
  void initState() {
    super.initState();

    k = widget.initial ??
        (List.of(widget.content.kanji)
          ..shuffle())
            .first;
  }

  void next() {
    final i = widget.content.kanji.indexOf(k);

    setState(() {
      k = widget.content.kanji[
          (i + 1) %
              widget.content.kanji.length];
      strokes.clear();
    });
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Stroke Order + Writing',
        ),
        actions: [
          IconButton(
            onPressed: next,
            icon: const Icon(
              Icons.skip_next,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Row(
            children: [
              Text(
                k.char,
                style: const TextStyle(
                  fontSize: 64,
                  fontWeight:
                      FontWeight.w900,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      k.meaning,
                      style: Theme.of(c)
                          .textTheme
                          .titleLarge,
                    ),
                    Text(
                      '${k.reading} • ${k.strokes} strokes • ${k.level}',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding:
                  const EdgeInsets.all(10),
              child: StrokeViewer(
                char: k.char,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Tulis dengan jari',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 360,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(c)
                    .colorScheme
                    .surfaceContainerHighest,
                borderRadius:
                    BorderRadius.circular(24),
              ),
              child: GestureDetector(
                onPanStart: (d) => setState(
                  () => current = [
                    d.localPosition
                  ],
                ),
                onPanUpdate: (d) => setState(
                  () => current
                      .add(d.localPosition),
                ),
                onPanEnd: (_) => setState(() {
                  if (current.isNotEmpty) {
                    strokes.add(
                      List.of(current),
                    );
                  }
                  current = [];
                }),
                child: CustomPaint(
                  painter:
                      HandwritingPainter(
                    strokes,
                    current,
                    k.char,
                  ),
                  child:
                      const SizedBox.expand(),
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(
                    () => strokes.clear(),
                  ),
                  child: const Text(
                    'Hapus',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    await widget.store.award(5);

                    if (mounted) {
                      ScaffoldMessenger.of(c)
                          .showSnackBar(
                        const SnackBar(
                          content:
                              Text('+5 XP'),
                        ),
                      );
                    }
                  },
                  child: const Text(
                    'Selesai',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class StrokeViewer extends StatelessWidget {
  final String char;

  const StrokeViewer({
    super.key,
    required this.char,
  });

  @override
  Widget build(BuildContext c) {
    final code = char.runes.first
        .toRadixString(16)
        .padLeft(5, '0');

    return Column(
      children: [
        SizedBox(
          height: 260,
          child: SvgPicture.asset(
            'assets/data/strokes/$code.svg',
            fit: BoxFit.contain,
            placeholderBuilder: (_) =>
                Center(
              child: Text(
                char,
                style:
                    const TextStyle(
                  fontSize: 120,
                ),
              ),
            ),
            semanticsLabel:
                'Stroke order $char',
          ),
        ),
        const Text(
          'Animasi mengikuti urutan goresan KanjiVG',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class HandwritingPainter
    extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> current;
  final String target;

  HandwritingPainter(
    this.strokes,
    this.current,
    this.target,
  );

  @override
  void paint(Canvas canvas, Size s) {
    final ghost = Paint()
      ..color =
          Colors.grey.withOpacity(.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;

    final ink = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 6;

    final tp = TextPainter(
      text: TextSpan(
        text: target,
        style: TextStyle(
          fontSize:
              min(s.width, s.height) * .52,
          color:
              Colors.grey.withOpacity(.14),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    tp.paint(
      canvas,
      Offset(
        (s.width - tp.width) / 2,
        (s.height - tp.height) / 2,
      ),
    );

    for (final st in [
      ...strokes,
      if (current.isNotEmpty) current,
    ]) {
      for (
        int i = 1;
        i < st.length;
        i++
      ) {
        canvas.drawLine(
          st[i - 1],
          st[i],
          ink,
        );
      }
    }

    canvas.drawLine(
      Offset(s.width / 2, 0),
      Offset(
        s.width / 2,
        s.height,
      ),
      ghost,
    );

    canvas.drawLine(
      Offset(0, s.height / 2),
      Offset(
        s.width,
        s.height / 2,
      ),
      ghost,
    );
  }

  @override
  bool shouldRepaint(
    covariant HandwritingPainter oldDelegate,
  ) {
    return true;
  }
}

class SpeakingPage extends StatefulWidget {
  final AppStore store;
  final ContentPack content;
  final bool embedded;

  const SpeakingPage({
    super.key,
    required this.store,
    required this.content,
    this.embedded = false,
  });

  @override
  State<SpeakingPage> createState() =>
      _SpeakingPageState();
}

class _SpeakingPageState
    extends State<SpeakingPage> {
  final stt.SpeechToText speech =
      stt.SpeechToText();

  final FlutterTts tts = FlutterTts();

  final Random rnd = Random();

  late Vocab target;

  bool ready = false;
  bool listening = false;

  String heard = '';
  double score = 0;

  @override
  void initState() {
    super.initState();

    _next();
    _initSpeech();
  }

  void _next() {
    target =
        (List.of(widget.content.vocab)
              ..shuffle(rnd))
            .first;

    heard = '';
    score = 0;
  }

  Future<void> _initSpeech() async {
    ready = await speech.initialize(
      onStatus: (_) {},
      onError: (_) {},
    );

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _listen() async {
    if (!ready) return;

    setState(
      () => listening = true,
    );

    await speech.listen(
      localeId: 'ja_JP',
      onResult: (r) => setState(
        () => heard = r.recognizedWords,
      ),
    );
  }

  Future<void> _stop() async {
    await speech.stop();

    setState(() {
      listening = false;
      score =
          similarity(heard, target.jp) *
              100;
    });

    await widget.store.answer(
      target.id,
      score >= 70,
    );
  }

  @override
  Widget build(BuildContext c) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Speaking & Listening',
                    style: Theme.of(c)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(
                          fontWeight:
                              FontWeight.w900,
                        ),
                  ),
                ),
                IconButton(
                  onPressed: () =>
                      setState(_next),
                  icon: const Icon(
                    Icons.refresh,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Card(
              color: Theme.of(c)
                  .colorScheme
                  .primaryContainer,
              child: Padding(
                padding:
                    const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(
                      target.jp,
                      style:
                          const TextStyle(
                        fontSize: 52,
                        fontWeight:
                            FontWeight.w900,
                      ),
                    ),
                    Text(target.reading),
                    Text(
                      target.meaning,
                      textAlign:
                          TextAlign.center,
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: () async {
                        await tts.setLanguage(
                          'ja-JP',
                        );
                        await tts.setSpeechRate(
                          .42,
                        );
                        await tts.speak(
                          target.jp,
                        );
                      },
                      icon: const Icon(
                        Icons.volume_up,
                      ),
                      label: const Text(
                        'Dengarkan',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              heard.isEmpty
                  ? 'Tekan mikrofon, lalu ucapkan kata Jepang.'
                  : heard,
              style: Theme.of(c)
                  .textTheme
                  .titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (score > 0)
              Text(
                'Kemiripan: ${score.round()}%',
                style:
                    const TextStyle(
                  fontSize: 22,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            const Spacer(),
            if (!ready)
              const Text(
                'Speech recognition belum tersedia di perangkat ini.',
              ),
            FilledButton.icon(
              onPressed: ready
                  ? (listening
                      ? _stop
                      : _listen)
                  : null,
              icon: Icon(
                listening
                    ? Icons.stop
                    : Icons.mic,
              ),
              label: Text(
                listening
                    ? 'Berhenti & nilai'
                    : 'Mulai speaking',
              ),
              style:
                  FilledButton.styleFrom(
                minimumSize:
                    const Size.fromHeight(
                  54,
                ),
              ),
            ),
            if (widget.embedded)
              const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }
}

double similarity(
  String a,
  String b,
) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;

  final aa = a.replaceAll(
    RegExp(r'[。、！？\s]'),
    '',
  );

  final bb = b.replaceAll(
    RegExp(r'[。、！？\s]'),
    '',
  );

  final prev =
      List<int>.generate(
    bb.length + 1,
    (i) => i,
  );

  for (
    int i = 1;
    i <= aa.length;
    i++
  ) {
    int left = i;
    int diag = i - 1;

    for (
      int j = 1;
      j <= bb.length;
      j++
    ) {
      final up = prev[j];

      final cost =
          aa[i - 1] == bb[j - 1]
              ? 0
              : 1;

      final v = min(
        up + 1,
        min(
          left + 1,
          diag + cost,
        ),
      );

      prev[j] = v;
      diag = up;
      left = v;
    }
  }

  final dist = prev.last;

  return 1 -
      dist /
          max(
            aa.length,
            bb.length,
          );
}

class LevelPage extends StatelessWidget {
  final String level;
  final ContentPack content;
  final AppStore store;

  const LevelPage({
    super.key,
    required this.level,
    required this.content,
    required this.store,
  });

  @override
  Widget build(BuildContext c) {
    final v = content.vocab
        .where(
          (x) => x.level == level,
        )
        .take(1000)
        .toList();

    final k = content.kanji
        .where(
          (x) => x.level == level,
        )
        .take(1000)
        .toList();

    final g = content.grammar
        .where(
          (x) => x.level == level,
        )
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'JLPT $level',
        ),
      ),
      body: ListView(
        padding:
            const EdgeInsets.all(18),
        children: [
          Text(
            '$level • ${v.length} kata • ${k.length} kanji • ${g.length} grammar',
            style: Theme.of(c)
                .textTheme
                .titleLarge,
          ),
          const SizedBox(height: 12),
          ...v
              .take(40)
              .map(
                (x) => VocabTile(
                  v: x,
                  store: store,
                  content: content,
                ),
              ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) =>
                    GrammarPage(
                  content: content,
                ),
              ),
            ),
            child: const Text(
              'Buka semua grammar',
            ),
          ),
        ],
      ),
    );
  }
}

class AiTutor extends StatefulWidget {
  final AppStore store;
  final ContentPack content;

  const AiTutor({
    super.key,
    required this.store,
    required this.content,
  });

  @override
  State<AiTutor> createState() =>
      _AiTutorState();
}

class _AiTutorState
    extends State<AiTutor> {
  final input =
      TextEditingController();

  final scroll =
      ScrollController();

  bool loading = false;

  final presets = [
    'Koreksi kalimat saya',
    'Buat kuis N5',
    'Latihan speaking',
    'Jelaskan grammar',
    'Buat rencana 30 hari',
  ];

  Future<void> send([
    String? preset,
  ]) async {
    final text =
        (preset ?? input.text).trim();

    if (text.isEmpty || loading) return;

    input.clear();

    setState(() {
      loading = true;

      widget.store.chats.add({
        'role': 'user',
        'text': text,
      });
    });

    scrollToEnd();

    final weak =
        widget.store.weakest(12).join(', ');

    String reply;

    if (widget.store.apiKey.isEmpty) {
      reply =
          'Mode demo. Kesalahan yang paling sering tersimpan: '
          '${weak.isEmpty ? 'belum ada data' : weak}.'
          '\n\n'
          'Untuk AI nyata, isi API key pada Pengaturan AI. '
          'Saya sudah menyiapkan konteks tutor agar AI memprioritaskan item yang sering salah.';
    } else {
      try {
        final r = await http.post(
          Uri.parse(
            widget.store.endpoint,
          ),
          headers: {
            'Content-Type':
                'application/json',
            'Authorization':
                'Bearer ${widget.store.apiKey}',
          },
          body: jsonEncode({
            'model':
                widget.store.model,
            'messages': [
              {
                'role': 'system',
                'content':
                    'Kamu adalah AI Sensei bahasa Jepang untuk penutur Indonesia. '
                    'Ajarkan N5-N1. Gunakan konteks kesalahan berikut untuk membuat latihan personal: '
                    '$weak. Koreksi secara spesifik, jangan hanya memberi jawaban. '
                    'Sertakan Jepang, bacaan dan arti Indonesia bila relevan.',
              },
              ...widget.store.chats
                  .takeLast(10)
                  .map(
                    (e) => {
                      'role': e['role'],
                      'content': e['text'],
                    },
                  ),
              {
                'role': 'user',
                'content': text,
              },
            ],
          }),
        );

        if (r.statusCode >= 200 &&
            r.statusCode < 300) {
          final d =
              jsonDecode(r.body);

          reply = d['choices'][0]
              ['message']['content']
              .toString();
        } else {
          reply =
              'AI error ${r.statusCode}: ${r.body}';
        }
      } catch (e) {
        reply =
            'Gagal terhubung ke AI: $e';
      }
    }

    widget.store.chats.add({
      'role': 'assistant',
      'text': reply,
    });

    await widget.store.save();

    if (mounted) {
      setState(
        () => loading = false,
      );
    }

    scrollToEnd();
  }

  void scrollToEnd() {
    if (scroll.hasClients) {
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration:
            const Duration(
          milliseconds: 250,
        ),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext c) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(
              18,
              18,
              18,
              8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .start,
                    children: [
                      Text(
                        'AI Sensei',
                        style: Theme.of(c)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              fontWeight:
                                  FontWeight.w900,
                            ),
                      ),
                      const Text(
                        'Tutor pribadi berdasarkan pola kesalahan',
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () =>
                      settings(c),
                  icon: const Icon(
                    Icons.settings,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection:
                  Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(
                horizontal: 18,
              ),
              itemCount: presets.length,
              separatorBuilder:
                  (_, __) =>
                      const SizedBox(
                width: 8,
              ),
              itemBuilder: (_, i) =>
                  ActionChip(
                label:
                    Text(presets[i]),
                onPressed: () =>
                    send(presets[i]),
              ),
            ),
          ),
          Expanded(
            child: widget.store.chats.isEmpty
                ? const Center(
                    child: Padding(
                      padding:
                          EdgeInsets.all(28),
                      child: Text(
                        'Tanya grammar, koreksi kalimat, speaking, role-play, atau minta kuis.',
                        textAlign:
                            TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: scroll,
                    padding:
                        const EdgeInsets.all(
                      14,
                    ),
                    itemCount:
                        widget.store.chats.length,
                    itemBuilder: (_, i) {
                      final m =
                          widget.store.chats[i];

                      final me =
                          m['role'] == 'user';

                      return Align(
                        alignment: me
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin:
                              const EdgeInsets.only(
                            bottom: 10,
                          ),
                          padding:
                              const EdgeInsets.all(
                            14,
                          ),
                          constraints:
                              BoxConstraints(
                            maxWidth:
                                MediaQuery.of(c)
                                        .size
                                        .width *
                                    .86,
                          ),
                          decoration:
                              BoxDecoration(
                            color: me
                                ? Theme.of(c)
                                    .colorScheme
                                    .primaryContainer
                                : Theme.of(c)
                                    .colorScheme
                                    .surfaceContainerHighest,
                            borderRadius:
                                BorderRadius.circular(
                              18,
                            ),
                          ),
                          child: Text(
                            m['text'] ?? '',
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (loading)
            const LinearProgressIndicator(
              minHeight: 2,
            ),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(
              12,
              8,
              12,
              12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: input,
                    minLines: 1,
                    maxLines: 4,
                    decoration:
                        const InputDecoration(
                      hintText:
                          'Tulis ke AI Sensei...',
                      border:
                          OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed:
                      loading ? null : send,
                  icon: const Icon(
                    Icons.send,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> settings(
    BuildContext c,
  ) async {
    final k = TextEditingController(
      text: widget.store.apiKey,
    );

    final e = TextEditingController(
      text: widget.store.endpoint,
    );

    final m = TextEditingController(
      text: widget.store.model,
    );

    await showDialog(
      context: c,
      builder: (_) => AlertDialog(
        title: const Text(
          'Pengaturan AI',
        ),
        content:
            SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: e,
                decoration:
                    const InputDecoration(
                  labelText: 'Endpoint',
                ),
              ),
              TextField(
                controller: m,
                decoration:
                    const InputDecoration(
                  labelText: 'Model',
                ),
              ),
              TextField(
                controller: k,
                obscureText: true,
                decoration:
                    const InputDecoration(
                  labelText: 'API Key',
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Untuk produksi jangan taruh API key langsung di APK publik.\n'
                'Gunakan backend/proxy.',
                style: TextStyle(
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(c),
            child: const Text(
              'Batal',
            ),
          ),
          FilledButton(
            onPressed: () async {
              widget.store.endpoint =
                  e.text.trim();

              widget.store.model =
                  m.text.trim();

              widget.store.apiKey =
                  k.text.trim();

              await widget.store.save();

              if (c.mounted) {
                Navigator.pop(c);
              }
            },
            child: const Text(
              'Simpan',
            ),
          ),
        ],
      ),
    );
  }
}

class Profile extends StatelessWidget {
  final AppStore store;
  final ContentPack content;

  const Profile({
    super.key,
    required this.store,
    required this.content,
  });

  @override
  Widget build(BuildContext c) {
    final acc = store.questions == 0
        ? 0
        : (store.correct /
                store.questions *
                100)
            .round();

    final due = content.vocab
        .where(
          (v) =>
              store.srs[v.id]?.isDue ??
              true,
        )
        .length;

    return SafeArea(
      child: ListView(
        padding:
            const EdgeInsets.all(18),
        children: [
          Text(
            'Profil & Statistik',
            style: Theme.of(c)
                .textTheme
                .headlineMedium
                ?.copyWith(
                  fontWeight:
                      FontWeight.w900,
                ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              StatBox(
                'XP',
                '${store.xp}',
              ),
              StatBox(
                'Akurasi',
                '$acc%',
              ),
              StatBox(
                'Review',
                '$due',
              ),
            ],
          ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.library_books,
                  ),
                  title: const Text(
                    'Content pack',
                  ),
                  subtitle: Text(
                    '${content.vocab.length} kosakata • '
                    '${content.kanji.length} kanji • '
                    '${content.grammar.length} grammar',
                  ),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.warning_amber,
                  ),
                  title: const Text(
                    'Kesalahan tersering',
                  ),
                  subtitle: Text(
                    store
                        .weakest(5)
                        .join(', ')
                        .ifEmpty(
                          'Belum ada data',
                        ),
                  ),
                ),
                SwitchListTile(
                  title: const Text(
                    'Mode gelap',
                  ),
                  value: store.dark,
                  onChanged: (v) {
                    store.dark = v;
                    store.save();
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                  ),
                  title: const Text(
                    'Hapus riwayat AI',
                  ),
                  onTap: () async {
                    store.chats.clear();

                    await store.save();

                    if (c.mounted) {
                      ScaffoldMessenger.of(
                        c,
                      ).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Riwayat dihapus.',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const Card(
            child: Padding(
              padding:
                  EdgeInsets.all(16),
              child: Text(
                'Sumber data: OpenJLPT (CC BY-SA 4.0), '
                'yang menggabungkan JMdict, KANJIDIC2, '
                'daftar level JLPT komunitas, dan Tatoeba.\n'
                'Stroke order: KanjiVG (CC BY-SA 3.0). '
                'Level JLPT adalah perkiraan komunitas, '
                'bukan daftar resmi JLPT.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StatBox extends StatelessWidget {
  final String a;
  final String b;

  const StatBox(
    this.a,
    this.b, {
    super.key,
  });

  @override
  Widget build(BuildContext c) {
    return Expanded(
      child: Card(
        child: Padding(
          padding:
              const EdgeInsets.all(14),
          child: Column(
            children: [
              Text(
                b,
                style:
                    const TextStyle(
                  fontSize: 21,
                  fontWeight:
                      FontWeight.w900,
                ),
              ),
              Text(a),
            ],
          ),
        ),
      ),
    );
  }
}

extension TakeLast<T>
    on Iterable<T> {
  Iterable<T> takeLast(int n) {
    final l = toList();

    return l.length <= n
        ? l
        : l.sublist(
            l.length - n,
          );
  }
}

extension StringEmpty on String {
  String ifEmpty(
    String fallback,
  ) {
    return isEmpty
        ? fallback
        : this;
  }
}
