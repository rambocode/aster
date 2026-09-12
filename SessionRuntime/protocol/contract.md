# 生产操作协议合同 v1

状态：契约与编解码基础已建立，实际 handler 按操作目录所列阶段实现。P0 probe 不自动成为生产 API，不能因为 schema 接受请求就执行未实现的方法。

## 单一来源与验证

- `scripts/build-protocol.py` 是操作/类型定义来源，生成 `operations.schema.json`、`events.schema.json`、`stream.schema.json`、目录、样例及 Swift/Zig 操作元数据。
- 修改定义后运行生成器；CI 用 `--check` 拒绝陈旧生成文件。
- `scripts/setup-protocol-tests.sh` 仅在隔离 `.build/schema-env` 安装锁定的测试依赖；`scripts/test-protocol.sh` 使用 Draft 2020-12 验证器。产品运行时不依赖 Python 或 schema 测试包。
- schema 校验结构；`validateEnvelope` 校验身份格式、范围和条件字段；实际 handler 继续校验目标归属、权限、能力、租约、修订号、资源和状态。前两者都不能代替授权。

## 请求范围

- `bootstrap` 只处理已安装运行时的准备入口。`server.prepare.allowStart=false` 禁止启动服务；安装/替换不由后台连接隐式执行。
- `registry` 访问当前 SSH 用户的命名会话注册表。停止/删除通过明确 sessionID 定位；删除活动会话失败。
- `session` 必须携带 serverID、serverEpoch、sessionID，服务逐项与当前实例核对。禁止按显示名、PID 或客户端当前选中项补全目标。
- requestID、clientID、资源 ID 使用规范小写 UUID。requestID 是幂等身份，不是身份认证凭据。
- 结构变更必须携带 expectedRevision；输入/尺寸/滚动必须携带 lease 与 controlSequence。上述 64 位值独立解析，禁止经过 Double 类型的动态 JSON 容器。
- `terminal.attach` 的 takeover=true 必须提交 params.expectedLeaseEpoch，空闲初始为 0，此后保留最后代数；CAS 不匹配返回 lease_lost，占用时普通申请返回 lease_busy。
- `terminal.observe` 的只读结果必须返回 `currentLeaseEpoch: UInt64`，初始空闲为 0，释放或过期后保留最后代数；不返回 lease token，也不申请或续租。客户端把该观察值作为显式接管的 `expectedLeaseEpoch`，冲突后重新观察。
- 持久操作必须携带 createdAtUnixMs，重试保持该时间，未来时间拒绝，24 小时有效期从此字段计算；范围以 operations.json durable=true 为准。非持久操作禁止此字段。
- `terminal.attach` 返回可写 attachment 和 lease；`terminal.observe` 只返回只读 attachment，不返回写租约。`terminal.release` 只分离，`terminal.terminate` 才结束进程。

## 控制与画面连接

- 控制连接承担 RPC、状态事件和健康检查；画面连接绑定一个 attachment/terminal，避免大画面阻塞其他控制请求。
- `surface.subscribe` 的 geometry 是画面投影请求，不能绕过租约去调整 PTY。真正的 PTY resize 必须通过 `terminal.control`。
- 画面连接在绑定后使用既有 snapshot/delta 事务格式；一条连接同时最多一个未完成事务，binary chunk 属于当前事务。
- 事件携带独立 eventID、target、sequence 和 revision。eventID 在不同连接间用于去重，sequence 属于当前控制流且连续；revision 不得回退。连接代次改变或序列失配时重新同步；未知事件不能被当成已应用的业务变更。

## 参数与资源校验

- 动态 params 必须是对象；字段按对应操作 schema 校验。扩展元数据限制在 extensions，不把未知字段解释成命令或权限。
- argv/environment 禁止 NUL，执行目录在执行机器验证。工具定位使用远端 PATH/绝对路径，不经过拼接 Shell 重新解释。
- base64 必须严格解码，再核对真实字节长度；JSON Schema 的 contentEncoding 仅是格式声明，不能代替解码。输入最多 65536 字节，上传块最多 262144 字节。
- geometry 除字段类型外，还需校验像素宽高同时缺省/同时有效，以及像素值不小于行列数量。
- 布局除递归深度 schema 外，还需验证总 pane 数、ID 唯一性、引用存在性和资源所有权。
- 新资源/结构操作登记幂等意图与结果；结果不确定时返回 outcome_unknown，调用方先查询，不能自动重复启动命令。

## 结果与失败

- 成功响应回显 requestID、operation、scope；session 响应同时返回 target 和 revision。客户端必须与在途请求及当前连接身份匹配。
- 错误使用独立 error 信封，包含 code、脱敏 message 和 retry。未识别错误码按不可自动重试处理，不根据自然语言消息执行动作。
- 错误响应可省略尚未通过鉴权的 target，避免泄露其他会话状态。
- server.replace/handoff 的版本来自已验证受管安装，不接受任意可执行路径。替换许可和影响说明由明确的设置/更新流程提供。

## 本机机器配置

