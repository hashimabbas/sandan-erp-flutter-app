import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/evidence_files.dart';

/// SPEC-024 Phase 3, Step 6 — the photograph's file.
///
/// 🔴 **What these tests are really about:** `image_picker` returns a file in a
/// temporary directory the operating system may delete at will. A queue item
/// holding that path is a photograph silently lost, and the Spec named exactly
/// that failure — *"a technician who photographs ten work orders in a basement
/// must not lose them to a restart."*
void main() {
  late Directory root;

  setUp(() async => root = await Directory.systemTemp.createTemp('sandan_evidence_test'));

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  EvidenceFiles files() => EvidenceFiles(directory: () async => root);

  Future<File> picked(String name) async {
    final temporary = await Directory.systemTemp.createTemp('sandan_picker');
    final file = File('${temporary.path}/$name');

    await file.writeAsBytes(List<int>.filled(128, 7));

    return file;
  }

  test('🔴 the picked file is COPIED, so deleting the original loses nothing', () async {
    final original = await picked('work.jpg');

    final kept = await files().keep(original, jobId: 'job-1');

    // The OS clears its temporary directory — which is the whole point.
    await original.delete();

    expect(await File(kept).exists(), isTrue);
    expect(await File(kept).length(), 128);
  });

  test('the copy lives under the app\'s own folder and names its job', () async {
    final kept = await files().keep(await picked('work.jpg'), jobId: 'job-7');

    expect(kept, contains('/${EvidenceFiles.folderName}/'));
    expect(kept, contains('job-7'));
    expect(kept, endsWith('.jpg'));
  });

  test('two photographs of one job do not overwrite each other', () async {
    final first = await files().keep(
      await picked('a.jpg'),
      jobId: 'job-1',
      now: DateTime.utc(2026, 10, 28, 9, 0, 0),
    );
    final second = await files().keep(
      await picked('b.jpg'),
      jobId: 'job-1',
      now: DateTime.utc(2026, 10, 28, 9, 0, 1),
    );

    // ⚠️ A replayed upload deliberately produces a second photograph rather
    // than silently swallowing a genuine one — Phase 0's rule, and this is the
    // file-level half of it.
    expect(first, isNot(second));
    expect(await File(first).exists(), isTrue);
    expect(await File(second).exists(), isTrue);
  });

  test('discard removes a photograph the server has accepted', () async {
    final kept = await files().keep(await picked('work.jpg'), jobId: 'job-1');

    await EvidenceFiles.discard(kept);

    expect(await File(kept).exists(), isFalse);
  });

  test('⚠️ discarding a file that is already gone is not an error', () async {
    // The upload succeeded. Refusing to finish because a tidy-up failed would
    // turn housekeeping into a lost confirmation.
    await EvidenceFiles.discard('${root.path}/never-existed.jpg');
  });
}
