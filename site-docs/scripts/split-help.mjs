#!/usr/bin/env node
/**
 * 将中英文用户帮助按二级标题切页；两种语言共用固定 slug 和侧栏分组。
 * 生成页与侧栏不入库。英文缺章、重复 slug 或未闭合围栏会使构建失败。
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** 已知标题共用稳定地址；中文新增章节仍使用原有 section-NN 回退。 */
const SLUGS = {
  "Aster 能做什么": "index", "What Aster Does": "index",
  "开始使用": "getting-started", "Getting Started": "getting-started",
  "远程机器": "remote-machines", "Remote Machines": "remote-machines",
  "诊断日志与反馈": "diagnostics", "Diagnostic Logs and Feedback": "diagnostics",
  "标签与三种布局": "tabs-and-layouts", "Tabs and Three Layouts": "tabs-and-layouts",
  "常用目录": "frequent-directories", "Frequent Directories": "frequent-directories",
  "分屏与 Pane": "splits-and-panes", "Splits and Panes": "splits-and-panes",
  "文件浏览器、编辑与预览": "files-and-preview", "Files, Editing, and Previews": "files-and-preview",
  "查找与命令面板": "search-and-command-palette", "Find and the Command Palette": "search-and-command-palette",
  "Recipes 与会话恢复": "recipes-and-restore", "Recipes and Session Restore": "recipes-and-restore",
  "CLI 与深链": "cli-and-deep-links", "CLI and Deep Links": "cli-and-deep-links",
  "Working with Agents": "working-with-agents",
  "项目记忆（Session Memory）": "session-memory", "Project Memory (Session Memory)": "session-memory",
  "十类设置": "settings", "十一类设置": "settings", "Eleven Settings Categories": "settings",
  "Quick Terminal 快速终端": "quick-terminal", "Quick Terminal": "quick-terminal",
  "远端会话恢复": "remote-session-restore", "Remote Session Restore": "remote-session-restore",
  "SSH 主机与快速连接": "ssh-hosts", "SSH Hosts and Quick Connect": "ssh-hosts",
  "命名工作区": "workspaces", "Named Workspaces": "workspaces",
  "软件更新": "software-update", "Software Updates": "software-update",
  "常见问题": "faq", "Frequently Asked Questions": "faq",
  "外观主题": "themes", "Appearance Themes": "themes",
};

const GROUPS = [
  { zh: "开始", en: "Start", slugs: ["index", "getting-started"] },
  { zh: "界面", en: "Interface", slugs: ["tabs-and-layouts", "splits-and-panes", "files-and-preview", "search-and-command-palette", "quick-terminal", "workspaces"] },
  { zh: "工作流", en: "Workflows", slugs: ["recipes-and-restore", "cli-and-deep-links", "working-with-agents", "remote-machines", "remote-session-restore", "ssh-hosts", "session-memory", "frequent-directories"] },
  { zh: "配置", en: "Configuration", slugs: ["settings", "themes", "software-update", "diagnostics", "faq"] },
];

/** 仅同字符、足够长度的围栏可闭合，避免代码中的标题被当成章节。 */
export function parseSections(src) {
  const sections = [];
  let current = null;
  let fence = null;
  for (const line of src.split("\n")) {
    const marker = line.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = null;
      if (current) current.body.push(line);
      continue;
    }
    const heading = !fence && line.match(/^## (.+?)\s*$/);
    if (heading) {
      current = { title: heading[1], body: [] };
      sections.push(current);
    } else if (current) current.body.push(line);
  }
  if (fence) throw new Error("split-help: 代码围栏未闭合");
  if (!sections.length) throw new Error("split-help: 未找到二级章节");
  return sections;
}

export function pagesFor(src, language) {
  const used = new Set();
  return parseSections(src).map((section, index) => {
    const slug = SLUGS[section.title] ?? (language === "zh" ? `section-${String(index + 1).padStart(2, "0")}` : null);
    if (!slug) throw new Error(`split-help: 英文标题未登记固定 slug：${section.title}`);
    if (used.has(slug)) throw new Error(`split-help: 重复 slug：${slug}`);
    used.add(slug);
    return { ...section, slug };
  });
}

export function validateLocales(zh, en) {
  const chinese = new Set(zh.map((page) => page.slug));
  const english = new Set(en.map((page) => page.slug));
  if (chinese.size !== english.size || [...chinese].some((slug) => !english.has(slug))) {
    throw new Error("split-help: 中英文章节 slug 不一致，请同步英文帮助并登记标题");
  }
}

function shiftHeadings(body) {
  // parseSections 已检查围栏；这里只降级围栏外的子标题。
  let fence = null;
  return body.map((line) => {
    const marker = line.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = null;
      return line;
    }
    return !fence && /^(#{3,6}) /.test(line) ? line.slice(1) : line;
  });
}

function generate(pages, language) {
  const prefix = language === "en" ? "/en/" : "/";
  const outDir = path.join(root, language === "en" ? "en/guide" : "guide");
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  for (const page of pages) {
    const body = shiftHeadings(page.body).join("\n").trim();
    fs.writeFileSync(path.join(outDir, `${page.slug}.md`),
      ["---", `title: ${JSON.stringify(page.title)}`, "---", "", `# ${page.title}`, "", body, ""].join("\n"));
  }
  const bySlug = new Map(pages.map((page) => [page.slug, page]));
  const used = new Set();
  const linkFor = (page) => ({ text: page.title, link: prefix + (page.slug === "index" ? "" : page.slug) });
  const sidebar = [];
  for (const group of GROUPS) {
    const items = group.slugs.filter((slug) => bySlug.has(slug)).map((slug) => {
      used.add(slug);
      return linkFor(bySlug.get(slug));
    });
    if (items.length) sidebar.push({ text: group[language], items });
  }
  const rest = pages.filter((page) => !used.has(page.slug));
  if (rest.length) sidebar.push({ text: language === "en" ? "Other" : "其他", items: rest.map(linkFor) });
  return sidebar;
}

export function generateHelp() {
  const zh = pagesFor(fs.readFileSync(path.join(root, "../docs/user/help.md"), "utf8"), "zh");
  const en = pagesFor(fs.readFileSync(path.join(root, "../docs/user/help.en.md"), "utf8"), "en");
  validateLocales(zh, en); // 写入前校验，避免英文缺章时留下半份生成产物。
  const sidebars = { root: generate(zh, "zh"), en: generate(en, "en") };
  fs.mkdirSync(path.join(root, ".vitepress"), { recursive: true });
  fs.writeFileSync(path.join(root, ".vitepress/sidebar.generated.json"), JSON.stringify(sidebars, null, 2));
  console.log(`split-help: 中文 ${zh.length} 页、英文 ${en.length} 页，各 ${GROUPS.length} 组`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) generateHelp();
