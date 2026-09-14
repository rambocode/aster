(() => {
  "use strict";

  // 协议编辑器只管理本地输入和串行提交；真正的语法与授权边界仍在原生层。
  window.AsterLinkProtocols = {
    open({ items, commit, t, restoreFocus }) {
      const overlay = document.createElement("div");
      overlay.className = "settings-dialog-overlay";
      overlay.innerHTML = `<section class="settings-dialog protocol-dialog" role="dialog" aria-modal="true" aria-labelledby="protocol-title" aria-describedby="protocol-description">
        <h2 id="protocol-title"></h2><p id="protocol-description"></p>
        <div class="protocol-list"></div><button type="button" class="action-button protocol-add"></button>
        <p class="protocol-status" role="status" aria-live="polite"></p>
        <div class="settings-dialog-actions"><button type="button" class="action-button protocol-retry" hidden></button><button type="button" class="action-button primary protocol-done"></button></div>
      </section>`;
      const list = overlay.querySelector(".protocol-list");
      const status = overlay.querySelector(".protocol-status");
      const add = overlay.querySelector(".protocol-add");
      const done = overlay.querySelector(".protocol-done");
      const retry = overlay.querySelector(".protocol-retry");
      overlay.querySelector("h2").textContent = t("自定义链接协议");
      overlay.querySelector("#protocol-description").textContent = t("输入要识别的协议名称；不需要添加 ://。");
      add.textContent = "+ " + t("添加协议");
      done.textContent = t("完成");
      retry.textContent = t("重试");
      let entries = items.map(value => ({ value }));
      let saved = normalized();
      let saving = false;
      let failed = false;
      let closing = false;
      const app = document.getElementById("app");
      const previousInert = app.inert;
      app.inert = true;

      function normalized() {
        return [...new Set(entries.map(entry => entry.value.trim().replace(/:\/\/$/, "").toLowerCase()).filter(Boolean))].sort().join(", ");
      }

      function validate() {
        let valid = true;
        for (const entry of entries) {
          const value = entry.value.trim();
          const scheme = value.replace(/:\/\/$/, "");
          const accepted = !value || (scheme.length <= 64 && /^[a-z][a-z0-9+.-]*$/i.test(scheme));
          entry.input?.setAttribute("aria-invalid", String(!accepted));
          valid &&= accepted;
        }
        return valid;
      }

      function updateFeedback() {
        const valid = validate();
        status.textContent = !valid ? t("协议名称无效，请使用字母开头的协议名。")
          : failed ? t("未能保存，请重试。") : saving ? t("正在保存…") : t("更改即时生效");
        status.classList.toggle("error", !valid || failed);
        retry.hidden = !failed;
        done.disabled = !valid || saving || failed;
        add.disabled = entries.length >= 64;
      }

      function close() {
        overlay.remove();
        app.inert = previousInert;
        restoreFocus();
      }

      async function save() {
        updateFeedback();
        if (saving || !validate()) return;
        const value = normalized();
        if (value === saved && !failed) { if (closing) close(); return; }
        saving = true;
        failed = false;
        updateFeedback();
        try {
          await commit(value);
          saved = value;
        } catch {
          failed = true;
          closing = false;
        } finally {
          saving = false;
          updateFeedback();
        }
        // 快照回执后再提交编辑期间产生的新值，避免旧 revision 覆盖连续输入。
        if (!failed && validate() && normalized() !== saved) await save();
        else if (!failed && closing && validate()) close();
      }

      function render() {
        list.replaceChildren();
        if (!entries.length) {
          const empty = document.createElement("p");
          empty.textContent = t("暂无自定义协议，在下方添加一个。");
          list.appendChild(empty);
        }
        entries.forEach((entry, index) => {
          const row = document.createElement("div");
          row.className = "protocol-row";
          const input = document.createElement("input");
          input.type = "text";
          input.autocomplete = "off";
          input.className = "control";
          input.value = entry.value;
          input.placeholder = "codex";
          input.spellcheck = false;
          input.setAttribute("aria-label", `${t("协议")} ${index + 1}`);
          input.setAttribute("aria-describedby", "protocol-description");
          input.addEventListener("input", () => { entry.value = input.value; void save(); });
          entry.input = input;
          const remove = document.createElement("button");
          remove.type = "button";
          remove.className = "action-button danger";
          remove.textContent = "×";
          remove.setAttribute("aria-label", `${t("移除")} ${t("协议")} ${index + 1}`);
          remove.addEventListener("click", () => {
            entries.splice(index, 1);
            render();
            (entries[Math.min(index, entries.length - 1)]?.input ?? add).focus();
            void save();
          });
          row.append(input, remove);
          list.appendChild(row);
        });
        updateFeedback();
      }

      function requestClose() {
        if (!validate() || failed) { updateFeedback(); (overlay.querySelector('[aria-invalid="true"]') ?? retry).focus(); return; }
        closing = true;
        if (!saving) void save();
      }
      add.addEventListener("click", () => {
        if (entries.length >= 64) return;
        entries.push({ value: "" });
        render();
        entries.at(-1).input.focus();
      });
      retry.addEventListener("click", () => void save());
      done.addEventListener("click", requestClose);
      overlay.addEventListener("click", event => { if (event.target === overlay) requestClose(); });
      overlay.addEventListener("keydown", event => {
        if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); requestClose(); }
        if (event.key !== "Tab") return;
        const focusable = [...overlay.querySelectorAll("input,button")].filter(element => !element.disabled && !element.hidden);
        const target = event.shiftKey ? focusable.at(-1) : focusable[0];
        if (document.activeElement === (event.shiftKey ? focusable[0] : focusable.at(-1))) { event.preventDefault(); target?.focus(); }
      });
      document.body.appendChild(overlay);
      render();
      (entries[0]?.input ?? add).focus();
    },
  };
})();
