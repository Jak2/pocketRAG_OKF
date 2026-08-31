import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/agent/graph_engine.dart';

/// A node that appends its id to state['trail'] and hands control to [next].
GraphNode trailNode(String id, String? next, {int tokens = 0}) {
  return (state) async {
    (state['trail'] as List<String>).add(id);
    return (next: next, output: 'out-$id', tokens: tokens);
  };
}

GraphState freshState() => <String, Object?>{'trail': <String>[]};

List<String> trailOf(GraphState state) => (state['trail'] as List<String>);

void main() {
  group('runGraph linear', () {
    test('runs two nodes in order and completes', () async {
      final result = await runGraph(
        nodes: {'a': trailNode('a', 'b'), 'b': trailNode('b', null)},
        start: 'a',
        state: freshState(),
      );

      expect(result.outcome, GraphOutcome.completed);
      expect(trailOf(result.state), ['a', 'b']);
      expect(result.steps.map((s) => s.nodeId), ['a', 'b']);
      expect(result.steps.map((s) => s.output), ['out-a', 'out-b']);
      expect(result.error, isNull);
      expect(result.message, isNotEmpty);
    });

    test('shared state carries accumulated results between nodes', () async {
      final result = await runGraph(
        nodes: {
          'plan': (state) async {
            state['summary'] = 'planned';
            return (next: 'act', output: null, tokens: 0);
          },
          'act': (state) async {
            state['summary'] = '${state['summary']}; acted';
            return (next: null, output: null, tokens: 0);
          },
        },
        start: 'plan',
      );

      expect(result.outcome, GraphOutcome.completed);
      expect(result.state['summary'], 'planned; acted');
    });

    test('an unknown start node fails explicitly instead of running nothing quietly', () async {
      final result = await runGraph(nodes: {'a': trailNode('a', null)}, start: 'nope');

      expect(result.outcome, GraphOutcome.nodeFailed);
      expect(result.steps, isEmpty);
      expect(result.error, isNotNull);
      expect(result.message, contains('nope'));
    });

    test('an unknown next id fails explicitly rather than ending as completed', () async {
      final result = await runGraph(
        nodes: {'a': trailNode('a', 'ghost')},
        start: 'a',
        state: freshState(),
      );

      expect(result.outcome, GraphOutcome.nodeFailed);
      expect(result.steps, hasLength(1));
      expect(result.message, contains('ghost'));
    });
  });

  group('runGraph step cap', () {
    test('a cyclic graph stops at exactly the default cap of 5', () async {
      var runs = 0;
      final result = await runGraph(
        nodes: {
          'loop': (state) async {
            runs++;
            return (next: 'loop', output: runs, tokens: 0);
          },
        },
        start: 'loop',
      );

      expect(result.outcome, GraphOutcome.stepCapReached);
      expect(runs, 5);
      expect(result.steps, hasLength(5));
      expect(result.message, contains('5'));
    });

    test('honours a caller-supplied cap', () async {
      var runs = 0;
      final result = await runGraph(
        nodes: {
          'loop': (state) async {
            runs++;
            return (next: 'loop', output: null, tokens: 0);
          },
        },
        start: 'loop',
        maxSteps: 2,
      );

      expect(result.outcome, GraphOutcome.stepCapReached);
      expect(runs, 2);
      expect(result.steps, hasLength(2));
    });

    test('a graph that finishes on the final allowed step completes, not capped', () async {
      final result = await runGraph(
        nodes: {'a': trailNode('a', 'b'), 'b': trailNode('b', null)},
        start: 'a',
        state: freshState(),
        maxSteps: 2,
      );

      expect(result.outcome, GraphOutcome.completed);
      expect(result.steps, hasLength(2));
    });
  });

  group('runGraph token budget', () {
    test('exceeding the budget aborts mid-run', () async {
      var runs = 0;
      final result = await runGraph(
        nodes: {
          'loop': (state) async {
            runs++;
            return (next: 'loop', output: null, tokens: 40);
          },
        },
        start: 'loop',
        tokenBudget: 100,
      );

      expect(result.outcome, GraphOutcome.budgetExceeded);
      expect(runs, 3, reason: 'stops on the step that crosses 100, not before');
      expect(result.totalTokens, 120);
      expect(result.message, contains('100'));
    });

    test('a run that stays inside the budget completes normally', () async {
      final result = await runGraph(
        nodes: {'a': trailNode('a', 'b', tokens: 10), 'b': trailNode('b', null, tokens: 10)},
        start: 'a',
        state: freshState(),
        tokenBudget: 100,
      );

      expect(result.outcome, GraphOutcome.completed);
      expect(result.totalTokens, 20);
    });
  });

  group('runGraph cancellation', () {
    test('a cancelled run stops and reports cancellation', () async {
      var cancelled = false;
      var runs = 0;
      final result = await runGraph(
        nodes: {
          'loop': (state) async {
            runs++;
            if (runs == 2) cancelled = true;
            return (next: 'loop', output: null, tokens: 0);
          },
        },
        start: 'loop',
        isCancelled: () => cancelled,
      );

      expect(result.outcome, GraphOutcome.cancelled);
      expect(runs, 2);
      expect(result.steps, hasLength(2), reason: 'work already done is still reported');
    });

    test('cancelling before the first step runs nothing', () async {
      var runs = 0;
      final result = await runGraph(
        nodes: {
          'a': (state) async {
            runs++;
            return (next: null, output: null, tokens: 0);
          },
        },
        start: 'a',
        isCancelled: () => true,
      );

      expect(result.outcome, GraphOutcome.cancelled);
      expect(runs, 0);
      expect(result.steps, isEmpty);
    });
  });

  group('runGraph node failure', () {
    test('a throwing node is surfaced, not swallowed', () async {
      final boom = StateError('node blew up');
      final result = await runGraph(
        nodes: {
          'a': trailNode('a', 'b'),
          'b': (state) async => throw boom,
        },
        start: 'a',
        state: freshState(),
      );

      expect(result.outcome, GraphOutcome.nodeFailed);
      expect(result.error, same(boom));
      expect(result.stackTrace, isNotNull);
      expect(result.failedNodeId, 'b');
      expect(result.steps.map((s) => s.nodeId), ['a'], reason: 'work before the failure is kept');
      expect(result.message, contains('b'));
      expect(result.message, contains('node blew up'));
    });
  });

  group('runGraph observability', () {
    test('emits one record per step, in order, with cumulative tokens', () async {
      final seen = <GraphStepRecord>[];
      final result = await runGraph(
        nodes: {
          'a': trailNode('a', 'b', tokens: 5),
          'b': trailNode('b', 'c', tokens: 7),
          'c': trailNode('c', null, tokens: 3),
        },
        start: 'a',
        state: freshState(),
        onStep: seen.add,
      );

      expect(seen.map((s) => s.nodeId), ['a', 'b', 'c']);
      expect(seen.map((s) => s.index), [1, 2, 3]);
      expect(seen.map((s) => s.tokens), [5, 7, 3]);
      expect(seen.map((s) => s.cumulativeTokens), [5, 12, 15]);
      expect(seen.map((s) => s.output), ['out-a', 'out-b', 'out-c']);
      expect(result.totalTokens, 15);
      expect(seen, equals(result.steps));
    });

    test('the aborting step is still emitted before the run ends', () async {
      final seen = <GraphStepRecord>[];
      await runGraph(
        nodes: {
          'loop': (state) async => (next: 'loop', output: null, tokens: 60),
        },
        start: 'loop',
        tokenBudget: 50,
        onStep: seen.add,
      );

      expect(seen, hasLength(1));
      expect(seen.single.cumulativeTokens, 60);
    });

    test('every outcome reports a non-empty message', () async {
      final messages = <String>[];
      messages.add((await runGraph(nodes: {'a': trailNode('a', null)}, start: 'a', state: freshState())).message);
      messages.add((await runGraph(nodes: {'a': trailNode('a', 'a')}, start: 'a', state: freshState())).message);
      messages.add(
        (await runGraph(
          nodes: {'a': trailNode('a', 'a', tokens: 9)},
          start: 'a',
          state: freshState(),
          tokenBudget: 1,
        )).message,
      );
      messages.add(
        (await runGraph(
          nodes: {'a': trailNode('a', 'a')},
          start: 'a',
          state: freshState(),
          isCancelled: () => true,
        )).message,
      );
      messages.add(
        (await runGraph(
          nodes: {'a': (state) async => throw StateError('x')},
          start: 'a',
        )).message,
      );

      expect(messages, hasLength(5));
      expect(messages.every((m) => m.trim().isNotEmpty), isTrue);
      expect(messages.toSet(), hasLength(5), reason: 'outcomes must be distinguishable');
    });
  });
}
