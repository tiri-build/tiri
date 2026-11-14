// Writes tiri.build's Chinese pages from the English ones.
//
// The English pages in public/ are the only pages anyone edits. For each language, this reads them, swaps every
// piece of text for its translation, points the links at that language's pages, and writes public/<language>/.
// The words app.js draws (the film and the two working windows) go into public/<language>/strings.js.
//
// The key is the English, exactly as it stands between two tags or inside t("…") in app.js. Text that sits
// beside a tag (a bold word mid-sentence) is several pieces, each with its own key; a key may start or end with
// a space when the translation shouldn't keep it. A translation may hold a <wbr> where a heading may break.
//
//   node i18n/build.mjs            write the pages; say what has no translation
//   node i18n/build.mjs --strict   the same, and fail if anything is missing or left over
//
// Wrangler runs this before `dev` and `deploy` (wrangler.jsonc), and `npm run deploy` runs it strictly, so a
// page can't go out with an English sentence in it. The output is not committed.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const pub = join(here, "..", "public");
const strict = process.argv.includes("--strict");

const LANGUAGES = [
  { code: "zh-Hans", dir: "zh-hans" },
  { code: "zh-Hant", dir: "zh-hant" },
];
// Each page, and where it lives under a language's folder.
const PAGES = [
  { file: "index.html", path: "" },
  { file: "privacy.html", path: "privacy" },
];
// Names, which read the same in every language. Paths and file names are kept without being listed.
const NAMES = new Set(["Tiri", "GitHub", "LinkedIn", "English", "Tianrun Qiu", "Cursor, Windsurf, Zed", "Conductor, Superset, Emdash"]);
const isPath = (s) => /^[\w@~-]*[./][\w./:@~-]*$/.test(s);
const hasWords = (s) => /[A-Za-z]{2}/.test(s.replace(/&#?\w+;/g, ""));
// A file that hasn't changed is left alone, so `wrangler dev`, which watches public/, doesn't build in circles.
const write = (to, text) => {
  if (!existsSync(to) || readFileSync(to, "utf8") !== text) writeFileSync(to, text);
};

const appSource = readFileSync(join(pub, "app.js"), "utf8");
// Every t("…") in app.js, as the string it stands for.
const appKeys = new Set();
for (const m of appSource.matchAll(/\bt\(\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\$]|\\.)*`)/g)) appKeys.add(new Function(`return ${m[1]}`)());

let problems = 0;
for (const lang of LANGUAGES) {
  const words = (await import(`./${lang.code}.mjs`)).default;
  const used = new Set();
  const missing = new Map();
  const miss = (text, where) => missing.has(text) || missing.set(text, where);
  const find = (text) => {
    if (!Object.hasOwn(words, text)) return null;
    used.add(text);
    return words[text];
  };
  // A piece of text, translated. Spaces around it are kept unless the key itself includes them.
  const say = (raw, where) => {
    const text = raw.trim();
    if (!text) return raw;
    const whole = find(raw);
    if (whole !== null) return whole;
    const inner = find(text);
    if (inner !== null) return raw.replace(text, () => inner);
    if (hasWords(text) && !NAMES.has(text) && !isPath(text)) miss(text, where);
    return raw;
  };

  const out = join(pub, lang.dir);
  mkdirSync(out, { recursive: true });

  for (const page of PAGES) {
    const parts = readFileSync(join(pub, page.file), "utf8").split(/(<[^>]*>)/);
    let toEnglish = false;
    for (let i = 0; i < parts.length; i++) {
      let p = parts[i];
      if (i % 2 === 0) {
        if (toEnglish && p.trim()) {
          p = "English";
          toEnglish = false;
        }
        parts[i] = say(p, page.file);
        continue;
      }
      if (/^<html\b/.test(p)) p = p.replace(/lang="[^"]*"/, `lang="${lang.code}"`);
      // The switch in the top bar leads back to English from here.
      else if (/class="nav-lang"/.test(p)) {
        p = `<a class="nav-lang" href="/${page.path}" data-lang="en" lang="en">`;
        toEnglish = true;
      } else if (/^<a\b/.test(p) && /data-lang=/.test(p)) {
        p = p.replace(' aria-current="page"', "");
        if (p.includes(`data-lang="${lang.dir}"`)) p = p.replace(/>$/, ' aria-current="page">');
      } else if (/^<a\b/.test(p)) {
        p = p.replace(/href="\/(#[^"]*)?"/, (_, hash = "") => `href="/${lang.dir}/${hash}"`);
        for (const other of PAGES) if (other.path) p = p.replace(`href="/${other.path}"`, `href="/${lang.dir}/${other.path}"`);
      } else if (/rel="canonical"|property="og:url"/.test(p)) {
        p = p.replace("https://tiri.build/", `https://tiri.build/${lang.dir}/`);
      } else if (p === '<script src="/app.js" defer>') {
        p = `<script src="/${lang.dir}/strings.js" defer></script>\n${p}`;
      }
      p = p.replace(/\b(aria-label|alt)="([^"]+)"/g, (_, name, value) => `${name}="${say(value, page.file)}"`);
      if (/^<meta\b/.test(p)) p = p.replace(/\bcontent="([^"]+)"/, (all, value) => (find(value) === null ? all : `content="${words[value]}"`));
      parts[i] = p;
    }
    write(join(out, page.file), parts.join(""));
  }

  // What app.js draws: every key it asks for by name, and any other key that appears in it (a workspace's
  // name, say, which is looked up when it's drawn).
  const table = {};
  for (const key of appKeys) {
    const value = find(key);
    if (value === null) miss(key, "app.js");
    else table[key] = value;
  }
  for (const key of Object.keys(words)) {
    if (!(key in table) && key.trim().length > 1 && (appSource.includes(`"${key}"`) || appSource.includes(`'${key}'`))) table[key] = find(key);
  }
  write(join(out, "strings.js"), `window.TIRI_STRINGS = ${JSON.stringify(table, null, 1)};\n`);

  const unused = Object.keys(words).filter((k) => !used.has(k));
  for (const [text, where] of missing) console.error(`${lang.code}: no translation, ${where}: ${JSON.stringify(text)}`);
  for (const key of unused) console.error(`${lang.code}: nothing uses ${JSON.stringify(key)}`);
  problems += missing.size + unused.length;
  console.log(`${lang.code}: ${PAGES.length} pages, ${used.size} pieces of text`);
}
if (problems && strict) process.exit(1);
