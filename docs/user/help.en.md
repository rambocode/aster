# Aster User Guide

## What Aster Does

Aster is a native macOS terminal workspace built entirely with AppKit. It supports full-color terminals, full-screen programs such as `vim`, `top`, and `fzf`, multiple tabs, and splits in any direction. File browsers, editors, and previews can share the same workspace.

The current terminal uses the Ghostty engine. Shells, full-screen TUIs, selection, copy and paste, scrolling, full-buffer search, titles, directories, notifications, read-only mode, Vi / Mark / Hint Mode, inline Autocomplete, Agent status, and command Outline are available. Ghostty handles explicit OSC 8 links. Hint Mode currently lists visible URLs and paths, not hidden OSC 8 URIs behind display text.

## Diagnostic Logs and Feedback

Use **Help → Report an Issue…** to enter an optional description, then choose **Save Diagnostic Package…** or **Share…**. Aster creates a ZIP only after you choose an action and uses the macOS share sheet; this flow does not upload information automatically. The package contains only Aster application logs from the last 7 days, capped at 20 MB, plus version and system summaries. Shell failures record exit type, status code, and session identifier, without terminal input or output, commands, paths, environment variables, configuration, clipboard contents, or system crash reports. Use **Open Logs Folder** to inspect `~/Library/Logs/Aster` first.

## Getting Started

1. Double-click `Aster.app`. Aster restores the previous workspace; on first launch it starts a login Shell in your home directory. Before starting the Shell, each restored terminal Pane prints dim timestamp banners: `Exited at MM/dd HH:mm` (when the last snapshot was saved, usually at exit) and `Restored at MM/dd HH:mm`. Output after them belongs to the current session. Snapshots from older versions have no exit time and show only the restore line.
2. Click the terminal and type commands directly; there is no separate input field.
3. Press `⌘T` for a new tab, `⌘D` to split right, or `⇧⌘D` to split down. The **View** menu contains all split commands.
4. By default, `⇧⌘P` opens the command palette to search the main actions. With the terminal focused, `⌘K` clears its screen. Customize the command-palette shortcut in **Settings → Shortcuts**.

### Multiple Windows, Pinning, and Picture in Picture

- `⌘N` opens an independent window with its own workspaces, tabs, splits, and restore snapshot (see **Named Workspaces** for workspaces within a window). Normal app exit restores additional windows that were still open. Windows you explicitly closed do not reopen on the next launch.
- Drag a vertical or horizontal tab to another Aster window to move it. Drop outside all windows to create a new window; drop on a Pane in the current window to merge it into the current tab (see **Drag a Tab into a Pane**). Running PTYs, scrollback, editor drafts, and Agent status are preserved.
- **View → Pin Window** toggles whether the current workspace stays on top. The separate Settings window does not change pinning.
- **View → Picture in Picture** opens system Picture in Picture, either fixed to the current terminal Pane or following the active Pane in the same workspace. The original terminal remains usable; resizing the floating window does not reflow it. Choose the same mode again or use the system close button to exit. Pause freezes the mirror, not the command. Non-terminal Panes are not supported yet.
- To type into the floating window, set **Settings → General → Picture in Picture → Picture in Picture Style** to **Interactive Window**. Selecting **Current Pane** then moves the terminal itself into an always-on-top window, supporting typing, IMEs, and full-screen programs such as Vim across Spaces and full-screen apps. Its original position shows a placeholder. Close the small window, press `⌘W` there, choose **Return to Workspace**, or select **Current Pane** again to return the terminal without ending the Shell. The terminal reflows to the smaller window; position and size are remembered. **Follow Active Pane** always uses system Picture in Picture.

## Tabs and Three Layouts

Choose a vertical, top, or bottom layout in **Settings → Appearance → Layout**. It applies immediately while Settings stays open. The vertical layout defaults to a 220 pt sidebar. Drag the divider between the left bar and central content to set a width from 180 to 360 pt; it darkens on hover. Double-click to reset to 220 pt. Dragging changes width and does not collapse the sidebar.

A tab row displays the directory name (`~` for home), keeping its name when you switch tabs. Running commands show a spinner on the right; hover replaces it with `×` so you can close a background tab without switching to it. Old sidebar widths migrate when a workspace window first creates its Panel layout; each window then saves its own left and right widths. Tab rows are rounded cards with selection and hover backgrounds. Hover anywhere over the sidebar to reveal `+` at the upper right; moving up to the traffic-light row also reveals the collapse icon. `+` remains visible when you switch tabs. With the sidebar hidden, hover at the window top beside the traffic lights to reveal `+` and expand, or use **View → Show/Hide Tab Bar**. New tabs are appended by default. The tab panel can stay visible or hide when there is only one tab; a tab's context menu offers splits, a file browser, and close. Terminal content extends to the bottom of the window without the old `workspace · path / PANE / UTF-8` status bar. Window size is saved after resizing; **Window Size** can restore the default.

In the top layout, traffic lights and the central directory capsule share a title row; the tab bar sits below it, clear of the traffic lights. In the bottom layout, tabs sit at the bottom and the title row stays at the top. Horizontal tabs fit their titles: the current tab is a rounded theme-colored capsule with a closing `×`; other tabs are text with hover feedback. Context menus still offer rename, split, file browser, and close. Running and awaiting-input badges sit at the right of each tab, with long titles truncated at the end. `+` opens a new tab. The command palette uses `⌘⇧P` or the View menu instead of a tab-bar icon. Tabs can still be dragged to other windows.

The organize icon beside `TABS` opens grouping and sorting: `No Grouping / By Project / By Date`, `Created Time / Updated Time`, `Insert Divider` after the current tab, and `Remove All Dividers`. Choices are saved; group headers appear only when grouping is enabled. Local projects use a folder icon and the final directory name, such as `aster`. SSH projects use a computer icon and group separately by the resolved server `hostname`. They have distinct identities, so an SSH tab does not stay in its originating local group. Full local paths remain the identity and tooltip, keeping equally named folders under different parents separate. `⌘T` and sidebar `+` inherit the current tab's directory and local project. After an `ssh` command, Aster asynchronously resolves the final hostname using OpenSSH configuration: for example, `ssh root@ubuntu@orb` may resolve through `~/.ssh/config` to `127.0.0.1` and form a separate SSH project. A failed connection, exit, or return to the local Shell restores the local directory group.

Right-click a tab and choose **Rename Tab…** to set a fixed name or a dynamic prefix that keeps updating with the running program. **Restore Auto Title** returns to the program's OSC title. Names, prefixes, and the last title are restored with the workspace. When an integrated Agent CLI such as Claude Code or Codex runs in the current Pane, its session title appears: preferably the Agent's own title (Claude Code's automatic title or `/rename`, or Codex's thread name), otherwise the first meaningful question after a brief delay following the initial prompt. A manually fixed name takes priority; the original title returns after the Agent exits.

New tabs receive an automatic title color. Within a window, colors are distinct until all 12 are used, then favor the least-used color. **Title Color** in the context menu lets you choose a color, request another random color, open a custom color picker, or reset to the default. Colors restore with the workspace. Disable **Random Title Colors** in **Settings → View → Tab Icon and Badge** to use the theme foreground again; manually chosen colors remain.

The tab-bar settings under **Appearance** also control new-tab position. **Auto** puts empty tabs at the end of the current group and tabs with directories or files after the current tab; you can instead always use the list end or the position after the current tab. In every case `⌘T` inherits the current tab's live working directory, or home if no tab can provide one.

When a window loses keyboard focus, the workspace fades slightly toward the theme background and the terminal cursor stops blinking without changing shape. Focus restores it; the first click still reaches the terminal. When content exceeds the Pane height, scrolling or hovering at the right edge reveals a scrollbar that fades afterward. Its own narrow gutter does not cover text. It is hidden for content shorter than a screen and for full-screen TUIs.

The upper-right title area uses the same background as the terminal canvas and normally shows the active Pane's program title. Hover to reveal a gray working-directory capsule. With a titled Agent session, the capsule shows its session title and the full directory moves to the tooltip. Click for tab name/prefix, copy path, Finder or installed-editor actions, prefilled Git commands, splits, current/global find, Jump to, and the command palette. **Notifications & Privileges** opens Shell notification settings. Git write actions only prefill the terminal; you execute them with Return. Aster loads signed Shell Integration for zsh, Bash, and fish. Where supported, OSC 7 updates the sidebar and session snapshots in real time; `file://localhost/...` becomes a readable `~/...` path and is safely restored as a local directory.

### Shell Integration and Command Navigation

- zsh and fish inject resources only into the current Aster-started session. Bash and tmux subshells use managed blocks with clear boundaries in `.bashrc`, `.bash_profile`, `.zshrc`, or fish `conf.d`. Aster changes only its blocks and preserves user content, permissions, and symbolic links.
- **Settings → Shell → Shell Integration** is on by default. Turning it off asks for confirmation and removes managed blocks without losing dependent preferences such as notifications and badges. Set `ASTER_DISABLE_INTEGRATION=1` before starting an individual Shell to disable it there.
- `Command+Page Up / Page Down` jumps to the previous or next command. Commands trimmed from scrollback do not jump to unrelated text. A running command shows a tab indicator; completion shows `✓` or a nonzero exit code according to settings.
- Ghostty Shell Integration supplies prompt markers and command navigation. The old engine's selection Backspace deletion behavior is not enabled in this version.

## Frequent Directories

Aster locally records directories visited in the terminal and ranks up to 100 by frequency and recency for quick opening and `jump`. Visits in the last hour have the highest weight. Queries favor an exact directory name, then name prefix, name substring, and full path.

**Settings → Shell → Frequent Directories → Automatically Record Visited Directories** is on by default. Turning it off stops new OSC 7 directory changes from entering the ranking. Ignored directories do not return after another `cd`; remove them from the ignore list first. This data stays on the machine without uploading or automatic synchronization.

## Splits and Panes

The **View** menu contains all split commands.

**Split**

- `⌘D`: right; `⌥⌘D`: left; `⇧⌘D`: down; `⌥⇧⌘D`: up.

**Zoom and Size**

- `⇧⌘↩` temporarily zooms the current Pane to fill the right content area; press again to restore. You can also hover at a Pane's top edge and click the circular zoom button beside `×`. That Pane zooms, and the button becomes restore. Sidebar and details-panel visibility stay as before. Other Panes keep running. Splitting or changing focus automatically restores the layout. Customize **Zoom Current Split** in **Settings → Shortcuts → Pane**; the shortcut persists across launches.
- `⇧⌘B` collapses or restores the current Pane's live view, stopping its redraw while Agent output continues. See **Collapse Live View** below.
- Double-click the empty top title strip around the path capsule to zoom/restore the entire window, equivalent to **View → Zoom**. This gesture replaces the hidden native title bar's double-click behavior.
- **Resize Split** offers `⌃⌘=` to equalize and `⌃⌘↑ / ↓ / ← / →` to move the current Pane's divider by 5% in that direction.
- Dividers are normally gray lines. Hover makes them thicker and uses the system accent (blue by default). Drag to resize; double-click to equalize. Ratios save with the session and terminals receive updated row/column sizes.
- While resizing the window edge, each affected Pane briefly shows its grid size, such as `75 x 24`, fading about 0.75 seconds after you stop. It does not intercept clicks. Divider changes, panel toggles, tab/Pane switches, and automatic layout after creating a Pane do not show it.

