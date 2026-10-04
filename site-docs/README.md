# Aster 文档站（VitePress）

官网文档子站的构建工程。**中文内容源是 `../docs/user/help.md`，英文内容源是 `../docs/user/help.en.md`**：
构建前 `scripts/split-help.mjs` 会按「## 章节」把两份帮助切分成 `guide/` 和 `en/guide/` 下的多页
（生成物不入库），中文应用内帮助与官网文档同步；英文翻译保留完整用户指南范围。

```bash
cd site-docs
npm ci
npm run docs:dev     # 开发预览（热更新）
npm run docs:build   # 构建到 ../site/docs/
```

- 落地页在 `../site/index.html`（手写静态，不经构建）；文档站构建输出到
  `../site/docs/`，两者合起来以 `site/` 为根目录部署或本地预览
  （`./scripts/serve-site.sh`）。
- `docs:build` 同时生成 `site/docs/sitemap.xml`；站点根目录的
  `site/sitemap.xml` 汇总首页与文档站两个 sitemap。新增文档页会随构建自动进入索引。
- 新增章节：直接在 `help.md` 里加「## 标题」即可出现在文档站；想要固定的
  英文 slug 和侧栏分组，在 `scripts/split-help.mjs` 的 `SLUGS` / `GROUPS`
  里补中英文标题和共用 slug，否则中文使用 `section-NN` 回退。两种语言的
  章节集合必须一致，英文缺章或标题未登记会使构建失败。
- 品牌样式集中在 `.vitepress/theme/custom.css`，token 与
  `site/assets/style.css` 保持一致。

- 中文地址保留 `/docs/`，英文是 `/docs/en/`。侧栏与本地搜索按语言分开。
- 语言切换保留对应章节页面；小节标题不同，切换时清除原语言锚点并回到页首。
- 日文、德文、法文落地页明确标注英文文档回退，不生成不存在的译文。
- `npm run docs:check` 检查章节对应、围栏、路由、锚点与落地页入口，先运行构建。
