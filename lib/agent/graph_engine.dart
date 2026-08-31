/// In-app graph orchestration.
///
/// Real graph execution — nodes, edges, cycles, shared state — running on the
/// device with no server and no dependencies. This is deliberately **not**
/// LangGraph and must never be named as such: no Dart LangGraph engine exists
/// (`langgraph_client` is an HTTP client for a hosted server, ~16 months
/// stale), so this is the app's own engine.
///
/// Carried over from `git_agent_app` and currently **unwired** — the Config
/// screen persists a preference for it and nothing reads that preference.
/// Kept because it is self-contained and tested; delete it if orchestration
/// does not land.
///
/// Cycles are the point, which is why every guardrail here is hard rather than
/// advisory: a step cap, a token budget, and a kill switch. A run always ends
/// with exactly one explicit [GraphOutcome] and a human-readable
/// [GraphRunResult.message] — never silently, never ambiguously.
library;

/// Shared mutable state threaded through a run.
///
/// A plain map: nodes read and write whatever they need, and it is returned in
/// [GraphRunResult.state]. Phase 5's running compact summary is just a key in
/// here (`state['summary']`) — the defence against quadratic context cost.
typedef GraphState = Map<String, Object?>;

/// What a node returns.
///
/// - [next]: the id of the node to run next, or `null` to finish the run.
///   Returning an already-visited id is legal — that is a cycle.
/// - [output]: whatever the node produced, surfaced per-step for the UI.
/// - [tokens]: tokens this step consumed. This is the caller's token-reporting
///   hook: nodes are caller-supplied, so the node that made the LLM call is the
///   only thing that knows the real cost. Report 0 for non-LLM steps.
typedef GraphNodeResult = ({String? next, Object? output, int tokens});

/// A unit of work in the graph. Async, operates on the shared [GraphState].
typedef GraphNode = Future<GraphNodeResult> Function(GraphState state);

/// How a run ended. Exactly one of these, always.
enum GraphOutcome {
  /// A node returned `next: null`.
  completed,

  /// The hard step cap was hit with more work still queued.
  stepCapReached,

  /// Cumulative tokens crossed the caller's budget.
  budgetExceeded,

  /// The caller's kill switch tripped.
  cancelled,

  /// A node threw, or an edge pointed at a node id that is not registered.
  nodeFailed,
}

/// One completed step, emitted as it happens so the UI can render progress.
class GraphStepRecord {
  const GraphStepRecord({
    required this.index,
    required this.nodeId,
    required this.output,
    required this.tokens,
    required this.cumulativeTokens,
  });

  /// 1-based position in the run.
  final int index;
  final String nodeId;
  final Object? output;

  /// Tokens this step consumed.
  final int tokens;

  /// Tokens consumed by this step and every step before it.
  final int cumulativeTokens;

  @override
  String toString() => 'step $index: $nodeId ($tokens tok, $cumulativeTokens total)';
}

/// The outcome of a run, including everything that happened on the way there.
class GraphRunResult {
  const GraphRunResult({
    required this.outcome,
    required this.steps,
    required this.state,
    required this.totalTokens,
    this.tokenBudget,
    this.error,
    this.stackTrace,
    this.failedNodeId,
  });

  final GraphOutcome outcome;

  /// Every step that ran, in order — including the step that tripped a limit,
  /// because it did happen and hiding it would be a fabricated signal.
  final List<GraphStepRecord> steps;

  /// The shared state as the run left it.
  final GraphState state;
  final int totalTokens;

  /// The budget this run was given, if any — reported so the message can say
  /// what was exceeded, not just by how much.
  final int? tokenBudget;

  /// Set only when [outcome] is [GraphOutcome.nodeFailed].
  final Object? error;
  final StackTrace? stackTrace;
  final String? failedNodeId;

  bool get isSuccess => outcome == GraphOutcome.completed;

