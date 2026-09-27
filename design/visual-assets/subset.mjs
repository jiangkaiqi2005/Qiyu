// Font subsetting script (source of truth for the app's serif font subset; not part of the repo build).
// subset-font@2.5 has NO `ranges` option -- it only accepts a text string. So we build
// the text from the exact codepoints we need, intersected with the source font's cmap.
//
// usage: node subset.mjs <outputPath> [profile]
//   profile: full (default, mandated ranges) | no-exta (size experiment only)
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const subsetFont = require('subset-font');
const fontkit = require('fontkit');

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INPUT = path.join(HERE, 'NotoSerifSC-Full.ttf');
const OUTPUT = path.resolve(process.argv[2] || path.join(HERE, 'NotoSerifSC-QiyuSubset.ttf'));
const PROFILE = process.argv[3] || 'full';

// Decimal codepoint ranges, inclusive.
const ALL_RANGES = [
  { name: 'Basic Latin (U+0020-U+007E)', start: 0x0020, end: 0x007e },
  { name: 'Latin-1 (U+00A0-U+00FF)', start: 0x00a0, end: 0x00ff },
  { name: 'General Punctuation (U+2010-U+2027)', start: 0x2010, end: 0x2027 },
  { name: 'CJK Symbols & Punct (U+3000-U+303F)', start: 0x3000, end: 0x303f },
  { name: 'CJK Ext A (U+3400-U+4DBF)', start: 0x3400, end: 0x4dbf },
  { name: 'CJK Unified Ideographs (U+4E00-U+9FFF)', start: 0x4e00, end: 0x9fff },
  { name: 'Half/Full Forms (U+FF00-U+FFEF)', start: 0xff00, end: 0xffef },
].sort((a, b) => a.start - b.start);

const RANGES =
  PROFILE === 'no-exta'
    ? ALL_RANGES.filter((r) => !r.name.includes('Ext A'))
    : ALL_RANGES;

const srcBuf = await fs.readFile(INPUT);
const src = fontkit.create(srcBuf);
const srcSet = new Set(src.characterSet);

// Build the payload text. All mandated ranges are BMP, so fromCharCode is safe.
const chars = [];
for (const r of RANGES) {
  for (let cp = r.start; cp <= r.end; cp++) if (srcSet.has(cp)) chars.push(cp);
}
const text = String.fromCodePoint(...chars);
console.log(`profile=${PROFILE} codepoints requested from source: ${chars.length}`);

const out = await subsetFont(srcBuf, text, {
  targetFormat: 'sfnt', // 'truetype' is an accepted alias
  preserveNameIds: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 13, 14],
});
await fs.writeFile(OUTPUT, out);

const sub = fontkit.create(out);
const subSet = new Set(sub.characterSet);
const wanted = new Set(chars);
let missing = 0;
for (const cp of wanted) if (!subSet.has(cp)) missing++;

console.log(`\nwrote ${OUTPUT}`);
console.log(`bytes: ${out.length} (${(out.length / 1024 / 1024).toFixed(2)} MB)`);
console.log(`subset covered codepoints: ${subSet.size}`);
console.log(`subset glyph count: ${sub.numGlyphs}`);
console.log(`requested-but-missing after subsetting: ${missing}`);

console.log('\nrange coverage in the produced subset:');
for (const r of RANGES) {
  let got = 0;
  const size = r.end - r.start + 1;
  for (let cp = r.start; cp <= r.end; cp++) if (subSet.has(cp)) got++;
  console.log(`  ${r.name.padEnd(42)} ${String(got).padStart(5)}/${String(size).padStart(5)}`);
}

const names = sub.names;
console.log('\nname table:');
for (const k of ['fontFamily', 'fullName', 'postScriptName', 'version', 'copyright', 'license']) {
  if (names && names[k]) console.log(`  ${k}: ${names[k]}`);
}
