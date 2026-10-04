import DefaultTheme from "vitepress/theme";
import { inBrowser } from "vitepress";
import { localeSwitchTarget } from "./locale-links.mjs";
import "./custom.css";

export default {
  ...DefaultTheme,
  enhanceApp(context) {
    DefaultTheme.enhanceApp?.(context);
    if (!inBrowser) return;
    const { router, siteData } = context;
    router.onBeforeRouteChange = async (href) => {
      const target = localeSwitchTarget(href, window.location.href, siteData.value.base);
      if (target) {
        await router.go(target);
        return false;
      }
    };
  },
};
