// 设置侧栏分区图标与点击动画：图标与动效对齐 Otty 设置页（24 网格、淡色填充 + 描边）。
(() => {
  "use strict";

  // 分区 id → 内联 SVG。带 mgc-* 类的分组是动画作用的部件（头、身体、波纹、格子等）。
  const svgs = {
    general: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><g fill=\"currentColor\" opacity=\".05\"><path d=\"M10.5 3.866a3 3 0 0 1 3 0l4.794 2.768a3 3 0 0 1 1.5 2.598v5.536a3 3 0 0 1-1.5 2.598L13.5 20.134a3 3 0 0 1-3 0l-4.794-2.768a3 3 0 0 1-1.5-2.598V9.232a3 3 0 0 1 1.5-2.598z\"/><path d=\"M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0\"/></g><path stroke=\"currentColor\" stroke-width=\"2\" d=\"M10.5 3.866a3 3 0 0 1 3 0l4.794 2.768a3 3 0 0 1 1.5 2.598v5.536a3 3 0 0 1-1.5 2.598L13.5 20.134a3 3 0 0 1-3 0l-4.794-2.768a3 3 0 0 1-1.5-2.598V9.232a3 3 0 0 1 1.5-2.598z\"/><path stroke=\"currentColor\" stroke-width=\"2\" d=\"M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z\"/></svg>",
    shell: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"M4 5a1 1 0 0 1 1-1h14a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1z\" opacity=\".05\"/><path stroke=\"currentColor\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M5 20h14a1 1 0 0 0 1-1V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1\"/><path class=\"mgc-inner\" pathLength=\"10\" stroke=\"currentColor\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M8.343 9.172 11.172 12l-2.829 2.828\"/><path class=\"mgc-inner mgc-inner-2\" pathLength=\"10\" stroke=\"currentColor\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M14 15h2\"/></svg>",
    controls: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"m7.69 3.28-.847 13.334 3.521-3.042 3.152 7.45 2.705-1.152-3.018-7.212 4.732-.292z\" opacity=\".05\"/><path stroke=\"currentColor\" stroke-width=\"2\" d=\"M7.844 3.416a.1.1 0 0 0-.166.069l-.82 12.891a.1.1 0 0 0 .165.082l3.237-2.796a.1.1 0 0 1 .158.036l2.903 6.863a.5.5 0 0 0 .656.265l1.787-.761a.5.5 0 0 0 .265-.653l-2.772-6.624a.1.1 0 0 1 .086-.139l4.351-.268a.1.1 0 0 0 .06-.175z\"/></svg>",
    editor: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"M5 4a1 1 0 0 1 1-1h7.586a1 1 0 0 1 .707.293l4.414 4.414a1 1 0 0 1 .293.707V20a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1z\" opacity=\".05\"/><path stroke=\"currentColor\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M13 3v5.5a.5.5 0 0 0 .5.5H19m-5.414-6H6a1 1 0 0 0-1 1v16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8.414a1 1 0 0 0-.293-.707l-4.414-4.414A1 1 0 0 0 13.586 3\"/><path class=\"mgc-inner\" pathLength=\"10\" stroke=\"currentColor\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M9 12h1\"/><path class=\"mgc-inner mgc-inner-2\" pathLength=\"10\" stroke=\"currentColor\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M9 16h6\"/></svg>",
    agents: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"M4 10a4 4 0 0 1 4-4h8a4 4 0 0 1 4 4v6a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4z\" opacity=\".05\"/><path stroke=\"currentColor\" stroke-linecap=\"round\" stroke-width=\"2\" d=\"M9 12v2m6-2v2m-3-9v2m0-2a1 1 0 1 0 0-2 1 1 0 0 0 0 2Zm-7 6h-.5a1.5 1.5 0 0 0 0 3H5zm14 0h.5a1.5 1.5 0 0 1 0 3H19zM8 19h8a3 3 0 0 0 3-3v-6a3 3 0 0 0-3-3H8a3 3 0 0 0-3 3v6a3 3 0 0 0 3 3Z\"/></svg>",
    hosts: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"M16 13H8a2 2 0 0 0-2 2v7h12v-7a2 2 0 0 0-2-2\" opacity=\".05\"/><path stroke=\"currentColor\" stroke-linecap=\"round\" stroke-width=\"2\" d=\"M18 21v-6a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v6M11 17h2\"/><path class=\"mgc-wave mgc-wave-1\" stroke=\"currentColor\" stroke-linecap=\"round\" stroke-width=\"2\" d=\"M14.285 9.717A3.982 3.982 0 0 0 12 9c-.85 0-1.638.265-2.285.717\"/><path class=\"mgc-wave mgc-wave-2\" stroke=\"currentColor\" stroke-linecap=\"round\" stroke-width=\"2\" d=\"M16.426 7.577A6.971 6.971 0 0 0 12 6c-1.679 0-3.219.59-4.425 1.576\"/><path class=\"mgc-wave mgc-wave-3\" stroke=\"currentColor\" stroke-linecap=\"round\" stroke-width=\"2\" d=\"M5.442 5.45A9.961 9.961 0 0 1 12 3a9.96 9.96 0 0 1 6.553 2.446\"/></svg>",
    view: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><g class=\"mgc-cluster\"><g class=\"mgc-cell mgc-cell-tl\"><path fill=\"currentColor\" opacity=\".05\" d=\"M10 5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1z\"/><path stroke=\"currentColor\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M10 5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1z\"/></g><g class=\"mgc-cell mgc-cell-tr\"><path fill=\"currentColor\" opacity=\".05\" d=\"M20 5a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1z\"/><path stroke=\"currentColor\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M20 5a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1z\"/></g><g class=\"mgc-cell mgc-cell-bl\"><path fill=\"currentColor\" opacity=\".05\" d=\"M10 15a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1z\"/><path stroke=\"currentColor\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M10 15a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1z\"/></g><g class=\"mgc-cell mgc-cell-br\"><path fill=\"currentColor\" opacity=\".05\" d=\"M20 15a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1z\"/><path stroke=\"currentColor\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M20 15a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h4a1 1 0 0 0 1-1z\"/></g></g></svg>",
    appearance: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"M17.902 15.484c1.322.22 2.682-.458 2.936-1.773a9 9 0 1 0-8.469 7.282c1.292-.053 1.891-1.472 1.313-2.63a2.115 2.115 0 0 1 .396-2.44l.089-.09a2.29 2.29 0 0 1 1.995-.64z\" opacity=\".05\"/><path fill=\"currentColor\" d=\"M8 12.5a.5.5 0 1 1-1 0 .5.5 0 0 1 1 0m2-4a.5.5 0 1 1-1 0 .5.5 0 0 1 1 0m5 0a.5.5 0 1 1-1 0 .5.5 0 0 1 1 0\"/><path stroke=\"currentColor\" stroke-width=\"2\" d=\"M17.902 15.484c1.322.22 2.682-.458 2.936-1.773a9 9 0 1 0-8.469 7.282c1.292-.053 1.891-1.472 1.313-2.63a2.115 2.115 0 0 1 .396-2.44l.089-.09a2.29 2.29 0 0 1 1.995-.64z\"/><path stroke=\"currentColor\" stroke-width=\"2\" d=\"M8 12.5a.5.5 0 1 1-1 0 .5.5 0 0 1 1 0Zm2-4a.5.5 0 1 1-1 0 .5.5 0 0 1 1 0Zm5 0a.5.5 0 1 1-1 0 .5.5 0 0 1 1 0Z\"/></svg>",
    recipes: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"M3 6.5c0-.315.148-.61.417-.774C4.129 5.293 5.683 4.5 7.5 4.5 10 4.5 12 6 12 6v14s-2-1.5-4.5-1.5c-1.508 0-2.834.546-3.649.979C3.488 19.672 3 19.412 3 19zm18 0a.893.893 0 0 0-.417-.774C19.871 5.293 18.318 4.5 16.5 4.5 14 4.5 12 6 12 6v14s2-1.5 4.5-1.5c1.508 0 2.834.546 3.648.979.364.193.852-.067.852-.479z\" opacity=\".05\"/><path stroke=\"currentColor\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M12 6v14m0-14s-2-1.5-4.5-1.5c-1.817 0-3.37.793-4.083 1.226A.893.893 0 0 0 3 6.5V19c0 .412.488.672.851.479.815-.433 2.141-.979 3.649-.979C10 18.5 12 20 12 20m0-14s2-1.5 4.5-1.5c1.817 0 3.37.793 4.083 1.226.27.163.417.46.417.774V19c0 .412-.488.672-.852.479-.814-.433-2.14-.979-3.648-.979C14 18.5 12 20 12 20\"/><path class=\"mgc-page\" stroke=\"currentColor\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M3 6.5c0-.315.148-.61.417-.774C4.129 5.293 5.683 4.5 7.5 4.5 10 4.5 12 6 12 6v14s-2-1.5-4.5-1.5c-1.508 0-2.834.546-3.649.979C3.488 19.672 3 19.412 3 19z\"/></svg>",
    shortcuts: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"M3 6a1 1 0 0 1 1-1h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z\" opacity=\".05\"/><path stroke=\"currentColor\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M7 9h1m3.5 0h1M16 9h1M7 12h1m3.5 0h1m3.5 0h1M7 15h10M4 19h16a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1\"/></svg>",
    advanced: "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path fill=\"currentColor\" d=\"M13.646 5.14a6.002 6.002 0 0 1 1.267 6.62l4.928 4.17a2.76 2.76 0 1 1-3.89 3.89l-4.17-4.927a6.002 6.002 0 0 1-7.8-8.083l3.832 4.162 2.652-.527.53-2.655L6.83 3.96a6.003 6.003 0 0 1 6.816 1.18\" opacity=\".05\"/><path stroke=\"currentColor\" stroke-linejoin=\"round\" stroke-width=\"2\" d=\"M13.646 5.14a6.002 6.002 0 0 1 1.267 6.62l4.928 4.17a2.76 2.76 0 1 1-3.89 3.89l-4.17-4.927a6.002 6.002 0 0 1-7.8-8.083l3.832 4.162 2.652-.527.53-2.655L6.83 3.96a6.003 6.003 0 0 1 6.816 1.18Z\"/></svg>",
  };

  // 分区 id → 动画名，对应 settings.css 里的 .nav-icon-<name>。
  const motions = {
    general: "spin",
    shell: "type",
    controls: "nudge",
    editor: "scroll",
    agents: "rock",
    hosts: "wave",
    view: "cluster",
    appearance: "draw",
    recipes: "page",
    shortcuts: "tilt",
    advanced: "rock",
  };

  const svgNamespace = "http://www.w3.org/2000/svg";
  // 「draw」动画按最长子路径长度设置虚线；同一分区只量一次。
  const drawLengths = new Map();

  // 量出图标里最长的一段描边子路径长度。
  // 一条 path 可能含多段 M 子路径，逐段累加 getTotalLength 再取增量，才能让每段同时画完。
  function longestStrokeSegment(svg) {
    const probe = document.createElementNS(svgNamespace, "path");
    svg.appendChild(probe);
    let longest = 0;
    try {
      svg.querySelectorAll("path[stroke]").forEach(path => {
        const d = path.getAttribute("d");
        if (!d) return;
        const segments = d.split(/(?=[Mm])/).filter(part => part.trim());
        let previous = 0;
        for (let index = 0; index < segments.length; index += 1) {
          probe.setAttribute("d", segments.slice(0, index + 1).join(""));
          const total = probe.getTotalLength();
          longest = Math.max(longest, total - previous);
          previous = total;
        }
      });
    } finally {
      probe.remove();
    }
    return longest;
  }

  /// 在图标容器上播放该分区的一次性动画；系统开启「减弱动态效果」时不播放。
  function play(container, sectionID) {
    const motion = motions[sectionID];
    if (!container || !motion || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const className = `nav-icon-${motion}`;
    if (motion === "draw") {
      const svg = container.querySelector("svg");
      if (!svg) return;
      let length = drawLengths.get(sectionID);
      if (length === undefined) {
        length = longestStrokeSegment(svg);
        drawLengths.set(sectionID, length);
      }
      if (length <= 0) return;
      container.style.setProperty("--draw-len", String(length));
    }
    // 先移除再强制回流，连续点击同一项也能重新播放。
    container.classList.remove(className);
    void container.offsetWidth;
    container.classList.add(className);
    const animations = container.getAnimations({ subtree: true });
    Promise.all(animations.map(animation => animation.finished))
      .then(() => container.classList.remove(className))
      .catch(() => {});
  }

  window.AsterNavIcons = {
    /// 分区图标 SVG 文本；未知分区返回空串。
    svg: sectionID => svgs[sectionID] ?? "",
    play,
  };
})();
