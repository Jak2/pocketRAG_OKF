// test/memory/memory_fact_test.dart
//
// Memory is the one thing here that persists across sessions, so the store is
// tested against a real file: a bug that only shows up after save/load is
// exactly the bug that reaches a user.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/memory/memory_fact.dart';

const _day = Duration.millisecondsPerDay;

void main() {
  group('memoryKindFrom', () {
    test('maps the known kinds', () {
      expect(memoryKindFrom('preference'), MemoryKind.preference);
      expect(memoryKindFrom('project'), MemoryKind.project);
      expect(memoryKindFrom('correction'), MemoryKind.correction);
      expect(memoryKindFrom(' FACT '), MemoryKind.fact);
    });

    test('an unknown or missing kind becomes fact rather than throwing', () {
      // The kind is free text from a small model; it will be wrong regularly
      // and that must not cost the extraction.
      expect(memoryKindFrom('opinion'), MemoryKind.fact);
      expect(memoryKindFrom(null), MemoryKind.fact);
      expect(memoryKindFrom(''), MemoryKind.fact);
    });
  });

  group('parseExtraction', () {
    test('parses a clean JSON array', () {
      final facts = parseExtraction(
          '[{"text": "prefers dart", "kind": "preference"}, {"text": "building an app", "kind": "project"}]');
      expect(facts.map((f) => f.text), ['prefers dart', 'building an app']);
      expect(facts.map((f) => f.kind), [MemoryKind.preference, MemoryKind.project]);
    });

    test('finds the array inside prose and code fences', () {
      const reply = 'Sure! Here is what I found:\n```json\n[{"text": "likes tea"}]\n```\nHope that helps.';
      expect(parseExtraction(reply).single.text, 'likes tea');
    });

    test('malformed JSON yields nothing and never throws', () {
      // Half-parsed garbage in the store is worse than no extraction at all.
      expect(parseExtraction('[{"text": "unclosed]'), isEmpty);
      expect(parseExtraction('[{"text" "missing colon"}]'), isEmpty);
      expect(parseExtraction('[[[['), isEmpty);
    });

    test('a reply with no array at all yields nothing', () {
      expect(parseExtraction('Nothing worth remembering.'), isEmpty);
      expect(parseExtraction(''), isEmpty);
      expect(parseExtraction(']['), isEmpty);
    });

    test('a bracket span that is not valid JSON yields nothing', () {
      expect(parseExtraction('"[not really]"'), isEmpty);
      expect(parseExtraction('see [the notes](notes.md)'), isEmpty);
    });

    test('an array nested in a JSON object is still harvested', () {
      // The parser takes the widest bracket span rather than requiring the
      // reply to be an array; a model that wraps its answer in an object is a
      // formatting miss, not a reason to lose the facts.
      expect(parseExtraction('{"facts": [{"text": "x"}]}').single.text, 'x');
    });

    test('an empty array yields nothing', () {
      expect(parseExtraction('[]'), isEmpty);
    });

    test('caps the harvest at five facts however many the model produced', () {
      final reply = jsonEncode(List.generate(12, (i) => {'text': 'fact $i', 'kind': 'fact'}));
      expect(parseExtraction(reply).length, 5);
    });

    test('an unknown kind is coerced to fact instead of dropping the row', () {
      expect(parseExtraction('[{"text": "x", "kind": "vibes"}]').single.kind, MemoryKind.fact);
      expect(parseExtraction('[{"text": "x"}]').single.kind, MemoryKind.fact);
    });

    test('blank and non-map entries are skipped', () {
      final facts = parseExtraction('[{"text": "   "}, "loose string", 7, {"text": "kept"}]');
      expect(facts.map((f) => f.text), ['kept']);
    });

    test('a non-string text is stringified rather than crashing the parse', () {
      expect(parseExtraction('[{"text": 42}]').single.text, '42');
    });
  });

  group('MemoryStore', () {
    late Directory dir;
    late MemoryStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('memory_store_');
      store = MemoryStore(File('${dir.path}/memory.json'));
      await store.load();
    });

    tearDown(() async => dir.delete(recursive: true));

    test('upsert inserts and persists', () async {
      await store.upsert(id: 'a', text: 'prefers dart', kind: MemoryKind.preference, now: 1000);
      expect(store.all.single.text, 'prefers dart');

      final reloaded = MemoryStore(store.file);
      await reloaded.load();
      expect(reloaded.all.single.id, 'a');
      expect(reloaded.all.single.kind, MemoryKind.preference);
      expect(reloaded.all.single.created, 1000);
    });

    test('upsert with a matching duplicate merges instead of inserting', () async {
      // Without this the store fills with fifty rephrasings of one preference.
      await store.upsert(id: 'a', text: 'prefers dart', kind: MemoryKind.preference, now: 1000);
      final merged = await store.upsert(
        id: 'b',
        text: 'the user likes dart',
        kind: MemoryKind.preference,
        now: 5000,
        isDuplicate: (existing) => existing.text.contains('dart'),
      );

      expect(store.all.length, 1);
      expect(merged.id, 'a');
      expect(merged.text, 'prefers dart');
      expect(merged.lastUsed, 5000);
    });

    test('a duplicate check that matches nothing still inserts', () async {
      await store.upsert(id: 'a', text: 'prefers dart', kind: MemoryKind.fact, now: 1000);
      await store.upsert(
        id: 'b',
        text: 'lives in berlin',
        kind: MemoryKind.fact,
        now: 2000,
        isDuplicate: (existing) => existing.text.contains('rust'),
      );
      expect(store.all.length, 2);
    });

    test('a deactivated fact is not a merge target', () async {
      await store.upsert(id: 'a', text: 'prefers dart', kind: MemoryKind.fact, now: 1000);
      await store.update('a', active: false);
      await store.upsert(
        id: 'b',
        text: 'prefers dart',
        kind: MemoryKind.fact,
        now: 2000,
        isDuplicate: (existing) => true,
      );
      expect(store.all.length, 2);
    });

    test('recordHit increments the count and refreshes lastUsed', () async {
      await store.upsert(id: 'a', text: 'x', kind: MemoryKind.fact, now: 1000);
      await store.recordHit('a', now: 4000);
      await store.recordHit('a', now: 9000);

      expect(store.all.single.hits, 2);
      expect(store.all.single.lastUsed, 9000);
    });

    test('recordHit on an unknown id is a no-op, not an error', () async {
      await store.recordHit('missing');
      expect(store.all, isEmpty);
    });

    test('decay soft-deletes only never-used facts past the cutoff', () async {
      final now = 400 * _day;
      final old = now - 200 * _day;
      final recent = now - 10 * _day;

      await store.upsert(id: 'stale', text: 'never touched', kind: MemoryKind.fact, now: old);
      await store.upsert(id: 'used', text: 'leaned on', kind: MemoryKind.fact, now: old);
      await store.recordHit('used', now: old);
      await store.upsert(id: 'fresh', text: 'new', kind: MemoryKind.fact, now: recent);

      expect(await store.decay(now: now), 1);
      expect(store.active.map((f) => f.id), ['used', 'fresh']);
    });

    test('decay never hard-deletes, so the user can still see what was dropped', () async {
      await store.upsert(id: 'stale', text: 'x', kind: MemoryKind.fact, now: 0);
      await store.decay(now: 400 * _day);

      expect(store.all.length, 1);
      expect(store.all.single.active, isFalse);
      expect(store.active, isEmpty);

      final reloaded = MemoryStore(store.file);
      await reloaded.load();
      expect(reloaded.all.single.active, isFalse);
    });

    test('decay is idempotent and only writes when something changed', () async {
      await store.upsert(id: 'stale', text: 'x', kind: MemoryKind.fact, now: 0);
      expect(await store.decay(now: 400 * _day), 1);
      expect(await store.decay(now: 400 * _day), 0);
    });

    test('update edits in place and leaves other rows alone', () async {
      await store.upsert(id: 'a', text: 'old', kind: MemoryKind.fact, now: 1000);
      await store.upsert(id: 'b', text: 'other', kind: MemoryKind.fact, now: 1000);
      await store.update('a', text: 'new', kind: MemoryKind.correction);

      expect(store.all.first.text, 'new');
      expect(store.all.first.kind, MemoryKind.correction);
      expect(store.all.last.text, 'other');
    });

    test('a missing store file loads as empty rather than failing', () async {
      final fresh = MemoryStore(File('${dir.path}/nested/none.json'));
      await fresh.load();
      expect(fresh.all, isEmpty);
    });

    test('a corrupt store file degrades to empty rather than blocking the app', () async {
      await store.file.writeAsString('{not json at all');
      await store.load();
      expect(store.all, isEmpty);
    });

    test('a JSON document that is not a list also degrades to empty', () async {
      await store.file.writeAsString('{"facts": []}');
      await store.load();
      expect(store.all, isEmpty);
    });
  });

  group('memoryScore', () {
    final now = 400 * _day;
    MemoryFact fact({int hits = 0, int ageDays = 0}) => MemoryFact(
          id: 'f',
          text: 't',
          kind: MemoryKind.fact,
          created: now - ageDays * _day,
          lastUsed: now - ageDays * _day,
          hits: hits,
        );

    test('a fact used more often ranks above an equally similar one', () {
      final leaned = memoryScore(0.8, fact(hits: 20), now: now);
      final untouched = memoryScore(0.8, fact(hits: 0), now: now);
      expect(leaned, greaterThan(untouched));
    });

    test('an older fact ranks below a recent one at equal similarity and usage', () {
      final recent = memoryScore(0.8, fact(ageDays: 1), now: now);
      final old = memoryScore(0.8, fact(ageDays: 180), now: now);
      expect(old, lessThan(recent));
    });

    test('the recency floor demotes an ancient fact without erasing it', () {
      // Zero would make an old fact unretrievable forever, which is a deletion
      // the user never asked for.
      final ancient = memoryScore(0.8, fact(ageDays: 10000), now: now);
      expect(ancient, greaterThan(0));
      expect(ancient, closeTo(0.8 * 0.25, 1e-9));
    });

    test('a fresh unused fact scores exactly its similarity', () {
      expect(memoryScore(0.8, fact(), now: now), closeTo(0.8, 1e-9));
    });

    test('a clock skew into the future does not inflate the score', () {
      final future = MemoryFact(
          id: 'f', text: 't', kind: MemoryKind.fact, created: now + 5 * _day, lastUsed: now + 5 * _day);
      expect(memoryScore(0.8, future, now: now), closeTo(0.8, 1e-9));
    });

    test('usage cannot outweigh a genuinely better match', () {
      // The boost is a tiebreaker, not an override — a much closer fact still
      // wins over a well-worn one.
      expect(memoryScore(0.9, fact(hits: 1000), now: now), lessThan(memoryScore(2.0, fact(), now: now)));
    });
  });

  group('MemoryFact json', () {
    test('survives a round trip including the soft-delete flag', () {
      const original = MemoryFact(
        id: 'a',
        text: 'prefers dart',
        kind: MemoryKind.preference,
        source: 'session-3',
        created: 1000,
        lastUsed: 2000,
        hits: 4,
        active: false,
      );
      final back = MemoryFact.fromJson(original.toJson());
      expect(back.id, 'a');
      expect(back.kind, MemoryKind.preference);
      expect(back.source, 'session-3');
      expect(back.lastUsed, 2000);
      expect(back.hits, 4);
      expect(back.active, isFalse);
    });

    test('a row written by an older version without the newer fields still loads', () {
      final back = MemoryFact.fromJson({'id': 'a', 'text': 't'});
      expect(back.kind, MemoryKind.fact);
      expect(back.hits, 0);
      expect(back.active, isTrue);
      expect(back.lastUsed, isNull);
    });
  });
}
