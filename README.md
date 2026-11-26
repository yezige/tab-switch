# TabSwitch

一款极简、零截屏、低占用的 macOS 应用切换工具（纯原生 Swift / AppKit 实现，无第三方依赖）。

专为 **外接键盘（如 Logitech K380 等）** 在 macOS 上互换 `Control ↔ Command` 后，依然想顺手使用 `Alt + Tab` 切换应用的场景打造。

## 为什么做 TabSwitch？

- **几乎 0% CPU 占用**：不抓取窗口缩略图、不使用录屏接口，不会像带预览图的应用切换器那样在切画面时拉高 CPU 和 `WindowServer`。
- **支持按物理键盘精准过滤**：通过 `IOKit HID` 自动识别已连接的键盘，可指定仅对某块外接键盘生效（例如 `Keyboard K380`），完全不影响 MacBook 自带键盘的快捷键。
- **原生体验**：
  - 极简纯图标切换条（自动显示在鼠标所在屏幕中央，适配多屏）
  - 支持 `Tab` / `Shift + Tab` / 左右方向键切换，`Q` 退出应用，`H` 隐藏应用，`Esc` 取消
  - 使用 macOS 13+ 官方 `SMAppService` 管理开机自启，与「系统设置 → 通用 → 登录项与扩展」双向同步

## 系统要求

- macOS 13.0+（Universal Binary，同时支持 Apple Silicon 与 Intel）

## 下载与构建

- **直接下载**：前往 GitHub **Releases** 页面下载 `TabSwitch.dmg`，将 `TabSwitch.app` 拖入 `/Applications` 即可。
- **自动构建（GitHub Actions）**：推送 `v*` 标签（如 `git tag v1.0.0 && git push origin v1.0.0`）或在 Actions 页面手动触发，会自动编译通用二进制并发布 `TabSwitch.dmg` 到 Release。

## 使用说明

### 1. 前置配置（Windows 键位习惯，如 Logitech K380）

如果你习惯用左下角 `Ctrl + C / V` 复制粘贴、空格旁 `Alt + Tab` 切换应用，先在 macOS 系统设置里只针对该外接键盘互换修饰键：

打开 **系统设置 → 键盘 → 键盘快捷键 → 修饰键**：
- **选择键盘**：选中你的外接键盘（例如 `Keyboard K380`）
- **Control (^) 键** → 改为 **`⌘ Command 键`**
- **Option (⌥) 键** → 保持 **`⌥ Option 键`**
- **Command (⌘) 键** → 改为 **`^ Control 键`**

> 这样左下角物理 `Ctrl` 键就可以直接 `Ctrl+C / Ctrl+V / Ctrl+W`，而空格旁物理 `Alt (⌘)` 键变成 `Control`，配合 TabSwitch 的 `Control + Tab` 热键即可实现完整的 Windows `Alt + Tab` 切换体验。

### 2. 安装与配置 TabSwitch

1. 将 `TabSwitch.app` 拖入 `/Applications` 并打开。
2. 点击顶部菜单栏的双窗口图标 → **「偏好设置...」**：
   - **目标键盘**：选择「所有键盘」或某块指定外接键盘（如 `Keyboard K380`）。
   - **切换热键**：选择 `Control + Tab`（配合上方修饰键互换，对应物理 `Alt + Tab`）或 `Option + Tab`（未互换修饰键时使用）。
   - **开机自启**：勾选即可注册到系统登录项。
3. 权限说明：
   - **辅助功能（必需）**：用于拦截切换热键。
   - **输入监控（仅选择「指定键盘」时需要）**：用于识别按键来自哪块物理键盘；如果选择「所有键盘」则不需要此权限。

## License

MIT