**Drag Panes to Rearrange**

- Hover at the center of a Pane's top edge to reveal a gray capsule. Hovering directly over it lengthens and darkens it and shows a grab cursor. It uses system gray, independent of the theme. Split content leaves room for this strip so it does not cover the first text line.
- Drag the capsule to move the Pane without restarting its terminal or scrollback. At another Pane's edge (the outer 25% on each side), half the target highlights in the theme color and the Pane inserts on that side. At the center, the whole target highlights green and the two Panes swap without changing the split structure or ratios.
- Dropping back on the source has no highlight and cancels.

**Drag a Tab into a Pane**

- Drag a tab from the left, top, or bottom bar onto a Pane in the current workspace. The target highlights half the Pane in the theme color; it merges on the nearest side, or on the right when dropped at the center.
- The entire dragged tab merges with its original split structure. Terminal processes, scrollback, editor drafts, and Agent status continue. The source tab disappears without entering Recently Closed.
- Tab clicks switch on mouse release, so dragging does not change the current workspace. Releasing within this window away from a Pane acts as a tab click.
- The selected tab cannot merge into itself. Remote-machine tabs cannot be merged.

**Drag a Pane into Its Own Tab**

- Drag the top-edge capsule onto the sidebar or horizontal tab bar. The whole bar highlights; on release, the Pane becomes a new tab after the current one.
- Processes, scrollback, drafts, and Agent status continue; nothing enters Recently Closed. The original tab stays selected and remaining Panes fill the space.
- The new title follows that Pane's program or directory; a fixed source-tab name does not transfer.
- This is unavailable when only one Pane remains, the tab bar is hidden, or the Pane belongs to a remote machine.
- The resulting tab can be dragged back into a Pane later.

**Focus and Close**

- **Focus Pane**: `⌥⌘↑ / ↓ / ← / →` focuses a neighbor; `⌘]` / `⌘[` cycles through Panes.
- Clicking any Pane, including terminal content, makes it current for find, interrupt, split, and close. Inactive split Panes fade slightly toward the theme background without a highlight border. The first click still reaches their terminal and restores its colors.
- `⌘W` closes the current Pane, or the whole tab if it is the last Pane. `⇧⌘W` always closes the tab; `⌥⌘W` closes only the Pane.
- Hover at the top of a split Pane for gray zoom/restore and `×` buttons; they darken with a hand cursor. `×` closes with the same behavior as `⌘W` and records Recently Closed. A single Pane does not show these buttons.
- Closing focuses a neighbor rather than jumping to the first Pane.

## Files, Editing, and Previews

The details panel's **Files** tab is rooted at the current working directory. Double-click Markdown, reStructuredText, HTML, SVG, or source code to open editable **Source** on the right. Images, PDFs, rich documents, diffs, Agent transcripts, and binary files remain read-only previews. Expand directories with an arrow or double-click. Context-menu actions include:

- `Open`: use the macOS default app, with another confirmation for executables or `.app` bundles.
- `Open in Aster`: Current Pane, New Tab, New Window, or Split Right/Left/Top/Bottom.
- `New File…` / `New Folder…`: create in a selected file's parent or inside a selected directory, without overwriting an existing name. New files open as editable Source.
- `Rename…` / `Move to Trash`: open Panes follow a renamed path; deleted items go to the recoverable system Trash.
- `Copy Path` / `Copy Relative Path` / `Reveal in Finder`: relative paths use the current Files root without `./`.

A File Pane's toolbar has mode, Send to Chat, and sharing on the left; filename and a more menu centrally; and `✓ Saved`, `Edited`, disk-conflict/error status, save, and close on the right. Markdown, reStructuredText, HTML, and SVG use code/eye controls to switch between editable Source and Preview; ordinary source uses code/lock to lock or unlock editing in place. Switching preserves selection, scroll position, and undo. `⌘S` saves atomically; there is no autosave. Closing unsaved content asks to save, discard, or cancel. External changes automatically reload an unedited Pane. With local edits, `Modified on Disk` appears; **… → Reload from Disk** explicitly discards local content.

Preview supports Markdown including GFM tables and task lists, reStructuredText, HTML, SVG, common images/GIF, PDF, diff, Office/media/font Quick Look, binary hex, and recognized Agent transcripts. HTML/SVG/Markdown previews disable JavaScript and network requests. Agent transcripts render by role with Markdown and collapsible tools, plus Resume or Fork. Hex draws only visible rows; large text and binary reads are bounded so one Pane cannot consume all memory. Remote SSH paths do not yet support File Panes.

For an ordinary UTF-8 file, the bubble **Send to Chat** action requires a non-symlink file no larger than 64 KiB. It removes control characters and masks common secrets first. Read/save failures show an explicit error and retain unsaved content.

Drag Finder files or directories to a Pane edge to create previews, file browsers, or new terminals inheriting the directory in the highlighted direction. Text dropped into a terminal uses the same dangerous-content confirmation as paste. HTTP/HTTPS URLs create Web Panes in that direction. At most 32 URLs are handled at once; symbolic links and special files are not read.

### Open Files and Links in the Terminal

Hold `⌘` to underline all clickable targets in the viewport. Hover shows a hand cursor, including when you press Command with the pointer already over a target; releasing Command or moving away restores it. Clicking uses the system default app or the destination selected in **Open In**. Aster recognizes absolute paths, `~/`, `./`, relative paths based on current OSC 7 directory, existing bare filenames such as `Makefile` or `site/README.md`, `path:line:column`, URLs, `mailto:`, and explicit OSC 8 links. Remote relative paths are not treated as local files.

In **Settings → Control → Link Protocols**, **Automatically Recognize Link Protocols → All** recognizes valid protocols. **Custom** limits plain-text URLs to `http`, `https`, `file`, `mailto`, and configured schemes. Explicit OSC 8 links are not limited by that list but still undergo security checks. **Show Link Preview** controls the full target tooltip in the lower-left corner on Command-hover; disabling it leaves links clickable. Local relative paths expand against the current trusted directory. The fixed translucent rounded tooltip is white on black in light appearance and black on white in dark appearance, independent of terminal theme. **Reset Security Prompts** clears all remembered Always Allow choices.

Under **Custom**, choose **Configure…** to add, edit, or remove protocols line by line; valid changes save immediately. Enter `codex` or `ssh`, or `SSH://` which normalizes to lowercase. Up to 64 protocols of at most 64 characters are allowed. Invalid input stays visible in red, and failed saves can be retried. **Done** or `Esc` closes after saving and returns to Configure. Switching to All preserves the custom list. Protocol changes immediately update open terminals' targets, underlines, and hand cursors. Reset success briefly shows a checkmark for about 1.6 seconds while retaining protocols and preview preferences.

**Settings → Control → Open In** separately chooses destinations for links, files, and folders. Local ordinary files/folders can open in Aster Editor / File Browser Panes or in system apps/Finder. HTTP/HTTPS pages can open in a Web Pane restricted to web navigation, without access to local files or custom protocols. The default Git client and custom apps are stored by bundle ID so macOS can find them after moving or upgrading.

The first open of an external website, nonstandard scheme such as `codex://`, executable, or `.app` asks to open once, always allow, or cancel. Reset clears these exceptions. Executable authorization follows the current file identity, so replacing or modifying it asks again. Settings import does not import another machine's security permissions. FIFOs, sockets, and device files are always rejected to avoid blocking or accessing system devices.

### Copy and Paste

- Use `⌘C`, **Edit → Copy**, or the terminal context menu to copy a selection, and `⌘V` to paste. **Copy on Select**, **Trim Trailing Whitespace When Copying**, and **Clear Selection After Copying** are all off by default. Copy on Select keeps highlighting for selection extension and ignores clear-after-copy.
- Paste protection is on by default. Multiline content, a trailing newline, `sudo`/`su`, or invisible control characters show a bounded preview with **Paste Anyway** or cancel. Full-screen TUIs or trusted bracketed paste may skip ordinary multiline warnings, but invisible controls always require confirmation. Embedded bracketed-paste end markers become visible text and cannot prematurely execute following commands.
- **Edit → Paste As** retains bracketed paste and **Paste and Continue in Composer**. Selection paste, Base64 file, and Shell-argument escaping actions that depend on the old engine's private input state are currently disabled.
- **Paste and Continue in Composer** hands clipboard text to Agent Composer when available; otherwise its context-menu entry is disabled.
- **Edit → Prompt Queue…** works in the current terminal regardless of Claude Code/Codex detection. It opens an input strip at the Pane bottom; Return or the upward arrow adds an item to the list. With installed lifecycle hooks, idle Claude Code/Codex receives the first queued prompt immediately; processing queues it until the turn ends, one at a time. Awaiting permission/input never sends automatically: Return at a permission selector would approve a tool call. Ordinary CLIs without hooks remain fully manual.
- Click an item's left `↳` to send immediately, or its trash icon to remove an unsent item. Closing the input strip does not cancel the queue. Expand for multiline input. Read-only and terminal input-mode restrictions still apply.
- **Edit → Send to Chat…** and context-menu **Send Selection to Chat** open a confirmation panel. Choose the current selection and/or terminal transcript, then a running Claude Code/Codex Pane from the current workspace. Send prefills the Comment and cleaned, masked context as ordinary typing; it does not press Return.
- In a remote managed terminal, `⌘V` with a PNG/TIFF clipboard image uploads it to a remote temporary directory and pastes only the remote path without a newline. Failure, cancellation, a changed terminal, or lost lease pastes nothing and leaves no partial remote file. The limit is 20 MiB per image. Image content does not enter diagnostic logs.

Programs can request clipboard access via OSC 52. **Settings → Control → Copy & Paste** separately offers Allow / Ask Every Time / Deny; writing defaults to Allow and reading to Ask Every Time. Each prompt authorizes only that request, followed by a 5-second cooldown for repeated requests. Config import cannot silently change read permission to Allow. Rejected or oversized requests do not read the clipboard.

### Select Terminal Text

- Drag for characters, double-click for words, and triple-click for a line. Shift-click extends from an existing anchor; Option-drag selects rectangular columns.
- Vi / Mark Mode supports keyboard movement and selection extension. Ghostty handles mouse and Option-rectangle selections.
- When programs such as vim or tmux enable mouse reporting, Ghostty and the foreground program determine whether Shift stays available for local selection.
- Copy on Select, clear-on-input, clear-after-copy, and trailing-space treatment under **Control → Selection** apply immediately. Old-engine Shift-arrow and Backspace deletion switches do not currently apply.

### Scroll Terminal History

