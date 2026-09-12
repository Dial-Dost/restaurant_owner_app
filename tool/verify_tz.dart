// Checks lib/services/tz_offsets.dart against the ICU offsets it was generated
// from. `tool/gen_tz_cases.mjs` writes the expectations, this replays them
// through the Dart resolver the app actually uses.
//
//   node tool/gen_tz_cases.mjs > tool/tz_cases.json
//   C:/Users/mechi/flutter/bin/dart.bat run tool/verify_tz.dart tool/tz_cases.json
//
// Exits non-zero on the first mismatch count > 0.

import 'dart:convert';
import 'dart:io';

// package:, not '../lib/...'. A relative path into lib/ gives the same library
// two identities — one via the relative path, one via package: — and Dart then
// treats their types as unrelated. It also fails outright the moment this script
// is run from anywhere but the repo root. Same file, addressed the one way that
// always resolves.
import 'package:restaurant_owner_app/services/tz_offsets.dart';

void main(List<String> args) {
  final path = args.isEmpty ? 'tool/tz_cases.json' : args.first;
  final cases = (jsonDecode(File(path).readAsStringSync()) as List).cast<List>();
  var bad = 0;
  for (final c in cases) {
    final zone = c[0] as String;
    final epoch = c[1] as int;
    final expected = c[2] as int;
    final got = tzOffsetMinutes(zone, epoch);
    if (got != expected) {
      bad++;
      if (bad <= 20) {
        stderr.writeln('MISMATCH $zone @$epoch: expected $expected got $got');
      }
    }
  }
  stdout.writeln('${cases.length} cases, $bad mismatches, '
      '$tzZoneCount zones, ${tzZoneNames.length} names, range $tzDataFromYear..$tzDataToYear');
  if (bad > 0) exitCode = 1;
}
