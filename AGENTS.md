# AGENTS.md

给 AI agent 与协作者的维护须知：这套胶水怎么工作、改哪里、别踩什么。面向用户的使用文档在 `README.md`（中英双语）与 `docs/index.html`。

## 1. 仓库定位（这是什么）

`deepseek-harness-android` 是一个**安装与兼容性修补工具包**，用于在 **Android 手机的 Termux** 里一键部署并原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`，DeepSeek 官方的 agent harness，类比 Claude Code），然后通过 Web UI（`http://127.0.0.1:3080`）在手机浏览器里使用。

它不是独立的源码项目。仓库里只有**胶水脚本 + 补丁**：它们负责安装上游 `dsh` 包，再对**已安装到 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`** 的那份文件做 Android 兼容修补（直接改写目标文件）。绝大多数改动不落在这份仓库里，而是落在 `dsh` 安装目录里——**所以「仓库干净」不等于「设备已修好」**：升级 dsh / Node 后必须重跑 `bash setup.sh`。

## 2. 版本基准与已验证状态

- 当前基准：`@deepseek-ai/dsh` **0.1.7-rc.2**（= npm `latest` = `next`；`alpha` 为 0.1.7-alpha.2）。其 `node_modules/@deepseek-ai/*` 同为 **0.1.7-rc.2**（`@deepseek-ai/node-addon-system` 用独立版本号 0.1.2、`node-addon-require-builtin` 0.1.6）。
- **⚠️ 版本号只表示「撰写/实测时点」，绝不能当逻辑依赖**：脚本与补丁一律**不得按版本号分支**（`setup.sh` 默认跟随 npm `latest`，`DSH_VERSION` 只由调用方按需传；补丁靠锚点/形状匹配，不靠版本串）。升级前后都用 `node -p "require('$DSH_DIR/package.json').version"` 与 `npm view @deepseek-ai/dsh dist-tags` 核对**实际**版本，再回来更新本行——在此之前，本行的版本号对代码没有任何约束力。
- **0.1.7 相对 0.1.5 的两处关键变化**：
  1. **新增原生 addon 家族，缺平台包就完全起不来**。`node-addon-require-builtin` 经 `node-addon-native-custom-loader` 加载平台可选包 `<name>-<platform>-<arch>`，上游只发布 darwin/linux-gnu/win32-msvc 七个预编译包、**没有 android**；`runtimeSuffix()` 对未知平台回退成 `${process.platform}-${process.arch}`（Termux 即 `android-arm64`），解析失败后 loader 会依次尝试 optional-package → local-build，但 published 安装不含 binding.gyp/src（上游 README 明说 "fail closed instead of compiling unvalidated local binaries"），于是 `dsh-app-boot` 的 `internalModules()`（**无条件** `createRequire(...)("node-addon-require-builtin")`，无 JS 回退）抛 `No usable native binding found` → host preparation 失败 → dsh 起不来。由 `patches/patch-dsh-android-require-builtin.js` 补平台包解决。
  2. 客户端 combo 惰性化已由上游原生 `lazyBody` 实现，补丁 02 的锚点必然失配（预期；02 已**移入 §12 弃用围栏**，只报 `[deprecated]` 而非失败，不影响运行）；补丁 01/03 仍命中。`resolveRgPath()` 也多了 electron `.asar` 归一化分支。
- 上游依赖大重组（client-ui 41→50 包）带来的**带安装脚本包**现为 5 个，已全部进 `ALLOW_SCRIPTS`：`@deepseek-ai/dsh-subprocess-local`、`koffi`、`node-pty`、`@google/genai`、`protobufjs`。其中 `koffi` 3.x 走 `@koromix/koffi-android-arm64`（上游有真 android 预编译，实测可加载）、`sharp` 仍走项目自己的 wasm32 回退。
- **JS 补丁锚点核对（可复现，正向更省事）**：`npm pack @deepseek-ai/dsh-client-modules@<ver> @deepseek-ai/dsh-host-frontend-static@<ver>` → 解包 → 对上游源码**正向**打 `patches/01`、`02`、`03` → 与安装树 `diff` **逐字节一致**。本机已对 `0.1.5-rc.3` 验过：`client-modules/lib/index.js` 与 `host-frontend-static/lib/index.js` 均 IDENTICAL（安装树 = 上游 + 01/02/03，无额外漂移；其它差异来自第 4 节那几张 Android 补丁表与应用侧改动）。
- 本机最近一次实测通过的检查（0.1.7-rc.2）：`bash apply-js-patches.sh`（`01[skip] 02[deprecated] 03[skip]`，**退出码 0**——02 的锚点已失效，但它已**移入弃用围栏**（见 §12），只报 `[deprecated]` 不计失败；全新安装的树是 `01[ok] 02[deprecated] 03[ok]`。此前它留在活跃清单里，在 0.1.7 线上必然退 1、害得 `setup.sh` 8/9 每次喊一次狼）、`bash apply-rg-fix.sh`（解析出 `/data/data/com.termux/files/usr/bin/rg` = ripgrep 15.2.0）、`node patches/verify-android-link-fix.js --root …`（6 项全 `[OK]`）、`node patches/patch-dsh-android-flock.js`（产物可加载 + 真实加锁自检）、`node --expose-internals patches/patch-dsh-android-require-builtin.js --root …`（平台包按内容刷新/复用 + `internalModules()` 自检通过）、`node patches/verify-client-modules-lazy.js`（11 项全 PASS，entries=70/batches=3，启动到 token 11.74s）、`dsh web` 冷启动到 token ~12~34s、鉴权链路 303→cookie→200、日志无任何 warn/error。

## 3. 目录结构

| 路径 | 作用 |
|---|---|
| `setup.sh` | **主入口**。0~9 步：锚点预检 → 依赖 → Node headers → 安装 dsh → 后端兼容补丁 → sharp WASM 回退 + 硬链接验证 → 重建 `dsh` 包装脚本 → 安装启动/停止/重启脚本与权限层 → JS 性能补丁 → 汇总。默认简洁输出，原始命令写入 `~/dsh/setup.log`；`--verbose` / `SETUP_VERBOSE=1` 透传原始输出。安装/升级后必须重跑。 |
| `apply-js-patches.sh` | 应用 `patches/01`、`02`、`03` 三个 JS 性能补丁（静态资源 immutable 缓存头；客户端 combo 按需构建，冷启动 22s→12s；`newlineCount` 索引循环）。**分层设计**：`01/02` 面向 0.1.5 线，`03` 与版本无关。**两个区**：活跃清单 `PATCHES`（已应用 `[skip]`、应用成功 `[ok]`、失配/写失败 `[FAIL]` 且退非 0）与**已弃用围栏** `DEPRECATED_PATCHES`（锚点已失效但为旧线保留：能命中就照打并标 `[ok]（弃用围栏：在目标版本上仍然有效）`，命中不了只报 `[deprecated]`、**不计失败**；见 §12）。⚠️ `PATCHES` 的**顺序即语义**（02 必须先于 03），围栏只改报告与退出码、不得改执行顺序。 |
| `apply-rg-fix.sh` | 修复 grep/glob 报 `ripgrep launch failed`（软链系统 `rg` 到 `@vscode/ripgrep-android-arm64/bin/rg` + 给 `resolveRgPath()` 加回退，已识别 4 种上游形态）。**锚点漂移不再判死**：软链本身就能让 `@vscode/ripgrep` 解析成功，故未识别形态时只 `warn`，成败交给第 3 步 fresh node 的实际解析结果。 |
| `start_dsh.sh` | 启动/复用 `dsh web`：流式读日志取带 token 的鉴权 URL、`curl` 校验 303/302，然后按包名优先用 **Via**（`am start`）打开浏览器，找不到再回退系统默认浏览器。默认静默（提示/剪贴板只在 `DSH_HINTS=1`）。 |
| `stop_dsh.sh` | 安全停止：pid 文件 + 身份二次确认；梯子是「优雅窗口 `DSH_STOP_GRACE` → 补发一次 `SIGTERM` → `SIGKILL` 兜底」。 |
| `restart_dsh_now.sh` | 重启：复用 `stop_dsh.sh` + `start_dsh.sh --no-open`，写 `storage/dsh_restart.log`，最后 `curl` 确认端口。 |
| `config/cordis.patch.yml` | sandbox `danger-full-access` 配置层，安装到 `~/.dsh/profiles/web/cordis.patch.yml`（缺该层时**追加**，不覆盖用户其它配置层）。 |
| `patches/01-frontend-static-cache.patch` | 给 `dsh-host-frontend-static` 的 `/assets/` 加 immutable 缓存头、其余 `no-cache`。 |
| `patches/02-client-modules-lazy-compose.patch` | 客户端 combo 按需构建（`dsh-client-modules`），冷启动 22s→12s。**已弃用（在 §12 围栏里）**：0.1.7 起上游原生 `lazyBody` 取代了它，锚点随之消失；0.1.5 线上仍能命中（实测 0.1.5-rc.3 全命中），故保留而不删。 |
| `patches/03-client-modules-newline-count.patch` | 只把 `newlineCount()` 的 for-of 换成 `charCodeAt` 索引循环（10.8MB 实测 302ms→60ms）。锚点跨 0.1.5/0.1.7 稳定，是版本无关的兜底性能补丁；02 已应用时它自动 `[skip]`。 |
| `patches/patch-dsh-android-link.js` | Android 禁 hardlink 修复（会话直接发布改 `rename()`；no-replace 路径用「O_EXCL 占位 + rename」回退）。 |
| `patches/patch-dsh-android-flock.js` | Android flock 原生绑定：clang 编译 `src/flock.c` 为 `bin/android-<arch>/system.node`，改 `lib/flock.js` 在 android 下加载它；自带真实加锁自检。 |
| `patches/patch-dsh-android-require-builtin.js` | **dsh ≥0.1.7 启动前提**：在 `<dsh>/node_modules/` 生成 `node-addon-require-builtin-android-arm64` 平台包（纯 JS `requireBuiltin` 实现，`backend=napi`/`abi=napi-v9`），补上上游缺失的 android 预编译槽位；自带 `internalModules()` 自检。**失败必须中断安装**（缺它 dsh 起不来）。dsh <0.1.7（没有该 addon 家族）→ `[SKIP]` 退 0，前提是「定位到 dsh 安装根」与「entry 包存在」**解耦**。幂等按**内容**判定：三个文件与脚本模板逐字节一致才 `[OK]`，否则 `[REFRESHED]` 原地刷新（manifest 修正、模板更新、entry 包版本变化都能下发）。归属判定读 manifest 的 `dshAndroidPatch` **字段**、存在性看**目录**；非本补丁生成的包一律让路不覆盖（`[SKIP]`），可用性由同一次 `verify()` 断言——通过退 0、加载不了才退 1。`--root` 是硬契约：显式给出但定位不到 dsh 安装根即报错退 1，**不回落**其它候选。`name`/`os`/`cpu` 由包名与 `process.platform`/`process.arch` 推导，不写死。 |
| `patches/verify-android-link-fix.js` | 硬链接补丁验证（静态检查 + 临时目录真实运行：附件保存/去重、fs-local 新建文件在 `link()`=EACCES 下必须成功）。 |
| `patches/verify-client-modules-lazy.js` | 补丁 02 自检：`--port 0` 起临时实例，逐字节核对单条/批量 bundle 与 sourcemap、未知 URL 404、HEAD 200，并打印启动到 token 的秒数。 |
| `patches/verify-require-builtin-fixture.js` | `patch-dsh-android-require-builtin.js` 的**夹具自检**（8 用例 / 29 断言）：`mktemp` 假安装根 + `cp -a` entry/loader 两个小包，覆盖 `[CREATED]`/`[REFRESHED]`/让路/`dsh <0.1.7` 的 `[SKIP]`/`--root` 硬契约/外来包不被改写；只写临时目录，唯一读真实树之处是断言它**未被触碰**。 |
| `docs/index.html` | 说明文档站。 |
| `README.md` | 中英文用户文档（安装、修复项、FAQ、仓库结构）。 |

## 4. 安装/修补流程（`setup.sh`）

| 步骤 | 做什么 |
|---|---|
| `0/9` | **锚点预检** `anchor_precheck()`：只读检查 7 条「文件路径\|补丁后特征串\|标签」（路径支持通配）+ 1 条 `lib/profile-boot-*.js` 的 `forceExitOnce`/`interrupt(code)` 探测（停止梯子前提，内容哈希名故用通配）。未命中只 `warn`，不中断。 |
| `1/9` | `pkg update/install`（`cmake clang make binutils pkg-config python nodejs ripgrep`）；探测 npmjs/nodejs.org 是否慢，慢则**仅本次会话** export `npm_config_registry` / `npm_config_disturl` 到 npmmirror。 |
| `2/9` | `npx node-gyp install` 拉 Node headers，再往 `~/.cache/node-gyp/<ver>/include/node/common.gypi` 的 `'variables': {` 后插入 `'android_ndk_path%': ''`（Termux 无 NDK，否则 node-pty 构建失败）。 |
| `3/9` | `npm install -g @deepseek-ai/dsh`：`CFLAGS/CXXFLAGS=-target aarch64-linux-android30 -I$PREFIX/include`，`--allow-scripts="$ALLOW_SCRIPTS"`。校验 `node-pty` 的 `build/Release/pty.node` 能加载、koffi 预编译包能加载；node-pty 缺产物直接 `exit 1`。之后跑**白名单自检**：扫描安装树里所有带 `preinstall/install/postinstall` 的包，凡不在白名单内的列出并 `warn`（npm 会静默跳过它们的构建）——0.1.7 的依赖大重组就是靠它发现的。支持 `DSH_VERSION=<ver>` 钉版本。 |
| `4/9` | 后端兼容补丁，见下表。 |
| `5/9` | **sharp WASM 回退**：比对 `sharp` 与 `@img/sharp-wasm32` 版本，一致才跳过；否则在临时目录装同版本 wasm 包，先 `rm -rf` 再 `cp`（旧目录直接 `cp -r` 是合并、会版本混装），并补 `@emnapi`。之后立刻跑 **硬链接验证**（必须在这一步之后，见第 7 节）。 |
| `6/9` | 重建 `dsh` 包装脚本（`--expose-internals --no-warnings`，临时文件 + `mv -f` 原子替换，绝不 `cat >` 覆盖符号链接）。 |
| `7/9` | 把 `start/stop/restart` 三个脚本拷到 `~/dsh/`；把 `danger-full-access` 权限层写入/追加到 `~/.dsh/profiles/web/cordis.patch.yml`。 |
| `8/9` | `apply-js-patches.sh`（**可选增强**：失败只 `warn`，不中断）。 |
| `9/9` | 完成汇总（耗时、日志、下一步、注意事项）。 |

`4/9` 的补丁落点：

| 落点 | 方式 | 失败语义 |
|---|---|---|
| `node-addon-require-builtin-android-arm64`（新建平台包，放在 `<dsh>/node_modules/`，**不在** `@deepseek-ai/` 下） | `node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"` | **`error` + `exit 1`**（4-boot，会让安装硬中断）：缺它 dsh 在 host preparation 阶段就抛 `No usable native binding found`，**完全起不来**。dsh <0.1.7（没有该 addon 家族）时脚本自身 `[SKIP]` 退 0（该分支由夹具用例 5 守着） |
| `dsh-session-persistence-jsonl` / `dsh-attachment-local` / `dsh-fs-local` | `node patches/patch-dsh-android-link.js --root …` | 只 `warn`，继续 |
| `node-addon-system`（flock） | `node patches/patch-dsh-android-flock.js --root …` | 只 `warn`，继续（但发消息会失败） |
| `dsh-subprocess-local/lib/*.js`（android≡linux 终端检测） | `python3` 通配扫描整个 `lib/`，命中才写 | 未命中锚点 → 退出码 3 → `warn`，继续 |
| `dsh-client-ui-conversation/lib/client.js`（作曲栏「回车=换行」） | `python3` 单点插入 + `.dsh-android.bak` 备份 | **会中断安装**：锚点不唯一/失败 → 回滚备份 → `exit 1` |
| `dsh-tool-fs-search/lib/index.js`（ripgrep） | `bash apply-rg-fix.sh` | 脚本内部：锚点漂移只 `warn`；仅当 fresh node 实际解析 `resolveRgPath()` 失败才非 0 退出 → `setup.sh` 显式 `error`+`exit 1`（rg 不可用会让 grep/glob 全废） |

## 5. Web 鉴权与启动链路

dsh Web UI 用 **进程 launch token + 持久化签名 cookie** 鉴权：

1. 每次 `dsh web` 启动生成一个内存态 launch token；
2. 服务启动日志打印 `dsh web: http://127.0.0.1:3080/?token=<base64url>`；
3. 浏览器打开该 `?token=` URL → 服务端返回 `303` 并 `Set-Cookie`（`HttpOnly; SameSite=Strict` 的签名 cookie）；
4. 之后 `/` 和 `/api` 都走 cookie 鉴权；
5. token 只存在于当前进程（不落盘），签名 secret 存于 `~/.dsh` 的 credentials 中。

因此项目脚本必须遵守：

- `start_dsh.sh` 必须优先打开日志里的**带 token URL**，不能只开裸 URL（裸 URL 返回 401）。
- **⚠️ 等 token 必须在整个 `READY_TIMEOUT`（默认 90s）内持续等，不能「端口一响应就倒计时」**：端口会先开始响应 401，带 token 的 URL 要等 `announceReady()`（plugin loader settle 完）才打印，冷启动实测可达十几秒。早期写成「端口通但 token 无效满 5 次就开裸 URL」，冷启动几乎必然开裸 URL → 401（已用假 dsh 复现并修复）。
- 交给浏览器前先用 `curl` 校验该 URL 返回 `303/302`，避免日志里残留旧进程 token 时打开后仍 401；降级到裸 URL 时必须打印**具体原因**（`no-token` / 实际 HTTP 码），不要只说“若空白/401”。
- token 是**进程级且可重复使用**的（同一 token 连续请求都返回 303），所以校验用的 curl 不会“烧掉” token；303 之后浏览器地址栏显示裸 `/`，属正常设计。
- `restart_dsh_now.sh` 必须用 `--no-open`，并且让 dsh 输出写进同一个 `~/dsh/storage/dsh.log`，否则 `start_dsh.sh` 找不到当前进程的新 token。
- **不要为了鉴权去改 dsh 前端界面文件**：前端已经能通过 `?token=` 自动换 cookie，脚本只要保证打开正确的 URL、日志文件一致。

## 6. 写脚本的约定

### 6.1 语言与输出

- `setup.sh` 与 `apply-*.sh` 是 **bash**：`set -euo pipefail`，进度用 `info()/warn()/ok()/error()`，主步骤用 `step()`；注释与用户提示用中文；`apply-rg-fix.sh` 的英文注释保持原样。
- **脚本头部与权限统一**：所有脚本的 shebang 一律写 **Termux 绝对路径**（`#!/data/data/com.termux/files/usr/bin/bash` 或 `.../node`），**不用 `#!/usr/bin/env …`**（`/usr/bin` 不可解析，见第 7 节）；`.sh` 与 `.js` 一律置**可执行位**（755），于是 `bash x.sh` / `node x.js` / 直接 `./x` 三种调用都成立。新增脚本请照此对齐——`verify-client-modules-lazy.js` 曾是唯一例外（`env` shebang + 644），2026-09 已对齐。
- `start_dsh.sh` / `stop_dsh.sh` / `restart_dsh_now.sh` 的 **body 只用 POSIX sh**（不用 `local` / `[[ ]]` / 数组 / `<<<` / `$SECONDS`；`$(())`、`case`、参数展开都可用），要求 `bash -n` 与 `dash -n` 都能过（shebang 仍是 bash，用户可能用 `sh` 调）。**但“快”不靠换 shell**：本机实测 bash 空启动 11ms、dash 17ms，真正的成本是 **fork+exec ≈19ms**（100×`true` = 1.9s）——所以禁止在轮询里每次起子进程。等待用 `tail -n 0 -f` 流式读 + `kill -0` 内建探测，端口只探一次。
- `setup.sh` 输出：默认原始子命令输出进 `~/dsh/setup.log`（`run_hidden`），终端只显示摘要；`--verbose` 用 `tee` 透传；`NO_COLOR=1` 或非 TTY 自动关色。ANSI 序列预先算进变量（`C_*`），输出路径零 fork。
- **常驻状态行**（TTY 且非 `--verbose`）：从脚本开头一直显示到结束，后台 ticker 每 0.15s 重画 `[⠹] 当前步骤 · M:SS`。改输出代码时必须遵守：
  1. **⚠️ 正文必须把 `$SP_CLEAR` 并入同一次 `printf`**（`info/ok/warn/step` 已包装）。**不要写「先 `status_clear` 再 printf」**：那是两次 write，ticker 可能恰好插在中间把状态行画回来，正文与状态行叠成一行。`error` 走 stderr，故单独 `status_clear`（不把光标控制码混进被重定向的 stderr）。
  2. python3/node 子进程自己打印时要读 `SP_CLEAR`（已 `export`）；stderr 非 TTY 时不要往里写控制码（见 `ECLR`）。
  3. 子 shell 看不到父 shell 的变量更新，状态文案经 `STATUS_FILE` 传递；耗时直接用 `SECONDS`（bash 子 shell 会继承并继续累加）。
  4. `status_stop` 幂等，由末尾与 `on_exit` 双保险调用；`STATUS_FILE` 只在 TTY 模式创建（非 TTY 运行不留临时文件）。
  5. **⚠️ 状态行必须按终端实际宽度截断**：`status_cols()` 读 `stty size`（读不到按 30 列），预留 `reserved=9` + **时钟实际宽度**（别写死 5 列，跑满 100 分钟会变 6 列），中文按 2 列估算，判定非 ASCII 用 `${s//[ -~]/}`（`[[ == *[!-~]* ]]` 是语法错误，`[![:print:]]` 在 UTF-8 locale 下判不出中文）。超宽会折行，而 `\r\033[K` 只擦得掉当前行开头、折下去那截擦不掉，6.7 帧/秒重画会把屏幕一路刷下去（手机竖屏约 40 列，实测 4 秒滚屏 23 次）。**绝不给标签设“最小宽度”下限**（曾写 `[ budget -lt 6 ] && budget=6`，20 列终端直接超宽刷屏）——预算不够时让标签退化成空。trap `WINCH` 立刻重算列数，另有 ~3s 兜底轮询。

### 6.2 目标路径与进程

- 所有补丁都针对绝对路径 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/...` 下的已安装文件，不要假设相对路径，也不要 cd 到别处。
- **⚠️ 绝不用 `/usr/bin/dsh` 作读写目标**：`/usr` 在部分 shell/挂载命名空间**不可解析**（实测 `ls /usr` 报 No such file or directory）。一律用真实绝对路径 `/data/data/com.termux/files/usr/bin/dsh`（`$PREFIX_BIN/dsh`）。
- **⚠️ 同一原因会让 `npm` 直接执行失败，必须包一层**：Termux 的 `env` 在 `$PREFIX/bin/env`，`/usr/bin/env` 不存在，而 `npm` 是指向 `npm-cli.js`（shebang `#!/usr/bin/env node`）的符号链接 → 直接跑 `npm …` 报 `bad interpreter: /usr/bin/env: no such file or directory`（实测本机必现）。`setup.sh` 用 `NPM_CMD=(node "$NPM_REAL")` 包装（shebang 正常时自动回退裸 `npm`），**不要**在脚本里写裸 `npm`。Node 侧脚本更彻底：别调 `npm root -g`，直接用 `path.join(path.dirname(path.dirname(process.execPath)), "lib", "node_modules")` 从 `process.execPath` 推出全局根（`patches/patch-dsh-android-{link,flock}.js` 与 `verify-android-link-fix.js` 已如此改造，因此不传 `--root` 也能自动定位）。
- **⚠️ 绝不 `cat >` 覆盖 dsh 命令文件**：`npm install -g` 会把它做成指向 `lib/bin.js` 的**符号链接**，`cat >` 会 follow 链接、覆盖 dsh 真实入口代码（弄坏 dsh）。正确做法：写临时文件 + `mv -f "$DSH_TMP" "$DSH_CMD"` 原子替换目录项本身，**不 follow 目标、不碰 lib/bin.js**；**绝不要先 `rm -f "$DSH_CMD"`**（会在写失败时制造“命令丢失”的非原子窗口）。临时文件由 `on_exit`（全脚本唯一的 EXIT trap）清理——**不要**再注册 `trap 'rm -f …' EXIT`，那会覆盖 `on_exit`、吞掉其后所有步骤的失败日志。备份 `.dsh-android.bak` 只在验证成功或回滚成功后删除，回滚失败必须保留。
- 包装脚本内容统一为 `exec node --expose-internals --no-warnings <绝对路径>/lib/bin.js "$@"`（lib/bin.js 的 shebang 是 `#!/usr/bin/env node`，缺 `--expose-internals` 会让 HMR 崩）。
- **进程匹配用 `[b]in.js` 括号技巧**：`pgrep/pkill -f` 可能匹配到含模式串的调用 shell 自身，模式写成 `.../lib/[b]in.js web`（可用 `DSH_WEB_PATTERN` 覆盖以支持多安装并存）。
- **按 pid 文件杀进程前必做身份二次确认**：pid 可能被系统复用。kill 前须 `pgrep -f "$DSH_WEB_PATTERN" | grep -qx "$pid"` 或 `ps -p "$pid" -o args= | grep -q "$DSH_WEB_PATTERN"`（与 `stop_dsh.sh` 一致），否则跳过走兜底匹配。
- **停止梯子**：耗时不在 kill，而在等 node 收尾——实测单次 SIGTERM 后 dsh 要 **2~4s** 才优雅退出，但**第二次退出信号会让它立即强退**（`profile-boot` 的 `createProcessShutdown`：首个信号走 dispose、再收到信号直接 `process.exit`，实测 0.17s）。所以顺序是：优雅窗口 `DSH_STOP_GRACE`（默认 1.5s，`kill -0` 内建轮询 0.1s 步进、**不 fork curl/pgrep**）→ 补发一次 SIGTERM → `DSH_STOP_TIMEOUT`（默认 6s）后 SIGKILL 兜底；端口只在最后确认一次（进程在时端口必然还在，逐轮探端口纯属浪费 fork）。实测停止 3.7s → 2.2s。要完整优雅退出就把 `DSH_STOP_GRACE` 调大（如 6）。

### 6.3 打开浏览器

顺序：① `DSH_OPEN_APP=<包名/组件>`（显式覆盖）→ ② Via（默认 `DSH_VIA_APP=mark.via`，用 `am start -a android.intent.action.VIEW -d <url> <pkg>` 按包名打开）→ ③ 系统默认浏览器（`termux-open-url` 不带包名）→ ④ `DSH_OPEN_CHOOSER=1` 才用 `xdg-open --chooser`。按包名打开同时也避开了 PWA 对 `?token=` 的 scope 劫持。

- **⚠️ `termux-open-url <url> [pkg]` 的退出码不可用**：它内部 `am start … > /dev/null`（不重定向 stderr），包名不存在时只打印 `Error: Activity not started...` 但仍返回 0。判定要用 `am start` 自己的退出码（包名不存在 = 1，成功 = 0，本机实测）。
- **⚠️ 不要用 `am start … | grep` 判定成败**：管道退出码是 `grep` 的，会把失败当成功。要么直接看 `am` 的退出码，要么把输出先落文件。
- 启动脚本默认静默：PWA 排查提示与剪贴板复制只在 `DSH_HINTS=1` 时做。剪贴板 `termux-clipboard-set+get` 一次 0.75s 且本机 `get` 读不回（`copy_url` 自带读回校验，失败不谎报），自动打开浏览器时纯属浪费。正常启动只打印两行，复用已跑服务的路径实测 0.16~0.19s。

### 6.4 幂等、版本漂移与文档

- **幂等**：所有 `apply-*.sh` 和 `setup.sh` 中的修补必须可重复执行——已应用则跳过（grep 特征标记 / `patch -R --dry-run`），内容变化时原地刷新。新增修补者请保持这一约定。
- **版本漂移容错**：dsh 升级会清空并重组 node_modules，补丁可能失效。锚点找不到时必须打印警告并跳过、**不落盘**；只有确认锚点命中才可打印成功。`apply-js-patches.sh` 的 `[FAIL]` 与 `setup.sh` 4c 的退出码 3 即此约定。⚠️ 补丁一旦锚点失效，就**移出活跃清单、进 §12 的「已弃用围栏」**：不要留在活跃清单里每次刷 `[FAIL]`——`setup.sh` 8/9 会每次都报警，久了就是「狼来了」，真正需要人看的失配反而被淹没（0.1.7 的补丁 02 正是这么暴露的）。
- **不破坏上游**：只做最小侵入式文本替换；替换前用特征字符串确认目标仍在，替换后打印说明。
- **文档同步**：改脚本/补丁行为后，同步更新 `README.md`（**中文节 + 英文节都要改**）、`docs/index.html` 对应条目，以及本文件相关段落。三份文档互相引用，只改一处会立刻过时（历史教训：删掉前端注入后仍留了一大堆描述）。
- **项目记忆只有一个落点：本文件**。`AGENTS.md`（尤其第 7 节踩坑清单）就是本仓库的项目记忆，**不要另建 `.ai-memory/`、`memory/` 之类的记忆目录**——正文里「只改一处会立刻过时」同样适用于记忆，多一份存储必然漂移；操作流水交给 `git log`（提交信息已要求写清原因与实测数字），不需要额外的日程日志。
- 提交信息沿用日志里的风格：中文 Conventional Commits（`fix(stop): …` / `docs(readme,docs): …` / `perf(client-modules): …` / `chore: …`），正文写清**原因与实测数字**。

### 6.5 可调环境变量（脚本读取）

| 变量 | 默认 | 位置 | 作用 |
|---|---|---|---|
| `DSH_PORT` | `3080` | start/stop/restart | 服务端口 |
| `DSH_ORIGIN` | `127.0.0.1` | start | 交给浏览器的 origin；`localhost` 可绕开 PWA 对 `?token=` 的劫持 |
| `DSH_NO_OPEN` / `--no-open` | 空 | start | 只拉起服务并打印 URL，不打开浏览器 |
| `DSH_HINTS` | `0` | start | `1` 才打印 PWA 排查提示并尝试复制 URL 到剪贴板 |
| `DSH_READY_TIMEOUT` | `90` | start | 等带 token URL 的最长秒数 |
| `DSH_STOP_GRACE` | `1.5` | stop | 优雅退出窗口（秒，可含小数） |
| `DSH_STOP_TIMEOUT` | `6` | stop | 补发 SIGTERM 后等多久才 SIGKILL |
| `DSH_WEB_PATTERN` | `…/lib/[b]in.js web` | start/stop | 进程匹配模式（多安装并存时覆盖） |
| `DSH_VIA_APP` / `DSH_OPEN_APP` / `DSH_OPEN_CHOOSER` | `mark.via` / 空 / `0` | start | 浏览器选择 |
| `SETUP_VERBOSE` / `NO_COLOR` | 空 | setup | 透传原始输出 / 关色 |
| `DSH_VERSION` | 空（跟随 npm `latest`） | setup | **仅**灰度/回退时钉版本（`DSH_VERSION=<ver>`，`<ver>` 从 npm 取）；默认留空，别写死 |
| `DSH_PACKAGES_DIR` | dsh 的 `node_modules/@deepseek-ai` | apply-js-patches | 目标包目录 |
| `DSH_ROOT`、`RG_PATH` | dsh 安装根、`command -v rg` | apply-rg-fix | 目标根、指定系统 rg |
| `DSH_DIR` | dsh 安装根 | verify-client-modules-lazy | 目标根（link/flock/verify-link 用 `--root`） |

## 7. 实测踩坑清单（每条都真的踩过）

Shell 语义：

- **⚠️ 管道子 shell 里 `return 0` 不会从函数返回**：`f(){ … | while read l; do … return 0; done; }` 的 `return` 只结束那个子 shell；循环里对变量赋值也传不回父 shell。判定成功要看**结果文件非空**（`start_dsh.sh` 的 `RESULT_FILE` / `PORT_FILE` 就是干这个的）。
- **⚠️ `test -s` 判的是“大小>0”，不是“存在”**：`: > "$f"` 建出 0 字节文件，`[ -s "$f" ]` 永远为假（曾因此让“降级打开裸 URL”的路径完全不可达）。标记文件要用 `printf 'up' > "$f"`。
- **⚠️ `set -u` 下函数参数写 `${1:-}`**：`open_gui` 被无参调用时 `[ -n "$1" ]` 会直接报 unbound variable 中止。
- **⚠️ 临时文件路径不要用 `VAR=x cmd` 初始化**：那是在子 shell 里赋值，主 shell 里 `VAR` 仍为空。
- **⚠️ `on_exit` 里打印日志尾部必须写 `tail -25 "$SETUP_LOG" >&2`**：重定向从左到右生效，`tail … 2>/dev/null >&2` 会先把 stderr 指向 /dev/null，再把 stdout 复制成同一个 /dev/null，“最近日志”后面永远是空的。
- **⚠️ 别硬编码 `/tmp`：Termux 的临时目录是 `$PREFIX/tmp`**。Android 的 `/tmp` **存在但不可写**——它是 `shell:shell` 的 `drwxrwx--x`（**0771**），Termux 的 app uid 属 `others`，只有 `--x` 遍历权，写入直接 `Permission denied`（是**权限问题不是「目录不存在」**，本机实测，别按「不存在」去排查）。Termux 自己的临时目录是 `$PREFIX/tmp`（`/data/data/com.termux/files/usr/tmp`，权限 **1777** = 777 + sticky），`TMPDIR` 默认就指向它。写脚本/一次性命令的规矩：

  ```sh
  TMP="${TMPDIR:-$PREFIX/tmp}"
  [ -d "$TMP" ] || { mkdir -p "$TMP" && chmod 777 "$TMP"; }   # 上游默认 1777，777 已足够
  ```

  **真实症状**：`curl -c /tmp/jar "$URL"` **静默**不写 cookie 罐（不报任何错），于是出现「带 token 的 URL 返回 303、随后 `/` 却 401」，极易误判成 token 过期 / 服务有问题——按第 9 节验证 Web 鉴权链路时，罐子必须落 `$PREFIX/tmp`（或 `$HOME/.cache`）。Node 侧安全：实测 `os.tmpdir()` 在 Termux 上即使 `TMPDIR` 未设也返回 `$PREFIX/tmp`，故 `fs.mkdtempSync(path.join(os.tmpdir(), …))` 可直接用；但**显式** `mktemp -p /tmp` 必失败（`env -u TMPDIR` 下裸 `mktemp -d` 实测仍落 `$PREFIX/tmp`，属 Termux 侧的默认值，别依赖它）。

补丁正确性：

- **⚠️ 报「bad interpreter: /usr/bin/env」不是脚本 bug，是 Termux 的 shebang 陷阱**：任何 shebang 写 `#!/usr/bin/env …` 的可执行文件在 Termux 上都可能直接执行失败（`/usr/bin` 不可解析）。表现因调用方而异：zsh/bash 说 `bad interpreter`，`sh` 说 `not found`，**都很容易被误判成「包没装」或「命令不存在」**。判断方法：`node "$(command -v <cmd>)" --version` 能跑通就说明是 shebang 问题而非缺包。修法二选一：`node <real>.js <args>`，或 `readlink -f` 后按 `*.js` 分支包装。
- **⚠️ 升级 dsh 后第一件事是「跑起来」，不是「看补丁还在不在」**：0.1.7 引入 `node-addon-require-builtin` 后，**所有 Android 补丁都还在、全部自检通过，但 dsh 依然完全起不来**——因为新原生 addon 家族的 android 平台包缺失，`dsh-app-boot` 的 host preparation 直接失败。所以版本漂移的检查清单必须包含「`dsh web` 真的能起来 + 鉴权 303→cookie→200」，静态锚点检查只能证明「已知问题没复发」，不能证明「能跑」。
- **⚠️ 上游新增 `<name>-<platform>-<arch>` 平台包时，`process.platform === "android"` 会静默落到 `${platform}-${arch}` 回退分支**：`node-addon-native-custom-loader` 的 `runtimeSuffix()` 只特判 `darwin`、`linux`（再拼 libc 后缀）、`win32`，其余一律 `${process.platform}-${process.arch}`。于是解析 `node-addon-require-builtin-android-arm64` 必然失败。**排查这类问题的通用手法**：扫全树 `optionalDependencies` 里形如 `-(darwin|linux|win32|android|freebsd|openbsd)-` 的依赖，逐个 `require.resolve` 探测，列出「声明了但装不上」的清单，比逐个读源码快得多。
- **⚠️ `npm ls` 报 `UNMET DEPENDENCY` 不一定是问题——先看它在哪个依赖段**：`npm install -g` **从不安装** `devDependencies`，所以根包的 devDep（含 `@types/*`）在 `npm ls` 里必然 UNMET，属良性。本机 0.1.7-rc.2 实测 8 条**全部**是根包 devDependencies：`@deepseek-ai/dsh-{agent-loop-testkit,experimental-ptc-runtime-python,llm-mock-server,llm-replay,loader-smoke,sdk-client}@0.1.7-rc.2` + `@types/{js-yaml,ws}`；其中 6 个连注册表都没有 0.1.7-rc.2（`dsh-agent-loop-testkit` 的 dist-tags 是 `latest=0.0.1-rc.1`/`next=0.1.7-rc.1`），但全树 ripgrep 对 `*.js/*.mjs/*.cjs/*.ts` **零引用** → 运行期零影响，**不要**照 require-builtin 的模式去补平台包。判定顺序：① 看依赖段（`devDependencies`/`optionalDependencies` → 良性）；② 全树搜是否真有 import；③ 只有 `dependencies` 里「声明了但装不上」才是真问题。**别把两类混为一谈**：*缺失的*平台包不会以 UNMET 出现（entry 的 `optionalDependencies` 从未声明 android），但**本补丁生成的那个**会显示为 `extraneous`——实测与 `@img/sharp-wasm32`、`@emnapi/runtime`、`@vscode/ripgrep-android-arm64` 并列；`extraneous` 的意思是「在 `node_modules` 里但不在依赖树里」，正是本仓库自己补的那些包的正常形态，不是错误。
- **⚠️ loader 的「平台可选包」通道不要求 `.node` 文件**：`node-addon-native-custom-loader` 的 `tryRequirePackage()` 只按 `validateLoadedBinding()` 校验导出形状（`requireBuiltin`/`isAllowedInternalId` 是函数、`getNativeBindingInfo()` 返回 `{mode,product,backend,abi}` 且 `backend∈{napi,nodeabi}`、`abi` 与 backend 自洽），**不检查文件是不是 ELF**。所以缺预编译包时可以自己写平台包顶上，不必交叉编译。上游之所以用原生 addon，是为了在**没有** `--expose-internals` 时也能 `require("internal/*")`；而本项目 `dsh` 包装脚本必定带 `--expose-internals`（第 6 步重建，缺了 HMR 会崩），该前提下纯 JS 实现完全够用。⚠️ 但纯 JS **没有**可靠的绕过 `--expose-internals` 的办法（`process.binding("natives")` 只给源码，esm/cjs loader 必须是真实例），所以这条路径与「包装脚本必须带 `--expose-internals`」是**强绑定**的，别拆开。
- **⚠️ 硬阻断补丁要和「只 warn」的补丁区分开**：`node-addon-require-builtin` 平台包缺失 = dsh 起不来，必须 `error` + `exit 1`；link/flock 这类「功能受损但能跑」才是 `warn` + 继续。把两者混成一种语义，会出现「setup 全绿但 dsh 根本起不来」或反过来「一个可选功能缺失就中断安装」。
- **⚠️ 生成物的 manifest 要填包名、「幂等」要比内容**：`patch-dsh-android-require-builtin.js` 早期把 `manifest.name` 写成了平台包目录的**绝对路径**（`name: pkgDir`）——运行期无害（loader 走 `tryRequirePackage()` 只校导出形状，`createEntryApi` 读的是 **entry 包** 的 name），但那是非法 npm 元数据；同时旧的 `reuse` 只查 `[dsh-android-require-builtin]` 标记、**不比内容**，导致「改了脚本模板但已装设备永远不更新」。现在改为：写 `platformPackageFiles()` 算出目标内容 → 逐字节比对一致才 `[OK]`、不一致 `[REFRESHED]` 原地刷新；**归属判定读 manifest 的 `dshAndroidPatch` 字段、存在性看目录**（旧实现按 `index.js` 是否存在判断，会把 `main` 指向 `prebuilt/` 的外来包当成「不存在」并改写；按子串扫标记又会把描述里恰好提到它的外来包认成自己的）；非本补丁生成的包一律**让路不覆盖**，可用性交给同一次 `verify()`——能加载就 `[SKIP]` 退 0，加载不了才报错退 1。⚠️ 这里**最初写成直接 throw**，而 `setup.sh` 4-boot 把非 0 当硬阻断，等于把「上游发了合法包」判成安装失败；「不覆盖他人的东西」的正确表现是**让路**，不是中断。同源问题还有 manifest 的 `os`/`cpu`：必须由 `process.platform`/`process.arch` 推导，写死 `arm64` 在 armv7 上就是假元数据。通用教训：生成型补丁 ① 幂等判定不要只看标记、要比内容；② 「不是我的东西」要么让路要么报错，但**报错前先确认它真的不可用**。
- **⚠️ 定位契约别依赖「正要判断存在性的那个东西」；`--root` 必须是硬契约**：`patch-dsh-android-require-builtin.js` 早期要求「找到 `node_modules/node-addon-require-builtin/package.json` 才算 dsh 安装根」，于是紧接着那句「entry 包不存在 → `[SKIP]` 退 0」（dsh <0.1.7 的场景）**恒不可达**——健康的 0.1.5 回退安装会被 4-boot 硬中断，而文档四处承诺会 SKIP（本机用夹具复现：伪造 `execPath` 指向空前缀 → `无法定位 dsh 安装根` + 退 1）。现在安装根按「`package.json` 的 `name` 为 `@deepseek-ai/dsh`，或该目录下就有 entry 包」判定，与 entry 包解耦。同时 `--root` 改成硬契约：显式给出但定位不到就**报错退 1**，不回落其它候选——旧行为会静默回落到生产树，让「夹具测试不碰安装树」变成假话（本机也复现过）。
- **⚠️ 客户端资源 URL 的形态在 0.1.7 变了两处**：`patches/verify-client-modules-lazy.js` 在 0.1.7 上先后踩了两次。① 清单里的 URL **不再带前导 `/`**（`plugins/??…` 而非 `/plugins/??…`），直接 `` `${origin}${url}` `` 会拼出 `http://127.0.0.1:43655plugins/??…` → `fetch` 抛 `ERR_INVALID_URL`；拼接必须统一补前导斜杠。② 响应体尾部 `//# sourceMappingURL=` 的形态也变了：0.1.5 是**完整路径**（`/plugins/??….map&rev=`），0.1.7 改成 **combo 内相对形态**（`??….map&rev=`，不含 `plugins/` 前缀），而**实际可取的 URL 仍须带 `plugins/` 前缀**。所以校验要「从 `??` 处切开」分别推出「可取 URL = 前缀+ids」与「响应体里的 ref = ids」，两种 ref 形态都接受。这类断言不要写死单一字符串形态。
- **⚠️ 改 `node:fs/promises` 导入时只增不删**：`patch-dsh-android-link.js` 的 `ensureFsImport()` 只追加名字。曾有版本把 `link` 从导入里删掉，但同文件 `defaultFileSystem` / `publishCurrentExclusive` 仍在引用 `link`，导致 dsh 启动即 `ReferenceError: link is not defined`。删除导入前必须确认全文不再引用它。
- **⚠️ 补丁必须报真话**：锚点未命中却 `str.replace()` 后写回文件、还打印 “patched”，就是假成功（4c 早期版本如此，终端功能静默失效）。同理 `anchor_precheck` 的 marker 必须是「打上补丁后才会出现」的特征串，否则预检永远 OK、掩盖问题。
- **⚠️ 4c 锚点可能在内容哈希 bundle 里**：0.1.5-rc.1 起 `createProcessInspector()` 被内联进 `dsh-subprocess-local/lib/runner-launch-*.js`，`lib/index.js` 里已找不到 `new LinuxProcessInspector(...)`。所以要按通配扫描整个 `lib/`，命中才报成功——不要退回「只 grep 单个固定文件 + 无条件打印成功」。
- **⚠️ 4d 作曲栏回车补丁要「先量唯一性再插」**：入口锚点 `if (event !== null && isComposingEvent(event, recentlyComposing)) return true;` 必须**恰好出现 1 次**、前导必须是纯空白缩进，否则退出码 2 → 回滚 `.dsh-android.bak` → `exit 1`（会让安装中断，**但不是唯一**：4-boot 平台包、4f ripgrep、3/9 的 npm 失败同样 `exit 1`，见第 4 节）。备份只在补丁成功或回滚成功后删除；回滚失败必须保留并提示人工处理。
- **⚠️ 硬链接验证必须排在 sharp WASM 回退之后**：附件测试要 `import dsh-attachment-local`，该模块加载时 `import sharp`；`npm install` 清空 node_modules 后 sharp 在回退前必然加载失败，会误报“硬链接修复验证未通过”。
- **⚠️ 判 sourcemap 不能用 `url.endsWith(".map")`**：combo URL 形如 `/plugins/??<id>/client.js.map&rev=<rev>`，`.map` 后面还有 `&rev=`（早期版本因此把 JS 当 map 回了）。补丁 02 的 `singleRecords` / `singleResponses` 每次 `compose()` 重建，`rebuilt()` 后 rev 变化不会命中旧 URL。
- **⚠️ 性能补丁要分层，别把「上游已原生实现」的改动写死成唯一补丁**：0.1.7 起上游有原生 `lazyBody`，补丁 02 的 `compose()` 惰性化锚点必然失配。若只留 02，冷启动优化会在新版上整段失效。现在拆成 `02`（0.1.5 线全量）+ `03`（只改 `newlineCount`，锚点跨版本稳定），02 失配时 03 仍保住热点；02 已应用时 03 会因同一处已改而 `[skip]`，不冲突。
- **⚠️ 补丁脚本的「锚点失配」不等于「功能不可用」，别让它中断安装**：`apply-rg-fix.sh` 第 1 步把系统 `rg` 软链成 `@vscode/ripgrep-android-arm64/bin/rg` 后，`@vscode/ripgrep` 只做 `require.resolve(\`${platformPkg}/bin/rg\`)`（**不校验 package.json**），所以**软链本身就足以让解析成功**，源码回退补丁只是双保险。因此 0.1.7 新增 electron `.asar` 形态导致锚点漂移时，脚本改为只 `warn`，成败交给第 3 步 fresh node 的实际解析结果——否则「版本升级 → 锚点漂移 → `exit 1` → `setup.sh` 在 4f 整体中断」。
- **⚠️ 带 token 的日志行可能不止一个 URL**：上游在绑定 `0.0.0.0` 时会打印 `dsh web: <loopback url> (LAN: <lan url>)`。`grep -oE … | tail -1` 会取到 **LAN** 地址。必须「先取最后一条含 `token=` 的行，再取该行**第一个** URL」（`start_dsh.sh` 的 `last_auth_url()` 与 `wait_for_token()` 都已如此）。loopback 部署下这条后缀不会出现，属潜在坑。
- **⚠️ `lib/profile-boot-*.js` 是内容哈希名**：`createProcessShutdown`（首个信号走 dispose、重复信号 `forceExitOnce` 立即 `process.exit`）就定义在这里，文件名随版本变化（0.1.5-rc.3 为 `profile-boot-Dk-7KqJc.js`）。停止梯子依赖这个语义，但**不能硬编码文件名**；`anchor_precheck()` 用通配探测，漂移只 `warn`（后果是停止退化为等满 `DSH_STOP_TIMEOUT`）。
- **⚠️ sharp wasm 版本必须与 sharp 一致**：只看“目录在不在”会在 sharp 升级后残留旧 wasm 时报假成功；装错版本比不装更糟。拷贝前先 `rm -rf` 目标目录（`cp -r src dst/` 是**合并**，旧文件会留下造成版本混装），且别忘了 `@emnapi/runtime`。
- **⚠️ `patch -p1` 的 cwd 是包目录的「父级」，不是包目录本身**：`patches/0x-*.patch` 里写的是 `a/dsh-client-modules/lib/index.js`，所以必须 `cd <...>/node_modules/@deepseek-ai`（= `apply-js-patches.sh` 的 `$DSH_PACKAGES_DIR`）再 `-p1`。`cd` 进包目录本身再 `-p1`，它会去找 `dsh-client-modules/lib/index.js` 而**永远失配**——本会话我因此把「已应用的 01/03」误判成「锚点失配」**两次**（审计脚本报红，真实状态却完好）。写这类核对脚本时：路径一律绝对路径、cwd 与 `apply-js-patches.sh` 完全一致，否则「红」不代表有问题。
- **⚠️ 锚点失效的补丁必须「移入已弃用围栏」，不要留在活跃清单里刷失败；而围栏不得改变执行顺序**：失效补丁留在活跃清单 → 每次 `setup.sh` 8/9 都报警 → 报警成为常态 → 真失配被淹没（0.1.7 的补丁 02 就是这样把用户吓到一次）。移进围栏后只报 `[deprecated]`、不计失败（见 §12）。⚠️ 我按「活跃/弃用」重排执行顺序时踩了坑：**02 与 03 改同一段 `newlineCount`，02 必须先于 03**，把 02 挪到后面执行会让它在**老线上也失配**（实测 0.1.5-rc.3：顺序正确时 02 命中、03 自动 `[skip]`；顺序颠倒时 02 报失配）。围栏只改报告与退出码语义。

## 8. 常用命令

```bash
bash setup.sh                       # 一键安装/升级 + 全量修补（简洁模式）
bash setup.sh --verbose             # 同时显示原始子命令输出
bash ~/dsh/start_dsh.sh             # 启动 dsh web 并打开带 token 浏览器
bash ~/dsh/stop_dsh.sh              # 停止
bash ~/dsh/restart_dsh_now.sh       # 重启 dsh web（不打开浏览器）
```

单独重跑某个修补（避免整树重装）：

```bash
bash apply-rg-fix.sh
bash apply-js-patches.sh
# 硬链接补丁与验证
node patches/patch-dsh-android-link.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/verify-android-link-fix.js --root "$DSH_DIR/node_modules/@deepseek-ai"
# Android flock 原生绑定（编译 + 自检 + 改 flock.js）
node patches/patch-dsh-android-flock.js --root "$DSH_DIR/node_modules/@deepseek-ai"
# Android require-builtin 平台包（dsh 启动前提；--expose-internals 必须带）
node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"
# require-builtin 夹具自检（8 用例 / 29 断言；只写临时目录，不碰安装树）
node patches/verify-require-builtin-fixture.js
# 补丁 02 自检（--port 0 临时实例，不打扰正在跑的服务）
node patches/verify-client-modules-lazy.js [--timeout 120]
```

其中 `DSH_DIR=/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`。

升级前后都该做的版本核对（**脚本里不要写死版本号**）：

```bash
node -p "require('$DSH_DIR/package.json').version"                         # 当前装的 dsh
node "$(readlink -f "$(command -v npm)")" view @deepseek-ai/dsh dist-tags   # 上游 latest/next/alpha
```

⚠️ 本机 npm 走的是 `registry.npmmirror.com`（见 `~/.npmrc`），镜像可能滞后：要判断「上游到底发了什么」，直连官方注册表核对，例如
`curl -s https://registry.npmjs.org/@deepseek-ai/dsh | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s)["dist-tags"]))'`。

## 9. 测试与验证

- 无单测框架。验证依赖真实 Termux+Android 环境实际运行（`dsh web` 起在 `127.0.0.1:3080`）。
- **语法自检**：`bash -n setup.sh`、`bash -n apply-*.sh`；三个运行期脚本还要 `dash -n`。
- **幂等自检**：连续跑两次修补，第二次应全部 `[OK]`/`[skip]`。
- **ripgrep**：`apply-rg-fix.sh` 第 3 步用 fresh node 子进程实际解析 `resolveRgPath()` 并打印版本自证。
- **硬链接**：`patches/verify-android-link-fix.js` 做静态检查 + 临时目录真实运行（附件保存/去重、fs-local 新建文件在 `link()`=EACCES 下必须成功），**不读取/修改 `~/.dsh/sessions`**；必须在 sharp 回退之后跑。
- **flock**：`patches/patch-dsh-android-flock.js` 自带运行时自检（真实 open 两个 fd：首次加锁成功、第二次竞争返回 `EAGAIN`），失败非 0 退出。
- **require-builtin（启动前提，优先级最高）**：`node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"`——会生成/按内容刷新平台包（三个文件与模板逐字节一致才 `[OK]`；不一致 `[REFRESHED]`；已存在但**无本补丁标记**则 `[SKIP]` 让路，只有该包连 loader 自检都过不了才退 1），然后走**真实 entry 包**断言 `getBindingInfo()`（`backend=napi`/`abi=napi-v9`/`bindingSource=optional-package`）与 `internalModules()` 依赖的 5 个 internal 模块成员（`getOrInitializeCascadedLoader`、`Module._resolveFilename`、`getCjsConditions`、`getDefaultConditions`、`defaultResolve`）全部可用。**反例验证**：手工 `rm -rf` 平台包后 `dsh web` 必须复现 `No usable native binding found for node-addon-require-builtin-android-arm64`，再跑补丁必须恢复。
- **require-builtin 夹具自检**：`node patches/verify-require-builtin-fixture.js`——**8 用例 / 29 断言**（本机全绿）。覆盖 `[CREATED]`、`[REFRESHED]`（含「内容一致不落盘」）、让路、`dsh <0.1.7` 的 `[SKIP]` 退 0、`--root` 硬契约、以及两个归属判定回归用例（外来包**无 `index.js`**、外来包描述里**恰好含标记串**，都不得被改写）。只写 `mktemp` 目录；唯一读真实安装树的地方是断言它**未被触碰**。
- **⚠️ 版本漂移的端到端验收**：`bash setup.sh` 之后**必须**真的 `bash ~/dsh/start_dsh.sh` 起一次，并确认日志出现 `dsh web: …?token=`、带 token URL 返回 303、换 cookie 后 `/` 返回 200、日志里无 `warn/error/fatal`。静态锚点全绿 ≠ 能跑（0.1.7 的 require-builtin 就是反例：所有已知补丁都自检通过，dsh 仍起不来）。
- **补丁 02**：`node patches/verify-client-modules-lazy.js`（内部用 `--port 0` 起临时实例；核对单条/批量 bundle 与 sourcemap、未知 URL 404、HEAD 200，并打印启动到 token 的秒数）。手工做等价验证时：另起一个实例 `dsh web --no-open --port 3099`，从 `GET /` 的 `window["__DSH_BOOT__"]` 取资源 URL，与**未打补丁实例**（`3080`，进程里还是旧代码）逐字节比对——单条 bundle、sourcemap、批量 combo 都必须一致（rev 含随机 nonce，比对前去掉 `//# sourceMappingURL=` 那行；`.map` 请求的 URL 要把每个 `client.js` 换成 `client.js.map`），未知 URL 仍须 404。冷启动 A/B 就测“从启动到日志出现 token”的秒数，同一脚本交替跑：本机实测未打补丁 22.6s / 打补丁 12.5s。
- **补丁 01/02/03 锚点核对**：见第 2 节（`npm pack` + 正向打补丁 + `diff`）。分版本预期：0.1.5 线 `01[ok] 02[ok]（弃用围栏：在旧线上仍有效） 03[skip]`（退 0，实测 0.1.5-rc.3）；0.1.7 线全新安装 `01[ok] 02[deprecated] 03[ok]`、已打过的树 `01[skip] 02[deprecated] 03[skip]`（均退 0）。`[deprecated]` 是围栏里的旧补丁、不算问题；出现 `[FAIL]` 才是需要人看的真漂移。
- **安装脚本白名单自检**：`setup.sh` 3/9 末尾扫描安装树，列出所有带安装脚本的包并标 `[allowed]`/`[UNCOVERED]`；出现 `[UNCOVERED]` 即说明 npm 跳过了构建步骤，需把包名补进 `ALLOW_SCRIPTS`。
- **鉴权启动**：`start_dsh.sh` 的 `check_url()` 用 `curl` 校验日志里的 token URL 返回 303/302；返回 401 说明 token 过期/日志陈旧，应重启 dsh。
- **⚠️ 别拿本机的 3080 做破坏性实验**：这台设备上 3080 往往正跑着当前会话的 GUI，`stop_dsh.sh` / `restart_dsh_now.sh` 会把它一起停掉；验证补丁优先用 `--port 0` / `--port 3099` 的临时实例。

## 10. 安全注意（这个仓库有意为之）

- **`danger-full-access`**：Android/Termux 无 bwrap/landlock 命名空间沙箱，受限权限模式会让 bash 工具报 `SANDBOX_UNAVAILABLE`，因此必须放开权限模式。**等于关闭进程沙箱，agent 可执行任意命令，仅建议个人设备。**
- 服务只监听 `127.0.0.1`（本机），不走局域网。
- API Key 存于 `~/.dsh/.credentials.yaml`（0600），不进日志、不进进程环境；Web 鉴权签名 secret 同样在 `~/.dsh`，不要写进日志、环境变量或仓库。
- 改动仅应针对上述绝对安装路径下的 dsh 文件，不要动系统其它位置。

## 11. 为 dsh 打补丁时应遵循（设计约束）

- 凡涉及 `link()`（Android 部分 ROM 通过 SELinux 禁用 hardlink）：会话日志【直接发布】改 `rename()`；带 no-replace 语义的发布（会话迁移、附件发布/别名、write 新建文件）在 link 报 `EACCES`/`EPERM`/`EMLINK`/`ENOSYS`/`ENOTSUP` 时回退到「O_EXCL 占位 + rename」；附件祖先遍历/清理容忍 `EACCES`/`ENOENT`。
- **原生 addon 的 Android 适配（两条路，按上游是否发布源码选）**：① 上游带 `src/*.c`（`@deepseek-ai/node-addon-system` 的 `flock.c`）→ clang 编译成本机 `system.node`（Node headers 取 `$PREFIX/include/node` 或 `~/.cache/node-gyp/<ver>/include/node`）并改加载分支；② 上游**只有预编译包、不发源码**（`node-addon-require-builtin`，其 README 明说 published install "fail closed instead of compiling unvalidated local binaries"）→ 按 loader 的「平台可选包」约定自建 `<name>-android-arm64` 包，导出形状过 `validateLoadedBinding()` 即可，纯 JS 亦可（前提运行时带 `--expose-internals`）。其它原生 addon 若报 “not supported on android-*” 或 “No usable native binding found” 可照这两条模式处理。
- 终端 / 平台检测：`process.platform === "android"` 需视同 `"linux"` 处理（见第 7 节 4c 的通配扫描要求）。
- **`03-client-modules-newline-count`**：只改 `newlineCount()` 的循环写法（`for (const char of value)` → `charCodeAt` 索引循环），不改语义。它是**版本无关**的兜底性能补丁，锚点在 0.1.5/0.1.7 上都稳定。
- **`02-client-modules-lazy-compose`（仅 0.1.5 线）**：改 `dsh-client-modules/lib/index.js` 三处——① `newlineCount` 用 `charCodeAt` 索引循环（与 for-of 等价；10.8MB 实测 302ms→60ms）；② `buildCombo` 行数只数一次（`line += lineCount + 1`，尾部 `;\n` 恰好一行）；③ `compose()` 不再为每条记录急切构建 artifact，改为 `singleRecords`（URL → 记录 + 是否 sourcemap）+ `singleResponses` 按需缓存，`bundleResource` 用 `?? this.singleResponse(url)` 兜底。背景：`dsh web` 启动期间 `ClientModuleRegistry` 会因 `internal/plugin` 事件**全量重组约 10 次**（构造 1 次 + 每个后加载的 client bundle 各 1 次，实测 table 大小 0→48→…→60），每次都为全部 client bundle 重算批量 combo + 逐条 combo；本机 10.8MB client 源码、60 条记录时一次 compose 约 2s，故光是组合就占冷启动一半以上；挂载的 client 插件越多越慢。
- **本仓库不改动 dsh 前端界面文件**：不注入 CSS/JS、不改 `dsh-web-frontend/dist/index.html` 的 viewport、不改 manifest。历史上有 `apply-frontend.sh` + `patches/mobile.css`/`mobile.js` 做移动端适配，已删除——它依赖上游构建产物里的类名/DOM 结构，每次 dsh 升级都会漂移，且与「只做最小侵入式文本替换」的约定冲突。前端问题请提给上游；本仓库只保证启动/鉴权链路与后端兼容修补。

## 12. 已弃用补丁围栏（deprecated fence）

**策略：补丁的锚点一旦失效，就移出活跃清单、进这道围栏；不要留在原处每次刷 `[FAIL]`。**

理由：留在活跃清单里的失效补丁会让 `apply-js-patches.sh` 每次都退非 0、`setup.sh` 8/9 每次都报警。
报警一旦成为常态，真正需要人看的失配就被淹没（「狼来了」）——0.1.7 的补丁 02 就是这么把用户吓到一次的。

围栏规则（由 `apply-js-patches.sh` 的 `DEPRECATED_PATCHES` + `deprecated_reason()` 实现）：

- 围栏补丁**仍在 `PATCHES` 的顺序位置上执行**（顺序即语义：02 必须先于 03，两者改同一段 `newlineCount`），
  但报告与退出码语义不同：能命中 → `[ok] …（弃用围栏：在目标版本上仍然有效）`；
  命中不了 → `[deprecated] <原因>`，**不计入 failed、不影响退出码**。
- 每个围栏补丁必须在 `deprecated_reason()` 里写清**为什么失效**与**什么条件下复活**。
- 围栏**只改报告与退出码，不得改执行顺序**（见上）。
- 与「删除」的区别：删除是彻底不再支持（如已删的 apiproxy history slim 那批）；围栏是**保留但降级**，
  旧版本线仍可能需要。该删该围，看是否还有目标版本能命中。

| 补丁 | 失效版本 | 原因 | 复活条件 |
|---|---|---|---|
| `02-client-modules-lazy-compose` | 0.1.7 | 上游用原生 `lazyBody` 实现了 combo 按需构建（同一优化），补丁锚点随之消失 | 上游移除 `lazyBody`；或仍需支持 0.1.5 线——实测 0.1.5-rc.3 上 01/02/03 仍能全部命中，故保留在围栏里 |