- The wheel or trackpad browses the normal buffer. With smooth scrolling, trackpad movement follows pixels and aligns to character rows after the gesture and inertia end; the mouse wheel remains row-based. Input returns to the latest content. New output follows only when already at the bottom; a running command or TUI does not pull you away from history you scrolled up to read.
- Scrolling or hovering at the right edge reveals a fading scrollbar when content exceeds the Pane height. Drag its thumb to locate any position; click above/below it to move by one screen.
- `Shift+Page Up / Page Down` pages; `Shift+Home / End` goes to the earliest/latest content. `Command+Page Up / Page Down` navigates Shell commands. These are also in **View → Terminal Scroll**.
- **Settings → Control → Scroll** can disable smooth scrolling and choose whether the last content line, cursor line, or first content line stops at the viewport top, center, or bottom when scrolling beyond the end/start. Full-screen TUI alternate screens never allow out-of-bounds blank space.

### Rendering and Continuous Output

Aster uses Ghostty's Metal renderer. The same engine manages PTY reads, VT state, scrollback, and drawing; Aster responds to the resulting render requests. Continuous output no longer uses the old AppKit byte-batch and Core Graphics grid path.

### Input and Secure Keyboard Entry

- Ghostty encodes keyboard, IME, modifier, and Kitty keyboard-protocol input. Aster no longer guesses ordinary Shell line-editing sequences separately.
- **Edit → Insert** selects one or more file/folder paths or starts a system interactive screenshot. Safely escaped paths are prefilled into the current foreground input, including Codex/Claude TUIs, without execution. **Edit → Insert from iPhone** offers nearby iPhone/iPad camera or scanning actions and inserts the private temporary path through the same flow. Phone imports accept common images or PDFs, up to 32 MiB per item.
- **Edit → Composer** (`⇧⌘E`) opens an input area at the current Pane's bottom for typing, sending, or adding to Prompt Queue; it is not a file picker. Open local files through File, the file tree, or a path. **Prompt Queue…** (`⇧⌘M`) and **Send to Chat…** open the current terminal's queue strip and confirmation panel respectively.
- New installs default **Option as Meta** to off, preserving accented/special-character entry. For Emacs/Vim-style Esc prefixes, choose both, left-only, or right-only Option under **Control → Keyboard**. VT100 keypad mode defaults to allowed; when off, the keypad keeps entering numbers even if a program requests DECKPAM.
- **Control → Mouse** configures right-click as menu, copy, paste, selection-dependent, or ignored; `Control + right-click` always opens the menu. It also configures the bypass modifier for TUI mouse reporting, hiding the pointer while typing, hover-to-focus, and click-to-move-cursor on a reliable Shell prompt line.
- **Automatic Secure Input** is on by default. A focused terminal entering canonical hidden input, such as a password prompt, activates macOS Secure Event Input on output arrival and before the first key is sent. Raw-mode TUIs such as Vim/less do not claim it. Echo restoration, focus loss, process exit, or switching apps releases it. **Edit → Secure Keyboard Entry** toggles it manually. A blue `SECURE INPUT` capsule appears in the workspace title bar only after system protection is active. Manual state pauses when Aster is inactive and resumes on return.
- Codex, Claude, and ordinary Shell inputs retain `Ctrl+A`, `Ctrl+E`, `Ctrl+K`, `Ctrl+U`, `Ctrl+W`, and other line-editing keys. Aster's native `⌘←` or `⌥←` menu shortcuts do not take them over.

### Font Size and Full Screen

- **View** offers increase/decrease/reset font size, also `⌘=`, `⌘-`, and `⌘0`. The range is 9–32 pt, reset is 13 pt, and changes apply to all open terminals.
- **View → Enter Full Screen** or `Fn+F` toggles the workspace window; the menu becomes Exit Full Screen afterward.

### Read-Only Mode

- Aster Vi / Mark / Hint Mode uses stable coordinates in Ghostty's retained buffer. Output or reflow invalidating an old anchor safely exits the mode.
- **Shell → Read-Only Mode**, or the command palette (`⇧⌘P`), toggles read-only per Pane. Keyboard, IME, paste, and TUI mouse reports no longer reach the program; output, scrolling, selection, copying, and find remain. Editor Panes stop accepting edits too. This temporary lock is not restored after closing and reopening the workspace.

### Collapse Live View

- Visible Panes redraw for each frame of continuous Agent output, including unfocused splits and Aster windows beside other apps. Collapse a Pane's live view when you do not need to watch it, to avoid that drawing work.
- Use terminal context-menu **Collapse Live View**, **View → Collapse Live View** (`⇧⌘B`, current focused Pane), or search **Collapse or Restore Live View** in the command palette.
- A small card replaces the view. With an Agent it shows the Agent name and processing, awaiting confirmation/input, idle, or completed status; waiting is highlighted. Otherwise it shows the Pane title. It shows only the collapse time, such as 14:03, without a running timer.
- The process, Agent, and terminal contents continue, and terminal size stays the same. Completion/wait notifications still work. Aster neither restores the view automatically nor steals focus.
- Click **Restore Live View**, choose the same menu again, or press Return/Space while the card is focused to show the latest view immediately.
- Keys are not sent while collapsed, avoiding unseen input. Tab/app switches do not restore it. Collapse state is not saved; restored workspaces show live views.
- Panes in system or interactive Picture in Picture cannot collapse; that action is disabled. Opening Picture in Picture for a collapsed Pane first restores its view.

### Autocomplete and Inline Suggestions

Choose keys under **Settings → Control → Autocomplete**:

- **Accept Candidate**: `Tab`, `Tab + Right Arrow` (either accepts), `Control + Space`, or Off (no key accepts the gray suggestion). macOS defaults Control+Space to input-source switching; change/disable that in **System Settings → Keyboard → Keyboard Shortcuts → Input Sources** before choosing it here.
- **Candidate Panel**: Auto opens while typing, Esc to Open uses Esc, Option + Esc to Open uses Option+Esc or F5, and Off never shows it.

With the panel visible, Tab can accept its first item. Return accepts an explicitly selected candidate; otherwise it goes to the Shell. Explicit failure corrections are definite suggestions and may take inline priority over history candidates.

The panel shows up to 8 rows, with arrow-key scrolling and full descriptions in its right sidebar. It does not automatically open on an empty prompt; it opens after the first character and hides if you delete everything. Esc can still open it manually. Continued typing narrows results without closing it. Auto-opening does not treat the first item as your selection: arrows select, and Return or Tab accepts. One Esc dismisses it for this prompt; another reopens it. Disabling both inline suggestion and the candidate panel fully disables this feature, including querying the built-in specifications.

Autocomplete uses Ghostty's raw PTY observer. Inline suggestions appear only for a single candidate or an explicitly selected one; changing selection updates preview and description together.

#### Clipboard Suggestions

Copy a command from a browser, document, or chat, then return to Aster. At an empty prompt it appears in gray with a paste hint. **Return inserts it into the input line without executing it**; review it and press Return again to run. Start typing or press Esc to ignore it. The same clipboard contents are not suggested twice.

Suggestions require a single line of at most 128 characters, without control characters or Chinese text, and not a URL. Options, pipes, redirection, `&&`, environment assignments, or path syntax identify commands even if the tool is not installed. Ambiguous plain words require a recognized first command (built-in spec, alias, history, or executable in `PATH`). Prose, URLs, and logs do not trigger suggestions. A short guard delay before Return can accept prevents accidental paste from repeated empty-prompt Return presses.

Clipboard contents marked concealed by password managers such as 1Password/Keychain are never suggested, nor are any suggestions shown during secure input. They appear only in the active input Pane. Disable **Clipboard suggestion** in **Control → Autocomplete** to turn them off. The gray text reveals clipboard contents on screen, so take care when recording or presenting. It uses the terminal font and input baseline without covering the prompt or echoed command. Candidate acceptance, privacy filters, local learning, and directory-context rules still apply.

An empty prompt recommends the current directory's frequent commands, pinned commands, and README commands, not the entire specification library. After a recognized failure, a correction takes priority at the next prompt; typing ignores it. If the Shell's own gray suggestion occupies the line end, Aster hides its inline suggestion but keeps the panel. Narrow Panes show fewer rows to avoid covering input.

After a complete command name but before a space, such as `docker`, candidates include that command's subcommands/options as well as other names sharing the prefix. Tab or another configured acceptance key accepts an already visible suggestion, including one drawn by zsh-autosuggestions. Aster sends only the suffix rather than invoking zsh's “list all possibilities” question. A single candidate stays inline; an open panel narrows to one and closes. With multiple candidates and no visible suggestion, the acceptance key opens the panel. Native Shell completion receives the key only when neither a suggestion nor candidates exist.

**Context-sensitive completion:** `cd` lists directories, including directory symlinks; `cd ..` becomes `../` and `cd ~` becomes `~/`. Previously visited directories that no longer exist are not recommended (this check is not made for remote sessions). Subcommand slots do not include unrelated project files. Names containing spaces or quotes preserve your existing quoting/escaping style. Options support `--option=value`; used nonrepeatable options are excluded and arguments after `--` are positional. Historical arguments learn per directory and argument position, so a frequent branch can still be suggested after adding `--force`. Disabling local learning disables historical argument suggestions too.

**Dynamic candidates:** when a built-in spec requires live data, such as `git checkout <branch>`, `brew install <formula>`, `npm run <script>`, or `make <target>`, Aster reads existing `.git/refs`, `.git/packed-refs`, `.git/config`, `package.json`, Makefiles, and Homebrew `Formula/`/`Cellar/` directories. It does not run the tool being completed: `brew install` completion does not trigger `brew update`, and `git checkout` completion does not execute git. Recent branches rank higher using `.git/logs/HEAD`. Data requiring tool execution, such as a `git status --short` staging list, falls back to file completion.

Homebrew 4.x uses its JSON API by default. Without a homebrew-core tap or API name cache, `brew install` can suggest only installed packages and third-party tap formulae, because completion does not fetch data or trigger `brew update`.

Scripts in `package.json`, Makefiles, or justfiles are not suggested as top-level commands; those files are read only when a specification requests that argument slot. To pin a project command, install the CLI in **Settings → Shell → Aster CLI**, then run in that directory:

```bash
aster learn 'npm run deploy'
```

When the argument is a bare binary name on PATH, `aster learn` instead runs its `--help` in a sandbox without network or file writes and parses subcommands/options into the local library:

```bash
aster learn ripgrep
```

These local specs are stored separately and survive built-in-spec **Update Now**. Repeating `aster learn` for a command increases its ranking weight. `aster ignore` reverses the three kinds of learning:

```bash
aster ignore ./old-project      # Stop tracking this frequent directory
aster ignore 'npm run deploy'   # Unpin this command
aster ignore ripgrep            # Remove this tool's locally learned help spec
```

Unpinning preserves ordinary execution history if you actually ran the command, but removes its pinned priority. Built-in CLI specs were not learned by you and are not removed by `aster ignore`.

