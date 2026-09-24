(() => {
  "use strict";

  // 「主机」分类：列表、搜索、编辑表单、行菜单与导入汇总。
  // 网页只收集输入并提交结构化意图；校验、钥匙串与文件操作都在原生层（SettingsHostsBridge）。
  // 设置页每收到一份快照就整页重绘，所以编辑表单与菜单挂在 body 上，不随列表重建而丢失输入。

  const state = { query: "", collapsed: new Set(), menu: null };
  const AUTH_MODES = ["auto", "password", "publicKey", "agent", "keyboardInteractive"];
  const FORWARD_KINDS = ["local", "remote", "dynamic"];

  /// 认证方式与转发类型的显示文案。
  function labels(t) {
    return {
      auth: { auto: t("自动"), password: t("口令"), publicKey: t("公钥"), agent: "Agent", keyboardInteractive: t("键盘交互") },
      forward: { local: t("L 本地"), remote: t("R 远端"), dynamic: t("D 动态") },
    };
  }

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(label, className, onClick) {
    const node = element("button", `action-button${className ? ` ${className}` : ""}`, label);
    node.type = "button";
    node.addEventListener("click", onClick);
    return node;
  }

  /// 分组显示名：null 是「未分组」。
  function groupLabel(group, t) {
    return group ?? t("未分组");
  }

  /// 搜索按名称、主机、用户、端口过滤（不区分大小写）。
  function matches(row, query) {
    if (!query) return true;
    const profile = row.profile;
    return [profile.name, profile.host, profile.user, profile.port == null ? "" : String(profile.port)]
      .some(value => String(value ?? "").toLocaleLowerCase().includes(query));
  }

  function closeMenu() {
    state.menu?.remove();
    state.menu = null;
  }
  document.addEventListener("click", event => { if (state.menu && !state.menu.contains(event.target)) closeMenu(); }, true);
  document.addEventListener("keydown", event => { if (event.key === "Escape" && state.menu) { event.stopPropagation(); closeMenu(); } }, true);
  window.addEventListener("resize", closeMenu);

  // MARK: - 列表

  /// 渲染整个「主机」页面主体。ctx 由 settings.js 提供（快照、t、mutate、对话框工具）。
  function render(ctx) {
    const { t, data } = ctx;
    const fragment = document.createDocumentFragment();
    if (data.loadError) fragment.appendChild(element("div", "message-banner", t("hosts.json 无法读取，正在显示最后一次有效内容：{detail}", { detail: data.loadError })));

    const group = element("section", "group");
    const toolbar = element("div", "hosts-toolbar");
    const search = element("input", "control hosts-search");
    search.type = "search";
    search.placeholder = t("按名称、主机、用户或端口搜索");
    search.setAttribute("aria-label", t("搜索主机"));
    search.value = state.query;
    const importButton = button(t("从 ~/.ssh/config 导入"), "", () => runImport(importButton, ctx));
    toolbar.append(
      search,
      button(t("新建主机"), "primary", () => openEditor(ctx, newProfile(), { isNew: true })),
      importButton,
      button(t("在 ~/.ssh/config 中编辑"), "", () => ctx.send("action", { action: "hosts.editSSHConfig", payload: {} })),
    );
    const card = element("div", "card hosts-list");
    const renderList = () => {
      closeMenu();
      card.replaceChildren(...listRows(ctx));
    };
    search.addEventListener("input", () => { state.query = search.value; renderList(); });
    renderList();
    group.append(toolbar, card);
    fragment.appendChild(group);
    // 快照重绘会换掉搜索框；如果用户正在输入，把焦点和光标还给新的输入框。
    if (document.activeElement?.classList.contains("hosts-search")) {
      const caret = document.activeElement.selectionStart;
      window.requestAnimationFrame(() => { search.focus(); search.setSelectionRange(caret, caret); });
    }
    return fragment;
  }

  /// 列表行：默认项、按分组排好的主机、空状态。
  function listRows(ctx) {
    const { t, data } = ctx;
    const query = state.query.trim().toLocaleLowerCase();
    const rows = [defaultsRow(ctx)];
    const visible = data.hosts.filter(row => matches(row, query));
    if (!data.hosts.length) rows.push(emptyRow(t("还没有保存的主机。点「新建主机」或从 ~/.ssh/config 导入。")));
    else if (!visible.length) rows.push(emptyRow(t("没有匹配“{query}”的主机", { query: state.query.trim() })));
    // 快照里的主机已按「导入组 → 命名分组 → 未分组」排好，这里只按相邻分组切段。
    let current;
    for (const row of visible) {
      const key = row.profile.group ?? null;
      if (current === undefined || key !== current) {
        current = key;
        rows.push(groupHeader(ctx, key, visible.filter(item => (item.profile.group ?? null) === key).length, query));
      }
      if (!query && state.collapsed.has(String(key))) continue;
      rows.push(hostRow(ctx, row));
    }
    return rows;
  }

  function emptyRow(text) {
    const row = element("div", "setting-row hosts-empty");
    row.appendChild(element("span", "setting-detail", text));
    return row;
  }

  function defaultsRow(ctx) {
    const { t } = ctx;
    const row = element("div", "setting-row hosts-row hosts-defaults");
    row.tabIndex = 0;
    row.setAttribute("role", "button");
    const copy = element("div", "setting-copy");
    copy.append(element("span", "setting-label", t("默认")), element("span", "setting-detail", t("所有主机都继承这里的值；留空的字段使用内置默认值")));
    row.append(copy, element("span", "hosts-chevron", "›"));
    activate(row, () => openEditor(ctx, ctx.data.defaults, { isDefaults: true }));
    return row;
  }

  function groupHeader(ctx, key, count, query) {
    const collapsed = !query && state.collapsed.has(String(key));
    const header = element("button", "hosts-group-header");
    header.type = "button";
    header.setAttribute("aria-expanded", String(!collapsed));
    header.append(element("span", "hosts-group-chevron", collapsed ? "▸" : "▾"), element("span", "", groupLabel(key, ctx.t)), element("span", "hosts-group-count", `· ${count}`));
    header.addEventListener("click", () => {
      if (query) return;
      const id = String(key);
      if (state.collapsed.has(id)) state.collapsed.delete(id); else state.collapsed.add(id);
      header.closest(".hosts-list")?.replaceChildren(...listRows(ctx));
    });
    return header;
  }

  function hostRow(ctx, row) {
    const { t } = ctx;
    const profile = row.profile;
    const host = element("div", "setting-row hosts-row");
    host.tabIndex = 0;
    host.setAttribute("role", "button");
    host.dataset.hostId = profile.id;
    const copy = element("div", "setting-copy");
    const detail = [row.connect || t("未填写主机")];
    if (row.jumpName) detail.push(t("经 {name}", { name: row.jumpName }));
    copy.append(element("span", "setting-label", profile.name || row.connect), element("span", "setting-detail", detail.join(" · ")));
    const control = element("div", "setting-control");
    if (row.hasPassword) control.appendChild(element("span", "hosts-badge", t("已保存口令")));
    if (row.machines.length) {
      const badge = element("span", "hosts-badge", t("{count} 台机器", { count: row.machines.length }));
      badge.title = row.machines.join("、");
      control.appendChild(badge);
    }
    const more = button("⋯", "hosts-more", event => { event.stopPropagation(); openMenu(ctx, row, more); });
    more.setAttribute("aria-label", t("更多操作"));
    more.setAttribute("aria-haspopup", "menu");
    control.appendChild(more);
    host.append(copy, control);
    activate(host, () => openEditor(ctx, profile, {}));
    return host;
  }

  /// 行点击与回车 / 空格都打开编辑；行内按钮自己处理事件。
  function activate(row, handler) {
    row.addEventListener("click", event => { if (!event.target.closest("button")) handler(); });
    row.addEventListener("keydown", event => {
      if (event.target !== row || (event.key !== "Enter" && event.key !== " ")) return;
      event.preventDefault();
      handler();
    });
  }

  // MARK: - 行菜单

  function openMenu(ctx, row, anchor) {
    const { t } = ctx;
    const reopen = state.menu?.dataset.hostId === row.profile.id;
    closeMenu();
    if (reopen) return;
    const menu = element("div", "hosts-menu");
    menu.setAttribute("role", "menu");
    menu.dataset.hostId = row.profile.id;
    const item = (label, handler, danger = false) => {
      const entry = element("button", `hosts-menu-item${danger ? " danger" : ""}`, label);
      entry.type = "button";
      entry.setAttribute("role", "menuitem");
      entry.addEventListener("click", () => { closeMenu(); handler(); });
      menu.appendChild(entry);
    };
    const id = row.profile.id;
    item(t("编辑…"), () => openEditor(ctx, row.profile, {}));
    item(t("复制"), () => ctx.send("action", { action: "hosts.duplicate", payload: { id } }));
    item(t("添加为机器…"), () => ctx.send("action", { action: "hosts.addMachine", payload: { id } }));
    if (row.hasPassword) item(t("忘记口令…"), () => confirmForgetPassword(ctx, row));
    menu.appendChild(element("div", "hosts-menu-separator"));
    item(t("删除…"), () => confirmDelete(ctx, row), true);
    document.body.appendChild(menu);
    const rect = anchor.getBoundingClientRect();
    const width = menu.offsetWidth;
    menu.style.left = `${Math.max(8, Math.min(rect.right - width, window.innerWidth - width - 8))}px`;
    const below = rect.bottom + 4;
    menu.style.top = `${below + menu.offsetHeight > window.innerHeight - 8 ? Math.max(8, rect.top - menu.offsetHeight - 4) : below}px`;
    state.menu = menu;
    menu.querySelector("button")?.focus();
  }

  /// 带名单的确认框：每个 list 一段标题加条目，空名单不显示。
  function confirmWithLists(ctx, { title, body, lists, button: confirmLabel }, onConfirm) {
    const { t } = ctx;
    const { dialog, close } = ctx.makeDialog(title, body);
    for (const list of lists.filter(entry => entry.items.length)) {
      const section = element("div", "hosts-confirm-list");
      section.appendChild(element("strong", "", list.heading));
      const items = element("ul");
      for (const text of list.items) items.appendChild(element("li", "", text));
      section.appendChild(items);
      dialog.appendChild(section);
    }
    const actions = element("div", "settings-dialog-actions");
    const confirm = button(confirmLabel, "danger", () => { onConfirm(); close(); });
    actions.append(button(t("取消"), "", close), confirm);
    dialog.appendChild(actions);
    confirm.focus();
  }

  function confirmForgetPassword(ctx, row) {
    const { t } = ctx;
    confirmWithLists(ctx, {
      title: t("忘记“{name}”的口令？", { name: row.profile.name }),
      body: t("口令会从钥匙串删除，下次连接时重新询问。"),
      lists: [{ heading: t("以下主机用同一个口令，也会一起失效："), items: row.credentialSharedWith }],
      button: t("忘记口令"),
    }, () => ctx.send("action", { action: "hosts.forgetPassword", payload: { id: row.profile.id } }));
  }

  function confirmDelete(ctx, row) {
    const { t } = ctx;
    let passwordNote = "";
    if (row.hasPassword) {
      passwordNote = row.credentialSharedWith.length
        ? t("已保存的口令还被其它主机使用，会保留在钥匙串里。")
        : t("已保存的口令会一起从钥匙串删除。");
    }
    confirmWithLists(ctx, {
      title: t("删除“{name}”？", { name: row.profile.name }),
      body: [t("删除后不能撤销。"), passwordNote].filter(Boolean).join(" "),
      lists: [
        { heading: t("引用它的机器（{count}）：", { count: row.machines.length }), items: row.machines },
        { heading: t("用它作跳板的主机（{count}），删除后不再经过跳板：", { count: row.jumpDependents.length }), items: row.jumpDependents },
        { heading: t("共用同一口令的主机："), items: row.hasPassword ? row.credentialSharedWith : [] },
      ],
      button: t("删除"),
    }, () => ctx.send("action", { action: "hosts.delete", payload: { id: row.profile.id } }));
  }

  // MARK: - 导入

  function runImport(importButton, ctx) {
    const { t } = ctx;
    const label = importButton.textContent;
    importButton.disabled = true;
    importButton.textContent = t("正在导入…");
    // 失败原因由原生 toast 显示；这里只恢复按钮。
    ctx.mutate("action", { action: "hosts.import", payload: {} }).catch(() => {}).finally(() => {
      importButton.disabled = false;
      importButton.textContent = label;
    });
  }

  /// 显示导入汇总：计数、被忽略的选项、无法映射的跳板与被跳过的主机。
  function showImportReport(report, ctx) {
    const { t } = ctx;
    const total = report.added + report.updated + report.unchanged;
    const summary = total
      ? t("新增 {added} 台，更新 {updated} 台，{unchanged} 台没有变化。", report)
      : t("~/.ssh/config 里没有可导入的主机。");
    const { dialog, close } = ctx.makeDialog(t("导入完成"), summary);
    const sections = [
      [t("没有导入的选项（{count}）：", { count: report.ignored.length }), report.ignored.map(item => `${item.file}:${item.line}  ${item.option} — ${item.reason}`)],
      [t("跳板不是已导入的主机，已留空（{count}）：", { count: report.unresolvedJumps.length }), report.unresolvedJumps.map(item => `${item.host}：ProxyJump ${item.proxyJump}`)],
      [t("参数无效、已跳过的主机（{count}）：", { count: report.rejected.length }), report.rejected.map(item => `${item.alias}：${item.reasons.join("；")}`)],
    ];
    for (const [heading, items] of sections.filter(([, items]) => items.length)) {
      const section = element("div", "hosts-confirm-list hosts-report-list");
      section.appendChild(element("strong", "", heading));
      const list = element("ul");
      for (const text of items) list.appendChild(element("li", "", text));
      section.appendChild(list);
      dialog.appendChild(section);
    }
    const actions = element("div", "settings-dialog-actions");
    const done = button(t("完成"), "primary", close);
    actions.appendChild(done);
    dialog.appendChild(actions);
    done.focus();
  }

  // MARK: - 编辑表单

  /// 新主机的空白对象。ID 必须是合法 UUID，原生侧按 `UUID` 解码；
  /// `crypto.randomUUID` 只在安全上下文可用，缺失时用 getRandomValues 拼一个 v4。
  function newProfile() {
    let id;
    if (crypto.randomUUID) id = crypto.randomUUID();
    else {
      const bytes = crypto.getRandomValues(new Uint8Array(16));
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = [...bytes].map(byte => byte.toString(16).padStart(2, "0")).join("");
      id = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    }
    return { id: id.toUpperCase(), name: "", host: "", user: "", identityFiles: [], forwards: [] };
  }

  /// 打开编辑对话框。表单在提交成功（原生回执）后才关闭；校验失败时保留输入。
  function openEditor(ctx, profile, { isDefaults = false, isNew = false }) {
    window.AsterHostsForm.open(ctx, profile, { isDefaults, isNew, labels: labels(ctx.t), AUTH_MODES, FORWARD_KINDS, element, button });
  }

  /// 打开指定主机的编辑表单（原生「编辑主机…」深链）；找不到时只停在列表。
  function edit(id, ctx) {
    const wanted = String(id || "").toUpperCase();
    const row = ctx.data.hosts.find(item => String(item.profile.id).toUpperCase() === wanted);
    if (row) openEditor(ctx, row.profile, {});
  }

  window.AsterHosts = { render, showImportReport, edit };
})();
