import 'package:flutter/material.dart';

import '../memory/memory_fact.dart';
import '../theme/app_theme.dart';

/// Every fact the app has stored about the user, editable and deletable.
///
/// Not optional. An agent that silently accumulates claims about a person and
/// offers no way to audit them is a bug, not a feature — so this screen ships
/// with the memory layer, not after it.
class MemoryScreen extends StatefulWidget {
  final MemoryStore store;
  const MemoryScreen({super.key, required this.store});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  bool _showInactive = false;

  Future<void> _edit(MemoryFact fact) async {
    final controller = TextEditingController(text: fact.text);
    // The controller outlives this frame but not the route, and disposing it
    // after the await races the close animation — DisposeWithRoute is the
    // house fix for exactly that red screen.
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => DisposeWithRoute(
        controllers: [controller],
        child: AlertDialog(
          backgroundColor: AppColors.bg,
          title: Text('Edit memory', style: appHeading(size: 15)),
          content: appBorderedField(controller: controller, hint: 'Fact', maxLines: 5),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel', style: appMono(size: 12, color: AppColors.muted)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Save', style: appMono(size: 12)),
            ),
          ],
        ),
      ),
    );
    if (saved ?? false) {
      await widget.store.update(fact.id, text: controller.text.trim());
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final facts = _showInactive ? widget.store.all : widget.store.active;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Memory', style: appHeading(size: 16)),
        actions: [
          TextButton(
            onPressed: () => setState(() => _showInactive = !_showInactive),
            child: Text(
              _showInactive ? 'Hide retired' : 'Show retired',
              style: appMono(size: 11, color: AppColors.muted),
            ),
          ),
        ],
      ),
      body: facts.isEmpty
          ? Center(
              child: Text(
                'Nothing remembered yet.',
                style: appMono(size: 12, color: AppColors.muted),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: facts.length,
              separatorBuilder: (_, _) => Divider(color: AppColors.divider, height: 20),
              itemBuilder: (_, i) {
                final fact = facts[i];
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fact.text,
                            style: appBody(
                              size: 13,
                              color: fact.active ? AppColors.fg : AppColors.muted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${fact.kind.name} · ${fact.hits} hit(s)'
                            '${fact.active ? '' : ' · retired'}',
                            style: appMono(size: 10, color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => _edit(fact),
                      icon: Icon(Icons.edit_outlined, size: 18, color: AppColors.muted),
                    ),
                    IconButton(
                      // Soft delete only: retiring a fact hides it from retrieval
                      // but leaves it visible here, so a wrong tap is recoverable.
                      onPressed: () async {
                        await widget.store.update(fact.id, active: !fact.active);
                        if (mounted) setState(() {});
                      },
                      icon: Icon(
                        fact.active ? Icons.delete_outline : Icons.restore,
                        size: 18,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
