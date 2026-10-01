# 官网与 GEO

官网 <https://aster.foo/> 由两部分组成：手写的静态落地页，以及从用户帮助生成的 VitePress 文档站。
本页说明目录结构、本地预览、多语言机制、内容政策，以及让传统搜索引擎和生成式搜索准确引用 Aster 的文件与维护规则。

GEO 指 Generative Engine Optimization：让 ChatGPT、Claude、Perplexity 等生成式搜索能抓取、理解并准确引用本站。
它和传统 SEO 共用同一套基础：可抓取、结构化、事实一致。

## 目录结构

```
site/                      # 部署根目录（wrangler.jsonc 的 assets.directory）
├── index.html             # 手写落地页，不经构建
├── robots.txt             # 爬虫规则，见「GEO 文件」
├── llms.txt               # 给大模型读的站点摘要
├── sitemap.xml            # sitemap 索引：汇总下面两个 sitemap
├── home-sitemap.xml       # 落地页 sitemap
├── assets/
│   ├── style.css          # 落地页样式与设计 token
│   ├── site.js            # 交互演示等动态内容
│   ├── i18n.js            # 多语言词典与切换器
│   ├── fonts.css、fonts/  # 自托管网页字体（脚本生成）
│   ├── jsonld.json        # 结构化数据源文件，内联进 index.html
│   ├── shots/             # 真实应用截图
│   └── social-card.*      # Open Graph 分享图
└── docs/                  # 文档站构建产物，不入库（.gitignore）

site-docs/                 # 文档站构建工程（VitePress）
├── .vitepress/config.mjs  # base=/docs/、outDir=../site/docs、cleanUrls
└── scripts/split-help.mjs # 把 docs/user/help.md 按「## 章节」切成多页
```

