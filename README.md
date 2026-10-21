# MonoList 一栏

MonoList 是一款常驻 macOS 菜单栏的轻量待办工具。

## 开发环境

- macOS 14 或更高版本
- Apple Command Line Tools
- Swift 6

无需安装完整 Xcode。

直接执行 `build-local.sh` 生成的是可点击测试的 `MonoList 开发版`，与
`/Applications/MonoList.app` 正式版使用不同应用身份。正式版安装包由
`package-dmg.sh` 显式使用 release 构建身份生成。开发版版本号通过
`MONOLIST_DEV_VERSION` 和 `MONOLIST_DEV_BUILD` 独立维护。

## 本地构建

```bash
bash scripts/build-local.sh
bash scripts/check-app-launch.sh
open "build/local/MonoList 开发版.app"
```

构建产物统一存放在：

```text
build/
├── local/MonoList 开发版.app
└── release/MonoList-vX.Y.Z.dmg
```

发布后执行 `scripts/cleanup-build.sh`，自动删除测试 App、测试产物和 DMG
暂存目录，只保留 `build/release` 中的正式安装包。`build/release` 默认至少保留
最新版 DMG；清理时不得删除整个 `build/`。只有已经核对 GitHub Release 存在
同版本资产且明确决定不再保留本地副本时，才可删除正式安装包。

## 验证

```bash
bash scripts/check-release-preflight.sh
bash scripts/build-local.sh
bash scripts/check-app-launch.sh
```

`check-release-preflight.sh` 会并行运行独立的源码与 Smoke 检查，并在失败时汇总
对应日志。`release.sh` 会在创建 tag 和 GitHub Release 前调用它；正式打包脚本
负责发布 App 的签名检查和最终 DMG 的校验，避免同一资产重复验证。

## 功能

- Dock 与菜单栏同时常驻
- 新增待办按 Enter 保存并自动继续下一行，点击空白处保存并结束输入
- 双击清单空白处新增待办；编辑已有待办按 Enter 保存并在下方新增
- 前三条一级待办自动使用从大到小的字号，后续任务使用正常字号；二级待办保持层级缩进
- 长列表新增待办时会自动滚动并聚焦到正在输入的行
- 双击编辑、整行拖动排序、单条删除
- 当天完成任务保留在底部，较早记录可显示或隐藏
- 30 / 60 / 90 / 120 分钟轻提醒，默认关闭提醒声音，也可选择系统声音
- 单条待办支持 10 分钟递增的倒计时、未来七天指定日期时间和每日提醒
- 轻提醒与单条提醒可选择 macOS 系统声音，并可在设置时试听
- 菜单栏显示全部未完成任务数量
- 可选开机启动与轻提醒测试
- GitHub Release 每日检测并自动更新，也可关闭自动更新或手动检测升级

任务、历史记录和设置仅保存在：

```text
~/Library/Application Support/MonoList/
```

除版本检测和下载安装包外，MonoList 不会主动联网。

## 发布说明

正式版本使用固定的 `MonoList Local Signing` 本地签名，不使用 Apple
Developer ID、不进行 Apple 公证，也不上架 App Store。首次运行时 macOS
可能显示 Gatekeeper 提示。

构建发布包：

```bash
MONOLIST_APP_VERSION=vX.Y.Z bash scripts/package-dmg.sh
```

## 产品物料

设计与商品详情页资料已移至开发区产品容器的[产品物料说明](../产品物料/物料说明.md)。App 源码、测试和构建脚本仍保留在本代码仓库。

## AI 智能体调用：CLI

CLI 与界面通过同一个运行中的 MonoList 实例操作任务，不内置模型、API 密钥或对话框。
设置中的“AI 智能体接入”提供复制接入说明、查看命令与示例、检测接口状态；复制内容自动使用当前 App 的路径与版本身份。用户可直接将说明粘贴给支持本机命令的智能体。
先打开对应 App。开发候选在仓库中用 `/bin/bash scripts/monolist help` 查看命令；
安装包内的入口是 `MonoList.app/Contents/MacOS/monolist-cli`，不用额外安装依赖或注册全局命令。
正式版与开发版的 CLI 分别连接各自的 App；此功能尚需随版本发布才会进入正式版。

除 `help` 外，所有响应都是 JSON：成功为 `{"ok":true,"result":...}`，退出码 0；
失败为 `{"ok":false,"error":"..."}`，退出码 1。JSON 参数从标准输入读取，最大 1 MiB。
日期使用 ISO 8601，任务 ID 使用 UUID。CLI 不自动启动 App，也不直接读写任务文件。

```bash
/bin/bash scripts/monolist list
/bin/bash scripts/monolist status
/bin/bash scripts/monolist settings.get
```

