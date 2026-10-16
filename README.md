# Fcitx5 + Ori + 雾凇拼音

为 **Fedora 44（DNF 版）＋ niri 25.11 及以上**准备的一行安装脚本。

默认组合：**Fcitx5 → fcitx5-rime → 雾凇全拼 → Ori 深色皮肤**。

## 一行安装

在 Fedora 的终端中以普通桌面用户执行：

```bash
bash -c 'f=$(mktemp) || exit; trap '\''rm -f "$f"'\'' EXIT; curl -fsSL --retry 3 https://raw.githubusercontent.com/kinsanka/fcitx5-ori-ice/main/install.sh -o "$f" && bash "$f"'
```

脚本先完整下载到临时文件再运行，退出时删除临时文件。安装系统依赖时会请求 sudo 密码；**不要在整条命令前加 sudo**。需要能访问 GitHub、GitHub codeload 和 Fedora 软件仓库。

**完成后注销并重新登录 niri**。用 `Ctrl+Space` 切换输入法；已有自定义快捷键时沿用原设置。Rime 内的 `Shift` 和 `F4` 行为沿用雾凇配置。

当前是联网安装器，不是离线安装包。初次部署词库可能需要几分钟。

## 浅色、跟随系统、双拼

安装命令中最后的 `bash "$f"` 可以加参数。例如 Ori 浅色＋小鹤双拼：

```bash
bash -c 'f=$(mktemp) || exit; trap '\''rm -f "$f"'\'' EXIT; curl -fsSL --retry 3 https://raw.githubusercontent.com/kinsanka/fcitx5-ori-ice/main/install.sh -o "$f" && bash "$f" --theme light --schema double_pinyin_flypy'
```

也可以先下载，便于查看脚本和多次运行：

```bash
curl -fsSLO https://raw.githubusercontent.com/kinsanka/fcitx5-ori-ice/main/install.sh
bash install.sh --theme auto
```

`--theme` 支持 `dark`、`light`、`auto`。`auto` 依赖桌面 portal 提供深浅色偏好；niri 本身不会自动设置该偏好。

| `--schema` | 方案 |
| --- | --- |
| `rime_ice` | 雾凇全拼，默认 |
| `double_pinyin_flypy` | 小鹤双拼 |
| `double_pinyin` | 自然码双拼 |
| `double_pinyin_mspy` | 微软双拼 |
| `double_pinyin_sogou` | 搜狗双拼 |
| `double_pinyin_abc` | 智能 ABC 双拼 |
| `double_pinyin_ziguang` | 紫光双拼 |
| `double_pinyin_jiajia` | 拼音加加双拼 |

每次安装只启用指定的一个方案。再次执行会更新上游管理的资源并应用本次参数；无参数时仍是深色＋全拼。

## 脚本会做什么

- 使用 DNF 安装 `fcitx5`、`fcitx5-rime`、图形配置工具、GTK 3/4 和 Qt 5/6 输入模块、`librime-lua`、`librime-tools` 等依赖。**雾凇需要的是 `librime-lua`，不是 `fcitx5-lua`。**
- 从固定上游 commit 下载雾凇和 Ori，并检查 SHA-256。项目维护者更新版本和校验值后，重新下载本安装器即可更新资源。
- 正常退出当前用户的 Fcitx5 后，备份 Rime 数据、Fcitx5 profile、皮肤设置、niri 主配置和本包管理的环境配置。
- 保留用户词库、同步数据、`*.custom.yaml` 和已有 `custom_phrase.txt`；更新上游方案、词库、Lua 等同名资源。直接修改上游同名文件的内容会被更新覆盖，请使用 Rime 的 custom 补丁。
- 合并 `default.custom.yaml` 的其他补丁，仅设置 `schema_list`；在 `user.yaml` 中记住所选方案。重写这两个 YAML 文件会改变格式并移除注释，原文件保留在备份中。
- 保留已有 Fcitx5 分组，添加或更新 `Ori Ice` 分组并置于首位；使用原有键盘布局（无记录时为 `us`）。profile 的注释和格式会被重写。
- 在 niri 主配置末尾添加一个带标记的 `include`，加载独立片段。重复安装不会重复添加标记或分组。
- 原生 Wayland GTK 不全局强制 `GTK_IM_MODULE=fcitx`。为 Qt、XWayland 设置相应变量，并在每次 niri 登录时向 systemd/D-Bus 传递输入法变量，覆盖 DMS 等启动器的后续应用启动。
- 验证 niri 配置，并用 `rime_deployer` 编译词库。配置或部署失败时自动尝试恢复本次安装前的配置，DNF 已安装的软件包保留。

