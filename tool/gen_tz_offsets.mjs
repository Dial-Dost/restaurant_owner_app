// Regenerates lib/services/tz_offsets.dart — the UTC-offset table the owner app
// uses to render instants in the restaurant's timezone.
//
// WHY THIS EXISTS
// ---------------
// Dart/Flutter ships no IANA timezone database: DateTime can only do UTC and the
// *device's* zone. The restaurant's reporting zone is a per-tenant setting that
// has nothing to do with the machine the owner app happens to run on, so the app
// has to resolve "what was the UTC offset of Asia/Kolkata (or America/New_York,
// or Australia/Lord_Howe) at this instant" itself.
//
// The backend cannot answer that per instant — GET /restaurant/timezones returns
// the zone *id* and nothing else (verified against the live server). So we take
// the offsets from the same place the backend gets them: Node's full-ICU build,
// ahead of time, and check the result in as data. No pub dependency is added.
//
// The table is a real transition list, not a fixed offset — a zone with DST has
// one entry per changeover, so a timestamp from January and one from July in
// America/New_York format five and four hours behind UTC respectively.
//
// RUN IT when the IANA rules change (a country moves or abolishes DST) or when
// the covered range needs extending:
//
//   node tool/gen_tz_offsets.mjs                  # zone list from Intl
//   BACKEND=http://localhost:3001 node tool/gen_tz_offsets.mjs
//
// With BACKEND set (plus ADMIN_USER / ADMIN_PASS / RESTAURANT / RESTAURANT_ID)
// the zone list is pulled from GET /restaurant/timezones so the app's table and
// the server's picker cover exactly the same zones. Without it the list comes
// from this machine's own Intl.supportedValuesOf, unioned with UTC and the
// backend default, which is the same set.

import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, "..", "lib", "services", "tz_offsets.dart");

// Range covered by the emitted table. Outside it the resolver clamps to the
// first/last known offset — a POS never displays a 1990 or a 2050 timestamp,
// and clamping is still right for every zone that has not changed its rules.
const FROM_YEAR = 2010;
const TO_YEAR = 2041;
// Coarse scan step. Every real transition pair is months apart (the tightest
// historical case, Morocco's Ramadan suspensions, is ~4 weeks), so 4 days can
// not step over one; the exact second is then found by binary search.
const STEP_MS = 4 * 86400000;

