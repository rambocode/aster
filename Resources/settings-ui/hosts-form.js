(() => {
  "use strict";

  // 「主机」编辑表单（含「默认」项）。常用字段直接显示；跳板机、端口转发与高级选项折叠。
  // 空字段表示继承默认项（默认项自己的空字段表示内置默认值），占位符写出将要生效的值。
  // 这里只做格式解析，是否合法由原生 `SSHHostStore.validate` 最终判定。

  /// 解析 `host:port` / `[v6]:port` / 纯端口；纯端口时用 fallbackHost。返回 null 表示格式不对。
  function parseHostPort(text, fallbackHost) {
    const value = text.trim();
    if (!value) return null;
    let host = fallbackHost;
    let port = value;
    const bracket = value.match(/^\[([^\]]+)\]:(\d+)$/);
    if (bracket) [, host, port] = bracket;
    else if (value.includes(":")) {
      const index = value.lastIndexOf(":");
      host = value.slice(0, index).trim();
      port = value.slice(index + 1).trim();
    }
    if (!/^\d+$/.test(port) || host === undefined || host === "") return null;
    return { host, port: Number(port) };
  }

  /// `{host, port}` 显示成输入框文本；IPv6 加方括号。
  function formatHostPort(value) {
    if (!value) return "";
    const host = value.host.includes(":") ? `[${value.host}]` : value.host;
    return host ? `${host}:${value.port}` : String(value.port);
  }

  /// 可空整数：空串返回 null，非整数返回 NaN（交给错误提示）。
  function optionalInteger(text) {
    const value = text.trim();
    if (!value) return null;
    return /^-?\d+$/.test(value) ? Number(value) : Number.NaN;
  }

  /// 三态开关（继承 / 开 / 关）与 JSON 值互转。
  const triState = { toValue: text => (text === "" ? null : text === "true"), fromValue: value => (value == null ? "" : String(value)) };

  function open(ctx, profile, options) {
    const { t, data } = ctx;
    const { isDefaults, isNew, labels, AUTH_MODES, FORWARD_KINDS, element, button } = options;
    const defaults = data.defaults;
    const builtin = data.builtin;
    // 占位符：普通主机显示默认项的值（没有再显示内置值）；默认项只显示内置值。
    const inherited = key => (isDefaults ? builtin[key] : (defaults[key] ?? builtin[key]));
    const title = isDefaults ? t("默认") : isNew ? t("新建主机") : t("编辑“{name}”", { name: profile.name });
    const description = isDefaults ? t("所有主机都继承这里的值。留空表示使用内置默认值。") : t("留空的字段继承「默认」项。");
    const { dialog, close } = ctx.makeDialog(title, description, { wide: true });
    dialog.classList.add("hosts-dialog");
    const form = element("div", "hosts-form");
    const fields = {};

    /// 一行「标签 + 控件」。
    const field = (label, control, hint) => {
      const row = element("label", "hosts-field");
      row.appendChild(element("span", "hosts-field-label", label));
      const body = element("span", "hosts-field-body");
      body.appendChild(control);
      if (hint) body.appendChild(element("small", "hosts-field-hint", hint));
      row.appendChild(body);
      return row;
    };
    const input = (key, value, placeholder, type = "text") => {
      const node = element("input", "control");
      node.type = type;
      node.value = value ?? "";
      node.placeholder = placeholder == null ? "" : String(placeholder);
      node.spellcheck = false;
      node.autocomplete = "off";
      fields[key] = node;
      return node;
    };
    const select = (key, entries, value) => {
      const node = element("select", "control");
      for (const [optionValue, label] of entries) {
        const option = element("option", "", label);
        option.value = optionValue;
        option.selected = optionValue === value;
        node.appendChild(option);
      }
      fields[key] = node;
      return node;
    };
    const inheritLabel = text => (isDefaults ? t("内置默认（{value}）", { value: text }) : t("继承默认（{value}）", { value: text }));
    const onOff = value => (value ? t("开") : t("关"));

    // 常用字段。
    const common = element("div", "hosts-form-grid");
    if (!isDefaults) {
      common.appendChild(field(t("名称"), input("name", profile.name, t("例如：生产数据库"))));
      const groupInput = input("group", profile.group, t("未分组"));
      const list = element("datalist");
      list.id = `hosts-groups-${profile.id}`;
      for (const group of data.groups) list.appendChild(Object.assign(element("option"), { value: group }));
      groupInput.setAttribute("list", list.id);
      common.append(field(t("分组"), groupInput), list);
      common.appendChild(field(t("主机"), input("host", profile.host, "example.com")));
    }
    common.appendChild(field(t("端口"), input("port", profile.port, inherited("port"), "number")));
    common.appendChild(field(t("用户"), input("user", profile.user, inherited("user"))));
    const authText = labels.auth[inherited("auth")] ?? inherited("auth");
    common.appendChild(field(t("认证方式"), select("auth", [["", inheritLabel(authText)], ...AUTH_MODES.map(mode => [mode, labels.auth[mode]])], profile.auth ?? "")));
    const identity = element("textarea", "control hosts-identity");
    identity.rows = 2;
    identity.spellcheck = false;
    identity.value = (profile.identityFiles ?? []).join("\n");
    identity.placeholder = (!isDefaults && defaults.identityFiles?.length ? defaults.identityFiles.join("\n") : "~/.ssh/id_ed25519");
    fields.identityFiles = identity;
    common.appendChild(field(t("私钥文件"), identity, t("每行一个；可用 ~、%h（主机）、%r（用户）")));
    form.appendChild(common);

    /// 可折叠区域；有内容时默认展开。
    const section = (label, openByDefault, content) => {
      const details = element("details", "hosts-section");
      details.open = openByDefault;
      details.appendChild(element("summary", "", label));
      details.appendChild(content);
      form.appendChild(details);
    };

    // 跳板机：不能选自己，也不列出默认项。
    const jumpGrid = element("div", "hosts-form-grid");
    const defaultJump = data.hosts.find(row => row.profile.id === defaults.jumpHostID);
    const jumpInherit = isDefaults ? t("不使用跳板") : inheritLabel(defaultJump ? defaultJump.profile.name : t("不使用跳板"));
    const jumpEntries = [["", jumpInherit], ...data.hosts.filter(row => row.profile.id !== profile.id).map(row => [row.profile.id, `${row.profile.name}（${row.connect}）`])];
    jumpGrid.appendChild(field(t("跳板机"), select("jumpHostID", jumpEntries, profile.jumpHostID ?? "")));
    section(t("跳板机"), Boolean(profile.jumpHostID), jumpGrid);

    // 端口转发规则。
    const forwards = (profile.forwards ?? []).map(rule => ({ kind: rule.kind, bind: formatHostPort(rule.bind), target: formatHostPort(rule.target), description: rule.description ?? "" }));
    const forwardHost = element("div", "hosts-forwards");
    const renderForwards = () => {
      forwardHost.replaceChildren();
      if (!isDefaults && defaults.forwards?.length) forwardHost.appendChild(element("p", "hosts-field-hint", t("「默认」项里的 {count} 条规则会先生效。", { count: defaults.forwards.length })));
      if (!forwards.length) forwardHost.appendChild(element("p", "hosts-field-hint", t("还没有转发规则。")));
      forwards.forEach((rule, index) => {
        const line = element("div", "hosts-forward");
        const kind = element("select", "control");
        for (const value of FORWARD_KINDS) {
          const option = element("option", "", labels.forward[value]);
          option.value = value;
          option.selected = rule.kind === value;
          kind.appendChild(option);
        }
        const bind = Object.assign(element("input", "control"), { value: rule.bind, placeholder: t("绑定 127.0.0.1:8080"), spellcheck: false });
        const target = Object.assign(element("input", "control"), { value: rule.target, placeholder: t("目标 localhost:80"), spellcheck: false });
        target.disabled = rule.kind === "dynamic";
        const note = Object.assign(element("input", "control"), { value: rule.description, placeholder: t("说明"), spellcheck: false });
        kind.addEventListener("change", () => { rule.kind = kind.value; target.disabled = rule.kind === "dynamic"; });
        bind.addEventListener("input", () => { rule.bind = bind.value; });
        target.addEventListener("input", () => { rule.target = target.value; });
        note.addEventListener("input", () => { rule.description = note.value; });
        const remove = button("×", "danger", () => { forwards.splice(index, 1); renderForwards(); });
        remove.setAttribute("aria-label", t("移除规则 {index}", { index: index + 1 }));
        line.append(kind, bind, target, note, remove);
        forwardHost.appendChild(line);
      });
      forwardHost.appendChild(button(t("+ 添加规则"), "", () => { forwards.push({ kind: "local", bind: "", target: "", description: "" }); renderForwards(); }));
    };
    renderForwards();
    section(t("端口转发"), forwards.length > 0, forwardHost);

    // 高级选项。
    const advanced = element("div", "hosts-form-grid");
    advanced.appendChild(field("ProxyCommand", input("proxyCommand", profile.proxyCommand, isDefaults ? "" : defaults.proxyCommand ?? ""), t("填写后不再直连；%h、%p 由 ssh 规则展开")));
    advanced.appendChild(field(t("SOCKS 代理"), input("socksProxy", formatHostPort(profile.socksProxy), isDefaults ? "127.0.0.1:1080" : formatHostPort(defaults.socksProxy) || "127.0.0.1:1080")));
    advanced.appendChild(field(t("HTTP 代理"), input("httpProxy", formatHostPort(profile.httpProxy), isDefaults ? "127.0.0.1:8080" : formatHostPort(defaults.httpProxy) || "127.0.0.1:8080")));
    advanced.appendChild(field(t("Keepalive 间隔（秒）"), input("keepaliveInterval", profile.keepaliveInterval, inherited("keepaliveInterval"), "number")));
    advanced.appendChild(field(t("Keepalive 次数"), input("keepaliveCountMax", profile.keepaliveCountMax, inherited("keepaliveCountMax"), "number")));
    advanced.appendChild(field(t("连接超时（秒）"), input("connectTimeout", profile.connectTimeout, inherited("connectTimeout"), "number")));
    advanced.appendChild(field(t("校验主机密钥"), select("verifyHostKeys", [["", inheritLabel(onOff(inherited("verifyHostKeys")))], ["true", t("开")], ["false", t("关")]], triState.fromValue(profile.verifyHostKeys))));
    advanced.appendChild(field(t("Agent 转发"), select("agentForward", [["", inheritLabel(onOff(inherited("agentForward")))], ["true", t("开")], ["false", t("关")]], triState.fromValue(profile.agentForward))));
    advanced.appendChild(field(t("只用指定私钥"), select("identitiesOnly", [["", inheritLabel(onOff(inherited("identitiesOnly")))], ["true", t("开")], ["false", t("关")]], triState.fromValue(profile.identitiesOnly)), t("开启后只尝试上面的私钥文件，不再用 agent 里的其它密钥（IdentitiesOnly）")));
    advanced.appendChild(field(t("Agent 套接字"), input("identityAgent", profile.identityAgent, isDefaults ? "SSH_AUTH_SOCK" : defaults.identityAgent ?? "SSH_AUTH_SOCK"), t("认证用的 ssh-agent 套接字路径（IdentityAgent），可用 ~；填 none 不用 agent，留空使用 SSH_AUTH_SOCK")));
    // known_hosts 与私钥一样按「非空才覆盖」继承：留空就用默认项，再缺省为 ~/.ssh/known_hosts。
    const knownHosts = element("textarea", "control hosts-identity");
    knownHosts.rows = 2;
    knownHosts.spellcheck = false;
    knownHosts.value = (profile.knownHostsFiles ?? []).join("\n");
    knownHosts.placeholder = (inherited("knownHostsFiles")?.length ? inherited("knownHostsFiles") : builtin.knownHostsFiles).join("\n");
    fields.knownHostsFiles = knownHosts;
    advanced.appendChild(field(t("known_hosts 文件"), knownHosts, t("每行一个；留空使用默认值 {path}", { path: builtin.knownHostsFiles.join("、") })));
    const advancedKeys = ["proxyCommand", "socksProxy", "httpProxy", "keepaliveInterval", "keepaliveCountMax", "connectTimeout", "verifyHostKeys", "agentForward", "identitiesOnly", "identityAgent"];
    section(t("高级"), advancedKeys.some(key => profile[key] != null && profile[key] !== "") || Boolean(profile.knownHostsFiles?.length), advanced);

    dialog.appendChild(form);
    const status = element("p", "hosts-form-error");
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    dialog.appendChild(status);

    /// 从表单收集主机对象；格式错误时返回 null 并显示原因。
    const collect = () => {
      const errors = [];
      const text = key => fields[key]?.value.trim() ?? "";
      const next = { id: profile.id, name: isDefaults ? profile.name : text("name"), host: isDefaults ? "" : text("host"), user: text("user") };
      if (!isDefaults && text("group")) next.group = text("group");
      for (const key of ["port", "keepaliveInterval", "keepaliveCountMax", "connectTimeout"]) {
        const value = optionalInteger(fields[key].value);
        if (Number.isNaN(value)) errors.push(t("{field} 必须是整数", { field: fields[key].closest(".hosts-field").firstChild.textContent }));
        else if (value !== null) next[key] = value;
      }
      if (fields.auth.value) next.auth = fields.auth.value;
      next.identityFiles = identity.value.split("\n").map(line => line.trim()).filter(Boolean);
      if (fields.jumpHostID.value) next.jumpHostID = fields.jumpHostID.value;
      if (text("proxyCommand")) next.proxyCommand = text("proxyCommand");
      if (text("identityAgent")) next.identityAgent = text("identityAgent");
      for (const [key, label] of [["socksProxy", t("SOCKS 代理")], ["httpProxy", t("HTTP 代理")]]) {
        if (!text(key)) continue;
        const parsed = parseHostPort(text(key));
        if (parsed) next[key] = parsed; else errors.push(t("{field} 要写成 主机:端口", { field: label }));
      }
      // 空的 known_hosts 列表保存成 nil（继承），而不是空数组。
      const knownHostsFiles = knownHosts.value.split("\n").map(line => line.trim()).filter(Boolean);
      if (knownHostsFiles.length) next.knownHostsFiles = knownHostsFiles;
      for (const key of ["verifyHostKeys", "agentForward", "identitiesOnly"]) {
        const value = triState.toValue(fields[key].value);
        if (value !== null) next[key] = value;
      }
      next.forwards = [];
      forwards.forEach((rule, index) => {
        // 只写端口时绑定本机回环、目标 localhost，与 ssh -L 8080:… 的习惯一致。
        const bind = parseHostPort(rule.bind, "127.0.0.1");
        const target = rule.kind === "dynamic" ? { host: "", port: 0 } : parseHostPort(rule.target, "localhost");
        if (!bind || !target) errors.push(t("第 {index} 条转发规则的地址要写成 主机:端口", { index: index + 1 }));
        else next.forwards.push({ kind: rule.kind, bind, target, description: rule.description.trim() });
      });
      status.textContent = errors.join("；");
      return errors.length ? null : next;
    };

    const actions = element("div", "settings-dialog-actions");
    const save = button(t("保存"), "primary", async () => {
      const next = collect();
      if (!next || save.disabled) return;
      save.disabled = true;
      try {
        await ctx.mutate("action", { action: "hosts.save", payload: { profile: next } });
        close();
      } catch {
        // 原生侧已用 toast 说明原因；保留表单让用户修改。
        save.disabled = false;
      }
    });
    actions.append(button(t("取消"), "", close), save);
    dialog.appendChild(actions);
    (fields.name ?? fields.port).focus();
  }

  window.AsterHostsForm = { open, parseHostPort, formatHostPort };
})();
