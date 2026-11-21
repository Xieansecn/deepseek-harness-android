# DeepSeek Harness for Android / Termux

在 **Android 手机的 Termux** 里安装并原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`），然后用手机浏览器打开 `http://127.0.0.1:3080` 使用。

- **只服务 Termux/Android**：全部修补都在安装期完成，运行期不加 hook、不加 loader。
- **不改上游前端**：不注入 CSS/JS，界面与交互问题请提给上游。
- **唯一入口是 `bash setup.sh`**：安装、升级、修复都重跑它——仓库干净 ≠ 设备已修好。

版本基线 `0.2.2-rc.5`（npm `latest`），rc.1 / rc.3 仍在支持范围（补丁按语义形状匹配，不按版本号分支）。

## 快速开始

```bash
pkg update && pkg upgrade -y
pkg install -y git
git clone <本仓库> deepseek-harness-android && cd deepseek-harness-android
bash setup.sh                # 安装 dsh + 8 项兼容补丁，约 5～15 分钟
bash ~/dsh/start_dsh.sh      # 启动并打开带 token 的浏览器
```

启动后在 Web UI 的 **Models** 页面填入 DeepSeek API Key 即可对话。

环境要求：Android + Termux（`aarch64`，无需 root）、Node ≥ 22（实测 v26）、npm（实测 12.x）。构建依赖（cmake clang make binutils pkg-config python nodejs ripgrep）由 `setup.sh` 自动安装。

## 修复清单

`setup.sh` 只做这 8 件事，其余一概不做。

| # | 现象 | 处理 | 失败语义 |
|---|---|---|---|
| 1 | 启动即崩：`No usable native binding found for node-addon-require-builtin-android-arm64` | 生成纯 JS 平台包；`dsh` 包装脚本带 `--expose-internals` | **中断安装** |
| 2 | 终端不可用：`terminal inspection is unsupported on platform android` | `dsh-subprocess-local` 的 `lib/` 全量扫描，android 视同 linux | warn |
| 3 | `node-pty` 无 Android 预编译 | 进 `ALLOW_SCRIPTS`，用 Termux headers 本地编译并校验 `pty.node` | **中断安装** |
| 4 | grep/glob 报 `ripgrep launch failed` | 软链系统 `rg` 到 `@vscode/ripgrep-android-arm64`，并给 `resolveRgPath()` 加回退 | **中断安装** |
| 5 | 会话/附件/write 报 `EACCES ... link` | 硬链接全链路改 `rename` / 「O_EXCL 占位 + rename」 | warn |
| 6 | 发消息报 `flock is not supported on android-arm64` | clang 编译 `flock.c` 为 `bin/android-<arch>/system.node` | warn |
| 7 | 附件/图片加载失败（`sharp` 无 android 包） | 装同版本 `@img/sharp-wasm32` + `@emnapi/runtime` | **中断安装** |
| 8 | bash 工具报 `SANDBOX_UNAVAILABLE` | 权限层写入 `danger-full-access` + `approval: never` | **中断安装** |

## 日常命令

| 命令 | 作用 |
|---|---|
| `bash setup.sh` | 安装 / 升级 / 修复（唯一受支持路径） |
| `bash setup.sh --verbose` | 同上，并在终端透传原始子命令输出 |
| `bash ~/dsh/start_dsh.sh` | 启动并打开带 token 的浏览器 |
| `bash ~/dsh/stop_dsh.sh` | 停止 |
| `bash ~/dsh/restart_dsh_now.sh` | 重启（不打开浏览器） |

> **不要直接 `npm -g update`**：它会覆盖安装期补丁并丢掉 Android 编译参数。dsh 的升级与修复只走 `bash setup.sh`。

## 配置

