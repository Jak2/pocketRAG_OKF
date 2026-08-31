/// One OKF concept file, parsed.
///
/// OKF is a *file format* — markdown + YAML frontmatter, cross-linked with
/// ordinary markdown links. It ships no runtime and no index. Everything in
/// `lib/okf/` and `lib/retrieval/` is this app's own consumer of that format.
library;

/// A markdown link found in a concept body, resolved against the bundle root
/// where possible.
class ConceptLink {
  /// Link text, e.g. `daily active users` in `[daily active users](x.md)`.
  final String anchor;

  /// The original href, kept verbatim for debugging dangling links.
  final String rawHref;

  /// Bundle-relative path of the target, or null when the link is external or
  /// could not be resolved to a path inside the bundle.
  final String? targetPath;

  const ConceptLink({required this.anchor, required this.rawHref, this.targetPath});
}

class Concept {
  /// Bundle-relative path, e.g. `concepts/metrics/daily-active-users.md`.
  final String relpath;

  /// Frontmatter `type`, or null. Never assume it is present.
  final String? type;
  final String title;
  final String description;
  final List<String> tags;

  /// Every frontmatter key/value, including ones this app does not know about.
  /// OKF is versioned outside this codebase; unknown keys must survive, not
  /// crash.
  final Map<String, String> frontmatter;

  final String body;
  final List<ConceptLink> links;

  const Concept({
    required this.relpath,
    required this.title,
    required this.body,
    this.type,
    this.description = '',
    this.tags = const [],
    this.frontmatter = const {},
    this.links = const [],
  });

  /// Links that resolved to a real path inside the bundle.
  Iterable<ConceptLink> get resolvedLinks => links.where((l) => l.targetPath != null);
}
