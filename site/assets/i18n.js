/* Aster 官网 —— 运行时语言辅助。
   各语言页面已由 scripts/build-site-i18n.mjs 生成为独立的静态 HTML（/、/en/、/ja/、/de/、/fr/），
   这个脚本不再替换正文，只做三件事：
   1. window.asterT：给 site.js 动态生成的文案取译文（表由生成脚本注入为 window.ASTER_STRINGS）；
   2. 语言菜单（<details>）的点外部关闭、Esc 关闭，并记住用户的选择；
   3. 用户偏好的语言与当前页不同时，显示一条可关闭的切换建议。
   不做自动跳转：同一网址必须对爬虫和分享链接始终给出同一语言。 */
(function () {
  "use strict";

  // MARK: - 动态文案

  var STRINGS = window.ASTER_STRINGS || {};

  /* 取当前页语言的译文；中文页或表里没有时原样返回中文 */
  window.asterT = function (zh) {
    return Object.prototype.hasOwnProperty.call(STRINGS, zh) ? STRINGS[zh] : zh;
  };

  // MARK: - 语言与偏好

  var PAGES = { zh: "/", en: "/en/", ja: "/ja/", de: "/de/", fr: "/fr/" };
  // 用新键：旧版脚本会把自动探测的结果也写进 "aster-lang"，那不代表用户的明确选择
  var STORE = "aster-site-lang";

  /* BCP 47 标签 → 站点语言代码；不支持的语言返回 null */
  function codeOf(tag) {
    var t = String(tag || "").toLowerCase();
    var codes = ["zh", "en", "ja", "de", "fr"];
    for (var i = 0; i < codes.length; i++) {
      if (t === codes[i] || t.indexOf(codes[i] + "-") === 0) return codes[i];
    }
    return null;
  }

  /* 读写用户最近一次明确选择的语言；隐私模式等场景下存储不可用时静默忽略 */
  function readChoice() {
    try { return window.localStorage.getItem(STORE); } catch (e) { return null; }
  }
  function saveChoice(code) {
    try { window.localStorage.setItem(STORE, code); } catch (e) { /* 忽略 */ }
  }

  var current = codeOf(document.documentElement.lang) || "zh";

  // MARK: - 语言菜单

  (function () {
    var menu = document.getElementById("lang-menu");
    if (!menu) return;
    var summary = menu.querySelector("summary");

    menu.addEventListener("click", function (event) {
      var link = event.target.closest && event.target.closest("a[data-lang]");
      if (link) saveChoice(link.getAttribute("data-lang"));
    });
    document.addEventListener("click", function (event) {
      if (menu.open && !menu.contains(event.target)) menu.open = false;
    });
    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape" || !menu.open) return;
      menu.open = false;
      if (summary) summary.focus();
    });
  })();

  // MARK: - 切换建议

  /* 建议条用访客偏好的那种语言书写，访客才看得懂 */
  var MESSAGES = {
    zh: { text: "本页有简体中文版。", go: "切换到中文", close: "关闭" },
    en: { text: "This page is available in English.", go: "Switch to English", close: "Dismiss" },
    ja: { text: "このページには日本語版があります。", go: "日本語で見る", close: "閉じる" },
    de: { text: "Diese Seite gibt es auch auf Deutsch.", go: "Auf Deutsch lesen", close: "Schließen" },
    fr: { text: "Cette page existe aussi en français.", go: "Lire en français", close: "Fermer" },
  };

  /* 偏好语言：明确选择过就用选择，否则取浏览器语言列表里第一个本站支持的 */
  function preferred() {
    var choice = readChoice();
    if (choice && PAGES[choice]) return choice;
    var list = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language];
    for (var i = 0; i < list.length; i++) {
      var code = codeOf(list[i]);
      if (code) return code;
    }
    return null;
  }

  (function () {
    var want = preferred();
    if (!want || want === current) return;
    var msg = MESSAGES[want];

    var bar = document.createElement("div");
    bar.className = "lang-suggest";
    bar.setAttribute("role", "region");
    bar.setAttribute("aria-label", msg.text);
    bar.lang = want;

    var text = document.createElement("span");
    text.textContent = msg.text;
    var go = document.createElement("a");
    go.href = PAGES[want] + window.location.hash;
    go.hreflang = want;
    go.textContent = msg.go;
    var close = document.createElement("button");
    close.type = "button";
    close.setAttribute("aria-label", msg.close);
    close.textContent = "×";

    go.addEventListener("click", function () { saveChoice(want); });
    // 关闭等于选择留在当前语言，之后不再提示
    close.addEventListener("click", function () {
      saveChoice(current);
      bar.remove();
    });

    bar.appendChild(text);
    bar.appendChild(go);
    bar.appendChild(close);
    document.body.appendChild(bar);
  })();
})();
