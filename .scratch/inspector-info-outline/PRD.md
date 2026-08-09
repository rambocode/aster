# 完善 Inspector Panel 的 Info 与 Outline

Status: ready-for-agent

## Problem Statement

Aster 的 Inspector Panel 已经提供 Info Section 与 Outline Section 的页签、基础视图、懒加载和部分数据读取，但用户实际使用时仍会感到这两个功能没有实现。

Info Section 会把进程检查失败、权限不足、超时、非终端 Pane 和真实空结果折叠成同一种空状态；进程范围只覆盖 Shell 后代，Agent 能力只对单一命令名做弱识别。Outline Section 只展示已经完成且具备完整 OSC 133 标记的命令，没有运行中的命令和 Agent 提示词；部分文档解析器不能给出可靠源码行号，JSONL 解析规则也与 Aster 已支持的 Agent transcript 不一致。

结果是界面虽然存在，但无法可靠回答用户最关心的两个问题：当前聚焦 Pane 正在运行什么、可以执行哪些会话动作，以及当前 Pane 中有哪些可导航的命令、提示词或文档结构。

## Solution

按照 Otty Details Panel 的用户语义完善 Info Section 与 Outline Section，同时保留 Aster 现有的纯 AppKit 架构、Inspector Panel 布局、主题系统和性能边界。

Info Section 将成为当前聚焦 Pane 的可信环境摘要：展示可靠工作目录、动态可用的打开动作、本机进程树、监听端口和与当前 Pane 精确绑定的 Agent session 能力，并明确区分加载中、真实空结果、不适用和检查失败。

Outline Section 将成为当前聚焦 Pane 的可信可导航索引：终端 Pane 展示运行中与已完成命令，受支持 Agent 展示当前 session 的历史提示词，文档 Pane 展示具有真实源码位置的结构条目。条目支持跳转和复制；缺少 Shell Integration、锚点已被裁剪、内容不受支持或解析失败时，界面给出准确且可操作的说明。

本次对齐以行为契约为目标，不逐像素复制 Otty，也不重做 Git Section、Files Section、Inspector Panel 显隐动画或全局快捷键体系。

## User Stories

