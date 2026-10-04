# 官网与 GEO

官网 <https://aster.foo/> 由两部分组成：手写的静态落地页，以及从用户帮助生成的 VitePress 文档站。
本页说明目录结构、本地预览、多语言机制、内容政策，以及让传统搜索引擎和生成式搜索准确引用 Aster 的文件与维护规则。

GEO 指 Generative Engine Optimization：让 ChatGPT、Claude、Perplexity 等生成式搜索能抓取、理解并准确引用本站。
它和传统 SEO 共用同一套基础：可抓取、结构化、事实一致。

## 目录结构

```
site/                      # 部署根目录（wrangler.jsonc 的 assets.directory）
├── index.html             # 中文落地页：唯一的手改入口（生成区除外）
├── en/ ja/ de/ fr/        # 各语言落地页，由 scripts/build-site-i18n.mjs 生成，不要手改
├── robots.txt             # 爬虫规则，见「GEO 文件」
├── llms.txt               # 给大模型读的站点摘要
├── sitemap.xml            # sitemap 索引：汇总下面两个 sitemap
├── home-sitemap.xml       # 落地页 sitemap（五种语言，带 hreflang），由生成脚本写出
├── assets/
│   ├── style.css          # 落地页样式与设计 token
│   ├── site.js            # 交互演示等动态内容
│   ├── i18n.js            # 运行时辅助：动态文案译文、语言菜单、切换建议
│   ├── fonts.css、fonts/  # 自托管网页字体（脚本生成）
│   ├── jsonld.json        # 结构化数据源文件（中文），生成脚本逐语言翻译后内联
│   ├── shots/             # 真实应用截图
│   └── social-card.*      # Open Graph 分享图
└── docs/                  # 文档站构建产物，不入库（.gitignore）

site-i18n/                 # 落地页译文：en.json、ja.json、de.json、fr.json

site-docs/                 # 文档站构建工程（VitePress）
├── .vitepress/config.mjs  # base=/docs/、outDir=../site/docs、cleanUrls
└── scripts/split-help.mjs # 把中英文用户帮助按「## 章节」切成多页
```

- 文档站的中文内容源是 `docs/user/help.md`，英文内容源是 `docs/user/help.en.md`。构建前 `split-help.mjs` 按二级标题切页，中文生成到 `guide/`，英文到 `en/guide/`，生成物不入库。中文应用内帮助保留原源文件。
- 两种语言共用固定 slug 与侧栏分组；英文需要覆盖完整章节集合。构建会拒绝英文缺章、重复 slug、未知英文标题和未闭合代码围栏。新增或改变用户行为时同步英文翻译，技术命令、快捷键与界面名按现有实现核对。
- 文档页 slug 来自 `split-help.mjs` 的 `SLUGS` 表。表里没有的章节会落到 `section-NN`，编号随章节顺序变化，不能当作稳定链接。对外链接（`llms.txt`、落地页、README）只用 `SLUGS` 里登记过的 slug。
- 两份帮助里的代码围栏必须成对。未闭合围栏会使切页脚本报错，避免后续章节被误当成代码并产生缺页。
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

## 多语言（静态生成）

落地页有五种语言，每种语言一个独立网址：`/`（中文）、`/en/`、`/ja/`、`/de/`、`/fr/`。
各语言页是构建前就生成好的静态 HTML，爬虫不执行 JS 也能读到对应语言的正文、标题、描述与结构化数据。
以前用 JS 在同一网址里替换文字，搜索引擎与 AI 爬虫只能看到中文，也没法声明 hreflang，所以改成了静态生成。

工作方式：

