import { defineConfig } from "vitepress";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const sidebars = JSON.parse(fs.readFileSync(path.join(here, "sidebar.generated.json"), "utf8"));

export default defineConfig({
  // 中文保留原地址；英文有对应的 /docs/en/<slug>。
  base: "/docs/",
  outDir: "../site/docs",
  sitemap: { hostname: "https://aster.foo/docs/" },
  rewrites: { "guide/:page": ":page", "en/guide/:page": "en/:page" },
  cleanUrls: true,
  srcExclude: ["README.md"],

  head: [
    ["link", { rel: "icon", type: "image/svg+xml", href: "/docs/aster-icon.svg" }],
    // 与落地页共用自托管字体；vitepress dev 下回退到系统字体。
    ["link", { rel: "preload", href: "/assets/fonts/newsreader-roman-latin.woff2", as: "font", type: "font/woff2", crossorigin: "" }],
    ["link", { rel: "preload", href: "/assets/fonts/jetbrains-mono-roman-latin.woff2", as: "font", type: "font/woff2", crossorigin: "" }],
    ["link", { rel: "stylesheet", href: "/assets/fonts.css" }],
    ["meta", { name: "theme-color", content: "#FCFCFB" }],
  ],

  locales: {
    root: {
      label: "简体中文",
      lang: "zh-CN",
      title: "Aster 文档",
      description: "Aster —— 原生 macOS 终端工作区的用户指南",
      themeConfig: {
        siteTitle: "Aster 文档",
        nav: [
          // /../ 绕过 VitePress base，回到对应落地页。
          { text: "首页", link: "/../", target: "_self" },
          { text: "用户指南", link: "/", activeMatch: "^/(?!en/)" },
          { text: "开发者", link: "https://github.com/OpenFabrica/aster/tree/master/docs/developer" },
          { text: "更新日志", link: "https://github.com/OpenFabrica/aster/releases" },
        ],
        sidebar: { "/": sidebars.root },
        outline: { level: [2, 3], label: "本页目录" },
        docFooter: { prev: "上一篇", next: "下一篇" },
        returnToTopLabel: "回到顶部",
        sidebarMenuLabel: "目录",
        darkModeSwitchLabel: "外观",
        lightModeSwitchTitle: "切换到浅色",
        darkModeSwitchTitle: "切换到深色",
        langMenuLabel: "切换语言",
        skipToContentLabel: "跳到正文",
        footer: { message: "MIT License · 崩溃报告与 CLI Agent 记忆提炼默认关闭", copyright: "© 2026 Aster Terminal" },
      },
    },
    en: {
      label: "English",
      lang: "en",
      title: "Aster Docs",
      description: "User guide for Aster, a native macOS terminal workspace",
      themeConfig: {
        siteTitle: "Aster Docs",
        nav: [
          { text: "Home", link: "/../en/", target: "_self" },
          { text: "User Guide", link: "/en/", activeMatch: "^/en/" },
          { text: "Developer Docs (Chinese)", link: "https://github.com/OpenFabrica/aster/tree/master/docs/developer" },
          { text: "Releases", link: "https://github.com/OpenFabrica/aster/releases" },
        ],
        sidebar: { "/en/": sidebars.en },
        outline: { level: [2, 3], label: "On this page" },
        docFooter: { prev: "Previous page", next: "Next page" },
        returnToTopLabel: "Return to top",
        sidebarMenuLabel: "Menu",
        darkModeSwitchLabel: "Appearance",
        lightModeSwitchTitle: "Switch to light theme",
        darkModeSwitchTitle: "Switch to dark theme",
        langMenuLabel: "Change language",
        skipToContentLabel: "Skip to content",
        footer: { message: "MIT License · Crash reporting and CLI Agent memory extraction are off by default", copyright: "© 2026 Aster Terminal" },
      },
    },
  },

  themeConfig: {
    logo: "/aster-icon.svg",
    socialLinks: [{ icon: "github", link: "https://github.com/OpenFabrica/aster" }],
    search: {
      provider: "local",
      options: {
        // 英文采用默认英文文案；中文只在 root locale 覆盖。
        locales: {
          root: {
            translations: {
              button: { buttonText: "搜索文档", buttonAriaLabel: "搜索文档" },
              modal: {
                displayDetails: "显示详细列表",
                noResultsText: "没有找到结果",
                resetButtonTitle: "清除查询",
                backButtonTitle: "关闭搜索",
                footer: { selectText: "选择", navigateText: "切换", closeText: "关闭" },
              },
            },
          },
        },
      },
    },
  },
});