**Local Learning** is on by default. It stores masked commands, directories, and counts, not output. Values for `--password`, `--token`, `--api-key`, and similar flags are removed. Only executed commands are learned; exit codes 126/127, explicit command-not-found output, clearly invalid long options, and History Ignore Patterns are excluded. Incomplete built-in structures may be probed with fixed `--help`, `-h`, or `help` arguments in a sandbox with no network/file writes, capped at 2.5 seconds and 128 KiB. Completeness considers options and arguments, not only subcommands: `docker` has 58 upstream subcommands but no top-level options. Probing chooses the deepest incomplete level, such as `docker compose --help` for the upstream `compose` placeholder. Results merge subcommands/options with the built-in fields instead of erasing its nested structure. Remote sessions do not read local project files or run local help probes. Disabling local learning disables history, pinned commands, README suggestions, corrections, and help probing; built-in specs and file completion remain.

**Ranking follows usage:** frequently used commands, subcommands, options, and arguments are remembered across directories. In a new directory, `cl` can still favor `claude`, and `git ch` your usual subcommand. Commands absent from built-in specs, such as `claude`/`codex`, and frequent argument values such as SSH hosts can complete anywhere. The previous successful command also informs ranking: frequent `git add` → `git commit` sequences favor commit after add. Failed preceding commands do not inform it. These rules adjust order, never execute commands, and reset with learning data.

Fig specifications do not update in the background. Control displays the count/version; use **Update Now** to refresh without replacing local help specs. Clearing history, pinned commands, and directory-frequency data does not delete built-in, manually updated, or help specs.

### Unicode, Bidirectional Text, and Terminal Images

- Aster supports combining characters, double-width CJK, emoji ZWJ/skin-tone/flag sequences, text/emoji variation selectors, 24-bit truecolor, 256 colors, and full SGR styling. Enclosed alphanumerics default to two columns; **Advanced** allows changing the East-Asian-Ambiguous blocks to widen. Width policy affects new tabs and subsequently written characters.
- **Appearance → Text** offers off, standard, or discretionary ligatures plus bold, italic, and blink rendering. Blink is steady by default and animates only when selected.
- Bidirectional text is on by default. Hebrew, Arabic, and mixed-direction lines display in reading order; copy, find, and paste use the program's logical order. Arrows and mouse hits follow visual positions. Disable it for full-screen TUIs that lay out RTL themselves. ECMA-48 mode 8 automatically suspends implicit reordering.
- Programs can display iTerm2, Kitty, and Sixel images. Input, chunks, decompression, pixel dimensions, and cache are bounded. Damaged, canceled, or oversized images are discarded without disrupting later output.
- The app bundles JetBrains Mono, Office Code Pro, and Symbols Nerd Font Mono as used by Otty 1.3.1, alongside Aster Nerd Symbols fallback. No separate installation is needed. BMP and supplementary-plane symbols remain available even when the base font lacks Powerline/Nerd icons.

### Progress, Badges, and Notifications

Programs can report percent, indeterminate progress, error, or completion via `OSC 9;4`. With Shell Integration, commands listed under **Advanced → Automatic Progress Commands** also show running state. Matching uses whitespace-separated prefixes: `git push` matches `git push origin main`, not `git pushd`. Empty the list to disable matching.

Tabs show running, just-completed, unread completion, error, and awaiting-input status beside their names. Agent processing/confirmation/resumption/completion changes update the icon without rebuilding terminals or interrupting input. Without lifecycle hooks, Claude Code/Codex spinners stop after about 5 seconds without input/output and restart when activity returns. With hooks, precise lifecycle state remains authoritative during quiet reasoning. Password, `[y/n]`, yes/no, or Press Enter prompts must remain for about 1.5 seconds before awaiting-input appears; any input clears it, including unread Agent-completion dots. Appearance can enable Dock animation. Red-on-error defaults to on; clicking the red Dock icon focuses the failed tab and acknowledges it. Acknowledged errors do not turn it red again; later app switching returns to your last tab.

With the CLI installed, wrap a one-off task or set the current tab's badge:

```bash
aster watch make deploy
aster watch -q cargo test
aster tab badge --kind awaiting-input
aster tab badge --clear
```

`watch` preserves the wrapped exit code. `-q` suppresses only this completion notification, not progress/badges.

OSC 9, OSC 777, and OSC 99 can send macOS notifications. OSC 99 supports separate title/body, urgency, base64, chunks, and replacement by ID. Shell settings independently control success/error/watch notifications, Shell Controlled behavior, foreground policy (always, unfocused tabs only, or off), Dock bounce, error-exit beep, BEL, and sounds for error/completion/app notifications. The permission row shows macOS's current state and opens system settings.

Title permissions are under **Advanced**: Shell Controlled allows OSC 0/1/2 title changes; title reporting allows programs to read titles and defaults to off. OSC 52 permissions and Secure Keyboard Entry remain under **Control**.

## Find and the Command Palette

`⌘F` searches the current terminal's full scrollback, with arrows for matches; Ghostty performs text, case-sensitive, and regex search. In a File Pane it instead searches that file as you type: `↩` next, `⇧↩` previous, Esc or another `⌘F` closes. Source shows match index/count and supports case/regex. Markdown/HTML previews, Agent transcripts, and PDF support find without regex; web previews indicate only whether a match exists. Images and binary files do not support find. **Find Globally** searches all terminal, editor, and preview Panes. Command Outline jumps with stable buffer anchors; entries whose pages were trimmed from scrollback become unavailable.

`⇧⌘O` opens **Open Quickly**. Categories filter All / Opened / Recent / Folders / SSH / Agents / Current / Recipes; `⌘J` opens Current directly. Fuzzy results include type icons, relative times, badges, and group headers. Results jump to Panes, open frequent directories, prefill SSH, resume Agent history, or open Recipes. Current also shows foreground commands and a Prompts group of recent input: a running Agent receives it in its Pane; without a running Agent, selecting a Prompt prefills the current terminal without Return. Use arrows, Return, or `⌘1`–`⌘9`. `⌘K` within Open Quickly or its Actions button opens result actions such as close tab, Fork, Reveal in Finder, or copy prompt. Hold `⌘` to reveal category shortcuts: `⌘0/W/R/Z/S/G/J/E` for All/Opened/Recent/Folders/SSH/Agents/Current/Recipes and row shortcuts for the first nine results. Release hides hints. Esc, switching apps, or any mouse click outside the overlay within Aster, including the title bar, closes it. The `⇧⌘P` command palette shares this style and includes new window, Pin, both Picture in Picture modes, details, Agent, splits, files, find, modes, and close, grouped by Pane/Window/Application scope. Common fixed shortcuts appear at the row end.

Open Quickly focuses search immediately; clicking it does not dismiss the overlay. Its Agent category is localized with the app. Opening/closing overlays and switching categories do not rebuild the terminal workspace; existing result rows are reused, including while typing with many results.

Esc closes the command palette, Open Quickly, global find, and Agent history even after clicking a result, button, session content, or background terminal. With no overlay, Esc goes to the terminal.

**View → Details Panel** has Info, Outline, Git, Files, and History icon tabs. Inactive tabs keep consistent icon widths/spacing with subtle hover backgrounds. The active tab expands to show its name, except with Reduce Motion. Its collapse icon stays visible while open; once closed, the same title-bar icon appears on hover. It briefly remains after closing, then fades if the pointer has left the title bar, without shifting or showing a second icon. View and the command palette also toggle the panel. Drag its divider for 240–480 pt width, double-click to reset 278 pt; dragging does not collapse it. Expansion/collapse uses a 0.18-second whole-panel transition (instant with Reduce Motion), clipping contents at the Panel boundary while central space fills. Terminal sizing changes once at the final visibility state. Toggles and page changes preserve terminals, sidebars, loaded pages, and input focus. Collapse cancels unfinished inspections while retaining completed results and Files search/sort/expansion state.

- **Info** shows working directory, copy/Finder/installed-editor actions, the local process tree rooted at the Shell, and deduplicated listening ports. Session copy/history/Branch actions appear only when lifecycle integration precisely binds the current Pane's provider/session. Visible Info refreshes about every 3 seconds. Non-terminal Panes and failed inspections show an explanation rather than pretending results are empty.
- **Outline** is a timeline: the upper area shows live running/successful/failed Shell commands with relative time (requires Shell Integration), click/context-menu Jump and copy; precisely bound Agent prompts; and structures for Markdown, HTML, JSON, YAML, TOML, Diff, and JSONL transcripts. Edits coalesce refreshes and entries jump to their lines. The lower area shows past project sessions when Session Recording is enabled: commands/exit codes, expandable output, Agent tools, file reads/writes, and git snapshots. Supplemental Agent-transcript entries are labeled separately from terminal observations.
- **History** shows project Memory with PINNED entries first, others newest first; each has a title, summary, and type/extraction-source/time subtitle. Search, pin, disable, and delete in the Memory browser opened from the header; manual refresh is available.
- **Git** shows branch, +/− totals, and changes grouped by staging state. Commit/editor controls share rounded primary-action/dropdown backgrounds with separate hover/press feedback. Commit offers Push/Pull/Fetch/Merge…/Rebase…; merge/rebase asks for a branch first. All prefill commands. The installed editor control (VS Code, Cursor, Xcode, Zed) opens the directory; choosing an editor from its dropdown saves that choice and immediately opens it. No detected editor means no button. Hover a change for stage/unstage, open-in-editor, and preview actions. Preview is a read-only diff bubble beside the panel pointing to that row; Esc, an outside click, or leaving Git closes it. **All repository write actions only prefill the terminal**, including Commit, staging, Push/Pull/Fetch, and Merge/Rebase. You execute with Return; Aster does not run writes in the background. Branches and paths use Shell escaping.
- **Files** shows a bounded CWD tree with muted accent icons and normal filenames. Directories start collapsed at the top level; chevron/double-click expands, and Find temporarily expands matching paths. Controls select directory-first sorting and whether hidden files are also included (off by default). Turning it on shows ordinary and hidden items such as `.gitignore`/`.build`, not hidden items alone. Hidden directory names are listed without expanding huge contents. Context actions are Open, Open in Aster with Pane/tab/window/four split targets, create/rename/Trash, copy paths, and Finder. **Both Git and Files require double-click to open files**; single clicks only browse. Git's row-end editor/preview buttons also work. Large trees render only visible rows, and search does not rebuild its field.

Info, Git, and Files load independently without waiting for each other. On `cd`, the old tree remains until new results smoothly replace it without taking terminal focus. Switching Panes similarly keeps existing Info/Outline/Git/Files until new results are ready. Old contents cannot be clicked during refresh; a short delay shows an updating hint at the upper right.

On collapse, only the right Panel animates; the central terminal goes directly to final width without another rendering-layer stretch or a final 1 pt divider jump. The same icon remains fixed throughout; after fully closing it waits 650 ms and fades only if the pointer left the title bar.

### Server Files and Server Monitor over SSH

After `ssh` to a server, details **Files** becomes server files and **Info** becomes server monitoring; other pages stay the same. `exit` restores local contents. Narrow panels omit secondary columns (process PID, port listening address, file modification time), restoring them when widened. Remote-machine terminals also support these pages without another authentication.

