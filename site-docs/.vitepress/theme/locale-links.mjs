// 语言切换保留对应章节，但清除译文中不存在的原语言小节锚点。
export function localeSwitchTarget(href, currentHref, base) {
  const current = new URL(currentHref);
  const target = new URL(href, current);
  if (target.origin !== current.origin || !target.hash) return null;
  if (![current.pathname, target.pathname].every((path) => path.startsWith(base))) return null;
  const isEnglish = (path) => path === `${base}en` || path.startsWith(`${base}en/`);
  if (isEnglish(current.pathname) === isEnglish(target.pathname)) return null;
  return target.pathname + target.search;
}
