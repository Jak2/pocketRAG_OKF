import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// What kind of thing a remembered fact is. Free-text `kind` from the model is
/// coerced into one of these; anything unrecognised becomes [fact].
enum MemoryKind { preference, fact, project, correction }

MemoryKind memoryKindFrom(String? raw) => MemoryKind.values.firstWhere(
      (k) => k.name == raw?.trim().toLowerCase(),
      orElse: () => MemoryKind.fact,
    );

/// One durable thing the app remembers about the user.
///
/// Deliberately boring: rows of text, no fine-tuning, no weight updates.
/// "Learning" here means this file and nothing more.
class MemoryFact {
  final String id;
  final String text;
  final MemoryKind kind;

  /// Session the fact was extracted from.
  final String source;
  final int created;
  final int? lastUsed;
  final int hits;

  /// Soft-delete flag. Decay sets this to false; nothing ever hard-deletes,
  /// because the user must be able to see and restore what was dropped.
  final bool active;

  const MemoryFact({
    required this.id,
    required this.text,
    required this.kind,
    required this.created,
    this.source = '',
    this.lastUsed,
    this.hits = 0,
    this.active = true,
  });

  MemoryFact copyWith({String? text, MemoryKind? kind, int? lastUsed, int? hits, bool? active}) =>
      MemoryFact(
        id: id,
        text: text ?? this.text,
        kind: kind ?? this.kind,
        source: source,
        created: created,
        lastUsed: lastUsed ?? this.lastUsed,
        hits: hits ?? this.hits,
        active: active ?? this.active,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'text': text,
        'kind': kind.name,
        'source': source,
        'created': created,
        'last_used': lastUsed,
        'hits': hits,
        'active': active,
      };

  factory MemoryFact.fromJson(Map<String, Object?> j) => MemoryFact(
        id: j['id'] as String,
        text: j['text'] as String,
        kind: memoryKindFrom(j['kind'] as String?),
        source: j['source'] as String? ?? '',
        created: j['created'] as int? ?? 0,
        lastUsed: j['last_used'] as int?,
        hits: j['hits'] as int? ?? 0,
        active: j['active'] as bool? ?? true,
      );
}

/// The extraction prompt, run at session end or every N turns.
const String kMemoryExtractionPrompt = '''
From the conversation below, extract 0-5 durable facts worth remembering
across future sessions. Durable = stable preferences, ongoing projects,
corrections the user made to you, personal context.
NOT durable = one-off questions, transient state, anything already obvious.
Output a JSON array of {"text": "...", "kind": "preference|fact|project|correction"}.
Output [] if nothing qualifies. Output only JSON.

Conversation:
{conversation}''';

String memoryExtractionPromptFor(String conversation) =>
    kMemoryExtractionPrompt.replaceFirst('{conversation}', conversation);

/// Parses the extraction reply.
///
/// Strict on purpose: malformed JSON writes nothing. A failed extraction must
/// never be allowed to corrupt the store with half-parsed garbage, and the
/// model produces exactly that often enough to matter.
List<({String text, MemoryKind kind})> parseExtraction(String reply) {
  // Models wrap JSON in prose or fences no matter what the prompt says; take
  // the outermost array and ignore the rest.
  final start = reply.indexOf('[');
  final end = reply.lastIndexOf(']');
  if (start < 0 || end <= start) return const [];

  try {
    final parsed = jsonDecode(reply.substring(start, end + 1));
    if (parsed is! List) return const [];
    return parsed
        .whereType<Map>()
        .map((m) => (text: (m['text'] ?? '').toString().trim(), kind: memoryKindFrom(m['kind'] as String?)))
        .where((f) => f.text.isNotEmpty)
        .take(5)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Above this cosine similarity a candidate is the same fact reworded, and is
/// merged rather than inserted. Without it the store fills with fifty
/// rephrasings of one preference inside a week.
const double kDedupeThreshold = 0.92;

/// Facts unused for this long with no hits are deactivated.
const int kDecayDays = 180;

/// JSON-file store. Small, auditable, and trivially exportable — which the
/// "user can see and delete everything" requirement needs anyway.
class MemoryStore {
  final File file;
  final List<MemoryFact> _facts = [];

  MemoryStore(this.file);

  List<MemoryFact> get all => List.unmodifiable(_facts);
  List<MemoryFact> get active => _facts.where((f) => f.active).toList();

  Future<void> load() async {
    _facts.clear();
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is List) {
        _facts.addAll(data.whereType<Map>().map((m) => MemoryFact.fromJson(m.cast<String, Object?>())));
      }
    } catch (_) {
      // A corrupt store degrades to an empty one rather than blocking the app.
    }
  }

  Future<void> save() async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(_facts.map((f) => f.toJson()).toList()));
  }

  /// Inserts [text], or merges into an existing fact when [isDuplicate] says
  /// it is the same thing said differently. Returns the row that ended up
  /// holding it.
  Future<MemoryFact> upsert({
    required String id,
    required String text,
    required MemoryKind kind,
    String source = '',
    int? now,
    bool Function(MemoryFact existing)? isDuplicate,
  }) async {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;

    if (isDuplicate != null) {
      for (var i = 0; i < _facts.length; i++) {
        if (_facts[i].active && isDuplicate(_facts[i])) {
          _facts[i] = _facts[i].copyWith(lastUsed: ts);
          await save();
          return _facts[i];
        }
      }
    }

    final fact = MemoryFact(id: id, text: text, kind: kind, source: source, created: ts, lastUsed: ts);
    _facts.add(fact);
    await save();
    return fact;
  }

  Future<void> update(String id, {String? text, MemoryKind? kind, bool? active}) async {
    for (var i = 0; i < _facts.length; i++) {
      if (_facts[i].id == id) {
        _facts[i] = _facts[i].copyWith(text: text, kind: kind, active: active);
        await save();
        return;
      }
    }
  }

  /// Records that a fact was actually used, which feeds the retrieval boost.
  Future<void> recordHit(String id, {int? now}) async {
    for (var i = 0; i < _facts.length; i++) {
      if (_facts[i].id == id) {
        _facts[i] = _facts[i].copyWith(hits: _facts[i].hits + 1, lastUsed: now ?? DateTime.now().millisecondsSinceEpoch);
        await save();
        return;
      }
    }
  }

  /// Deactivates never-used facts older than [kDecayDays]. Soft only.
  Future<int> decay({int? now}) async {
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;
    final cutoff = ts - Duration(days: kDecayDays).inMilliseconds;
    var count = 0;
    for (var i = 0; i < _facts.length; i++) {
      final f = _facts[i];
      if (f.active && f.hits == 0 && (f.lastUsed ?? f.created) < cutoff) {
        _facts[i] = f.copyWith(active: false);
        count++;
      }
    }
    if (count > 0) await save();
    return count;
  }
}

/// Boosts a memory fact's similarity by how often and how recently it is used.
///
/// A fact the user leans on repeatedly should beat a marginally closer fact
/// they have never touched.
double memoryScore(double similarity, MemoryFact fact, {int? now}) {
  final ts = now ?? DateTime.now().millisecondsSinceEpoch;
  final ageDays = (ts - (fact.lastUsed ?? fact.created)) / Duration.millisecondsPerDay;
  // Halves roughly every 90 days, floored so an old fact is demoted, not erased.
  final recency = ageDays <= 0 ? 1.0 : (1 / (1 + ageDays / 90)).clamp(0.25, 1.0);
  final usage = 1 + 0.1 * _log1p(fact.hits.toDouble());
  return similarity * usage * recency;
}

double _log1p(double x) => x <= 0 ? 0 : math.log(1 + x);