| 变量 | 默认 | 作用 |
|---|---|---|
| `DSH_VERSION` | 空（跟随 npm `latest`） | 灰度/回退时钉版本：`DSH_VERSION=0.2.2-rc.5 bash setup.sh` |
| `DSH_PORT` | `3080` | 端口，脚本会显式转成 dsh 的 `--port` |
| `DSH_ORIGIN` | `127.0.0.1` | 交给浏览器的 origin（`localhost` 可绕开 PWA 对 `?token=` 的劫持） |
| `DSH_NO_OPEN` / `--no-open` | 空 | 只拉起服务，不打开浏览器 |
| `DSH_READY_TIMEOUT` | `90` | 等带 token URL 的最长秒数 |
| `DSH_STOP_GRACE` / `DSH_STOP_TIMEOUT` | `1.5` / `6` | 停止梯子：优雅窗口 → 补发 SIGTERM → SIGKILL |
| `DSH_WEB_PATTERN` | `…/lib/[b]in.js web` | 进程匹配模式（多安装并存时覆盖） |
| `DSH_VIA_APP` / `DSH_OPEN_APP` / `DSH_OPEN_CHOOSER` | `mark.via` / 空 / `0` | 浏览器选择 |
| `SETUP_VERBOSE` / `NO_COLOR` | 空 | 透传原始输出 / 关色 |

`--pnpm` / `--npm` 参数已废弃，传入会打印提示并退出。

## 常见问题

- **`bad interpreter: /usr/bin/env node`** — Termux 的 `/usr/bin` 不可解析；本仓库一律使用 Termux 绝对 shebang，并由静态检查钉住。
- **`EADDRINUSE`** — 端口上已有实例。`start_dsh.sh` 先探端口，发现不可管理就退 1 并提示换端口：`DSH_PORT=3081 bash ~/dsh/start_dsh.sh`。
- **`koffi` 被跳过** — 它在 `SKIP_SCRIPTS` 里（npm 12 下放进白名单会让整次安装退 1），运行期只在 `win32` 分支懒加载。
- **能用 pnpm 吗** — 不能。pnpm 全局是符号链接 store 布局，补丁的落点假设不成立，且默认拦截 `node-pty` 构建。
- **`setup.sh` 停在 4/8** — require-builtin 平台包与 ripgrep 修复是硬阻断（dsh 起不来 / grep 全废），按提示看 `~/dsh/setup.log`。

## 安全须知

- **`danger-full-access` 等于关闭进程沙箱**：Android 没有 bwrap/landlock，受限模式会让 bash 工具直接报 `SANDBOX_UNAVAILABLE`。agent 可执行任意命令，**仅建议个人设备**。
- 服务只监听 `127.0.0.1`，不走局域网。
- API Key 与 Web 鉴权签名 secret 都在 `~/.dsh`（0600），不进日志、环境变量与仓库。

## 兼容性

- 支持版本线：`0.2.2-rc.5`（npm `latest`）、rc.1、rc.3。
- 已实测：Huawei Mate 60（HarmonyOS 4.2，无 root）、Termux aarch64、Node v26.13、npm 12.x、ripgrep 15.2.0。
- 前端不修改。

## 仓库结构

```text
setup.sh                      # 主入口：0~8 步安装 + 全部兼容补丁（幂等）
apply-rg-fix.sh               # ripgrep 修复（系统 rg 软链 + resolveRgPath 回退）
start_dsh.sh                  # 启动 / 复用 dsh web，打开带 token 浏览器
stop_dsh.sh                   # 安全停止（身份二次确认 + 分级信号）
restart_dsh_now.sh            # 重启（复用 stop + start --no-open）
config/cordis.patch.yml       # 权限层（sandbox-policy + approval 两条）
patches/                      # 补丁、权限层安装器、验证与夹具
REPORTS.md                    # 修改与适配报告
AGENTS.md                     # 维护须知
```

## 维护者

<details>
<summary><code>setup.sh</code> 的 0~8 步</summary>

