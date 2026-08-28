import { defineConfig } from "vitepress";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const sidebar = JSON.parse(
  fs.readFileSync(path.join(here, "sidebar.generated.json"), "utf8")
);

export default defineConfig({
  lang: "zh-CN",
  title: "Aster 文档",
  description: "Aster —— 原生 macOS 终端工作区的用户指南",

  // 官网整体以 site/ 为根：落地页在 /，文档站构建到 site/docs/
  base: "/docs/",
  outDir: "../site/docs",

  // guide/ 下的生成页提升到文档站根路径
  rewrites: { "guide/:page": ":page" },

  // Cloudflare Pages 会把 /docs/faq.html 一律 307 到 /docs/faq。不开 cleanUrls
  // 的话 VitePress 生成的站内链接全带 .html，每次点击都要多走一跳重定向。
  cleanUrls: true,

  // 工程说明不属于文档内容
  srcExclude: ["README.md"],

  head: [
    ["link", { rel: "icon", type: "image/svg+xml", href: "/docs/aster-icon.svg" }],
    // 与落地页共用自托管字体（site/assets/fonts.css），不走 fonts.googleapis.com：
    // 该域名在中国大陆不可达。这里的路径是部署后的站点根路径，不带 /docs/ 前缀，
    // 因此只在 serve-site.sh 或线上生效；vitepress dev 下会回退到系统字体。
    ["link", { rel: "preload", href: "/assets/fonts/newsreader-roman-latin.woff2", as: "font", type: "font/woff2", crossorigin: "" }],
    ["link", { rel: "preload", href: "/assets/fonts/jetbrains-mono-roman-latin.woff2", as: "font", type: "font/woff2", crossorigin: "" }],
    ["link", { rel: "stylesheet", href: "/assets/fonts.css" }],
    ["meta", { name: "theme-color", content: "#FCFCFB" }],
  ],

  themeConfig: {
    logo: "/aster-icon.svg",
    siteTitle: "Aster 文档",

    nav: [
      // "/../"：浏览器归一化为站点根（site/ 落地页），绕开 VitePress 的 base 前缀
      { text: "首页", link: "/../", target: "_self" },
      { text: "用户指南", link: "/", activeMatch: "/" },
      { text: "开发者", link: "https://github.com/rambocode/aster/tree/master/docs/developer" },
      { text: "更新日志", link: "https://github.com/rambocode/aster/releases" },
    ],

    sidebar: { "/": sidebar },

    outline: { level: [2, 3], label: "本页目录" },

    socialLinks: [{ icon: "github", link: "https://github.com/rambocode/aster" }],

    search: {
      provider: "local",
      options: {
        translations: {
          button: { buttonText: "搜索文档", buttonAriaLabel: "搜索文档" },
          modal: {
            noResultsText: "没有找到结果",
            resetButtonTitle: "清除查询",
            footer: { selectText: "选择", navigateText: "切换", closeText: "关闭" },
          },
        },
      },
    },

    docFooter: { prev: "上一篇", next: "下一篇" },
    returnToTopLabel: "回到顶部",
    sidebarMenuLabel: "目录",
    darkModeSwitchLabel: "外观",
    lightModeSwitchTitle: "切换到浅色",
    darkModeSwitchTitle: "切换到深色",

    footer: {
      message: "MIT License · 不含遥测，不上传数据",
      copyright: "© 2026 Aster Terminal",
    },
  },
});