1. As an Aster user, I want Info Section to follow the currently focused Pane, so that I never inspect stale information from another Pane.
2. As an Aster user, I want Info Section to update when I switch tabs, so that the displayed information always belongs to the active workspace context.
3. As an Aster user, I want to see the current Pane's reliable working directory, so that I know which project or directory my actions will target.
4. As an Aster user, I want to copy the working directory path, so that I can reuse it in another application or command.
5. As a macOS user, I want to reveal the working directory in Finder, so that I can inspect it with native file tools.
6. As an Aster user, I want to see only installed applications in the Open in actions, so that every visible action can actually be used.
7. As an Aster user, I want opening a directory in an editor to report failure, so that a failed launch is not mistaken for a successful action.
8. As a terminal user, I want Process to include the Pane's Shell and all of its live descendants, so that an idle Shell and nested commands are represented truthfully.
9. As a terminal user, I want each process row to show its name, PID and elapsed time, so that I can identify and distinguish running programs.
10. As a terminal user, I want the foreground process group to be visually distinguishable, so that I can tell which process currently controls the terminal.
11. As a terminal user, I want the process list to refresh while Info Section is visible, so that completed and newly spawned processes do not remain stale.
12. As a performance-conscious user, I want process polling to stop when Info Section or Inspector Panel is hidden, so that an inactive panel does not consume resources.
13. As a terminal user, I want Ports to list listeners owned by the Pane's local process tree, so that I can find services started from that Pane.
14. As a terminal user, I want each port row to identify the process, PID, protocol and listening endpoint, so that ambiguous port numbers remain understandable.
15. As an Aster user, I want duplicate listener records to be collapsed deterministically, so that IPv4, IPv6 and repeated `lsof` rows do not create misleading noise.
16. As an Aster user, I want a clear No listening ports state only after a successful inspection, so that an empty result has a precise meaning.
17. As an Aster user, I want inspection failures to show an explanation and Retry action, so that permissions, timeout and command failures are recoverable.
18. As a file or preview Pane user, I want Process and Ports to say they are unavailable for that Pane type, so that absence of a terminal process is not presented as an empty terminal result.
19. As an Aster user, I want a missing or deleted working directory to be shown as unavailable, so that Aster does not silently substitute an unrelated path.
20. As an SSH user, I want Aster to avoid claiming visibility into remote processes and ports, so that local inspection results are not misrepresented as remote state.
21. As a supported Agent user, I want Info Section to identify the Agent and current session, so that session actions are scoped to the correct Pane.
22. As a supported Agent user, I want to copy the current session ID, so that I can reference or resume it elsewhere.
23. As a supported Agent user, I want to open the current session history, so that I can review earlier interactions.
24. As a supported Agent user, I want to Branch or Fork into a split, tab or window, so that I can continue work without losing the current session.
25. As an Agent user, I want unsupported Fork or Branch actions to be disabled with a reason, so that capability differences are explicit.
26. As an Agent user without an installed integration, I want an actionable setup explanation, so that I know how to enable session-aware features.
27. As an Aster user, I want Agent session data to require an exact current-Pane binding, so that prompts from another Pane are never exposed by a recency heuristic.
28. As a terminal user, I want Outline Section to show the command that is currently running, so that the outline represents the live session rather than only completed history.
29. As a terminal user, I want successful, failed and running commands to have distinct states, so that command outcomes are readable at a glance.
30. As a terminal user, I want command rows to show useful context such as command text, working directory and relative time when available, so that similar commands can be distinguished.
31. As a terminal user, I want clicking a command row to jump to its terminal location, so that navigation is direct.
32. As a keyboard or context-menu user, I want Jump and Copy Text Content actions on each outline row, so that navigation does not depend on a single input method.
33. As a terminal user, I want an old command to remain copyable after its scrollback anchor is trimmed, so that useful command text is not lost from the session outline.
34. As a terminal user, I want Jump to be disabled with an explanation when its anchor has been trimmed, so that Aster does not jump to the wrong location.
35. As a terminal user without Shell Integration, I want a clear requirement and setup entry instead of guessed command history, so that the outline remains trustworthy.
36. As a supported Agent user, I want Outline Section to include prompts from the current session, so that I can navigate both Shell commands and Agent interactions.
37. As a supported Agent user, I want prompt rows to identify their Agent or session and relative time, so that multiple interactions remain understandable.
38. As a supported Agent user, I want clicking a prompt row to navigate to its reliable source when available, so that the outline and transcript stay connected.
39. As a Markdown or HTML author, I want Outline Section to show document headings with their real source lines, so that clicking a heading always reaches the correct location.
40. As a JSON, YAML or TOML author, I want Outline Section to show top-level keys with their real source lines, so that the index is useful for structured configuration files.
41. As a diff viewer, I want Outline Section to show changed files, so that I can jump between file sections efficiently.
42. As an Agent transcript reader, I want JSONL prompts to use Aster's canonical transcript schema, so that real transcripts are indexed rather than only simplified examples.
43. As a document user, I want parsers to show only entries with reliable locations, so that partial parsing cannot create incorrect jumps.
44. As a document user, I want malformed, unsupported and oversized documents to have different states, so that I know whether the content is empty or cannot be indexed.
45. As an editor user, I want rapid edits to coalesce into one outline refresh, so that typing remains responsive.
46. As an Aster user, I want an outdated inspection or parse result to be discarded after switching Pane, tab or document revision, so that late work cannot overwrite current state.
47. As an Aster user, I want the previous snapshot to remain visible but non-interactive during a refresh, so that the panel does not flash empty or execute stale actions.
48. As an Aster user, I want the existing table views and row pools to be reused, so that large outlines and frequent refreshes stay smooth.
49. As an accessibility user, I want loading, unavailable, failed and disabled states to have meaningful labels, so that the same distinctions are available without relying on color.
50. As an Aster user, I want Inspector Panel transitions and page changes to preserve terminal input focus and PTY runtime, so that inspecting details never interrupts terminal work.

## Implementation Decisions