| 步骤 | 做什么 |
|---|---|
| `0/8` | 锚点预检（只读）：5 条补丁锚点 + 3 个特殊探测；未命中只 warn |
| `1/8` | `pkg update/install` 构建依赖；探测镜像速度 |
| `2/8` | 优先用 Termux 自带 Node headers，缺失才 `npx node-gyp install` |
| `3/8` | `npm install -g @deepseek-ai/dsh`（Android CFLAGS + `--allow-scripts` 白名单），校验 `pty.node` |
| `4/8` | 后端补丁：require-builtin 平台包 → link → flock → subprocess → ripgrep |
| `5/8` | sharp WASM 回退（版本须与 `sharp` 一致），随后跑硬链接验证 |
| `6/8` | 重建 `dsh` 包装脚本（原子替换） |
| `7/8` | 拷入 start/stop/restart 脚本；安全合并权限层 |
| `8/8` | 汇总 |

</details>

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

## 参考

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)

---

# 🇬🇧 English

Install and run [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`@deepseek-ai/dsh`) natively on an **Android phone** via Termux, then use it from the phone browser at `http://127.0.0.1:3080`.

- **Termux/Android only**: every fix is applied at install time; no runtime hooks or loaders.
- **No frontend changes**: no CSS/JS injection — report UI issues upstream.
- **Single entry point**: `bash setup.sh` installs, upgrades and repairs. A clean repo does not mean a patched device.

Baseline `0.2.2-rc.5` (npm `latest`); rc.1 / rc.3 remain supported (patches match by semantic shape, never by version string).

## Quick start

```bash
pkg update && pkg upgrade -y
pkg install -y git
git clone <this repo> deepseek-harness-android && cd deepseek-harness-android
bash setup.sh                # installs dsh + 8 compatibility fixes, 5–15 minutes
bash ~/dsh/start_dsh.sh      # starts the server and opens the token URL
```

Then fill in your DeepSeek API key on the **Models** page of the web UI.

Requirements: Android + Termux (`aarch64`, no root), Node ≥ 22 (tested v26), npm (tested 12.x). Build dependencies (cmake clang make binutils pkg-config python nodejs ripgrep) are installed by `setup.sh`.

## What gets fixed

`setup.sh` does exactly these eight things.

| # | Symptom | Fix | On failure |
|---|---|---|---|
| 1 | Boot fails: `No usable native binding found for node-addon-require-builtin-android-arm64` | generate the pure-JS Android platform package; wrapper adds `--expose-internals` | **abort install** |
| 2 | `terminal inspection is unsupported on platform android` | treat android as linux inside `dsh-subprocess-local` | warn |
| 3 | `node-pty` has no Android prebuild | allow its build script, compile against Termux headers, verify `pty.node` | **abort install** |
| 4 | `ripgrep launch failed` | symlink system `rg` into `@vscode/ripgrep-android-arm64` + `resolveRgPath()` fallback | **abort install** |
| 5 | `EACCES ... link` on sessions/attachments/write | `rename` / "O_EXCL placeholder + rename" instead of hard links | warn |
| 6 | `flock is not supported on android-arm64` | compile `flock.c` to `bin/android-<arch>/system.node` | warn |
| 7 | `sharp` cannot load on android-arm64 | install matching `@img/sharp-wasm32` + `@emnapi/runtime` | **abort install** |
| 8 | bash tool throws `SANDBOX_UNAVAILABLE` | permission layer with `danger-full-access` + `approval: never` | **abort install** |

## Everyday commands

| Command | Purpose |
|---|---|
| `bash setup.sh` | install / upgrade / repair (the only supported path) |
| `bash setup.sh --verbose` | same, streaming raw subcommand output |
| `bash ~/dsh/start_dsh.sh` | start and open the token URL |
| `bash ~/dsh/stop_dsh.sh` | stop |
| `bash ~/dsh/restart_dsh_now.sh` | restart without opening a browser |

