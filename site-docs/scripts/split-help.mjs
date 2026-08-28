#!/usr/bin/env node
/**
 * 把 docs/user/help.md 按「## 章节」切分成 VitePress 多页文档。
 *
 * help.md 是唯一内容源：本脚本在每次 docs:dev / docs:build 前运行，
 * 生成 guide/<slug>.md 与 .vitepress/sidebar.generated.json，均不入库。
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");            // site-docs/
const helpPath = path.resolve(root, "../docs/user/help.md");
const outDir = path.resolve(root, "guide");
const sidebarPath = path.resolve(root, ".vitepress/sidebar.generated.json");

/** 已知章节 → slug；新章节自动落到 section-N，脚本永不失败 */
const SLUGS = {
  "Aster 能做什么": "index",
  "开始使用": "getting-started",
  "诊断日志与反馈": "diagnostics",
  "标签与三种布局": "tabs-and-layouts",
  "常用目录": "frequent-directories",
  "分屏与 Pane": "splits-and-panes",
  "文件浏览器、编辑与预览": "files-and-preview",
  "查找与命令面板": "search-and-command-palette",
  "Recipes 与会话恢复": "recipes-and-restore",
  "CLI 与深链": "cli-and-deep-links",
  "Working with Agents": "working-with-agents",
  "项目记忆（Session Memory）": "session-memory",
  "十类设置": "settings",
  "软件更新": "software-update",
  "常见问题": "faq",
  "外观主题": "themes",
};

/** 侧栏分组；未列出的章节归入「其他」 */
const GROUPS = [
  { text: "开始", slugs: ["index", "getting-started"] },
  { text: "界面", slugs: ["tabs-and-layouts", "splits-and-panes", "files-and-preview", "search-and-command-palette"] },
  { text: "工作流", slugs: ["recipes-and-restore", "cli-and-deep-links", "working-with-agents", "session-memory", "frequent-directories"] },
  { text: "配置", slugs: ["settings", "themes", "software-update", "diagnostics", "faq"] },
];

const src = fs.readFileSync(helpPath, "utf8");
const lines = src.split("\n");

// ---- 按 ## 切分（跳过代码围栏内的行） ----
const sections = [];
let current = null;
let inFence = false;
for (const line of lines) {
  if (/^\s*(```|~~~)/.test(line)) inFence = !inFence;
  const m = !inFence && line.match(/^## (.+?)\s*$/);
  if (m) {
    current = { title: m[1], body: [] };
    sections.push(current);
    continue;
  }
  if (current) current.body.push(line);
}

if (sections.length === 0) {
  console.error("split-help: 在 " + helpPath + " 中未找到任何「## 章节」");
  process.exit(1);
}

// ---- 生成页面 ----
fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });

function shiftHeadings(body) {
  let fenced = false;
  return body.map((line) => {
    if (/^\s*(```|~~~)/.test(line)) fenced = !fenced;
    if (fenced) return line;
    const m = line.match(/^(#{3,6}) /);
    return m ? line.slice(1) : line; // ### → ##、#### → ### …
  });
}

const pages = [];
let auto = 0;
for (const sec of sections) {
  auto += 1;
  const slug = SLUGS[sec.title] ?? `section-${String(auto).padStart(2, "0")}`;
  const body = shiftHeadings(sec.body).join("\n").trim();
  const fm = ["---", `title: ${JSON.stringify(sec.title)}`, "---", "", `# ${sec.title}`, "", body, ""].join("\n");
  fs.writeFileSync(path.join(outDir, `${slug}.md`), fm);
  pages.push({ title: sec.title, slug });
}

// ---- 生成侧栏 ----
const bySlug = new Map(pages.map((p) => [p.slug, p]));
const used = new Set();
const sidebar = [];
for (const g of GROUPS) {
  const items = [];
  for (const slug of g.slugs) {
    const p = bySlug.get(slug);
    if (!p) continue;
    used.add(slug);
    items.push({ text: p.title, link: slug === "index" ? "/" : `/${slug}` });
  }
  if (items.length) sidebar.push({ text: g.text, items });
}
const rest = pages.filter((p) => !used.has(p.slug));
if (rest.length) {
  sidebar.push({ text: "其他", items: rest.map((p) => ({ text: p.title, link: `/${p.slug}` })) });
}

fs.mkdirSync(path.dirname(sidebarPath), { recursive: true });
fs.writeFileSync(sidebarPath, JSON.stringify(sidebar, null, 2));

console.log(`split-help: ${pages.length} 页 → guide/，侧栏 ${sidebar.length} 组`);
