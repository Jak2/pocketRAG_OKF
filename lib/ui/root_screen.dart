import 'package:flutter/material.dart';

import '../retrieval/knowledge_service.dart';
import '../memory/memory_fact.dart';
import '../retrieval/route_log.dart';
import '../secrets/secret_store.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import 'config_screen.dart';
import 'memory_screen.dart';
import 'route_log_screen.dart';

class RootScreen extends StatefulWidget {
  final SecretStore secretStore;
  const RootScreen({super.key, required this.secretStore});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tabIndex = 0;

  /// One service for the whole app: the corpus and its embeddings are the
  /// largest thing in memory, and a second copy would double it.
  final _knowledge = KnowledgeService();

  String? _lastIndexedLabel;
  String _indexProgress = '';
  double? _indexFraction;

  /// Incremented on leaving Config so the chat screen re-reads settings. The
  /// tabs are an IndexedStack, so nothing else tells it a path changed.
  int _configRevision = 0;

  @override
  void dispose() {
    _knowledge.dispose();
    super.dispose();
  }

  /// Leaving Config bumps the revision, which is what makes a newly picked
  /// bundle or embedding model take effect without an app restart.
  void _switchTab(int index) {
    setState(() {
      if (_tabIndex == 1 && index != 1) _configRevision++;
      _tabIndex = index;
    });
  }

  Future<void> _reindex() async {
    setState(() {
      _indexProgress = 'starting…';
      _indexFraction = 0;
    });
    await _knowledge.reindex(
      onProgress: (done, total, stage) {
        if (mounted) {
          setState(() {
            _indexProgress = '$stage $done/$total';
            _indexFraction = total == 0 ? null : done / total;
          });
        }
      },
    );
    if (mounted) {
      setState(() {
        _indexProgress = '';
        _indexFraction = null;
        _lastIndexedLabel = DateTime.now().toString().split('.').first;
      });
    }
  }

  /// Stops an indexing pass. The service checks the flag between chunks, so
  /// the bar keeps its last position until the current chunk finishes.
  void _cancelIndex() {
    _knowledge.cancelIndexing();
    if (mounted) setState(() => _indexProgress = 'cancelling…');
  }

  void _openMemory(MemoryStore store) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MemoryScreen(store: store)),
    );
  }

  void _openRouteLog(RouteLog log) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RouteLogScreen(log: log)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final memory = _knowledge.memory;
    final routeLog = _knowledge.routeLog;

    final tabs = [
      ChatScreen(
        secretStore: widget.secretStore,
        knowledge: _knowledge,
        configRevision: _configRevision,
        onOpenConfig: () => _switchTab(1),
        onOpenMemory: memory == null ? null : () => _openMemory(memory),
      ),
      ConfigScreen(
        secretStore: widget.secretStore,
        onReindex: _reindex,
        lastIndexedLabel: _indexProgress.isNotEmpty ? _indexProgress : _lastIndexedLabel,
        indexFraction: _indexFraction,
        onCancelIndex: _indexFraction == null ? null : _cancelIndex,
        onOpenRouteLog: routeLog == null ? null : () => _openRouteLog(routeLog),
      ),
    ];
    final navItems = [
      (icon: Icons.chat_bubble_outline, label: 'Chat'),
      (icon: Icons.tune, label: 'Config'),
    ];

    return Scaffold(
      body: IndexedStack(index: _tabIndex, children: tabs),
      bottomNavigationBar: Container(
        // Hairline, not the old 2px rule — the design has no heavy borders.
        decoration: BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              for (var i = 0; i < navItems.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => _switchTab(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(navItems[i].icon,
                              size: 21, color: _tabIndex == i ? AppColors.fg : AppColors.muted),
                          const SizedBox(height: 4),
                          Text(navItems[i].label,
                              style: appMono(
                                  size: 10, color: _tabIndex == i ? AppColors.fg : AppColors.muted)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
