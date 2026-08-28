/* Aster 官网 —— 终端打字动画 */

/* 小工具：进入视口才运行，离开即暂停 */
function asterOnVisible(el, start, stop) {
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { start(); } else { stop(); }
      });
    }, { threshold: 0.25 });
    io.observe(el);
  } else {
    start();
  }
}

(function () {
  "use strict";

  var pane = document.getElementById("term-pane");
  if (!pane) return;

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* 一轮演示脚本：cmd 逐字输入，out 按延时逐行输出 */
  var SCRIPT = [
    { type: "cmd", text: "./scripts/build-app.sh" },
    { type: "out", html: '<span class="dim">▸ Compiling AsterCore · 312 sources</span>', delay: 750 },
    { type: "out", html: '<span class="dim">▸ Linking GhosttyKit.xcframework</span>', delay: 950 },
    { type: "out", html: '<span class="ok">✓</span> Signed Aster.app <span class="dim">(Developer ID)</span>', delay: 1100 },
    { type: "gap" },
    { type: "pause", delay: 700 },
    { type: "cmd", text: "open dist/Aster.app" },
    { type: "out", html: '<span class="dim">→ Aster.app launched</span>', delay: 650 },
    { type: "pause", delay: 3200 }
  ];

  function contextLine() {
    var el = document.createElement("div");
    el.innerHTML = '<span class="dir">aster</span><span class="dim"> on </span><span class="ok">⎇ main</span>';
    return el;
  }

  function promptLine() {
    var el = document.createElement("div");
    var p = document.createElement("span");
    p.className = "prompt";
    p.textContent = "❯ ";
    var typed = document.createElement("span");
    typed.className = "typed";
    var cursor = document.createElement("span");
    cursor.className = "cursor";
    el.appendChild(p);
    el.appendChild(typed);
    el.appendChild(cursor);
    return { line: el, typed: typed, cursor: cursor };
  }

  /* 减少动态效果：直接渲染完整静态记录 */
  if (reduced) {
    pane.innerHTML = "";
    pane.appendChild(contextLine());
    SCRIPT.forEach(function (step) {
      var el;
      if (step.type === "cmd") {
        el = document.createElement("div");
        el.innerHTML = '<span class="prompt">❯</span> ' + step.text;
        pane.appendChild(el);
      } else if (step.type === "out") {
        el = document.createElement("div");
        el.innerHTML = step.html;
        pane.appendChild(el);
      } else if (step.type === "gap") {
        el = document.createElement("div");
        el.className = "gap";
        pane.appendChild(el);
      }
    });
    var last = promptLine();
    last.cursor.style.animation = "none";
    pane.appendChild(last.line);
    return;
  }

  var timer = null;
  var running = false;

  function wait(ms, fn) { timer = setTimeout(fn, ms); }

  function typeInto(entry, text, done) {
    var i = 0;
    (function tick() {
      if (i >= text.length) { done(); return; }
      entry.typed.textContent += text.charAt(i);
      i += 1;
      wait(45 + Math.random() * 75, tick);
    })();
  }

  function runFrom(index, entry) {
    if (index >= SCRIPT.length) {
      /* 一轮结束：清屏重来 */
      pane.innerHTML = "";
      pane.appendChild(contextLine());
      wait(400, function () { runFrom(0, null); });
      return;
    }
    var step = SCRIPT[index];

    if (step.type === "cmd") {
      var e = promptLine();
      pane.appendChild(e.line);
      wait(500, function () {
        typeInto(e, step.text, function () {
          wait(380, function () {
            e.cursor.remove(); /* 回车执行 */
            runFrom(index + 1, null);
          });
        });
      });
      return;
    }

    if (step.type === "out") {
      wait(step.delay, function () {
        var el = document.createElement("div");
        el.innerHTML = step.html;
        pane.appendChild(el);
        runFrom(index + 1, null);
      });
      return;
    }

    if (step.type === "gap") {
      var g = document.createElement("div");
      g.className = "gap";
      pane.appendChild(g);
      runFrom(index + 1, null);
      return;
    }

    /* pause */
    wait(step.delay, function () { runFrom(index + 1, null); });
  }

  function start() {
    if (running) return;
    running = true;
    pane.innerHTML = "";
    pane.appendChild(contextLine());
    wait(600, function () { runFrom(0, null); });
  }

  function stop() {
    running = false;
    if (timer) { clearTimeout(timer); timer = null; }
  }

  asterOnVisible(pane, start, stop);
})();

