import 'retrieval_result.dart';
import 'tokens.dart';

/// Tokens held back for the model's own reply. Retrieval is never allowed to
/// eat the whole window — a perfectly retrieved context with no room to answer
/// is still a failed turn.
const int kReserveOutput = 512;

/// Ceiling on how much of the window conversation history may take.
const double kHistoryShare = 0.20;

/// Share of a VECTOR-mode budget held for memory facts, so a strong topical
/// match can never crowd out everything the app knows about the user.
const double kMemoryShare = 0.15;

/// How many tokens retrieval may spend this turn.
int retrievalBudget({
  required int contextTokens,
  required String systemPrompt,
  required List<String> history,
}) {
  final systemCost = estimateTokens(systemPrompt);
  final historyCap = (contextTokens * kHistoryShare).floor();
  final historyCost = history.fold(0, (sum, h) => sum + estimateTokens(h));
  final budget = contextTokens - kReserveOutput - systemCost - (historyCost < historyCap ? historyCost : historyCap);
  return budget < 0 ? 0 : budget;
}

/// Renders retrieved content with its provenance.
///
/// The `source` attribute is not decoration: on an offline app with a small
/// model, citation is the main defence against confabulation, and it turns bad
/// retrieval from invisible into obvious.
String renderContext(RetrievalResult result) {
  final buffer = StringBuffer();
  for (final item in result.items) {
    buffer.writeln('<context source="${item.source}"'
        '${item.type == null ? '' : ' type="${item.type}"'}'
        ' mode="${result.mode == RetrievalMode.graph ? 'okf' : 'rag'}">');
    buffer.writeln(item.text.trim());
    buffer.writeln('</context>');
  }
  return buffer.toString();
}

/// Splits a vector-mode result so memory keeps its reserved share.
///
/// Knowledge items fill the larger share; memory items fill theirs. Whichever
/// side does not use its full allowance releases it to the other, so the
/// reservation costs nothing when there is no memory to show.
RetrievalResult applyMemoryShare(RetrievalResult result, int budgetTokens) {
  if (result.mode != RetrievalMode.vector) return result;

  final memory = result.items.where((i) => i.source.startsWith('memory:')).toList();
  final knowledge = result.items.where((i) => !i.source.startsWith('memory:')).toList();
  if (memory.isEmpty || knowledge.isEmpty) return result;

  final memoryBudget = (budgetTokens * kMemoryShare).floor();
  final kept = <RetrievedItem>[];

  var memoryUsed = 0;
  for (final item in memory) {
    if (memoryUsed + item.nTokens > memoryBudget) break;
    kept.add(item);
    memoryUsed += item.nTokens;
  }

  var used = memoryUsed;
  for (final item in knowledge) {
    if (used + item.nTokens > budgetTokens) continue;
    kept.add(item);
    used += item.nTokens;
  }

  // Restore the fused ranking; the split above reorders by category.
  kept.sort((a, b) => b.score.compareTo(a.score));
  // The weakness signals describe the retrieval, not the surviving subset, so
  // they are carried through. Dropping them resets bestLexical to 0 and marks
  // every mixed memory+knowledge result weak, firing a fallback on a result
  // that matched perfectly well.
  return RetrievalResult(
    mode: result.mode,
    items: kept,
    seeds: result.seeds,
    bestLexical: result.bestLexical,
    bestDense: result.bestDense,
  );
}

const String kSystemPrompt = '''
You answer questions using only the <context> blocks provided below.
Cite the `source` attribute of every block you use, inline, like [source: path/to/file.md].
If the context does not contain the answer, say so plainly. Do not invent sources.''';

/// Assembles the final prompt: system rules, retrieved context, recent turns,
/// then the question.
String buildPrompt({
  required String question,
  required RetrievalResult retrieved,
  required List<String> history,
  required int contextTokens,
  String systemPrompt = kSystemPrompt,
}) {
  final historyCap = (contextTokens * kHistoryShare).floor();
  final kept = <String>[];
  var used = 0;
  for (final line in history.reversed) {
    final cost = estimateTokens(line);
    if (used + cost > historyCap) break;
    kept.insert(0, line);
    used += cost;
  }

  final buffer = StringBuffer()
    ..writeln(systemPrompt)
    ..writeln();
  if (!retrieved.isEmpty) {
    buffer
      ..writeln(renderContext(retrieved))
      ..writeln();
  }
  if (kept.isNotEmpty) {
    buffer.writeln('Conversation so far:');
    if (kept.length < history.length) {
      buffer.writeln('[${history.length - kept.length} earlier message(s) omitted to fit]');
    }
    for (final line in kept) {
      buffer.writeln(line);
    }
    buffer.writeln();
  }
  buffer
    ..writeln('User: $question')
    ..write('Assistant:');
  return buffer.toString();
}