machine add/list/rename/enable/disable/remove 属于客户端配置 API，P4 接入既有 AsterControl 协议；不要把它们发送到某台远端会话服务。配置只保存不透明 ID、标签、SSH 目标、命名会话和 enabled，成功准备后才保存，移除只断开连接。

## P1 当前控制处理器

`service_control.zig` 提供 health.check / server.status / server.stop，并分派终端与画面领域。
实际服务握手声明 health_check、server_lifecycle、terminal_control、terminal_observe、surface_interest。
有效请求必须匹配当前 serverID、serverEpoch、sessionID；不匹配返回
stale_server_epoch 并要求重连。未实现能力返回 missing_capability，不以空结果伪装成功。
健康查询 params 必须为空对象，回复携带关联请求身份和当前 revision。

处理器对输入施加控制帧大小、64 层 JSON 深度及最高 4 MiB 临时解析空间限制。非法 JSON
或信封使连接失败；业务错误使用固定脱敏消息和既定 retry 枚举。控制上下文不负责传输鉴权，
连接层必须先验证同用户 peer，再发送 Hello 或调用处理器。后台循环、终端管理 CLI 和独立画面连接已接入，流式客户端仍在完成验收。

## P1 当前连接层

service_connection.zig 接管已认证的非阻塞 socket，在任何业务回复之前发送 Hello。每次 tick
限制读取 16 KiB、写出 64 KiB；控制连接积压上限为两个最大控制帧及帧头，独立画面连接为 8 MiB。超限或协议错误只使该连接
失败。失败连接必须关闭，不能重新继续解析。写半关闭后先排空回复，再报告 finished。

发送逐次使用 MSG_NOSIGNAL，不能以全局忽略信号作为安全前置条件。连接自身只持有 socket、
解码缓冲和发送队列，控制上下文按调用借用。服务循环仍须限制总连接数、空闲期限和全局预算，
并在每轮公平调度所有连接与 PTY；这些规则尚未由连接模块单独实现。

## 当前前台服务

`aster-session server serve <private-parent> <name>` 已将控制连接接入常驻循环。调度层最多维护
64 个连接，每轮接入最多 8 个新连接；默认空闲 30 秒、单帧 5 秒，接收零星字节不重置单帧期限。
等待集合包含监听器、连接和信号管道，停止信号不会被一分钟的空闲 poll 延迟。

该入口只声明 health_check，不托管用户终端，不派生后台进程。全局精确内存预算与 PTY 公平
调度仍在 P1 后续实现；前台进程端到端测试不能替代最终 daemon 保活和 A04–A07 验收。

## 当前 status CLI

server status 通过私有 socket 查询当前实例，不能从 PID 或磁盘文件推断服务运行成功。
Hello 与响应共用 3 秒期限，所有回复都核对请求关联及目标身份。允许未知可选字段，但必需字段
不能缺失，result/error 必须互斥；状态能力按集合与 Hello 一致。

成功时 stdout 为已校验的 response JSON；已校验的服务端 error 保留 RPC 信封并返回非零退出码。
本地连接/校验失败使用独立 client_error JSON，不能冒充有 requestID 的服务端错误。status 不创建
状态目录，也不因失败自动启动或结束任何进程。

## 当前后台启动 CLI

server start 派生独立进程并关闭无关继承 FD；只有收到私有 ready 且真实 status 的 epoch 与本次
父进程生成的 epoch 一致，才报告 started。重复启动不能重置现有服务，必须验证后报告 already_running。
未知结果只允许后续查询，不按 PID 自动结束进程，不把启动超时解释成服务已停止。

stdout 的 server_start 包含状态、诊断 PID 和已校验 status；PID 不是权限或资源身份。后台标准流
指向 /dev/null，前台 serve 用于诊断初始化失败。server stop 和终端生命周期仍在 P1 后续接入。

## P1 当前实例停止

操作目录新增 server.stop（session / server_lifecycle / P1），共 54 项操作。请求必须带当前
serverID、serverEpoch、sessionID，params 为空。验证通过且回复可编码后才进入 stopping；重复
stop 返回同样的接受状态，其它新操作返回 service_stopping。排空阶段不继续读取请求，最长尝试
250ms 发送已有回复，再关闭连接和实例资源。

CLI stop 将 stopping 与 stopped 分开：等待原连接 EOF，并确认锁已释放，或通过已鉴权 status
确认不同 epoch；后者只说明原实例结束，绝不能再向替代实例发停止请求。假确认、无效确认、超时
或不可验证状态返回错误；不重试 mutation，也不按 PID 发送信号。当前服务仍不托管用户终端，
PTY 结束/回收须在 P1 后续接入这一生命周期。

### 定向事件序号

事件 sequence 在当前连接可见的事件流内从 1 连续递增。定向 lease.revoked 不消耗其他连接的序号；只有成功入队才推进该连接计数。新连接建立后重置本地事件游标，并按所订阅资源重新获取快照；不得沿用上一连接的 afterSequence。序号溢出或输出失败关闭对应连接，不重置旧连接的计数。