- 文档站的唯一内容源是 `docs/user/help.md`。构建前 `split-help.mjs` 按二级标题切页，生成物不入库。
- 文档页 slug 来自 `split-help.mjs` 的 `SLUGS` 表。表里没有的章节会落到 `section-NN`，编号随章节顺序变化，不能当作稳定链接。对外链接（`llms.txt`、落地页、README）只用 `SLUGS` 里登记过的 slug。
- `help.md` 里的代码围栏必须成对。多出一个 ` ``` ` 会让切页脚本把后面所有章节当成代码块，这些页面在线上全部 404。
- 部署由 Cloudflare Workers Builds 完成：构建命令是 `cd site-docs && npm ci && npm run docs:build`，然后以 `site/` 为根上传静态资产（见 `wrangler.jsonc`）。
- 线上开启 clean URL：`/docs/faq` 对应 `site/docs/faq.html`，`.html` 形式会被重定向到无后缀形式。

## 本地预览

```bash
cd site-docs && npm ci && npm run docs:build && cd ..
./scripts/serve-site.sh          # 默认 http://localhost:4321
./scripts/serve-site.sh 8080     # 指定端口
```

- 不要用裸的 `python3 -m http.server`。它不做 clean URL 回退，点任何文档链接都会 404。`serve-site.sh` 补上了和线上一致的回退规则。
- 只改落地页时不必重建文档站，直接运行 `serve-site.sh` 即可。
- `npm run docs:dev` 可以热更新预览文档站，但它不经过站点根，自托管字体会回退到系统字体，这是预期行为。

## 字体自托管

- 字体文件放在 `site/assets/fonts/`，由 `scripts/fetch-webfonts.py` 从 Google Fonts 抓取并生成 `fonts.css`。只在字体清单或字重变化时重跑，不要手改 `fonts.css`。
- 不能直接链接 `fonts.googleapis.com`：该域名在中国大陆不可达，访客要等到超时才会回退，首屏明显变慢。
- 只保留 latin 与 latin-ext 子集。中文不加载网页字体，目标用户都是 macOS，系统自带的宋体与苹方由 `style.css` 的回退链接管。
- 文档站通过 `config.mjs` 的 `head` 引用同一份 `/assets/fonts.css`，两边字体保持一致。

## 多语言（i18n.js）

落地页支持中文、English、日本語、Deutsch、Français 五种语言。中文写在 HTML 里，其他四种语言在 `site/assets/i18n.js` 的词典里。

工作方式：

1. **中文文本节点就是键。** 页面加载后，脚本遍历 `<body>` 里的文本节点，把去掉首尾空白后能在词典里查到的节点缓存下来。切换语言时只替换这些节点的文字，切回中文即还原。
2. **富文本按选择器整体替换。** 含 `<br>`、`<em>`、`<kbd>` 等内联标记的元素无法按文本节点翻译，登记在 `RICH` 数组里，按 CSS 选择器整体替换 `innerHTML`。
3. **页面元信息单独处理。** `<title>` 与 `meta[name="description"]` 的各语言版本在 `META` 里。
4. **动态内容走 `window.asterT`。** `site.js` 生成的文字（例如补全演示的提示条）调用 `asterT("中文原文")` 取当前语言文案。
5. **初始语言**按「上次手动选择（localStorage）→ 浏览器语言 → 英文」决定。

新增或修改文案的规则：

- 每条新增中文文案必须同时补齐 en、ja、de、fr 四种翻译。缺翻译的节点会在其他语言下显示中文，混在页面里很难发现。
- 修改中文原文等于换了键。词典里的旧键要一起改，否则这个节点不再被翻译。
- 一个文本节点只放一句完整文案。被内联标签拆开的句子，要么整体登记进 `RICH`，要么调整结构让每段都是独立的键。
- `RICH` 的选择器必须在页面里唯一匹配，否则只有第一个元素会被替换。
- 数字和事实（版本号、规格数量、主题数量）在五种语言里必须一致，改一处就要检查全部语言。

## 真实截图

- 截图放在 `site/assets/shots/`，必须来自真实运行的 Aster，不用设计稿或动画演示冒充真实画面。
- 截图内容只能来自公开的示例项目（fixture），例如本仓库或公开的开源仓库。不出现个人项目、内部代码或真实会话内容。
- 画面里不能出现本机用户名、主目录路径、主机名、令牌、私钥、Shell 历史或通知内容。开发期截图常带本机路径，上线前必须用干净的账户或示例目录重新采集。
- 截图对应的功能必须已经发布。只在开发分支上的功能不能出现在官网截图里。
- 替换截图时同步更新 `<img>` 的 `alt` 文案，并为 `alt` 补齐四种翻译。

## 用户评价内容政策

- 只发布可以核实的真实反馈：能指向公开来源（GitHub Issue 或 Discussion、公开帖子），或者有反馈者明确同意公开的记录。
- 引用时保留原意，不改写成更好听的说法；署名方式按反馈者的意愿处理。
- 占位文案不得冒充真实口碑。开发期需要占位时，必须在页面上明显标注为示例，或者不上线这个区块。
- 不发布购买、交换或请求得来的评价，也不展示无法核实的用户数、下载量或 star 数。推广规则见 [公开推广资料](../promotion.md)。

## GEO 文件

| 文件 | 作用 |
| --- | --- |
| `site/robots.txt` | 允许所有爬虫，并显式允许常见 AI 爬虫；指向 sitemap 索引 |
| `site/sitemap.xml` | sitemap 索引，汇总落地页与文档站 |
| `site/home-sitemap.xml` | 落地页 URL，带 `lastmod` 与 `changefreq` |
| `site/docs/sitemap.xml` | 文档站构建时由 VitePress 自动生成，不手改 |
| `site/llms.txt` | 按 [llmstxt.org](https://llmstxt.org/) 格式写的站点摘要：中英文定义、核心事实清单、文档链接 |
| `site/assets/jsonld.json` | schema.org 结构化数据（`@graph`）：`Organization`、`WebSite`、`SoftwareApplication`、`FAQPage` |
| `site/index.html` | 内联 `jsonld.json` 的 `<script type="application/ld+json">`，以及 canonical、Open Graph、Twitter Card |

`robots.txt` 显式列出的 AI 爬虫：GPTBot、ChatGPT-User、OAI-SearchBot、ClaudeBot、Claude-SearchBot、anthropic-ai、PerplexityBot、Google-Extended、Applebot-Extended、CCBot、Bytespider。
显式列出是为了让各家不依赖对 `*` 分组的不同解释。新增爬虫时照同样格式追加一个分组。

### 内容规则

- **只写已发布的能力。** 事实以已发布版本的 `docs/user/help.md`、README 和发行说明为准。开发分支上的功能等发布后再加。
- **每条事实能被单独引用。** 生成式搜索常常只截取一两句话，所以每条 FAQ 答案和事实清单条目都要自成一体，不依赖上下文，不用「如上所述」。
- **事实处处一致。** 版本号、系统要求、规格数量、主题数量、语言数量在 `index.html`、`llms.txt`、`jsonld.json`、README 里必须一致。
- **隐私表述要精确。** Aster 不收集使用数据，但崩溃报告是可选功能（默认关闭），把项目记忆交给 CLI Agent 提炼也会发送摘要（默认关闭）。对外不写「从不联网」「绝不上传任何数据」这类绝对说法。
- **系统要求写全。** 当前安装包只包含 arm64 版本，系统要求要同时写 macOS 14+ 与 Apple 芯片。构建方式改变后同步更新。
- `jsonld.json` 是唯一源文件。修改后把内容同步到 `index.html` 的内联脚本，两者必须完全一致。

### 发版时同步

每次发布正式版（与「发行说明与官网版本号」提交一起）：

1. `site/index.html` 里所有可见的版本号（例如 `v0.6.15`）。
2. `site/assets/jsonld.json` 的 `softwareVersion` 与 `releaseNotes`，再同步到 `index.html` 的内联 JSON-LD。
3. `site/llms.txt` 的「当前发布版本」一行，包括发布日期。
4. `site/home-sitemap.xml` 的 `lastmod`，改成发布日期。
5. 如果这次发布改变了核心事实（新增大功能、规格数量、主题数量、系统要求），同步检查 FAQ 答案、`featureList` 与 `llms.txt` 的事实清单。
6. `help.md` 新增了「## 章节」时，在 `split-help.mjs` 的 `SLUGS` 里登记固定 slug，再把新页面加进 `llms.txt`。

预览版不改这些文件，官网只描述正式版。

## 验证清单

提交前逐项执行：

```bash
# 结构化数据可以解析
node -e 'JSON.parse(require("fs").readFileSync("site/assets/jsonld.json","utf8"))'