  /// A plain-language explanation of how the run ended, distinct per outcome.
  /// Safe to show a user as-is.
  String get message => switch (outcome) {
    GraphOutcome.completed => 'Completed in ${steps.length} step(s), $totalTokens token(s).',
    GraphOutcome.stepCapReached =>
      'Stopped: hit the hard limit of ${steps.length} step(s) with work still pending.',
    GraphOutcome.budgetExceeded =>
      'Stopped: token budget of $tokenBudget exceeded — used $totalTokens token(s) '
          'in ${steps.length} step(s).',
    GraphOutcome.cancelled => 'Cancelled after ${steps.length} step(s), $totalTokens token(s).',
    GraphOutcome.nodeFailed => 'Failed at node "$failedNodeId": $error',
  };

  @override
  String toString() => 'GraphRunResult(${outcome.name}): $message';
}

/// Executes [nodes] starting at [start] until a node finishes the run or a
/// guardrail stops it.
///
/// - [maxSteps] is a **hard** cap (default 5, the agreed value): once that many
///   nodes have run the loop stops, even mid-graph.
/// - [tokenBudget] aborts the run as soon as cumulative reported tokens exceed
///   it. `null` means no budget.
/// - [isCancelled] is the kill switch, polled before each step and again after
///   each step returns. An in-flight node cannot be interrupted from here —
///   Dart futures are not cancellable — so a long node finishes, and the run
///   stops immediately afterwards. A node that wants to bail sooner can close
///   over the same flag.
/// - [onStep] receives each [GraphStepRecord] as the step completes.
///
/// Observability is a callback rather than a `Stream` on purpose: it fires
/// synchronously, in order, with no chance of a late subscriber missing the
/// first steps and no subscription to cancel — and the same records are
/// available in full afterwards via [GraphRunResult.steps]. A UI that wants a
/// stream can push these into its own `StreamController` in one line.
///
/// Never throws for a node failure: a throwing node comes back as
/// [GraphOutcome.nodeFailed] with the original [GraphRunResult.error] and
/// stack trace intact, so the caller still gets the steps that already ran.
Future<GraphRunResult> runGraph({
  required Map<String, GraphNode> nodes,
  required String start,
  GraphState? state,
  int maxSteps = 5,
  int? tokenBudget,
  bool Function()? isCancelled,
  void Function(GraphStepRecord step)? onStep,
}) async {
  final runState = state ?? <String, Object?>{};
  final steps = <GraphStepRecord>[];
  var totalTokens = 0;
  String? nextId = start;

  GraphRunResult finish(
    GraphOutcome outcome, {
    Object? error,
    StackTrace? stackTrace,
    String? failedNodeId,
  }) => GraphRunResult(
    outcome: outcome,
    steps: List.unmodifiable(steps),
    state: runState,
    totalTokens: totalTokens,
    tokenBudget: tokenBudget,
    error: error,
    stackTrace: stackTrace,
    failedNodeId: failedNodeId,
  );

  while (nextId != null) {
    if (isCancelled?.call() ?? false) return finish(GraphOutcome.cancelled);
    if (steps.length >= maxSteps) return finish(GraphOutcome.stepCapReached);

    final nodeId = nextId;
    final node = nodes[nodeId];
    if (node == null) {
      return finish(
        GraphOutcome.nodeFailed,
        error: StateError('No node registered for id "$nodeId".'),
        stackTrace: StackTrace.current,
        failedNodeId: nodeId,
      );
    }

    final GraphNodeResult result;
    try {
      result = await node(runState);
    } catch (error, stackTrace) {
      // Surfaced, never swallowed: the caller gets the original error, its
      // stack trace, the failing node, and every step that ran before it.
      return finish(
        GraphOutcome.nodeFailed,
        error: error,
        stackTrace: stackTrace,
        failedNodeId: nodeId,
      );
    }

    totalTokens += result.tokens;
    final record = GraphStepRecord(
      index: steps.length + 1,
      nodeId: nodeId,
      output: result.output,
      tokens: result.tokens,
      cumulativeTokens: totalTokens,
    );
    steps.add(record);
    onStep?.call(record);

    if (tokenBudget != null && totalTokens > tokenBudget) {
      return finish(GraphOutcome.budgetExceeded);
    }
    if (isCancelled?.call() ?? false) return finish(GraphOutcome.cancelled);

    nextId = result.next;
  }

  return finish(GraphOutcome.completed);
}