- **Server files** follow remote `cd`. Double-click a directory to enter and use `↑` in the path bar for its parent. Find, directory-first, and hidden-file controls match local behavior. At most 2,000 items display with a shown/total truncation note. Context actions include enter, prefill terminal `cd`, download, copy path/relative path, and upload here. Prefilled `cd '…'` requires your Return.
- **Upload/download**: drag local files into the list for the current directory or onto a directory row for that subfolder; upload is also in the context menu. Only regular files, up to 512 MiB each and 20 at once, are accepted. More than 5 files or over 50 MiB total asks for confirmation. Transfers write a temporary file and rename after success, leaving no partial file or `.aster-upload` on failure. Existing remote names ask before overwrite.
- **Remote integration** is needed for directory reports. Until one arrives, the page offers installation, Browse `$HOME`, or Enter Path. Installation first lists remote modifications for confirmation: typically `~/.config/aster/shell-integration.bash`/`.zsh` and a marked block in `~/.bashrc` or `${ZDOTDIR:-$HOME}/.zshrc`. fish writes `~/.config/fish/conf.d/aster.fish` without editing rc files. Reinstallation does not duplicate blocks. Log in again or run `exec $SHELL` remotely afterward. Temporarily disable with `ASTER_REMOTE_INTEGRATION_DISABLE=1`; remove the marked block and script to uninstall.
- **Server monitor** has Overview / Disk / Processes / Ports, one metric category at a time. Overview includes hostname/system, uptime, load/CPU, memory/swap. Disk lists up to 8 partitions, deduplicating a disk mounted at multiple paths. Processes shows process/CPU/memory, sortable by CPU or memory in either direction; select for PID, user, resource use, and full command line, then return to the list. Ports lists listening TCP/UDP. It refreshes every 3 seconds while visible; switching pages does not reconnect. CPU requires two samples, so initially shows `—`. Non-root limitations on other users' process names are explained in ports. Missing platform data, such as `/proc` on macOS servers, is labeled unavailable rather than zero.
- **Missing contents**: an authentication-required message means the established channel could not be reused. Enable **Settings → Shell → SSH Connection Reuse** and connect from a newly opened terminal; the switch affects future terminals only. Retry timeout/connection failures; for nonexistent directories use parent or Browse `$HOME`. This panel does not ask for passwords.
- **Limits**: server files browse/transfer only; double-click does not open remote files in Aster, and remote Git is unsupported. Download to edit locally or use a remote terminal editor.

## Recipes and Session Restore

The **View** menu saves the current tab as `.asterrecipe` or opens a Recipe. Recipes store tab/window scope, nested splits and ratios, Pane types, directories, files, optional commands, and content levels, not PIDs, tokens, or file descriptors. Each open creates new Pane identities, making repeated use possible. External Recipes must be size-limited regular files; referenced editing resources have a cumulative budget too.

External commands are fully listed for confirmation by default, including command 21 onward. **Settings → Recipes** offers never replay, one confirmation, confirmation per command, or trust only identical SHA-256 content. Trust follows contents, not paths; edits ask again. Per-command confirmation offers run/skip/stop immediately before sending each command. Commands send sequentially only after Shell Integration is ready at an idle prompt and the preceding command has a completion marker.

**Settings → Shell → Session Restore** controls what returns in each terminal after quitting and reopening Aster:

- **Restore tmux / screen Sessions**: if the foreground process was `tmux`/`screen` at snapshot, the first prompt runs `tmux attach -t <session>` or `screen -r <session>`, or attaches without arguments if the name cannot be parsed.
- **Restore Code Agent sessions**: Claude/Codex/OpenCode reconnect via native `--resume`, sharing the switch on the Agents page.
- **Latest project Agent session as first completion**: when an Agent such as Claude Code, Codex, or Grok Build exits, the window offers its resume command and remembers that directory's latest session. Any Pane in that directory gets the whole resume command as the empty-prompt inline suggestion and first pinned candidate; Tab accepts and Return runs it. Prefixes such as `cl` keep it first. Commands differ by provider: `claude --resume <id>`, `grok --resume <id>`, `codex resume <id>`, or `--session <id>` for OpenCode/Kimi/Pi. Only providers with native resume are recorded; each directory keeps one latest entry. Closing a running Agent's Pane/tab or quitting Aster also records it. Claude Code/Codex do not require hooks for this: their files in `~/.claude/projects/<encoded-directory>/` and `~/.codex/sessions/` bind a session ID during execution, enabling titles, Fork, and copy ID, and identify it at exit. If no new session file is created, for example by `claude --version`, but old sessions exist, completion falls back to `claude --continue` / `codex resume --last`. Nothing executes automatically.
- **Terminal restore protocol (OSC 88)**: a program can declare how it should restart. `printf '\e]88;query\a'` receives `\e]88;supported;v=1\a`; `printf '\e]88;restart=nvim .\a'` declares a command and `\e]88;clear\a` removes it. The declaration stores in the workspace snapshot and sends as ordinary input on restore; it is not evaluated as a separate script.
- **Restart running processes**: never, allowlist only, or all running processes. The comma-separated allowlist matches command prefixes, so `npm run` matches `npm run dev`.

Priority is OSC 88 declaration, then multiplexer, then ordinary process. Agent-bound Panes use only Agent reconnection. Restore commands send at the first Shell prompt; any earlier user input cancels them. Switches are read at send time, so changing settings does not require another quit.

`⇧⌘T` restores mistakenly closed Panes/tabs in recently closed order. This history survives normal exit and crashes. Normal exit restores the main window and still-open additional windows. After three consecutive crashes, Aster bypasses a potentially damaged snapshot and opens a clean Shell. Serializable layouts restore, but PIDs, file descriptors, and transient read-only state do not persist.

## CLI and Deep Links

Install `aster` in **Settings → Shell → Aster CLI**, then control the workspace from a Shell:

```bash
aster open ~/project --title API
aster view README.md --right
aster edit Sources/App.swift --new-window
aster jump project
aster learn ~/project
aster ignore ~/Downloads
aster pane capture --lines 100 --format json
aster pane send-text 'npm test\n'
aster pane run -- npm test
aster pane exec --format json -- git status --short
```

`open/view/edit/jump/learn/ignore/capture` are read-only or workspace actions. `pane send/run/exec` require **Settings → Control → IPC Allow Sending Input**; SSH/sudo and other sensitive sessions also require **IPC Allow Sensitive Sessions**. `aster://learn?...` handles only bounded directory-learning requests; `ssh://` only prefills, never automatically executes.

The installed `aster` symlinks to `aster-cli` inside Aster.app, preferably in `/usr/local/bin`, otherwise `~/.local/bin` when unwritable (ensure it is on PATH). Old sh-script installs are replaced. An unrelated existing `aster` is not overwritten; installation reports that conflict. The CLI uses a current-user-only local socket, normally `~/Library/Application Support/Aster/Control/aster.sock`, falling back to `$TMPDIR/aster-control.sock` if HOME makes the path too long. It listens on no network port. Aster terminals receive the actual `ASTER_SOCKET_PATH`. Set absolute `ASTER_CONTROL_SOCKET_PATH` before launching the app to change its listener; CLI `--socket <path>` or `ASTER_SOCKET_PATH` selects it explicitly. If Aster is not running, the CLI launches it in the background and waits up to 5 seconds, then exits 69 if still unable to connect. `aster --help` and `aster --version` show syntax and version.

Within Aster terminals, commands can inspect and control other Panes and Agents:

```bash
aster session snapshot                       # All windows / tabs / Panes
aster agent list                             # Running Agents and status
aster agent read w1:p2 --lines 40            # Read an Agent's screen
aster agent prompt w1:p2 "Run the tests" --wait  # Submit and wait for idle
aster pane read --current --source recent
aster pane send-text --pane w1:p3 'npm test' --enter
aster pane wait-output w1:p3 --match "passed" --timeout 60000
aster events subscribe --kind pane.agent_status_changed
aster notification show "Build complete" --body "All passed"
aster session terminals                      # Managed terminals and actual status
aster session detach --current               # Detach; background tasks continue
aster session end w1:p3                      # Terminate this managed terminal
```

### Remote TUI Client

Run the full terminal client in a remote SSH Shell with `aster-session` installed there:

```
aster-session ui <state-parent> <session-name>              # Interactive
aster-session ui <state-parent> <session-name> --observe    # Read-only observation
aster-session ui --remote <ssh-target> --session <name>     # Through SSH
aster-session ui --remote <ssh-target> --session <name> --observe  # Remote read-only
```

`--remote` SSHes from the local machine to run the remote TUI, without a manual `ssh` first. Targets are separated with `--` and remote commands use POSIX quoting to prevent Shell reinterpretation.

Shortcuts use a Ctrl+B prefix:

| Key | Action |
| --- | --- |
| Ctrl+B q / d | Detach; exit TUI while background tasks continue |
| Ctrl+B n | Next tab |
| Ctrl+B p | Previous tab |
| Ctrl+B o | Next Pane |
| Ctrl+B w | Next workspace |
| Ctrl+B c | New tab |
| Ctrl+B % | Horizontal split |
| Ctrl+B " | Vertical split |
| Ctrl+B x | Close current Pane |
| Ctrl+B Ctrl+B | Send literal Ctrl+B |
| Ctrl+B ? | Show help |

The bottom bar shows workspace > tab [Pane/total]. Below 40×20, the TUI uses a compact layout.

`session terminals/detach/end` applies only to **managed terminals** running in the background session service. Closing a window or quitting Aster detaches; tasks continue and reopening attaches to the same process. Only end terminates it. One Aster window can input to a terminal at a time: with two Aster instances, the later one shows detached; Reattach transfers control, leaving the first detached until it takes control back. New terminals from the packaged app default to the managed path with background `aster-session`. `ASTER_SESSION_BINARY` and `ASTER_SESSION_STATE_DIR` override binary/state locations. Unmigrated old unmanaged layouts stay as they were. Ordinary local terminals are unaffected; detach/end on an ordinary Pane errors without ending its Shell. **File** offers equivalent detach/end/manage-layout actions. A normal background-service replacement stops it and cold-restores. Experimental live handoff can transfer PTY ownership without terminating processes, but is not exposed in the UI.

Short IDs identify windows (`w1`), tabs (`w1:t2`), and Panes (`w1:p5`); Agent names or `--current` from `ASTER_PANE_ID` also work. `agent`, `events`, and `notification` require Aster terminals (`ASTER_ENV=1`) unless explicitly using `--allow-outside`. Writes share the `pane send/run/exec` IPC switches. `--json` returns raw results; errors print `{"code":"…","message":"…"}` to stderr and exit 1.

## Working with Agents

