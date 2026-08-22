# 软件更新

## 背景与选型

0.5.0 之前 Aster 没有任何更新能力：用户只能自己去 GitHub Release 页面查看新版、下载 DMG 再手动拖进 Applications。`docs/developer/settings-web.md` 早期版本明确把「自动更新」排除在设置清单之外，是对齐 Otty 时的有意取舍。

现在改用 **Sparkle 2**（macOS 生态的事实标准）承担完整链路：后台检查 → 下载 → 安装 → 重启。选它而不是自研的核心理由是「替换正在运行的自己」这一步：需要一个独立助手进程在主程序退出后原子替换 app bundle，并处理权限、回滚与签名校验。Sparkle 的 `Autoupdate` 与 `Updater.app` 正是为此存在，自研等于重写它最难的部分。

界面用 `SPUStandardUpdaterController` 的代码构造器 `init(startingUpdater:updaterDelegate:userDriverDelegate:)`——这是官方 programmatic setup 的正式 API，不是 Interface Builder 专用。手搭 `SPUUpdater` + `SPUStandardUserDriver` 只会把同一套标准 UI 手动拼回去，还得自己处理 host bundle 配对与 `startUpdater` 的错误路径，净损失。

## 领域边界

- `Sources/AsterCore/SoftwareUpdate.swift`：`UpdateChannel` 与 `SoftwareUpdateStatus`。纯领域，无 AppKit、无 Sparkle。**不实现版本比较**——那是 Sparkle `SUStandardVersionComparator` 的职责，自己写一份只会造出第二个真值。
- `Sources/Aster/SoftwareUpdateService.swift`：**全仓库唯一 `import Sparkle` 的文件**。持有 updater controller、充当它的两个 delegate，把 Sparkle 的一串回调折叠成单个 `SoftwareUpdateStatus` 并经 `.softwareUpdateStatusDidChange` 广播。
- `SoftwareUpdateControlling` 协议：设置页与菜单看到的全部能力面。`SettingsViewController` 与 `AsterAppDelegate` 都不 `import Sparkle`，测试用 stub 即可在不联网、不打包成 `.app` 的前提下驱动全部接线。
- `SoftwareUpdateService.shared` 只在 `Bundle.main` 是 `.app`、`SUFeedURL` 是 https、`SUPublicEDKey` 非空时构造。开发构建返回 nil，设置页走 `capability=false` 的禁用态，不假装可用。

## 真值归属

这是最容易被后来者改错的一处，`SettingsResponsivenessTests` 里有专门的回归锁。

| 设置项 | 真值位置 | 理由 |
| --- | --- | --- |
| 自动检查更新 | Sparkle 的 `UserDefaults`（`SUEnableAutomaticChecks`） | Sparkle 自带的更新对话框里也有这个勾选框，其内部排班与 `Autoupdate` 助手进程都直接读它。若让 `AsterConfiguration` 当真值再单向同步，用户在 Sparkle 对话框里改一下就永久分叉。设置页只做透传读写，**不存副本**，漂移在构造上不可能发生。 |
| 自动下载并安装 | Sparkle 的 `UserDefaults`（`SUAutomaticallyUpdate`） | 同上。 |
| 更新通道 | `AppPreferences` 独立键 `aster.update.channel.v1` | Sparkle 自己不持久化通道，只在每次检查时问 `allowedChannels(for:)`。放独立键而不是 `AsterConfiguration`：通道属于「这台机器上的这次安装」，不该随导出的 `settings.json` 把同事也拽上预览分支（与 Session Memory 同样的隔离理由）。 |

三者都**不进** `SettingsWebBridge.compatibilityDefaults`：那个字典的定义是「尚未进入强类型运行时配置的 **Otty 兼容**字段」，Otty 没有更新通道，塞进去会让 `resetAll`、导入导出与 allowlist 校验的语义全部走味。

代价是非打包构建里两个开关无值可读。这由既有的 capability 机制处理（`capabilities.softwareUpdate`），而不是补一份影子存储。

## 通道

