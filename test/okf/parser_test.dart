// test/okf/parser_test.dart
//
// The parser is the only thing standing between a hand-edited markdown bundle
// and the rest of the app, so every case here is a file a human could plausibly
// write by accident. Nothing in it is allowed to throw.
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/okf/parser.dart';

void main() {
  group('splitFrontmatter', () {
    test('a file with no --- block is all body', () {
      final r = splitFrontmatter('# Title\n\nSome prose.\n');
      expect(r.yaml, isEmpty);
      expect(r.body, '# Title\n\nSome prose.\n');
    });

    test('a well-formed block is split off and the body keeps its content', () {
      final r = splitFrontmatter('---\ntitle: Alpha\ntype: concept\n---\n\nBody text.\n');
      expect(r.yaml, contains('title: Alpha'));
      expect(r.yaml, contains('type: concept'));
      expect(r.body, '\nBody text.\n');
    });

    test('an unterminated block stays body rather than swallowing the file', () {
      // The alternative — treating it as frontmatter — would silently delete
      // every word the user wrote.
      final raw = '---\ntitle: Alpha\nthis file was never closed\n';
      final r = splitFrontmatter(raw);
      expect(r.yaml, isEmpty);
      expect(r.body, raw);
    });

    test('CRLF line endings are normalised before the block is found', () {
      final r = splitFrontmatter('---\r\ntitle: Alpha\r\n---\r\n\r\nBody.\r\n');
      expect(parseFrontmatter(r.yaml)['title'], 'Alpha');
      expect(r.body, contains('Body.'));
      expect(r.body, isNot(contains('\r')));
    });

    test('a UTF-8 BOM does not hide the frontmatter block', () {
      // Editors on Windows add this invisibly; without stripping it the file
      // parses as one giant body and loses its type and title.
      final r = splitFrontmatter('\u{FEFF}---\ntitle: Alpha\n---\nBody.\n');
      expect(parseFrontmatter(r.yaml)['title'], 'Alpha');
      expect(r.body, 'Body.\n');
    });

    test('frontmatter with an empty body yields an empty body, not an error', () {
      final r = splitFrontmatter('---\ntitle: Alpha\n---\n');
      expect(parseFrontmatter(r.yaml)['title'], 'Alpha');
      expect(r.body, isEmpty);
    });

    test('a --- that is not on the first line is not treated as frontmatter', () {
      final raw = 'Intro\n---\ntitle: Alpha\n---\n';
      final r = splitFrontmatter(raw);
      expect(r.yaml, isEmpty);
      expect(r.body, raw);
    });
  });

  group('parseFrontmatter', () {
    test('keeps unknown keys verbatim', () {
      // OKF is versioned outside this codebase; a key this app has never heard
      // of must survive a round trip rather than be dropped.
      final fm = parseFrontmatter('title: Alpha\nokf_version: 3\nstatus: draft\n');
      expect(fm['okf_version'], '3');
      expect(fm['status'], 'draft');
    });

    test('skips malformed lines instead of throwing', () {
      final fm = parseFrontmatter('title: Alpha\n:::garbage:::\n- orphan item\n   \n: leading colon\nvalid: yes\n');
      expect(fm['title'], 'Alpha');
      expect(fm['valid'], 'yes');
      expect(fm.containsKey(''), isFalse);
    });

    test('strips matching quotes from values', () {
      final fm = parseFrontmatter('title: "Alpha: The Concept"\nother: \'single\'\nbare: plain\n');
      expect(fm['title'], 'Alpha: The Concept');
      expect(fm['other'], 'single');
      expect(fm['bare'], 'plain');
    });

    test('ignores comment lines', () {
      final fm = parseFrontmatter('# a comment\ntitle: Alpha\n  # indented comment\n');
      expect(fm.keys, ['title']);
    });

    test('a block list is collected under its key', () {
      final fm = parseFrontmatter('tags:\n  - alpha\n  - beta\ntitle: After\n');
      expect(fm['tags'], 'alpha, beta');
      expect(fm['title'], 'After');
    });

    test('a key with no value and no list stays empty rather than vanishing', () {
      final fm = parseFrontmatter('description:\ntitle: Alpha\n');
      expect(fm['description'], '');
      expect(fm['title'], 'Alpha');
    });
  });

  group('parseTags', () {
    test('parses the inline [a, b] form', () {
      expect(parseTags('[alpha, beta, gamma]'), ['alpha', 'beta', 'gamma']);
    });

    test('parses a bare comma list', () {
      expect(parseTags('alpha, beta'), ['alpha', 'beta']);
    });

    test('parses the block form as flattened by parseFrontmatter', () {
      final fm = parseFrontmatter('tags:\n  - alpha\n  - beta\n');
      expect(parseTags(fm['tags']), ['alpha', 'beta']);
    });

    test('unquotes quoted tags', () {
      expect(parseTags('["alpha one", \'beta two\']'), ['alpha one', 'beta two']);
    });

    test('empty, null and empty-list forms all yield no tags', () {
      expect(parseTags(null), isEmpty);
      expect(parseTags(''), isEmpty);
      expect(parseTags('   '), isEmpty);
      expect(parseTags('[]'), isEmpty);
      expect(parseTags('[ , , ]'), isEmpty);
    });
  });

  group('extractLinks', () {
    test('resolves a sibling link relative to the source file', () {
      final links = extractLinks('see [beta](beta.md)', 'concepts/alpha.md');
      expect(links.single.anchor, 'beta');
      expect(links.single.targetPath, 'concepts/beta.md');
    });

    test('resolves ../ links against the source directory', () {
      final links = extractLinks('see [up](../runbooks/deploy.md)', 'concepts/metrics/alpha.md');
      expect(links.single.targetPath, 'concepts/runbooks/deploy.md');
    });

    test('strips the #anchor before resolving', () {
      final links = extractLinks('see [beta](beta.md#definition)', 'concepts/alpha.md');
      expect(links.single.targetPath, 'concepts/beta.md');
      expect(links.single.rawHref, 'beta.md#definition');
    });

    test('a bare #anchor is a self-link and resolves to nothing', () {
      final links = extractLinks('jump to [later](#later)', 'concepts/alpha.md');
      expect(links.single.targetPath, isNull);
      expect(links.single.rawHref, '#later');
    });

    test('external schemes are kept as links but never resolved to a path', () {
      final links = extractLinks(
        '[web](https://example.com/a.md) [plain](http://example.com) [mail](mailto:a@b.c) [ftp](ftp://x/y.md)',
        'index.md',
      );
      expect(links.length, 4);
      expect(links.every((l) => l.targetPath == null), isTrue);
      expect(links.map((l) => l.anchor), ['web', 'plain', 'mail', 'ftp']);
    });

    test('a dangling target still resolves to a path — existence is the loader\'s job', () {
      // The parser has no view of the filesystem; the walk drops targets that
      // byPath cannot find, and rawHref is what makes that debuggable.
      final links = extractLinks('see [gone](does-not-exist.md)', 'concepts/alpha.md');
      expect(links.single.targetPath, 'concepts/does-not-exist.md');
      expect(links.single.rawHref, 'does-not-exist.md');
    });

    test('a link to the file itself resolves to its own path', () {
      final links = extractLinks('see [me](alpha.md)', 'concepts/alpha.md');
      expect(links.single.targetPath, 'concepts/alpha.md');
    });

    test('URL-encoded paths are decoded so byPath can match them', () {
      final links = extractLinks('see [spaced](my%20concept.md)', 'concepts/alpha.md');
      expect(links.single.targetPath, 'concepts/my concept.md');
    });

    test('a path escaping the bundle root resolves to null', () {
      // Path-traversal guard: a bundle is untrusted user content and must never
      // address a file outside its own root.
      final links = extractLinks(
        '[esc](../../../etc/passwd) [esc2](../outside.md)',
        'index.md',
      );
      expect(links.map((l) => l.targetPath), [null, null]);
    });

    test('a leading / is treated as bundle-root-relative, not filesystem-absolute', () {
      final links = extractLinks('see [root](/concepts/beta.md)', 'deep/nested/alpha.md');
      expect(links.single.targetPath, 'concepts/beta.md');
    });

    test('a link with a title attribute still resolves', () {
      final links = extractLinks('see [beta](beta.md "The Beta")', 'concepts/alpha.md');
      expect(links.single.targetPath, 'concepts/beta.md');
    });

    test('an empty href produces no target', () {
      final links = extractLinks('see [nothing]()', 'concepts/alpha.md');
      expect(links, isEmpty);
    });
  });

  group('parseConcept', () {
    test('reads title, type, description, tags and links off a normal file', () {
      final c = parseConcept(
        relpath: 'concepts/alpha.md',
        raw: '---\ntitle: Alpha Concept\ntype: concept\ndescription: The first one\ntags: [a, b]\n---\n'
            'Body linking to [beta](beta.md).\n',
      );
      expect(c.title, 'Alpha Concept');
      expect(c.type, 'concept');
      expect(c.description, 'The first one');
      expect(c.tags, ['a', 'b']);
      expect(c.resolvedLinks.single.targetPath, 'concepts/beta.md');
    });

    test('falls back to the filename as title when frontmatter has none', () {
      // Title-based seeding is the strongest routing signal there is, so a file
      // with no frontmatter must still get a usable one.
      final c = parseConcept(relpath: 'concepts/daily-active-users.md', raw: 'Just a body.\n');
      expect(c.title, 'daily active users');
      expect(c.type, isNull);
      expect(c.body, 'Just a body.\n');
    });

    test('an empty type is treated as absent rather than as the empty string', () {
      final c = parseConcept(relpath: 'a.md', raw: '---\ntype:\ntitle: A Thing\n---\nbody\n');
      expect(c.type, isNull);
    });

    test('an empty title in frontmatter still falls back to the filename', () {
      final c = parseConcept(relpath: 'notes/some-note.md', raw: '---\ntitle:\n---\nbody\n');
      expect(c.title, 'some note');
    });

    test('relpath is the identity and is never taken from frontmatter', () {
      final c = parseConcept(relpath: 'real/path.md', raw: '---\nrelpath: fake/path.md\n---\nbody\n');
      expect(c.relpath, 'real/path.md');
      expect(c.frontmatter['relpath'], 'fake/path.md');
    });
  });
}
