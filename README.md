# DeepSeek Harness for Android / Termux

在 **Android 手机的 Termux** 里安装并原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`），然后通过 Web UI（`http://127.0.0.1:3080`）在手机浏览器里使用。

> **仓库定位（2026-11 收紧）**：本仓库**只有安装期补丁**，**只服务 Termux/Android**，**不改动 dsh 前端**。凡是纯性能优化、界面行为调整、或与 Android 兼容无关的改动，都已删除。

> **版本基线**：`0.2.2-rc.5`（npm `latest`）。补丁锚点已在 rc.5 的隔离安装树上核对（require-builtin / link / flock / ripgrep / 权限层 / subprocess），Web 链路（token → 303 → cookie → 200）实测通过。更早的 rc.1 / rc.3 仍在支持范围内（补丁按语义形状匹配，不按版本号分支）。

# 🇨🇳 中文文档

## 这是什么

`deepseek-harness-android` 是一个**安装与兼容性修补工具包**。它负责三件事：

1. 用 `npm install -g @deepseek-ai/dsh` 装上游 dsh；
2. 对**已安装到 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`** 的那份文件打 Android 兼容补丁（直接改写目标文件）；
3. 提供启动/停止脚本与权限层配置。

**升级 dsh / Node 后必须重跑 `bash setup.sh`**（仓库干净 ≠ 设备已修好）。

## 修复清单（只有这些）

| # | 问题 | 做法 | 失败语义 |
|---|---|---|---|
| 1 | 启动即崩：`No usable native binding found for node-addon-require-builtin-android-arm64` | 按 loader 的「平台可选包」约定生成纯 JS 平台包；`dsh` 包装脚本带 `--expose-internals` | **中断安装** |
| 2 | 终端不可用：`terminal inspection is unsupported on platform android` | `dsh-subprocess-local` 的 `lib/` 全量扫描，android 视同 linux | warn |
| 3 | 终端不可用：`node-pty` 无 android 预编译 | `node-pty` 进 `ALLOW_SCRIPTS`，用 Termux headers 本地编译并校验 `pty.node` | **中断安装** |
| 4 | grep/glob 报 `ripgrep launch failed` | 软链系统 `rg` 到 `@vscode/ripgrep-android-arm64`，并给 `resolveRgPath()` 加回退 | **中断安装** |
| 5 | 会话/附件/write 报 `EACCES ... link` | 硬链接全链路改 `rename` / 「O_EXCL 占位 + rename」 | warn |
| 6 | 发消息报 `flock is not supported on android-arm64` | clang 编译 `node-addon-system/src/flock.c` 为 `bin/android-<arch>/system.node` | warn |
| 7 | 附件/图片加载失败（`sharp` 无 android 包） | 装同版本 `@img/sharp-wasm32` + `@emnapi/runtime` | **中断安装** |
| 8 | bash 工具报 `SANDBOX_UNAVAILABLE` | `~/.dsh/profiles/web/cordis.patch.yml` 写入 `sandbox-policy: danger-full-access` + `approval: never` | **中断安装** |

不在这张表里的事都不做：不改前端、不注入 CSS/JS、不做性能补丁（静态资源缓存头 / `newlineCount` 索引循环都已在 2026-11-21 删除）。

## 环境要求

- Android + Termux（`aarch64`），**无需 root**
- `pkg install cmake clang make binutils pkg-config python nodejs ripgrep git`
- Node ≥ 22（实测 v26）
- npm（实测 12.x；`pnpm` 不作为安装器，见 FAQ）

## 快速开始

```bash
pkg update && pkg upgrade -y
pkg install -y git
git clone <本仓库> && cd deepseek-harness-android
bash setup.sh            # 安装 dsh + 全部兼容补丁（5～15 分钟）
bash ~/dsh/start_dsh.sh  # 启动并打开带 token 的浏览器
```

## 日常命令

```bash
bash setup.sh                       # 安装 / 升级 / 修复（唯一支持路径）
bash setup.sh --verbose             # 同时显示原始子命令输出
bash ~/dsh/start_dsh.sh             # 启动 dsh web 并打开带 token 浏览器
bash ~/dsh/stop_dsh.sh              # 停止
bash ~/dsh/restart_dsh_now.sh       # 重启（不打开浏览器）
```

> **不要直接 `npm -g update` / `pnpm add -g`**：前者会覆盖安装期补丁、还会丢掉 Android 编译参数；后者给出符号链接布局，补丁的落点假设（`<dsh>/node_modules/...` 真实目录）不成立。dsh 的升级/修复只走 `bash setup.sh`。

## 配置

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_VERSION` | 空（跟随 npm `latest`） | 仅灰度/回退时钉版本，如 `DSH_VERSION=0.2.2-rc.5 bash setup.sh` |
| `DSH_PORT` | `3080` | start/stop/restart 使用；脚本会显式转成 dsh 的 `--port` |
| `DSH_ORIGIN` | `127.0.0.1` | 交给浏览器的 origin（`localhost` 可绕开 PWA 对 `?token=` 的劫持） |
| `DSH_NO_OPEN` / `--no-open` | 空 | 只拉起服务、不打开浏览器 |
| `DSH_READY_TIMEOUT` | `90` | 等带 token URL 的最长秒数 |
| `DSH_STOP_GRACE` / `DSH_STOP_TIMEOUT` | `1.5` / `6` | 停止梯子：优雅窗口 → 补发 SIGTERM → SIGKILL |
| `DSH_WEB_PATTERN` | `…/lib/[b]in.js web` | 进程匹配模式（多安装并存时覆盖） |
| `DSH_VIA_APP` / `DSH_OPEN_APP` / `DSH_OPEN_CHOOSER` | `mark.via` / 空 / `0` | 浏览器选择 |
| `SETUP_VERBOSE` / `NO_COLOR` | 空 | 透传原始输出 / 关色 |
| `DSH_SETUP_PREFIX` | 空 | **仅测试夹具用**：把生产前缀整体换到临时目录 |