- `stable` 映射为**空集合**而不是 `["stable"]`。Sparkle 的默认通道不是一个名字：未标记 `<sparkle:channel>` 的条目永远落在默认通道上。写成 `["stable"]` 会让所有正式版对稳定用户直接消失。
- `preview` 映射为 `["preview"]`，**仍然包含默认通道**。Sparkle 在设计上不允许 updater 把自己排除出默认通道，这正是「预览分支最终被稳定版本追上并收敛回去」的预期语义，也保证预览用户能收到稳定分支的紧急修复。
- 切换通道不需要向 Sparkle 推送任何状态（`allowedChannels(for:)` 是每次检查现问的），只调 `resetUpdateCycle()` 让排班重来。切到 `preview` 时额外做一次 `checkForUpdateInformation()` 静默探测刷新状态点。
- **切回 `stable` 不做立即检查**：Sparkle 永远不提供比当前更旧的版本，立刻查只会返回一条误导性的「已是最新」，而用户此刻装的其实仍是预览版。
- **已知限制：preview → stable 不降级。** 用户会停留在预览版上，直到稳定分支的版本号超过它。

## 启动时序与权限对话框

`softwareUpdateController?.start()` 放在 `applicationDidFinishLaunching` 的**末尾、`NSApp.activate` 之前**，必须排在 `showMainWindow()` 与 `restoreAdditionalWorkspaceWindows()` 之后。Sparkle 起来后会按排班安排一次后台检查，首次检查可能立刻弹出更新窗口；排在前面会让更新窗口抢在工作区恢复完成之前成为 key window，用户开机看到的第一眼是更新框而不是终端。

**不要**手动调用 `checkForUpdatesInBackground()`。Sparkle 按 `SUScheduledCheckInterval` 自己排班，手动调用会绕过它的节流逻辑，官方文档明确不建议。

首次运行的「是否允许自动检查更新」对话框**双保险抑制**：

1. `Info.plist` 显式声明 `SUEnableAutomaticChecks = true`（Sparkle 文档：显式设置此键即绕过询问）。它只提供**默认值**——用户在设置页关掉后写入的 `UserDefaults` 仍然优先，语义正确。
2. `SPUUpdaterDelegate.updaterShouldPromptForPermissionToCheck(forUpdates:)` 返回 `false`，保证即使 `Info.plist` 被漏配也不会冒出一个我们控制不了的对话框。

两个都要。允许 Sparkle 自己问，等于让「自动检查更新」这个设置有两个写入入口，正是真值归属一节要避免的漂移源。

代价：**首次启动就默认开启自动检查，用户没有被问过。** 这是「全自动更新」这个产品决策的直接后果，已在 `docs/user/help.md` 的「软件更新」一节明说并给出关闭路径。

前台时的排班更新走 gentle reminder：`standardUserDriverShouldHandleShowingScheduledUpdate` 在 `NSApp.isActive` 时返回 `false`，只刷新设置页状态点，不抢焦点。终端用户很可能正盯着一条跑了十分钟的命令。

## 网络与隐私

这是 Aster 第二个会主动发起网络请求的组件（第一个是 `AutocompleteService.updateNow()`）。

- 只请求 `Info.plist` 里固定的 appcast，不接受运行时改写（但保留 `defaults write` 覆盖通道用于测试，见下）。
- 更新包经 EdDSA 签名与 Apple 代码签名双重校验后才安装。
- **不启用 `SUSendProfileInfo`**，不上报系统画像或任何使用数据。
- 设置页网页本身的 CSP 是 `connect-src 'none'`，更新检查全部由原生侧发起，网页只展示状态。

## 打包与逐层签名

Sparkle 以 **dynamic XCFramework** 分发，与静态的 `GhosttyKit` 完全不同。SwiftPM 在非 Xcode 构建下只在链接期提供 `-F/-framework`，既不嵌入 framework，也不写 `LC_RPATH`：

- `Package.swift` 手写 `-rpath @executable_path/../Frameworks`。缺它打好的 `.app` 会在 dyld 阶段直接崩。
- `build-app.sh` 探测 `$BUILD_DIR/artifacts/**/Sparkle.xcframework` 并 `ditto` 复制到 `Contents/Frameworks`。用 `ditto` 而非 `cp -R`：framework 内含符号链接（`Versions/Current` 以及顶层的 `Sparkle`/`Resources`/`XPCServices`），codesign 对 framework 的密封依赖这套标准 Versions 布局。
- 路径不写死。SwiftPM 的 artifacts 布局历史上变过一次，脚本改为探测 + 五项结构校验，缺任何一项即失败，绝不打出一个「没有更新器」的分发包。

**签名必须逐层、由内向外，不能用 `--deep`**：

