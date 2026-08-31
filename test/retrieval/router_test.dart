// test/retrieval/router_test.dart
//
// The reason string, not the mode, is what makes these heuristics tunable: two
// queries can both route to graph for completely different reasons and only one
// of them may be worth keeping. So every table row asserts the reason.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/okf/bundle.dart';
import 'package:pocket_rag_okf/okf/concept.dart';
import 'package:pocket_rag_okf/retrieval/retrieval_result.dart';
import 'package:pocket_rag_okf/retrieval/router.dart';

/// A bundle built in code — the router only ever reads titles and types, and a
/// real directory would add nothing but IO.
final _bundle = Bundle(
  id: 'test',
  root: Directory('/nonexistent'),
  contentHash: '',
  concepts: const [
    Concept(relpath: 'index.md', title: 'index', body: ''),
    Concept(
        relpath: 'metrics/daily-active-users.md',
        title: 'Daily Active Users',
        type: 'metric',
        body: ''),
    Concept(
        relpath: 'runbooks/rotate-keys.md', title: 'Rotate Signing Keys', type: 'runbook', body: ''),
  ],
);

/// 26 words: one past kLongQueryWords, and deliberately opening with a
/// definitional phrase so the precedence is visible.
final _longQuery = 'what is ${List.filled(24, 'thing').join(' ')}';

/// Exactly 25 words with no other signal in them at all.
final _borderlineQuery = List.filled(25, 'zebra').join(' ');

typedef _Row = ({String label, String query, RetrievalMode? mode, String? reason});

const _vector = RetrievalMode.vector;
const _graph = RetrievalMode.graph;

final List<_Row> _table = [
  // Long queries — a natural-language description, however it opens.
  (label: 'long query beats a definitional opener', query: _longQuery, mode: _vector, reason: 'heuristic:long-query'),
  (label: 'long rambling description', query: 'i keep ${List.filled(30, 'wondering').join(' ')}', mode: _vector, reason: 'heuristic:long-query'),

  // Synthesis / recall — the wrong job for whole structured documents.
  (label: 'summarise (en-GB)', query: 'summarise what i know about churn', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'summarize (en-US)', query: 'summarize my notes on pricing', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'feelings', query: 'how do i feel about the migration', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'remind me', query: 'remind me what we decided last month', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'did i ever', query: 'did i ever write about caching', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'anything about', query: 'anything about postgres tuning', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'something about', query: 'something about latency spikes', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'my thoughts', query: 'my thoughts on the vendor', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'brainstorm', query: 'brainstorm names for the service', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'ideas for', query: 'ideas for the next sprint', mode: _vector, reason: 'heuristic:synthesis'),
  (label: 'synthesis outranks an exact title', query: 'summarise daily active users', mode: _vector, reason: 'heuristic:synthesis'),

  // Exact concept titles — the strongest signal in the corpus.
  (label: 'title inside a question', query: 'how is daily active users computed', mode: _graph, reason: 'heuristic:title-match'),
  (label: 'title outranks a definitional opener', query: 'what is daily active users', mode: _graph, reason: 'heuristic:title-match'),
  (label: 'title outranks a relational phrase', query: 'rotate signing keys steps to follow', mode: _graph, reason: 'heuristic:title-match'),

  // Definitional openers — only at the start of the query.
  (label: 'what is', query: 'what is churn', mode: _graph, reason: 'heuristic:definitional'),
  (label: "what's", query: "what's a cohort", mode: _graph, reason: 'heuristic:definitional'),
  (label: 'what are', query: 'what are the pricing tiers', mode: _graph, reason: 'heuristic:definitional'),
  (label: 'define', query: 'define retention', mode: _graph, reason: 'heuristic:definitional'),
  (label: 'definition of', query: 'definition of arpu', mode: _graph, reason: 'heuristic:definitional'),
  (label: 'meaning of', query: 'meaning of stickiness', mode: _graph, reason: 'heuristic:definitional'),
  (label: 'explain the', query: 'explain the onboarding funnel', mode: _graph, reason: 'heuristic:definitional'),

  // Relational wording — needs the link graph, not nearest neighbours.
  (label: 'depends on', query: 'billing depends on invoicing', mode: _graph, reason: 'heuristic:relational'),
  (label: 'dependency', query: 'dependency chain for auth', mode: _graph, reason: 'heuristic:relational'),
  (label: 'upstream', query: 'upstream of the ingest job', mode: _graph, reason: 'heuristic:relational'),
  (label: 'downstream', query: 'downstream consumers of events', mode: _graph, reason: 'heuristic:relational'),
  (label: 'related to', query: 'is churn related to pricing', mode: _graph, reason: 'heuristic:relational'),
  (label: 'compare', query: 'compare the pricing tiers', mode: _graph, reason: 'heuristic:relational'),
  (label: 'difference between', query: 'difference between arpu and arr', mode: _graph, reason: 'heuristic:relational'),
  (label: 'across', query: 'signups across regions', mode: _graph, reason: 'heuristic:relational'),
  (label: 'connected to', query: 'services connected to billing', mode: _graph, reason: 'heuristic:relational'),
  (label: 'linked to', query: 'pages linked to onboarding', mode: _graph, reason: 'heuristic:relational'),
  (label: 'how does', query: 'how does the ingest pipeline work', mode: _graph, reason: 'heuristic:relational'),
  (label: 'steps to', query: 'steps to revoke a token', mode: _graph, reason: 'heuristic:relational'),

  // Structural nouns, taken from the corpus's own type vocabulary.
  (label: 'corpus type: runbook', query: 'find the runbook for outages', mode: _graph, reason: 'heuristic:type-noun'),
  (label: 'corpus type: metric', query: 'which metric matters most', mode: _graph, reason: 'heuristic:type-noun'),

  // No opinion — these must reach the next routing stage, not be guessed at.
  (label: 'bare noun', query: 'pricing', mode: null, reason: null),
  (label: 'conversational', query: 'tell me about the billing service', mode: null, reason: null),
  (label: 'imperative with no signal', query: 'show me last quarter numbers', mode: null, reason: null),
  (label: 'exactly 25 words', query: _borderlineQuery, mode: null, reason: null),
  (label: 'empty', query: '', mode: null, reason: null),
  (label: 'whitespace only', query: '   \t\n ', mode: null, reason: null),
];