`--pnpm` / `--npm` 参数已废弃（安装方式只有 npm），传入会打印提示并 `exit 1`。

## 安装步骤（`setup.sh`）

| 步骤 | 做什么 |
|---|---|
| `0/8` | 锚点预检（只读）：5 条补丁锚点 + 3 个特殊探测；未命中只 `warn` |
| `1/8` | `pkg update/install` 构建依赖；探测镜像速度 |
| `2/8` | 优先用 Termux 自带 Node headers（`$PREFIX/include/node`），缺失才 `npx node-gyp install` |
| `3/8` | `npm install -g @deepseek-ai/dsh`（Android CFLAGS、`--allow-scripts` 白名单），校验 `pty.node`，自检白名单覆盖 |
| `4/8` | 后端兼容补丁：require-builtin 平台包 → link → flock → subprocess 平台检测 → ripgrep |
| `5/8` | sharp WASM 回退（版本必须与 `sharp` 一致），随后跑硬链接补丁验证 |
| `6/8` | 重建 `dsh` 包装脚本（`--expose-internals --no-warnings`，原子替换） |
| `7/8` | 拷入 start/stop/restart 脚本；安全合并权限层到 `~/.dsh/profiles/web/cordis.patch.yml` |
| `8/8` | 完成汇总（耗时、日志、后续操作） |

## 鉴权与启动链路

1. `dsh web` 启动时生成内存态 launch token，日志打印 `?token=<base64url>`；
2. 打开该 URL → 服务端 `303` + `Set-Cookie`（`HttpOnly; SameSite=Strict` 的签名 cookie）；
3. 之后 `/` 与 `/api` 走 cookie 鉴权；token 不落盘，签名 secret 在 `~/.dsh`。

因此 `start_dsh.sh` 必须：等日志里的**带 token URL**（不能端口一通就降级）、用 `curl` 验证 303 后再交给浏览器、把 `DSH_PORT` 显式传成 `--port`。

## 仓库结构

```text
setup.sh                            # 主入口：0~8 步安装 + 全部兼容补丁（幂等）
apply-rg-fix.sh                     # ripgrep 修复（系统 rg 软链 + resolveRgPath 回退）
start_dsh.sh / stop_dsh.sh / restart_dsh_now.sh   # 运行期脚本（POSIX sh 主体）
config/cordis.patch.yml             # 权限层（sandbox-policy + approval 两条）
patches/
  patch-dsh-android-require-builtin.js   # dsh 启动前提（平台包）
  patch-dsh-android-link.js              # 硬链接 → rename / 无硬链接 no-replace
  patch-dsh-android-flock.js             # flock 原生绑定（clang 编译）
  apply-profile-patch.js                 # 权限层安全合并（解析校验 + 按条目补缺）
  verify-*.js / verify-*.sh              # 夹具与静态契约（只读/临时目录）
REPORTS.md                          # 修改与适配报告
AGENTS.md                           # 维护须知（项目记忆）
```