Aster supports Claude Code, Codex, OpenCode, Cursor CLI, Kimi Code, Pi, omp, and Grok Build. **Settings → Agents** shows each provider's icon and detected absolute CLI path, including `~/.local/bin`, Homebrew, and common Node version managers when launched from Finder/Dock. Installed/Off and the switch refer specifically to Aster-managed lifecycle integration, separately from CLI detection. Expand a provider to control its quick-launch visibility and structured launch command for wrappers, environment setup, or custom executables. Installation/uninstallation changes only Aster-marked hooks/plugins, preserving user configuration; restart the Agent afterward. Grok Build uses native `[[hooks.Event]]` entries in `~/.grok/config.toml`, independent of Claude Code. It requires Grok ≥ 1.0.25; older versions do not read config.toml hooks. User-level hooks need no `/hooks-trust` (that applies to project `.grok/hooks/`). Grok sessions do not yet appear in Agent history or Open Quickly.

- Lifecycle hooks normalize `processing / idle / awaiting-input` to the owning PTY, driving badges, completion/wait notifications, and prevention of sleep during processing. They do not read or save prompt bodies. Hooks first write `/dev/tty`; Claude Code 2.1.x hooks lack a controlling terminal, so they find the Pane device through the parent process chain without changing Claude configuration.
- The **Shell** menu follows Otty's structure: Rename Tab… and Set Tab Prefix… share a native dialog (prefix preselected for the latter), then Clear Screen (`⌘K`); CWD copy/Finder/Open In actions are disabled without reliable CWD; then Vi/Mark/Hint, read-only, and Composer; finally Git GUI-client plus Commit/Push/Pull/Fetch/Merge/Rebase actions (prefill only) and Notifications & Privileges leading to Shell settings. Open In/Git entries match the title capsule menu.
- The Shell menu's Agent submenu, such as Codex or Claude, follows the focused Pane and updates after split focus changes. Once opened, Fork stays bound to that workspace even if Settings or another window becomes foreground. Install lifecycle integration and restart the Agent to link sessions for copy ID, history, and Fork into four split directions, a new tab, or a new window. Submenu history is current-project only, using linked-session project first or Pane CWD before linkage. Use command-palette Agent History for all projects. On first loading a new Codex hook, run `/hooks` to review/trust Aster; the installer migrates old invalid top-level Aster `hooks` boolean configuration. Copy/Fork stay disabled without a trusted session ID.
- Agent history (project-scoped from the submenu, all projects from the palette) and Open Quickly search known providers' local records. Resume/Fork uses native provider commands; unsupported Fork explicitly fails. Return or Open creates a new tab named for the session, rendering its read-only transcript: your messages are light cards, replies use Markdown, and consecutive tools collapse into a summary such as `Claude · 30×Bash, 26×Edit`. The header shows title, session file, project, and Resume/Fork. Per-entry/total limits truncate long sessions with a note. Opening the same session again selects its existing tab.

### Menu-Bar AI Usage

This feature is **off by default**. Enable it in **Settings → Agents → AI Usage in the Menu Bar**, or use **View → Show AI Usage** / the same command-palette action, which also enables the switch. A macOS menu-bar icon shows Claude/Codex's used percentage for the 5-hour window, or weekly if unavailable. At 80% it warns and at 95% turns red; awaiting-input Agents add a red dot.

Click for an animated floating window beneath the icon. It can be moved/resized and remembers size, but opens under the icon each time on the current display/Space and remains in front after app switching. Moving away after an icon-open, even without entering the window, or leaving after entering waits about half a second then closes; quickly returning or resizing prevents dismissal. Menu/palette-opened windows do not auto-close before the pointer has visited. Click the icon or upper-left close control to dismiss.

The window has three pages:

- **Quota**: cards show accounts, tiers such as Max 20x/Pro, 5-hour/weekly/model-week usage, and reset time. Claude shares one app-wide request timeline: every 300 seconds with only the icon active, 90 while Claude runs. Codex starts `codex app-server` every 300 seconds for official limits; rollout files contain only the last session response, missing usage elsewhere, so they are fallback when the CLI is unavailable/too old. Cursor queries its official usage API with its own credentials for the billing-cycle proportion. Antigravity has no local quota cache and requires its running app's local service (`agy` stopped exposing it from 1.2.2); this path has **not been verified on a real machine** and may never show a card. Cursor/Antigravity depend on undocumented interfaces that may change; unavailable cards disappear without an error dialog. Other Agents do not store local subscription quotas and have no cards.
- **Token**: today/7 days/30 days/all totals for input, cache write/read, and output, ranked by Agent/project, with a project's past-year activity heatmap. Supported records include Claude Code, Codex, Pi, Grok Build, Gemini CLI, droid, OpenCode, and Hermes. droid lacks CWD and goes under Other; Cursor/Copilot/Qwen do not retain local token data. This reads only numbers, timestamps, and working directories from local session files, not conversation bodies; no network or currency conversion is used. Git worktrees combine under the main repository. The initial full scan may take a minute or two for several GB, with progress and resume after closing; later scans read additions only.
- **Sessions**: one card per running Agent across windows, showing awaiting-input/running/completed/idle and its Pane's whole process-tree CPU, memory, and process count. Waiting comes first; click to focus that Pane. Cards do not reorder while open, only on reopening.

The feature does not alter terminals. With the switch off it performs no work; with the floating window closed only a Claude quota request every 300 seconds remains. Token and process-usage scans run only while their corresponding page is open.

### Composer, Skills, and Context Sharing

- Composer supports multiline drafts, ordinary file attachments, pinned/floating presentation, and cancel. Sending uses bracketed paste and respects read-only and paste protection. Prompt Queue dispatches automatically only on hook `idle`; processing/awaiting-input queue only. Without hooks, send each item manually via its left icon.
- **Let Agents operate Aster:** the bundled skill (`aster --skill`) teaches Claude Code/Codex to read neighboring Panes, start/wait for another Agent, and send keys/notifications through `aster`. Install it from **Settings → Agents** into `~/.claude/skills/aster` or `~/.codex/skills/aster` with a version marker; upgrades show when it needs updating. Only Aster-marked directories are managed. Your own same-name skills or symlinks are not overwritten, and uninstall removes only Aster's copy. Prompt/text/focus writes require **IPC Allow Sending Input**; otherwise the Agent receives `write_not_allowed` and asks for manual operation. The skill applies only in Aster terminals (`ASTER_ENV=1`).
- Send to Chat accepts terminal selection, the visible transcript, or file context. It wraps content in `untrusted-context`, strips terminal controls, masks common keys, and enforces a 128 KiB total budget. Aster does not claim to identify every business secret; review before sending. The terminal confirmation panel prefills the target Agent as ordinary typing; you make the final submission.

## Project Memory (Session Memory)

Aster can record terminal work so the next Agent can query a project's past process without another explanation. It is **off by default**; enable **Session Memory Recording** under **Settings → Agents**.

- **Modes**: Off, Recording, and Incognito. Off/Incognito both write nothing; Incognito signals a temporary pause. Recording captures commands, exit codes, output excerpts, CWD, Agent state, and git branch/commit. Full command output is in separate files, with excerpts in the database. Empty sessions without commands or Agent participation are neither recorded nor listed in History.
- **Excluded directories/commands** are blocked at event creation, not recorded then deleted. Excluded-command output is excluded too. Common secrets are masked before writes using the Send to Chat rules. An always-active, nonremovable baseline excludes `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.password-store`, and commands `op`, `vault`, `pass`, `gpg`, `security`; your exclusions add to it.
- Data stays in `~/Library/Application Support/Aster/Memory/`, with directories `0700` and files `0600`. Settings can show usage, open the folder, or clear all records. Memory and diagnostics are independent, with distinct masking rules and no shared files.
- **Extraction** derives reusable conclusions (problem, root cause, failed attempts, solution) when a Shell exits or a tab/Pane closes. Sessions missed on app quit/crash are processed on next launch. Local rule-based extraction always runs without network. Optional CLI Agent extraction invokes your installed Agent CLI and **sends the session summary to that Agent's cloud service**. It is off by default, asks on first enable, and offers an exact outgoing-content preview. Unavailable CLI, timeout, or parse failure falls back to rules without losing recorded facts.
- **History**: Outline's lower area groups timelines by session, including commands/exit codes, expandable output, tools, file reads/writes, and git snapshots. Supplemental Agent-transcript entries are labeled separately. History gives extracted project Memory with pinned entries first and a browser-management entry.
- **Tasks and Memory management**: the palette (`⇧⌘P`) offers Browse Session Memory, create Task, assign current session to Task, and continue Task. Tasks can link multiple sessions across Agents. The Memory browser is a separate panel window that can remain open beside terminal work; closing returns focus naturally. Search, source backlinks, pin, disable, and delete are available. Disabled Memory is invisible to Agent retrieval.
- **Pin conclusions**: pinned architecture decisions/conventions always accompany project context, bypassing retrieval ranking.
- **Retention**: raw events/output older than 90 days are cleaned at session end. Extracted Memory and session summaries remain indefinitely.
- **Agent access log**: Context records show each MCP query's time, query, returned Memory count, and approximate tokens.

### Give Agents Access through MCP

The bundled local `aster-memory-mcp` server lets MCP-capable Agents query the same memory. It opens the database read-only and works even while Aster is not running.

Tools: `search_memory` (Memory/commands), `get_project_context` (overview, always pinned first), `get_session` (full timeline), `get_related_history` (files/keywords), `get_task` (details/list), and `get_recent_commands`.

Uninformative broad queries return empty instead of irrelevant material. If nothing matches the current project, search widens to other projects with explicit origin labels. Historical text has a non-instruction declaration and structural sanitization; instruction-shaped output is not executed as commands.

Registration is under **Settings → Agents → Project Memory MCP**, after recording/extraction choices:

- The current project comes from the active tab of the most recently active workspace window; MCP registration is per project.
- Claude Code writes the project's `.mcp.json`, managing only `aster-memory` and preserving other servers. Correct registration shows disabled Installed; stale paths offer repair, and Remove is available.
- Codex offers a copyable snippet. Aster does not edit `~/.codex/config.toml` for you.
- Permission, symlink, size, or JSON errors reading `.mcp.json` are shown with installation disabled, rather than pretending it is unregistered.

## Eleven Settings Categories

Settings uses one separate window, initially `700 × 460 pt`. The workspace stays fully visible at its existing size/content and terminals continue. While Settings is open, the main window can switch/create tabs and manipulate/split Panes. Drag the title bar to move it, or any edge to resize with minima 700×460 pt. Both dimensions are remembered, constrained to a smaller screen if necessary. Minimize is disabled; the red close button closes only Settings. The Dock context menu has no Open Settings entry and does not list this window as Aster Settings.

Aster's embedded web UI renders Settings with General, Shell, Control, Editor, Agents, Hosts, View, Appearance, Recipes, Shortcuts, and Advanced navigation. Search covers every category and jumps to the matching setting. Toggles, menus, text, colors, and sliders save immediately; invalid values show an explanation and revert to the actual value. The Settings web page itself does not network or open Otty/other-product pages. Update's Check Now and the completion database's Update Now ask Aster's native app to fetch data.

