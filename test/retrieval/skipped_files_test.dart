import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/retrieval/corpus.dart';

void main() {
  late Directory root;

  setUp(() async => root = await Directory.systemTemp.createTemp('okf_skipped_'));
  tearDown(() async => root.delete(recursive: true));

  Future<void> write(String relpath, List<int> bytes) async {
    final file = File('${root.path}/$relpath');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  group('openCorpus skipped files', () {
    test('a clean markdown bundle skips nothing', () async {
      await write('a.md', '# Alpha\n\nSome body text.'.codeUnits);

      final opened = await openCorpus(root: root, embedModel: 'none');
      expect(opened.skipped, isEmpty);
      expect(opened.corpus.bundle.concepts, hasLength(1));
    });

    test('an enabled file tool that extracts nothing is reported, not silent', () async {
      // The failure this guards: a user turns on Word, their .docx yields no
      // text, and the app looks exactly as it did when the toggle was off.
      await write('a.md', '# Alpha\n\nBody.'.codeUnits);
      await write('broken.docx', 'this is not a zip archive at all'.codeUnits);

      final opened = await openCorpus(root: root, embedModel: 'none', fileTools: {'docx'});

      expect(opened.skipped, hasLength(1));
      expect(opened.skipped.single, contains('broken.docx'));
      expect(opened.corpus.bundle.concepts, hasLength(1),
          reason: 'the unreadable file must not take the readable one down with it');
    });

    test('a file whose tool is disabled is not reported as unreadable', () async {
      // It was never meant to be read, so calling it unreadable would be noise.
      await write('a.md', '# Alpha\n\nBody.'.codeUnits);
      await write('ignored.docx', 'not a zip'.codeUnits);

      final opened = await openCorpus(root: root, embedModel: 'none');
      expect(opened.skipped, isEmpty);
    });

    test('a valid docx is extracted rather than skipped', () async {
      final archive = Archive()
        ..addFile(ArchiveFile.string(
          'word/document.xml',
          '<w:document><w:body><w:p><w:r><w:t>Quarterly notes</w:t></w:r></w:p>'
              '</w:body></w:document>',
        ));
      await write('report.docx', ZipEncoder().encode(archive));

      final opened = await openCorpus(root: root, embedModel: 'none', fileTools: {'docx'});

      expect(opened.skipped, isEmpty);
      expect(opened.corpus.bundle.concepts.single.body, contains('Quarterly notes'));
    });
  });
}
