// Glyph-level acceptance check for the shipped subset. Reads the real asset file and
// asserts each mandated codepoint not only appears in cmap but resolves to a real glyph
// with outlines (not .notdef / not an empty shell).
// usage: node verify-font.mjs [pathToTtf]
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const fontkit = require('fontkit');

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TARGET = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.resolve(HERE, '../../apps/qiyu_flutter/assets/fonts/NotoSerifSC-QiyuSubset.ttf');

// codepoint, human label, must-have-outline (space-like glyphs legitimately have none)
const MUST_HAVE_GLYPH = [
  [0x6816, '栖'], [0x8bed, '语'], [0x3002, '。'], [0x3001, '、'],
  [0x300a, '《'], [0x300b, '》'], [0xff0c, '，'], [0xff1a, '：'],
  [0xff1b, '；'], [0xff1f, '？'], [0x2014, '—'], [0x2018, '‘'],
  [0x201c, '“'], [0x201d, '”'], [0x2026, '…'], [0x4e00, '一'],
  [0x9fff, '鿿 (CJK block end)'], [0x3400, '㐀 (Ext A start)'],
  [0x4dbf, '㒿 (Ext A end)'], [0xff5e, '～'], [0x3000, 'IDEOGRAPHIC SPACE'],
  [0x0041, 'A'], [0x0037, '7'], [0x0020, 'SPACE'],
];

const buf = await fs.readFile(TARGET);
const font = fontkit.create(buf);
const set = new Set(font.characterSet);
const glyphIdOf = (cp) => {
  const g = font.glyphForCodePoint(cp);
  return g ? g.id : -1;
};

console.log(`file: ${TARGET}`);
console.log(`bytes: ${buf.length} (${(buf.length / 1024 / 1024).toFixed(2)} MB)`);
console.log(`family: ${font.familyName} / ${font.fullName}`);
console.log(`postscript: ${font.postscriptName}`);
console.log(`unitsPerEm: ${font.unitsPerEm}  glyphs: ${font.numGlyphs}`);
console.log(`covered codepoints: ${set.size}\n`);

let fail = 0;
const rows = [];
for (const [cp, label] of MUST_HAVE_GLYPH) {
  const inCmap = set.has(cp);
  const gid = glyphIdOf(cp);
  let commands = -1;
  let aw = 0;
  if (inCmap && gid > 0) {
    const g = font.glyphForCodePoint(cp);
    aw = g.advanceWidth || 0;
    try {
      commands = g.path.commands.length; // decodes glyf; 0 for a blank glyph
    } catch {
      commands = -1; // undecodable outline
    }
  }
  const whitespace = cp === 0x20 || cp === 0x3000;
  // gid > 0 excludes .notdef; blank spaces legitimately carry no ink, everything else must.
  const ok = inCmap && gid > 0 && commands >= 0 && (whitespace ? aw > 0 : commands > 0 && aw > 0);
  rows.push({ cp: 'U+' + cp.toString(16).toUpperCase().padStart(4, '0'), label, cmap: inCmap ? 'yes' : 'NO', gid, aw: String(aw), cmd: String(commands), ok });
  if (!ok) fail++;
}

const pad = (s, n) => String(s).padEnd(n, ' ');
console.log(pad('codepoint', 10) + pad('glyph', 24) + pad('inCmap', 8) + pad('gid', 7) + pad('advW', 6) + pad('cmds', 6) + 'result');
console.log('-'.repeat(72));
for (const r of rows) {
  console.log(pad(r.cp, 10) + pad(r.label, 24) + pad(r.cmap, 8) + pad(r.gid, 7) + pad(r.aw, 6) + pad(r.cmd, 6) + (r.ok ? 'PASS' : 'FAIL'));
}

// Contiguous-block assertions the brief called out explicitly.
function blockCheck(name, start, end) {
  let miss = 0;
  for (let cp = start; cp <= end; cp++) if (!set.has(cp)) miss++;
  const total = end - start + 1;
  const ok = miss === 0;
  console.log(`\nblock ${name} (U+${start.toString(16).toUpperCase()}-U+${end.toString(16).toUpperCase()}): ${total - miss}/${total} present -> ${ok ? 'PASS' : 'FAIL'}`);
  if (!ok) fail++;
  return miss;
}
blockCheck('fullwidth ASCII', 0xff01, 0xff5e);
blockCheck('CJK unified', 0x4e00, 0x9fff);
blockCheck('CJK ext A', 0x3400, 0x4dbf);
blockCheck('CJK symbols & punct', 0x3000, 0x303f);
blockCheck('basic latin', 0x0020, 0x007e);

console.log(`\n${fail === 0 ? 'ALL ASSERTIONS PASSED' : fail + ' ASSERTION(S) FAILED'}`);
process.exit(fail === 0 ? 0 : 1);