void main() {
  group('heuristicRoute', () {
    for (final row in _table) {
      test(row.label, () {
        final decision = heuristicRoute(query: row.query, bundle: _bundle);
        if (row.reason == null) {
          expect(decision, isNull, reason: 'query: "${row.query}"');
        } else {
          expect(decision, isNotNull, reason: 'query: "${row.query}"');
          expect(decision!.reason, row.reason, reason: 'query: "${row.query}"');
          expect(decision.mode, row.mode, reason: 'query: "${row.query}"');
        }
      });
    }

    test('the table covers every reason the heuristics can emit', () {
      final covered = _table.map((r) => r.reason).whereType<String>().toSet();
      expect(covered, {
        'heuristic:long-query',
        'heuristic:synthesis',
        'heuristic:title-match',
        'heuristic:definitional',
        'heuristic:relational',
        'heuristic:type-noun',
      });
    });

    test('confidence falls as the signal weakens', () {
      double conf(String q) => heuristicRoute(query: q, bundle: _bundle)!.confidence;
      expect(conf('what is daily active users'), 0.95); // exact title
      expect(conf('what is churn'), 0.8); // definitional
      expect(conf('summarise this'), 0.75);
      expect(conf('compare tiers'), 0.75); // relational
      expect(conf('the runbook please'), 0.7); // type noun
    });

    test('a short generic title never matches — it would fire on every question', () {
      // 'index' is 5 characters and one word; matching it would route half the
      // corpus's questions to graph mode for no reason.
      expect(heuristicRoute(query: 'rebuild the index today', bundle: _bundle), isNull);
    });

    test('a type not present in the corpus is not a structural noun', () {
      expect(heuristicRoute(query: 'the changelog please', bundle: _bundle), isNull);
    });

    test('an empty bundle still routes on wording alone', () {
      final empty = Bundle(id: 'e', root: Directory('/nonexistent'), concepts: const [], contentHash: '');
      expect(heuristicRoute(query: 'what is churn', bundle: empty)?.reason, 'heuristic:definitional');
      expect(heuristicRoute(query: 'pricing', bundle: empty), isNull);
    });
  });

  group('routeQuery cascade', () {
    test('a firing heuristic short-circuits before the LLM is ever asked', () {
      var called = false;
      return routeQuery(
        query: 'what is churn',
        bundle: _bundle,
        classify: (q) async {
          called = true;
          return 'RAG';
        },
      ).then((decision) {
        expect(decision.reason, 'heuristic:definitional');
        expect(called, isFalse);
      });
    });

    test('a heuristic also short-circuits a memory hit', () {
      return routeQuery(query: 'what is churn', bundle: _bundle, memoryHit: true).then((d) {
        expect(d.reason, 'heuristic:definitional');
      });
    });

    test('a memory hit shortcuts to vector when no heuristic fires', () async {
      final decision = await routeQuery(query: 'pricing', bundle: _bundle, memoryHit: true);
      expect(decision.reason, 'memory-hit');
      expect(decision.mode, RetrievalMode.vector);
      expect(decision.confidence, 0.7);
    });

    test('a memory hit is preferred over the LLM stage', () async {
      var called = false;
      final decision = await routeQuery(
        query: 'pricing',
        bundle: _bundle,
        memoryHit: true,
        classify: (q) async {
          called = true;
          return 'OKF';
        },
      );
      expect(decision.reason, 'memory-hit');
      expect(called, isFalse);
    });

    test('the LLM answering OKF routes to graph', () async {
      final decision = await routeQuery(query: 'pricing', bundle: _bundle, classify: (q) async => 'OKF');
      expect(decision.mode, RetrievalMode.graph);
      expect(decision.reason, 'llm');
      expect(decision.confidence, 0.6);
    });

    test('the LLM answering RAG routes to vector', () async {
      final decision = await routeQuery(query: 'pricing', bundle: _bundle, classify: (q) async => 'RAG');
      expect(decision.mode, RetrievalMode.vector);
      expect(decision.reason, 'llm');
    });

    test('the LLM reply is parsed leniently for case and stray tokens', () async {
      for (final reply in ['okf', ' OKF ', 'OKF.', 'okf — graph mode']) {
        final decision = await routeQuery(query: 'pricing', bundle: _bundle, classify: (q) async => reply);
        expect(decision.reason, 'llm', reason: 'reply: "$reply"');
        expect(decision.mode, RetrievalMode.graph, reason: 'reply: "$reply"');
      }
    });

    test('an LLM stage that never answers falls through to the default', () async {
      // A router slower than the retrieval it routes is a failed design, so the
      // timeout must not be waited out — the default answer is already good.
      final stuck = Completer<String?>();
      addTearDown(() => stuck.complete(null));

      final decision = await routeQuery(
        query: 'pricing',
        bundle: _bundle,
        classify: (q) => stuck.future,
        classifyTimeout: const Duration(milliseconds: 20),
      );
      expect(decision.reason, 'default');
      expect(decision.mode, RetrievalMode.vector);
      expect(decision.confidence, 0.3);
    });

    test('an LLM stage that throws falls through to the default', () async {
      final decision = await routeQuery(
        query: 'pricing',
        bundle: _bundle,
        classify: (q) async => throw StateError('model not loaded'),
      );
      expect(decision.reason, 'default');
    });

    test('an unparseable LLM reply falls through to the default', () async {
      for (final reply in ['maybe both?', '', 'GRAPH', null]) {
        final decision = await routeQuery(query: 'pricing', bundle: _bundle, classify: (q) async => reply);
        expect(decision.reason, 'default', reason: 'reply: "$reply"');
        expect(decision.mode, RetrievalMode.vector);
        expect(decision.confidence, 0.3);
      }
    });

    test('with no classifier at all the default is vector', () async {
      final decision = await routeQuery(query: 'pricing', bundle: _bundle);
      expect(decision.reason, 'default');
      expect(decision.mode, RetrievalMode.vector);
    });

    test('every decision carries a latency, including the free heuristic path', () async {
      final heuristic = await routeQuery(query: 'what is churn', bundle: _bundle);
      expect(heuristic.latencyMs, greaterThanOrEqualTo(0));
      final llm = await routeQuery(query: 'pricing', bundle: _bundle, classify: (q) async => 'OKF');
      expect(llm.latencyMs, greaterThanOrEqualTo(0));
    });
  });

  group('RouteDecision', () {
    test('withFallback flips the mode and records why in the reason', () {
      const decision = RouteDecision(
          mode: RetrievalMode.graph, confidence: 0.8, reason: 'heuristic:definitional', latencyMs: 7);
      final flipped = decision.withFallback();
      expect(flipped.mode, RetrievalMode.vector);
      expect(flipped.reason, 'heuristic:definitional+fallback');
      expect(flipped.confidence, 0.8);
      expect(flipped.latencyMs, 7);
    });

    test('withFallback flips the other way too', () {
      const decision = RouteDecision(mode: RetrievalMode.vector, confidence: 0.3, reason: 'default');
      expect(decision.withFallback().mode, RetrievalMode.graph);
      expect(decision.withFallback().reason, 'default+fallback');
    });

    test('withLatency leaves the decision itself untouched', () {
      const decision = RouteDecision(mode: RetrievalMode.graph, confidence: 0.6, reason: 'llm');
      final timed = decision.withLatency(42);
      expect(timed.latencyMs, 42);
      expect(timed.mode, RetrievalMode.graph);
      expect(timed.reason, 'llm');
    });
  });

  group('classifierPromptFor', () {
    test('substitutes the query and keeps the one-word instruction intact', () {
      final prompt = classifierPromptFor('what is churn');
      expect(prompt, contains('Question: what is churn'));
      expect(prompt, contains('exactly one word: RAG or OKF'));
      expect(prompt, isNot(contains('{query}')));
    });
  });

  group('RetrievalModeLabel', () {
    test('labels are the ones the mode switch shows', () {
      expect(RetrievalMode.vector.label, 'RAG');
      expect(RetrievalMode.graph.label, 'OKF');
      expect(RetrievalMode.auto.label, 'Auto');
    });
  });
}
