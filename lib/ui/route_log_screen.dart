import 'package:flutter/material.dart';

import '../retrieval/route_log.dart';
import '../theme/app_theme.dart';

/// Every routing decision the app has made, on device.
///
/// This screen is the justification for AUTO existing at all. The fallback and
/// override columns are what say which heuristics in `router.dart` earn their
/// place — and if the answer turns out to be "none of them", deleting AUTO is
/// a good outcome rather than a failure.
class RouteLogScreen extends StatefulWidget {
  final RouteLog log;
  const RouteLogScreen({super.key, required this.log});

  @override
  State<RouteLogScreen> createState() => _RouteLogScreenState();
}

class _RouteLogScreenState extends State<RouteLogScreen> {
  List<RouteLogEntry>? _entries;

  @override
  void initState() {
    super.initState();
    widget.log.readAll().then((entries) {
      if (mounted) setState(() => _entries = entries.reversed.toList());
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Routing log', style: appHeading(size: 16)),
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
              ? Center(
                  child: Text('No queries logged yet.',
                      style: appMono(size: 12, color: AppColors.muted)),
                )
              : Column(children: [
                  _summary(entries),
                  Divider(color: AppColors.divider, height: 1),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) =>
                          Divider(color: AppColors.divider, height: 16),
                      itemBuilder: (_, i) => _row(entries[i]),
                    ),
                  ),
                ]),
    );
  }

  /// The three numbers worth tuning from. A high fallback rate for one reason
  /// is the signal to delete that heuristic.
  Widget _summary(List<RouteLogEntry> entries) {
    final fellBack = entries.where((e) => e.fellBack).length;
    final overridden = entries.where((e) => e.userOverride != null).length;

    String percent(int n) =>
        entries.isEmpty ? '—' : '${(100 * n / entries.length).toStringAsFixed(0)}%';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        _stat('queries', '${entries.length}'),
        _stat('fell back', percent(fellBack)),
        _stat('overridden', percent(overridden)),
      ]),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: appHeading(size: 20)),
          const SizedBox(height: 2),
          Text(label, style: appMono(size: 10, color: AppColors.muted)),
        ]),
      );

  Widget _row(RouteLogEntry entry) {
    final when = DateTime.fromMillisecondsSinceEpoch(entry.ts);
    final stamp = '${when.year}-${_two(when.month)}-${_two(when.day)} '
        '${_two(when.hour)}:${_two(when.minute)}';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(entry.chosenMode.toUpperCase(), style: appMono(size: 11)),
        const SizedBox(width: 8),
        if (entry.fellBack)
          Text('fallback ', style: appMono(size: 10, color: AppColors.muted)),
        if (entry.userOverride != null)
          Text('override→${entry.userOverride} ',
              style: appMono(size: 10, color: AppColors.muted)),
        const Spacer(),
        Text(stamp, style: appMono(size: 10, color: AppColors.muted)),
      ]),
      const SizedBox(height: 4),
      Text(entry.query, style: appBody(size: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
      const SizedBox(height: 4),
      Text(
        '${entry.reason} · conf ${entry.confidence.toStringAsFixed(2)} · '
        '${entry.latencyMs}ms · ${entry.nResults} items · ${entry.ctxTokens} tokens',
        style: appMono(size: 10, color: AppColors.muted),
      ),
    ]);
  }

  String _two(int n) => n.toString().padLeft(2, '0');
}