## 维护与测试

```bash
bash patches/verify-all-checks.sh          # 语法 + 静态契约 + 5 个夹具（193 条断言）
bash patches/verify-all-checks.sh --full   # 追加变异测试（8 个注入回归 + 4 个对照组）
```

单独重跑某个修补（不必整树重装）：

```bash
bash apply-rg-fix.sh
node patches/patch-dsh-android-link.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/verify-android-link-fix.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/patch-dsh-android-flock.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"
node patches/apply-profile-patch.js --target "$HOME/.dsh/profiles/web/cordis.patch.yml" --layer config/cordis.patch.yml --root "$DSH_DIR"
```

## 安全注意

- **`danger-full-access`**：Android/Termux 没有 bwrap/landlock 命名空间沙箱，受限模式会让 bash 工具直接报 `SANDBOX_UNAVAILABLE`，所以权限层必须放开。**这等于关闭进程沙箱，agent 可执行任意命令，仅建议个人设备。**
- 服务只监听 `127.0.0.1`，不走局域网。
- API Key 与 Web 鉴权签名 secret 都在 `~/.dsh`（0600），不进日志/环境变量/仓库。

## 常见问题

- **`bad interpreter: /usr/bin/env node`**：Termux 上 `/usr/bin` 不可解析；本仓库一律用 Termux 绝对 shebang，并被 `verify-setup-static-check.sh` 钉住。
- **`dsh web` 报 `EADDRINUSE`**：端口上已有实例（可能属于别的用户/会话）。`start_dsh.sh` 先探端口，发现不可管就退 1 并提示换端口：`DSH_PORT=3081 bash ~/dsh/start_dsh.sh`。
- **`koffi` 构建失败/被跳过**：`koffi` 在 `SKIP_SCRIPTS` 里（npm 12 下放进白名单会让整次安装退 1），而 dsh 只在 `win32` 分支懒加载它，Android 运行期用不到。
- **能不能用 pnpm 装**：可以装（`pnpm add -g` 能成功），但 pnpm 全局是符号链接 store 布局，补丁要求 `<dsh>/node_modules/...` 是真实目录、平台包放在能被 loader 解析的位置；且 pnpm 默认拦截 build scripts（`node-pty` 直接缺产物）。**本仓库只支持 npm 安装路径。**
- **`setup.sh` 在 4/8 中断**：require-builtin 平台包或 ripgrep 修复属硬阻断（dsh 起不来 / grep 全废），按提示看 `~/dsh/setup.log`。

## 兼容性

- 支持版本线：`0.2.2-rc.5`（npm `latest`）；rc.1 / rc.3 仍在支持范围内。
- 已实测环境：Huawei Mate 60（HarmonyOS 4.2，无 root），Termux aarch64，Node v26.13，npm 12.x，ripgrep 15.2.0。
- 前端：**不修改**。界面/交互问题请提给上游。

## 参考

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)

# 🇬🇧 English docs

## What is this

`deepseek-harness-android` is an **install-and-compatibility patch kit**: it installs upstream `@deepseek-ai/dsh` with `npm install -g`, patches the installed tree under `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh` for Android/Termux, and ships start/stop scripts plus the permission layer.

**Scope (tightened 2026-11)**: install-time patches only, Termux only, **no dsh frontend changes**. Pure performance patches and UI-behaviour tweaks were removed.

**Baseline**: `0.2.2-rc.5` (npm `latest`); patch anchors checked on an isolated rc.5 tree, web chain verified (token → 303 → cookie → 200). rc.1 / rc.3 remain supported (patches match by semantic shape, never by version string).

## What gets fixed

| # | Symptom | Fix |
|---|---|---|
| 1 | `No usable native binding found for node-addon-require-builtin-android-arm64` at boot | generate the Android platform package (pure JS) + `--expose-internals` wrapper |
| 2 | `terminal inspection is unsupported on platform android` | treat android as linux in `dsh-subprocess-local` |
| 3 | `node-pty` has no Android prebuild | allow its build script; compile against Termux headers |
| 4 | `ripgrep launch failed` | symlink system `rg` into `@vscode/ripgrep-android-arm64` + `resolveRgPath()` fallback |
| 5 | `EACCES ... link` on sessions/attachments/write | `rename` / "O_EXCL placeholder + rename" everywhere `link()` was used |
| 6 | `flock is not supported on android-arm64` | compile `flock.c` to `bin/android-<arch>/system.node` |
| 7 | `sharp` cannot load on android-arm64 | install matching `@img/sharp-wasm32` + `@emnapi/runtime` |
| 8 | bash tool throws `SANDBOX_UNAVAILABLE` | write `sandbox-policy` + `approval` into the web profile layer |