默认遵守 `XDG_CONFIG_HOME`、`XDG_DATA_HOME` 和 `XDG_STATE_HOME`。使用其他 niri 主配置时，在执行前设置 `NIRI_CONFIG` 为**实际绝对路径**。当前不自动改写符号链接管理的配置目录，检测到会报出路径并停止；请先处理 dotfiles 中的链接布局。

**Rime 词库、OpenCC（含 Emoji）和编译产物统一放在 `${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/rime`**，与原生 fcitx5-rime 的读取目录一致。旧版误写入 `~/.config/fcitx5/rime` 的个人配置会在再次安装时补入正确目录；同名冲突保留正确目录中的现有文件，已有用户数据库不会混合拼接，旧目录保留并纳入备份。

安装器不会自动终止 IBus，也不会删除原有自启动项。如果原来配置了自动重启 Fcitx5 的 systemd 服务，请先停止该服务，避免备份/部署时进程被重新拉起。

## 检查、备份与恢复

下载 `install.sh` 后：

```bash
bash install.sh --check
bash install.sh --restore latest
# 或用安装时打印的准确备份名：
bash install.sh --restore 20261016-123456-AbCdEf
```

备份在 `${XDG_STATE_HOME:-$HOME/.local/state}/fcitx5-ori-ice/backups/`。恢复时也会先备份当前状态，因此可以再次恢复。`latest` 指最近一次完整备份，反复使用可能在两份状态之间切换。恢复到旧备份会把本包管理的配置和 Rime 数据恢复到那个时间点；期间新增的个人词库数据也会被恢复前备份保存。软件包不卸载。

新版备份同时记录正确的数据目录和旧目录。修复前生成的旧版备份仍可恢复，但仅恢复其清单中的原路径，不会覆盖当时未备份的新数据目录。

部署日志为相应备份目录中的 `deploy.log`。`--check` 检查依赖、niri 语法、主题和词库产物；它不等于在真实应用中完成打字测试。

## Chromium、Electron 和其他应用

如果原生 Wayland Chromium/Electron 应用没有中文输入，可以尝试为**那个应用**增加参数：

```text
--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3
```

参数是否可用取决于应用内置 Chromium/Electron 版本。脚本不批量改写所有应用的启动文件。

旧 GTK/XWayland 应用需要时可以单独启动：

```bash
env GTK_IM_MODULE=fcitx your-app
```

Flatpak 的输入模块/权限、应用自己的启动参数以及原有 IBus/Fcitx5 自启动冲突需按应用排查。可用 `fcitx5-diagnose` 获取进一步信息。

systemd 启动器在会话初期已经启动的子进程不会因环境同步而改变；重新登录后再打开应用。如果登录配置稍后再次设置输入法变量，需要移除那个冲突来源。

## 验证

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
bash tests/smoke.sh
```

Python 配置测试需要 PyYAML；完整 smoke 测试还需要 `python3-gobject-base` 和 `dbus-daemon`。GitHub Actions 在 Fedora 44 容器中检查 ShellCheck、配置保留和恢复、niri 解析、全拼/小鹤方案的实际词库编译，并在隔离 D-Bus 会话中启动原生 Fcitx5，验证“开心、苹果、爱心”的 Emoji 候选。测试不会连接现有桌面的输入法；容器检查不覆盖真实 niri 桌面里的候选窗位置、皮肤显示及每个应用的输入行为。

## 上游与许可

本仓库的安装脚本采用 [MIT](LICENSE)。上游文件从原仓库下载，分别遵守各自许可；本仓库不重新声明其许可：

- [Fcitx5](https://github.com/fcitx/fcitx5) 和 [fcitx5-rime](https://github.com/fcitx/fcitx5-rime)
- [Ori-fcitx5](https://github.com/Reverier-Xu/Ori-fcitx5)：MPL-2.0，作者 Reverier-Xu
- [雾凇拼音](https://github.com/iDvel/rime-ice)：GPL-3.0，作者 iDvel 及贡献者

参考：[Fcitx5 Wayland 指南](https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland)、[niri 配置 include](https://github.com/niri-wm/niri/wiki/Configuration:-Include)、[Fedora Fcitx5](https://fedoraproject.org/wiki/I18N/Fcitx5)。
