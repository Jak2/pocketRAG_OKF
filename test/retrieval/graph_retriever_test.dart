// test/retrieval/graph_retriever_test.dart
//
// The fixture bundle is written to disk and read back through loadBundle so
// the walk is tested over the same parsing and link resolution the app does,
// not over hand-built Concept objects that can drift from it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/okf/bundle.dart';
import 'package:pocket_rag_okf/retrieval/corpus.dart';
import 'package:pocket_rag_okf/retrieval/graph_retriever.dart';
import 'package:pocket_rag_okf/retrieval/retrieval_result.dart';
import 'package:pocket_rag_okf/retrieval/tokens.dart';

/// Filler of roughly [chars] characters, so a concept has a predictable token
/// cost for the budget assertions.
String _filler(String seed, int chars) {
  final buffer = StringBuffer();
  var i = 0;
  while (buffer.length < chars) {
    buffer.write('$seed$i ');
    i++;
  }
  return buffer.toString().substring(0, chars).trim();
}

void main() {
  late Directory root;
  late Corpus corpus;

  Future<void> write(String relpath, String content) async {
    final file = File('${root.path}/$relpath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('okf_graph_');

    await write('index.md', '---\ntitle: Bundle Index\n---\nThe lodestar entry point. ${_filler('idx', 80)}\n');

    // A two-node cycle: the walk must terminate on it.
    await write(
      'concepts/alpha.md',
      '---\ntitle: Alpha Concept Document\ntype: concept\ndescription: The first concept\n---\n'
      '${_filler('alpha', 500)}\n\nSee [beta](beta.md) for the counterpart.\n',
    );
    await write(
      'concepts/beta.md',
      '---\ntitle: Beta Concept Document\ntype: concept\ndescription: The quokka concept\n---\n'
      '${_filler('beta', 500)}\n\nBack to [alpha](alpha.md).\n',
    );

    // A four-node chain: hop-three sits three hops from hop-zero.
    await write('chain/hop-zero.md',
        '---\ntitle: Hop Zero Waypoint\ntype: waypoint\n---\nStart. [one](hop-one.md)\n');
    await write('chain/hop-one.md',
        '---\ntitle: Hop One Waypoint\ntype: waypoint\n---\nMiddle. [two](hop-two.md)\n');
    await write('chain/hop-two.md',
        '---\ntitle: Hop Two Waypoint\ntype: waypoint\n---\nNearly. [three](hop-three.md)\n');
    await write('chain/hop-three.md',
        '---\ntitle: Hop Three Waypoint\ntype: waypoint\n---\nToo far to reach.\n');

    await write('runbooks/deploy.md',
        '---\ntitle: Deploy Service Runbook\ntype: runbook\n---\nHow to deploy. ${_filler('deploy', 100)}\n');

    // Two neighbours that differ only in their anchor text, for link scoring.
    await write(
      'hub/hub.md',
      '---\ntitle: Hub Waypoint Document\ntype: waypoint\n---\n${_filler('hub', 300)}\n\n'
      'See [wombat details](matching.md) and [click here](other.md).\n',
    );
    await write('hub/matching.md',
        '---\ntitle: Neighbour One Document\ntype: waypoint\n---\n${_filler('mone', 340)}\n');
    await write('hub/other.md',
        '---\ntitle: Neighbour Two Document\ntype: waypoint\n---\n${_filler('mtwo', 340)}\n');

    corpus = Corpus.build(await loadBundle(root));
  });

  tearDown(() async => root.delete(recursive: true));

  group('loadBundle', () {
    test('reads every markdown file under the root, recursively', () {
      expect(corpus.bundle.concepts.length, 11);
      expect(corpus.bundle.byPath('concepts/alpha.md')?.title, 'Alpha Concept Document');
      expect(corpus.bundle.byPath('chain/hop-three.md'), isNotNull);
    });

    test('exposes the corpus type vocabulary the router builds on', () {
      expect(corpus.bundle.types, {'concept', 'waypoint', 'runbook'});
    });

    test('resolves links to bundle-relative paths that byPath can find', () {
      final alpha = corpus.bundle.byPath('concepts/alpha.md')!;
      expect(alpha.resolvedLinks.single.targetPath, 'concepts/beta.md');
      expect(corpus.bundle.byPath(alpha.resolvedLinks.single.targetPath!), isNotNull);
    });
  });

  group('linkScore', () {
    test('an anchor overlapping the query scores above an unrelated one', () {
      // Anchor text is the author's own description of why the link exists, so
      // it is the cheapest relevance signal available without a model.
      final matching = linkScore(
        query: 'wombat details please',
        anchor: 'wombat details',
        targetTitle: 'Neighbour One Document',
      );
      final unrelated = linkScore(
        query: 'wombat details please',
        anchor: 'click here',
        targetTitle: 'Neighbour One Document',
      );
      expect(matching, greaterThan(unrelated));
    });

    test('a title overlapping the query lifts the score independently of the anchor', () {
      final titled = linkScore(query: 'wombat herds', anchor: 'here', targetTitle: 'Wombat Herds');
      final untitled = linkScore(query: 'wombat herds', anchor: 'here', targetTitle: 'Something Else');
      expect(titled, greaterThan(untitled));
    });

    test('a description match counts for less than a title match', () {
      final byTitle = linkScore(query: 'wombat', anchor: 'x', targetTitle: 'Wombat');
      final byDescription =
          linkScore(query: 'wombat', anchor: 'x', targetTitle: 'Other', targetDescription: 'Wombat');
      expect(byDescription, greaterThan(0));
      expect(byDescription, lessThan(byTitle));
    });

    test('a query naming a type prefers neighbours of that type', () {
      final typed = linkScore(
          query: 'the runbook for this', anchor: 'x', targetTitle: 'Deploy', targetType: 'runbook');
      final untyped = linkScore(
          query: 'the runbook for this', anchor: 'x', targetTitle: 'Deploy', targetType: 'concept');
      expect(typed - untyped, closeTo(0.5, 1e-12));
    });

    test('a query with no indexable terms scores zero rather than dividing by zero', () {
      expect(linkScore(query: 'the and of', anchor: 'anything', targetTitle: 'Anything'), 0);
      expect(linkScore(query: '', anchor: 'anything', targetTitle: 'Anything'), 0);
    });
  });

  group('seedConcepts', () {
    test('an exact title in the query beats everything else', () {
      final seeded = seedConcepts(corpus, 'tell me about the alpha concept document today');
      expect(seeded.reason, 'title-exact');
      expect(seeded.weak, isFalse);
      expect(seeded.seeds.map((c) => c.relpath), ['concepts/alpha.md']);
    });

    test('a query naming a corpus type restricts BM25 to that type', () {
      final seeded = seedConcepts(corpus, 'runbook for a bad deploy');
      expect(seeded.reason, 'type-filter');
      expect(seeded.seeds.every((c) => c.type == 'runbook'), isTrue);
    });

    test('an ordinary query falls through to plain BM25', () {
      final seeded = seedConcepts(corpus, 'quokka');
      expect(seeded.reason, 'bm25');
      expect(seeded.weak, isFalse);
      expect(seeded.seeds.first.relpath, 'concepts/beta.md');
    });

    test('a query matching nothing lands on index.md and is flagged weak', () {
      // Weak is the whole point: index.md is an entry point, not an answer, and
      // the caller has to be able to tell the difference.
      final seeded = seedConcepts(corpus, 'xylophonic zzzzq nonsensical');
      expect(seeded.reason, 'index-fallback');
      expect(seeded.weak, isTrue);
      expect(seeded.seeds.single.relpath, 'index.md');
    });

    test('an empty bundle seeds nothing and says so', () async {
      final empty = await Directory.systemTemp.createTemp('okf_empty_');
      addTearDown(() => empty.delete(recursive: true));
      final seeded = seedConcepts(Corpus.build(await loadBundle(empty)), 'anything');
      expect(seeded.reason, 'empty-bundle');
      expect(seeded.weak, isTrue);
      expect(seeded.seeds, isEmpty);
    });

    test('a bundle with no index.md and no match reports no-seed', () async {
      final lonely = await Directory.systemTemp.createTemp('okf_lonely_');
      addTearDown(() => lonely.delete(recursive: true));
      await File('${lonely.path}/only.md').writeAsString('---\ntitle: Only\n---\nsomething\n');
      final seeded = seedConcepts(Corpus.build(await loadBundle(lonely)), 'xylophonic zzzzq');
      expect(seeded.reason, 'no-seed');
      expect(seeded.weak, isTrue);
      expect(seeded.seeds, isEmpty);
    });
  });

  group('graphRetrieve', () {
    test('a cycle terminates and each concept appears exactly once', () {
      final result = graphRetrieve(corpus, 'alpha concept document', budgetTokens: 100000);
      final sources = result.sources;
      expect(sources, contains('concepts/alpha.md'));
      expect(sources, contains('concepts/beta.md'));
      expect(sources.toSet().length, sources.length);
    });

    test('a node three hops from the seed is never returned', () {
      // kMaxDepth is the only thing stopping a densely linked bundle from
      // pulling itself entirely into the context window.
      final result = graphRetrieve(corpus, 'hop zero waypoint', budgetTokens: 100000);
      expect(result.sources, contains('chain/hop-zero.md'));
      expect(result.sources, contains('chain/hop-one.md'));
      expect(result.sources, contains('chain/hop-two.md'));
      expect(result.sources, isNot(contains('chain/hop-three.md')));
      expect(kMaxDepth, 2);
    });

    test('the walk stays inside the token budget when nothing needs truncating', () {
      const budget = 200;
      final result = graphRetrieve(corpus, 'alpha concept document', budgetTokens: budget);
      expect(result.sources, ['concepts/alpha.md']);
      expect(result.totalTokens, lessThanOrEqualTo(budget));
    });

    test('a seed too large for the budget is truncated, never dropped', () {
      // The seed is the direct answer to the question; returning nothing at all
      // would be a worse failure than returning part of it.
      const marker = '[truncated to fit the context window]';
      final result = graphRetrieve(corpus, 'alpha concept document', budgetTokens: 30);
      expect(result.sources, ['concepts/alpha.md']);
      expect(result.items.single.text, contains(marker));

      final body = result.items.single.text.replaceFirst('\n\n$marker', '');
      expect(estimateTokens(body), lessThanOrEqualTo(30));
    });

    test('a truncated seed stays inside the budget, marker included', () {
      // The marker is the only text retrieval adds of its own accord, so it is
      // the one thing that could push a result past a ceiling that everything
      // else respects. It is charged against the budget like any other text.
      final result = graphRetrieve(corpus, 'alpha concept document', budgetTokens: 30);
      expect(result.sources, ['concepts/alpha.md']);
      expect(result.items.single.text, contains('[truncated to fit the context window]'));
      expect(result.totalTokens, lessThanOrEqualTo(30));
    });

    test('a neighbour that does not fit is skipped while the seed survives', () {
      final result = graphRetrieve(corpus, 'hub waypoint document wombat', budgetTokens: 250);
      expect(result.sources.first, 'hub/hub.md');
      expect(result.sources, isNot(contains('hub/other.md')));
    });

    test('the neighbour whose anchor matches the query is walked first', () {
      final result = graphRetrieve(corpus, 'hub waypoint document wombat', budgetTokens: 250);
      expect(result.sources, contains('hub/matching.md'));
    });

    test('seeds are reported so the UI can explain where the walk started', () {
      final result = graphRetrieve(corpus, 'alpha concept document', budgetTokens: 100000);
      expect(result.seeds, ['concepts/alpha.md']);
      expect(result.mode, RetrievalMode.graph);
    });

    test('a bundle with nothing to seed from returns an empty graph result', () async {
      final empty = await Directory.systemTemp.createTemp('okf_empty2_');
      addTearDown(() => empty.delete(recursive: true));
      final result =
          graphRetrieve(Corpus.build(await loadBundle(empty)), 'anything', budgetTokens: 1000);
      expect(result.isEmpty, isTrue);
      expect(result.mode, RetrievalMode.graph);
    });

    test('a walk that finds only index.md reports itself as such', () {
      final result = graphRetrieve(corpus, 'xylophonic zzzzq nonsensical', budgetTokens: 100000);
      expect(result.onlyIndexMd, isTrue);
    });

    test('items are scored in walk order so the first-found concept ranks top', () {
      final result = graphRetrieve(corpus, 'alpha concept document', budgetTokens: 100000);
      for (var i = 1; i < result.items.length; i++) {
        expect(result.items[i - 1].score, greaterThan(result.items[i].score));
      }
    });
  });
}
