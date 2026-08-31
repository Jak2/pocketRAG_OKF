// test/retrieval/retrieval_service_test.dart
//
// The post-retrieval fallback is the riskiest code in the retrieval layer: it
// is the one place that can quietly hand back a different mode than the one
// that was asked for. The contract it must never break is that a manual choice
// is served exactly as chosen, weak or not.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/okf/bundle.dart';
import 'package:pocket_rag_okf/retrieval/corpus.dart';
import 'package:pocket_rag_okf/retrieval/retrieval_result.dart';
import 'package:pocket_rag_okf/retrieval/retrieval_service.dart';

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

  /// Query terms chosen so BM25 finds nothing anywhere in the bundle.
  const nonsense = 'xylophonic zzzzq nonsensical';

  /// Reaches index.md and nothing else: 'lodestar' appears only there, and
  /// index.md has no outgoing links for the walk to follow.
  const indexOnly = 'what is the lodestar';

  /// Names a concept title verbatim, so the graph walk has a real seed.
  const titled = 'summarise the alpha concept document';

  Future<void> write(String relpath, String content) async {
    final file = File('${root.path}/$relpath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('okf_service_');
    await write('index.md', '---\ntitle: Bundle Index\n---\nThe lodestar entry point.\n');
    await write(
      'concepts/alpha.md',
      '---\ntitle: Alpha Concept Document\ntype: concept\n---\n'
      '${_filler('alpha', 500)}\n\nSee [beta](beta.md).\n',
    );
    await write(
      'concepts/beta.md',
      '---\ntitle: Beta Concept Document\ntype: concept\n---\n'
      '${_filler('beta', 500)}\n\nBack to [alpha](alpha.md).\n',
    );
    corpus = Corpus.build(await loadBundle(root));
  });

  tearDown(() async => root.delete(recursive: true));

  /// One vector per chunk, orthogonal so a query vector selects exactly one.
  /// Chunk order follows the sorted concept order: alpha, beta, index.
  void embedOrthogonally() {
    expect(corpus.chunks.map((c) => c.conceptPath),
        ['concepts/alpha.md', 'concepts/beta.md', 'index.md']);
    for (var i = 0; i < corpus.chunks.length; i++) {
      corpus.vectors.add(i, List.generate(corpus.chunks.length, (j) => i == j ? 1.0 : 0.0));
    }
  }

  List<double> vectorFor(int chunkIndex) =>
      List.generate(corpus.chunks.length, (j) => j == chunkIndex ? 1.0 : 0.0);

  /// Puts every chunk on one axis, so [offAxisQuery] is a loaded embedding
  /// model reporting an honestly poor match rather than an absent one.
  void embedOnOneAxis() {
    for (var i = 0; i < corpus.chunks.length; i++) {
      corpus.vectors.add(i, [1, 0]);
    }
  }

  /// Cosine 0.196 against every chunk above — under kMinDenseScore.
  const offAxisQuery = [0.2, 1.0];

  group('manual mode', () {
    test('a manual graph request is served as graph even when the walk is weak', () async {
      // The switch is a promise. A manual choice that silently second-guesses
      // the user is worse than having no switch at all.
      final outcome = await retrieve(
        corpus: corpus,
        query: indexOnly,
        requested: RetrievalMode.graph,
        budgetTokens: 4000,
      );
      expect(outcome.result.mode, RetrievalMode.graph);
      expect(outcome.result.onlyIndexMd, isTrue);
      expect(outcome.decision.reason, 'manual');
      expect(outcome.fellBack, isFalse);
    });

    test('a manual graph request is served as graph even when it finds nothing', () async {
      final outcome = await retrieve(
        corpus: corpus,
        query: nonsense,
        requested: RetrievalMode.graph,
        budgetTokens: 4000,
      );
      expect(outcome.result.mode, RetrievalMode.graph);
      expect(outcome.fellBack, isFalse);
      expect(outcome.decision.reason, 'manual');
      expect(outcome.decision.confidence, 1);
    });

    test('a manual vector request is served as vector even below the score floor', () async {
      // Nothing in the fixture contains these terms, so BM25 genuinely comes
      // back with nothing and the result is weak — a manual request must still
      // be served it rather than being quietly rerouted.
      final outcome = await retrieve(
        corpus: corpus,
        query: nonsense,
        requested: RetrievalMode.vector,
        budgetTokens: 4000,
      );
      expect(outcome.result.mode, RetrievalMode.vector);
      expect(outcome.result.bestLexical, lessThan(kMinLexicalScore));
      expect(outcome.fellBack, isFalse);
      expect(outcome.decision.reason, 'manual');
    });

    test('a manual request never consults the router', () async {
      var called = false;
      final outcome = await retrieve(
        corpus: corpus,
        query: indexOnly,
        requested: RetrievalMode.vector,
        budgetTokens: 4000,
        classify: (q) async {
          called = true;
          return 'OKF';
        },
      );
      expect(called, isFalse);
      expect(outcome.decision.reason, 'manual');
    });
  });

  group('auto fallback', () {
    test('a graph route that finds only index.md falls back to vector', () async {
      embedOrthogonally();
      final outcome = await retrieve(
        corpus: corpus,
        query: indexOnly,
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
        queryVector: vectorFor(2),
      );
      expect(outcome.fellBack, isTrue);
      expect(outcome.result.mode, RetrievalMode.vector);
      expect(outcome.decision.reason, 'heuristic:definitional+fallback');
      expect(outcome.decision.mode, RetrievalMode.vector);
    });

    test('a vector route below the score floor falls back to graph', () async {
      embedOnOneAxis();
      final outcome = await retrieve(
        corpus: corpus,
        query: titled,
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
        queryVector: offAxisQuery,
      );
      expect(outcome.fellBack, isTrue);
      expect(outcome.result.mode, RetrievalMode.graph);
      expect(outcome.decision.reason, 'heuristic:synthesis+fallback');
      expect(outcome.result.sources, contains('concepts/alpha.md'));
      expect(outcome.result.totalTokens, greaterThanOrEqualTo(kMinUsefulTokens));
    });

    test('a fallback that is also weak does not replace the original result', () async {
      // Two bad answers do not make a good one; swapping in an equally empty
      // result would only lose the reason the first mode was chosen.
      final outcome = await retrieve(
        corpus: corpus,
        query: 'what is xylophonic zzzzq',
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
      );
      expect(outcome.fellBack, isFalse);
      expect(outcome.result.mode, RetrievalMode.graph);
      expect(outcome.result.sources, ['index.md']);
      expect(outcome.decision.reason, 'heuristic:definitional');
      expect(outcome.decision.reason, isNot(contains('fallback')));
    });

    test('a fallback that comes back empty does not replace the original either', () async {
      final outcome = await retrieve(
        corpus: corpus,
        query: nonsense,
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
      );
      expect(outcome.fellBack, isFalse);
      expect(outcome.decision.reason, 'default');
      expect(outcome.result.mode, RetrievalMode.vector);
      expect(outcome.result.isEmpty, isTrue);
    });

    test('a strong route is returned as routed, with no fallback attempted', () async {
      embedOrthogonally();
      final outcome = await retrieve(
        corpus: corpus,
        query: 'what is the alpha concept document',
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
        queryVector: vectorFor(0),
      );
      expect(outcome.decision.reason, 'heuristic:title-match');
      expect(outcome.result.mode, RetrievalMode.graph);
      expect(outcome.fellBack, isFalse);
    });

    test('the router still decides the mode when no heuristic fires', () async {
      embedOrthogonally();
      final outcome = await retrieve(
        corpus: corpus,
        query: 'lodestar',
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
        queryVector: vectorFor(2),
        classify: (q) async => 'RAG',
      );
      expect(outcome.decision.reason, 'llm');
      expect(outcome.result.mode, RetrievalMode.vector);
      expect(outcome.fellBack, isFalse);
    });

    test('a budget too small for the fallback to be useful keeps the original', () async {
      // The same query falls back at a 4000-token budget; at 200 the walk can
      // only fit one concept, which is under kMinUsefulTokens and so is not an
      // improvement worth switching modes for.
      final outcome = await retrieve(
        corpus: corpus,
        query: titled,
        requested: RetrievalMode.auto,
        budgetTokens: 200,
      );
      expect(outcome.fellBack, isFalse);
      expect(outcome.result.mode, RetrievalMode.vector);
      expect(outcome.decision.reason, 'heuristic:synthesis');
    });
  });

  group('weakness signals', () {
    test('bestDense is null with no query vector and set with one', () async {
      // Null is not "nothing matched" — it is "no embedding model loaded", and
      // the fallback has to be able to tell those two apart.
      final noVector = await retrieve(
        corpus: corpus,
        query: titled,
        requested: RetrievalMode.vector,
        budgetTokens: 4000,
      );
      expect(noVector.result.bestDense, isNull);

      embedOrthogonally();
      final withVector = await retrieve(
        corpus: corpus,
        query: titled,
        requested: RetrievalMode.vector,
        budgetTokens: 4000,
        queryVector: vectorFor(0),
      );
      expect(withVector.result.bestDense, closeTo(1.0, 1e-12));
    });

    test('a low cosine marks a result weak even when BM25 scored well', () async {
      // Dense similarity is the better signal, so where it exists it decides;
      // a strong lexical score on the same query does not rescue it.
      embedOnOneAxis();
      final vectorOnly = await retrieve(
        corpus: corpus,
        query: titled,
        requested: RetrievalMode.vector,
        budgetTokens: 4000,
        queryVector: offAxisQuery,
      );
      expect(vectorOnly.result.bestLexical, greaterThanOrEqualTo(kMinLexicalScore));
      expect(vectorOnly.result.bestDense, lessThan(kMinDenseScore));

      final routed = await retrieve(
        corpus: corpus,
        query: titled,
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
        queryVector: offAxisQuery,
      );
      expect(routed.fellBack, isTrue, reason: 'the vector result should be judged weak');
      expect(routed.result.mode, RetrievalMode.graph);
    });

    test('with no embeddings a good BM25 score is not weak', () async {
      // Degraded mode is supported, not merely tolerated: before the embedding
      // pass has run the app must still answer from the lexical index instead
      // of thrashing into a fallback on every query.
      final outcome = await retrieve(
        corpus: corpus,
        query: 'lodestar',
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
      );
      expect(outcome.result.bestDense, isNull);
      expect(outcome.result.bestLexical, greaterThanOrEqualTo(kMinLexicalScore));
      expect(outcome.result.mode, RetrievalMode.vector);
      expect(outcome.fellBack, isFalse);
    });

    test('a query matching nothing is weak on the lexical signal', () async {
      final outcome = await retrieve(
        corpus: corpus,
        query: nonsense,
        requested: RetrievalMode.vector,
        budgetTokens: 4000,
      );
      expect(outcome.result.bestLexical, 0);
      expect(outcome.result.isEmpty, isTrue);
    });
  });

  group('toLogEntry', () {
    test('reports a fallback so a bad heuristic can be deleted on evidence', () async {
      embedOnOneAxis();
      final outcome = await retrieve(
        corpus: corpus,
        query: titled,
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
        queryVector: offAxisQuery,
      );
      final entry = outcome.toLogEntry(titled);
      expect(entry.fellBack, isTrue);
      expect(entry.chosenMode, 'graph');
      expect(entry.reason, 'heuristic:synthesis+fallback');
      expect(entry.query, titled);
      expect(entry.nResults, outcome.result.items.length);
      expect(entry.ctxTokens, outcome.result.totalTokens);
      expect(entry.userOverride, isNull);
    });

    test('reports no fallback when none happened, and carries the override', () async {
      final outcome = await retrieve(
        corpus: corpus,
        query: indexOnly,
        requested: RetrievalMode.graph,
        budgetTokens: 4000,
      );
      final entry = outcome.toLogEntry(indexOnly, userOverride: 'vector');
      expect(entry.fellBack, isFalse);
      expect(entry.chosenMode, 'graph');
      expect(entry.reason, 'manual');
      expect(entry.confidence, 1);
      expect(entry.userOverride, 'vector');
    });

    test('the logged mode is what actually ran, not what was routed', () async {
      // After a fallback these disagree, and the one worth logging is the one
      // whose results the user saw.
      embedOnOneAxis();
      final outcome = await retrieve(
        corpus: corpus,
        query: titled,
        requested: RetrievalMode.auto,
        budgetTokens: 4000,
        queryVector: offAxisQuery,
      );
      expect(outcome.fellBack, isTrue);
      expect(outcome.toLogEntry(titled).chosenMode, outcome.result.mode.name);
    });
  });
}
