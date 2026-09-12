# AGENTS.md

给 AI agent 与协作者的维护须知：这套胶水怎么工作、改哪里、别踩什么。面向用户的使用文档在 `README.md`（中英双语）与 `docs/index.html`。

## 1. 仓库定位（这是什么）

`deepseek-harness-android` 是一个**安装与兼容性修补工具包**，用于在 **Android 手机的 Termux** 里一键部署并原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`，DeepSeek 官方的 agent harness，类比 Claude Code），然后通过 Web UI（`http://127.0.0.1:3080`）在手机浏览器里使用。

它不是独立的源码项目。仓库里只有**胶水脚本 + 补丁**：它们负责安装上游 `dsh` 包，再对**已安装到 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`** 的那份文件做 Android 兼容修补（直接改写目标文件）。绝大多数改动不落在这份仓库里，而是落在 `dsh` 安装目录里——**所以「仓库干净」不等于「设备已修好」**：升级 dsh / Node 后必须重跑 `bash setup.sh`。

## 2. 版本基准与已验证状态

- 当前基准：`@deepseek-ai/dsh` **0.1.5-rc.1**，其 `node_modules/@deepseek-ai/*` 为 **0.1.5-rc.2**（`@deepseek-ai/node-addon-system` 用独立版本号，当前 0.1.2）。
- **JS 补丁锚点核对（可复现）**：`npm pack @deepseek-ai/dsh-client-modules@0.1.5-rc.2 @deepseek-ai/dsh-host-frontend-static@0.1.5-rc.2` → 把安装树里对应的 `lib/index.js` 拷出来、**反向**打上 `patches/01`、`patches/02` → 与上游源码 `diff` **逐字节一致**。也就是说这两个包的这两个文件上，安装树 = 上游源码 + 补丁 01/02，没有额外漂移（其它差异来自第 4 节那几张 Android 补丁表与应用侧改动）。
- 本机最近一次实测通过的检查：`bash apply-js-patches.sh`（两个补丁都 `[skip]`，退出码 0）、`bash apply-rg-fix.sh`（fresh node 解析出 `/data/data/com.termux/files/usr/bin/rg` = ripgrep 15.2.0）、`node patches/verify-android-link-fix.js --root …`（6 项全 `[OK]`）。

## 3. 目录结构

| 路径 | 作用 |
|---|---|
| `setup.sh` | **主入口**。0~9 步：锚点预检 → 依赖 → Node headers → 安装 dsh → 后端兼容补丁 → sharp WASM 回退 + 硬链接验证 → 重建 `dsh` 包装脚本 → 安装启动/停止/重启脚本与权限层 → JS 性能补丁 → 汇总。默认简洁输出，原始命令写入 `~/dsh/setup.log`；`--verbose` / `SETUP_VERBOSE=1` 透传原始输出。安装/升级后必须重跑。 |
| `apply-js-patches.sh` | 应用 `patches/01`、`02` 两个 JS 性能补丁（静态资源 immutable 缓存头；客户端 combo 按需构建，冷启动 22s→12s）。幂等：已应用 `[skip]`，锚点失配 `[FAIL]` 且不落盘（`setup.sh` 对它的非 0 退出码只告警）。 |
| `apply-rg-fix.sh` | 修复 grep/glob 报 `ripgrep launch failed`（软链系统 `rg` 到 `@vscode/ripgrep-android-arm64/bin/rg` + 给 `resolveRgPath()` 加回退）。幂等；`setup.sh` 里失败会中断安装。 |
| `start_dsh.sh` | 启动/复用 `dsh web`：流式读日志取带 token 的鉴权 URL、`curl` 校验 303/302，然后按包名优先用 **Via**（`am start`）打开浏览器，找不到再回退系统默认浏览器。默认静默（提示/剪贴板只在 `DSH_HINTS=1`）。 |
| `stop_dsh.sh` | 安全停止：pid 文件 + 身份二次确认；梯子是「优雅窗口 `DSH_STOP_GRACE` → 补发一次 `SIGTERM` → `SIGKILL` 兜底」。 |
| `restart_dsh_now.sh` | 重启：复用 `stop_dsh.sh` + `start_dsh.sh --no-open`，写 `storage/dsh_restart.log`，最后 `curl` 确认端口。 |
| `config/cordis.patch.yml` | sandbox `danger-full-access` 配置层，安装到 `~/.dsh/profiles/web/cordis.patch.yml`（缺该层时**追加**，不覆盖用户其它配置层）。 |
| `patches/01-frontend-static-cache.patch` | 给 `dsh-host-frontend-static` 的 `/assets/` 加 immutable 缓存头、其余 `no-cache`。 |
| `patches/02-client-modules-lazy-compose.patch` | 客户端 combo 按需构建（`dsh-client-modules`），冷启动 22s→12s。 |
| `patches/patch-dsh-android-link.js` | Android 禁 hardlink 修复（会话直接发布改 `rename()`；no-replace 路径用「O_EXCL 占位 + rename」回退）。 |
| `patches/patch-dsh-android-flock.js` | Android flock 原生绑定：clang 编译 `src/flock.c` 为 `bin/android-<arch>/system.node`，改 `lib/flock.js` 在 android 下加载它；自带真实加锁自检。 |
| `patches/verify-android-link-fix.js` | 硬链接补丁验证（静态检查 + 临时目录真实运行：附件保存/去重、fs-local 新建文件在 `link()`=EACCES 下必须成功）。 |
| `patches/verify-client-modules-lazy.js` | 补丁 02 自检：`--port 0` 起临时实例，逐字节核对单条/批量 bundle 与 sourcemap、未知 URL 404、HEAD 200，并打印启动到 token 的秒数。 |
| `docs/index.html` | 说明文档站。 |
| `README.md` | 中英文用户文档（安装、修复项、FAQ、仓库结构）。 |

## 4. 安装/修补流程（`setup.sh`）

| 步骤 | 做什么 |
|---|---|
| `0/9` | **锚点预检** `anchor_precheck()`：只读检查 7 条「文件路径\|补丁后特征串\|标签」（路径支持通配）。未命中只 `warn`，不中断。 |
| `1/9` | `pkg update/install`（`cmake clang make binutils pkg-config python nodejs ripgrep`）；探测 npmjs/nodejs.org 是否慢，慢则**仅本次会话** export `npm_config_registry` / `npm_config_disturl` 到 npmmirror。 |
| `2/9` | `npx node-gyp install` 拉 Node headers，再往 `~/.cache/node-gyp/<ver>/include/node/common.gypi` 的 `'variables': {` 后插入 `'android_ndk_path%': ''`（Termux 无 NDK，否则 node-pty 构建失败）。 |
| `3/9` | `npm install -g @deepseek-ai/dsh`：`CFLAGS/CXXFLAGS=-target aarch64-linux-android30 -I$PREFIX/include`，`--allow-scripts=…dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs`。校验 `node-pty` 的 `build/Release/pty.node` 能加载、koffi 预编译包能加载；node-pty 缺产物直接 `exit 1`。 |
| `4/9` | 后端兼容补丁，见下表。 |
| `5/9` | **sharp WASM 回退**：比对 `sharp` 与 `@img/sharp-wasm32` 版本，一致才跳过；否则在临时目录装同版本 wasm 包，先 `rm -rf` 再 `cp`（旧目录直接 `cp -r` 是合并、会版本混装），并补 `@emnapi`。之后立刻跑 **硬链接验证**（必须在这一步之后，见第 7 节）。 |
| `6/9` | 重建 `dsh` 包装脚本（`--expose-internals --no-warnings`，临时文件 + `mv -f` 原子替换，绝不 `cat >` 覆盖符号链接）。 |
| `7/9` | 把 `start/stop/restart` 三个脚本拷到 `~/dsh/`；把 `danger-full-access` 权限层写入/追加到 `~/.dsh/profiles/web/cordis.patch.yml`。 |
| `8/9` | `apply-js-patches.sh`（**可选增强**：失败只 `warn`，不中断）。 |
| `9/9` | 完成汇总（耗时、日志、下一步、注意事项）。 |

`4/9` 的补丁落点：

| 落点 | 方式 | 失败语义 |
|---|---|---|
| `dsh-session-persistence-jsonl` / `dsh-attachment-local` / `dsh-fs-local` | `node patches/patch-dsh-android-link.js --root …` | 只 `warn`，继续 |
| `node-addon-system`（flock） | `node patches/patch-dsh-android-flock.js --root …` | 只 `warn`，继续（但发消息会失败） |
| `dsh-subprocess-local/lib/*.js`（android≡linux 终端检测） | `python3` 通配扫描整个 `lib/`，命中才写 | 未命中锚点 → 退出码 3 → `warn`，继续 |
| `dsh-client-ui-conversation/lib/client.js`（作曲栏「回车=换行」） | `python3` 单点插入 + `.dsh-android.bak` 备份 | **唯一会中断安装的补丁**：锚点不唯一/失败 → 回滚备份 → `exit 1` |
| `dsh-tool-fs-search/lib/index.js`（ripgrep） | `bash apply-rg-fix.sh` | 失败即中断（`setup.sh` 是 `set -e`，rg 不可用会让 grep/glob 全废） |

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
- **版本漂移容错**：dsh 升级会清空并重组 node_modules，补丁可能失效。锚点找不到时必须打印警告并跳过、**不落盘**；只有确认锚点命中才可打印成功。`apply-js-patches.sh` 的 `[FAIL] 锚点失配` 与 `setup.sh` 4c 的退出码 3 即此约定。
- **不破坏上游**：只做最小侵入式文本替换；替换前用特征字符串确认目标仍在，替换后打印说明。
- **文档同步**：改脚本/补丁行为后，同步更新 `README.md`（**中文节 + 英文节都要改**）、`docs/index.html` 对应条目，以及本文件相关段落。三份文档互相引用，只改一处会立刻过时（历史教训：删掉前端注入后仍留了一大堆描述）。
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

补丁正确性：

- **⚠️ 改 `node:fs/promises` 导入时只增不删**：`patch-dsh-android-link.js` 的 `ensureFsImport()` 只追加名字。曾有版本把 `link` 从导入里删掉，但同文件 `defaultFileSystem` / `publishCurrentExclusive` 仍在引用 `link`，导致 dsh 启动即 `ReferenceError: link is not defined`。删除导入前必须确认全文不再引用它。
- **⚠️ 补丁必须报真话**：锚点未命中却 `str.replace()` 后写回文件、还打印 “patched”，就是假成功（4c 早期版本如此，终端功能静默失效）。同理 `anchor_precheck` 的 marker 必须是「打上补丁后才会出现」的特征串，否则预检永远 OK、掩盖问题。
- **⚠️ 4c 锚点可能在内容哈希 bundle 里**：0.1.5-rc.1 起 `createProcessInspector()` 被内联进 `dsh-subprocess-local/lib/runner-launch-*.js`，`lib/index.js` 里已找不到 `new LinuxProcessInspector(...)`。所以要按通配扫描整个 `lib/`，命中才报成功——不要退回「只 grep 单个固定文件 + 无条件打印成功」。
- **⚠️ 4d 作曲栏回车补丁要「先量唯一性再插」**：入口锚点 `if (event !== null && isComposingEvent(event, recentlyComposing)) return true;` 必须**恰好出现 1 次**、前导必须是纯空白缩进，否则退出码 2 → 回滚 `.dsh-android.bak` → `exit 1`（这是唯一会中断安装的补丁）。备份只在补丁成功或回滚成功后删除；回滚失败必须保留并提示人工处理。
- **⚠️ 硬链接验证必须排在 sharp WASM 回退之后**：附件测试要 `import dsh-attachment-local`，该模块加载时 `import sharp`；`npm install` 清空 node_modules 后 sharp 在回退前必然加载失败，会误报“硬链接修复验证未通过”。
- **⚠️ 判 sourcemap 不能用 `url.endsWith(".map")`**：combo URL 形如 `/plugins/??<id>/client.js.map&rev=<rev>`，`.map` 后面还有 `&rev=`（早期版本因此把 JS 当 map 回了）。补丁 02 的 `singleRecords` / `singleResponses` 每次 `compose()` 重建，`rebuilt()` 后 rev 变化不会命中旧 URL。
- **⚠️ sharp wasm 版本必须与 sharp 一致**：只看“目录在不在”会在 sharp 升级后残留旧 wasm 时报假成功；装错版本比不装更糟。拷贝前先 `rm -rf` 目标目录（`cp -r src dst/` 是**合并**，旧文件会留下造成版本混装），且别忘了 `@emnapi/runtime`。

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
# 补丁 02 自检（--port 0 临时实例，不打扰正在跑的服务）
node patches/verify-client-modules-lazy.js [--timeout 120]
```

其中 `DSH_DIR=/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`。

## 9. 测试与验证

- 无单测框架。验证依赖真实 Termux+Android 环境实际运行（`dsh web` 起在 `127.0.0.1:3080`）。
- **语法自检**：`bash -n setup.sh`、`bash -n apply-*.sh`；三个运行期脚本还要 `dash -n`。
- **幂等自检**：连续跑两次修补，第二次应全部 `[OK]`/`[skip]`。
- **ripgrep**：`apply-rg-fix.sh` 第 3 步用 fresh node 子进程实际解析 `resolveRgPath()` 并打印版本自证。
- **硬链接**：`patches/verify-android-link-fix.js` 做静态检查 + 临时目录真实运行（附件保存/去重、fs-local 新建文件在 `link()`=EACCES 下必须成功），**不读取/修改 `~/.dsh/sessions`**；必须在 sharp 回退之后跑。
- **flock**：`patches/patch-dsh-android-flock.js` 自带运行时自检（真实 open 两个 fd：首次加锁成功、第二次竞争返回 `EAGAIN`），失败非 0 退出。
- **补丁 02**：`node patches/verify-client-modules-lazy.js`（内部用 `--port 0` 起临时实例；核对单条/批量 bundle 与 sourcemap、未知 URL 404、HEAD 200，并打印启动到 token 的秒数）。手工做等价验证时：另起一个实例 `dsh web --no-open --port 3099`，从 `GET /` 的 `window["__DSH_BOOT__"]` 取资源 URL，与**未打补丁实例**（`3080`，进程里还是旧代码）逐字节比对——单条 bundle、sourcemap、批量 combo 都必须一致（rev 含随机 nonce，比对前去掉 `//# sourceMappingURL=` 那行；`.map` 请求的 URL 要把每个 `client.js` 换成 `client.js.map`），未知 URL 仍须 404。冷启动 A/B 就测“从启动到日志出现 token”的秒数，同一脚本交替跑：本机实测未打补丁 22.6s / 打补丁 12.5s。
- **补丁 01/02 锚点核对**：见第 2 节（`npm pack` + 反向 dry-run + `diff`）。
- **鉴权启动**：`start_dsh.sh` 的 `check_url()` 用 `curl` 校验日志里的 token URL 返回 303/302；返回 401 说明 token 过期/日志陈旧，应重启 dsh。
- **⚠️ 别拿本机的 3080 做破坏性实验**：这台设备上 3080 往往正跑着当前会话的 GUI，`stop_dsh.sh` / `restart_dsh_now.sh` 会把它一起停掉；验证补丁优先用 `--port 0` / `--port 3099` 的临时实例。

## 10. 安全注意（这个仓库有意为之）

- **`danger-full-access`**：Android/Termux 无 bwrap/landlock 命名空间沙箱，受限权限模式会让 bash 工具报 `SANDBOX_UNAVAILABLE`，因此必须放开权限模式。**等于关闭进程沙箱，agent 可执行任意命令，仅建议个人设备。**
- 服务只监听 `127.0.0.1`（本机），不走局域网。
- API Key 存于 `~/.dsh/.credentials.yaml`（0600），不进日志、不进进程环境；Web 鉴权签名 secret 同样在 `~/.dsh`，不要写进日志、环境变量或仓库。
- 改动仅应针对上述绝对安装路径下的 dsh 文件，不要动系统其它位置。

## 11. 为 dsh 打补丁时应遵循（设计约束）

- 凡涉及 `link()`（Android 部分 ROM 通过 SELinux 禁用 hardlink）：会话日志【直接发布】改 `rename()`；带 no-replace 语义的发布（会话迁移、附件发布/别名、write 新建文件）在 link 报 `EACCES`/`EPERM`/`EMLINK`/`ENOSYS`/`ENOTSUP` 时回退到「O_EXCL 占位 + rename」；附件祖先遍历/清理容忍 `EACCES`/`ENOENT`。
- **原生 addon 的 Android 适配**：上游 `@deepseek-ai/node-addon-system` 只发布 linux/darwin 预编译包。`flock` 路径用 clang 编译其自带 `src/flock.c` 为 `bin/android-<arch>/system.node`，并改 `lib/flock.js` 在 `android` 下加载本地绑定（Node headers 取 `$PREFIX/include/node` 或 `~/.cache/node-gyp/<ver>/include/node`）。其它原生 addon 若报 “not supported on android-*” 可照此模式处理。
- 终端 / 平台检测：`process.platform === "android"` 需视同 `"linux"` 处理（见第 7 节 4c 的通配扫描要求）。
- **`02-client-modules-lazy-compose`**：改 `dsh-client-modules/lib/index.js` 三处——① `newlineCount` 用 `charCodeAt` 索引循环（与 for-of 等价；10.8MB 实测 302ms→60ms）；② `buildCombo` 行数只数一次（`line += lineCount + 1`，尾部 `;\n` 恰好一行）；③ `compose()` 不再为每条记录急切构建 artifact，改为 `singleRecords`（URL → 记录 + 是否 sourcemap）+ `singleResponses` 按需缓存，`bundleResource` 用 `?? this.singleResponse(url)` 兜底。背景：`dsh web` 启动期间 `ClientModuleRegistry` 会因 `internal/plugin` 事件**全量重组约 10 次**（构造 1 次 + 每个后加载的 client bundle 各 1 次，实测 table 大小 0→48→…→60），每次都为全部 client bundle 重算批量 combo + 逐条 combo；本机 10.8MB client 源码、60 条记录时一次 compose 约 2s，故光是组合就占冷启动一半以上；挂载的 client 插件越多越慢。
- **本仓库不改动 dsh 前端界面文件**：不注入 CSS/JS、不改 `dsh-web-frontend/dist/index.html` 的 viewport、不改 manifest。历史上有 `apply-frontend.sh` + `patches/mobile.css`/`mobile.js` 做移动端适配，已删除——它依赖上游构建产物里的类名/DOM 结构，每次 dsh 升级都会漂移，且与「只做最小侵入式文本替换」的约定冲突。前端问题请提给上游；本仓库只保证启动/鉴权链路与后端兼容修补。