> **Never run `npm -g update`**: it overwrites the install-time patches and loses the Android compile flags.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `DSH_VERSION` | empty (npm `latest`) | pin a version for rollback: `DSH_VERSION=0.2.2-rc.5 bash setup.sh` |
| `DSH_PORT` | `3080` | port, passed explicitly as dsh's `--port` |
| `DSH_ORIGIN` | `127.0.0.1` | browser origin (`localhost` dodges PWA rewriting of `?token=`) |
| `DSH_NO_OPEN` / `--no-open` | empty | start the server only |
| `DSH_READY_TIMEOUT` | `90` | max seconds to wait for the token URL |
| `DSH_STOP_GRACE` / `DSH_STOP_TIMEOUT` | `1.5` / `6` | stop ladder: graceful → extra SIGTERM → SIGKILL |
| `DSH_WEB_PATTERN` | `…/lib/[b]in.js web` | process matcher for multiple installs |
| `DSH_VIA_APP` / `DSH_OPEN_APP` / `DSH_OPEN_CHOOSER` | `mark.via` / empty / `0` | browser selection |
| `SETUP_VERBOSE` / `NO_COLOR` | empty | stream raw output / disable colour |

`--pnpm` / `--npm` are retired and exit with a notice.

## FAQ

- **`bad interpreter: /usr/bin/env node`** — `/usr/bin` is unresolvable on Termux; all scripts use Termux absolute shebangs, enforced by the static check.
- **`EADDRINUSE`** — something already listens on the port; `start_dsh.sh` probes first and suggests `DSH_PORT=3081`.
- **`koffi` skipped** — it lives in `SKIP_SCRIPTS` (allowlisting it fails the whole install under npm 12) and dsh only loads it on `win32`.
- **pnpm?** — not supported: the symlinked store breaks patch placement and blocks `node-pty`'s build.
- **`setup.sh` stops at 4/8** — the require-builtin platform package and the ripgrep fix are hard blockers; see `~/dsh/setup.log`.

## Security

- **`danger-full-access` disables the process sandbox** (Android has no bwrap/landlock). The agent can run arbitrary commands — personal devices only.
- Listens on `127.0.0.1` only.
- API keys and the cookie secret live in `~/.dsh` (0600) and never reach logs, env vars or the repo.

## Compatibility

- Versions: `0.2.2-rc.5` (npm `latest`), rc.1, rc.3.
- Tested: Huawei Mate 60 (HarmonyOS 4.2, no root), Termux aarch64, Node v26.13, npm 12.x, ripgrep 15.2.0.
- Frontend untouched.

## Repository layout

```text
setup.sh                      # 0~8 installer + all compatibility patches (idempotent)
apply-rg-fix.sh               # ripgrep fix (system rg symlink + resolveRgPath fallback)
start_dsh.sh                  # start/reuse dsh web, open the token URL
stop_dsh.sh                   # safe stop (identity re-check + signal ladder)
restart_dsh_now.sh            # restart (stop + start --no-open)
config/cordis.patch.yml       # permission layer (sandbox-policy + approval)
patches/                      # patches, profile installer, verifiers, fixtures
REPORTS.md                    # adaptation report
AGENTS.md                     # maintenance notes
```

## Maintainers

<details>
<summary><code>setup.sh</code> steps 0~8</summary>

| Step | What |
|---|---|
| `0/8` | read-only anchor precheck (5 specs + 3 special probes) |
| `1/8` | `pkg update/install` build deps; mirror latency probe |
| `2/8` | prefer Termux Node headers, `node-gyp install` only when missing |
| `3/8` | `npm install -g @deepseek-ai/dsh` (Android CFLAGS + `--allow-scripts` allowlist), verify `pty.node` |
| `4/8` | require-builtin package → link → flock → subprocess → ripgrep |
| `5/8` | sharp WASM fallback (version match), then hard-link verification |
| `6/8` | rebuild the `dsh` wrapper (atomic replace) |
| `7/8` | install start/stop/restart scripts, merge the permission layer |
| `8/8` | summary |

</details>

```bash
bash patches/verify-all-checks.sh          # syntax + static contract + 5 fixtures (193 assertions)
bash patches/verify-all-checks.sh --full   # plus mutation testing (8 injected regressions + 4 controls)
```

Re-run a single patch:

```bash
bash apply-rg-fix.sh
node patches/patch-dsh-android-link.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/verify-android-link-fix.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/patch-dsh-android-flock.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"
node patches/apply-profile-patch.js --target "$HOME/.dsh/profiles/web/cordis.patch.yml" --layer config/cordis.patch.yml --root "$DSH_DIR"
```

## Reference

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