# 内联到 index.html 的 JSON-LD 也可以解析，并且与源文件一致
node -e '
const fs = require("fs");
const html = fs.readFileSync("site/index.html", "utf8");
const m = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
if (!m) throw new Error("index.html 里没有 JSON-LD");
const inline = JSON.parse(m[1]);
const src = JSON.parse(fs.readFileSync("site/assets/jsonld.json", "utf8"));
if (JSON.stringify(inline) !== JSON.stringify(src)) throw new Error("内联 JSON-LD 与 jsonld.json 不一致");
console.log("JSON-LD OK");'

# sitemap 是合法 XML
xmllint --noout site/sitemap.xml site/home-sitemap.xml

# 文档站能完整构建，页面数与 help.md 的章节数一致
cd site-docs && npm ci && npm run docs:build && cd ..

# 本地预览，逐个点击导航、文档入口与下载链接
./scripts/serve-site.sh
```

链接检查：

- `llms.txt` 与 `index.html` 里的每个 `aster.foo` 链接，在本地预览中都要返回 200。可以用下面的命令批量检查：

  ```bash
  grep -o 'https://aster.foo/[^) "]*' site/llms.txt | sort -u | \
    sed 's#https://aster.foo#http://localhost:4321#' | \
    while read -r u; do printf '%s %s\n' "$(curl -s -o /dev/null -w '%{http_code}' "$u")" "$u"; done
  ```

- GitHub 链接（Releases、LICENSE、README）用浏览器或 `curl -I` 确认可以打开。
- 上线后用 [Google 富媒体搜索结果测试](https://search.google.com/test/rich-results) 检查结构化数据，并直接访问 `https://aster.foo/robots.txt` 与 `https://aster.foo/llms.txt` 确认已部署。

多语言检查：

- 在五种语言之间来回切换，确认没有残留中文、没有布局溢出，切回中文后文字完全还原。
- 检查 `<html lang>`、`<title>` 与 description 随语言变化。

纯文案改动不需要运行应用测试，但上面的结构化数据、XML 与链接检查必须执行。没有执行的检查要在提交说明里写明。