`list` 返回 `result.revision` 和全部任务（`status` 为 `pending` 或 `history`），含父子关系、
顺序和提醒；智能体按状态筛选即可。所有任务写入使用 `apply`，必须带刚读取的 revision：

```json
{
  "expectedRevision": "从 list 的 result.revision 取得",
  "operations": [
    {"kind": "add", "id": "11111111-1111-4111-8111-111111111111", "text": "准备项目材料"},
    {"kind": "add", "parentID": "11111111-1111-4111-8111-111111111111", "text": "整理参考资料"}
  ]
}
```

将上述 JSON 通过标准输入交给 `monolist apply`。新增任务可由调用方提供 UUID，后续操作
可在同批引用；未提供时由软件生成。每批 1–500 个操作，一次校验、一次保存，任何一步
失败都不发布部分结果；期间清单发生变化会返回 `conflict`，必须重新读取并判断，不能自动
覆盖新内容。界面正在编辑已有任务时返回 `editor_busy`。现有任务文本会随 CLI 更新同步刷新。

| 任务操作 kind | 参数与语义 |
| --- | --- |
| `add` | `text`；可选 `id`、`parentID`、`afterID`（在该任务之后插入） |
| `edit` | `id`、`text`，沿用原任务其他属性 |
| `complete` / `restore` | `id`；完成可选 `text`。沿用界面的父子级联规则 |
| `delete` | `id`；整个请求另需 `confirm:true`，沿用父子删除规则 |
| `clear.pending` / `clear.history` / `clear.all` | 请求另需 `confirm:true` |
| `indent` / `outdent` | `id`，缩进为前一主任务的子任务／提升为主任务 |
| `parent` | `id`、`parentID`（null 提升为主任务），只支持现有两级层次 |
| `move` | `id`、`offset`（上移 -1，下移 1）；或 `id`、`beforeID`、`parentID`，null 落点表示末尾 |
| `reorder` | `ids`，必须恰好包含全部未完成任务，保留既有父子关系 |
| `reminder` | `id`、`reminder`；null 清除提醒 |

一次提醒格式：`{"kind":"once","date":"2026-12-01T09:00:00+08:00","minuteOfDay":0}`。
倒计时由调用方换算为一次提醒日期。每日提醒格式：
`{"kind":"daily","minuteOfDay":540,"recurrenceID":"新生成的 UUID"}`。

其他现有功能的入口如下，`help` 同样可以发现这些命令：

| 命令 | 输入 / 行为 |
| --- | --- |
| `settings.get` | 返回设置和独立的设置 revision |
| `settings.set` | `expectedRevision`、`values` 局部字段；支持轻提醒开关、间隔、时段、位置、声音开关与声音名称、自动更新开关，值域与界面相同 |
| `login.set` | `enabled`、`confirm:true`；开机启动沿用系统权限规则，开发版拒绝修改 |
| `view.get` / `view.set` | 读取 / 修改 `collapsedIDs`、`homeHistory`、`panelHistory`；收起任务状态保留，历史显示状态只在当前会话内生效 |
| `window.home` / `window.settings` / `window.panel` / `window.hide` | 显示主页、设置、菜单栏浮窗／隐藏窗口 |
| `reminder.test` / `reminder.close` | 与界面的测试提醒、关闭提醒相同 |
| `update.check` / `update.status` | 发起异步检查／读取检查和安装状态；`accepted` 只表示已受理 |
| `update.install` | `confirm:true`，仅安装已检查到的更新；开发版禁止安装 |
| `data.retry-load` | `confirm:true`，仅在读取失败时重试加载 |
| `data.retry-save` | 重试保存当前内存数据 |
| `app.quit` | `confirm:true`；存在进行中的任务编辑时拒绝退出 |

本机通信不开放网络端口。通信超时返回 `result_unknown`，表示调用方不能确定操作是否完成，
必须先读回状态再决定是否重试；不可盲目重发新增、删除等请求。请避免把任务响应自动写入公开日志。
任务写入前保留同目录 `tasks.cli-backup.json`，设置写入前保留 `settings.cli-backup.json`，
各保留最近一次写入前的状态。恢复前退出对应 App，将备份复制覆盖同目录对应的 `tasks.json`
或 `settings.json`，再启动 App；任务备份恢复路径已用隔离数据验证。

验证入口：

```bash
/bin/bash scripts/check-task-cli.sh
/bin/bash scripts/build-local.sh
env -u PYTHONPATH /usr/bin/python3 Tests/cli_integration.py
```

集成检查仅使用开发版支持的 `MONOLIST_CLI_TEST_DIRECTORY` 隔离目录与独立通信名称，
不操作正式任务、不启动菜单栏服务、不改开机启动注册。实际系统授权、在线下载升级不在该测试中执行。
鼠标悬停、双击、拖动等界面手势不另设命令，由对应读取、编辑、移动、排序和窗口命令覆盖其结果。
