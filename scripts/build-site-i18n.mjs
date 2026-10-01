#!/usr/bin/env node
// 由中文源页 site/index.html 与 site-i18n/<lang>.json 生成官网各语言静态页，并维护生成区与 sitemap。
//
//   node scripts/build-site-i18n.mjs           写入：site/<lang>/index.html、site/index.html 的生成区、site/home-sitemap.xml
//   node scripts/build-site-i18n.mjs --check   只校验：缺译文、拉丁语系页面残留中文、生成物过期时退出码为 1
//
// 为什么静态生成：搜索引擎与 AI 爬虫要在独立网址上直接读到对应语言的 HTML，
// 运行时 JS 替换文字时它们只能看到中文，也无法声明 hreflang。
// 规则：中文源页是唯一的手改入口；site/<lang>/index.html 是生成物，不要手改。
// 无第三方依赖，Node 18+ 即可运行。

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SITE_DIR = path.join(ROOT, "site");
const DICT_DIR = path.join(ROOT, "site-i18n");
const SOURCE = path.join(SITE_DIR, "index.html");
const JSONLD = path.join(SITE_DIR, "assets", "jsonld.json");
const SITEMAP = path.join(SITE_DIR, "home-sitemap.xml");
const ORIGIN = "https://aster.foo";

// MARK: - 配置

/** 站点语言。zh 是源页；path 是对外网址；hreflang 用 zh-Hans 覆盖所有简体中文读者，不限地区 */
const LANGS = [
  { code: "zh", label: "中文", htmlLang: "zh-CN", hreflang: "zh-Hans", ogLocale: "zh_CN", path: "/", menuLabel: "语言" },
  { code: "en", label: "English", htmlLang: "en", hreflang: "en", ogLocale: "en_US", path: "/en/", menuLabel: "Language" },
  { code: "ja", label: "日本語", htmlLang: "ja", hreflang: "ja", ogLocale: "ja_JP", path: "/ja/", menuLabel: "言語" },
  { code: "de", label: "Deutsch", htmlLang: "de", hreflang: "de", ogLocale: "de_DE", path: "/de/", menuLabel: "Sprache" },
  { code: "fr", label: "Français", htmlLang: "fr", hreflang: "fr", ogLocale: "fr_FR", path: "/fr/", menuLabel: "Langue" },
];
/** 语言都不匹配时的默认页：面向全球访客用英文 */
const X_DEFAULT = "en";

/** 含内联标记的标题：整段替换 innerHTML，译文在 <lang>.json 的 rich 里 */
const RICH_IDS = ["hero-title", "workspace-title", "voices-title", "closing-title"];
/** 需要翻译的属性 */
const TRANSLATED_ATTRS = ["aria-label", "alt", "title"];
/** site.js 运行时通过 window.asterT 查询的文案；译文取自 text，注入为 window.ASTER_STRINGS */
const RUNTIME_KEYS = [
  "暂停动效", "播放动效", "暂停", "播放", "打开导航", "关闭导航",
  "已补全为 ", "。这是演示，没有执行命令。",
  "打包并签名 Aster.app", "生成并校验 DMG", "构建原生 SSH 运行时",
  "终端与 Markdown 文档，在同一个原生窗口里。", "Aster 实际窗口：左侧标签栏、中间终端、右侧 Markdown 预览",
  "专注终端时，侧栏与文件面板都能收起。", "Aster 实际终端窗口，显示公开演示目录和配置文件",
  "截图暂时无法载入，请重新选择。",
];
const HAN = /[\u4e00-\u9fff]/;

// MARK: - 小工具

