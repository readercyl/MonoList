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
