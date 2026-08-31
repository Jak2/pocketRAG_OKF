import 'dart:convert';
import 'dart:io';

/// One routing decision, recorded on device and never sent anywhere.
///
/// This log is the entire justification for building AUTO at all. After a
/// couple of hundred real queries, [fellBack] and [userOverride] say which
/// heuristics earn their place — tune from this, not from guesses.
class RouteLogEntry {
  final int ts;
  final String query;
  final String chosenMode;
  final String reason;
  final double confidence;
  final bool fellBack;
  final int nResults;
  final int ctxTokens;
  final int latencyMs;

  /// Set when the user hits "wrong mode, retry as X" on the answer.
  final String? userOverride;

  const RouteLogEntry({
    required this.ts,
    required this.query,
    required this.chosenMode,
    required this.reason,
    required this.confidence,
    required this.fellBack,
    required this.nResults,
    required this.ctxTokens,
    required this.latencyMs,
    this.userOverride,
  });

  Map<String, Object?> toJson() => {
        'ts': ts,
        'query': query,
        'chosen_mode': chosenMode,
        'reason': reason,
        'confidence': confidence,
        'fell_back': fellBack,
        'n_results': nResults,
        'ctx_tokens': ctxTokens,
        'latency_ms': latencyMs,
        'user_override': userOverride,
      };

  factory RouteLogEntry.fromJson(Map<String, Object?> j) => RouteLogEntry(
        ts: j['ts'] as int? ?? 0,
        query: j['query'] as String? ?? '',
        chosenMode: j['chosen_mode'] as String? ?? '',
        reason: j['reason'] as String? ?? '',
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0,
        fellBack: j['fell_back'] as bool? ?? false,
        nResults: j['n_results'] as int? ?? 0,
        ctxTokens: j['ctx_tokens'] as int? ?? 0,
        latencyMs: j['latency_ms'] as int? ?? 0,
        userOverride: j['user_override'] as String?,
      );
}

/// Append-only JSON-lines log.
///
/// ponytail: JSONL rather than a SQLite table. It is written once per query,
/// read only when tuning, and appending a line costs no schema and no
/// migration. Move to sqflite if this ever needs aggregate queries the phone
/// cannot do by reading the file.
class RouteLog {
  final File file;
  RouteLog(this.file);

  Future<void> append(RouteLogEntry entry) async {
    await file.parent.create(recursive: true);
    await file.writeAsString('${jsonEncode(entry.toJson())}\n', mode: FileMode.append);
  }

  Future<List<RouteLogEntry>> readAll() async {
    if (!await file.exists()) return const [];
    return file
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) {
          try {
            return RouteLogEntry.fromJson(jsonDecode(l) as Map<String, Object?>);
          } catch (_) {
            return null;
          }
        })
        .whereType<RouteLogEntry>()
        .toList();
  }
}