const pageUrl = (lang) => ORIGIN + lang.path;
const escText = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escAttr = (s) => escText(s).replace(/"/g, "&quot;");
/** 词典键是浏览器解码后的文字，查表前把源 HTML 里的常见实体解码 */
const decode = (s) => s.replace(/&nbsp;/g, "\u00a0").replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
/** JSON 内联进 <script> 时防止提前闭合 */
const inlineJson = (v) => JSON.stringify(v).replace(/</g, "\\u003c");

/** 把 <!-- i18n:NAME:start -->…<!-- i18n:NAME:end --> 之间的内容换成 content */
function setRegion(html, name, content) {
  const re = new RegExp(`<!-- i18n:${name}:start -->[\\s\\S]*?<!-- i18n:${name}:end -->`);
  if (!re.test(html)) throw new Error(`site/index.html 缺少生成区标记 i18n:${name}`);
  return html.replace(re, () => `<!-- i18n:${name}:start -->${content}<!-- i18n:${name}:end -->`);
}

// MARK: - 各生成区的内容

/** head 生成区：canonical、全部语言的 hreflang、og:url 与 og:locale */
function headRegion(lang) {
  const lines = [`<link rel="canonical" href="${pageUrl(lang)}">`];
  for (const l of LANGS) lines.push(`<link rel="alternate" hreflang="${l.hreflang}" href="${pageUrl(l)}">`);
  lines.push(`<link rel="alternate" hreflang="x-default" href="${pageUrl(LANGS.find((l) => l.code === X_DEFAULT))}">`);
  lines.push(`<meta property="og:url" content="${pageUrl(lang)}">`);
  lines.push(`<meta property="og:locale" content="${lang.ogLocale}">`);
  for (const l of LANGS) if (l !== lang) lines.push(`<meta property="og:locale:alternate" content="${l.ogLocale}">`);
  return "\n  " + lines.join("\n  ") + "\n  ";
}

/** 语言菜单：纯链接，不依赖 JS 也能切换；当前语言标 aria-current */
function menuRegion(lang) {
  const items = LANGS.map((l) =>
    `<a href="${l.path}" hreflang="${l.hreflang}" lang="${l.htmlLang}" data-lang="${l.code}"${l === lang ? ' aria-current="page"' : ""}>${escText(l.label)}</a>`);
  return `
        <details class="lang-menu" id="lang-menu">
          <summary aria-label="${escAttr(`${lang.menuLabel}: ${lang.label}`)}"><svg aria-hidden="true"><use href="#i-globe"/></svg><span class="lang-label">${escText(lang.label)}</span><svg class="chev" aria-hidden="true"><use href="#i-chevron"/></svg></summary>
          <div class="lang-list">
            ${items.join("\n            ")}
          </div>
        </details>
        `;
}

/** 运行时文案：只给非中文页注入 site.js 需要的那几条 */
function runtimeRegion(lang, dict, missing) {
  if (lang.code === "zh") return "";
  const strings = {};
  for (const key of RUNTIME_KEYS) {
    if (key in dict.text) strings[key] = dict.text[key];
    else missing.push(`runtime: ${key}`);
  }
  return `\n  <script>window.ASTER_STRINGS = ${inlineJson(strings)};</script>\n  `;
}

/** 结构化数据：jsonld.json 逐条翻译，FAQ 与本页 WebPage 节点带上语言与网址 */
function jsonldRegion(lang, dict, title, missing) {
  const source = JSON.parse(fs.readFileSync(JSONLD, "utf8"));
  const translate = (value) => {
    if (typeof value === "string") {
      if (lang.code === "zh" || !HAN.test(value)) return value;
      const tr = dict.text[value] ?? dict.jsonld?.[value];
      if (tr === undefined) { missing.push(`jsonld: ${value}`); return value; }
      return tr;
    }
    if (Array.isArray(value)) return value.map(translate);
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, translate(v)]));
    return value;
  };
  const data = translate(source);
  for (const node of data["@graph"]) {
    if (node["@type"] === "FAQPage") {
      node["@id"] = `${pageUrl(lang)}#faq`;
      node.inLanguage = lang.htmlLang;
    }
  }
  // 每个语言页一个 WebPage 节点，把网址、语言与软件实体连起来
  data["@graph"].push({
    "@type": "WebPage",
    "@id": `${pageUrl(lang)}#webpage`,
    url: pageUrl(lang),
    name: title,
    inLanguage: lang.htmlLang,
    isPartOf: { "@id": `${ORIGIN}/#website` },
    about: { "@id": `${ORIGIN}/#software` },
    mainEntity: { "@id": `${pageUrl(lang)}#faq` },
  });
  return `\n  <script type="application/ld+json" id="jsonld">${inlineJson(data)}</script>\n  `;
}

/** 给某个语言填好全部生成区 */
function fillRegions(html, lang, dict, title, missing) {
  html = setRegion(html, "head", headRegion(lang));
  html = setRegion(html, "jsonld", jsonldRegion(lang, dict, title, missing));
  html = setRegion(html, "menu", menuRegion(lang));
  html = setRegion(html, "runtime", runtimeRegion(lang, dict, missing));
  return html;
}

// MARK: - 正文翻译

/**
 * 把中文源页翻译成目标语言。
 * 单遍处理源 HTML 的标签与文本：查表只看中文原文，所以日文译文里的汉字不会被误判为未翻译。
 * 生成区先换成占位符，避免语言菜单里的「中文」等自称被当作待翻译文字。
 */