- **Advanced → Configuration File** opens `~/Library/Application Support/Aster/settings.json`; use reload after edits. Format version is 3, with older Aster JSON still importable.
- Windows text rendering is marked Windows. macOS preserves it for config round-trips but neither applies nor allows editing it.
- Click a shortcut keycap, then press the new combination. AppKit menu shortcuts update and persist across launches; Esc cancels recording.
- Recipes lists `.asterrecipe` files in `~/Library/Application Support/Aster/Recipes`, with Finder/folder actions.
- **Shell → Shell Integration → SSH Connection Reuse** defaults to on and also requires SSH integration. Aster-started terminals wrap `ssh` with OpenSSH ControlMaster options so server files/monitor can reuse authentication. These command-line options override your `ControlMaster`/`ControlPath` settings, but an existing user `ssh` function/alias is not replaced (the panel may then require authentication). Only newly created terminals are affected. Aster-managed blocks in `~/.zshrc`, `~/.bashrc`, `~/.bash_profile`, and `~/.config/fish/conf.d/aster-shell-integration.fish` load the wrapper, independently of tmux; disabling Shell Integration removes them.
- System-action failures, such as Shell/Agent integration, CLI installation, or config import, retain their actual error instead of showing a successful switch.
- **General → Language** offers System, Simplified Chinese, Traditional Chinese, English, Japanese, French, and German. System matches macOS preferred languages in order (`zh-TW` to Traditional Chinese, `en-GB` to English), falling back to English if none match. Restart Aster for a whole-interface language change. Terminal programs use their own Shell `LANG`, unaffected by this setting.

Navigation is fixed at 200 pt and reaches the window top. Widening fills the right column with responsive cards/controls rather than blank space. The neutral-gray search field does not autofocus; click it to search labels/descriptions across all eleven categories. Content starts at the top as group headings and rounded cards, with scrolling when needed. Switching categories changes only the right side; controls update in place, and Swift state snapshots preserve the selected category. Appearance's left/right Panel widths edit the most recently active workspace window.

