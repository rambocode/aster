/* Aster 官网交互脚本：动效开关、滚动入场、导航、命令补全演示、真实截图、主题演示与 GitHub star 数。
   无需构建；每个模块独立 IIFE，缺少所需元素时静默跳过。 */
(function () {
  "use strict";

  // MARK: - 共享工具

  var root = document.documentElement;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  /* 取当前语言文案；i18n.js 未加载时原样返回中文 */
  function t(zh) {
    return typeof window.asterT === "function" ? window.asterT(zh) : zh;
  }

  /* 按 ID 取元素 */
  function byId(id) {
    return document.getElementById(id);
  }

  /* querySelectorAll 转数组，便于 forEach */
  function qsa(selector, scope) {
    return Array.prototype.slice.call((scope || document).querySelectorAll(selector));
  }

  /* 全局动效是否处于暂停状态（以 html 上的 class 为唯一真值） */
  function motionPaused() {
    return root.classList.contains("motion-paused");
  }

  /* 监听媒体查询变化；兼容 Safari 14 以前只有 addListener 的实现 */
  function onMediaChange(mq, fn) {
    if (mq.addEventListener) mq.addEventListener("change", fn);
    else if (mq.addListener) mq.addListener(fn);
  }

  /* 写入按钮文字；按钮内有 [data-label] 子元素时只改它，保留图标 */
  function setButtonLabel(button, text) {
    var target = button.querySelector("[data-label]") || button;
    if (target.textContent !== text) target.textContent = text;
  }

  /* 元素进入视口时调用 start，离开时调用 stop；不支持 IntersectionObserver 时直接 start */
  function onVisible(el, start, stop, threshold) {
    if (!("IntersectionObserver" in window)) { start(); return; }
    new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) start(); else stop();
      });
    }, { threshold: threshold }).observe(el);
  }

  // MARK: - 全局动效开关

  (function () {
    var button = byId("motion-toggle");
    var paused = reduced.matches;

    /* 同步 class、按钮状态，并按需广播 aster:motion */
    function setPaused(next, notify) {
      paused = next;
      root.classList.toggle("motion-paused", paused);
      if (button) {
        button.setAttribute("aria-pressed", String(paused));
        setButtonLabel(button, t(paused ? "播放动效" : "暂停动效"));
      }
      if (notify) {
        window.dispatchEvent(new CustomEvent("aster:motion", { detail: { paused: paused } }));
      }
    }

    // 初始化时其他模块还没挂监听，不广播；它们启动时直接读 html 上的 class
    setPaused(paused, false);

    if (button) {
      button.addEventListener("click", function () { setPaused(!paused, true); });
    }
    // 用户在演示里主动点播放或重播，视为同意恢复全局动效
    window.addEventListener("aster:demo-play", function () {
      if (paused) setPaused(false, true);
    });
    onMediaChange(reduced, function () { setPaused(reduced.matches, true); });
  })();

  // MARK: - 滚动入场

  (function () {
    var items = qsa("[data-reveal]");
    if (!items.length) return;

    /* 一次性展示所有尚未入场的元素 */
    function revealAll() {
      items.forEach(function (el) { el.classList.add("in"); });
    }

    if (reduced.matches || motionPaused() || !("IntersectionObserver" in window)) {
      revealAll();
      return;
    }

    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("in");
        observer.unobserve(entry.target);
      });
    }, { threshold: 0.15 });
    items.forEach(function (el) { observer.observe(el); });

    // 暂停动效后不应再有元素淡入，剩余的直接展示
    window.addEventListener("aster:motion", function (event) {
      if (!event.detail || !event.detail.paused) return;
      observer.disconnect();
      revealAll();
    });
  })();

  // MARK: - 移动端导航

  (function () {
    var button = byId("menu-button");
    var nav = byId("mobile-nav");
    if (!button || !nav) return;

    // 只有 HTML 原本用 aria-label 命名按钮时才维护它，避免覆盖可见文字
    var managesLabel = button.hasAttribute("aria-label");

    /* 打开或关闭菜单，同步 aria 状态 */
    function setOpen(open) {
      nav.hidden = !open;
      button.setAttribute("aria-expanded", String(open));
      if (managesLabel) button.setAttribute("aria-label", t(open ? "关闭导航" : "打开导航"));
    }

    button.addEventListener("click", function () { setOpen(nav.hidden); });
    nav.addEventListener("click", function (event) {
      if (event.target.closest && event.target.closest("a")) setOpen(false);
    });
    document.addEventListener("keydown", function (event) {
      if (event.key !== "Escape" || nav.hidden) return;
      setOpen(false);
      button.focus();
    });
    var desktop = window.matchMedia("(min-width: 861px)");
    onMediaChange(desktop, function () { if (desktop.matches) setOpen(false); });
  })();

  // MARK: - 导航高亮

  (function () {
    // 只保留目标 section 真实存在的锚点链接
    var pairs = qsa('.nav-links a[href^="#"]').map(function (link) {
      var id = decodeURIComponent(link.getAttribute("href").slice(1));
      var section = id ? document.getElementById(id) : null;
      return section && section.matches("section[id]") ? { link: link, section: section } : null;
    }).filter(Boolean);
    if (!pairs.length) return;

    var pending = false;

    /* 取视口上部 30% 线之上最后一个 section 作为当前位置；滚到底时取最后一个 */
    function update() {
      pending = false;
      var line = window.innerHeight * 0.3;
      var atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 2;
      var currentId = null;
      pairs.forEach(function (pair) {
        if (pair.section.getBoundingClientRect().top <= line) currentId = pair.section.id;
      });
      if (atBottom) currentId = pairs[pairs.length - 1].section.id;
      pairs.forEach(function (pair) {
        var active = pair.section.id === currentId;
        pair.link.classList.toggle("active", active);
        if (active) pair.link.setAttribute("aria-current", "location");
        else pair.link.removeAttribute("aria-current");
      });
    }

    /* 用 rAF 合并同一帧内的多次滚动事件 */
    function schedule() {
      if (pending) return;
      pending = true;
      window.requestAnimationFrame(update);
    }

    window.addEventListener("scroll", schedule, { passive: true });
    window.addEventListener("resize", schedule);
    update();
  })();

  // MARK: - 首屏命令补全演示

  /* 独立设计演示：只改网页中的示例文字，绝不执行命令或连接终端。 */
  (function () {
    var host = byId("command-demo");
    var input = byId("demo-input");
    var menu = byId("completion-list");
    var output = byId("command-output");
    if (!host || !input || !menu || !output) return;
    var toggle = byId("toggle-demo");
    var replayButton = byId("replay-demo");
    var announcement = byId("demo-announcement");
    var scenarioButtons = qsa("[data-scenario]");

    // 时间轴参数（毫秒）。一轮约 9 秒；打字从 120ms 开始，保证打开页面 2 秒内能看到。
    var CYCLE = 9000;
    var TYPE_START = 120;
    var TYPE_STEP = 85;
    var TYPE_SETTLE = 150;
    var SUGGEST_HOLD = 2350;
    var ACCEPT_STEP = 40;
    var OUTPUT_DELAY = 250;
    // 减少动效时停留的静态帧：两个场景在这一刻都处于候选列表展开状态
    var STATIC_FRAME = 1600;

    /* 场景数据；desc 为中文时经 asterT 翻译，Fig 规格英文原文翻译后保持不变 */
    var SCENARIOS = {
      git: {
        prefix: "git ch",
        full: "git checkout feature/file-pane",
        output: "Switched to branch 'feature/file-pane'",
        options: [
          { label: "checkout", desc: "Switch branches or restore working tree files", completion: "git checkout" },
          { label: "cherry-pick", desc: "Apply the changes introduced by some existing commits", completion: "git cherry-pick" },
          { label: "check-ignore", desc: "Debug gitignore / exclude files", completion: "git check-ignore" }
        ]
      },
      build: {
        prefix: "./scripts/bu",
        full: "./scripts/build-app.sh",
        output: "▸ Compiling AsterCore\n▸ Linking GhosttyKit.xcframework\n✓ Signed Aster.app (Developer ID)",
        options: [
          { label: "build-app.sh", desc: "打包并签名 Aster.app", completion: "./scripts/build-app.sh" },
          { label: "build-dmg.sh", desc: "生成并校验 DMG", completion: "./scripts/build-dmg.sh" },
          { label: "build-ssh-runtime.sh", desc: "构建原生 SSH 运行时", completion: "./scripts/build-ssh-runtime.sh" }
        ]
      }
    };

    /* 按前缀与完整命令长度算出各阶段起点，让不同长度的场景都落在同一轮时长内 */
    function timeline(sample) {
      var suggest = TYPE_START + sample.prefix.length * TYPE_STEP + TYPE_SETTLE;
      var accept = suggest + SUGGEST_HOLD;
      var result = accept + (sample.full.length - sample.prefix.length) * ACCEPT_STEP;
      return { suggest: suggest, accept: accept, result: result, output: result + OUTPUT_DELAY };
    }
    Object.keys(SCENARIOS).forEach(function (key) {
      SCENARIOS[key].tl = timeline(SCENARIOS[key]);
    });

    var pressed = scenarioButtons.filter(function (b) { return b.getAttribute("aria-pressed") === "true"; })[0];
    var scenario = pressed && SCENARIOS[pressed.dataset.scenario] ? pressed.dataset.scenario : "git";
    var elapsed = reduced.matches ? STATIC_FRAME : 0;
    var userPaused = reduced.matches;
    var globallyPaused = motionPaused();
    var reducedPlaybackAllowed = false;
    var inView = true;
    var lastTime = null;
    var frameID = 0;
    var cycles = 0;
    var selectionOverride = null; // 方向键手动选中的候选序号
    var manualChoice = null;      // 用户接受的候选序号
    var dismissed = false;        // 用户按 Esc 关闭了候选列表
    var lastRender = "";
    var announceTimer = 0;

    /* 演示是否应当推进时间轴 */
    function running() {
      return !userPaused && !globallyPaused && !document.hidden && inView &&
        (!reduced.matches || reducedPlaybackAllowed);
    }

    /* 用户接受补全后的说明文字：同时用于输出区与读屏播报 */
    function acceptedMessage(command) {
      return t("已补全为 ") + command + t("。这是演示，没有执行命令。");
    }

    /* 根据时间轴位置计算该时刻的界面状态（纯函数，便于暂停后原样恢复） */
    function stateAt(time) {
      var sample = SCENARIOS[scenario];
      var tl = sample.tl;
      if (manualChoice !== null) {
        var command = sample.options[manualChoice].completion;
        return { text: command, phase: "result", options: false, selected: manualChoice, output: "✓ " + acceptedMessage(command) };
      }
      if (dismissed) {
        return { text: sample.prefix, phase: "typing", options: false, selected: 0, output: "" };
      }
      if (time < tl.suggest) {
        var typed = Math.max(0, Math.min(sample.prefix.length, Math.floor((time - TYPE_START) / TYPE_STEP)));
        return { text: sample.prefix.slice(0, typed), phase: "typing", options: false, selected: 0, output: "" };
      }
      if (time < tl.accept) {
        // 自动播放时中途把高亮移到第二项再移回，模拟方向键浏览
        var offset = time - tl.suggest;
        var auto = offset > 850 && offset < 1550 ? 1 : 0;
        return { text: sample.prefix, phase: "suggestions", options: true, selected: selectionOverride !== null ? selectionOverride : auto, output: "" };
      }
      if (time < tl.result) {
        var count = sample.prefix.length + Math.floor((time - tl.accept) / ACCEPT_STEP);
        return { text: sample.full.slice(0, count), phase: "accepting", options: false, selected: 0, output: "" };
      }
      return { text: sample.full, phase: "result", options: false, selected: 0, output: time >= tl.output ? sample.output : "" };
    }

    /* 按当前场景重建候选按钮 */
    function makeOptions() {
      while (menu.firstChild) menu.removeChild(menu.firstChild);
      SCENARIOS[scenario].options.forEach(function (item, index) {
        var button = document.createElement("button");
        button.type = "button";
        button.className = "completion-option";
        button.id = "completion-" + scenario + "-" + index;
        button.setAttribute("role", "option");
        button.setAttribute("aria-selected", "false");
        button.tabIndex = -1;
        var symbol = document.createElement("span");
        symbol.className = "option-symbol";
        symbol.setAttribute("aria-hidden", "true");
        symbol.textContent = "›";
        var label = document.createElement("span");
        label.className = "option-label";
        label.textContent = item.label;
        var description = document.createElement("span");
        description.className = "option-description";
        description.textContent = t(item.desc);
        button.appendChild(symbol);
        button.appendChild(label);
        button.appendChild(description);
        button.addEventListener("click", function () { acceptOption(index); });
        menu.appendChild(button);
      });
    }

    /* 把当前状态写入 DOM；状态签名不变时跳过，避免每帧重复改 DOM */
    function render() {
      var state = stateAt(elapsed);
      var paused = userPaused || globallyPaused;
      var signature = [scenario, state.text, state.phase, state.options, state.selected, state.output, paused].join("\u0001");
      if (signature === lastRender) return;
      lastRender = signature;

      input.value = state.text;
      input.style.width = Math.max(0.1, state.text.length) + "ch";
      input.setAttribute("aria-expanded", String(state.options));
      menu.hidden = !state.options;
      qsa('[role="option"]', menu).forEach(function (button, index) {
        button.setAttribute("aria-selected", String(state.options && index === state.selected));
      });
      if (state.options) input.setAttribute("aria-activedescendant", "completion-" + scenario + "-" + state.selected);
      else input.removeAttribute("aria-activedescendant");
      output.textContent = state.output;
      host.setAttribute("data-phase", state.phase);
      host.setAttribute("data-cycle", String(cycles));

      if (toggle) {
        toggle.setAttribute("aria-pressed", String(paused));
        setButtonLabel(toggle, t(paused ? "播放" : "暂停"));
      }
      // 步骤指示只有三格，接受补全的过渡阶段归到「候选」
      var step = state.phase === "accepting" ? "suggestions" : state.phase;
      qsa("[data-step]").forEach(function (el) {
        el.classList.toggle("active", el.getAttribute("data-step") === step);
      });
    }

    /* rAF 时间轴：单帧最多推进 100ms，防止切回标签页时跳过整段动画 */
    function tick(now) {
      frameID = 0;
      if (!running()) { lastTime = null; return; }
      if (lastTime !== null) elapsed += Math.min(now - lastTime, 100);
      lastTime = now;
      if (elapsed >= CYCLE) {
        elapsed %= CYCLE;
        cycles += 1;
        selectionOverride = null;
        manualChoice = null;
        dismissed = false;
      }
      render();
      frameID = window.requestAnimationFrame(tick);
    }

    /* 状态变化后重置时钟：立即渲染，并按是否运行决定是否继续排帧 */
    function syncClock() {
      if (frameID) window.cancelAnimationFrame(frameID);
      frameID = 0;
      lastTime = null;
      render();
      if (running()) frameID = window.requestAnimationFrame(tick);
    }

    /* 读屏播报；先清空再写入，保证相同文字也会被重新播报 */
    function announce(text) {
      if (!announcement) return;
      window.clearTimeout(announceTimer);
      announcement.textContent = "";
      announceTimer = window.setTimeout(function () { announcement.textContent = text; }, 60);
    }

    /* 从头播放；属于用户主动操作，减少动效时也允许运行 */
    function replay() {
      elapsed = 0;
      manualChoice = null;
      selectionOverride = null;
      dismissed = false;
      userPaused = false;
      globallyPaused = false;
      reducedPlaybackAllowed = true;
      window.dispatchEvent(new Event("aster:demo-play"));
      syncClock();
    }

    /* 接受某个候选：停在结果并播报，说明没有真正执行命令 */
    function acceptOption(index) {
      manualChoice = index;
      selectionOverride = null;
      dismissed = false;
      userPaused = true;
      syncClock();
      announce(acceptedMessage(SCENARIOS[scenario].options[index].completion));
      try { input.focus({ preventScroll: true }); } catch (e) { input.focus(); }
    }

    // 键盘交互：方向键改选、Tab/Enter 接受、Esc 关闭；列表关闭时 Tab 保持默认焦点移动
    input.addEventListener("keydown", function (event) {
      var key = event.key;
      var count = SCENARIOS[scenario].options.length;
      var open = !menu.hidden;
      if (key === "ArrowDown" || key === "ArrowUp") {
        event.preventDefault();
        if (open) {
          var change = key === "ArrowDown" ? 1 : -1;
          selectionOverride = (stateAt(elapsed).selected + change + count) % count;
        } else {
          selectionOverride = 0;
        }
        manualChoice = null;
        dismissed = false;
        userPaused = true;
        elapsed = SCENARIOS[scenario].tl.suggest + 400;
        syncClock();
      } else if ((key === "Tab" || key === "Enter") && open) {
        event.preventDefault();
        acceptOption(stateAt(elapsed).selected);
      } else if (key === "Escape" && open) {
        event.preventDefault();
        event.stopPropagation();
        dismissed = true;
        selectionOverride = null;
        userPaused = true;
        syncClock();
      }
    });

    if (toggle) {
      toggle.addEventListener("click", function () {
        var willPlay = userPaused || globallyPaused;
        if (!willPlay) {
          userPaused = true;
          syncClock();
          return;
        }
        // 已手动接受或关闭列表时，继续播放等同于重播，避免从半截状态续播
        if (manualChoice !== null || dismissed) { replay(); return; }
        selectionOverride = null;
        userPaused = false;
        globallyPaused = false;
        reducedPlaybackAllowed = true;
        window.dispatchEvent(new Event("aster:demo-play"));
        syncClock();
      });
    }
    if (replayButton) replayButton.addEventListener("click", replay);

    scenarioButtons.forEach(function (button) {
      button.addEventListener("click", function () {
        var next = button.dataset.scenario;
        if (!SCENARIOS[next]) return;
        scenario = next;
        scenarioButtons.forEach(function (item) {
          item.setAttribute("aria-pressed", String(item === button));
        });
        if (announcement) announcement.textContent = "";
        makeOptions();
        replay();
      });
    });

    document.addEventListener("visibilitychange", syncClock);
    window.addEventListener("aster:motion", function (event) {
      globallyPaused = !!(event.detail && event.detail.paused);
      if (!globallyPaused) {
        userPaused = false;
        reducedPlaybackAllowed = true;
      }
      syncClock();
    });
    // 系统切换「减少动效」时回到静态帧或恢复自动播放
    onMediaChange(reduced, function () {
      userPaused = reduced.matches;
      reducedPlaybackAllowed = false;
      if (reduced.matches) {
        elapsed = STATIC_FRAME;
        manualChoice = null;
        selectionOverride = null;
        dismissed = false;
      }
      syncClock();
    });
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (entries) {
        inView = entries[entries.length - 1].isIntersecting;
        syncClock();
      }, { threshold: 0.12 }).observe(host);
    }

    makeOptions();
    syncClock();
  })();

  // MARK: - 真实截图切换与放大

  (function () {
    var realShot = byId("real-shot");
    if (!realShot) return;
    var caption = byId("shot-caption");
    var number = byId("shot-number");
    var openButton = byId("open-shot");
    var buttons = qsa("[data-shot]");

    var SHOTS = {
      workspace: {
        src: "/assets/shots/workspace.png",
        caption: "终端与 Markdown 文档，在同一个原生窗口里。",
        alt: "Aster 实际窗口：左侧标签栏、中间终端、右侧 Markdown 预览",
        number: "01 / 02"
      },
      terminal: {
        src: "/assets/shots/terminal.png",
        caption: "专注终端输出，保留目录与标签导航。",
        alt: "Aster 实际终端窗口，显示公开演示目录和配置文件",
        number: "02 / 02"
      }
    };

    var pressed = buttons.filter(function (b) { return b.getAttribute("aria-pressed") === "true"; })[0];
    var selected = pressed && SHOTS[pressed.dataset.shot] ? pressed.dataset.shot : "workspace";
    var request = 0;
    var failed = false;

    /* 写入当前截图的说明、替代文字与序号（不改 src，避免重复请求） */
    function renderText() {
      var shot = SHOTS[selected];
      realShot.alt = t(shot.alt);
      if (caption) caption.textContent = t(failed ? "截图暂时无法载入，请重新选择。" : shot.caption);
      if (number) number.textContent = shot.number;
    }

    /* 预载并解码图片；不支持 decode() 的浏览器退回 onload/onerror */
    function preload(src) {
      var image = new Image();
      image.src = src;
      if (image.decode) return image.decode();
      return new Promise(function (resolve, reject) {
        image.onload = resolve;
        image.onerror = reject;
      });
    }

    /* 移除再添加 class，强制重新触发切换动画 */
    function replayChangeAnimation() {
      if (!openButton) return;
      openButton.classList.remove("changing");
      void openButton.offsetWidth;
      openButton.classList.add("changing");
    }

    buttons.forEach(function (button) {
      button.addEventListener("click", function () {
        var key = button.dataset.shot;
        if (!SHOTS[key]) return;
        // 序号令牌：连点时只让最后一次点击生效，先到的旧结果直接丢弃
        var token = ++request;
        if (key === selected) {
          if (failed) { failed = false; renderText(); }
          return;
        }
        preload(SHOTS[key].src).then(function () {
          if (token !== request) return;
          selected = key;
          failed = false;
          realShot.src = SHOTS[key].src;
          renderText();
          buttons.forEach(function (item) {
            item.setAttribute("aria-pressed", String(item.dataset.shot === key));
          });
          replayChangeAnimation();
        }, function () {
          if (token !== request) return;
          failed = true;
          renderText();
        });
      });
    });

    renderText();

    // 放大查看：原生 <dialog>，关闭后焦点回到触发按钮
    var dialog = byId("shot-dialog");
    var dialogImage = byId("dialog-image");
    var closeButton = byId("close-dialog");
    if (!openButton) return;

    openButton.addEventListener("click", function () {
      var shot = SHOTS[selected];
      if (!dialog || typeof dialog.showModal !== "function" || !dialogImage) {
        window.open(shot.src, "_blank", "noopener");
        return;
      }
      dialogImage.src = shot.src;
      dialogImage.alt = t(shot.alt);
      dialog.showModal();
      if (closeButton) closeButton.focus();
    });
    if (!dialog) return;
    if (closeButton) closeButton.addEventListener("click", function () { dialog.close(); });
    dialog.addEventListener("close", function () {
      try { openButton.focus({ preventScroll: true }); } catch (e) { openButton.focus(); }
    });
    // 点击落在 dialog 自身且坐标在其矩形外，说明点的是背景遮罩
    dialog.addEventListener("click", function (event) {
      if (event.target !== dialog) return;
      var r = dialog.getBoundingClientRect();
      var outside = event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom;
      if (outside) dialog.close();
    });
  })();

  // MARK: - 多主题即时切换演示

  (function () {
    var term = byId("theme-demo");
    var chipsBox = byId("theme-chips");
    if (!term || !chipsBox) return;

    /* 色值逐项取自 Sources/AsterCore/BuiltInThemeTable.swift */
    var THEMES = [
      { name: "Ayu Light",   bg: "#FCFCFC", fg: "#5C6166", dim: "#8E8E93", red: "#E7666A", green: "#80AB24", yellow: "#EBA54D", blue: "#4196DF", accent: "#4196DF" },
      { name: "Paper",       bg: "#FCFBF9", fg: "#1A1A1A", dim: "#8C8A80", red: "#A33A3A", green: "#2B5A38", yellow: "#A85A20", blue: "#4A7A8A", accent: "#2B5A38" },
      { name: "Ayu Dark",    bg: "#0A0E14", fg: "#B3B1AD", dim: "#686868", red: "#EA6C73", green: "#91B362", yellow: "#F9AF4F", blue: "#53BDFA", accent: "#53BDFA" },
      { name: "Nord",        bg: "#2E3440", fg: "#F1F6FF", dim: "#7B8294", red: "#BF616A", green: "#A3BE8C", yellow: "#EBCB8B", blue: "#81A1C1", accent: "#88C0D0" },
      { name: "Dracula",     bg: "#282A36", fg: "#F8F8F2", dim: "#6272A4", red: "#FF5555", green: "#50FA7B", yellow: "#F1FA8C", blue: "#BD93F9", accent: "#FF79C6" },
      { name: "Tokyo Night", bg: "#1A1B26", fg: "#C0CAF5", dim: "#787CA0", red: "#F7768E", green: "#9ECE6A", yellow: "#E0AF68", blue: "#7AA2F7", accent: "#7DCFFF" }
    ];

    var current = -1;
    var timer = null;
    var running = false;
    var chips = [];
    // 减少动效时不自动轮播；用户通过全局开关主动恢复动效后才允许
    var autoAllowed = !reduced.matches;
    var paused = motionPaused();

    /* 应用第 i 个主题的 CSS 变量，并同步标签选中态 */
    function apply(i) {
      if (i === current) return;
      current = i;
      var theme = THEMES[i];
      ["bg", "fg", "dim", "red", "green", "yellow", "blue", "accent"].forEach(function (key) {
        term.style.setProperty("--t-" + key, theme[key]);
      });
      chips.forEach(function (chip, j) {
        chip.classList.toggle("on", j === i);
        chip.setAttribute("aria-selected", j === i ? "true" : "false");
      });
    }

    THEMES.forEach(function (theme, i) {
      var chip = document.createElement("button");
      chip.type = "button";
      chip.className = "theme-chip";
      chip.setAttribute("role", "tab");
      var dot = document.createElement("span");
      dot.className = "dot";
      dot.style.background = theme.bg;
      chip.appendChild(dot);
      chip.appendChild(document.createTextNode(theme.name));
      chip.addEventListener("click", function () {
        apply(i);
        restart(); // 手动选择后重新计时
      });
      chipsBox.appendChild(chip);
      chips.push(chip);
    });

    /* 每 2.6 秒轮换到下一个主题 */
    function tick() {
      timer = window.setTimeout(function () {
        apply((current + 1) % THEMES.length);
        tick();
      }, 2600);
    }

    /* 清掉旧计时器，满足条件时重新开始轮播 */
    function restart() {
      if (timer) { window.clearTimeout(timer); timer = null; }
      if (running && autoAllowed && !paused) tick();
    }

    /* 进入视口：首次应用默认主题并开始轮播 */
    function start() {
      if (running) return;
      running = true;
      if (current < 0) apply(0);
      restart();
    }

    /* 离开视口：停止轮播 */
    function stop() {
      running = false;
      if (timer) { window.clearTimeout(timer); timer = null; }
    }

    window.addEventListener("aster:motion", function (event) {
      paused = !!(event.detail && event.detail.paused);
      if (!paused) autoAllowed = true;
      restart();
    });
    onMediaChange(reduced, function () {
      autoAllowed = !reduced.matches;
      restart();
    });

    onVisible(term, start, stop, 0.25);
  })();

  // MARK: - GitHub star 数

  (function () {
    var target = byId("gh-stars");
    if (!target || typeof window.fetch !== "function") return;

    var count = null;

    /* 按页面语言格式化数字；不支持该 locale 时退回默认格式 */
    function renderCount() {
      if (count === null) return;
      try { target.textContent = count.toLocaleString(root.lang || undefined); }
      catch (e) { target.textContent = count.toLocaleString(); }
    }

    // 4 秒超时；失败、限流或超时都静默保留 HTML 里的原文
    var controller = "AbortController" in window ? new AbortController() : null;
    var timeout = window.setTimeout(function () { if (controller) controller.abort(); }, 4000);
    window.fetch("https://api.github.com/repos/OpenFabrica/aster", controller ? { signal: controller.signal } : undefined)
      .then(function (response) { return response.ok ? response.json() : null; })
      .then(function (data) {
        if (data && typeof data.stargazers_count === "number") {
          count = data.stargazers_count;
          renderCount();
        }
      })
      .catch(function () { /* 静默失败，保留原文 */ })
      .then(function () { window.clearTimeout(timeout); });
  })();
})();
