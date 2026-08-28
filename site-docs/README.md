# Aster 文档站（VitePress）

官网文档子站的构建工程。**内容唯一来源是 `../docs/user/help.md`**：
构建前 `scripts/split-help.mjs` 会按「## 章节」把它切分成 `guide/` 下的多页
（生成物不入库），应用内帮助与官网文档永远同步。

```bash
cd site-docs
npm install
npm run docs:dev     # 开发预览（热更新）
npm run docs:build   # 构建到 ../site/docs/
```

- 落地页在 `../site/index.html`（手写静态，不经构建）；文档站构建输出到
  `../site/docs/`，两者合起来以 `site/` 为根目录部署或本地预览
  （`./scripts/serve-site.sh`）。
- 新增章节：直接在 `help.md` 里加「## 标题」即可出现在文档站；想要固定的
  英文 slug 和侧栏分组，在 `scripts/split-help.mjs` 的 `SLUGS` / `GROUPS`
  里补一行，否则会以 `section-NN` 落到「其他」分组。
- 品牌样式集中在 `.vitepress/theme/custom.css`，token 与
  `site/assets/style.css` 保持一致。