function translateBody(html, dict, used, missing) {
  const regions = [];
  html = html.replace(/<!-- i18n:(\w+):start -->[\s\S]*?<!-- i18n:\1:end -->/g, (m) => {
    regions.push(m);
    return `\u0000${regions.length - 1}\u0000`;
  });

  const tokens = html.split(/(<!--[\s\S]*?-->|<script\b[\s\S]*?<\/script>|<style\b[\s\S]*?<\/style>|<[^>]*>)/);
  const out = [];
  let inTitle = false;
  for (let i = 0; i < tokens.length; i++) {
    const tok = tokens[i];
    if (i % 2 === 0) {
      // 文本：<title> 交给 meta 处理；其余带汉字的整段（去首尾空白）查表
      const key = decode(tok.trim());
      if (inTitle || !HAN.test(key)) { out.push(tok); continue; }
      const tr = dict.text[key];
      if (tr === undefined) { missing.push(`text: ${key}`); out.push(tok); continue; }
      used.add(key);
      const lead = tok.match(/^\s*/)[0];
      const trail = tok.match(/\s*$/)[0];
      out.push(lead + escText(tr) + trail);
      continue;
    }
    if (tok.startsWith("<!--")) continue; // 开发注释不进生成页
    if (tok.startsWith("<script") || tok.startsWith("<style")) { out.push(tok); continue; }

    inTitle = /^<title\b/i.test(tok);
    let tag = tok;
    for (const attr of TRANSLATED_ATTRS) {
      tag = tag.replace(new RegExp(`(\\s${attr}=")([^"]*)(")`, "g"), (m, a, value, b) => {
        const key = decode(value);
        if (!HAN.test(key)) return m;
        const tr = dict.text[key];
        if (tr === undefined) { missing.push(`attr ${attr}: ${key}`); return m; }
        used.add(key);
        return a + escAttr(tr) + b;
      });
    }
    out.push(tag);

    // 富文本标题：输出译文后跳过源里的子节点，直到对应的闭合标签
    const id = tok.match(/\sid="([^"]+)"/)?.[1];
    if (id && RICH_IDS.includes(id)) {
      const name = tok.match(/^<([a-z0-9]+)/i)[1];
      if (!dict.rich?.[id]) missing.push(`rich: #${id}`);
      out.push(dict.rich?.[id] ?? "");
      let depth = 0;
      for (i += 1; i < tokens.length; i++) {
        const t = tokens[i];
        if (i % 2 === 0) continue;
        if (new RegExp(`^<${name}\\b`, "i").test(t)) depth += 1;
        else if (new RegExp(`^</${name}>`, "i").test(t)) {
          if (depth === 0) { out.push(t); break; }
          depth -= 1;
        }
      }
    }
  }
  // 去掉注释后整行只剩空白的，连同换行一起删
  return out.join("").replace(/\n[ \t]+(?=\n)/g, "").replace(/\u0000(\d+)\u0000/g, (m, n) => regions[Number(n)]);
}

/** 页面级 meta：html lang、标题、描述、分享卡片文案、品牌链接回到本语言首页 */
function applyMeta(html, lang, dict, missing) {
  const meta = dict.meta ?? {};
  for (const k of ["title", "description", "ogImageAlt"]) if (!meta[k]) missing.push(`meta: ${k}`);
  const setContent = (attr, name, value) => {
    const re = new RegExp(`(<meta ${attr}="${name}" content=")[^"]*(">)`);
    if (!re.test(html)) throw new Error(`site/index.html 缺少 <meta ${attr}="${name}">`);
    html = html.replace(re, (m, a, b) => a + escAttr(value ?? "") + b);
  };
  html = html.replace(/<html lang="[^"]*">/, `<html lang="${lang.htmlLang}">`);
  html = html.replace(/<title>[^<]*<\/title>/, `<title>${escText(meta.title ?? "")}</title>`);
  setContent("name", "description", meta.description);
  setContent("property", "og:title", meta.title);
  setContent("property", "og:description", meta.description);
  setContent("property", "og:image:alt", meta.ogImageAlt);
  setContent("name", "twitter:title", meta.title);
  setContent("name", "twitter:description", meta.description);
  html = html.replace(/class="brand" href="\/"/g, `class="brand" href="${lang.path}"`);
  return html;
}

// MARK: - sitemap

