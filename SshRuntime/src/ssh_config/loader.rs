//! 配置文件加载：安全读取、Include 展开（glob、`~`、相对 `~/.ssh/`）、Host/Match 分块。
//! 分块思路移植自 tty7 `src/core/ssh_config.rs`（HEAD 458c923，Apache-2.0），
//! Include 与全局指令的语义按 OpenSSH readconf.c 修正。

use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use super::lexer::{is_concrete_alias, split_keyword, split_words};
use super::values::{parse_setting, Setting};
use super::IgnoredDirective;

/// 单个配置文件的大小上限。
pub(super) const MAX_FILE_BYTES: u64 = 1024 * 1024;
/// 一次解析最多读取的文件数（含根配置）。
pub(super) const MAX_FILES: usize = 64;
/// Include 最大嵌套层数，与 OpenSSH `READCONF_MAX_DEPTH` 相同。
pub(super) const MAX_INCLUDE_DEPTH: usize = 16;

/// 一段连续的指令。`conditions` 里每一组都是一行 Host 的模式列表，全部匹配时整段生效；
/// 空表示无条件（第一个 Host 之前的全局指令）。
///
/// 用「条件链」而不是单层模式，是因为 Host 块里的 Include：OpenSSH 只在外层 Host 匹配时
/// 才处理被包含文件，被包含文件里的 Host 行又各自再筛一次，两层都要满足。
#[derive(Debug)]
pub(super) struct Block {
    pub conditions: Vec<Vec<String>>,
    pub settings: Vec<Setting>,
}

/// 一次解析的结果：按出现顺序排列的指令块、所有具体 alias（去重，保持首次出现顺序）和 ignored。
#[derive(Debug, Default)]
pub(super) struct Loaded {
    pub blocks: Vec<Block>,
    pub aliases: Vec<String>,
    pub ignored: Vec<IgnoredDirective>,
}

/// 读取文件失败的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReadError {
    NotFound,
    NotRegularFile,
    TooLarge,
    Unreadable,
}

impl ReadError {
    /// ignored 条目里 `reason` 字段的原因码。
    fn code(self) -> &'static str {
        match self {
            ReadError::NotFound => "notFound",
            ReadError::NotRegularFile => "notRegularFile",
            ReadError::TooLarge => "tooLarge",
            ReadError::Unreadable => "unreadable",
        }
    }

    /// 把 IO 错误归到原因码；只区分「不存在」和其它。
    fn from_io(err: &io::Error) -> Self {
        match err.kind() {
            io::ErrorKind::NotFound => ReadError::NotFound,
            _ => ReadError::Unreadable,
        }
    }
}

/// 解析 `config_path` 及其 Include。根配置不存在不算错误（返回空结果）；其它读失败记进 ignored（line 为 0）。
pub(super) fn load(config_path: &Path, home: &Path) -> Loaded {
    let mut loader = Loader {
        home,
        out: Loaded::default(),
        alias_set: HashSet::new(),
        files_read: 0,
        stack: Vec::new(),
    };
    loader.enter_file(config_path, &[], 0, None);
    loader.out
}

/// Include 失败时要回指的那一行：(文件显示名, 行号, 关键字原文)。
type Origin<'a> = (&'a str, usize, &'a str);

/// 递归加载的状态。`stack` 是正在解析的文件链（规范化路径），用来识别 Include 循环。
struct Loader<'a> {
    home: &'a Path,
    out: Loaded,
    alias_set: HashSet<String>,
    files_read: usize,
    stack: Vec<PathBuf>,
}

