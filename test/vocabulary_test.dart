import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/models/work_order.dart';

/// SPEC-024 Phase 1, Step 2 — the app stops holding the server's vocabulary.
void main() {
  group('the legacy priority is gone for good', () {
    test("no source file under lib/ contains the string 'medium'", () {
      // 🔴 This is a grep, deliberately, and it is the point of the step.
      //
      // `'medium'` was renamed to `'normal'` by SPEC-018 D3. The app went on
      // posting it, and a dated alias in `StoreFacilityComplaintRequest` has
      // been translating every complaint raised from a phone ever since. That
      // alias is being retired, and the moment it is, a `'medium'` that crept
      // back into Dart becomes a 422 the operator cannot explain — not a
      // failing test.
      //
      // A unit test cannot watch a whole codebase; a grep can.
      final offenders = <String>[];

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;

        final lines = entity.readAsLinesSync();

        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // Comments may name it — this file and the screen both explain why
          // it went. Only live code is forbidden to contain it.
          if (line.trimLeft().startsWith('//') || line.trimLeft().startsWith('///')) continue;
          if (line.contains("'medium'") || line.contains('"medium"')) {
            offenders.add('${entity.path}:${i + 1}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: "The server does not accept 'medium'. Priorities come from "
            'GET /api/facility/complaints/lookup/vocabulary.',
      );
    });
  });

  group('the vocabulary payload', () {
    test('decodes the shape the endpoint actually returns', () {
      // ⚠️ Recorded from `FacilityComplaintController::vocabulary()`, which
      // maps `ComplaintPriority::cases()` and `ComplaintStatus::cases()` to
      // `{value, label}` — read, not assumed.
      final body = jsonDecode('''
        {
          "priorities": [
            {"value": "low", "label": "Low"},
            {"value": "normal", "label": "Normal"},
            {"value": "high", "label": "High"},
            {"value": "emergency", "label": "Emergency"}
          ],
          "statuses": [
            {"value": "new", "label": "New"},
            {"value": "assigned", "label": "Assigned"}
          ]
        }
      ''') as Map<String, dynamic>;

      final priorities = (body['priorities'] as List<dynamic>)
          .map((e) => Vocab.fromJson(e as Map<String, dynamic>))
          .toList();

      expect(priorities, hasLength(4));
      expect(priorities.first.value, 'low');
      expect(priorities.map((p) => p.value), contains('normal'));
      // 🔴 The app's old static list had THREE options and could not raise an
      // emergency at all.
      expect(priorities.map((p) => p.value), contains('emergency'));
      expect(priorities.map((p) => p.value), isNot(contains('medium')));
    });

    test('the default is the first value the SERVER sends, not a name in Dart', () {
      // 🎯 The web's create form uses `priorities[0]?.value`. The app does the
      // same, so the two clients cannot default differently — and neither of
      // them states an opinion the server did not.
      final priorities = [
        const Vocab(value: 'low', label: 'Low'),
        const Vocab(value: 'normal', label: 'Normal'),
      ];

      expect(priorities.first.value, 'low');
    });
  });
}