/* ============ 演示二：本机智能补全 ============ */
(function () {
  "use strict";

  var box = document.getElementById("ac-demo");
  if (!box) return;

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var CMD_ICON =
    '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#84A957" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 7l5 5-5 5"></path><path d="M13 17h6"></path></svg>';
  var BRANCH_ICON =
    '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#84A957" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="2.6"></circle><circle cx="6" cy="18" r="2.6"></circle><circle cx="18" cy="8" r="2.6"></circle><path d="M6 8.6v6.8"></path><path d="M18 10.6c0 3-3 4.4-6 4.4"></path></svg>';

  /* 候选描述来自 Fig 命令规格（英文原文） */
  var SUB = [
    { name: "checkout", hi: "ch", desc: "Switch branches or restore working tree files" },
    { name: "cherry-pick", hi: "ch", desc: "Apply the changes introduced by some existing commits" },
    { name: "check-ignore", hi: "ch", desc: "Debug gitignore / exclude files" },
  ];
  var BRANCHES = [
    { name: "main", hi: "", desc: "当前仓库分支" },
    { name: "feature/file-pane", hi: "", desc: "当前仓库分支" },
    { name: "fix/tab-spinner", hi: "", desc: "当前仓库分支" },
  ];

  function popup(items, sel, icon) {
    var tr = window.asterT || function (s) { return s; };
    var el = document.createElement("div");
    el.className = "ac-pop";
    items.forEach(function (it, i) {
      var row = document.createElement("div");
      row.className = "ac-row" + (i === sel ? " sel" : "");
      var name = it.hi
        ? '<b>' + it.hi + "</b>" + it.name.slice(it.hi.length)
        : it.name;
      row.innerHTML = icon + '<span class="ac-name">' + name + '</span><span class="ac-desc">' + tr(it.desc) + "</span>";
      el.appendChild(row);
    });
    var t = window.asterT || function (s) { return s; };
    var hint = document.createElement("div");
    hint.className = "ac-hint";
    hint.innerHTML =
      "<span>" + t("↑↓ 选择") + "</span><span>" + t("Tab 补全") + "</span><span>" + t("Esc 关闭") + "</span>";
    el.appendChild(hint);
    return el;
  }

  function promptLine() {
    var line = document.createElement("div");
    var p = document.createElement("span");
    p.className = "prompt";
    p.textContent = "❯ ";
    var typed = document.createElement("span");
    var cur = document.createElement("span");
    cur.className = "cursor";
    line.appendChild(p);
    line.appendChild(typed);
    line.appendChild(cur);
    return { line: line, typed: typed, cur: cur };
  }

  /* 关闭动态效果：静态展示弹层本身 */
  if (reduced) {
    box.innerHTML = "";
    var s = promptLine();
    s.typed.textContent = "git ch";
    s.cur.style.animation = "none";
    box.appendChild(s.line);
    box.appendChild(popup(SUB, 0, CMD_ICON));
    return;
  }

  var timer = null;
  var running = false;

  function wait(ms, fn) { timer = setTimeout(fn, ms); }

  function typeInto(entry, text, done) {
    var i = 0;
    (function tick() {
      if (i >= text.length) { done(); return; }
      entry.typed.textContent += text.charAt(i);
      i += 1;
      wait(55 + Math.random() * 80, tick);
    })();
  }

  function round() {
    box.innerHTML = "";
    var e = promptLine();
    box.appendChild(e.line);

    wait(700, function () {
      typeInto(e, "git ch", function () {
        var pop = popup(SUB, 0, CMD_ICON);
        wait(180, function () {
          box.appendChild(pop);           /* 弹出候选 */
          wait(1300, function () {        /* Tab：补全子命令 */
            pop.remove();
            e.typed.textContent = "git checkout ";
            var pop2 = popup(BRANCHES, 0, BRANCH_ICON);
            wait(260, function () {
              box.appendChild(pop2);      /* 弹出分支候选 */
              wait(900, function () {     /* ↓ 移到第二项 */
                pop2.remove();
                pop2 = popup(BRANCHES, 1, BRANCH_ICON);
                box.appendChild(pop2);
                wait(1100, function () {  /* Tab：补全分支 */
                  pop2.remove();
                  e.typed.textContent = "git checkout feature/file-pane";
                  wait(600, function () { /* 回车执行 */
                    e.cur.remove();
                    var out = document.createElement("div");
                    out.textContent = "Switched to branch 'feature/file-pane'";
                    box.appendChild(out);
                    wait(3200, function () { if (running) round(); });
                  });
                });
              });
            });
          });
        });
      });
    });
  }

  function start() {
    if (running) return;
    running = true;
    round();
  }

  function stop() {
    running = false;
    if (timer) { clearTimeout(timer); timer = null; }
  }

  asterOnVisible(box, start, stop);
})();

