//! ssh_config 行级词法：关键字切分、OpenSSH `argv_split` 兼容分词和 Host 模式匹配。
//! 思路移植自 tty7 `src/core/ssh_config.rs`（HEAD 458c923，Apache-2.0），细节按 OpenSSH readconf.c 修正。

/// 把一行拆成 `(关键字, 其余原文)`；空行和注释行返回 None。
///
/// 关键字与值之间可以是空白，也可以是一个 `=`（两侧可带空白），与 OpenSSH `strdelim` 一致，
/// 所以 `Port=22`、`Host = foo` 都合法。
pub(super) fn split_keyword(line: &str) -> Option<(&str, &str)> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let end = line
        .find(|c: char| c.is_whitespace() || c == '=')
        .unwrap_or(line.len());
    let keyword = &line[..end];
    if keyword.is_empty() {
        return None;
    }
    let mut rest = line[end..].trim_start();
    if let Some(after_eq) = rest.strip_prefix('=') {
        rest = after_eq.trim_start();
    }
    Some((keyword, rest))
}

/// 按 OpenSSH `argv_split(..., terminate_on_comment=1)` 的规则分词；引号不配对时返回 None。
///
/// 规则要点（和 tty7 原实现不同的地方都是为了对齐 OpenSSH）：
/// - 单双引号都能包住空白；引号本身不进结果。
/// - 反斜杠只转义 `'`、`"`、`\`，以及引号外的空格；其它反斜杠原样保留（Windows 风格路径不被吃掉）。
/// - 只有「词首」的 `#` 开始行尾注释，`proxy#1` 这种词中的 `#` 保留。
pub(super) fn split_words(input: &str) -> Option<Vec<String>> {
    let chars: Vec<char> = input.chars().collect();
    let mut words = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == ' ' || chars[i] == '\t' {
            i += 1;
            continue;
        }
        if chars[i] == '#' {
            break;
        }
        let mut word = String::new();
        let mut quote: Option<char> = None;
        while i < chars.len() {
            let c = chars[i];
            let next = chars.get(i + 1).copied();
            if c == '\\' {
                let escapable = matches!(next, Some('\'' | '"' | '\\'))
                    || (quote.is_none() && next == Some(' '));
                if escapable {
                    i += 1;
                    word.push(chars[i]);
                } else {
                    word.push(c);
                }
            } else if quote.is_none() && (c == ' ' || c == '\t') {
                break;
            } else if quote.is_none() && (c == '"' || c == '\'') {
                quote = Some(c);
            } else if quote == Some(c) {
                quote = None;
            } else {
                word.push(c);
            }
            i += 1;
        }
        if quote.is_some() {
            return None;
        }
        words.push(word);
    }
    Some(words)
}

/// OpenSSH `match_pattern` 语义的通配匹配：只认 `*` 和 `?`，大小写不敏感。
///
/// 用贪心回溯（记住最后一个 `*` 的位置）而不是递归：tty7 的递归写法对 `*a*a*a*b`
/// 这类模式是指数复杂度，配置文件最大 1MB，不能给恶意模式留口子。
pub(super) fn pattern_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let t: Vec<char> = text.to_lowercase().chars().collect();
    let (mut pi, mut ti) = (0, 0);
    let mut star: Option<usize> = None;
    let mut mark = 0;
    while ti < t.len() {
        if pi < p.len() && (p[pi] == '?' || p[pi] == t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ti;
            pi += 1;
        } else if let Some(s) = star {
            // 让上一个 `*` 多吃一个字符再试
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

/// 一行 Host 的模式列表是否匹配 alias：命中任一 `!` 取反模式即不匹配，否则至少要命中一个正向模式。
pub(super) fn host_patterns_match(patterns: &[String], alias: &str) -> bool {
    let mut positive = false;
    for pattern in patterns {
        if let Some(negated) = pattern.strip_prefix('!') {
            if pattern_match(negated, alias) {
                return false;
            }
        } else if pattern_match(pattern, alias) {
            positive = true;
        }
    }
    positive
}

/// Host 模式是否是可以直接连接的具体 alias（不含通配符、不是取反）。
pub(super) fn is_concrete_alias(pattern: &str) -> bool {
    !pattern.is_empty() && !pattern.starts_with('!') && !pattern.contains(['*', '?'])
}