1. **中文源页是唯一的手改入口。** 改文案、改结构都只改 `site/index.html`。
2. **译文在 `site-i18n/<lang>.json`。** `text` 以中文原文为键（文本节点去掉首尾空白后的整段，或 `aria-label` / `alt` / `title` 的值）；`rich` 是四个含内联标记的标题（按元素 id 整体替换）；`meta` 是 title、description 与分享图替代文字；`jsonld` 是只出现在结构化数据里的句子。
3. **生成脚本 `scripts/build-site-i18n.mjs`** 读取源页与译文，写出 `site/<lang>/index.html` 和 `site/home-sitemap.xml`，并刷新所有页面里的生成区。生成区用 `<!-- i18n:NAME:start -->…<!-- i18n:NAME:end -->` 标记，内容由脚本维护，不要手改：
   - `head`：canonical、五种语言加 `x-default` 的 hreflang、`og:url`、`og:locale`；
   - `jsonld`：从 `site/assets/jsonld.json` 翻译出的结构化数据，外加本页的 `WebPage` 节点；
   - `menu`：语言菜单（`<details>` 加普通链接，不依赖 JS）；
   - `runtime`：非中文页注入的 `window.ASTER_STRINGS`，供 `site.js` 动态文案使用。
4. **运行时脚本 `site/assets/i18n.js` 不再替换正文。** 它只提供 `window.asterT`、处理语言菜单开合，并在访客偏好的语言与当前页不同时显示一条可关闭的建议。偏好是用户在菜单或建议条里的明确选择，没有选择时才看浏览器语言。
5. **不做自动跳转。** 同一网址对爬虫、分享链接和所有访客始终是同一种语言。`x-default` 指向英文页。

改文案的流程：

```bash
# 1. 改 site/index.html（中文）
# 2. 在 site-i18n/en.json、ja.json、de.json、fr.json 里补齐或改对应的键
# 3. 重新生成
node scripts/build-site-i18n.mjs
# 4. 提交前校验：缺译文、拉丁语系页面残留中文、生成物过期都会失败
node scripts/build-site-i18n.mjs --check
```

规则：

- 修改中文原文等于换了键。四个译文文件里的旧键要一起改，否则脚本会报「缺少译文」。脚本也会警告不再使用的键，看到就删。
- 一个文本节点只放一句完整文案。被内联标签拆开的半句，译文要能和相邻节点连读，需要的空格写在译文里。
- 版本号等会变的值放在独立的 `<span>` 里，不要和文案写在同一个文本节点，否则每次发版都会换键。
- 新增由 `site.js` 动态生成的中文文案时，同时加进脚本的 `RUNTIME_KEYS` 和四个译文文件。
- 页面里的站内链接与资源一律用站点根路径（`/assets/…`、`/docs/`），生成到子目录后才不会失效。
- 数字和事实（版本号、规格数量、主题数量）在五种语言里必须一致。
- 文档站 `/docs/` 保留中文，`/docs/en/` 提供完整英文指南；对应页面共享 slug（例如 `/docs/faq` 与 `/docs/en/faq`）。VitePress 的 nav、sidebar、outline、搜索与界面文案按语言配置，本地搜索只返回当前语言。
- 英文落地页与 README 指向英文指南；日、德、法落地页的文档、FAQ、主题入口也指向英文，并在可见文字里明确标注英文回退。开发者文档尚为中文，非中文入口明确标注。不得创建空的其他语言文档路由或冒充已翻译。
- 文档语言切换保留对应章节页面；不同语言的小节锚点不同，切换时清除原语言 hash 并回到页首，同语言页内锚点保持不变。

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
- 当前区块是工作流示例，直接描述已发布功能，不使用虚构人物署名或引号。页面上的 `.voices-note` 明确说明不是用户评价。
- 保留现有卡片布局；每条示例以任务命名，使用编号与「工作流示例」标记，不放头像、公司名或星级。
- 真实反馈如需引用，单独按上述来源与授权要求处理，不把示例改成未经核验的用户引言。
- 不发布购买、交换或请求得来的评价，也不展示无法核实的用户数、下载量或 star 数。推广规则见 [公开推广资料](../promotion.md)。

## GEO 文件