impl Loader<'_> {
    /// 检查深度、文件数、循环后读入并解析一个文件。`origin` 为 None 表示根配置。
    fn enter_file(
        &mut self,
        path: &Path,
        conditions: &[Vec<String>],
        depth: usize,
        origin: Option<Origin<'_>>,
    ) {
        let fail = |loader: &mut Self, reason: &str| match origin {
            Some((file, line, option)) => loader.ignore(file, line, option, reason),
            // 根配置的问题没有具体行，line 记 0、option 留空
            None => {
                let file = loader.display(path);
                loader.ignore(&file, 0, "", reason);
            }
        };
        if depth > MAX_INCLUDE_DEPTH {
            return fail(self, "includeDepth");
        }
        if self.files_read >= MAX_FILES {
            return fail(self, "tooManyFiles");
        }
        let canonical = match fs::canonicalize(path) {
            Ok(p) => p,
            // 根配置不存在是常态（用户没写过 ssh_config），不报
            Err(e) if origin.is_none() && e.kind() == io::ErrorKind::NotFound => return,
            Err(e) => return fail(self, ReadError::from_io(&e).code()),
        };
        if self.stack.contains(&canonical) {
            return fail(self, "includeCycle");
        }
        let text = match read_limited(&canonical) {
            Ok(text) => text,
            Err(e) => return fail(self, e.code()),
        };
        self.files_read += 1;
        self.stack.push(canonical);
        self.parse_text(path, &text, conditions, depth);
        self.stack.pop();
    }

    /// 逐行解析一个文件的内容，把指令块追加到 `out.blocks`。
    fn parse_text(&mut self, path: &Path, text: &str, parent: &[Vec<String>], depth: usize) {
        let file = self.display(path);
        let mut conditions = parent.to_vec();
        self.push_block(&conditions);
        let mut in_match = false;
        for (index, raw) in text.lines().enumerate() {
            let line = index + 1;
            let Some((keyword, rest)) = split_keyword(raw) else {
                continue;
            };
            match keyword.to_ascii_lowercase().as_str() {
                "host" => {
                    in_match = false;
                    // 写坏的 Host 行按「什么都不匹配」处理：比把后面的指令当成全局更安全
                    let patterns = match split_words(rest) {
                        Some(words) if !words.is_empty() => words,
                        _ => {
                            self.ignore(&file, line, keyword, "invalidValue");
                            Vec::new()
                        }
                    };
                    for pattern in &patterns {
                        if is_concrete_alias(pattern) && self.alias_set.insert(pattern.clone()) {
                            self.out.aliases.push(pattern.clone());
                        }
                    }
                    conditions = parent.to_vec();
                    conditions.push(patterns);
                    self.push_block(&conditions);
                }
                // Match 条件（exec、user、localnetwork…）无法静态求值，整块跳过，只在 Match 行记一次
                "match" => {
                    in_match = true;
                    self.ignore(&file, line, keyword, "unsupported");
                }
                _ if in_match => {}
                "include" => {
                    self.include(&file, line, keyword, rest, &conditions, depth);
                    // 被包含文件追加了自己的块；回到本文件后接着当前 Host 的条件继续
                    self.push_block(&conditions);
                }
                key => match parse_setting(key, rest) {
                    Ok(setting) => self.current_block().settings.push(setting),
                    Err(rejected) => self.ignore(&file, line, keyword, rejected.code()),
                },
            }
        }
    }

    /// 处理一行 Include：每个参数展开成文件列表后依次进入。
    fn include(
        &mut self,
        file: &str,
        line: usize,
        keyword: &str,
        rest: &str,
        conditions: &[Vec<String>],
        depth: usize,
    ) {
        let tokens = match split_words(rest) {
            Some(tokens) if !tokens.is_empty() => tokens,
            _ => return self.ignore(file, line, keyword, "invalidValue"),
        };
        for token in tokens {
            let paths = match self.expand_include(&token) {
                Ok((paths, partly_unreadable)) => {
                    // 部分目录读不了时，已匹配到的文件照常处理，但要在报告里留痕
                    if partly_unreadable {
                        self.ignore(file, line, keyword, "unreadable");
                    }
                    paths
                }
                Err(reason) => {
                    self.ignore(file, line, keyword, reason);
                    continue;
                }
            };
            for path in paths {
                self.enter_file(&path, conditions, depth + 1, Some((file, line, keyword)));
            }
        }
    }

    /// 把一个 Include 参数展开成路径列表（已排序），第二个值表示 glob 途中有目录读不了。
    ///
    /// 相对路径按 `~/.ssh/` 解析（OpenSSH 对用户配置的规定），而不是按当前文件所在目录。
    /// 不含通配符的参数原样返回，文件不存在由 `enter_file` 记为 notFound；
    /// 含通配符但一个都没匹配到是正常情况（常见的 `Include conf.d/*`），不记。
    fn expand_include(&self, token: &str) -> Result<(Vec<PathBuf>, bool), &'static str> {
        let (base, relative): (Option<PathBuf>, &str) = if token == "~" {
            (Some(self.home.to_path_buf()), "")
        } else if let Some(rest) = token.strip_prefix("~/") {
            (Some(self.home.to_path_buf()), rest)
        } else if token.starts_with('~') {
            // `~user/…` 需要查别的用户的家目录，不支持
            return Err("unsupported");
        } else if token.starts_with('/') {
            (None, token)
        } else {
            (Some(self.home.join(".ssh")), token)
        };

        if !relative.contains(['*', '?', '[']) {
            let path = match base {
                Some(base) if relative.is_empty() => base,
                Some(base) => base.join(relative),
                None => PathBuf::from(relative),
            };
            return Ok((vec![path], false));
        }

        // 家目录路径里可能含 `[` 这类 glob 元字符，拼进模式前先转义
        let pattern = match base {
            Some(base) => format!(
                "{}/{}",
                glob::Pattern::escape(&base.to_string_lossy()),
                relative
            ),
            None => relative.to_string(),
        };
        // 与 glob(3) 一致：`*` 不匹配以 `.` 开头的文件，也不跨目录
        let options = glob::MatchOptions {
            case_sensitive: true,
            require_literal_separator: true,
            require_literal_leading_dot: true,
        };
        let entries = glob::glob_with(&pattern, options).map_err(|_| "invalidValue")?;
        let mut paths = Vec::new();
        let mut unreadable = false;
        for entry in entries {
            match entry {
                Ok(path) => paths.push(path),
                Err(_) => unreadable = true,
            }
        }
        paths.sort();
        Ok((paths, unreadable))
    }

    /// 以当前条件开一个新的指令块。
    fn push_block(&mut self, conditions: &[Vec<String>]) {
        self.out.blocks.push(Block {
            conditions: conditions.to_vec(),
            settings: Vec::new(),
        });
    }

    /// 当前正在追加指令的块（`parse_text` 开头保证至少有一个）。
    fn current_block(&mut self) -> &mut Block {
        if self.out.blocks.is_empty() {
            self.push_block(&[]);
        }
        let last = self.out.blocks.len() - 1;
        &mut self.out.blocks[last]
    }

    /// 记一条 ignored。
    fn ignore(&mut self, file: &str, line: usize, option: &str, reason: &str) {
        self.out.ignored.push(IgnoredDirective {
            file: file.to_string(),
            line,
            option: option.to_string(),
            reason: reason.to_string(),
        });
    }

    /// 报告里显示的文件名：家目录下的路径写成 `~/…`，避免把用户名带进报告。
    fn display(&self, path: &Path) -> String {
        match path.strip_prefix(self.home) {
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => path.display().to_string(),
        }
    }
}

/// 安全读取一个配置文件：必须是普通文件（符号链接按目标判断），且不超过 `MAX_FILE_BYTES`。
///
/// 先 stat 再 open，open 之后再 fstat 一次：防止两次调用之间文件被换成 FIFO 或设备。
/// 用 O_NONBLOCK 打开，即使碰上 FIFO 也不会卡住；对普通文件的读取没有影响。
/// 读取时多读 1 字节来判断超限，不信任 stat 给出的长度（文件可能正在增长）。
fn read_limited(path: &Path) -> Result<String, ReadError> {
    let meta = fs::metadata(path).map_err(|e| ReadError::from_io(&e))?;
    if !meta.is_file() {
        return Err(ReadError::NotRegularFile);
    }
    if meta.len() > MAX_FILE_BYTES {
        return Err(ReadError::TooLarge);
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .map_err(|e| ReadError::from_io(&e))?;
    let meta = file.metadata().map_err(|e| ReadError::from_io(&e))?;
    if !meta.is_file() {
        return Err(ReadError::NotRegularFile);
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| ReadError::from_io(&e))?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(ReadError::TooLarge);
    }
    // 非 UTF-8 字节换成替换字符，不因为一行乱码放弃整个文件
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}
