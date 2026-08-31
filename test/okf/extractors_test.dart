// test/okf/extractors_test.dart
//
// The FILE TOOLS toggles let a user point the indexer at binary documents. The
// contract that matters is not "extraction is perfect" but "a bad file is
// skipped, never thrown" — one unreadable PDF in a folder must not make the
// whole bundle unindexable. Fixtures are real files on disk, and the OOXML ones
// are real ZIPs, so the tests exercise the same decode path the app does.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rag_okf/okf/bundle.dart';
import 'package:pocket_rag_okf/okf/extractors.dart';

void main() {
  late Directory root;

  Future<File> writeText(String name, String content) async {
    final file = File('${root.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  /// Writes a ZIP holding exactly [entries] (path -> XML), which is all any of
  /// the OOXML extractors reads.
  Future<File> writeZip(String name, Map<String, String> entries) async {
    final archive = Archive();
    entries.forEach((path, xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    });
    final file = File('${root.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  Future<File> writeDocx(String name, String bodyXml) => writeZip(name, {
        'word/document.xml':
            '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>$bodyXml</w:body></w:document>',
      });

  setUp(() async => root = await Directory.systemTemp.createTemp('okf_extract_'));
  tearDown(() async => root.delete(recursive: true));

  group('extractText dispatch', () {
    test('an enabled extension is extracted', () async {
      final file = await writeText('notes.txt', 'plain notes');
      expect(await extractText(file, {'txt'}), 'plain notes');
    });

    test('a disabled extension yields null even though an extractor exists', () async {
      // This is the whole point of the toggle: the extractor is registered but
      // the user did not switch the format on, so the file is not read.
      final file = await writeText('notes.txt', 'plain notes');
      expect(await extractText(file, const {}), isNull);
      expect(await extractText(file, {'csv'}), isNull);
    });

    test('an extension with no extractor at all yields null', () async {
      final file = await writeText('archive.zip', 'not really a zip');
      expect(await extractText(file, {'zip'}), isNull);
    });

    test('the extension match is case-insensitive', () async {
      final file = await writeText('SHOUTING.TXT', 'loud');
      expect(await extractText(file, {'txt'}), 'loud');
    });

    test('a missing file returns null rather than throwing', () async {
      expect(await extractText(File('${root.path}/gone.txt'), {'txt'}), isNull);
    });
  });

  group('docx', () {
    test('concatenates w:t runs and breaks a line at each paragraph end', () async {
      final file = await writeDocx(
        'memo.docx',
        '<w:p><w:r><w:t>Hello </w:t></w:r><w:r><w:t>world</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>Second line</w:t></w:r></w:p>',
      );
      expect(await extractText(file, {'docx'}), 'Hello world\nSecond line');
    });

    test('xml entities are unescaped back to their characters', () async {
      // Word escapes these on write; leaving them escaped would put literal
      // "&amp;" into the retrieved context the model sees.
      final file = await writeDocx(
        'entities.docx',
        '<w:p><w:r><w:t>Tom &amp; Jerry &lt;b&gt; &quot;q&quot; &apos;a&apos;</w:t></w:r></w:p>',
      );
      expect(await extractText(file, {'docx'}), 'Tom & Jerry <b> "q" \'a\'');
    });

    test('a w:t with attributes is still swept, and its spacing kept', () async {
      // Word writes `xml:space="preserve"` on any run with meaningful
      // whitespace; a sweep that only matched bare <w:t> would drop the run
      // entirely, and trimming here would glue the next run onto it.
      final file = await writeDocx(
        'spaced.docx',
        '<w:p><w:r><w:t xml:space="preserve">kept </w:t></w:r><w:r><w:t>apart</w:t></w:r></w:p>',
      );
      expect(await extractText(file, {'docx'}), 'kept apart');
    });

    test('a corrupt archive returns null rather than throwing', () async {
      // One malformed file must never break the whole bundle load.
      final file = await writeText('broken.docx', 'this is not a zip at all');
      expect(await extractText(file, {'docx'}), isNull);
    });

    test('a valid zip missing word/document.xml returns null', () async {
      final file = await writeZip('empty.docx', {'docProps/app.xml': '<x/>'});
      expect(await extractText(file, {'docx'}), isNull);
    });
  });

  group('pptx', () {
    test('collects a:t runs from every slide', () async {
      final file = await writeZip('deck.pptx', {
        'ppt/slides/slide1.xml': '<p:sld><a:t>Title slide</a:t></p:sld>',
        'ppt/slides/slide2.xml': '<p:sld><a:t>Second slide</a:t><a:t>bullet</a:t></p:sld>',
        // Notes and layouts are not slides and must not be swept in.
        'ppt/slideLayouts/slideLayout1.xml': '<p:sldLayout><a:t>Click to edit</a:t></p:sldLayout>',
      });
      final text = await extractText(file, {'pptx'});
      expect(text, 'Title slide\nSecond slide\nbullet');
      expect(text, isNot(contains('Click to edit')));
    });

    test('a corrupt archive returns null rather than throwing', () async {
      final file = await writeText('broken.pptx', 'nope');
      expect(await extractText(file, {'pptx'}), isNull);
    });
  });

  group('xlsx', () {
    test('reads the shared string table and inline sheet values', () async {
      final file = await writeZip('book.xlsx', {
        'xl/sharedStrings.xml': '<sst><si><t>Revenue</t></si><si><t>Q1</t></si></sst>',
        'xl/worksheets/sheet1.xml':
            '<worksheet><sheetData><row>'
            '<c r="A1" t="s"><v>0</v></c>'
            '<c r="B1"><v>42000</v></c>'
            '</row></sheetData></worksheet>',
      });
      final text = await extractText(file, {'xlsx'});
      expect(text, contains('Revenue'));
      expect(text, contains('42000'));
    });

    test('a shared-string cell does not emit its table index as a number', () async {
      // `<c t="s"><v>0</v>` means "the string at index 0", not the number 0.
      // Emitting the index would litter the corpus with meaningless digits.
      final file = await writeZip('indices.xlsx', {
        'xl/sharedStrings.xml': '<sst><si><t>Revenue</t></si></sst>',
        'xl/worksheets/sheet1.xml':
            '<worksheet><row><c r="A1" t="s"><v>0</v></c></row></worksheet>',
      });
      expect(await extractText(file, {'xlsx'}), 'Revenue');
    });

    test('a corrupt archive returns null rather than throwing', () async {
      final file = await writeText('broken.xlsx', 'nope');
      expect(await extractText(file, {'xlsx'}), isNull);
    });
  });

  group('unimplemented formats', () {
    test('pdf is registered but extracts nothing', () async {
      // Registered so the extension is recognised; returning null is honest.
      // Faking extraction would put garbage in the citations.
      expect(textExtractors.containsKey('pdf'), isTrue);
      expect(await extractText(await writeText('paper.pdf', '%PDF-1.4'), {'pdf'}), isNull);
    });

    test('images extract nothing — offline OCR needs a native dependency', () async {
      for (final ext in ['png', 'jpg', 'jpeg']) {
        expect(textExtractors.containsKey(ext), isTrue);
        expect(await extractText(await writeText('shot.$ext', 'binary'), {ext}), isNull);
      }
    });
  });

  group('loadBundle with file tools', () {
    setUp(() async {
      await writeText('index.md', '---\ntitle: Bundle Index\n---\nEntry point.\n');
      await writeText('notes.txt', 'A plain text note about quokkas.');
      await writeDocx('report.docx', '<w:p><w:r><w:t>Quarterly report body</w:t></w:r></w:p>');
    });

    test('an empty file-tool set indexes markdown only, exactly as before', () async {
      // The regression that matters most: the default must not change what an
      // existing bundle indexes or what its content hash is.
      final bundle = await loadBundle(root);
      expect(bundle.concepts.map((c) => c.relpath), ['index.md']);
    });

    test('an enabled extension adds the file as a concept', () async {
      final bundle = await loadBundle(root, fileTools: {'txt'});
      expect(bundle.concepts.map((c) => c.relpath), containsAll(['index.md', 'notes.txt']));
      expect(bundle.byPath('notes.txt')!.body, contains('quokkas'));
    });

    test('a non-markdown concept takes the extension as its type and the filename as its title',
        () async {
      // The type feeds the router's corpus-type vocabulary for free.
      final bundle = await loadBundle(root, fileTools: {'docx'});
      final doc = bundle.byPath('report.docx')!;
      expect(doc.type, 'docx');
      expect(doc.title, 'report');
      expect(doc.links, isEmpty);
      expect(bundle.types, contains('docx'));
    });

    test('a disabled extension is not walked at all', () async {
      final bundle = await loadBundle(root, fileTools: {'txt'});
      expect(bundle.byPath('report.docx'), isNull);
    });

    test('the content hash changes when a newly-enabled file joins the bundle', () async {
      // Without this, turning PDF on would leave the old index in place and the
      // new files would never be embedded.
      final markdownOnly = await loadBundle(root);
      final withText = await loadBundle(root, fileTools: {'txt'});
      expect(withText.contentHash, isNot(markdownOnly.contentHash));
    });

    test('a corrupt enabled file is skipped, and the rest of the bundle still loads', () async {
      await writeText('broken.docx', 'not a zip');
      final skipped = <String>[];
      final bundle = await loadBundle(root, fileTools: {'docx'}, skipped: skipped);
      expect(bundle.byPath('index.md'), isNotNull);
      expect(bundle.byPath('report.docx'), isNotNull);
      expect(bundle.byPath('broken.docx'), isNull);
      expect(skipped.single, contains('broken.docx'));
    });
  });

  group('BundleManifest staleness', () {
    const manifest = BundleManifest(
      bundleId: 'b',
      contentHash: 'h',
      indexedAt: 0,
      embedModel: 'm',
      embedDim: 4,
      fileCount: 1,
      fileTools: ['docx', 'pdf'],
    );

    test('the same configuration is not stale', () {
      expect(
        manifest.isStaleFor(contentHash: 'h', embedModel: 'm', fileTools: {'pdf', 'docx'}),
        isFalse,
      );
    });

    test('enabling a new file tool makes the index stale even with no disk change', () {
      // The whole reason the manifest records the set: nothing on disk moved,
      // but there are now files that belong in the index and are not in it.
      expect(
        manifest.isStaleFor(contentHash: 'h', embedModel: 'm', fileTools: {'pdf', 'docx', 'xlsx'}),
        isTrue,
      );
    });

    test('disabling a file tool also makes the index stale', () {
      expect(manifest.isStaleFor(contentHash: 'h', embedModel: 'm', fileTools: {'pdf'}), isTrue);
    });

    test('a manifest written before file tools existed reads back as none enabled', () {
      final old = BundleManifest.fromJson({
        'bundle_id': 'b',
        'content_hash': 'h',
        'embed_model': 'm',
      });
      expect(old.fileTools, isEmpty);
      expect(old.isStaleFor(contentHash: 'h', embedModel: 'm'), isFalse);
      expect(old.isStaleFor(contentHash: 'h', embedModel: 'm', fileTools: {'pdf'}), isTrue);
    });
  });
}