/* ============ 演示三：多主题即时切换 ============ */
(function () {
  "use strict";

  var term = document.getElementById("theme-demo");
  var chipsBox = document.getElementById("theme-chips");
  if (!term || !chipsBox) return;

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* 色值逐项取自 Sources/AsterCore/BuiltInThemeTable.swift */
  var THEMES = [
    { name: "Ayu Light",   bg: "#FCFCFC", fg: "#5C6166", dim: "#8E8E93", red: "#E7666A", green: "#80AB24", yellow: "#EBA54D", blue: "#4196DF", accent: "#4196DF" },
    { name: "Paper",       bg: "#FCFBF9", fg: "#1A1A1A", dim: "#8C8A80", red: "#A33A3A", green: "#2B5A38", yellow: "#A85A20", blue: "#4A7A8A", accent: "#2B5A38" },
    { name: "Ayu Dark",    bg: "#0A0E14", fg: "#B3B1AD", dim: "#686868", red: "#EA6C73", green: "#91B362", yellow: "#F9AF4F", blue: "#53BDFA", accent: "#53BDFA" },
    { name: "Nord",        bg: "#2E3440", fg: "#F1F6FF", dim: "#7B8294", red: "#BF616A", green: "#A3BE8C", yellow: "#EBCB8B", blue: "#81A1C1", accent: "#88C0D0" },
    { name: "Dracula",     bg: "#282A36", fg: "#F8F8F2", dim: "#6272A4", red: "#FF5555", green: "#50FA7B", yellow: "#F1FA8C", blue: "#BD93F9", accent: "#FF79C6" },
    { name: "Tokyo Night", bg: "#1A1B26", fg: "#C0CAF5", dim: "#787CA0", red: "#F7768E", green: "#9ECE6A", yellow: "#E0AF68", blue: "#7AA2F7", accent: "#7DCFFF" },
  ];

  var current = -1;
  var timer = null;
  var running = false;
  var chips = [];

  function apply(i) {
    if (i === current) return;
    current = i;
    var t = THEMES[i];
    term.style.setProperty("--t-bg", t.bg);
    term.style.setProperty("--t-fg", t.fg);
    term.style.setProperty("--t-dim", t.dim);
    term.style.setProperty("--t-red", t.red);
    term.style.setProperty("--t-green", t.green);
    term.style.setProperty("--t-yellow", t.yellow);
    term.style.setProperty("--t-blue", t.blue);
    term.style.setProperty("--t-accent", t.accent);
    chips.forEach(function (c, j) {
      c.classList.toggle("on", j === i);
      c.setAttribute("aria-selected", j === i ? "true" : "false");
    });
  }

  THEMES.forEach(function (t, i) {
    var chip = document.createElement("button");
    chip.type = "button";
    chip.className = "theme-chip";
    chip.setAttribute("role", "tab");
    chip.innerHTML = '<span class="dot" style="background:' + t.bg + '"></span>' + t.name;
    chip.addEventListener("click", function () {
      apply(i);
      restart(); /* 手动选择后重新计时 */
    });
    chipsBox.appendChild(chip);
    chips.push(chip);
  });

  function tick() {
    timer = setTimeout(function () {
      apply((current + 1) % THEMES.length);
      tick();
    }, 2600);
  }

  function restart() {
    if (timer) clearTimeout(timer);
    if (running && !reduced) tick();
  }

  function start() {
    if (running) return;
    running = true;
    if (current < 0) apply(0);
    if (!reduced) tick();       /* 关闭动态效果：不自动轮播，仍可点选 */
  }

  function stop() {
    running = false;
    if (timer) { clearTimeout(timer); timer = null; }
  }

  asterOnVisible(term, start, stop);
})();