/** 每个语言网址一条，互相列出 hreflang 备选；lastmod 沿用现有文件里首页那条（发版时手动改） */
function buildSitemap() {
  const current = fs.existsSync(SITEMAP) ? fs.readFileSync(SITEMAP, "utf8") : "";
  const lastmod = current.match(/<lastmod>([^<]+)<\/lastmod>/)?.[1] ?? new Date().toISOString().slice(0, 10);
  const alternates = [...LANGS.map((l) => [l.hreflang, pageUrl(l)]), ["x-default", pageUrl(LANGS.find((l) => l.code === X_DEFAULT))]]
    .map(([h, u]) => `    <xhtml:link rel="alternate" hreflang="${h}" href="${u}"/>`).join("\n");
  const urls = LANGS.map((l) => `  <url>
    <loc>${pageUrl(l)}</loc>
    <lastmod>${lastmod}</lastmod>
    <changefreq>weekly</changefreq>
    <priority>${l.code === "zh" ? "1.0" : "0.9"}</priority>
${alternates}
  </url>`).join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!-- 落地页 sitemap，由 scripts/build-site-i18n.mjs 生成。发版时只改这里的 lastmod，再重新运行脚本。 -->
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">
${urls}
</urlset>
`;
}

// MARK: - 主流程

function main() {
  const check = process.argv.includes("--check");
  const source = fs.readFileSync(SOURCE, "utf8");
  const zhTitle = decode(source.match(/<title>([^<]*)<\/title>/)[1]);
  const outputs = new Map(); // 绝对路径 → 期望内容
  const problems = [];
  const warnings = [];

  const zh = LANGS[0];
  const zhMissing = [];
  outputs.set(SOURCE, fillRegions(source, zh, { text: {} }, zhTitle, zhMissing));
  problems.push(...zhMissing.map((m) => `zh ${m}`));

  for (const lang of LANGS.slice(1)) {
    const dictPath = path.join(DICT_DIR, `${lang.code}.json`);
    const dict = JSON.parse(fs.readFileSync(dictPath, "utf8"));
    const used = new Set(RUNTIME_KEYS);
    const missing = [];
    let html = translateBody(source, dict, used, missing);
    html = applyMeta(html, lang, dict, missing);
    html = fillRegions(html, lang, dict, dict.meta?.title ?? "", missing);
    html = html.replace(/^<!doctype html>\n/i, (m) =>
      `${m}<!-- Generated by scripts/build-site-i18n.mjs from site/index.html and site-i18n/${lang.code}.json. Do not edit. -->\n`);

    // 拉丁语系页面不应再有汉字（语言菜单里的「中文」「日本語」自称除外）
    if (!["ja"].includes(lang.code)) {
      // 语言菜单是各语言自称；运行时文案表的键本来就是中文
      const visible = html.replace(/<!-- i18n:(menu|runtime):start -->[\s\S]*?<!-- i18n:\1:end -->/g, "");
      const leftover = visible.match(/[^<>"]{0,20}[\u4e00-\u9fff][^<>"]{0,20}/g);
      if (leftover && !missing.length) missing.push(...leftover.slice(0, 5).map((s) => `残留中文: ${s.trim()}`));
    }
    problems.push(...missing.map((m) => `${lang.code} ${m}`));
    const unused = Object.keys(dict.text).filter((k) => !used.has(k) && !jsonldUses(k));
    if (unused.length) warnings.push(`${lang.code} 有 ${unused.length} 条词典键已不在页面里：${unused.slice(0, 5).join(" | ")}${unused.length > 5 ? " …" : ""}`);
    outputs.set(path.join(SITE_DIR, lang.code, "index.html"), html);
  }
  outputs.set(SITEMAP, buildSitemap());

  warnings.forEach((w) => console.warn(`警告：${w}`));
  if (problems.length) {
    console.error(`缺少译文或残留中文，共 ${problems.length} 处：`);
    problems.forEach((p) => console.error(`  ${p}`));
    process.exit(1);
  }

  const stale = [...outputs].filter(([file, content]) => !fs.existsSync(file) || fs.readFileSync(file, "utf8") !== content);
  if (check) {
    if (stale.length) {
      console.error("生成物已过期，请运行 node scripts/build-site-i18n.mjs：");
      stale.forEach(([file]) => console.error(`  ${path.relative(ROOT, file)}`));
      process.exit(1);
    }
    console.log(`官网多语言检查通过：${LANGS.length} 种语言，生成物是最新的。`);
    return;
  }
  for (const [file, content] of stale) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
    console.log(`写入 ${path.relative(ROOT, file)}`);
  }
  if (!stale.length) console.log("生成物已是最新，无需写入。");
}

/** FAQ 问答同时出现在正文与 JSON-LD；正文已用到就算用到，这里只为不误报 JSON-LD 独有的键 */
let jsonldStrings = null;
function jsonldUses(key) {
  if (!jsonldStrings) {
    jsonldStrings = new Set();
    (function walk(v) {
      if (typeof v === "string") jsonldStrings.add(v);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    })(JSON.parse(fs.readFileSync(JSONLD, "utf8")));
  }
  return jsonldStrings.has(key);
}

main();