| 文件 | 作用 |
| --- | --- |
| `site/robots.txt` | 允许所有爬虫，并显式允许常见 AI 爬虫；指向 sitemap 索引 |
| `site/sitemap.xml` | sitemap 索引，汇总落地页与文档站 |
| `site/home-sitemap.xml` | 五种语言的落地页网址，互相列出 hreflang 备选；由生成脚本写出，只手改 `lastmod` |
| `site/<lang>/index.html` | 各语言静态落地页，带各自的 `lang`、title、description、canonical 与 hreflang |
| `site/docs/sitemap.xml` | 文档站构建时由 VitePress 自动生成，不手改 |
| `site/llms.txt` | 按 [llmstxt.org](https://llmstxt.org/) 格式写的站点摘要：中英文定义、核心事实清单、文档链接 |
| `site/assets/jsonld.json` | schema.org 结构化数据（`@graph`）：`Organization`、`WebSite`、`SoftwareApplication`、`FAQPage` |
| `site/index.html` | 中文落地页；JSON-LD、canonical 与 hreflang 在生成区里，由生成脚本维护 |

`robots.txt` 显式列出的 AI 爬虫：GPTBot、ChatGPT-User、OAI-SearchBot、ClaudeBot、Claude-SearchBot、anthropic-ai、PerplexityBot、Google-Extended、Applebot-Extended、CCBot、Bytespider。
显式列出是为了让各家不依赖对 `*` 分组的不同解释。新增爬虫时照同样格式追加一个分组。

### 内容规则

- **只写已发布的能力。** 事实以已发布版本的 `docs/user/help.md`、README 和发行说明为准。开发分支上的功能等发布后再加。
- **每条事实能被单独引用。** 生成式搜索常常只截取一两句话，所以每条 FAQ 答案和事实清单条目都要自成一体，不依赖上下文，不用「如上所述」。
- **事实处处一致。** 版本号、系统要求、规格数量、主题数量、语言数量在 `index.html`、`llms.txt`、`jsonld.json`、README 里必须一致。
- **隐私表述要精确。** Aster 不收集使用数据，但崩溃报告是可选功能（默认关闭），把项目记忆交给 CLI Agent 提炼也会发送摘要（默认关闭）。对外不写「从不联网」「绝不上传任何数据」这类绝对说法。
- **系统要求写全。** 当前安装包只包含 arm64 版本，系统要求要同时写 macOS 14+ 与 Apple 芯片。构建方式改变后同步更新。
- `jsonld.json` 是唯一源文件（中文）。修改后运行生成脚本，它会翻译并内联到五个语言页；只出现在 JSON-LD 里的新句子要在四个译文文件的 `jsonld` 里补译文。

### 发版时同步

每次发布正式版（与「发行说明与官网版本号」提交一起）：

1. `site/index.html` 里所有可见的版本号（例如 `v0.6.15`）。
2. `site/assets/jsonld.json` 的 `softwareVersion` 与 `releaseNotes`。
3. `site/llms.txt` 的「当前发布版本」一行，包括发布日期。
4. `site/home-sitemap.xml` 第一条 `lastmod`，改成发布日期。
5. 运行 `node scripts/build-site-i18n.mjs`，把以上改动带到各语言页、JSON-LD 与 sitemap。
6. 如果这次发布改变了核心事实（新增大功能、规格数量、主题数量、系统要求），同步检查 FAQ 答案、`featureList` 与 `llms.txt` 的事实清单。
7. `help.md` 新增了「## 章节」时，同步 `help.en.md`，在 `split-help.mjs` 的 `SLUGS` 里登记中英文标题与固定 slug，再把新页面加进 `llms.txt`。

预览版不改这些文件，官网只描述正式版。

## 验证清单

提交前逐项执行：

```bash
# 结构化数据可以解析
node -e 'JSON.parse(require("fs").readFileSync("site/assets/jsonld.json","utf8"))'

# 各语言页、生成区与 sitemap 是最新的，没有缺译文
node scripts/build-site-i18n.mjs --check

# sitemap 是合法 XML
xmllint --noout site/sitemap.xml site/home-sitemap.xml

# 文档站能完整构建，页面数与 help.md 的章节数一致
cd site-docs && npm ci && npm run docs:build && npm run docs:check && cd ..

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

- 用语言菜单在五个网址之间切换，确认没有布局溢出、长译文没有挤压首屏。
- 直接 `curl` 某个语言页，确认原始 HTML 里就是该语言（不靠 JS），`<html lang>`、`<title>`、description、canonical 与 hreflang 正确。
- 把浏览器语言设成别的语言打开首页，确认出现切换建议；点关闭后刷新不再出现。

纯文案改动不需要运行应用测试，但上面的结构化数据、XML 与链接检查必须执行。没有执行的检查要在提交说明里写明。
