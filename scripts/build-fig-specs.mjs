#!/usr/bin/env node
// 把 @withfig/autocomplete npm 包里编译好的 Fig 规格转换成 Aster 的 fig-specs.json(schema v2)。
// 用法: node scripts/build-fig-specs.mjs [--version <npm 版本>] [--out Resources/autocomplete/fig-specs.json]
// 只保留静态、可序列化的字段(函数型 generator/postProcess 全部丢弃),并合并旧文件里已有的中文描述。
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const option = (flag, fallback) => {
  const index = args.indexOf(flag);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};
const version = option("--version", "latest");
const outPath = resolve(option("--out", join(scriptDir, "..", "Resources", "autocomplete", "fig-specs.json")));

// 与 Swift 侧 AutocompleteSpecStore 保持一致的上限;超出即在生成阶段失败,而不是让 app 拒绝加载。
const LIMITS = {
  itemNameBytes: 512,
  descriptionBytes: 1024,
  childrenPerNode: 2000,
  nodesPerCommand: 20000,
  encodedBytes: 32 * 1024 * 1024,
};

/// 下载并解包 npm 包,返回解包目录。
function fetchPackage() {
  const dir = mkdtempSync(join(tmpdir(), "fig-specs-"));
  execFileSync("npm", ["pack", `@withfig/autocomplete@${version}`, "--silent"], { cwd: dir, stdio: "pipe" });
  const tarball = readdirSync(dir).find((name) => name.endsWith(".tgz"));
  execFileSync("tar", ["xzf", tarball], { cwd: dir });
  return join(dir, "package");
}

/// 读取旧文件中的中文描述,按命令路径("git/commit")建索引以便合并。
function loadChineseOverlay(path) {
  if (!existsSync(path)) return new Map();
  const map = new Map();
  const walk = (command, prefix) => {
    const key = prefix ? `${prefix}/${command.name}` : command.name;
    const chinese = typeof command.description === "object" ? command.description?.chinese : "";
    if (chinese) map.set(key, chinese);
    for (const sub of command.subcommands ?? []) walk(sub, key);
  };
  try {
    for (const command of JSON.parse(readFileSync(path, "utf8")).commands ?? []) walk(command, "");
  } catch {
    // 旧文件损坏就当没有中文覆盖,不阻塞生成。
  }
  return map;
}

const utf8Length = (value) => Buffer.byteLength(value, "utf8");
const cleanText = (value, maxBytes) => {
  if (typeof value !== "string") return "";
  // 去掉控制字符和多余空白;超长描述按字节截断到上限之内(按字符裁剪保证 UTF-8 完整)。
  // Swift 的 CharacterSet.controlCharacters 同时包含 Cc 和 Cf(零宽连接符等),这里一并清掉。
  let text = value.replace(/[\x00-\x1f\x7f]+/g, " ").replace(/\p{Cf}/gu, "").replace(/\s+/g, " ").trim();
  while (utf8Length(text) > maxBytes) text = text.slice(0, -1).trim();
  return text;
};
const asArray = (value) => (value == null ? [] : Array.isArray(value) ? value : [value]);
// 与 Swift 侧 AutocompleteSpecStore.validItemName 相同的字符白名单:会被插入命令行的名称
// (子命令、选项、静态候选)必须是安全的 shell token,不合规的直接丢弃而不是让 app 拒绝整个文件。
const validItemName = (name) =>
  typeof name === "string" && utf8Length(name) <= LIMITS.itemNameBytes && /^[A-Za-z0-9._+@%/=:,-]+$/.test(name);

/// 转换参数:保留名称、描述、模板、静态候选和纯字符串数组形式的 generator 脚本。
function convertArgument(arg) {
  if (!arg || typeof arg !== "object") return null;
  const result = { name: cleanText(arg.name ?? "", LIMITS.itemNameBytes) || "arg" };
  const description = cleanText(arg.description, LIMITS.descriptionBytes);
  if (description) result.description = description;
  const template = asArray(arg.template).filter((t) => t === "filepaths" || t === "folders");
  if (template.length) result.template = template;
  const suggestions = asArray(arg.suggestions)
    .map((s) => (typeof s === "string" ? { name: s } : s && typeof s === "object" ? { name: asArray(s.name)[0], description: cleanText(s.description, LIMITS.descriptionBytes) } : null))
    .filter((s) => s && validItemName(s.name))
    .slice(0, LIMITS.childrenPerNode)
    .map((s) => (s.description ? s : { name: s.name }));
  if (suggestions.length) result.suggestions = suggestions;
  const scripts = asArray(arg.generators)
    // 多行 bash 脚本含换行(控制字符),Swift 侧会拒绝,直接丢弃这类 generator。
    .map((g) => g && Array.isArray(g.script) && g.script.length > 0 && g.script.length <= 32
      && g.script.every((s) => typeof s === "string" && utf8Length(s) <= 512 && !/[\p{Cc}\p{Cf}]/u.test(s)) ? g.script : null)
    .filter(Boolean);
  if (scripts.length) result.generatorScripts = scripts.slice(0, 8);
  if (arg.isOptional) result.isOptional = true;
  if (arg.isVariadic) result.isVariadic = true;
  return result;
}