- `Inspector Panel` remains the canonical window-layout term. `Info Section` and `Outline Section` are the canonical names for the two capabilities. User-facing copy may continue to call the container “详情面板”.
- Behavior parity with Otty is the target. Existing native AppKit components, Aster theme tokens, tab-chip layout, Inspector Panel width, animation and persistence remain authoritative for presentation.
- Info Section binds every snapshot and action to the active window, tab and Pane identity. A result is applied only if all identities still match when asynchronous work completes.
- The Info data contract must represent at least `loading`, `loaded`, `unavailable` and `failed`. A successful `loaded` result may contain empty process or port collections; failure and inapplicability must never be encoded as empty collections.
- Working-directory resolution uses the most reliable Pane-specific source: current terminal OSC 7 state for a terminal Pane, the resource or containing directory for a document Pane, and an existing Pane root where one is explicitly owned. No unrelated current directory or filesystem root is used as a fallback.
- Open in actions are discovered dynamically from installed applications. The same injectable editor-discovery and editor-opening boundary is used by Info and Git Sections; launch failures produce user feedback.
- Local terminal Process is the full live tree rooted at the Pane's Shell process, including the Shell itself. Rows expose process name, PID, elapsed time and whether the process belongs to the terminal's current foreground process group.
- Process ordering is deterministic: tree relationship first, then PID for siblings. A process that exits between discovery and rendering is omitted on the next snapshot rather than retained as a live row.
- While Info Section is visible, process and port inspection refreshes every three seconds and also invalidates on active Pane, tab and known command-state changes. Hiding Info Section or Inspector Panel cancels the timer and outstanding inspection.
- Process inspection retains the existing safety boundary: fixed absolute executable paths, no login Shell, bounded output, timeout, cancellation propagation and forced termination of a stuck child process.
- Ports are derived only from local listeners owned by the inspected local process tree. The stable identity is protocol, local address, port and owner PID; duplicate source rows collapse to one displayed row.
- Port rows display process name, PID, protocol and endpoint. They do not automatically open a browser or infer an application protocol. Copying displayed text may use the standard context menu.
- Automatic remote process or port inspection is not introduced. In an SSH session, Aster may show the local Shell and SSH client process but must label Process and Ports as local; it must not execute remote discovery commands or imply that local listeners are remote listeners.
- Info refresh errors expose a safe category and retry action without including command output, environment values, paths or other sensitive diagnostic material.
- Agent information is provided through Aster's existing supported-provider and session-history capabilities, expanded behind one Pane-scoped production interface rather than special-casing process names in the view.
- A Pane may expose Agent session actions only when the provider/session binding is exact. Recency, matching executable names or another Pane's latest history are not sufficient. A missing binding produces a pending or integration-required state.
- Agent actions are capability-driven. Copy Session ID and history require the corresponding data; Branch/Fork destinations include Split Right, Split Left, Split Down, Split Up, New Tab and New Window only when the provider supports them. Unsupported actions remain visible only when a reason helps the user, and are disabled with that reason.
- Terminal Outline owns a bounded, Pane-local runtime index of at most 1,000 commands. It includes a command once its reliable OSC 133 command-start boundary is known, updates the same entry while running, and records its exit status when completion arrives.
- Terminal command status semantics are fixed: gray dot for running, green check for exit status zero, and red cross with the status for non-zero completion.
- Terminal output is never scraped to guess commands when Shell Integration is missing. Outline shows an explanation and routes the user to the existing Shell Integration setup surface.
- Command text is retained within the bounded runtime index after its scrollback anchor is trimmed. Copy remains available; Jump becomes disabled and explains that the source is no longer in the buffer.
- Outline's primary click action is Jump. Its context menu provides Jump and Copy Text Content. Both actions are disabled while a retained old snapshot is covered by the refresh overlay.
- Agent prompt entries come only from the exactly bound current session. Unknown Agent-like CLIs remain ordinary terminal commands. Prompt rows must not expose another Pane's history.
- Document Outline continues to support Markdown, HTML, JSON, YAML, TOML, diff/patch and recognized JSONL Agent transcripts. Every generated row must carry a real source line or another reliable navigation anchor.
- JSON object keys preserve their source positions; alphabetical reordering must not manufacture line numbers. YAML and TOML include only reliably identified top-level keys. HTML recognizes valid heading structure without requiring both tags to be on one physical line. Markdown continues to index headings without executing embedded content.
- JSONL transcript indexing reuses Aster's canonical Agent transcript decoding rules, including nested and array content forms already supported by Agent history. A second reduced transcript schema is not maintained.
- Parsers may return reliable partial results for recoverable malformed input. If no reliable result exists, the state distinguishes empty structure, unsupported content, size limit, malformed content and cancellation. Cancellation caused by a newer revision is not shown as an error.
- Document parsing remains off the main thread, uses trailing debounce for consecutive edits, cooperatively checks cancellation, applies revision validation and preserves the existing virtualized table and row pool.
- Info and Outline retain the existing lazy-loading rule: only the selected Section performs expensive work. Completed snapshots may remain cached while hidden, but hidden pages do not poll or parse.
- Pane and tab switches retain the existing atomic-refresh behavior: the previous snapshot remains visible, an overlay blocks stale interactions, delayed loading feedback avoids short spinner flashes, and only a fully validated current result replaces the snapshot.
- Inspector work must not trigger whole-workspace reconstruction, change Pane UUIDs, restart PTYs, disturb first responder, or add intermediate terminal resize events.
- No persistent schema migration is required. Process snapshots, command indexes and refresh states are runtime data; existing session history remains the source for persisted Agent prompts.
- The developer documentation must gain a focused Details Panel domain section or document covering business background, domain concepts, rules, flow, implementation boundary, failure semantics and acceptance. User help, Otty parity status and design QA must be updated to describe only behavior that has actually been verified.
- The existing parity status must not continue marking Info/Outline complete until implementation tests and applicable real-window acceptance are complete.

## Testing Decisions

