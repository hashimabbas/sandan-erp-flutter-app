import 'dart:io';

/// SPEC-024 Phase 3, Step 6 — where a queued photograph actually lives.
///
/// 🔴 **The failure this class exists to prevent.** `image_picker` hands back
/// a file in a **temporary** directory, which the operating system may delete
/// whenever it likes. A queue item holding that path is a photograph silently
/// lost — and the Spec named it: *"a technician who photographs ten work
/// orders in a basement must not lose them to a restart."*
///
/// ✅ So the picked file is **copied into the app's own storage** and the queue
/// holds the copy's path. The copy is deleted once the server has it.
///
/// ⚠️ **The directory is injected**, like every other platform-shaped thing in
/// this app: `path_provider` resolves the documents directory through a
/// platform channel, which `flutter test` does not have. A class that asked
/// for it in its constructor would be untestable — the lesson Phase 2 paid for
/// twice.
class EvidenceFiles {
  EvidenceFiles({required this.directory});

  /// Where the app may keep files. Injected — see the note above.
  final Future<Directory> Function() directory;

  static const folderName = 'evidence';

  /// Copies [picked] into the app's own storage and returns the copy's path.
  ///
  /// The name carries the job and a timestamp so two photographs of one job
  /// cannot overwrite each other — ⚠️ and a replayed upload deliberately
  /// produces a second photograph rather than silently swallowing a genuine
  /// one, which is the rule Phase 0 settled.
  Future<String> keep(File picked, {required String jobId, DateTime? now}) async {
    final root = Directory('${(await directory()).path}/$folderName');

    if (!await root.exists()) {
      await root.create(recursive: true);
    }

    final stamp = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final extension = picked.path.split('.').last.toLowerCase();
    final target = '${root.path}/$jobId-$stamp.$extension';

    await picked.copy(target);

    return target;
  }

  /// Removes a photograph the server has accepted.
  ///
  /// 🔴 Called from the drain, because **no outbox row may be removed without
  /// its file**: otherwise the phone fills up with photographs of jobs that
  /// closed weeks ago, and nothing points at them any more.
  ///
  /// ⚠️ Failures are swallowed: the upload succeeded, and refusing to finish
  /// because a file could not be deleted would turn a tidy-up into a lost
  /// confirmation.
  static Future<void> discard(String path) async {
    try {
      final file = File(path);

      if (await file.exists()) await file.delete();
    } catch (_) {
      // The photograph reached the server. Nothing here is worth failing for.
    }
  }
}
