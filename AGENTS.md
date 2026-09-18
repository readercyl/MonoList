# MonoList 项目规则

## 本地版本身份与保留边界

- `/Applications/MonoList.app` 是本机唯一正式版入口，只保留当前最新正式版本。
- 默认执行 `scripts/build-local.sh` 只生成代码仓库内的 `build/local/MonoList 开发版.app`。
- 开发版版本号由 `MONOLIST_DEV_VERSION` 和 `MONOLIST_DEV_BUILD` 独立维护，不能沿用或覆盖正式版版本号。
- 开发版必须使用独立显示名称 `MonoList 开发版`、独立 Bundle ID
  `com.qingcheng.monolist.dev` 和独立菜单栏服务 Bundle ID，不得复用正式版身份。
- 开发版可以在开发完成后由青城点击测试，但不得复制到 `/Applications`，不得被当作正式版启动。
- 正式打包必须显式使用 `MONOLIST_BUILD_FLAVOR=release`，生成正式 Bundle ID
  `com.qingcheng.monolist.mac` 和正式安装包。
- 本地最多保留一个开发测试 App 和一个最新正式安装包；旧的可再生候选包在新候选确认后移入废纸篓或按用户要求清理。
- 开发版不执行自动升级，不得替换或覆盖 `/Applications/MonoList.app`。
- 开发版复用正式版的任务、设置、专注和提醒数据；系统级开机启动状态由正式版保留和管理，开发版不得注册或注销该权限。
- 若历史开发版曾经注册过启动项，开发版首次启动只允许注销自己的遗留注册，不得触碰正式版启动项。
- 收尾时验证正式 App、开发 App、Bundle ID、显示名称和 LaunchServices 登记状态，不能只看构建是否成功。