- Tests assert externally visible behavior and domain outputs, not private timers, individual view-construction calls or specific subprocess implementation details.
- The primary high-level seam is the existing Details Panel controller with injected inspection, editor-opening and Pane-scoped Agent-session dependencies. It verifies rendered state, enabled actions, active-Pane identity, retry, refresh replacement, stale-action blocking, navigation and copy behavior.
- The production dependency boundary should be extended rather than adding test-only hooks. Info and Git use the same editor boundary; Agent details and prompt Outline use one Pane-scoped session-capability boundary.
- Controller-level tests cover each Info state: loading, successful process/port data, successful empty ports, non-terminal unavailable, inspection failure and retry success.
- Controller-level tests verify the full Process row contract, foreground indication, deterministic order and Ports de-duplication through injected snapshots without invoking real local processes.
- Controller-level tests cover exact Agent binding, all capability combinations, missing integration, unsupported Fork, each placement target, and the guarantee that history from another Pane is never rendered.
- Controller-level tests cover running, successful and failed terminal commands; primary-click Jump; context-menu Jump and Copy; trimmed-anchor behavior; and missing Shell Integration guidance.
- Controller-level tests cover Markdown, HTML, JSON, YAML, TOML, diff and canonical JSONL transcript rows, including actual click-to-source navigation.
- Pure AsterCore tests remain the seam for process-tree construction, port parsing/de-duplication, command-index transitions and document source-position extraction. These tests use value inputs and outputs and do not construct AppKit views.
- TerminalSession integration tests remain the seam for OSC 133 A/B/C/D event sequences, running-to-completed transitions, absolute buffer anchors and scrollback trimming. They must prove the behavior through the public timeline/navigation surface.
- Existing Details Panel lifecycle tests are extended to verify three-second refresh invalidation semantically with a controllable clock or scheduler at the controller boundary, not by waiting for wall-clock time.
- Cancellation tests verify that hiding the Section, switching Pane, switching tab or advancing document revision prevents a late result from changing the visible snapshot.
- Failure-path tests cover missing `ps`/`lsof`, permission failure, timeout, malformed output and cancellation at the inspection-client boundary. User-visible tests assert safe categories rather than raw process error text.
- Parser tests include multiline HTML headings, JSON keys whose source order differs from alphabetical order, nested YAML/TOML content, malformed-but-partially-indexable input, size limits and real nested Agent transcript fixtures.
- Accessibility assertions verify that status icons have text alternatives and disabled actions expose reasons without relying only on color.
- Performance regression tests preserve the existing stable root views, virtualized tables, row reuse, lazy page work, debounce and identity/revision validation. They should not depend on exact private subview counts beyond existing architecture invariants.
- Applicable verification for implementation completion is: focused AsterCore tests, focused Details Panel tests, Shell Integration/TerminalSession tests, the full non-parallel test suite and a release build. Real-window interaction should validate Process/Ports, Agent actions, Jump/Copy, Pane switching and focus retention when such UI verification is explicitly authorized.
- Prior art includes the existing Details Panel controller tests for page caching and Pane refresh, Workspace discovery parser tests, and Shell Integration timeline tests. New cases extend those suites instead of creating one test file per behavior.

## Out of Scope

- Pixel-for-pixel reproduction of Otty's visual design.
- Redesigning Git Section or Files Section.
- Changing Inspector Panel width, persistence, tab-chip animation, fixed toggle icon or collapse/expand transition.
- Adding Otty's exact global shortcut or replacing Aster's command and keybinding systems.
- Guessing terminal commands from rendered terminal output when OSC 133 is unavailable.
- Automatically inspecting remote SSH hosts or executing `ps`, `lsof` or equivalent commands remotely.
- Automatically opening listening ports in a browser or guessing whether an endpoint is HTTP, HTTPS or another protocol.
- Adding support for new Agent providers beyond the providers Aster already recognizes.
- Persisting a new global history of Shell commands or Agent prompts.
- Indexing arbitrary programming-language symbols beyond the documented Markdown, HTML, structured-data, diff and Agent transcript formats.
- Introducing SwiftUI, third-party parser dependencies or business logic into vendored SwiftTerm.
- Changing Git/Files write-operation safety rules or executing new background write commands.

## Further Notes

- Source behavior references: [Otty Details Panel](https://docs.otty.sh/user-interface/details-panel), [Otty Outline / Jump To](https://docs.otty.sh/user-interface/outline), [Otty Shell Integration](https://docs.otty.sh/terminal-features/shell-integration), and [Otty Fork / Branch Session](https://docs.otty.sh/agents/fork-branch-session).
- Aster's existing glossary defines Inspector Panel as a window-level Panel rather than a content Pane. Implementation and tests must preserve that distinction.
- The reliable Pane-to-Agent-session binding decision deliberately rejects a tempting recency heuristic. If the implementation introduces or centralizes this cross-domain interface, record the rationale in a short ADR before merging.
- This specification is published to the local Markdown issue tracker because the repository currently has no Git remote from which a GitHub or GitLab issue target can be resolved.
