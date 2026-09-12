<div align="center">

# DeepSeek Harness for Android / Termux

**在 Android 手机的 Termux 里原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)**
**Run DeepSeek Harness natively inside Termux on Android**

[![tested](https://img.shields.io/badge/tested-0.1.5--rc.1-blue)](#-兼容性--compatibility)
[![platform](https://img.shields.io/badge/platform-Android%20%C2%B7%20Termux-green)](#-环境要求--requirements)
[![license](https://img.shields.io/badge/license-MIT-lightgrey)](#license)

[🇨🇳 中文](#-中文文档) · [🇬🇧 English](#-english-docs)

</div>

> [!IMPORTANT]
> 已在 **deepseek-harness `0.1.5-rc.1`** 上实测通过，向下兼容 `rc.6` / `rc.7` 及更早版本。
> Tested on **deepseek-harness `0.1.5-rc.1`**, back-compatible with `rc.6` / `rc.7` and earlier.

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
| 🧩 | 原生插件适配：node-pty / koffi / sharp / ripgrep / flock |
| 🔗 | 无硬链接（SELinux 禁 `link()`）修复：会话、附件、工具写文件全部照常 |
| 🔐 | 新版 Web 鉴权适配：自动提取带 token 的启动 URL 并校验后再交给浏览器 |
| 🌐 | 默认用 **Via 浏览器**（按包名）打开，找不到再回退系统默认浏览器 |
| ⚡ | 启动脚本零轮询等待（流式读日志），复用已在运行的服务约 0.4s |
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
```

> [!WARNING]
> **不要直接打开 `http://127.0.0.1:3080`**：新版 dsh 需要**带 token 的启动 URL** 换取登录 cookie，直接打开会 401。请始终用 `start_dsh.sh`，它会从日志里取当前进程的 token、用 `curl` 验证返回 303 之后才交给浏览器。

## ⚙️ 用法与配置

### 脚本参数

| 脚本 | 参数 | 说明 |
|---|---|---|
| `setup.sh` | `--verbose` / `SETUP_VERBOSE=1` | 透传子命令原始输出（默认只显示摘要，原始日志写 `~/dsh/setup.log`） |
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
| `DSH_PORT` | `3080` | 服务端口 |
| `NO_COLOR` | 空 | 非空则关闭彩色输出 |

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

## 🔧 原理：setup.sh 自动修复了什么

上游 `@deepseek-ai/dsh` 只发布 linux/darwin 预编译产物，且假设了完整的 Linux 命名空间沙箱与硬链接能力。Android/bionic 环境下需要下面这些适配——**全部由 `setup.sh` 自动完成，且幂等**：

| 问题 | 现象 | 修复方式 |
|---|---|---|
| node-pty 编译失败 | `Undefined variable android_ndk_path` | 修补 node-gyp 缓存里的 `common.gypi` |
| koffi 编译失败 | `statx` 的 `__u32` 编译错误 | 加 `-target aarch64-linux-android30` |
| npm 拦截构建脚本 | node-pty / koffi 没有产物 | `--allow-scripts` 放行指定包 |
| `link()` 被 SELinux 禁用 | 会话/附件保存、会话迁移、`write` 新建文件报 `EACCES` | 会话日志直接发布改 `rename()`；no-replace 场景回退「O_EXCL 占位 + rename」；附件遍历/清理容忍 `EACCES`/`ENOENT` |
| `flock` 在 Android 不可用 | 发消息报 `flock is not supported on android-arm64` | 用 clang 把 `node-addon-system` 自带 `src/flock.c` 编成本机 `system.node`，并让 `lib/flock.js` 在 android 下加载它（含真实加锁自检） |
| PTY 终端检测失败 | `unsupported on platform android` | subprocess 把 `android` 视同 `linux`（锚点可能在内容哈希 bundle 里，按通配扫描 `lib/`） |
| 安卓输入法回车直接发送 | 打不出多行：回车即发送 | 修补 `dsh-client-ui-conversation`：普通回车=换行，`Ctrl/Cmd+Enter`=发送（唯一「失败即回滚并中断安装」的补丁） |
| sharp 无法加载 | `Could not load sharp module` | 安装 `@img/sharp-wasm32` wasm 回退（含 `@emnapi/runtime`） |
| grep/glob 报 `ripgrep launch failed` | `@vscode/ripgrep` 无 Android 预编译包 | 符号链接系统 `rg` + 修补 `resolveRgPath()` 回退 |
| HMR 启动崩溃 | `--expose-internals is required` | 重建 `dsh` 包装脚本，加 `--expose-internals --no-warnings` |
| bash 工具不可用 | `SANDBOX_UNAVAILABLE` | 写入 `danger-full-access` 配置层（见下方安全说明） |
| 整页重载重复下载 JS | 每次刷新重下 `/assets/` 全部构建产物（本机实测 ~4.5MB） | 给 `/assets/` 静态资源加 immutable 缓存头 |
| 冷启动十几秒才出 token | `dsh web` 起来后端口先回 401，十几秒后才打印鉴权 URL | 补丁 `02`：客户端插件组合（`dsh-client-modules`）启动时会全量重组约 10 次，每次都把所有 client bundle 预建一遍单条 artifact；改为**按需构建** + 索引式行数统计（实测冷启动 22.6s → 12.5s，产物与未打补丁时逐字节一致） |

> [!NOTE]
> 现在只保留两个上游 JS 性能补丁：`01-frontend-static-cache`（静态资源 immutable 缓存头）与 `02-client-modules-lazy-compose`（客户端 combo 按需构建）。历史上做长会话历史瘦身的 `01`~`03`/`05`（apiproxy history slim、增量重连、连接 schema、插件 bundle 缓存）宿主模块已被上游移除或原生实现，相关补丁文件与"过时跳过"逻辑已删除。两个补丁的锚点已对照 npm 上 0.1.5-rc.2 源码逐字节核对。

## 🗂 工作原理与安装步骤

### 安装步骤（`setup.sh` 的 9 步）

| 步骤 | 做什么 |
|---|---|
| `0/9` | 锚点预检：确认目标文件里补丁特征串还在（版本漂移早发现） |
| `1/9` | 安装构建依赖：`cmake clang make binutils pkg-config python nodejs ripgrep` |
| `2/9` | 准备 Node headers（慢则切 npmmirror） |
| `3/9` | `npm install -g` 安装 dsh（android30 目标，`--allow-scripts` 放行原生包） |
| `4/9` | 后端兼容补丁：link→rename 回退、flock 原生绑定、subprocess 平台检测（android≡linux）、作曲栏「回车=换行」、grep/glob ripgrep 修复 |
| `5/9` | sharp wasm 回退（附件模块依赖），紧接硬链接补丁验证（临时目录真实运行，不碰会话数据；必须排在 wasm 回退之后，否则附件模块 `import sharp` 失败会误报） |
| `6/9` | 重建 `dsh` 包装脚本（`--expose-internals`，原子 `mv` 替换，不碰符号链接目标） |
| `7/9` | 写入 `~/dsh/` 下的启动/停止/重启脚本 + `danger-full-access` 配置层 |
| `8/9` | JS 性能补丁（`01` 静态资源缓存头 / `02` 客户端 combo 按需构建；锚点失配只告警不中断） |
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
- 复用已在运行的服务约 **0.4s**，冷启动脚本侧开销约 **9.1s**（其中约 9s 是 dsh 自身 plugin loader settle，非脚本可消除）。

## 📁 仓库结构

```text
deepseek-harness-android/
├── setup.sh                     # 主入口：安装 dsh + 全部 Android 修补（幂等）
├── apply-js-patches.sh          # 应用 JS 性能补丁（01 缓存头 / 02 客户端 combo，幂等）
├── apply-rg-fix.sh              # 修复 ripgrep launch failed
├── start_dsh.sh                 # 启动/复用服务 + 取 token + 打开浏览器（Via 优先）
├── stop_dsh.sh                  # 安全停止（pid 身份二次校验 + 端口释放确认）
├── restart_dsh_now.sh           # 重启（复用 stop + start --no-open）
├── config/
│   └── cordis.patch.yml         # danger-full-access 配置层（安装到 ~/.dsh/profiles/web/）
├── patches/
│   ├── 01~02-*.patch            # JS 补丁源（缓存头 / 客户端 combo）
│   ├── patch-dsh-android-link.js    # 禁硬链接修复（rename / O_EXCL+rename 回退）
│   ├── patch-dsh-android-flock.js   # flock 原生绑定（编译 + 运行时自检）
│   └── verify-android-link-fix.js   # 硬链接修复验证（临时目录真实运行，不碰会话）
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
# 补丁 02 自检（临时实例，不动运行中的服务）
node patches/verify-client-modules-lazy.js
```

其中 `DSH_DIR=/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`。
所有修补脚本**幂等**：连跑两次，第二次应全部 `[OK]` / `[skip]`。

## 🔐 安全说明

- 服务**只监听 `127.0.0.1`**（本机回环），不走局域网。
- API Key 存于 `~/.dsh/.credentials.yaml`（0600），不进日志、不进进程环境。
- Web 鉴权签名 secret 同样存于 `~/.dsh`，不要把它写进日志、环境变量或仓库。
- **`danger-full-access` 等同于关闭进程沙箱**：Android 无 bwrap/landlock 可用，受限模式会让 bash 工具直接 `SANDBOX_UNAVAILABLE`。这意味着 agent 可执行任意命令——**仅建议个人设备使用**。

## ❓ 常见问题

- **页面白屏 / 打不开**：确认在 Termux 里跑；看 `~/dsh/storage/dsh.log`。
- **直接开 `127.0.0.1:3080` 显示 401**：正常，新版需要带 token URL，用 `bash ~/dsh/start_dsh.sh`。
- **浏览器落在了裸地址**：多半是 PWA 劫持，试 `DSH_ORIGIN=localhost`；`DSH_HINTS=1 bash ~/dsh/start_dsh.sh` 会打印三条排查办法。
- **没有用 Via 打开**：确认 Via 包名为 `mark.via`（不同渠道包名可能不同），可用 `DSH_VIA_APP=<包名>` 指定。
- **模型没反应**：检查 Models 页的 API Key 与 `~/.dsh/.credentials.yaml`。
- **升级 dsh / Node 后异常**：重跑 `bash setup.sh`。
- **换机 / 重装**：重跑 `bash setup.sh` 即可。

## 🧪 兼容性 / Compatibility

- **作者实测**：Huawei Mate 60（ALN-AL80），HarmonyOS 4.2.0（build 4.2.0.186），**无 root**，Termux（Node v26，aarch64），deepseek-harness `0.1.5-rc.1`。
- 不同机型 / ROM 可能有差异：部分 ROM 通过 SELinux 禁用 `link()`、命名空间沙箱权限不同、bwrap/landlock 可用性不同等。
- `setup.sh` 覆盖通用 Android 场景，个别机型可能仍需额外适配。

**欢迎提 Issue / PR 适配更多环境**：<https://github.com/FunnelCakes/deepseek-harness-android/issues>

## 📚 参考

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
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
| 🧩 | Native addon adaptation: node-pty / koffi / sharp / ripgrep / flock |
| 🔗 | No-hardlink (SELinux blocks `link()`) fix: sessions, attachments, tool file writes all work |
| 🔐 | New Web auth support: extracts the tokenized launch URL and verifies it before handing it to the browser |
| 🌐 | Opens **Via** browser by package name by default, falls back to the system default browser |
| ⚡ | Zero-poll startup wait (streams the log); reusing a running service takes ~0.4s |
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
```

> [!WARNING]
> **Do not open `http://127.0.0.1:3080` directly**: recent dsh versions require the **tokenized launch URL** to exchange for the auth cookie — the bare URL returns 401. Always use `start_dsh.sh`, which reads the current process's token from the log and only hands it to the browser after verifying it returns 303.

## ⚙️ Usage & configuration

### Script options

| Script | Option | Description |
|---|---|---|
| `setup.sh` | `--verbose` / `SETUP_VERBOSE=1` | Stream raw sub-command output (default shows a summary; raw log goes to `~/dsh/setup.log`) |
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
| `DSH_PORT` | `3080` | Service port |
| `NO_COLOR` | empty | Non-empty disables colored output |

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

## 🔧 How it works: what setup.sh fixes

Upstream `@deepseek-ai/dsh` ships linux/darwin prebuilds only and assumes a full Linux namespace sandbox plus hardlink support. On Android/bionic, the following adaptations are needed — **all applied automatically and idempotently by `setup.sh`**:

| Issue | Symptom | Fix |
|---|---|---|
| node-pty build fails | `Undefined variable android_ndk_path` | patch node-gyp cache `common.gypi` |
| koffi build fails | `statx` `__u32` compile error | add `-target aarch64-linux-android30` |
| npm blocks build scripts | no node-pty / koffi artifacts | allow the packages via `--allow-scripts` |
| `link()` blocked by SELinux | `EACCES` saving sessions/attachments, migrating sessions, and when the `write` tool creates a file | session-log publish uses `rename()`; no-replace paths fall back to "O_EXCL reserve + rename"; attachment walks/cleanup tolerate `EACCES`/`ENOENT` |
| `flock` unavailable | `flock is not supported on android-arm64` when sending a message | compile `node-addon-system`'s bundled `src/flock.c` with clang into a local `system.node` and load it from `lib/flock.js` on android (with a real lock self-test) |
| PTY terminal detection fails | `unsupported on platform android` | treat `android` as `linux` in subprocess (the anchor may live in a content-hashed bundle, so `lib/` is glob-scanned) |
| Enter sends instead of a newline | cannot type multi-line input | patch `dsh-client-ui-conversation`: Enter = newline, `Ctrl/Cmd+Enter` = send (the only patch that rolls back and aborts the install on failure) |
| sharp fails to load | `Could not load sharp module` | install the `@img/sharp-wasm32` wasm fallback (plus `@emnapi/runtime`) |
| grep/glob: `ripgrep launch failed` | no Android prebuild from `@vscode/ripgrep` | symlink system `rg` + patch the `resolveRgPath()` fallback |
| HMR crashes on start | `--expose-internals is required` | rebuild the `dsh` wrapper with `--expose-internals --no-warnings` |
| bash tool unavailable | `SANDBOX_UNAVAILABLE` | write the `danger-full-access` config layer (see Security) |
| Full reload re-downloads JS | every refresh re-fetched all of `/assets/` (~4.5MB measured here) | immutable cache headers for `/assets/` |
| Cold start takes tens of seconds | the port answers 401 long before the tokenized URL is printed | patch `02`: `dsh-client-modules` recomposes the whole client-plugin graph ~10x during boot and eagerly prebuilds a per-record artifact for every client bundle; made lazy plus an indexed line count (measured cold start 22.6s → 12.5s, byte-identical artifacts) |

> [!NOTE]
> Only two upstream JS patches remain: `01-frontend-static-cache` (immutable static-asset cache headers) and `02-client-modules-lazy-compose` (lazy client combos). The old `01`~`03`/`05` history-slimming patches (apiproxy history slim, incremental resync, connection schema, plugin-bundle cache) targeted host modules that were removed upstream or are now native, so those files and the "superseded" machinery were deleted. Both remaining patches were diffed byte-for-byte against the 0.1.5-rc.2 npm sources.

## 🗂 Architecture & install steps

### Install steps (the 9 steps of `setup.sh`)

| Step | What it does |
|---|---|
| `0/9` | Anchor pre-check: confirm patch markers still exist (catch version drift early) |
| `1/9` | Install build deps: `cmake clang make binutils pkg-config python nodejs ripgrep` |
| `2/9` | Prepare Node headers (switch to npmmirror when slow) |
| `3/9` | `npm install -g` dsh (android30 target, `--allow-scripts` for native packages) |
| `4/9` | Backend patches: link→rename fallback, native flock binding, subprocess platform detection (android≡linux), composer Enter = newline, grep/glob ripgrep fix |
| `5/9` | sharp wasm fallback (attachments depend on it), immediately followed by the hardlink verification (real run in a temp dir, never touches your sessions; it must come after the wasm fallback or the attachment module's `import sharp` fails and reports a false negative) |
| `6/9` | Rebuild the `dsh` wrapper (`--expose-internals`, atomic `mv` replace that never follows the symlink target) |
| `7/9` | Write start/stop/restart scripts into `~/dsh/` + the `danger-full-access` config layer |
| `8/9` | JS performance patches (`01` static-asset cache headers / `02` lazy client combos; an anchor mismatch only warns) |
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
- reusing a running service takes ~**0.4s**; a cold start costs ~**9.1s** script-side, of which ~9s is dsh's own plugin-loader settle (not removable from the script).

## 📁 Repository layout

```text
deepseek-harness-android/
├── setup.sh                     # main entry: install dsh + all Android patches (idempotent)
├── apply-js-patches.sh          # apply the JS perf patches (cache headers / lazy client combos)
├── apply-rg-fix.sh              # fix "ripgrep launch failed"
├── start_dsh.sh                 # start/reuse service + fetch token + open browser (Via first)
├── stop_dsh.sh                  # safe stop (pid identity re-check + port release confirm)
├── restart_dsh_now.sh           # restart (reuses stop + start --no-open)
├── config/
│   └── cordis.patch.yml         # danger-full-access layer (installed to ~/.dsh/profiles/web/)
├── patches/
│   ├── 01~02-*.patch            # JS patch sources (cache headers / lazy client combos)
│   ├── patch-dsh-android-link.js    # no-hardlink fix (rename / O_EXCL+rename fallback)
│   ├── patch-dsh-android-flock.js   # native flock binding (compile + runtime self-test)
│   └── verify-android-link-fix.js   # hardlink fix verification (real run in temp dir)
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
```

where `DSH_DIR=/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`.
All patch scripts are **idempotent**: run them twice and the second run reports `[OK]` / `[skip]` only.

## 🔐 Security notes

- The service listens on **`127.0.0.1` only** (loopback), never on the LAN.
- The API key lives in `~/.dsh/.credentials.yaml` (0600) and never enters logs or the process environment.
- The Web auth signing secret also lives in `~/.dsh`; never write it to logs, env vars, or the repo.
- **`danger-full-access` effectively disables the process sandbox**: Android has no bwrap/landlock, and a restricted mode makes the bash tool fail with `SANDBOX_UNAVAILABLE`. This means the agent can run arbitrary commands — **personal devices only**.

## ❓ FAQ

- **Blank page / cannot open**: make sure you are inside Termux; check `~/dsh/storage/dsh.log`.
- **Opening `127.0.0.1:3080` directly shows 401**: expected — the new auth needs the tokenized URL; use `bash ~/dsh/start_dsh.sh`.
- **The browser lands on the bare URL**: most likely PWA hijacking; try `DSH_ORIGIN=localhost`, or `DSH_HINTS=1 bash ~/dsh/start_dsh.sh` to print the three workarounds.
- **It did not open in Via**: verify Via's package is `mark.via` (it can differ per distribution channel) and set `DSH_VIA_APP=<pkg>` if needed.
- **Model not responding**: check the API key on the Models page and `~/.dsh/.credentials.yaml`.
- **Broken after upgrading dsh / Node**: re-run `bash setup.sh`.
- **New device / reinstall**: just re-run `bash setup.sh`.

## 🧪 Compatibility

- **Author's setup**: Huawei Mate 60 (ALN-AL80), HarmonyOS 4.2.0 (build 4.2.0.186), **no root**, Termux (Node v26, aarch64), deepseek-harness `0.1.5-rc.1`.
- Phones/ROMs differ: some block the `link()` syscall via SELinux, namespace-sandbox permissions vary, and bwrap/landlock availability differs.
- `setup.sh` covers the common Android cases; specific devices may still need extra tweaks.

**Issues & PRs welcome for more environments**: <https://github.com/FunnelCakes/deepseek-harness-android/issues>

## 📚 References

- [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
- [Discussion #136 — Android/Termux deployment](https://github.com/deepseek-ai/deepseek-harness/discussions/136)
- [Discussion #248 — hardlinks blocked on Android (link→rename proposal)](https://github.com/deepseek-ai/deepseek-harness/discussions/248)
- [Termux Wiki](https://wiki.termux.com/)

---

## License

MIT — see [LICENSE](LICENSE).