Nothing else is done: no frontend edits, no CSS/JS injection, no performance patches.

## Requirements

Android + Termux (aarch64), no root; `pkg install cmake clang make binutils pkg-config python nodejs ripgrep git`; Node ≥ 22 (tested v26); npm (tested 12.x). `pnpm` is not a supported installer.

## Quick start

```bash
pkg update && pkg upgrade -y
pkg install -y git
git clone <this repo> && cd deepseek-harness-android
bash setup.sh
bash ~/dsh/start_dsh.sh
```

## Everyday commands

```bash
bash setup.sh                       # install / upgrade / repair (the only supported path)
bash setup.sh --verbose
bash ~/dsh/start_dsh.sh             # start and open the token URL
bash ~/dsh/stop_dsh.sh
bash ~/dsh/restart_dsh_now.sh
```

Never run `npm -g update` (it overwrites the patches and loses the Android compile flags) and do not install with pnpm (symlinked store layout breaks the patch placement and blocks build scripts).

## Install steps (`setup.sh`)

| Step | What |
|---|---|
| `0/8` | read-only anchor precheck |
| `1/8` | `pkg update/install` build deps |
| `2/8` | Termux Node headers, `npx node-gyp install` only when missing |
| `3/8` | `npm install -g @deepseek-ai/dsh` + `--allow-scripts` allowlist, verify `pty.node` |
| `4/8` | require-builtin platform package → link → flock → subprocess platform → ripgrep |
| `5/8` | sharp WASM fallback (version must match), then hardlink verification |
| `6/8` | rebuild the `dsh` wrapper (`--expose-internals`, atomic replace) |
| `7/8` | install start/stop/restart scripts, merge the permission layer |
| `8/8` | summary |

## Auth flow

`dsh web` prints `?token=…`; opening it returns `303` + a signed cookie (`HttpOnly; SameSite=Strict`); afterwards `/` and `/api` use the cookie. `start_dsh.sh` therefore waits for the token URL (never degrades early), validates it with `curl`, and passes `DSH_PORT` explicitly as `--port` (upstream does not read that env var).

## Repository layout

```text
setup.sh                     # 0~8, idempotent
apply-rg-fix.sh              # ripgrep fix
start_dsh.sh / stop_dsh.sh / restart_dsh_now.sh
config/cordis.patch.yml      # permission layer (sandbox-policy + approval)
patches/                     # 3 android patches + profile installer + fixtures
REPORTS.md / AGENTS.md
```

## Tests

```bash
bash patches/verify-all-checks.sh          # syntax + static contract + 5 fixtures (193 assertions)
bash patches/verify-all-checks.sh --full   # plus mutation testing (8 injected regressions + 4 controls)
```

## Security

`danger-full-access` is required (no bwrap/landlock on Android), which disables the process sandbox — personal devices only. The service listens on `127.0.0.1` only; keys and the cookie secret live in `~/.dsh` (0600).

## FAQ

- **`bad interpreter: /usr/bin/env …`** — `/usr/bin` is unresolvable on Termux; every script here uses a Termux absolute shebang (enforced by the static check).
- **`EADDRINUSE`** — something already listens on the port; the start script detects it and exits 1 with a hint to use `DSH_PORT=3081`.
- **`koffi` skipped** — it lives in `SKIP_SCRIPTS` (putting it in `ALLOW_SCRIPTS` fails the whole install under npm 12) and dsh only loads it on `win32`.
- **pnpm?** — `pnpm add -g` installs, but the symlinked layout breaks patch placement and pnpm blocks `node-pty`'s build script. npm-only.
- **Frontend** — not modified; report UI issues upstream.

## Compatibility

Supported: `0.2.2-rc.5` (npm `latest`), plus rc.1 / rc.3. Tested on Huawei Mate 60 (HarmonyOS 4.2, no root), Termux aarch64, Node v26.13, npm 12.x, ripgrep 15.2.0. Frontend untouched.

## References

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