```
Versions/B/XPCServices/Installer.xpc
Versions/B/XPCServices/Downloader.xpc   ← 唯一需要 --preserve-metadata=entitlements
Versions/B/Autoupdate
Versions/B/Updater.app
Sparkle.framework
Contents/MacOS/aster-memory-mcp
Aster.app                                ← 最后，不加 --deep
```

四个原因：

1. Sparkle 出厂时 XPC services、`Autoupdate`、`Updater.app` 都是 **ad-hoc 签名**，不重签，公证必被拒。
2. Hardened Runtime 会开启 **Library Validation**：主程序被 Developer ID 签名后，dyld 只允许加载同 Team ID 或 Apple 签名的动态库，ad-hoc 的 `Sparkle.framework` 会在**启动时**被拒绝加载，App 直接崩。
3. `--deep` 用同一套参数覆盖所有嵌套项，会**吃掉 `Downloader.xpc` 的 entitlements`**。Sparkle 文档点名这是常见错误源。
4. 顺序不可颠倒：codesign 把子项的 CDHash 密封进父层签名，先签外层会在签完内层的瞬间失效。

**连带影响**：`Contents/MacOS/` 在 codesign 的默认封存规则（`CodeResources` 的 `rules2`）里是 nested 目录，主可执行文件之外的二进制不会被外层签名覆盖。`aster-memory-mcp` 此前是靠 `--deep` 顺带签上的，去掉后必须显式补签，否则 `codesign --verify --deep --strict` 与公证都会失败。

**ad-hoc 分支刻意不加 `--options runtime`**。开启 hardened runtime 等同开启 Library Validation，而 ad-hoc 签名没有 Team ID，dyld 会拒绝加载同为 ad-hoc 的 `Sparkle.framework`。这是必须刻意维持的性质，不要「顺手统一」两个分支。

非沙箱应用其实不需要 XPC Services，删掉可省约 1.5MB 并少两层签名。这里选择保留：与上游文档命令逐条对齐，将来若要沙箱化零改动。

## EdDSA 密钥

私钥存在**登录钥匙串**（service `https://sparkle-project.org`，account `ed25519`），公钥写在 `Resources/Info.plist` 的 `SUPublicEDKey`。

```zsh
SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_keys"                 # 首次生成；已有则打印现有公钥
"$SPARKLE_BIN/generate_keys" -p              # 只打印公钥（脚本用，release.sh 靠它比对）
"$SPARKLE_BIN/generate_keys" -x ~/aster.key  # 导出私钥备份
"$SPARKLE_BIN/generate_keys" -f ~/aster.key  # 在另一台机器导入
```

- 导出文件的内容**等价于私钥本身**。存 1Password 或离线加密盘，绝不进仓库、绝不进 CI 明文环境变量。`.gitignore` 已忽略 `*.sparkle.key`。
- 钥匙串或系统被抹掉即丢失密钥。但**还有救**：`SUUpdateValidator` 的策略是「EdDSA 签名有效 **或** 新旧 Apple 代码签名一致」二选一，可以发一个换新 EdDSA key 的版本走密钥轮换恢复。前提是**不能同时**更换 Developer ID 证书和 EdDSA key。
- 上 CI 时不要用已废弃的 `-s`（新格式密钥不支持），用 stdin：`echo "$KEY" | generate_appcast --ed-key-file - …`。

## 发版

用 `scripts/release.sh`：

```zsh
ASTER_SIGN_IDENTITY="Developer ID Application: …" ASTER_NOTARY_PROFILE=aster-notary \
  ./scripts/release.sh --short 0.5.0 --bundle 10
# 非交互环境无法写入钥匙串 profile 时，改用 App Store Connect API Key：
ASTER_SIGN_IDENTITY="Developer ID Application: …" \
  ASTER_NOTARY_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8" \
  ASTER_NOTARY_KEY_ID=XXXXXXXXXX ASTER_NOTARY_ISSUER=<issuer-uuid> \
  ./scripts/release.sh --short 0.5.0 --bundle 10
# 预览版：
  ./scripts/release.sh --short 0.5.0-preview.1 --bundle 8 --preview
```

它承担五个「顺序错了就出事」的不变量，详见脚本头部注释。其中**唯一不可逆**的是 `CFBundleVersion` 单调递增：Sparkle 用 `sparkle:version`（即 `CFBundleVersion`）判定有没有新版本，`generate_appcast` 拿它当 appcast item 的主键，重复值直接报错，而发出去的版本号收不回来。脚本阶段 0 的 `MAX_IN_FEED` 校验是唯一防线。

