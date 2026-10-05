#!/usr/bin/env node
// 双语生成与部署根路径回归检查；先运行 docs:build，不启动浏览器或部署。
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pagesFor, parseSections, validateLocales } from "./split-help.mjs";
import { localeSwitchTarget } from "../.vitepress/theme/locale-links.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const site = path.join(root, "site");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const zh = pagesFor(read("docs/user/help.md"), "zh");
const en = pagesFor(read("docs/user/help.en.md"), "en");
validateLocales(zh, en);
assert.equal(en.length, 21);

// 代码中的 ##、异种或过短围栏不能截断章节；缺章不能悄悄构建成功。
const fenced = "## First\n````bash\n## Not a page\n```\n~~~\n````\n## Second\ntext";
assert.deepEqual(parseSections(fenced).map((page) => page.title), ["First", "Second"]);
assert.throws(() => parseSections("## First\n```\n## Hidden"), /未闭合/);
assert.throws(() => pagesFor("## Getting Started\ntext\n## Getting Started\nagain", "en"), /重复 slug/);
assert.throws(() => pagesFor("## Unregistered English Chapter\ntext", "en"), /未登记/);
assert.throws(() => validateLocales(zh, en.slice(1)), /不一致/);

// 技术命令与参数不因翻译丢失；仅注释与两个演示 prompt/通知正文允许翻译。
function commands(pages) {
  return pages.flatMap((page) => {
    const fences = page.body.join("\n").matchAll(/^```[^\n]*\n([\s\S]*?)^```\s*$/gm);
    return [...fences].flatMap((match) => match[1].split("\n").map((line) => line.split(/\s+#/)[0].trim()).filter(Boolean));
  }).map((line) => line.replace(/(aster agent prompt w1:p2) "[^"]*"/, '$1 "<prompt>"')
    .replace(/(aster notification show) "[^"]*" --body "[^"]*"/, '$1 "<title>" --body "<body>"'));
}
assert.deepEqual(commands(en), commands(zh));

const origin = "https://aster.foo";
assert.equal(localeSwitchTarget("/docs/faq#why", `${origin}/docs/en/faq#why`, "/docs/"), "/docs/faq");
assert.equal(localeSwitchTarget("/docs/en/faq?view=1#中文", `${origin}/docs/faq#中文`, "/docs/"), "/docs/en/faq?view=1");
assert.equal(localeSwitchTarget("/docs/en/themes#cursor", `${origin}/docs/en/faq`, "/docs/"), null);
assert.equal(localeSwitchTarget("/docs/en/faq", `${origin}/docs/faq`, "/docs/"), null);
assert.equal(localeSwitchTarget("https://example.org/docs/en/faq#cursor", `${origin}/docs/faq`, "/docs/"), null);
assert.equal(localeSwitchTarget("/en/#workspace", `${origin}/docs/faq`, "/docs/"), null);

const entities = (text) => text.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
const pagePath = (prefix, slug) => prefix + (slug === "index" ? "index.html" : `${slug}.html`);
const documents = [...zh.map((page) => pagePath("docs/", page.slug)), ...en.map((page) => pagePath("docs/en/", page.slug))];
const landings = ["index.html", "en/index.html", "ja/index.html", "de/index.html", "fr/index.html"];
const htmlByPath = new Map([...documents, ...landings].map((file) => [file, fs.readFileSync(path.join(site, file), "utf8")]));

for (const [pages, prefix, lang] of [[zh, "docs/", "zh-CN"], [en, "docs/en/", "en"]]) {
  const actual = fs.readdirSync(path.join(site, prefix)).filter((file) => file.endsWith(".html") && file !== "404.html");
  assert.deepEqual(actual.sort(), pages.map((page) => pagePath("", page.slug)).sort(), `${prefix} 页面集合`);
  for (const page of pages) {
    const html = htmlByPath.get(pagePath(prefix, page.slug));
    assert.match(html, new RegExp(`<html lang="${lang}"`));
    assert.ok(html.includes(page.title.replace(/&/g, "&amp;")), page.title);
    if (lang === "en") {
      const main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/)?.[1];
      assert.ok(main?.length > 100, `${page.slug} 不是空壳`);
      assert.doesNotMatch(main, /\p{Script=Han}/u, `${page.slug} 英文正文残留中文`);
    }
    const otherPrefix = lang === "en" ? "/docs/" : "/docs/en/";
    const counterpart = otherPrefix + (page.slug === "index" ? "" : page.slug);
    assert.ok(html.includes(`href="${counterpart}"`), `${page.slug} 对应语言切换链接`);
  }
}

let links = 0;
for (const [file, html] of htmlByPath) {
  for (const match of html.matchAll(/\b(?:href|src)="([^"]*)"/g)) {
    const href = entities(match[1]);
    if (!href || /^(data:|mailto:|tel:)/.test(href)) continue;
    const url = new URL(href, `${origin}/${file}`);
    if (url.origin !== origin) continue;
    const pathname = decodeURIComponent(url.pathname).replace(/^\//, "");
    const candidates = [pathname, `${pathname}.html`, path.join(pathname, "index.html")];
    const target = candidates.find((candidate) => fs.existsSync(path.join(site, candidate)) && fs.statSync(path.join(site, candidate)).isFile());
    assert.ok(target, `${file}: 缺少 ${href}`);
    if (url.hash && target.endsWith(".html")) {
      const targetHtml = htmlByPath.get(target) ?? fs.readFileSync(path.join(site, target), "utf8");
      const anchor = decodeURIComponent(url.hash.slice(1));
      assert.ok([...targetHtml.matchAll(/\bid="([^"]+)"/g)].some((id) => entities(id[1]) === anchor), `${file}: 缺少锚点 ${href}`);
    }
    links++;
  }
}

for (const file of landings) {
  const html = htmlByPath.get(file);
  const docsLinks = [...html.matchAll(/href="(\/docs\/[^"#]*)"/g)].map((match) => match[1]);
  assert.equal(docsLinks.length, 6, `${file} 文档入口数量`);
  assert.ok(docsLinks.every((href) => file === "index.html" ? !href.startsWith("/docs/en/") : href.startsWith("/docs/en/")), `${file} 文档语言`);
  if (file.startsWith("ja/")) assert.match(html, /ドキュメント（英語）/);
  if (file.startsWith("de/")) assert.match(html, /Doku \(Englisch\)/);
  if (file.startsWith("fr/")) assert.match(html, /Docs \(anglais\)/);
}

const sitemap = read("site/docs/sitemap.xml");
for (const file of documents) {
  const route = file.replace(/(?:index)?\.html$/, "");
  assert.ok(sitemap.includes(`<loc>${origin}/${route}</loc>`), `sitemap: ${route}`);
}
assert.match(read("README.md"), /\[Read the user guide\]\(https:\/\/aster\.foo\/docs\/en\/\)/);
console.log(`docs:check 通过：${zh.length} 中文页 + ${en.length} 英文页、5 个落地页、${links} 个站内链接/资源/锚点；围栏、命令、语言切换与回退标签一致。`);
