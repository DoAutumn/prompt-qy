# Claude Command Bar

[English](README.md) · **简体中文**

> 一个常驻菜单栏、始终置顶的输入助手：把选中文本、文件路径、截图汇集到一个悬浮编辑器里，一键发送到终端里正在运行的 Claude Code。

在终端用 Claude Code 时，经常要把「文件路径 / 选中的代码 / 报错信息 / 截图」喂给它——反复复制、切窗口、粘贴很打断心流。这个小工具把这些动作收敛到一个随手呼出的置顶编辑器里。

> ⚠️ 个人自用工具，非 Anthropic 官方产品。目前只对接 **Terminal.app**。

## 功能

- **菜单栏常驻**，无 Dock 图标（`LSUIElement`）
- **始终置顶的编辑器**：浮于任何 App 之上、跨 Space / 全屏可见，可拖拽移动、缩放，位置大小自动记忆
- **双击 Control 呼出**：若前台有选中文本，自动插入到光标处（先走辅助功能 API，取不到再回退合成 ⌘C）
- **拖文件进编辑器**：插入文件路径（含空格自动加引号）
- **双击 Option 插入 Finder 选中项**的路径
- **截图自动插路径**：⌘⇧4 截图后，把新截图路径插进编辑器
- **一键发送**：⌘↵ → 若有多个终端窗口，弹菜单按窗口标题选择 → 内容粘进 Claude 并回车、编辑器清空
- **历史记录**：发送过的内容存进菜单，点击可再次填入编辑器（保留条数可设）
- **可自定义**：呼出/插入的修饰键、历史条数、菜单标题宽度（菜单栏 → 设置…）

## 交互一览

| 操作 | 效果 |
|---|---|
| 双击 **Control** | 呼出编辑器；有选中文本则插入 |
| 双击 **Option** | 插入 Finder 当前选中文件的路径 |
| 拖文件到编辑器 | 插入其路径 |
| ⌘⇧4 截图 | 新截图路径插入编辑器 |
| **⌘↵** | 发送到终端（多个则弹选择菜单） |
| **Esc** | 隐藏编辑器 |
| ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z | 编辑器内标准编辑操作 |

每次插入的路径 / 选中文本后都会自动换行，多项各占一行。

## 安装

### 方式 A — 一行命令安装（推荐）

```bash
curl -L -o /tmp/claude-command-bar.zip \
  https://github.com/DoAutumn/claude-command-bar/releases/latest/download/Claude-Command-Bar.app.zip \
  && unzip -oq /tmp/claude-command-bar.zip -d /Applications/ \
  && xattr -dr com.apple.quarantine "/Applications/Claude Command Bar.app" \
  && rm /tmp/claude-command-bar.zip \
  && open "/Applications/Claude Command Bar.app"
```

它做的事：拉取最新 Release → 解压到 `/Applications/` → 清掉 quarantine 标记（App 未签名/未公证，绕过 Gatekeeper）→ 启动。

手动方式（不想跑脚本）：到 [Releases](https://github.com/DoAutumn/claude-command-bar/releases/latest) 下 `Claude-Command-Bar.app.zip`，解压拖进 `/Applications`，然后**右键 → 打开 → 在弹窗里再点一次「打开」**（仅一次）即可过 Gatekeeper。

### 方式 B — 从源码构建

依赖 Xcode 命令行工具（`swiftc`），无需 Xcode 工程。

```bash
git clone https://github.com/DoAutumn/claude-command-bar.git
cd claude-command-bar
./build_app.sh                                 # 产物：dist/Claude Command Bar.app

open "dist/Claude Command Bar.app"             # 首次运行
cp -R "dist/Claude Command Bar.app" /Applications/   # 安装到应用程序
```

本地构建的 App **没有 quarantine 标记**，Gatekeeper 不会拦。

## 关于权限

首次使用会弹窗请求（各授权一次即可）：

- **辅助功能**：全局键盘监听（双击呼出）、读取选中文本、合成按键
- **自动化**：控制 Finder 和 Terminal.app（枚举窗口、发送内容）
- **桌面文件夹**：监听截图保存目录

如果遇到「已授权但仍不生效」，通常是旧的失效授权残留，可以让系统重新索引 App、再重置该项授权，下次使用时会重新弹窗：

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Claude Command Bar.app"
tccutil reset AppleEvents io.github.claude-command-bar
```

## 文件说明

| 文件 | 作用 |
|---|---|
| `command_bar.swift` | 全部逻辑（单文件） |
| `build_app.sh` | 编译 + 打包 + 签名成 `.app` |
| `make_zip.sh` | 把构建好的 App 压成 Release 产物 |
| `generate_icon.swift` | 生成 App 图标 |
| `setup_signing.sh` | 可选的开发者辅助脚本（见下） |

> **需要反复重建？** `swiftc` 产出的 App 没有稳定代码签名，macOS 的隐私系统（TCC）在每次重建后都会重新要辅助功能/自动化授权。跑一次 `./setup_signing.sh` 会新建一个**独立钥匙串**（**不碰**你的登录钥匙串）里的自签名身份，`build_app.sh` 之后就用它签名，授权便能跨重建保留。**下载 Release 安装的普通用户完全不需要这一步。**

## License

[MIT](LICENSE)