/// 转换选项:Fig 的 name 可能是字符串或数组,统一为 names 数组。
function convertOption(opt) {
  if (!opt || typeof opt !== "object") return null;
  const names = asArray(opt.name).filter(validItemName);
  if (!names.length) return null;
  const result = { names };
  const description = cleanText(opt.description, LIMITS.descriptionBytes);
  if (description) result.description = description;
  const optionArgs = asArray(opt.args).map(convertArgument).filter(Boolean);
  if (optionArgs.length) result.args = optionArgs;
  if (opt.isRequired) result.isRequired = true;
  if (opt.isRepeatable) result.isRepeatable = true;
  if (opt.hidden) result.hidden = true;
  return result;
}

/// 递归转换命令/子命令。name 数组的首项是主名,其余作为 aliases。
function convertCommand(spec, path, overlay, counter) {
  if (!spec || typeof spec !== "object") return null;
  const names = asArray(spec.name).filter(validItemName);
  if (!names.length) return null;
  counter.nodes += 1;
  if (counter.nodes > LIMITS.nodesPerCommand) return null;
  const key = path ? `${path}/${names[0]}` : names[0];
  const english = cleanText(spec.description, LIMITS.descriptionBytes);
  const chinese = overlay.get(key) ?? "";
  const result = {
    name: names[0],
    description: chinese ? { english, chinese } : english,
  };
  if (names.length > 1) result.aliases = names.slice(1);
  if (spec.hidden) result.hidden = true;
  const subcommands = asArray(spec.subcommands)
    .map((sub) => convertCommand(sub, key, overlay, counter))
    .filter(Boolean)
    .slice(0, LIMITS.childrenPerNode);
  if (subcommands.length) result.subcommands = subcommands;
  const options = asArray(spec.options).map(convertOption).filter(Boolean).slice(0, LIMITS.childrenPerNode);
  if (options.length) result.options = options;
  const commandArgs = asArray(spec.args).map(convertArgument).filter(Boolean).slice(0, LIMITS.childrenPerNode);
  if (commandArgs.length) result.arguments = commandArgs;
  return result;
}

const packageDir = fetchPackage();
const packageJson = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf8"));
const overlay = loadChineseOverlay(outPath);
const buildDir = join(packageDir, "build");
const commands = [];
const skipped = [];
// build/ 下每个顶层 .js 就是一个命令规格;index.js 是清单,dynamic/ 与 shared/ 不是命令。
for (const file of readdirSync(buildDir).sort()) {
  if (!file.endsWith(".js") || file === "index.js") continue;
  const name = file.slice(0, -3);
  if (!/^[A-Za-z0-9][A-Za-z0-9._+@-]*$/.test(name)) { skipped.push(name); continue; }
  try {
    const module = await import(pathToFileURL(join(buildDir, file)).href);
    const converted = convertCommand({ ...module.default, name }, "", overlay, { nodes: 0 });
    if (converted) commands.push(converted); else skipped.push(name);
  } catch (error) {
    skipped.push(`${name} (${error.message.split("\n")[0]})`);
  }
}
commands.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

// 发布日期取 npm 的版本发布时间;失败时退回今天,只影响设置页显示的 "v<日期>"。
let sourceDate = new Date().toISOString().slice(0, 10);
try {
  const times = JSON.parse(execFileSync("npm", ["view", `@withfig/autocomplete@${packageJson.version}`, "time", "--json"], { stdio: "pipe" }));
  const published = times?.[packageJson.version] ?? times?.modified;
  if (published) sourceDate = String(published).slice(0, 10);
} catch {}

const database = {
  schemaVersion: 2,
  sourceRevision: `npm-${packageJson.version}`,
  sourceDate,
  commands,
};
const encoded = JSON.stringify(database);
if (utf8Length(encoded) > LIMITS.encodedBytes) {
  console.error(`fig-specs.json 超过 ${LIMITS.encodedBytes} 字节上限: ${utf8Length(encoded)}`);
  process.exit(1);
}
writeFileSync(outPath, encoded + "\n");
console.log(`已写入 ${outPath}: ${commands.length} 条命令, ${(utf8Length(encoded) / 1024 / 1024).toFixed(2)} MB, 版本 ${database.sourceRevision} (${sourceDate})`);
if (skipped.length) console.log(`跳过 ${skipped.length}: ${skipped.join(", ")}`);