- **General**: language, launch behavior, window close behavior, tab/window/Pane close-confirmation policy, system integrations (default `ssh://` terminal, common external apps' default terminal, Finder Open in Aster service, Full Disk Access), and updates (automatic checks, download/install, stable/preview, check now).
- **Shell**: working directories for windows/tabs/splits; Shell/SSH integration and connection reuse; Aster CLI installation, omitted prefix, command overrides, aliases; frequent folders with tracked/ignored management and Zoxide sync; restore for multiplexers, Code Agents, OSC protocol, and never/allowlist/all processes; bell/error beep; system notification permission, app/completion/error/watch notifications, foreground policy, sounds, and continuous Dock bounce until returning; terminal identity. `TERM=auto` prefers bundled `xterm-ghostty` matching the engine, falling back to `xterm-256color` if absent. Custom accepts an actually installed terminfo name. The arrangement follows Otty.
- **Control**: nine groups, following Otty: autocomplete, selection, scroll, Open In, link protocols, keyboard, mouse, secure input, clipboard. They include inline suggestions, Option/Meta, VT100 keypad, TUI mouse bypass, copy cleanup, paste protection, schemes/security exceptions, start/end scrolling, and secure-input status.
- **Editor**: wrap, line numbers, invisible characters, Tab width, scroll beyond end, Vim keys, and rich-document preview.
- **Agents**: eight providers including Grok Build, structured launch commands, install/uninstall integration, badges, menu-bar AI usage, notifications, and running options.
- **Hosts**: saved SSH hosts (see **SSH Hosts and Quick Connect**).
- **View**: four groups aligned with Otty. Tab/title rules organize by item (alias/icon/title lists) or project (all three together). Conditions for path, command, Agent, SSH host, file, etc. must all match; no condition means every tab. Rules set alias, colored built-in icon (61 choices) or emoji, and title templates. Variables include `${alias}`, `${cwd}`, `${folder}`, `${user}`, `${host}`, `${agent}`, `${branch}`, `${command}`, `${title}`, `${shell}`, `${index}`, `${file}`; `${title|folder|'Shell'}` takes the first nonempty value. Rule titles rank below fixed manual names but above auto titles. Tab icons/badges can share an indicator (status takes over) or separate left-icon/right-badge positions while hiding the Shell name, with completion/failure/awaiting-input switches. Web Panes can persist cookies for subsequently opened Panes and clear browsing data. Details Panel supports reorder/toggle for Info/Outline/Git/Files/Memory and Add View: a terminal program such as `lazydocker` with `${cwd}`/`${pid}` command/directory variables (empty directory uses `~/.config/aster/views/<name>`) or a web page, optionally requesting mobile content.
- **Appearance**: workspace Panel widths, tab position/autohide, window size, Dock task state, light/dark themes, theme edit/import, text style, fonts/fallbacks, cursor color/style/blink/animation.
- **Recipes**: replay and content-trust policies; confirm external commands according to the selected policy.
- **Shortcuts**: view built-ins and edit bindings as described above.
- **Advanced**: auto-progress commands, title write/read permissions, SSH engine (native `aster-ssh` or OpenSSH, after restart), JSON config import/export/reset, and runtime information.

Global settings save/export with configuration. Left/right Panel widths belong to individual workspace windows and are saved only with them, excluded from config import/export. Notifications also depend on macOS **System Settings → Notifications** permissions and banner style.

## Software Updates

Aster checks the official update feed **once daily in the background** by default, enabled on first launch without a prompt. Disable **Automatically Check for Updates** in **Settings → General → Update** if desired.

- **Automatically Check for Updates**: off leaves only manual Check Now.
- **Automatically Download and Install**: off by default. Enabling downloads silently and installs on app exit without interrupting terminals. It is not default because terminals may run long-lived commands.
- **Update Channel**: Stable receives releases; Preview receives earlier testing builds with greater risk of problems. Switching from Preview to Stable does not downgrade; the current preview remains until stable catches up.
- **Check Now**: equivalent to **Aster → Check for Updates…**. Its status dot is gray for not checked/checking, green for current, orange for an update, and red for failure.

Updates request only Aster's official feed. Downloads must pass Aster signature and macOS notarization checks before installation. Update checks send no usage data or system information.

If the whole group is disabled with an automatic-updates-unavailable explanation, this is a source-built development version without an update feed; download a release from the project's Releases page.

> Versions 0.4.1 and earlier have no updater. Download one newer DMG manually; subsequent updates can be automatic.

## Frequently Asked Questions

### Why Do Panels Become Narrower than Their Settings?

Aster preserves usable central space, temporarily shrinking the right panel and then the left when a window is too narrow. Saved widths stay intact and return on widening. Hide panels with tab-bar collapse or the details toggle, not divider dragging.

### Why Does `vim` or `top` Look Wrong?

Check **Settings → Shell → Terminal Identity → TERM** is `auto` (bundled `xterm-ghostty`, or an installed terminfo name), and allow mouse reporting under Control. Invalid custom names show a Pane startup warning and fall back to `xterm-256color`. For SSH hosts without `xterm-ghostty`, install that terminfo remotely or use `TERM=xterm-256color ssh …` temporarily.

### What Happens after `exit`?

The Pane closes like `⌘W`; Ctrl+D ending the Shell does too. A last Pane closes its tab, while the window retains at least one tab. `⇧⌘T` recovers an accidentally closed layout with a new Shell.

`exit` without arguments preserves the last command's status, so a nonzero status still closes. These abnormal cases instead keep the last view and show an end card:

- Nonzero Shell exit within 3 seconds of startup, often from broken Shell configuration.
- A signal-terminated Shell or abnormal PTY disconnection.
- Remote managed process exit: the end card offers restart Shell or close tab.
- With local background keep-alive, `exit` still closes normally; a card remains only if the service already reclaimed the terminal or is temporarily unavailable.

History outside the card remains selectable/copyable. Restart Shell creates a fresh PTY in the same Pane, not reuse of the dead channel. **Help → Report an Issue…** opens local logs for diagnosis.

### Do Recipes Execute Commands Automatically?

The Recipes replay policy decides. Default is command preview/confirmation; Never restores layout only. Trust applies to current SHA-256 contents and asks again after changes. Replay is sequential at idle prompts, not through an independent `/bin/sh`.

### Why Is AI Usage Missing a Percentage, or Sessions Empty?

Percentages are quota-based. Claude needs subscription login and Keychain permission (Aster uses Claude Code's stored login credentials for the official interface). Codex needs at least one local run. API-key users have no 5-hour/weekly quota and show only the icon. Sessions needs Aster's control channel: if two Aster instances run, the later one may fail to acquire it and show empty Sessions; Quota/Token are unaffected.

### Can Closing an Editor Lose Unsaved Content?

Closing a Pane/tab or quitting asks Save / Don't Save / Cancel for unsaved content. A failed save prevents closing.

## Appearance Themes

### Choose a Theme

**Settings → Appearance** has separate light/dark theme areas, four cards per row that grow with window width. Aster includes 9 light and 15 dark themes aligned with Otty 1.3.1. Selection updates the workspace and open terminals immediately without closing Settings, switches to the theme's light/dark appearance, and enables an independent dark theme when choosing dark.

**View → Theme** offers a searchable picker containing all 24 themes. Arrow keys or hovering preview the Tabs Sidebar, title bar, and Container holding central Panes and the Inspector. Click/Return saves and changes appearance; Esc, clicking outside, or switching apps cancels and restores the previous theme.

Glass Light/Dark retain actual theme transparency, using native macOS materials to show the desktop. Screenshot gray is the composited result, not a saved flat color. All splits update together. Floating Card, Nord, Pink, Monokai Classic, and other themes use their own cursor-text and selection colors rather than generic approximations. The nine light themes apply final detail values to Window, Container, Sidebar, tab bar/tabs, terminal, Inspector, cursor, selection, and ANSI colors. The Inspector and central Pane share one Container card without a second Sidebar material. Undefined light-theme selection defaults to terminal foreground at 30% opacity.

Dark themes also apply to Pane toolbars, find bars, Sidebar, and Inspector. Terminal-only themes such as Tokyo Night/Dracula derive a slightly lighter Sidebar from their background rather than one common black-gray. File Pane toolbars do not remain white.

### Edit Theme Colors

1. Select a card; light cards set the light theme and dark cards the dark one. Adjust fonts, cursor color, and opacity below; empty cursor color follows the theme. Import `.astertheme` or open the theme folder there. Settings itself follows system appearance, not terminal theme colors.
2. Details show a terminal sample, foreground/background, ANSI 16 colors, and Window/Panel/Tab/Cursor/Selection tokens. Click a color/token to open its editor at that field, or expand all parameters with the edit-theme action. `#RRGGBB` / `#RRGGBBAA` applies when leaving the field. Color/ANSI/theme-font edits keep the name/ID and append managed overrides to the original theme. Only explicit Duplicate creates a new theme.
3. **Restore Theme's Original Parameters** clears color/ANSI/font overrides without deleting the theme file. Mappable values sync to its managed-override section. Failure retains the in-app values and shows the actual error.

### Import Themes

**Import Theme…** accepts regular `.astertheme` files up to 256 KiB, not symlinks/FIFOs/devices, validating name and all ANSI 16 colors first. Open the theme folder at `~/.config/aster/themes` for built-in, edited, and imported text files. First launch copies 24 bundled themes there. Aster neither reads nor writes `~/.config/otty/themes`; `.astertheme` and `.ottytheme` stay independent.

### Text and Fonts

Text controls adjust size, bold, italic, underline, blink, ligatures, smoothing, and line height immediately in open terminals; menu font-size actions update immediately too. Line height changes grid height/space. In ordinary/GPU drawing, bar cursors use the actual font size, vertically centered in the cell, without extending into the previous line through font leading or sitting too low in Shell/Agent inputs. Old cursor pixels clear every frame so style changes/typing leave no cell trails.

Font Family has four scopes; enter a name directly or clear it to restore auto/inheritance. Install/open-font-folder actions are available:

- **Computed Value**: read-only actual regular/bold/italic/bold-italic resolved through Global → Theme → Fallback; system fonts are labeled system monospace.
- **Global**: takes priority over theme. An unset primary continues to use the theme. Automatic weight/style matching hides per-style pickers; turn it off for separate faces.
- **Theme**: overrides the current theme. The primary goes first in `font-mono` while preserving other candidates; style fonts use `font-mono-bold`, `font-mono-italic`, and `font-mono-bold-italic`. Built-ins retain name/ID without duplication. The full candidate stack remains editable.
- **Fallback**: fills missing characters with regular/bold/italic/bold-italic choices; unspecified styles inherit regular fallback. Aster Nerd Symbols keeps Powerline/Nerd icons visible. Ordered fallbacks follow the primary, with the system language's default CJK font appended (PingFang SC for Simplified Chinese), preventing symbol-dependent regional glyph changes. Set regular fallback to choose another CJK font.

With only a regular font and automatic matching, Aster finds styles in its family, falling back safely to regular if absent. JetBrains Mono 2.304 ships/registers at startup; no system installation is needed. Missing custom names remain in the field without rewriting, while rendering falls back to macOS Menlo Regular and Computed Value shows that result. Nerd-patched family names differ, such as `JetBrainsMono Nerd Font` versus `JetBrains Mono`; use the actual listed name.

### Cursor

Cursor controls include theme/custom color, text-under-cursor color, opacity, block/bar/underline/hollow-block shape, blink priority, and smooth animation, with live preview.

- Default Off/On sets initial blink; vim, Claude Code, Codex, and others can later request blink via DECSCUSR, but cannot override your chosen shape.
- Always Off/On fixes blink too and ignores program requests.

Agent output retains cursor shape but pauses blinking, restoring the chosen policy at awaiting-input/completion. Inactive Pane/window cursors also stop blinking without becoming hollow boxes. Smooth animation affects only short same-line movements and respects macOS Reduce Motion.

### Dock Icon

The card previews the app's Dock icon. **Spin While Task Is Running** rotates only the central star, leaving the rounded base and `>` still. Its continuing CPU/power cost makes it off by default. **Turn Red on Error** changes the base red with `!`; clicking focuses the failed tab and acknowledges it. Without red state/new errors, clicking just returns to the last tab. **Bounce on Notification** applies only when Aster is backgrounded and system permissions allow, continuing until you return. The three switches are independent.

## Quick Terminal

**Window → Quick Terminal** opens an independent terminal. Choose a global shortcut under **Settings → General → Quick Terminal**, such as Control + backtick or Control + Option + Space, to toggle from other apps. Aster must stay running; no global shortcut is claimed by default.

Choose top/bottom/left/right/center, size, margin, display, animation duration, hide-on-focus-loss, and following Spaces. Margin is screen-edge distance, default 12 pt; zero sits flush. The anchored edge is flush, with margin on the other two sides. Content has 20 pt inner padding.

Resize by dragging edges; width/height survive hide/show and restart. Changing position, size percentage, or margin in settings restores the percentage-based layout. The window cannot be moved by dragging; Position determines it.

First open uses the recent workspace directory; afterward it keeps its own Shell/CWD. Hiding or Command+W does not stop tasks; Escape still reaches the terminal. `exit`/Control+D hides it, with a fresh terminal on next open. An abnormal early Shell exit (signal or immediate nonzero configuration failure) retains the view; use **Window → Restart Quick Terminal**. Quitting Aster ends it; this temporary session does not restore next launch. For an occupied shortcut, choose another or use the Window menu.

## Remote Machines

Aster can use another machine, such as a Linux server or OrbStack VM, as a working machine. Terminals, tabs, and splits live in its background session service; quitting Aster, network loss, or reconnecting from another Mac leaves processes/layouts there.

- **Add** via **File → Add Machine…** or `+` in the lower-left machine switcher. Select a saved host or enter a target: `~/.ssh/config` alias, `user@host`, `ssh://user@host:port`, or OrbStack `root@ubuntu@orb`, then a named session (default `default`). The bundled SSH engine uses your ssh-agent, keys, and known_hosts. Passwords prompt when required; remembering in Keychain avoids repeated prompts.
- **Service**: the remote needs `aster-session`. If absent, adding offers installation from bundled app artifacts into `~/.local/share/aster`. For old versions, the machine context menu or **File → Update Remote Service…** lists terminals that will stop before replacement and preserves the old version for rollback. Platform, architecture, and digest are checked before uploading.
- **Switch** using the lower-left capsule or **File → Switch Machine**. Its dot is green online, yellow connecting, orange needing attention, or gray offline. Switching detaches the view while tasks run; return restores it.
- **Remote Agents**: connection detects remote Agent CLIs (`claude`, `codex`, `grok`, `gemini`, etc.) beside the machine row. After adding, Aster offers remote Agent integration so running/wait/completion appears in Sidebar/Dock as locally. The machine's New Agent submenu or **File → New Remote Agent…** opens that CLI in a remote tab, returning to a remote Shell on exit.
- **Workspaces**: a machine can hold multiple named workspaces, such as one per project. Choose it in **File → New Workspace…** and switch via the workspace list. Switching detaches views without stopping tasks. Closing a remote workspace terminates all its processes after showing terminal count and confirming.
- **Process exit**: an end card offers restart Shell (a new terminal on the server, using `--resume` for a Pane that ran an Agent) or close tab.
- **Files/monitoring**: remote Files/Info browse directories, upload/download, and show monitoring without new authentication. Directory reports still require remote Shell integration (see **Server Files and Server Monitor over SSH**).
- **Limits**: remote tabs cannot open local File Panes or treat local paths as remote. Image paste uploads as described under Copy and Paste. Remote editing, Git panels, and directory mounting are outside this feature; use remote git/editor commands. Port forwarding supports only static rules in host configuration, established on connection.

## Remote Session Restore

After service restart, each Pane shows one recovery path:

- **Continuing**: the background task survived and the view reconnects.
- **New Shell**: a new Shell was created after restart; the old process ended.
- **History Replay**: a stored disk screen snapshot, not live state; requires Screen History enabled.
- **Agent conversation restore**: the Agent CLI's `--resume` restores the conversation.
- **Restore Failed**: recovery failed and a new Shell replaced it; possible causes include damaged layout, full disk, or incompatible version.

A card at the Pane top explains the recovery type and details.

## SSH Hosts and Quick Connect

**Settings → Hosts** saves SSH hosts that can open directly as SSH tabs or become remote machines.

- **Defaults** at the top apply to all hosts. Empty host fields inherit defaults; empty defaults use port 22, automatic authentication, and 10-second connection timeout.
- **Fields**: name/group/host/port/user; auto/password/public-key/agent/keyboard-interactive authentication; private-key files, one per line with `~`, `%h`, `%r`. Jump host selects a saved host. Port forwarding takes local `-L`, remote `-R`, and SOCKS `-D` rules. Advanced includes ProxyCommand, SOCKS/HTTP proxy, keepalive, timeout, host-key checks, agent forwarding, specified keys only (`IdentitiesOnly`), and known_hosts files (one per line; blank uses `~/.ssh/known_hosts`; tools such as OrbStack have their own files).
- **Groups/search**: imported `~/.ssh/config` hosts first, your groups next, then ungrouped. Search filters name/host/user/port.
- **Import** supports Include and first-match semantics, updating only the imported group and preserving manual hosts. Unsupported options/Match blocks are not imported and are listed afterward. The edit action opens `~/.ssh/config` in the default editor.
- **Passwords** and key passphrases stay only in macOS Keychain, never files. They save only after successful login. A rejected stored password is deleted. Forget Password removes it, first listing other hosts sharing the same `user@host:port` credential.
- **Host keys**: the first connection shows a fingerprint; confirmation writes `~/.ssh/known_hosts`. Changed keys warn of possible impersonation and require typing `yes`. Background reconnection does not confirm for you.
- **Quick Connect**: `⌘⇧O`, then `⌘S` for SSH. Enter `user@host`, `user@host:2222`, or `[::1]:22` to connect, save, or add a machine. Saved hosts/machines/config aliases appear, frequent first.
- **Native SSH tab**: a host opens as an ordinary tab directly in the remote Shell, without a local Shell. It reconnects after app restart.
- **Save as Host…** in a local tab's context menu prefills an address after manually connecting with `ssh user@host`. Configure options such as `-i`/`-J` in host settings.
- **OpenSSH fallback**: select OpenSSH in **Settings → Advanced → SSH Engine**, then restart. Manually typed `ssh` always uses system OpenSSH regardless of this choice.

## Named Workspaces

A workspace is a set of tabs. A window can have several, such as one per project, and each can contain multiple tabs. Workspaces can also be remote.

- **Location**: the upper sidebar lists workspace names/tab counts and highlights the current one. The tab-section heading identifies its workspace.
- **Create**: workspace `+` or **File → New Workspace…** (`⌘⇧N`) starts a home-directory Shell. New tabs via `+`/`⌘T` belong to that workspace. The host picker chooses Local for the current window, an existing machine for remote, or a not-yet-added host/alias to add it first.
- **Switch**: sidebar, **File → Next Workspace** (`⌃⌘]`) / previous (`⌃⌘[`), or Open Quickly's Workspaces category. Terminals/Agents continue and notifications still arrive; clicking one switches to its workspace.
- **Top/bottom layouts**: the leftmost tab-bar button shows the workspace and offers switching/create/rename.
- **Rename**: double-click the sidebar workspace, its context menu, or **File → Rename Workspace…**.
- **Move tabs**: tab context-menu Move to Workspace.
- **Delete**: workspace context menu or **File → Delete Workspace…** closes its tabs, recoverable through Recently Closed. At least one workspace remains.
- **Old windows** formerly created by `⌘⇧N` can still reopen from the switcher after closing.
- **Remote** switching leaves tasks running; closing ends all processes after confirmation.
- **CLI**: `aster-cli workspace list`, `aster-cli workspace open <name>`, `aster-cli workspace new --name <name> [--machine <machine>]`.