async function zoneList() {
  const base = process.env.BACKEND;
  if (base) {
    const login = await fetch(`${base}/auth/employee-login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        employeeUsername: process.env.ADMIN_USER ?? "admin",
        password: process.env.ADMIN_PASS ?? "admin123",
        restaurantName: process.env.RESTAURANT ?? "CSR Organics",
        restaurantId: process.env.RESTAURANT_ID ?? "csrorganics",
      }),
    });
    const { token } = await login.json();
    const res = await fetch(`${base}/restaurant/timezones`, {
      headers: { Authorization: `Bearer ${token}`, "X-Restaurant-Id": process.env.RESTAURANT_ID ?? "csrorganics" },
    });
    const body = await res.json();
    if (Array.isArray(body.timezones) && body.timezones.length) return body.timezones;
  }
  // Same union the backend's supportedTimezones() builds: the canonical list
  // plus UTC and the default, neither of which the canonical list contains
  // (canonical for India is the legacy alias Asia/Calcutta).
  const canonical = Intl.supportedValuesOf?.("timeZone") ?? [];
  return [...new Set([...canonical, "UTC", "Asia/Kolkata"])].sort((a, b) => a.localeCompare(b));
}

// IANA "backward" links whose two spellings are the SAME zone. The canonical
// list Intl hands out picks exactly one of each pair, and which one is an ICU
// build detail — this ICU calls India "Asia/Calcutta" and Nepal "Asia/Katmandu"
// while the backend's default and most stored values use "Asia/Kolkata". A
// tenant row (or a newer backend) can legitimately carry either spelling, so
// both are generated; they dedupe onto one shared rule set, costing a map line.
// Ids this ICU does not accept are skipped, so the list is safe to over-provide.
const ALIASES = [
  "Asia/Kolkata", "Asia/Calcutta", "Asia/Kathmandu", "Asia/Katmandu",
  "Asia/Ho_Chi_Minh", "Asia/Saigon", "Asia/Yangon", "Asia/Rangoon",
  "Asia/Dhaka", "Asia/Dacca", "Asia/Chongqing", "Asia/Shanghai",
  "Asia/Istanbul", "Europe/Istanbul", "Asia/Tel_Aviv", "Asia/Jerusalem",
  "Asia/Nicosia", "Europe/Nicosia", "Europe/Kyiv", "Europe/Kiev",
  "America/Nuuk", "America/Godthab", "America/Buenos_Aires",
  "America/Argentina/Buenos_Aires", "America/Indianapolis",
  "America/Indiana/Indianapolis", "America/Louisville",
  "America/Kentucky/Louisville", "Atlantic/Faroe", "Atlantic/Faeroe",
  "Africa/Asmara", "Africa/Asmera", "Pacific/Chuuk", "Pacific/Truk",
  "Pacific/Pohnpei", "Pacific/Ponape", "Pacific/Kanton", "Pacific/Enderbury",
  "Australia/Canberra", "Australia/Sydney", "UTC", "Etc/UTC", "GMT", "Etc/GMT",
];

function icuAccepts(tz) {
  try {
    new Intl.DateTimeFormat(undefined, { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

const formatters = new Map();
function formatterFor(tz) {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    formatters.set(tz, f);
  }
  return f;
}

// Offset of `tz` from UTC, in minutes, at the given instant. Same trick the
// backend's zonedWallToUtc uses: render the instant as wall-clock in the zone,
// re-read those fields as if they were UTC, and diff.
function offsetMinutes(tz, ms) {
  const parts = {};
  for (const p of formatterFor(tz).formatToParts(new Date(ms))) parts[p.type] = p.value;
  const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  return Math.round((asUtc - ms) / 60000);
}

function transitionsFor(tz) {
  const start = Date.UTC(FROM_YEAR, 0, 1);
  const end = Date.UTC(TO_YEAR, 0, 1);
  let prev = offsetMinutes(tz, start);
  const rule = [prev]; // [baseOffsetMin, epochSec, offsetMin, epochSec, offsetMin, …]
  let lo = start;
  for (let t = start + STEP_MS; t <= end; t += STEP_MS) {
    const cur = offsetMinutes(tz, t);
    if (cur !== prev) {
      let a = lo;
      let b = t;
      while (b - a > 1000) {
        const mid = a + Math.floor((b - a) / 2000) * 1000;
        if (offsetMinutes(tz, mid) === prev) a = mid;
        else b = mid;
      }
      rule.push(Math.round(b / 1000), cur);
      prev = cur;
    }
    lo = t;
  }
  return rule;
}

const zones = [...new Set([...(await zoneList()), ...ALIASES.filter(icuAccepts)])].sort((a, b) =>
  a.localeCompare(b),
);
const byZone = new Map();
for (const tz of zones) byZone.set(tz, transitionsFor(tz));

// Most zones share a rule set (all of the EU, all of the non-DST tropics, …):
// deduping takes 419 rule lists down to ~140 and the file to a third of its size.
const unique = new Map();
const index = [];
for (const [tz, rule] of byZone) {
  const key = rule.join(",");
  if (!unique.has(key)) unique.set(key, unique.size);
  index.push([tz, unique.get(key)]);
}

const header = `// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Regenerate with:  node tool/gen_tz_offsets.mjs
//
// UTC-offset transitions for every timezone the backend's picker offers
// (GET /restaurant/timezones), taken from Node's full-ICU database — the same
// one the backend validates zones against — because Dart has no IANA database
// of its own and the server exposes no per-instant offset.
//
// Covers ${FROM_YEAR}-01-01 .. ${TO_YEAR}-01-01 UTC. Generated ${new Date().toISOString().slice(0, 10)}
// from ${zones.length} zones / ${unique.size} distinct rule sets.
`;

const body =
  `${header}
/// First year of real data in [_rules]; before it the base offset is assumed.
const int tzDataFromYear = ${FROM_YEAR};

/// Last year of real data in [_rules]; after it the final offset is assumed.
const int tzDataToYear = ${TO_YEAR};

/// True when [zone] is covered by this table (callers fall back to the device
/// zone and say so when it is not).
bool tzZoneKnown(String zone) => _zones.containsKey(zone);

/// Number of zones in the table — surfaced in the settings UI.
int get tzZoneCount => _zones.length;

/// Every zone this build can render, sorted. Used as the settings picker's
/// offline fallback when GET /restaurant/timezones is unreachable.
List<String> get tzZoneNames => _zones.keys.toList();

/// UTC offset of [zone], in minutes, at [epochSeconds]; null when the zone is
/// not in the table.
///
/// Binary-searches the zone's transition list, so a January and a July instant
/// in a DST zone resolve to different offsets — the whole point of shipping
/// transitions rather than one fixed number per zone.
int? tzOffsetMinutes(String zone, int epochSeconds) {
  final ruleIndex = _zones[zone];
  if (ruleIndex == null) return null;
  final rule = _rules[ruleIndex];
  // rule = [baseOffset, t0, off0, t1, off1, …] with t ascending (epoch seconds).
  var lo = 0; // count of transitions at or before epochSeconds
  var hi = (rule.length - 1) ~/ 2;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2; // candidate count, 1-based into the pairs
    if (rule[mid * 2 - 1] <= epochSeconds) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo == 0 ? rule[0] : rule[lo * 2];
}

const List<List<int>> _rules = [
${[...unique.keys()].map((r) => `  [${r}],`).join("\n")}
];

const Map<String, int> _zones = {
${index.map(([z, i]) => `  '${z}': ${i},`).join("\n")}
};
`;

mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, body);
console.log(`wrote ${OUT}: ${zones.length} zones, ${unique.size} rule sets, ${Buffer.byteLength(body)} bytes`);
