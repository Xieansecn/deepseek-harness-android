<div align="center">

# DeepSeek Harness for Android / Termux

**在 Android 手机的 Termux 里原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)**
**Run DeepSeek Harness natively inside Termux on Android**

[![tested](https://img.shields.io/badge/tested-0.2.1--rc.2-blue)](#-兼容性--compatibility)
[![platform](https://img.shields.io/badge/platform-Android%20%C2%B7%20Termux-green)](#-环境要求--requirements)
[![license](https://img.shields.io/badge/license-MIT-lightgrey)](#license)

[🇨🇳 中文](#-中文文档) · [🇬🇧 English](#-english-docs)

</div>

> [!IMPORTANT]
> 已在 **deepseek-harness `0.2.1-rc.5`**（**撰写时**的 npm `latest` = `next`；`alpha` 是 `0.2.2-alpha.2`，当前版本用 `npm view @deepseek-ai/dsh version` 查）上实测通过：本机直接跑 `bash setup.sh`（**3m18s**，npm 报告 `added 3 / removed 4 / changed 605 packages`）、**全部现有补丁命中（无需改任何锚点）**、`dsh web` 冷启动到 token **13.9s**、鉴权 303→cookie→200、日志零 warn/error，重跑幂等。0.2.0-rc.2 与 0.1.7-rc.2 线同样支持（0.1.7 起性能补丁 `02` 锚点失效、报 `[deprecated]` 不计失败，由 `03` 继续保住热点；见下方「JS 性能补丁」）。升级只需重跑 `bash setup.sh`，然后重启 GUI（`bash ~/dsh/restart_dsh_now.sh`）。
>
> **2026-11 更新**：当前设备已升级到 **`0.2.2-rc.1`** 并迁移到 npm 原生全局布局（旧 `~/.local/share/dsh-android/dsh` hold 树已删除）。0.2.2 重写了 `dsh-host-frontend-static`（`Response` API）和 `dsh-fs-local` 的 `createIfAbsent`；补丁 `01` 与 link 补丁已**重锚**并通过 js-patches（21）/guards（39）夹具。`2/9` 还修了一个隐藏炸弹：旧提示文本把命令写在反引号里，bash **真的会执行**（安装中途偷偷重装未打补丁的 dsh）。升级仍只需 `bash setup.sh`。
> Tested on **deepseek-harness `0.2.1-rc.5`** (npm `latest` = `next` **at the time of writing**; `alpha` is `0.2.2-alpha.2` — check the current one with `npm view @deepseek-ai/dsh version`): full `bash setup.sh` run (**3m18s**, npm reported `added 3 / removed 4 / changed 605 packages`), **every existing patch still applies with no anchor changes**, `dsh web` cold start to token in **13.9s**, auth 303→cookie→200, zero warn/error lines, idempotent reruns. The `0.2.0-rc.2` and `0.1.7-rc.2` lines are supported as well (since `0.1.7` upstream implements client-combo laziness natively, perf patch `02` finds no anchor there and reports `[deprecated]`, not a failure, while `03` keeps the hotspot fast; see the JS perf notes). The device now runs `0.2.1-rc.5`; upgrading is just re-running `bash setup.sh`, then restarting the GUI (`bash ~/dsh/restart_dsh_now.sh`).
>
> **2026-11 update**: the device has been upgraded to **`0.2.2-rc.1`** and migrated to npm's native global layout (the old `~/.local/share/dsh-android/dsh` hold tree was deleted). 0.2.2 rewrote `dsh-host-frontend-static` (Response API) and `dsh-fs-local`'s `createIfAbsent`; patch `01` and the link patch were **re-anchored** and verified by the js-patches (21) / guards (39) fixtures. Step `2/9` also got a hidden-bomb fix: the old hint text put a command in backticks, which bash **actually executed** (mid-install reinstall of an unpatched dsh). Upgrading is still just `bash setup.sh`.

---

# 🇨🇳 中文文档

## 这是什么

在 Android 手机上**原生**运行 DeepSeek Harness（`@deepseek-ai/dsh`，DeepSeek 官方的 agent harness，类 Claude Code）。手机浏览器访问 Web UI（`http://127.0.0.1:3080`）使用，agent 可以在手机上真实执行 bash 命令、读写文件、跑构建。

本仓库**不是 dsh 的源码**，而是一套**安装器 + Android 兼容性补丁**：

- `setup.sh` 负责把上游 `@deepseek-ai/dsh` 装进 Termux，并自动打上所有 Android 适配补丁；
- 补丁直接改写**已安装到** `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh` 的文件；
- 附带启动/停止/重启脚本、`danger-full-access` 配置层。

> [!TIP]
> 一句话：上游 dsh 只发 linux/darwin 产物，这个项目让它能在**无 root 的 Android** 上跑起来。

## ✨ 功能特性

| | 特性 |
|---|---|
| 🚀 | 一条命令完成安装 + 全部 Android 修补（幂等，可反复重跑） |
| 🧰 | 安装方式单一：**npm**（`npm install -g`，命令与旧版逐字一致）；另含 `2.5/9` 的 pnpm 运行时供给（dsh 插件功能的运行期依赖） |
| 🧩 | 原生插件适配：node-pty / koffi / sharp / ripgrep / flock / node-addon-require-builtin |
| 🔗 | 无硬链接（SELinux 禁 `link()`）修复：会话、附件、工具写文件全部照常 |
| 🔐 | 新版 Web 鉴权适配：自动提取带 token 的启动 URL 并校验后再交给浏览器 |
| 🌐 | 默认用 **Via 浏览器**（按包名）打开，找不到再回退系统默认浏览器 |
| 📱 | 可选：社区插件 **dsh-android-ui** 做手机界面适配（刘海避让、软键盘跟随、侧栏抽屉），一行装进 `web` profile（见「📱 手机界面适配（可选）」） |
| ⚡ | 启动脚本零轮询等待（流式读日志），复用已在运行的服务约 0.2s |
| 🎨 | 安装全程状态行 + 彩色输出，原始日志落盘便于排查 |

## 📋 环境要求

- **Android 手机 + [Termux](https://f-droid.org/en/packages/com.termux/)**（F-Droid 或 GitHub 版，**不要用 Google Play 版**，已过时）
- 无需 root；aarch64 设备（作者实测 Huawei Mate 60 / HarmonyOS 4.2 / Node v26）
- 建议留出 ~1GB 空间（npm 依赖 + 构建缓存）

## 🚀 快速开始

### 1. 安装 Termux 并更新

```bash
pkg update -y && pkg upgrade -y
```

### 2. 克隆并一键安装

```bash
pkg install -y git
git clone https://github.com/FunnelCakes/deepseek-harness-android.git
cd deepseek-harness-android
bash setup.sh            # 首次约 5~15 分钟；加 --verbose 可看原始输出
```

> [!NOTE]
> **国内网络**：`setup.sh` 会先测速，npm / nodejs.org 慢时**自动切到 npmmirror 镜像**（仅本次会话生效，不改全局配置）。若 `git clone` 超时，可先开代理，或改用镜像：`https://gitclone.com/github.com/FunnelCakes/deepseek-harness-android.git`。

### 3. 启动并使用

```bash
bash ~/dsh/start_dsh.sh     # 启动服务并自动用 Via 打开带 token 的页面
```

然后在网页的 **Models** 页填入 **DeepSeek API Key** 即可开始（Key 存于 `~/.dsh/.credentials.yaml`，权限 0600）。

### 4. 日常命令

```bash
bash ~/dsh/start_dsh.sh       # 启动 / 复用服务，并打开浏览器
bash ~/dsh/stop_dsh.sh        # 停止服务
bash ~/dsh/restart_dsh_now.sh # 重启服务（不打开浏览器）
bash setup.sh                 # 升级 dsh 或 Node 后必须重跑
bash npm_android.sh -g update # 仅用于其它全局包：注入 Android target；dsh 升级请走 setup.sh
```

> [!IMPORTANT]
> **不要在本项目环境里直接运行 `npm -g update`**：它不经过 `setup.sh`，不会设置 `CFLAGS/CXXFLAGS=-target aarch64-linux-android30`。dsh 依赖的 koffi 3.1.1 回退本地编译时会因 bionic 的 `statx()` 只在 API 30 头文件里声明而报 `__u32`/`const char *` 错误。必须手动操作 npm 时统一走 `bash npm_android.sh <npm 参数…>`。**dsh 现在是原生全局安装，`npm -g update` 会直接升级/覆盖它并丢失安装期补丁**；升级 dsh 只走 `bash setup.sh`。
>
> dsh 现在**直接安装在 npm 默认全局目录**（`/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`，真实目录，不是 symlink）。npm 没有「hold 单个全局包」的能力：裸 `npm -g update` **会**升级/重装 dsh 并丢掉安装期补丁（node-addon 平台包、link/flock 修复、JS 性能补丁等），还可能因 koffi 回退编译缺 Android target 而失败。因此 **dsh 的升级/修复只走 `bash setup.sh`**；误跑 `npm -g update` 后重跑 `bash setup.sh` 即可恢复。从旧版 hold 布局迁移时脚本会自动摘除旧 symlink，并提示旧安装树的清理命令。

> [!WARNING]
> **不要直接打开 `http://127.0.0.1:3080`**：新版 dsh 需要**带 token 的启动 URL** 换取登录 cookie，直接打开会 401。请始终用 `start_dsh.sh`，它会从日志里取当前进程的 token、用 `curl` 验证返回 303 之后才交给浏览器。

> [!NOTE]
> 直接跑 `dsh web` 时报 `dsh: startup failed: … listen EADDRINUSE: address already in use 127.0.0.1:3080`，含义是**端口上已经有一个 dsh web 实例**（token 是进程级的，起第二个必然失败）。`start_dsh.sh` 会复用正在跑的实例；若占用端口的进程本会话看不到（另一个用户/应用、`su` 启动、别的终端会话），它会在 1 秒内说明情况并给出「结束旧实例 / `DSH_PORT=3081` 换端口」的做法，**不会再白拉起一个必然 EADDRINUSE 的实例、也不空等到超时**。

## ⚙️ 用法与配置

### 安装方式：npm

安装后端只有一种：`npm install -g`（命令与旧版逐字一致）。另有 `2.5/9` 的 **pnpm 运行时供给**（dsh ≥0.2.1 的插件功能在运行期依赖 pnpm；PATH 上已有可用 pnpm 11.x 时只报 `[OK]`、不写任何文件）。

> 历史上曾提供第二种安装方式 `--pnpm`（pnpm 11 非全局 project 安装 + 迁移到规范 `DSH_DIR`）。因为产物与 npm 方式逐项一致、却要额外维护版本线校验与冲突预检，已移除。现在传 `--pnpm` / `--npm` 会明确报「参数已废弃」并 `exit 1`，不会静默改用 npm 安装。

> ⚠️ **pnpm 12 在 Android 上不可用**，请只用 **pnpm 11.x**。另外 **dsh ≥0.2.1 的插件功能（`dsh plugin …` / 插件市场）运行期会从 PATH 调用 `pnpm`**，所以插件功能依赖可用的 pnpm 11 —— 见下文「pnpm 运行时（插件功能依赖）」。

### pnpm 运行时（插件功能依赖）

dsh ≥0.2.1 的插件管理器（`dsh plugin …` / 插件市场）运行期会 `execa("pnpm")` 从 PATH 调用 pnpm，所以 **pnpm 11.x 不只是安装工具，也是运行期依赖**。`setup.sh` 新增 `2.5/9 pnpm 运行时` 步骤（幂等，装/不装 dsh 都会跑）：

预检**不写死某个 pnpm 路径、也不写死某个版本号**：它把 **PATH 上每一个 `pnpm`**（顺序即优先级）、`~/.local/share/pnpm-pin`、`PNPM_HOME`、npm 全局目录全探一遍，逐个跑 `--version`，只认 **11.x**，然后按下面四种结局之一处理（前三种都不会让你卡住）：

- **PATH 首位就是可用的 11.x** → 直接复用，**不写任何文件**。
- **别处有能用的 11.x（如经探测到的 pin 目录 / `PNPM_HOME` / npm 全局 11.x）** → **复用**它：写包装指向该入口，**不重新下载**。
- **只有不合格的 pnpm（12.x / <11 / 坏入口），但 `~/bin` 在 PATH 上且排在它前面** → 自动 `npm --prefix ~/.local/share/pnpm-pin install pnpm@11.27.1`（纯 **JS build**，无原生 exe）并写 4 个包装 `~/bin/{pnpm,pn,pnpx,pnx}`，用它们**压过**坏的 pnpm；随后验证 `~/bin/pnpm --version` 是 11.x 且 PATH 确实解析到它。
- **确实找不到能用的版本，且写包装也压不过（`~/bin` 不在 PATH、或排在坏 pnpm 之后）** → **停止并提示**：列出探测到的每个 pnpm 及其版本、为什么不合格、三条具体修复命令（`npm install -g pnpm@11` / `npm uninstall -g pnpm` / 调整 PATH 顺序），并明确告知「本步骤只读、未改动任何文件」。**改完直接重跑 `bash setup.sh` 即可正常继续**（夹具里有对应用例钉住这一点）。
- **本仓库的包装损坏** → 自动修复；**已等价的包装**（用户手写的 pin 包装）→ 认领、不覆盖；**别人的同名包装且内容不等价** → 拒绝（设 `DSH_PNPM_CONFLICT_OVERRIDE=1` 可强制，旧文件备份为 `.dsh-android.bak`）。
- **包装目录不在 PATH 上** → 中文提示并 `exit 1`（dsh 子进程 `execa("pnpm")` 找不到就白装）：在 `~/.bashrc` 里加 `export PATH="$HOME/bin:$PATH"` 后重开终端。
- 被遮蔽的 npm 全局 pnpm 12 只 `warn` 提醒（不影响本次运行）。
- **npm `strict-allow-scripts=true`** → 配置类冲突，`exit 1` 并提示改回 `false`（否则 `SKIP_SCRIPTS` 里的 koffi 会让整次 npm install 中断）。
- 可调：`DSH_PNPM_PIN_DIR`（默认 `~/.local/share/pnpm-pin`）、`DSH_PNPM_WRAPPER_DIR`（默认 `~/bin`）、`DSH_PNPM_VERSION`（默认 `11.27.1`）。**不建议把 `DSH_PNPM_VERSION` 升到 12.x**（Android 不可用），11.28+ 也可能改回「下载原生二进制」的路径。
- 只想单独跑这一步（排障/补装）：`DSH_SETUP_PROVISION_ONLY=1 bash setup.sh`（**测试/排障钩子**，不会安装 dsh）。

> `~/bin` 必须排在 `$PREFIX/bin` 之前（Termux 默认配置里 `~/bin` 一般更靠前）；被遮蔽的坏 pnpm 12 不要删到影响其它工具，保持在 `~/bin` 的 11.x 之后即可。

### 脚本参数

| 脚本 | 参数 | 说明 |
|---|---|---|
| `setup.sh` | `--verbose` / `SETUP_VERBOSE=1` | 透传子命令原始输出（默认只显示摘要，原始日志写 `~/dsh/setup.log`） |
| | `--pnpm` / `--npm` | **已废弃**：安装方式只有 npm；传入会打印废弃提示并 `exit 1` |
| `start_dsh.sh` | `--no-open` | 只拉起服务并打印带 token 的 URL，不打开浏览器 |
| | `DSH_NO_OPEN=1` | 同上（环境变量形式） |

### 环境变量

| 变量 | 默认值 | 作用 |
|---|---|---|
| `DSH_READY_TIMEOUT` | `90` | 等 dsh 打印带 token URL 的最长秒数（冷启动实测 ~12s，未打补丁 ~22s，留足余量） |
| `DSH_STOP_GRACE` | `1.5` | 停止时给 dsh 优雅退出的秒数；超时补发一次 `SIGTERM`（dsh 自己的"二次信号立即强退"，实测 0.17s）。设大些（如 `6`）可让它自己退完 |
| `DSH_STOP_TIMEOUT` | `6` | 补发 `SIGTERM` 后仍不退时，等多久 `SIGKILL` 兜底 |
| `DSH_HINTS` | `0` | `1` 时启动脚本额外打印 PWA 排查提示并尝试复制 URL 到剪贴板（默认静默） |
| `DSH_VIA_APP` | `mark.via` | 优先打开的浏览器包名（Via） |
| `DSH_OPEN_APP` | 空 | 强制指定浏览器包名/组件，优先级最高，如 `com.android.chrome` |
| `DSH_OPEN_CHOOSER` | `0` | 设为 `1` 时弹系统应用选择器 |
| `DSH_ORIGIN` | `127.0.0.1` | 打开给浏览器的 origin；`localhost` 可绕开 PWA 对 `?token=` 的劫持 |
| `DSH_PORT` | `3080` | 服务端口（`start_dsh.sh` 会把它作为 `--port` 显式传给 dsh——dsh 本身不读这个变量） |
| `NO_COLOR` | 空 | 非空则关闭彩色输出 |
| `DSH_VERSION` | 空（跟随 npm `latest`） | **仅**灰度/回退时钉版本：`DSH_VERSION=<ver> bash setup.sh`，`<ver>` 从 `npm view @deepseek-ai/dsh versions` 取。默认留空——写死版本号会让升级永远跟不上 |
| `DSH_PNPM_PIN_DIR` | `~/.local/share/pnpm-pin` | `2.5/9` 把 pnpm 11（JS build）装到这个目录（`npm --prefix`） |
| `DSH_PNPM_WRAPPER_DIR` | `~/bin` | `2.5/9` 写 `pnpm`/`pn`/`pnpx`/`pnx` 包装脚本的目录；**必须在 PATH 上**，dsh 子进程才找得到 |
| `DSH_PNPM_VERSION` | `11.27.1` | `2.5/9` **需要下载时**安装的 pnpm 版本（探测到本机已有可用 11.x 时会直接复用）；**别升到 12.x**（Android 不可用） |
| `DSH_PNPM_CONFLICT_OVERRIDE` | `0` | pnpm 运行时遇到「用户自己的 pnpm 包装」等**共存类冲突**时强制继续（旧包装备份为 `.dsh-android.bak`）；pnpm 版本类冲突**不可覆盖** |

> `DSH_SETUP_PREFIX` / `DSH_SETUP_PREFLIGHT_ONLY` / `DSH_SETUP_PROVISION_ONLY` 是**仅测试夹具/排障使用**的钩子（替换前缀 / 只跑预检 / 只跑 pnpm 运行时供给），**生产环境不要设置**。

### 打开浏览器的顺序

1. `DSH_OPEN_APP=<包名>`（显式覆盖）
2. **Via**（默认 `mark.via`）——用 `am start` 按包名打开，顺带避开 PWA 劫持
3. 系统默认浏览器（`termux-open-url` 不带包名）
4. `DSH_OPEN_CHOOSER=1` 时才弹选择器

```bash
# 例子
DSH_OPEN_APP=com.android.chrome bash ~/dsh/start_dsh.sh   # 指定 Chrome
DSH_ORIGIN=localhost bash ~/dsh/start_dsh.sh              # 绕开 PWA 劫持
DSH_NO_OPEN=1 bash ~/dsh/start_dsh.sh                     # 只打印 URL 自己粘
```

## 📱 手机界面适配（可选）

dsh 的 Web UI 是给桌面浏览器排的版：刘海压住顶部内容、软键盘盖住作曲栏、侧栏把正文挤窄、个别按钮只接了 hover 路径（手指点不动）。这些**不属于本仓库的修补范围**——本仓库只保证启动/鉴权链路与后端兼容性，**不注入任何前端 CSS/JS**（历史上做过 `apply-frontend.sh`，因为依赖上游哈希类名、每次升级必漂移，已删除；见「原理」末尾）。

想要手机友好的界面，可以装社区组合包插件 **[Xieansecn/dsh-android-ui](https://github.com/Xieansecn/dsh-android-ui)**（官方插件形态，不改 dsh 产品文件）：

```bash
# 1) 装进 web profile（dsh 内部走 pnpm；需要 git 与网络）
dsh plugin --profile web add github:Xieansecn/dsh-android-ui

# 2) 确认组合层已挂上，输出里应出现 "# == dsh-android-ui"
dsh --profile web --dump-config | grep -A2 dsh-android-ui

# 3) Node 半在启动时读进内存：刷新页面不够，必须重启
bash ~/dsh/restart_dsh_now.sh
```

卸载（同样是 pnpm，改完同样要重启）：

```bash
dsh plugin --profile web remove dsh-android-ui
bash ~/dsh/restart_dsh_now.sh
```

它做什么（详见它自己的 README）：`viewport` 就地改写为 `viewport-fit=cover` + `interactive-widget=resizes-content`（刘海避让，软键盘收缩内容区而不是盖住页面）、移动端 CSS（侧栏变抽屉、safe-area、作曲栏重排、设置面板全屏）、启动前 polyfill（`AbortSignal.any` / `crypto.randomUUID`，老 WebView 缺了会直接白屏），以及运行期的软键盘跟随、悬浮侧栏开关与触摸兜底。它另带一个**可选的一次性脚本**把 PWA manifest 的 `display: fullscreen` 改成 `standalone`（manifest 是浏览器自己 GET 的静态 JSON，运行期插件改不到；只用浏览器打开、不装 PWA 可以跳过）。

注意事项：

- **第三方插件，不是本项目的一部分**：不打包、不修改，版本兼容与问题反馈都归它自己的仓库。
- **它按 dsh `0.1.7-rc.2` 逐个核对了上游哈希类名，而哈希类名随版本漂移且是静默失效**（页面正常、效果全无）。升级 dsh 后请同步升级/重装它，或先卸载以确认问题归属——`bash setup.sh` 不会替你处理这一步，它只做后端修补。
- **与本仓库互不干扰**：`setup.sh` 第 7 步只把权限层**合并**进 `~/.dsh/profiles/web/cordis.patch.yml`——文件还是 dsh 的空数组模板（`[]`）就整体替换，已有你自己的配置层就追加——不覆盖 profile 里的其它配置层，所以装好插件后照常重跑 `setup.sh` 即可。
- **「普通回车=换行」不在这个插件里**：那处按键映射要改产品包，仍由本仓库的 `setup.sh` 修补（见下文「原理」表）；插件只负责 `enterkeyhint=newline`。
- **只对 `web` profile 有意义**，`tui` / `headless` 无关。
- **鉴权链路不变**：仍用 `bash ~/dsh/start_dsh.sh` 打开带 token 的 URL，直接开裸地址依旧 401。

## 🔧 原理：setup.sh 自动修复了什么

上游 `@deepseek-ai/dsh` 只发布 linux/darwin 预编译产物，且假设了完整的 Linux 命名空间沙箱与硬链接能力。Android/bionic 环境下需要下面这些适配——**全部由 `setup.sh` 自动完成，且幂等**：

| 问题 | 现象 | 修复方式 |
|---|---|---|
| node-pty 编译失败 | `Undefined variable android_ndk_path` | 修补 node-gyp 缓存里的 `common.gypi` |
| **koffi 原生模块不可用** | 0.2.0-rc.2 起 `koffi` 被**精确钉在 3.1.1**；`@koromix/koffi-android-arm64` 从 3.2.1 才有预编译包，3.1.1 的 install 脚本会自愈式回退到本地编译（历史上会死在 bionic 与 glibc 的 `statx` 原型差异上） | 仍**不进 `--allow-scripts` 白名单**（`setup.sh` 的 `SKIP_SCRIPTS`）：npm 12 里白名单内脚本**失败会让整次安装退 1**，白名单外只警告并跳过。⚠️ **本机实测修正**：设备上的 npm 是 **11.21.1**，它的 `--allow-scripts=<list>` 是**建议性**的（未列出的包脚本仍会执行，只打警告；只有 `strict-allow-scripts` 才硬失败），所以这里 koffi 的 install 脚本**实际执行且编译成功**（`koffi.load('libc.so')` 可加载）——旧文档「构建必然失败」在这台设备上**不复现**。无论编不编得过，dsh 的 koffi 调用点全是懒加载且 `platform === "win32"` 才走，Android 运行期都用不到。⚠️ dsh 现在是**原生全局安装**：`npm -g update` 会重装 dsh 依赖并绕过本项目的 Android 编译参数与安装后补丁，所以升级/修复 dsh 必须 `bash setup.sh`（单独手动安装其他包可用 `bash npm_android.sh …` 注入 Android target） |
| npm 构建脚本审批随版本不同 | 同一份白名单在 npm 11 与 npm 12 行为不同：npm 11（本机 11.21.1）的 `--allow-scripts` 只**建议**要不要执行、未列出的脚本仍执行并警告；npm 12 才把白名单变成**强制** | `setup.sh` 仍只把**能在 Android 构建成功**的包放 `--allow-scripts`、把 koffi 放 `SKIP_SCRIPTS`：这样在 npm 12 上不会被 koffi 拖死整次安装，在 npm 11 上也不影响结果（koffi 编得过但没有运行期调用点）。若你手动在 npm 配置里设了 `strict-allow-scripts=true`，白名单外的脚本会变成硬错误——`setup.sh` 的安装预检会把它当成安装冲突，打印处置建议后提前退出 |
| `link()` 被 SELinux 禁用 | 会话/附件保存、会话迁移、`write` 新建文件报 `EACCES` | 会话日志直接发布改 `rename()`；no-replace 场景回退「O_EXCL 占位 + rename」；附件遍历/清理容忍 `EACCES`/`ENOENT` |
| `flock` 在 Android 不可用 | 发消息报 `flock is not supported on android-arm64` | 用 clang 把 `node-addon-system` 自带 `src/flock.c` 编成本机 `system.node`，并让 `lib/flock.js` 在 android 下加载它（含真实加锁自检） |
| **dsh ≥0.1.7 完全起不来** | `No usable native binding found for node-addon-require-builtin-android-arm64`，`host preparation failed` | 上游新增的原生 addon 家族只发布 darwin/linux/win32 预编译包，没有 android。补一个 `node-addon-require-builtin-android-arm64` 平台包（纯 JS 实现，依赖包装脚本已带的 `--expose-internals`），并内置 `internalModules()` 自检（包名后缀随设备架构变化，如 armv7 上是 `-android-arm`） |
| **`dsh web` 起不来：`YAMLException: end of the stream or a document separator is expected`** | 报错指向 `~/.dsh/profiles/web/cordis.patch.yml` 里我们自己写的 `- id: sandbox-policy`（形如 `(13:1)`） | dsh 首次启动（哪怕跑失败的那次）会自己在 profile 里写一份「空数组文档」模板（3 行注释 + `[]`）；旧版 `setup.sh` 只查有没有 `danger-full-access` 就无条件 `>>` 追加权限层，于是在一个**已经结束**的 YAML 文档后面再挂序列项，整个 profile 解析失败。现在由 `patches/apply-profile-patch.js` 按内容分类：空数组模板→**整体替换**、已有真实配置层→**追加**、残留裸 `[]`→**定点摘除**（现场修复），落盘前后都用 dsh 自己的 `loadOverlayPatches()` 真解析校验，坏文件一个字节都不动（夹具 30 断言） |
| **日志出现 `permission: composed sandbox and approval defaults match no preset`、`1 entry did not activate`** | 0.2.0 起新增的 `permission` 行（`@deepseek-ai/dsh-permission-presets`）不激活：bash 仍能跑，但权限预设服务缺失 | 该行按「sandbox + approval 组合」反查预设，而预设 `danger-full-access` = 这两者的组合；只改 sandbox 而 approval 还是基线的 `ask` 就匹配不到。现在权限层**两条成对**下发，重跑 `bash setup.sh` 会自动补上缺的那条 |
| PTY 终端检测失败 | `unsupported on platform android` | subprocess 把 `android` 视同 `linux`（锚点可能在内容哈希 bundle 里，按通配扫描 `lib/`） |
| 安卓输入法回车直接发送 | 打不出多行：回车即发送 | 修补 `dsh-client-ui-conversation`：普通回车=换行，`Ctrl/Cmd+Enter`=发送（失败即回滚并中断安装；会中断安装的还有 4-boot 平台包、ripgrep、3/9 的 npm 安装） |
| sharp 无法加载 | `Could not load sharp module` | 安装 `@img/sharp-wasm32` wasm 回退（含 `@emnapi/runtime`） |
| grep/glob 报 `ripgrep launch failed` | `@vscode/ripgrep` 无 Android 预编译包 | 符号链接系统 `rg` + 修补 `resolveRgPath()` 回退 |
| HMR 启动崩溃 | `--expose-internals is required` | 重建 `dsh` 包装脚本，加 `--expose-internals --no-warnings` |
| bash 工具不可用 | `SANDBOX_UNAVAILABLE` | 写入 `danger-full-access` 配置层（见下方安全说明） |
| 整页重载重复下载 JS | 每次刷新重下 `/assets/` 全部构建产物（本机实测 ~4.5MB） | 给 `/assets/` 静态资源加 immutable 缓存头 |
| 冷启动十几秒才出 token | `dsh web` 起来后端口先回 401，十几秒后才打印鉴权 URL | 客户端插件组合（`dsh-client-modules`）启动时会全量重组约 10 次，每次都把所有 client bundle 预建一遍单条 artifact：`0.1.7` 起上游已用原生 `lazyBody` 按需构建，补丁 `02` 在 `0.1.5` 线上做同一件事（实测冷启动 22.6s → 12.5s，产物与未打补丁时逐字节一致），`03` 再把这处行数统计改成索引循环 |

> [!NOTE]
> 现在保留三个上游 JS 性能补丁：`01-frontend-static-cache`（`/assets/` 内容哈希资源用 immutable 缓存头；⚠️ 0.2.2 起上游已原生给所有非 index 文件加 `no-cache`+ETag+304，补丁只把 `/assets/` 升级为 immutable，其余沿用上游行为）、`02-client-modules-lazy-compose`（客户端 combo 按需构建）与 `03-client-modules-newline-count`（`newlineCount` 改索引循环，10.8MB 实测 302ms→60ms）。
> `01`/`02` 面向 0.1.5 线；`0.1.7` 起上游已原生实现 combo 惰性化（`lazyBody`），`02` 已弃用（上游原生 `lazyBody` 取代了它），报 `[deprecated]` 而不是失败（第 8/9 步不再告警），此时由**与版本无关**的 `03` 继续保住这处热点。历史上做长会话历史瘦身的补丁（apiproxy history slim、增量重连、连接 schema、插件 bundle 缓存）宿主模块已被上游移除或原生实现，相关文件与"过时跳过"逻辑已删除。三个补丁的锚点均已对照 npm 对应版本源码逐字节核对。

> [!IMPORTANT]
> **本仓库不注入任何前端界面代码**：不注入 CSS/JS、不改 `dsh-web-frontend` 的 viewport 与 PWA manifest。历史上做过（`apply-frontend.sh` + `patches/mobile.css`/`mobile.js`），但它依赖上游构建产物里的哈希类名与 DOM 结构，**每次 dsh 升级都会漂移**，与「只做最小侵入式文本替换」的约定冲突，已删除。前端体验问题请提给上游；需要手机界面适配请装可选插件（见「📱 手机界面适配（可选）」）。唯一例外是作曲栏的按键映射（`dsh-client-ui-conversation`：普通回车=换行、`Ctrl/Cmd+Enter`=发送），它改的是按键处理逻辑而非样式，且同样按锚点修补、失配即回滚。

## 🗂 工作原理与安装步骤

### 安装步骤（`setup.sh` 的 9 步）

> 安装动作之前会先跑一次**只读的 pnpm 运行时预检**，并在 `2.5/9` 实际供给（见「pnpm 运行时（插件功能依赖）」）。dsh 本身的安装命令与旧版逐字一致（`npm install -g`），没有额外的安装冲突预检。

| 步骤 | 做什么 |
|---|---|
| `0/9` | 锚点预检：确认目标文件里补丁特征串还在（版本漂移早发现） |
| `1/9` | 安装构建依赖：`cmake clang make binutils pkg-config python nodejs ripgrep` |
| `2/9` | 准备 Node headers：**Termux 自带 `$PREFIX/include/node` 时直接使用并跳过下载**（node-gyp 未给 `--nodedir` 时走 `process.config.variables.node_prefix`）；否则 `npx node-gyp install`（慢则切 npmmirror）并给缓存 `common.gypi` 补 `android_ndk_path` |
| `2.5/9` | **pnpm 运行时**（dsh 插件功能依赖）：PATH 上已有可用 pnpm 11.x 就直接复用；没有就 `npm --prefix ~/.local/share/pnpm-pin install pnpm@11.27.1`（JS build）并写 `~/bin/{pnpm,pn,pnpx,pnx}` 包装，幂等 |
| `3/9` | 安装 dsh：`npm install -g` **直接装到 npm 默认全局目录**（旧版 hold symlink 与旧 dsh 包装会在安装前自动摘除/移开，失败会还原；android30 目标；`--allow-scripts` 只放行**构建能在 Android 成功**的原生包，koffi 在 `SKIP_SCRIPTS` 里、npm 12 下只会警告并跳过——白名单内的脚本失败会让整次安装退 1；npm 11 的 `--allow-scripts` 只是建议性）。装后校验 node-pty 产物、跑安装脚本白名单自检、并报告实际生效的 `allow-scripts` 策略（advisory / strict） |
| `4/9` | 后端兼容补丁：`node-addon-require-builtin` android 平台包（≥0.1.7 启动前提，失败即中断）、link→rename 回退、flock 原生绑定、subprocess 平台检测（android≡linux）、作曲栏「回车=换行」、grep/glob ripgrep 修复 |
| `5/9` | sharp wasm 回退（附件模块依赖），紧接硬链接补丁验证（临时目录真实运行，不碰会话数据；必须排在 wasm 回退之后，否则附件模块 `import sharp` 失败会误报） |
| `6/9` | 重建 `dsh` 包装脚本（`--expose-internals`，原子 `mv` 替换，不碰符号链接目标） |
| `7/9` | 写入 `~/dsh/` 下的启动/停止/重启脚本；用 `patches/apply-profile-patch.js` 安全安装权限层（`sandbox-policy` + `approval` **两条**；空数组模板→替换、已有配置层→按条目只补缺失、残留 `[]`→定点修复；写前写后都用 dsh 自己的解析器校验，不可解析即中断，绝不留下起不来的 profile） |
| `8/9` | JS 性能补丁（`01` 静态资源缓存头 / `02` 客户端 combo 按需构建 / `03` newlineCount 索引循环；锚点失配只告警不中断） |
| `9/9` | 完成汇总 |

### 鉴权与启动链路

```text
setup.sh                安装 + 打补丁 + 生成脚本
   │
   ├─ ~/dsh/start_dsh.sh        启动/复用 dsh web，取带 token URL 并打开浏览器
   ├─ ~/dsh/stop_dsh.sh         按 pid 文件 + 身份二次校验安全停止
   └─ ~/dsh/restart_dsh_now.sh  复用 stop + start（--no-open）
        │
        └─ dsh web（node bin.js，监听 127.0.0.1:3080）
             ├─ 启动时生成内存态 launch token，日志打印：
             │    dsh web: http://127.0.0.1:3080/?token=...
             ├─ 浏览器打开该 URL → 服务端 303 + Set-Cookie（签名 cookie）
             └─ 之后 / 和 /api 都走 cookie 鉴权
```

`start_dsh.sh` 的关键行为：

- **等 token 用流式读日志**（`tail -f`），token 一出现立即返回，不再每秒 `grep`+`curl` 轮询；
- token 用 `curl` 校验必须返回 **303/302** 才交给浏览器，避免日志残留旧进程 token 导致 401；
- 拿不到有效 token 时降级打开裸 URL，并打印**具体原因**（`no-token` 或实际 HTTP 码）；
- **拉起前先探端口**：端口已有响应但本机看不到 dsh 进程（另一个用户/应用、`su`、别的会话）→ **不启动必败的第二个实例**，直接说明占用情况并给出「结束旧实例 / `DSH_PORT=3081` 换端口」；
- **启动失败立即报**：日志出现 `startup failed` 或进程在给出 token 前退出时，立刻打印原因与日志末尾（不再空等 `DSH_READY_TIMEOUT`，也不把 401 裸地址当成功）；
- 复用已在运行的服务约 **0.2s**，冷启动脚本侧开销约 **9.1s**（其中约 9s 是 dsh 自身 plugin loader settle，非脚本可消除）。
- **每次结束打印一行 `[dsh] 本次耗时 X.XX 秒`**（2 位小数；复用/冷启动/降级/失败/中断都打，挂 EXIT trap 只打一次；bash 走内建 `EPOCHREALTIME`，零额外 fork）。
- **「现有进程没就绪 → 自动重启」这条路能走通了**：`wait_for_token()` 每次进入都重置 FIFO 与标记文件，重启后会再等一次 token（此前第二次 `mkfifo ""` 必然失败，重启后直接报「启动超时」；夹具用例 12 守着）。

## 📁 仓库结构

```text
deepseek-harness-android/
├── setup.sh                     # 主入口：安装 dsh（npm install -g）+ 全部 Android 修补（幂等）
├── apply-js-patches.sh          # 应用 JS 性能补丁（01 缓存头 / 02 combo 惰性化 / 03 newlineCount，幂等）
├── apply-rg-fix.sh              # 修复 ripgrep launch failed
├── start_dsh.sh                 # 启动/复用服务 + 取 token + 打开浏览器（Via 优先）
├── stop_dsh.sh                  # 安全停止（pid 身份二次校验 + 端口释放确认）
├── restart_dsh_now.sh           # 重启（复用 stop + start --no-open）
├── config/
│   └── cordis.patch.yml         # danger-full-access 配置层（由 patches/apply-profile-patch.js 安全合并进 ~/.dsh/profiles/web/）
├── patches/
│   ├── 01~03-*.patch            # JS 补丁源（缓存头 / 客户端 combo / newlineCount）
│   ├── patch-dsh-android-link.js    # 禁硬链接修复（rename / O_EXCL+rename 回退）
│   ├── patch-dsh-android-flock.js   # flock 原生绑定（编译 + 运行时自检）
│   ├── patch-dsh-android-require-builtin.js # ≥0.1.7 启动前提：补 android 平台包
│   ├── verify-android-link-fix.js   # 硬链接修复验证（临时目录真实运行，不碰会话）
│   ├── apply-profile-patch.js       # 安全安装权限层（分类：替换/追加/定点修复 + dsh 解析器校验）
│   ├── verify-client-modules-lazy.js # 客户端 combo 补丁自检（--port 0 临时实例）
│   ├── verify-require-builtin-fixture.js # 平台包补丁夹具自检（8 用例 / 29 断言，只写临时目录）
│   ├── verify-patch-guards-fixture.js # link/flock 守护条件夹具自检（11 用例 / 39 断言，只写临时目录）
│   ├── verify-profile-patch-fixture.js # 权限层补丁夹具自检（11 用例 / 41 断言，只写临时目录）
│   ├── verify-js-patches-fixture.js # apply-js-patches.sh 夹具（21 断言：反向上游→正向打→幂等→破坏退 1）
│   ├── verify-runtime-scripts-fixture.js # start/stop/restart 夹具（40 断言：假 dsh + 隔离 HOME，不碰 3080）
│   ├── verify-pnpm-provision-fixture.js # pnpm 运行时供给夹具（76 断言：离线、临时 HOME/PIN/WRAPPER）
│   ├── verify-setup-static-check.sh # setup.sh / 运行期脚本静态契约（30 条，只读）
│   ├── verify-test-effectiveness.js # 变异测试：往副本注入 10 个已知回归，对应套件必须变红
│   └── verify-all-checks.sh         # 一条命令跑完全部脚本级检查（--full 追加变异测试）
├── npm_android.sh               # Termux npm 包装：注入 android30 编译参数（手动 npm update 必用）
├── docs/
│   └── index.html               # 说明文档站
├── AGENTS.md                    # 维护者约定与踩坑记录（给 AI/协作者）
└── README.md                    # 本文件（中英双语）
```

### 运行期目录（安装后生成，不在仓库里）

```text
~/dsh/
├── start_dsh.sh  stop_dsh.sh  restart_dsh_now.sh   # 安装时复制的脚本
├── setup.log                                       # setup.sh 原始输出
└── storage/
    ├── dsh.log          # dsh web 运行日志（含当前进程 token URL）
    ├── dsh.pid          # 当前进程 pid
    └── dsh_restart.log  # 重启记录

/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/   # dsh 原生 npm 全局安装目录（真实目录；旧版 hold 安装树迁移后可删）
~/.local/share/pnpm-pin/          # 2.5/9 安装的 pnpm 11（JS build；dsh 插件功能的运行期依赖）
~/bin/{pnpm,pn,pnpx,pnx}           # 2.5/9 写的 pnpm 11 包装（必须在 PATH 上）

~/.dsh/
├── .credentials.yaml    # API Key / 鉴权签名 secret（0600）
├── settings.yaml        # 设置
├── profiles/web/cordis.patch.yml   # 安装的 danger-full-access 配置层
└── sessions/ attachments/ skills/ ...   # 会话、附件、技能
```

## 🛠 维护与单独重跑

```bash
# 只重跑某个修补（不必整树重装）
bash apply-rg-fix.sh
bash apply-js-patches.sh

# 硬链接 / flock 补丁与验证
node patches/patch-dsh-android-link.js  --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/verify-android-link-fix.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/patch-dsh-android-flock.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"
# 补丁 02 自检（临时实例，不动运行中的服务）
node patches/verify-client-modules-lazy.js
# 夹具自检（只写临时目录，不碰安装树）
node patches/verify-require-builtin-fixture.js
node patches/verify-patch-guards-fixture.js
node patches/verify-profile-patch-fixture.js
node patches/verify-js-patches-fixture.js
node patches/verify-runtime-scripts-fixture.js
node patches/verify-pnpm-provision-fixture.js

# 一条命令跑完全部脚本级检查（语法 + setup 静态契约 39 条 + 6 个夹具 246 条断言；全绿输出 套件 PASS=8，加 --full 为 PASS=9）
bash patches/verify-all-checks.sh            # 摘要
bash patches/verify-all-checks.sh --verbose  # 全量输出
bash patches/verify-all-checks.sh --full     # 再跑变异测试（约 5 分钟，证明套件抓得住回归）
```

其中 `DSH_DIR=/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`。
这套检查**只读或只写临时目录**：不跑 `setup.sh`、不碰 3080、不写 `~/.dsh`、不改安装树。
所有修补脚本**幂等**：连跑两次，第二次应全部 `[OK]` / `[skip]`。
⚠️ `--root` 是**硬契约**：显式给出却定位不到就报错退 1，**不会**回落到其它安装树（所以拿它指临时副本时，绝不会误写生产树）；不传 `--root` 才自动定位。

## 🔐 安全说明

- 服务**只监听 `127.0.0.1`**（本机回环），不走局域网。
- API Key 存于 `~/.dsh/.credentials.yaml`（0600），不进日志、不进进程环境。
- Web 鉴权签名 secret 同样存于 `~/.dsh`，不要把它写进日志、环境变量或仓库。
- **`danger-full-access` 等同于关闭进程沙箱**：Android 无 bwrap/landlock 可用，受限模式会让 bash 工具直接 `SANDBOX_UNAVAILABLE`。这意味着 agent 可执行任意命令——**仅建议个人设备使用**。
- 权限层是**两条**：`sandbox-policy.mode = danger-full-access` **加** `approval.policy = never`。0.2.0 起上游新增 `permission` 行（`@deepseek-ai/dsh-permission-presets`），它按「组合后的 sandbox + approval」反查预设表，而预设 `danger-full-access` 的定义正是这两者的组合；只改 sandbox 会让它匹配不到任何预设（该行不激活并报警）。

## ❓ 常见问题

- **页面白屏 / 打不开**：确认在 Termux 里跑；看 `~/dsh/storage/dsh.log`。
- **直接开 `127.0.0.1:3080` 显示 401**：正常，新版需要带 token URL，用 `bash ~/dsh/start_dsh.sh`。
- **`dsh web` 报 `dsh: startup failed: … listen EADDRINUSE: address already in use 127.0.0.1:3080`**：3080 上已经有 dsh web 在跑（token 是进程级的，再起一个只会失败）。日常用 `bash ~/dsh/start_dsh.sh`：能复用就复用；占用端口的进程如果本会话看不到（另一个用户/应用、`su` 启动、别的终端会话），脚本会立刻打印「端口 3080 已被 … 占用」+ 三条做法，不会再白拉起一个实例、也不空等 90s 后打开一个 401 页面。想并行跑第二个就换端口：`DSH_PORT=3081 bash ~/dsh/start_dsh.sh`。
- **`dsh web` 起来后很快退出 / 日志里有 `startup failed` / profile YAML 报 `YAMLException`**：`start_dsh.sh` 会在进程退出或日志出现 `startup failed` 时**立刻**报出原因（不再等满 `DSH_READY_TIMEOUT`），并打印日志末尾与 `~/.dsh/logs/startup-*.log` 路径。
- **`stop_dsh.sh` 说「已停止」，但浏览器还能打开 3080**：停止只杀本会话可见的进程；若端口仍有响应，脚本会在 stderr 提醒「占用它的进程本机看不到、不受本脚本管理」，需要到启动它的窗口结束它（或换 `DSH_PORT`）。
- **浏览器落在了裸地址**：多半是 PWA 劫持，试 `DSH_ORIGIN=localhost`；`DSH_HINTS=1 bash ~/dsh/start_dsh.sh` 会打印三条排查办法。
- **没有用 Via 打开**：确认 Via 包名为 `mark.via`（不同渠道包名可能不同），可用 `DSH_VIA_APP=<包名>` 指定。
- **模型没反应**：检查 Models 页的 API Key 与 `~/.dsh/.credentials.yaml`。
- **手机上排版难受 / 软键盘挡住输入框 / 某些按钮点不动**：这是上游 Web UI 按桌面排版的固有行为，本仓库不再注入前端 CSS/JS。可安装社区插件 `dsh-android-ui`，见「📱 手机界面适配（可选）」。
- **升级 dsh 后 dsh 起不来，日志报 `No usable native binding found`**：0.1.7 起上游新增原生 addon 家族但没发 android 预编译包。重跑 `bash setup.sh`（会补 `node-addon-require-builtin-android-arm64` 平台包）即可。
- **升级到 0.2.1 后首次启动，profile 里少了一个 bundle / 日志提到迁移**：0.2.1 的 `RETIRED_BUNDLES` 迁移会自动把 `dsh-experimental-schedule-bundle` 从旧 profile 里摘除——**正常行为，不是错误**，不用手动加回。
- **`dsh plugin …` / 插件市场报找不到 pnpm，或 pnpm 报 `ERR_PNPM_STORE_DIR_ACQUIRE_OPERATION_LOCK`**：dsh ≥0.2.1 的插件功能运行期会从 PATH 调用 pnpm，而 pnpm 12 在 Android 上不可用。先 `command -v pnpm && pnpm --version` 确认解析到的是 **11.x**；需要时用 `npm install -g pnpm@11`，或让 `~/bin/pnpm` 的 11.x 包装在 PATH 中优先（见「pnpm 运行时（插件功能依赖）」）。
- **`bash setup.sh --pnpm` 报「参数已废弃」**：pnpm 安装方式已移除，安装方式只有 `npm install -g`；直接跑 `bash setup.sh`（要钉版本用 `DSH_VERSION=<ver> bash setup.sh`）。
- **`bad interpreter: /usr/bin/env` / `npm: not found`**：Termux 的 `/usr/bin` 不可解析，而 npm 的 shebang 是 `#!/usr/bin/env node`。`setup.sh` 已自动改用 `node npm-cli.js` 调用；若你自己敲 `npm` 报这个错，用 `node "$(readlink -f "$(command -v npm)")" …` 代替。
- **直接 `npm -g update` 时 koffi 报 `statx` / `__u32` / `const char *` 编译错误，或升级后 dsh 起不来**：`npm -g update` 不经过 `setup.sh`，既没有 Android 编译参数，也不会重打安装期补丁（dsh 现在是原生全局安装，会被它直接升级/重装）。升级或修复 dsh 请跑 `bash setup.sh`；已经跑坏的话重跑同一脚本即可恢复。
- **升级 dsh / Node 后异常**：重跑 `bash setup.sh`。
- **换机 / 重装**：重跑 `bash setup.sh` 即可。

## 🧪 兼容性 / Compatibility

- **作者实测**：Huawei Mate 60（ALN-AL80），HarmonyOS 4.2.0（build 4.2.0.186），**无 root**，Termux（Node v26，aarch64），deepseek-harness **`0.2.1-rc.5`**（本机 `bash setup.sh` 实跑：耗时 3m18s、npm 报 `added 3 / removed 4 / changed 605 packages`、全部补丁命中且锚点零改动、冷启动 13.9s、303→cookie→200、日志零 warn/error；撰写时点）。`0.2.0-rc.2` 与 `0.1.7-rc.2` 线亦通过（回退验证）。**2026-11-08 升级实测**：设备升级到 `0.2.2-rc.1` 并迁移到原生全局布局；`01` 与 link 补丁按 0.2.2 重锚后 js-patches（21）、guards（39）夹具全绿，静态契约 39 条全绿。
- **0.2.1 相对 0.2.0 的变化**（已核对，对补丁/配置的影响）：
  - 依赖闭包 **532 → 604 个包**（rc.2 时点；rc.5 本机实测约 605，差额来自本项目的自补包），直接依赖 **+10/−6**；新增 11 个实验性 bundle、`dsh-plugin-manager`、`dsh-plugin-market*`、`dsh-tool-schedule/terminal/session-query`、`dsh-session-query-sqlite`（用 `node:sqlite`，Node 26 可用）等；移除 `dsh-webhook(-github)`、`dsh-hooks-codex/claude-code`、`dsh-tool-ralph`、`dsh-experimental-schedule-bundle`、`dsh-client-store/ui-primitives/ui-slots`、`dsh-invariants`、`dsh-hook-protocol`、`dsh-subagent-in-process-driver`。
  - `OPTIONAL_BUNDLES` **4 → 12**（rc.2 时点，全部是实验性 bundle、默认不启用；rc.5 未逐项复核）；Web 默认 bundle 不变；**所有现有补丁锚点全在、无需改动**。
  - 版本敏感项：`cordis` 4.0.5、`chokidar` 5（要求 Node ≥20.19，Node 26 满足）、`openai` 7.x、`pi-ai` 1.3；不变项：`koffi` 3.1.1、`node-pty` 1.2.0-beta.15、`sharp` 0.35.5、`node-addon-system` 0.1.2、`node-addon-require-builtin`/`native-custom-loader` 0.1.9。
  - `0.2.1-rc.5` 复核（本机实跑）：锚点仍**零改动**，`chokidar 5.0.0` / `openai 7.19.0` 与上面一致，`koffi`/`node-pty`/`sharp`/addon 家族版本全部不变；权限层两条仍与 `permission` 预设匹配（启动零告警）。
  - 上游 0.2.1 启动时会通过 `RETIRED_BUNDLES` 迁移**自动从旧 profile 摘除 `dsh-experimental-schedule-bundle`**——这是正常的迁移，不是错误。
  - 潜伏风险（默认不触发）：`sherpa-onnx-node`（语音输入，需手动启用实验性 bundle）与 `libreoffice-kit`（没有 android 平台包，office→pdf 可能不可用）。
- **升级方式**：`cd` 到仓库 → `bash setup.sh`（安装方式只有 npm，见「安装方式：npm」）→ `bash ~/dsh/restart_dsh_now.sh` 重启 GUI。脚本默认跟随 npm `latest`，要钉版本用 `DSH_VERSION=<ver> bash setup.sh`。**dsh 是原生全局安装，`npm -g update` 会升级/覆盖它并丢失安装期补丁**；升级 dsh 必须运行 `bash setup.sh`（旧版 hold 布局会在安装时自动迁移，成功后提示清理旧安装树）。
- 不同机型 / ROM 可能有差异：部分 ROM 通过 SELinux 禁用 `link()`、命名空间沙箱权限不同、bwrap/landlock 可用性不同等。
- `setup.sh` 覆盖通用 Android 场景，个别机型可能仍需额外适配。

**欢迎提 Issue / PR 适配更多环境**：<https://github.com/FunnelCakes/deepseek-harness-android/issues>

## 📚 参考

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- [Xieansecn/dsh-android-ui — 手机界面适配组合包插件（可选的第三方插件，见「📱 手机界面适配」）](https://github.com/Xieansecn/dsh-android-ui)
- [Discussion #136 — Android/Termux 部署](https://github.com/deepseek-ai/deepseek-harness/discussions/136)
- [Discussion #248 — Android 禁 hardlink（link→rename 提案）](https://github.com/deepseek-ai/deepseek-harness/discussions/248)
- [Termux Wiki](https://wiki.termux.com/)

---

# 🇬🇧 English docs

## What is this

Run **DeepSeek Harness** (`@deepseek-ai/dsh`, DeepSeek's official agent harness, Claude Code–like) **natively on Android**. Drive it from your phone browser via the Web UI at `http://127.0.0.1:3080`; the agent can run real bash commands, read/write files, and run builds on the device.

This repository is **not dsh's source code** — it is an **installer + Android compatibility patch set**:

- `setup.sh` installs upstream `@deepseek-ai/dsh` into Termux and applies every Android patch automatically;
- patches rewrite the files **already installed at** `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`;
- it also ships start/stop/restart scripts and a `danger-full-access` config layer.

> [!TIP]
> In one line: upstream dsh only publishes linux/darwin artifacts; this project makes it run on **non-rooted Android**.

## ✨ Features

| | Feature |
|---|---|
| 🚀 | One command for install + all Android patches (idempotent, safe to re-run) |
| 🧰 | One install backend: **npm** (`npm install -g`, command unchanged from earlier versions), plus the `2.5/9` pnpm runtime provisioning step (a runtime dependency of dsh's plugin features) |
| 🧩 | Native addon adaptation: node-pty / koffi / sharp / ripgrep / flock / node-addon-require-builtin |
| 🔗 | No-hardlink (SELinux blocks `link()`) fix: sessions, attachments, tool file writes all work |
| 🔐 | New Web auth support: extracts the tokenized launch URL and verifies it before handing it to the browser |
| 🌐 | Opens **Via** browser by package name by default, falls back to the system default browser |
| 📱 | Optional: the community plugin **dsh-android-ui** adapts the UI for phones (notch, soft keyboard, drawer sidebar) — one command into the `web` profile (see "📱 Mobile UI (optional)") |
| ⚡ | Zero-poll startup wait (streams the log); reusing a running service takes ~0.2s |
| 🎨 | Live status line + colored output during install; raw logs kept on disk for debugging |

## 📋 Requirements

- **Android phone + [Termux](https://f-droid.org/en/packages/com.termux/)** (F-Droid or GitHub build — do **NOT** use the outdated Google Play version)
- No root required; aarch64 device (author tested: Huawei Mate 60 / HarmonyOS 4.2 / Node v26)
- ~1 GB free space recommended (npm deps + build cache)

## 🚀 Quick start

### 1. Install Termux and update

```bash
pkg update -y && pkg upgrade -y
```

### 2. Clone and install

```bash
pkg install -y git
git clone https://github.com/FunnelCakes/deepseek-harness-android.git
cd deepseek-harness-android
bash setup.sh            # 5–15 min on first run; add --verbose for raw output
```

> [!NOTE]
> `setup.sh` benchmarks npm / nodejs.org and **switches to the npmmirror registry when they are slow** (session-only; your global config is untouched).

### 3. Start and use

```bash
bash ~/dsh/start_dsh.sh     # start the service and open the tokenized page in Via
```

Then open the **Models** page in the Web UI and enter your **DeepSeek API Key** (stored at `~/.dsh/.credentials.yaml`, mode 0600).

### 4. Everyday commands

```bash
bash ~/dsh/start_dsh.sh       # start / reuse the service and open the browser
bash ~/dsh/stop_dsh.sh        # stop
bash ~/dsh/restart_dsh_now.sh # restart (does not open a browser)
bash setup.sh                 # must re-run after upgrading dsh or Node
bash npm_android.sh -g update # for other global packages only: injects the Android target; use setup.sh to upgrade dsh
```

> [!IMPORTANT]
> **Never run `npm -g update` directly in this environment**: it bypasses `setup.sh` and therefore does not set `CFLAGS/CXXFLAGS=-target aarch64-linux-android30`. When dsh's koffi 3.1.1 falls back to a local build, bionic only declares `statx()` for API 30, so the compiler reports `__u32` / `const char *` errors. Use `bash npm_android.sh <npm args…>` for any manual npm operation. **dsh is now a native global install, so `npm -g update` will upgrade/overwrite it and lose the install-time patches**; use `bash setup.sh` to upgrade dsh.
>
> dsh now lives **directly in npm's default global directory** (`/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`, a real directory, not a symlink). npm has no way to "hold" a single global package: bare `npm -g update` **will** upgrade/reinstall dsh and drop the install-time patches (the node-addon platform package, link/flock fixes, JS perf patches…), and may also fail on koffi's fallback build without the Android target. Therefore **upgrade/repair dsh only via `bash setup.sh`**; if `npm -g update` was run by accident, re-running `bash setup.sh` restores everything. When migrating from the old hold layout, the script removes the stale symlink and prints the cleanup command for the old install tree.

> [!WARNING]
> **Do not open `http://127.0.0.1:3080` directly**: recent dsh versions require the **tokenized launch URL** to exchange for the auth cookie — the bare URL returns 401. Always use `start_dsh.sh`, which reads the current process's token from the log and only hands it to the browser after verifying it returns 303.

> [!NOTE]
> Running `dsh web` directly and getting `dsh: startup failed: … listen EADDRINUSE: address already in use 127.0.0.1:3080` means **another dsh web instance already owns the port** (tokens are per-process, so a second instance can only fail). `start_dsh.sh` reuses the running instance; if the process holding the port is invisible to this session (another user/app, started under `su`, another terminal session) it explains that within a second and offers "stop the old instance" / `DSH_PORT=3081` instead of spawning a doomed duplicate and sitting out the full timeout.

## ⚙️ Usage & configuration

### Install backend: npm

There is exactly one backend: `npm install -g` (the command is byte-for-byte the same as in earlier versions). A separate `2.5/9` **pnpm runtime provisioning** step remains, because dsh ≥0.2.1's plugin features depend on pnpm at runtime (when a working pnpm 11.x is already on PATH it only reports `[OK]` and writes nothing).

> A second backend, `--pnpm` (non-global pnpm 11 project install migrated into the canonical `DSH_DIR`), used to exist. Its output was item-for-item identical to the npm layout while requiring extra version-line checks and conflict preflights, so it was removed. `--pnpm` / `--npm` now print a deprecation notice and exit 1 rather than silently falling back to npm.

> ⚠️ **pnpm 12 does not work on Android** — use **pnpm 11.x only**. Also, **dsh ≥0.2.1's plugin features (`dsh plugin …` / plugin market) shell out to `pnpm` from PATH at runtime**, so plugins need a working pnpm 11 — see "pnpm runtime (plugin dependency)" below.

### pnpm runtime (plugin dependency)

Since dsh 0.2.1 the plugin manager (`dsh plugin …` / plugin market) runs `execa("pnpm")` from PATH, so **pnpm 11.x is not just an installer but a runtime dependency**. `setup.sh` adds a `2.5/9 pnpm runtime` step (idempotent):

The preflight **hardcodes neither a pnpm path nor a version**: it probes **every `pnpm` on PATH** (PATH order is priority), `~/.local/share/pnpm-pin`, `PNPM_HOME` and the npm global dir, runs `--version` on each, and accepts **11.x only**. Then one of four outcomes:

- **A working 11.x is first on PATH** → reused, **no files written**.
- **A working 11.x exists elsewhere** (probed pin dir / `PNPM_HOME` / npm-global 11.x) → **reused**: wrappers are written to point at that entry, **nothing is downloaded**.
- **Only unusable pnpm (12.x / <11 / broken entry), but `~/bin` is on PATH and ahead of it** → installs `pnpm@11.27.1` into `~/.local/share/pnpm-pin` via `npm --prefix` (pure **JS build**, no native exe), writes the four `~/bin/{pnpm,pn,pnpx,pnx}` wrappers and **shadows** the broken one; then verifies `~/bin/pnpm --version` is 11.x and that PATH resolves to it.
- **No usable version and no way to shadow** (`~/bin` not on PATH, or after the broken pnpm) → **stops with a diagnosis**: lists every pnpm found with its version, why it is unusable, three concrete fixes (`npm install -g pnpm@11` / `npm uninstall -g pnpm` / reorder PATH), and states that this step is read-only. **Re-running `bash setup.sh` after the fix simply works** (a fixture case pins this).
- **Our wrapper is broken** → repaired automatically; **an equivalent wrapper** (hand-written pin wrapper) → claimed, not overwritten; **someone else's non-equivalent wrapper** → refused (force with `DSH_PNPM_CONFLICT_OVERRIDE=1`; old file backed up as `.dsh-android.bak`).
- **The wrapper dir is not on PATH** → prints Chinese remediation and exits 1 (dsh's `execa("pnpm")` would not see it): add `export PATH="$HOME/bin:$PATH"` to `~/.bashrc` and reopen the terminal.
- A shadowed npm-global pnpm 12 is only warned about (it does not block this run).
- **npm `strict-allow-scripts=true`** → configuration conflict, exits 1 and tells you to set it back to `false` (otherwise koffi in `SKIP_SCRIPTS` aborts the whole npm install).
- Tunables: `DSH_PNPM_PIN_DIR` (default `~/.local/share/pnpm-pin`), `DSH_PNPM_WRAPPER_DIR` (default `~/bin`), `DSH_PNPM_VERSION` (default `11.27.1`). **Do not raise `DSH_PNPM_VERSION` to 12.x** (it does not work on Android); 11.28+ may also switch back to downloading a native binary.
- To run this step alone (troubleshooting/re-provision): `DSH_SETUP_PROVISION_ONLY=1 bash setup.sh` (a **test/troubleshooting hook**; it does not install dsh).

> `~/bin` must come before `$PREFIX/bin` in PATH (Termux's default usually has it earlier); keep the broken pnpm 12 shadowed rather than deleting it if other tools rely on it.

### Script options

| Script | Option | Description |
|---|---|---|
| `setup.sh` | `--verbose` / `SETUP_VERBOSE=1` | Stream raw sub-command output (default shows a summary; raw log goes to `~/dsh/setup.log`) |
| | `--pnpm` / `--npm` | **Deprecated**: npm is the only backend; passing either prints a deprecation notice and exits 1 |
| `start_dsh.sh` | `--no-open` | Start the service, print the tokenized URL, do not open a browser |
| | `DSH_NO_OPEN=1` | Same as above (env form) |

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `DSH_READY_TIMEOUT` | `90` | Max seconds to wait for the tokenized URL (cold start ~12s patched, ~22s unpatched; kept generous) |
| `DSH_STOP_GRACE` | `1.5` | Seconds dsh gets to exit gracefully; after that a second `SIGTERM` is sent (dsh's own "second signal quits now", measured 0.17s). Raise it (e.g. `6`) to let it finish disposing |
| `DSH_STOP_TIMEOUT` | `6` | After that second `SIGTERM`, how long to wait before the `SIGKILL` fallback |
| `DSH_HINTS` | `0` | `1` makes the start script print the PWA troubleshooting hints and try copying the URL to the clipboard (silent by default) |
| `DSH_VIA_APP` | `mark.via` | Browser package to prefer (Via) |
| `DSH_OPEN_APP` | empty | Force a browser package/component (highest priority), e.g. `com.android.chrome` |
| `DSH_OPEN_CHOOSER` | `0` | Set to `1` to show the system app chooser |
| `DSH_ORIGIN` | `127.0.0.1` | Origin handed to the browser; `localhost` avoids PWA hijacking of `?token=` |
| `DSH_PORT` | `3080` | Service port (`start_dsh.sh` passes it to dsh as `--port`; dsh itself does not read this env var) |
| `NO_COLOR` | empty | Non-empty disables colored output |
| `DSH_VERSION` | empty (npm `latest`) | Pin **only** for canary/rollback: `DSH_VERSION=<ver> bash setup.sh`, with `<ver>` from `npm view @deepseek-ai/dsh versions`. Leave it empty by default — hardcoding a version blocks upgrades |
| `DSH_PNPM_PIN_DIR` | `~/.local/share/pnpm-pin` | Where `2.5/9` installs pnpm 11 (JS build) via `npm --prefix` |
| `DSH_PNPM_WRAPPER_DIR` | `~/bin` | Where `2.5/9` writes the `pnpm`/`pn`/`pnpx`/`pnx` wrappers; **must be on PATH** so dsh's child process can find them |
| `DSH_PNPM_VERSION` | `11.27.1` | pnpm version `2.5/9` installs **when a download is needed** (an existing usable 11.x is reused instead); **do not raise to 12.x** (broken on Android) |
| `DSH_PNPM_CONFLICT_OVERRIDE` | `0` | pnpm runtime: force past **coexistence conflicts** such as a user's own pnpm wrapper (old wrapper backed up as `.dsh-android.bak`); pnpm version conflicts are **not** overridable |

> `DSH_SETUP_PREFIX` / `DSH_SETUP_PREFLIGHT_ONLY` / `DSH_SETUP_PROVISION_ONLY` are **test-fixture/troubleshooting hooks** (replace the prefix / preflight only / pnpm runtime provisioning only). **Do not set them in production.**

### Browser open order

1. `DSH_OPEN_APP=<pkg>` (explicit override)
2. **Via** (default `mark.via`) — opened by package name via `am start`, which also dodges PWA hijacking
3. System default browser (`termux-open-url` without a package)
4. The app chooser, only when `DSH_OPEN_CHOOSER=1`

```bash
# examples
DSH_OPEN_APP=com.android.chrome bash ~/dsh/start_dsh.sh   # force Chrome
DSH_ORIGIN=localhost bash ~/dsh/start_dsh.sh              # dodge PWA hijacking
DSH_NO_OPEN=1 bash ~/dsh/start_dsh.sh                     # print the URL only
```

## 📱 Mobile UI (optional)

dsh's Web UI is laid out for desktop browsers: the notch covers the top, the soft keyboard hides the composer, the sidebar squeezes the text, and a few buttons are wired to hover paths only (so taps do nothing). **None of that is in this repo's scope** — this project only guarantees the startup/auth chain and backend compatibility and **injects no front-end CSS/JS** (it used to via `apply-frontend.sh`; that was deleted because it keyed off upstream hashed class names and drifted on every upgrade — see the note at the end of "How it works").

For a phone-friendly UI, install the community composition-package plugin **[Xieansecn/dsh-android-ui](https://github.com/Xieansecn/dsh-android-ui)** (an official plugin, it touches no dsh product file):

```bash
# 1) install into the web profile (dsh uses pnpm under the hood; needs git + network)
dsh plugin --profile web add github:Xieansecn/dsh-android-ui

# 2) verify the composition layer is mounted — you should see "# == dsh-android-ui"
dsh --profile web --dump-config | grep -A2 dsh-android-ui

# 3) the Node half is read into memory at boot: a page refresh is not enough, restart
bash ~/dsh/restart_dsh_now.sh
```

Uninstall (pnpm again; restart afterwards too):

```bash
dsh plugin --profile web remove dsh-android-ui
bash ~/dsh/restart_dsh_now.sh
```

What it does (see its own README): rewrites `viewport` in place to `viewport-fit=cover` + `interactive-widget=resizes-content` (keeps content out of the notch, lets the IME shrink the content area instead of covering it), mobile CSS (sidebar becomes a drawer, safe-area padding, recomposed composer, fullscreen settings), boot-time polyfills (`AbortSignal.any` / `crypto.randomUUID` — old WebViews fail to boot without them), and runtime effects (keyboard following, floating sidebar toggle, touch fallbacks). It also ships an **optional one-shot script** that flips the PWA manifest from `display: fullscreen` to `standalone` (a manifest is a static JSON the browser fetches itself, so a runtime plugin cannot rewrite it; skip this if you only use a browser, without installing the PWA).

Caveats:

- **Third-party plugin, not part of this project**: we neither bundle nor modify it; version compatibility and bug reports belong to its own repo.
- **Its hashed class names were verified against dsh `0.1.7-rc.2`, and hashed names drift with each upstream release — failing *silently*** (the page works, the effects are simply gone). After upgrading dsh, upgrade/reinstall it too, or uninstall first to attribute the problem correctly; `bash setup.sh` will not do that for you, it only patches the backend.
- **The two are independent**: `setup.sh` step 7 only *merges* the permission layer into `~/.dsh/profiles/web/cordis.patch.yml` — replacing dsh's empty-array template, or appending when you already have your own layers — and never overwrites other config layers in the profile, so re-running `setup.sh` after installing the plugin is fine.
- **"Enter = newline" is not in that plugin**: that key mapping requires patching the product package and stays in this repo's `setup.sh` (see the table under "How it works" below); the plugin only provides `enterkeyhint=newline`.
- **Only meaningful for the `web` profile**; `tui` / `headless` are unaffected.
- **The auth chain is unchanged**: still open the tokenized URL via `bash ~/dsh/start_dsh.sh`; the bare URL still returns 401.

## 🔧 How it works: what setup.sh fixes

Upstream `@deepseek-ai/dsh` ships linux/darwin prebuilds only and assumes a full Linux namespace sandbox plus hardlink support. On Android/bionic, the following adaptations are needed — **all applied automatically and idempotently by `setup.sh`**:

| Issue | Symptom | Fix |
|---|---|---|
| node-pty build fails | `Undefined variable android_ndk_path` | patch node-gyp cache `common.gypi` |
| **koffi native module unavailable** | since 0.2.0-rc.2 `koffi` is pinned to **exactly 3.1.1**; `@koromix/koffi-android-arm64` only exists from 3.2.1, and 3.1.1's install script self-heals into a local build (which historically died on the bionic-vs-glibc `statx` prototype mismatch) | still **kept out of `--allow-scripts`** (`setup.sh`'s `SKIP_SCRIPTS`): under npm 12 a *failing allowlisted* script aborts the whole install, while a blocked one is only warned about and skipped. ⚠️ **Measured correction on this device**: its npm is **11.21.1**, whose `--allow-scripts=<list>` is **advisory** (unlisted package scripts still run, only a warning is printed; only `strict-allow-scripts` is a hard error), so koffi's install script **actually runs and compiles successfully** here (`koffi.load('libc.so')` loads) — the old "the build always fails" claim does **not** reproduce on this device. Either way, every koffi call site in dsh is lazy and gated on `platform === "win32"`, so Android never needs it at runtime. ⚠️ dsh is now a **native global install**: `npm -g update` reinstalls dsh's dependencies and bypasses this project's Android compile flags and install-time patches, so upgrading/repairing dsh must go through `bash setup.sh` (use `bash npm_android.sh …` when manually installing other packages that need the Android target) |
| npm build-script approval differs by version | the same allowlist behaves differently on npm 11 vs 12: npm 11 (11.21.1 here) treats `--allow-scripts` as **advisory** (unlisted scripts still run, with a warning), while npm 12 enforces the list | `setup.sh` still allowlists only packages whose build **can** succeed on Android and keeps koffi in `SKIP_SCRIPTS`: on npm 12 koffi can no longer kill the whole install, and on npm 11 the result is the same (koffi may build, but there is no runtime call site). If you set `strict-allow-scripts=true` yourself, unlisted scripts become hard errors — the installer's preflight treats that as an install conflict, prints remediation and exits early |
| `link()` blocked by SELinux | `EACCES` saving sessions/attachments, migrating sessions, and when the `write` tool creates a file | session-log publish uses `rename()`; no-replace paths fall back to "O_EXCL reserve + rename"; attachment walks/cleanup tolerate `EACCES`/`ENOENT` |
| `flock` unavailable | `flock is not supported on android-arm64` when sending a message | compile `node-addon-system`'s bundled `src/flock.c` with clang into a local `system.node` and load it from `lib/flock.js` on android (with a real lock self-test) |
| **dsh ≥0.1.7 won't start at all** | `No usable native binding found for node-addon-require-builtin-android-arm64`, `host preparation failed` | upstream's new native-addon family ships darwin/linux/win32 prebuilds only, none for android. Add a `node-addon-require-builtin-android-arm64` platform package (pure-JS implementation, relying on the `--expose-internals` the wrapper already sets) with a built-in `internalModules()` self-test (the suffix follows the device arch, e.g. `-android-arm` on armv7) |
| **`dsh web` won't start: `YAMLException: end of the stream or a document separator is expected`** | the error points at *our own* `- id: sandbox-policy` entry inside `~/.dsh/profiles/web/cordis.patch.yml` (e.g. `(13:1)`) | on its first boot — even a failed one — dsh writes its own profile template: three comment lines plus an **empty-array document** (`[]`). The old `setup.sh` only grepped for `danger-full-access` and then appended the permission layer, so a sequence item followed an already-closed YAML document and the whole profile became unparsable. `patches/apply-profile-patch.js` now classifies the file first: empty-array template → **replace**, real config layers → **append**, a stray `[]` → **strip that document line** (in-place repair); every write is validated before and after with dsh's own `loadOverlayPatches()`, and an unparsable file is left byte-for-byte untouched (fixture: 30 assertions) |
| **log shows `permission: composed sandbox and approval defaults match no preset`, `1 entry did not activate`** | the 0.2.0-only `permission` row (`@deepseek-ai/dsh-permission-presets`) refuses to activate: bash still works, but the permission-preset service is missing | that row derives a preset from the composed sandbox + approval pair, and its `danger-full-access` preset *is* that pair; changing only the sandbox while approval stays at the baseline `ask` matches nothing. The layer now ships **both entries**; re-run `bash setup.sh` to append the missing one |
| PTY terminal detection fails | `unsupported on platform android` | treat `android` as `linux` in subprocess (the anchor may live in a content-hashed bundle, so `lib/` is glob-scanned) |
| Enter sends instead of a newline | cannot type multi-line input | patch `dsh-client-ui-conversation`: Enter = newline, `Ctrl/Cmd+Enter` = send (rolls back and aborts the install on failure; the 4-boot platform package, ripgrep and the 3/9 npm install also abort) |
| sharp fails to load | `Could not load sharp module` | install the `@img/sharp-wasm32` wasm fallback (plus `@emnapi/runtime`) |
| grep/glob: `ripgrep launch failed` | no Android prebuild from `@vscode/ripgrep` | symlink system `rg` + patch the `resolveRgPath()` fallback |
| HMR crashes on start | `--expose-internals is required` | rebuild the `dsh` wrapper with `--expose-internals --no-warnings` |
| bash tool unavailable | `SANDBOX_UNAVAILABLE` | write the `danger-full-access` config layer (see Security) |
| Full reload re-downloads JS | every refresh re-fetched all of `/assets/` (~4.5MB measured here) | immutable cache headers for `/assets/` |
| Cold start takes tens of seconds | the port answers 401 long before the tokenized URL is printed | `dsh-client-modules` recomposes the whole client-plugin graph ~10x during boot and eagerly prebuilds a per-record artifact for every client bundle: upstream made combos lazy natively (`lazyBody`) in 0.1.7, patch `02` did the same for the 0.1.5 line (measured cold start 22.6s → 12.5s, byte-identical artifacts), and `03` turns that line count into an index loop |

> [!NOTE]
> Three upstream JS patches remain: `01-frontend-static-cache` (immutable cache headers for content-hashed `/assets/`; ⚠️ since 0.2.2 upstream natively sends `no-cache` + ETag + 304 for every non-index file, so the patch only upgrades `/assets/` to immutable and keeps upstream behaviour elsewhere), `02-client-modules-lazy-compose` (lazy client combos) and `03-client-modules-newline-count` (`newlineCount` switched to an index loop; measured 302ms→60ms on 10.8MB).
> `01`/`02` target the 0.1.5 line; upstream implemented combo laziness natively (`lazyBody`) in 0.1.7, so `02` is deprecated (upstream's native `lazyBody` replaces it) and reported as `[deprecated]` rather than a failure (step 8/9 no longer warns), while the version-agnostic `03` keeps that hotspot fast. The old history-slimming patches (apiproxy history slim, incremental resync, connection schema, plugin-bundle cache) targeted host modules that were removed upstream or are now native, so those files and the "superseded" machinery were deleted. All three patches were diffed byte-for-byte against the corresponding npm sources.

> [!IMPORTANT]
> **This repo injects no front-end UI code**: no CSS/JS injection, no edits to `dsh-web-frontend`'s viewport or PWA manifest. It used to (`apply-frontend.sh` + `patches/mobile.css`/`mobile.js`), but that keyed off hashed class names and the DOM structure of upstream build output, so it **drifted on every dsh upgrade** and conflicted with the "minimal text replacement only" rule — it was deleted. Report front-end issues upstream; for a phone-friendly UI install the optional plugin (see "📱 Mobile UI (optional)"). The single exception is the composer key mapping (`dsh-client-ui-conversation`: Enter = newline, `Ctrl/Cmd+Enter` = send), which changes key handling rather than styling and is still applied by anchor with a rollback on mismatch.

## 🗂 Architecture & install steps

### Install steps (the 9 steps of `setup.sh`)

> Before any install action a read-only **pnpm runtime preflight** runs, and `2.5/9` provisions it (see "pnpm runtime (plugin dependency)"). The dsh install itself is the unchanged `npm install -g` command; there is no extra install-conflict preflight.

| Step | What it does |
|---|---|
| `0/9` | Anchor pre-check: confirm patch markers still exist (catch version drift early) |
| `1/9` | Install build deps: `cmake clang make binutils pkg-config python nodejs ripgrep` |
| `2/9` | Prepare Node headers: **use Termux's own `$PREFIX/include/node` and skip the download when present** (node-gyp falls back to `process.config.variables.node_prefix` without `--nodedir`); otherwise `npx node-gyp install` (npmmirror when slow) and patch `android_ndk_path` into the cached `common.gypi` |
| `2.5/9` | **pnpm runtime** (dsh plugin dependency): reuse a working pnpm 11.x already on PATH, otherwise `npm --prefix ~/.local/share/pnpm-pin install pnpm@11.27.1` (JS build) and write the `~/bin/{pnpm,pn,pnpx,pnx}` wrappers — idempotent |
| `3/9` | Install dsh: `npm install -g` **directly into npm's default global directory** (an old hold symlink and the old `dsh` wrapper are removed/moved aside beforehand and restored on failure; android30 target; `--allow-scripts` covers only native packages whose build **can** succeed on Android — koffi stays in `SKIP_SCRIPTS` so npm 12 merely warns, because a failing allowlisted script aborts the whole install; npm 11 treats `--allow-scripts` as advisory). Afterwards: verify the node-pty artifact, run the install-script allowlist self-check, and report the effective `allow-scripts` policy (advisory / strict) |
| `4/9` | Backend patches: `node-addon-require-builtin` android platform package (>=0.1.7 boot prerequisite, aborts the install on failure), link→rename fallback, native flock binding, subprocess platform detection (android≡linux), composer Enter = newline, grep/glob ripgrep fix |
| `5/9` | sharp wasm fallback (attachments depend on it), immediately followed by the hardlink verification (real run in a temp dir, never touches your sessions; it must come after the wasm fallback or the attachment module's `import sharp` fails and reports a false negative) |
| `6/9` | Rebuild the `dsh` wrapper (`--expose-internals`, atomic `mv` replace that never follows the symlink target) |
| `7/9` | Write start/stop/restart scripts into `~/dsh/`; install the permission layer through `patches/apply-profile-patch.js` (**two** entries: `sandbox-policy` + `approval`; empty-array template → replace, existing layers → append only what is missing, stray `[]` → in-place repair; validated before and after with dsh's own parser, and the install aborts rather than leaving a profile that cannot boot) |
| `8/9` | JS performance patches (`01` static-asset cache headers / `02` lazy client combos / `03` index-loop newlineCount; an anchor mismatch only warns) |
| `9/9` | Summary |

### Auth & startup flow

```text
setup.sh                install + patch + generate scripts
   │
   ├─ ~/dsh/start_dsh.sh        start/reuse dsh web, fetch the tokenized URL, open the browser
   ├─ ~/dsh/stop_dsh.sh         stop safely (pid file + identity re-check)
   └─ ~/dsh/restart_dsh_now.sh  reuse stop + start (--no-open)
        │
        └─ dsh web (node bin.js, 127.0.0.1:3080)
             ├─ generates an in-memory launch token and logs:
             │    dsh web: http://127.0.0.1:3080/?token=...
             ├─ browser opens that URL → 303 + Set-Cookie (signed cookie)
             └─ afterwards both / and /api authenticate via the cookie
```

Key behaviours of `start_dsh.sh`:

- **Waits by streaming the log** (`tail -f`): returns the moment the token appears, with no per-second `grep`+`curl` polling;
- the token must return **303/302** from `curl` before it is handed to the browser, so a stale token from a previous process can never cause a 401;
- if no valid token arrives, it falls back to the bare URL and prints the **specific reason** (`no-token` or the actual HTTP code);
- **probes the port before launching**: if it is already answering but no dsh process is visible (another user/app, `su`, another session), it **never spawns a doomed second instance** — it reports who holds the port and offers "stop the old one / `DSH_PORT=3081`";
- **reports boot failures immediately**: when the log says `startup failed` or the process exits before printing a token, it prints the reason and the log tail right away (no more waiting out `DSH_READY_TIMEOUT` or handing out a 401 bare URL as success);
- reusing a running service takes ~**0.2s**; a cold start costs ~**9.1s** script-side, of which ~9s is dsh's own plugin-loader settle (not removable from the script).
- **every run ends with `[dsh] 本次耗时 X.XX 秒`** (two decimals; reuse / cold start / fallback / failure / interrupt all print it exactly once from an EXIT trap; bash uses the built-in `EPOCHREALTIME`, so no extra forks).
- **the "running instance not ready → auto-restart" path actually works**: `wait_for_token()` resets its FIFO and marker files on every call, so it can wait a second time after the restart (previously the second `mkfifo ""` always failed and the restart ended in an immediate "启动超时"; fixture case 12 pins this).

## 📁 Repository layout

```text
deepseek-harness-android/
├── setup.sh                     # main entry: install dsh (`npm install -g`) + all Android patches (idempotent)
├── apply-js-patches.sh          # apply the JS perf patches (cache headers / lazy combos / newlineCount)
├── apply-rg-fix.sh              # fix "ripgrep launch failed"
├── start_dsh.sh                 # start/reuse service + fetch token + open browser (Via first)
├── stop_dsh.sh                  # safe stop (pid identity re-check + port release confirm)
├── restart_dsh_now.sh           # restart (reuses stop + start --no-open)
├── config/
│   └── cordis.patch.yml         # danger-full-access layer (merged into ~/.dsh/profiles/web/ by patches/apply-profile-patch.js)
├── patches/
│   ├── 01~03-*.patch            # JS patch sources (cache headers / lazy client combos / newlineCount)
│   ├── patch-dsh-android-link.js    # no-hardlink fix (rename / O_EXCL+rename fallback)
│   ├── patch-dsh-android-flock.js   # native flock binding (compile + runtime self-test)
│   ├── patch-dsh-android-require-builtin.js # dsh >=0.1.7 boot prerequisite: android platform pkg
│   ├── verify-android-link-fix.js   # hardlink fix verification (real run in temp dir)
│   ├── apply-profile-patch.js       # safe permission-layer install (classify: replace/append/repair + dsh parser check)
│   ├── verify-client-modules-lazy.js # client-combo patch self-test (--port 0 temp instance)
│   ├── verify-require-builtin-fixture.js # platform-package fixture self-test (8 cases / 29 assertions, temp dir only)
│   ├── verify-patch-guards-fixture.js # link/flock guard fixture self-test (11 cases / 39 assertions, temp dir only)
│   ├── verify-profile-patch-fixture.js # permission-layer fixture self-test (11 cases / 41 assertions, temp dir only)
│   ├── verify-js-patches-fixture.js # apply-js-patches.sh fixture (21 assertions: rebuild upstream → forward → idempotent → corrupt ⇒ rc 1)
│   ├── verify-runtime-scripts-fixture.js # start/stop/restart fixture (40 assertions: fake dsh + isolated HOME, never touches 3080)
│   ├── verify-pnpm-provision-fixture.js # pnpm runtime provisioning fixture (76 assertions: offline, temp HOME/PIN/WRAPPER)
│   ├── verify-setup-static-check.sh # static contracts of setup.sh / runtime scripts (39 checks, read-only)
│   ├── verify-test-effectiveness.js # mutation testing: inject 10 known regressions into copies, suites must turn red
│   └── verify-all-checks.sh         # one command for every script-level check (--full adds mutation testing)
├── npm_android.sh               # Termux npm wrapper: injects android30 compile flags (use for manual npm updates)
├── docs/
│   └── index.html               # documentation site
├── AGENTS.md                    # maintainer conventions & pitfalls (for AI/collaborators)
└── README.md                    # this file (bilingual)
```

### Runtime directories (created on install, not in the repo)

```text
~/dsh/
├── start_dsh.sh  stop_dsh.sh  restart_dsh_now.sh   # copies installed by setup.sh
├── setup.log                                       # raw setup.sh output
└── storage/
    ├── dsh.log          # dsh web log (contains the current process token URL)
    ├── dsh.pid          # current pid
    └── dsh_restart.log  # restart history

/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/   # native npm global install dir (real directory; the old hold tree can be deleted after migration)
~/.local/share/pnpm-pin/          # pnpm 11 installed by 2.5/9 (JS build; runtime dependency of dsh plugins)
~/bin/{pnpm,pn,pnpx,pnx}           # pnpm 11 wrappers written by 2.5/9 (must be on PATH)

~/.dsh/
├── .credentials.yaml    # API key / auth signing secret (0600)
├── settings.yaml        # settings
├── profiles/web/cordis.patch.yml   # installed danger-full-access layer
└── sessions/ attachments/ skills/ ...   # sessions, attachments, skills
```

## 🛠 Maintenance & re-running single patches

```bash
# re-run one patch without reinstalling everything
bash apply-rg-fix.sh
bash apply-js-patches.sh

# hardlink / flock patches and verification
node patches/patch-dsh-android-link.js  --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/verify-android-link-fix.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/patch-dsh-android-flock.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"
# fixture self-tests (temp dir only, never touch the install tree)
node patches/verify-require-builtin-fixture.js
node patches/verify-patch-guards-fixture.js
node patches/verify-profile-patch-fixture.js
node patches/verify-js-patches-fixture.js
node patches/verify-runtime-scripts-fixture.js
node patches/verify-pnpm-provision-fixture.js

# one command for every script-level check (syntax + 39 setup static contracts + 6 fixtures / 246 assertions)
bash patches/verify-all-checks.sh            # summary
bash patches/verify-all-checks.sh --verbose  # full output
bash patches/verify-all-checks.sh --full     # also run mutation testing (~5 min, proves the suites bite)
```

where `DSH_DIR=/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`.
These checks are **read-only or temp-dir only**: they never run `setup.sh`, never touch port 3080, never write `~/.dsh`, never modify the install tree.
All patch scripts are **idempotent**: run them twice and the second run reports `[OK]` / `[skip]` only.
⚠️ `--root` is a **hard contract**: if given explicitly and it does not resolve, the script exits 1 and **never** falls back to another install tree (so pointing it at a temp copy can never touch the production tree); auto-location only happens when `--root` is omitted.

## 🔐 Security notes

- The service listens on **`127.0.0.1` only** (loopback), never on the LAN.
- The API key lives in `~/.dsh/.credentials.yaml` (0600) and never enters logs or the process environment.
- The Web auth signing secret also lives in `~/.dsh`; never write it to logs, env vars, or the repo.
- **`danger-full-access` effectively disables the process sandbox**: Android has no bwrap/landlock, and a restricted mode makes the bash tool fail with `SANDBOX_UNAVAILABLE`. This means the agent can run arbitrary commands — **personal devices only**.
- The permission layer is **two entries**: `sandbox-policy.mode = danger-full-access` **plus** `approval.policy = never`. From 0.2.0 on, upstream's new `permission` row (`@deepseek-ai/dsh-permission-presets`) derives a preset from the *composed* sandbox + approval pair, and its `danger-full-access` preset is exactly that pair; changing only the sandbox leaves the pair matching no preset (the row refuses to activate and logs a warning).

## ❓ FAQ

- **Blank page / cannot open**: make sure you are inside Termux; check `~/dsh/storage/dsh.log`.
- **Opening `127.0.0.1:3080` directly shows 401**: expected — the new auth needs the tokenized URL; use `bash ~/dsh/start_dsh.sh`.
- **`dsh web` prints `dsh: startup failed: … listen EADDRINUSE: address already in use 127.0.0.1:3080`**: another dsh web instance already owns 3080 (tokens are per-process, so a second instance can only fail). Use `bash ~/dsh/start_dsh.sh`: it reuses the running instance; if the process holding the port is invisible to this session (another user/app, started under `su`, another terminal session) it immediately prints "port 3080 is held by …" plus three remedies, instead of spawning a doomed instance and waiting out the timeout before opening a 401 page. To run a second instance in parallel, use another port: `DSH_PORT=3081 bash ~/dsh/start_dsh.sh`.
- **`dsh web` exits shortly after starting / the log says `startup failed` / a profile YAML raises `YAMLException`**: `start_dsh.sh` reports the reason **immediately** when the process exits or the log shows `startup failed` (no longer waiting out `DSH_READY_TIMEOUT`), and prints the log tail plus the `~/.dsh/logs/startup-*.log` path.
- **`stop_dsh.sh` says "stopped" but the browser still opens 3080**: stop can only kill processes visible to this session; if the port still responds, the script warns on stderr that the holder is invisible and unmanaged — end it in the window that started it, or use another `DSH_PORT`.
- **The browser lands on the bare URL**: most likely PWA hijacking; try `DSH_ORIGIN=localhost`, or `DSH_HINTS=1 bash ~/dsh/start_dsh.sh` to print the three workarounds.
- **It did not open in Via**: verify Via's package is `mark.via` (it can differ per distribution channel) and set `DSH_VIA_APP=<pkg>` if needed.
- **Model not responding**: check the API key on the Models page and `~/.dsh/.credentials.yaml`.
- **Awkward layout on a phone / the soft keyboard hides the input / some buttons do not respond to taps**: that is upstream's desktop-oriented Web UI and this repo no longer injects any front-end CSS/JS. Install the community `dsh-android-ui` plugin — see "📱 Mobile UI (optional)".
- **dsh won't start after an upgrade, log says `No usable native binding found`**: since 0.1.7 upstream added a native-addon family but ships no android prebuild. Re-run `bash setup.sh` (it adds the `node-addon-require-builtin-android-arm64` platform package).
- **After upgrading to 0.2.1 the profile lost a bundle / the log mentions a migration**: 0.2.1's `RETIRED_BUNDLES` migration auto-removes `dsh-experimental-schedule-bundle` from existing profiles — **normal behaviour, not an error**; do not add it back manually.
- **`dsh plugin …` / plugin market cannot find pnpm, or pnpm reports `ERR_PNPM_STORE_DIR_ACQUIRE_OPERATION_LOCK`**: since 0.2.1 the plugin features shell out to `pnpm` from PATH, and pnpm 12 does not work on Android. First check `command -v pnpm && pnpm --version` resolves to **11.x**; install/pin it with `npm install -g pnpm@11`, or make the 11.x wrapper at `~/bin/pnpm` take precedence in PATH (see "pnpm runtime (plugin dependency)").
- **`bash setup.sh --pnpm` reports "deprecated flag"**: the pnpm install backend is gone — npm (`npm install -g`) is the only backend. Just run `bash setup.sh` (pin a version with `DSH_VERSION=<ver> bash setup.sh`).
- **`bad interpreter: /usr/bin/env` / `npm: not found`**: on Termux `/usr/bin` is not resolvable while npm's shebang is `#!/usr/bin/env node`. `setup.sh` already calls npm as `node npm-cli.js`; if you hit this typing `npm` yourself, use `node "$(readlink -f "$(command -v npm)")" …` instead.
- **`npm -g update` fails building koffi with `statx` / `__u32` / `const char *` errors, or dsh won't start after an upgrade**: `npm -g update` bypasses `setup.sh` — it sets no Android compile flags and re-applies none of the install-time patches (dsh is a native global install, so it gets upgraded/reinstalled directly). Use `bash setup.sh` to upgrade or repair dsh; if it was already damaged, re-running that script restores it.
- **How to upgrade**: `cd` into the repo → `bash setup.sh` (npm is the only backend, see "Install backend: npm") → `bash ~/dsh/restart_dsh_now.sh` to restart the GUI. The script follows npm `latest`; pin a version with `DSH_VERSION=<ver> bash setup.sh`. **dsh is a native global install, so `npm -g update` will upgrade/overwrite it and lose the install-time patches**; upgrading dsh must go through `bash setup.sh` (an old hold layout is migrated automatically, and the old install tree's cleanup command is printed afterwards).
- Phones/ROMs differ: some block the `link()` syscall via SELinux, namespace-sandbox permissions vary, and bwrap/landlock availability differs.
- `setup.sh` covers the common Android cases; specific devices may still need extra tweaks.

**Issues & PRs welcome for more environments**: <https://github.com/FunnelCakes/deepseek-harness-android/issues>

## 📚 References

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- [Xieansecn/dsh-android-ui — mobile UI composition-package plugin (optional third-party plugin, see "📱 Mobile UI")](https://github.com/Xieansecn/dsh-android-ui)
- [Discussion #136 — Android/Termux deployment](https://github.com/deepseek-ai/deepseek-harness/discussions/136)
- [Discussion #248 — hardlinks blocked on Android (link→rename proposal)](https://github.com/deepseek-ai/deepseek-harness/discussions/248)
- [Termux Wiki](https://wiki.termux.com/)

---

## License

MIT — see [LICENSE](LICENSE).