版本号策略：`CFBundleVersion` 用**跨通道共享的全局单调整数**，`CFBundleShortVersionString` 承载语义。

| CFBundleVersion | ShortVersion | 通道 | tag |
| --- | --- | --- | --- |
| 7 | `0.4.2` | stable | `v0.4.2` |
| 8 | `0.5.0-preview.1` | preview | `v0.5.0-preview.1`（prerelease） |
| 9 | `0.5.0` | stable | `v0.5.0` |

不把 `-preview.1` 塞进 `CFBundleVersion`：Apple 规定它只能是不超过三段的数字点分串，带后缀会让 codesign、LaunchServices 与公证的行为不确定。

Sparkle 2 原生支持 DMG，直接复用现有的 `build-dmg.sh` 产物，不需要额外打 zip。

**一次性迁移断层**：v0.4.1（`CFBundleVersion=6`）的存量用户机器上没有 Sparkle，永远收不到自动更新，必须手动下载一次带 Sparkle 的版本。README 与首个带更新功能版本的 release notes 都要写明这一点。

## 验证

离线部分（不需要真实 appcast，全部由 stub 驱动）：

```zsh
./scripts/test.sh --no-parallel --filter "SoftwareUpdate|settingsBridgeRoutesUpdateSettings|settingsSnapshotExposesUpdate|settingsUpdateAction|settingsUpdateSectionMatchesBridge|applicationMenuContainsCheckForUpdates|checkForUpdatesMenu|infoPlistDeclaresSparkle|updateServiceIsUnavailable"
node --check Resources/settings-ui/settings.js
```

必须走 `scripts/test.sh` 而不是裸 `swift test`：xctest 宿主不在 `.app` 布局里，`@executable_path/../Frameworks` 指向不存在的目录，脚本负责注入 `DYLD_FRAMEWORK_PATH`（SwiftPM 对动态 binaryTarget 的已知缺口，swiftlang/swift-package-manager#4514）。

构建后静态验证（`build-app.sh` 已内建前两项）：

```zsh
codesign --verify --deep --strict --verbose=2 dist/Aster.app   # --deep 用于校验是正确用法
otool -l dist/Aster.app/Contents/MacOS/Aster | grep -A2 LC_RPATH
otool -L dist/Aster.app/Contents/MacOS/Aster | grep Sparkle    # 期望 @rpath/Sparkle.framework/Versions/B/Sparkle
```

另外有两道**免费的强校验**：`build-app.sh` 末尾的 `--verify-packaged-resources` 会真实运行打包后的可执行文件，rpath 写错或 framework 没拷进去就在 dyld 加载阶段崩；`generate_appcast` 内部会对解出来的 App 跑 `codesign --verify --deep`，漏签任何一层都会报 `No usable archives found`。

端到端「更新真的能装上」：用 `defaults write io.local.aster-terminal SUFeedURL <https URL>` 覆盖 feed，零代码改动（Sparkle 2 仍读 host `UserDefaults` 里的 `SUFeedURL`，其源码中的警告文案就明说这是给测试用的）。造一对高版本号的包（如 `CFBundleVersion` 100/101），都用 Developer ID 签名并公证，**从 DMG 装到 `/Applications`** 再测——Sparkle 的安装器要原子替换目标位置，从 `dist/` 或只读挂载卷启动测不出真实的权限与路径行为。

**不要用 `file://` 或 `http://` 做测试 feed**：`SPUUpdater` 对非 https feed 会走 ATS 检查并被拦，而 Aster 的 `Info.plist` 里没有 `NSAppTransportSecurity` 例外。用一个临时分支上的 raw.githubusercontent URL 最省事。

日志：

```zsh
log stream --level debug --predicate 'subsystem == "org.sparkle-project.Sparkle"'
log show --last 10m --predicate 'process IN {"Aster","Autoupdate","Updater"}'
```

**ad-hoc debug 构建能测到哪一步**：能加载 framework（前提是 ad-hoc 分支不加 `--options runtime`），也能完成安装——`SUUpdateValidator` 要求的是「EdDSA 一致 **或** 代码签名一致」，不是「新旧签名必须一致」。但测不到 Gatekeeper、公证票据、hardened runtime 下 `Updater.app` 与 `Autoupdate` 的启动，以及 Library Validation。分工：ad-hoc 快速迭代链接、rpath、菜单、设置页与通道逻辑；两个真正公证过的包做发布前的最终端到端验收。
