// Sends a Chinese reader to the Chinese page, once, before anything is drawn. A language chosen from the
// footer or the top bar is remembered in this browser and wins from then on. Nothing leaves the browser.
(() => {
  "use strict";
  const KEY = "tiri-language";
  const PAGES = ["zh-hans", "zh-hant"];
  let chosen = null;
  try {
    chosen = localStorage.getItem(KEY);
  } catch {}
  addEventListener("click", (e) => {
    const a = e.target.closest && e.target.closest("a[data-lang]");
    if (!a) return;
    try {
      localStorage.setItem(KEY, a.dataset.lang);
    } catch {}
  });
  if (document.documentElement.lang !== "en") return;
  let want = chosen;
  if (!want) {
    const first = (navigator.language || "").toLowerCase();
    if (first.startsWith("zh")) want = /^zh-(hant|tw|hk|mo)/.test(first) ? "zh-hant" : "zh-hans";
  }
  if (PAGES.includes(want)) location.replace(`/${want}${location.pathname}${location.search}${location.hash}`);
})();
