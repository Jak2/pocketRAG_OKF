import 'package:flutter/material.dart';

import '../okf/concept.dart';
import '../theme/app_theme.dart';

/// One retrieved source, shown raw.
///
/// The point of citing a `source` path is that the user can go and check it.
/// A citation that cannot be opened is decoration, so every chip under an
/// answer lands here.
class SourceScreen extends StatelessWidget {
  final Concept concept;

  /// Opens another concept by bundle-relative path. Null disables link
  /// navigation, which is what happens when the corpus is not available.
  final void Function(String relpath)? onFollowLink;

  const SourceScreen({super.key, required this.concept, this.onFollowLink});

  @override
  Widget build(BuildContext context) {
    final metadata = <String, String>{
      if (concept.type != null) 'type': concept.type!,
      if (concept.description.isNotEmpty) 'description': concept.description,
      if (concept.tags.isNotEmpty) 'tags': concept.tags.join(', '),
    };
    final links = concept.resolvedLinks.toList();

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(concept.title, style: appHeading(size: 15), overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(concept.relpath, style: appMono(size: 10, color: AppColors.muted)),
          const SizedBox(height: 12),
          if (metadata.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in metadata.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('${entry.key}: ${entry.value}',
                          style: appMono(size: 11, color: AppColors.muted)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          // Raw markdown, not rendered: the whole reason to open a source is to
          // see exactly what the model was given.
          SelectableText(concept.body, style: appMono(size: 12)),
          if (links.isNotEmpty && onFollowLink != null) ...[
            const SizedBox(height: 24),
            Text('LINKS', style: appMono(size: 10, color: AppColors.muted)),
            const SizedBox(height: 8),
            for (final link in links)
              InkWell(
                onTap: () => onFollowLink!(link.targetPath!),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    link.anchor.isEmpty ? link.targetPath! : link.anchor,
                    style: appMono(size: 12).copyWith(decoration: TextDecoration.underline),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
