// Writes [zone, epochSeconds, offsetMinutes] expectations straight from ICU for
// tool/verify_tz.dart to replay through the shipped Dart table. Covers every
// zone at fixed mid-winter/mid-summer instants (so DST zones are exercised on
// both sides of every changeover) plus random instants across the whole range.
//
//   node tool/gen_tz_cases.mjs > tool/tz_cases.json

const canonical = Intl.supportedValuesOf?.("timeZone") ?? [];
const zones = [...new Set([...canonical, "UTC", "Asia/Kolkata"])].sort((a, b) => a.localeCompare(b));

const formatters = new Map();
function offsetMinutes(tz, ms) {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz, hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    formatters.set(tz, f);
  }
  const p = {};
  for (const q of f.formatToParts(new Date(ms))) p[q.type] = q.value;
  return Math.round((Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second) - ms) / 60000);
}

const LO = Date.UTC(2010, 0, 1);
const HI = Date.UTC(2041, 0, 1);
const cases = [];
let seed = 12345;
const rnd = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);

for (const tz of zones) {
  for (let y = 2010; y < 2041; y += 3) {
    for (const ms of [Date.UTC(y, 0, 15, 12), Date.UTC(y, 6, 15, 12)]) cases.push([tz, ms / 1000, offsetMinutes(tz, ms)]);
  }
  for (let i = 0; i < 4; i++) {
    const ms = Math.floor(LO + rnd() * (HI - LO));
    cases.push([tz, Math.floor(ms / 1000), offsetMinutes(tz, ms)]);
  }
}

process.stdout.write(JSON.stringify(cases));
