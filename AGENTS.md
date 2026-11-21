# AGENTS.md

给 AI agent 与协作者的维护须知：这套胶水怎么工作、改哪里、别踩什么。面向用户的使用文档在 `README.md`（中英双语）与 `docs/index.html`。

> 📄 **安装期修改、版本适配与验证证据见 [`REPORTS.md`](REPORTS.md)**。改脚本/补丁行为后，先更新 `REPORTS.md` 对应条目，再同步 README / docs。

## 1. 仓库定位（这是什么）

`deepseek-harness-android` 是一个**安装与兼容性修补工具包**，用于在 **Android 手机的 Termux** 里一键部署并原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`），然后通过 Web UI（`http://127.0.0.1:3080`）在手机浏览器里使用。

它不是独立的源码项目。仓库里只有**胶水脚本 + 补丁**：它们负责安装上游 `dsh` 包，再对**已安装到 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`** 的那份文件做 Android 兼容修补（直接改写目标文件）。绝大多数改动不落在这份仓库里，而是落在 `dsh` 安装目录里——**所以「仓库干净」不等于「设备已修好」**：升级 dsh / Node 后必须重跑 `bash setup.sh`。

### 1.1 硬性范围（2026-11-21 收紧，不要再扩）

1. **只服务 Termux/Android**：与 Android 兼容无关的优化、安装后端、UX 调整一律不做。
2. **不改动 dsh 前端**：不注入 CSS/JS、不改 `dsh-web-frontend`、不改 `dsh-client-ui-*` 的界面行为（历史上那条「作曲栏回车=换行」补丁已删除）。
3. **只保留安装期补丁**：运行期不加 hook / loader / monkey patch，只允许安装期静态替换、编译原生绑定、生成包装脚本。
4. **安装后端只有 npm**：`npm install -g`；历史上短暂存在过的 `--pnpm` 安装路径与 pnpm 运行时供给都已删除。

## 2. 版本基准与已验证状态

- **适配基线**：`0.2.2-rc.5`（npm `latest`）。补丁锚点在 rc.5 的隔离安装树上核对：require-builtin 平台包生成、link 三包全 `[PATCHED ]`、flock `[BUILT ]` + 运行时自检、rg 两代落点命中、权限层合并、subprocess 4c 命中；Web 链路 token→303→cookie→200、日志零 warn/error。
- **仍支持**：`0.2.2-rc.1` / `0.2.2-rc.3`（补丁按语义形状匹配，不按版本号分支）。
- **本机环境（2026-11-21）**：Node `v26.13.1`、npm `12.2.3`、ripgrep `15.2.0`、Termux aarch64、无 root；系统 Go `1.27.4`（仅用于 AOCI 工具链，与 dsh 无关）。
- **⚠️ 版本号只表示「撰写/实测时点」，绝不能当逻辑依赖**：脚本与补丁一律**不得按版本号分支**。升级前后用 `node -p "require('$DSH_DIR/package.json').version"` 与 `npm view @deepseek-ai/dsh dist-tags` 核对实际版本。
- **安装布局**：3/8 直接 `npm install -g @deepseek-ai/dsh` 到 npm 默认全局目录 `$PREFIX/lib/node_modules/@deepseek-ai/dsh`（**真实目录**）；原生需求是补丁能直接改写这棵树。pnpm 的全局布局（store 符号链接 + `global/v11/<hash>`）与补丁落点假设不兼容，**不要**把 pnpm 重新引入。
- **带安装脚本的包（全闭包 5 个）**：`@deepseek-ai/dsh-subprocess-local`、`node-pty`、`@google/genai`、`protobufjs` 进 `ALLOW_SCRIPTS`；**`koffi` 进 `SKIP_SCRIPTS`**（npm 12 上放进白名单会拖死整次安装；运行期只在 win32 分支懒加载）。3/8 末尾自检表把 koffi 标 `[skipped]`、其余不在白名单的标 `[UNCOVERED]` 并退 3。
- **本机 npm 策略**：npm 12 的 `--allow-scripts` 是强制的（白名单内失败 → 整次安装退 1）；用户显式 `strict-allow-scripts=true` 会让 `SKIP_SCRIPTS` 里的 koffi 变硬错误，因此 3/8 直接拒绝该配置并提示关掉。

## 3. 目录结构

| 路径 | 作用 |
|---|---|
| `setup.sh` | **主入口**。0~8 步：锚点预检（只读）→ 依赖 → Node headers → 安装 dsh（npm 全局真实目录；安装前摘旧 symlink、移开旧 `dsh` 包装）→ 后端兼容补丁 → sharp WASM 回退 + 硬链接验证 → 重建 `dsh` 包装 → 运行期脚本 + 权限层 → 汇总。默认简洁输出，原始命令写入 `~/dsh/setup.log`；`--verbose` 透传。参数只有 `--verbose`；`--pnpm` / `--npm` 打印「参数已废弃」并退 1。 |
| `apply-rg-fix.sh` | 修复 grep/glob 的 `ripgrep launch failed`：软链系统 `rg` 到 `@vscode/ripgrep-android-arm64/bin/rg` + 给 `resolveRgPath()` 加回退。**多宿主**：≤rc.1 在 `dsh-tool-fs-search`，rc.3+ 拆到新包 `dsh-util-ripgrep`；消费者文件静默跳过。锚点漂移只 `warn`，成败交给 fresh node 实测解析。 |
| `start_dsh.sh` | 启动/复用 `dsh web`：流式读日志取带 token URL → `curl` 校验 303 → 按包名优先 Via → 回退系统浏览器。先探端口再决定是否拉起；启动失败立即报原因；结束打印本次耗时。 |
| `stop_dsh.sh` | 安全停止：pid 文件 + 身份二次确认；「优雅窗口 → 补发 SIGTERM → SIGKILL」。没有可管进程但端口仍响应时在 stderr 提醒。 |
| `restart_dsh_now.sh` | 复用 stop + start `--no-open`，日志写同一个 `dsh.log`，最后 `curl` 确认端口。 |
| `config/cordis.patch.yml` | 权限层（**两条**：`sandbox-policy.mode = danger-full-access` + `approval.policy = never`）。每条前有哨兵 `# >>> dsh-android-layer-entry`，供按条目补缺。 |
| `patches/apply-profile-patch.js` | 权限层安装器：按内容分类（缺文件 `[CREATED]` / 空数组模板 `[REPLACED]` / 已有层补缺 / 残留裸 `[]` `[REPAIRED]` / 齐备 `[OK]`），写盘前后用 dsh 自己的 `loadOverlayPatches()` 校验，坏文件一字节不动。`--root` 是硬契约。 |
| `patches/patch-dsh-android-require-builtin.js` | **dsh 启动前提**：在 `<dsh>/node_modules/` 生成 `node-addon-require-builtin-android-arm64` 纯 JS 平台包（`requireBuiltin` / `isAllowedInternalId` / `getNativeBindingInfo`，`backend=napi` / `abi=napi-v9`）。**失败必须中断安装**。幂等按内容逐字节比较；归属读 manifest 的 `dshAndroidPatch` 字段；外来包让路。 |
| `patches/patch-dsh-android-link.js` | 硬链接修复：会话直接发布改 `rename()`；no-replace 路径用「O_EXCL 占位 + rename」回退。只支持 0.2.2+ 的 `options.createIfAbsent` 形状。`--root` 硬契约；幂等看 helper 的**函数定义**。 |
| `patches/patch-dsh-android-flock.js` | Android flock 原生绑定：clang 编译 `src/flock.c` 为 `bin/android-<arch>/system.node`，改 `lib/flock.js` 在 android 下加载；自带真实加锁自检。幂等判定看剥离注释后的真 android 分支。 |
| `patches/verify-android-link-fix.js` | 硬链接补丁验证（静态检查 + 临时目录真实运行）。**必须在 sharp 回退之后跑**。 |
| `patches/verify-*fixture.js`、`verify-setup-static-check.sh`、`verify-test-effectiveness.js`、`verify-all-checks.sh` | **脚本级测试**：5 个夹具 / 193 条断言（require-builtin 27、profile 41、guards 52、runtime-scripts 40、rg 33）+ 静态契约 40 条 + 变异测试（8 注入回归 + 4 对照组）。`bash patches/verify-all-checks.sh [--verbose] [--full]`；只读或只写临时目录。 |
| `docs/index.html` | 说明文档站。 |
| `README.md` | 中英文用户文档。 |
| `REPORTS.md` | 修改与适配报告（范围、证据、升级风险）。 |

## 4. 安装/修补流程（`setup.sh`）

| 步骤 | 做什么 |
|---|---|
| `0/8` | **锚点预检** `anchor_precheck()`：只读检查 **5 条**「路径\|补丁后特征串\|标签」规格 + **3 个特殊探测**（`lib/profile-boot-*.js` 的 `forceExitOnce`/`interrupt(code)`、require-builtin android 平台包、ripgrep 两代宿主）。未命中只 `warn`。 |
| `1/8` | `pkg update/install`（cmake clang make binutils pkg-config python nodejs ripgrep git）；探测镜像是否慢。 |
| `2/8` | 优先用 Termux 自带 headers（`$PREFIX/include/node`）；没有才 `npx node-gyp install` 并给缓存 `common.gypi` 插 `'android_ndk_path%': ''`。⚠️ 提示文本禁止反引号命令替换。 |
| `3/8` | `npm install -g @deepseek-ai/dsh`，`CFLAGS/CXXFLAGS=-target aarch64-linux-android30 -I$PREFIX/include`，`--allow-scripts="$ALLOW_SCRIPTS"`、`--ignore-scripts=false`。安装前摘旧 hold symlink、把旧 `$PREFIX/bin/dsh` 包装原子移开（npm bin link 会 `EEXIST`，失败由 `on_exit` 还原、成功由 6/8 重建）；装完校验 `pty.node` 可加载、跑白名单自检、报告 npm allow-scripts 策略（`strict-allow-scripts=true` 直接拒绝）。支持 `DSH_VERSION=<ver>`。 |
| `4/8` | 后端兼容补丁：require-builtin 平台包（**硬阻断**）→ link → flock → subprocess 平台检测（通配扫描 `lib/`）→ ripgrep（**硬阻断**）。 |
| `5/8` | sharp WASM 回退：`sharp` 与 `@img/sharp-wasm32` 版本一致才跳过；否则临时目录装同版本 → 先 `rm -rf` 再 `cp`（`cp -r` 是合并，会版本混装）→ 补 `@emnapi`。之后立刻跑硬链接验证。 |
| `6/8` | 重建 `dsh` 包装脚本（`--expose-internals --no-warnings`，临时文件 + `mv -f` 原子替换）。 |
| `7/8` | 拷入 start/stop/restart；调 `patches/apply-profile-patch.js` 安全合并权限层。 |
| `8/8` | 完成汇总。 |

失败语义：**硬阻断**（中断安装）= require-builtin 平台包、ripgrep 实际解析失败、node-pty 产物缺失、sharp wasm 缺失、权限层不可解析；其余（link / flock / subprocess / 锚点漂移）只 `warn`。

## 5. Web 鉴权与启动链路

1. 每次 `dsh web` 启动生成内存态 launch token；
2. 日志打印 `dsh web: http://127.0.0.1:3080/?token=<base64url>`；
3. 打开该 URL → `303` + `Set-Cookie`（`HttpOnly; SameSite=Strict` 签名 cookie）；
4. 之后 `/` 与 `/api` 走 cookie；token 不落盘，签名 secret 在 `~/.dsh` credentials。

因此：`start_dsh.sh` 必须等**带 token 的 URL**（端口先回 401 属正常）、用 `curl` 校验 303/302、把 `DSH_PORT` 显式传成 `--port`；`restart_dsh_now.sh` 必须 `--no-open` 且写同一个 `dsh.log`。**不要为了鉴权去改前端文件。**

## 6. 写脚本的约定

### 6.1 语言与输出

- `setup.sh` / `apply-rg-fix.sh` 用 **bash**（`set -euo pipefail`），进度用 `info/ok/warn/error/step`；注释与提示用中文。
- **shebang 一律 Termux 绝对路径**（`#!/data/data/com.termux/files/usr/bin/bash` 或 `.../node`），**不用** `#!/usr/bin/env …`；`.sh` 与 `.js` 一律 755。
- `start/stop/restart` 的 body 只用 POSIX sh（`bash -n` 与 `dash -n` 都要过）；禁止在轮询里起子进程（fork+exec ≈19ms），用 `tail -f` 流式读 + `kill -0` 内建。
- `setup.sh` 默认原始输出进 `~/dsh/setup.log`；`--verbose` 用 `tee` 透传；`NO_COLOR`/非 TTY 关色。
- **常驻状态行**：正文必须把 `$SP_CLEAR` 并入**同一次 printf**（拆成两次会被 ticker 插进中间）；`error` 走 stderr 单独 `status_clear`；状态行按终端实际宽度截断（中文按 2 列），**绝不设最小宽度下限**。

### 6.2 目标路径与进程

- 所有补丁针对绝对路径 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/...`。
- **绝不用 `/usr/bin/dsh`**：`/usr` 在 Termux 上不可解析。
- **npm 必须包一层**：直接跑 `npm …` 会因 `npm-cli.js` 的 `#!/usr/bin/env node` 报 `bad interpreter`；用 `NPM_CMD=(node "$NPM_REAL")`。
- **绝不 `cat >` 覆盖 dsh 命令文件**（它是符号链接）：写临时文件 + `mv -f`；不要先 `rm -f`。
- 进程匹配用 `[b]in.js` 括号技巧；按 pid 文件杀进程前必须身份二次确认；停止梯子「优雅窗口 → 补发 SIGTERM（dsh 二次信号立即强退）→ SIGKILL」。
- 端口只探一次；端口有响应但本机看不到 dsh 进程 → 不拉起第二个实例，直接报占用并退 1。

### 6.3 打开浏览器

顺序：`DSH_OPEN_APP` → Via（`DSH_VIA_APP=mark.via`，`am start` 按包名）→ 系统默认浏览器 → `DSH_OPEN_CHOOSER=1` 才 `xdg-open --chooser`。判定用 `am start` 的退出码（`termux-open-url` 的退出码不可用）。

### 6.4 幂等、版本漂移与文档

- **幂等**：已应用则跳过（特征标记 / `patch -R --dry-run`），内容变化时原地刷新。
- **版本漂移容错**：锚点找不到必须打印警告并跳过、**不落盘**；只有锚点命中才可报成功。目标版本线已不支持的补丁**直接删除**（连同夹具与文档），不要留下永远打不上的补丁——报警成常态后，真失配会被淹没。
- **不破坏上游**：最小侵入式文本替换；替换前确认目标仍在。
- **改动必须落在仓库**：手工改安装树只算临时验证，必须回填成脚本/补丁；问题先在夹具或 `--port 0/3099` 临时实例复现，别拿 3080 当实验场。
- **文档同步**：改行为后同步 `README.md`（中文节 + 英文节）、`docs/index.html`、本文件与 `REPORTS.md`。
- **项目记忆只有一个落点：本文件**。不要另建 `.ai-memory/`、`memory/`；操作流水交给 `git log`。
- 提交信息：中文 Conventional Commits（`fix(stop): …` / `docs(readme,docs): …` / `chore: …`），正文写清原因与实测数字。

### 6.5 可调环境变量（脚本读取）

| 变量 | 默认 | 位置 | 作用 |
|---|---|---|---|
| `DSH_PORT` | `3080` | start/stop/restart | 端口；⚠️ dsh 不读它，必须转成 `--port` |
| `DSH_ORIGIN` | `127.0.0.1` | start | 交给浏览器的 origin |
| `DSH_NO_OPEN` / `--no-open` | 空 | start | 只拉起服务 |
| `DSH_HINTS` | `0` | start | `1` 才打印 PWA 提示并复制 URL |
| `DSH_READY_TIMEOUT` | `90` | start | 等 token URL 的最长秒数 |
| `DSH_STOP_GRACE` / `DSH_STOP_TIMEOUT` | `1.5` / `6` | stop | 停止梯子 |
| `DSH_WEB_PATTERN` | `…/lib/[b]in.js web` | start/stop | 进程匹配（多安装并存） |
| `DSH_VIA_APP` / `DSH_OPEN_APP` / `DSH_OPEN_CHOOSER` | `mark.via` / 空 / `0` | start | 浏览器选择 |
| `SETUP_VERBOSE` / `NO_COLOR` | 空 | setup | 透传输出 / 关色 |
| `DSH_VERSION` | 空（跟随 npm `latest`） | setup | 仅灰度/回退时钉版本 |
| `DSH_SETUP_PREFIX` | 空 | setup | **仅测试夹具**：把生产前缀换到临时目录 |
| `DSH_PACKAGES_DIR` | dsh 的 `node_modules/@deepseek-ai` | apply-rg-fix? | 注意：`apply-rg-fix.sh` 用 `DSH_ROOT` |
| `DSH_ROOT` / `RG_PATH` | dsh 安装根 / `command -v rg` | apply-rg-fix | 目标根 / 系统 rg |
| `DSH_DIR` | dsh 安装根 | verify-setup-static-check | 目标根 |

## 7. 实测踩坑清单（每条都真的踩过）

Shell 语义：

- **⚠️ 双引号里的反引号是命令替换，会真的执行**：`warn "… `npm i -g …` …"` 会中途偷偷重装 dsh。提示文本不要用反引号包命令（静态契约已拦截）。
- **⚠️ 管道子 shell 里 `return`/`break` 不会影响父流程**：`tail -f … | while` 里的 `break` 只结束子 shell，`tail` 仍挂着。改用 FIFO + `done < "$TAIL_PIPE"`。
- **⚠️ `tail -n 0 -f` 只在启动后读**：进程瞬崩会漏原因。用 `tail --pid=<pid>` + 结束后 `kill -0` 复核。
- **⚠️ `test -s` 判的是「大小>0」**：标记文件用 `printf 'up' > "$f"`。
- **⚠️ 临时目录是 `$PREFIX/tmp`**：Android 的 `/tmp` 存在但**不可写**（0771，无写权限）；`curl -c /tmp/jar` 会**静默**不写 cookie 罐，制造「token 303 但 / 401」的假象。

补丁正确性：

- **⚠️ 按语义形状匹配，不按版本号**：上游重写时先读新实现找同一语义，再重锚；跨两代形状的补丁把两套块都写进去、按 `src.includes` 选。
- **⚠️ 补丁目标会搬家**：rc.3 把 `resolveRgPath()` 从 `dsh-tool-fs-search` 拆到 `dsh-util-ripgrep`；候选列表要收两代落点，消费者文件静默跳过。
- **⚠️ `bad interpreter: /usr/bin/env` 不是缺包**，是 Termux 的 `/usr/bin` 不可解析。
- **⚠️ 升级后第一件事是「跑起来」**：0.1.7 起 `require-builtin` 缺 android 平台包时，所有补丁全在、自检全绿，dsh 依然完全起不来。静态锚点只能证明「已知问题没复发」。
- **⚠️ 平台包约定不要求 `.node`**：loader 只校验导出形状；纯 JS 实现可行，但**必须**配 `--expose-internals`（`dsh` 包装脚本），两者强绑定。
- **⚠️ 硬阻断补丁 vs 只 warn 的补丁要分清**：require-builtin / rg / node-pty / sharp / 权限层是「起不来或功能全废」；link / flock / subprocess 是「能跑但功能受损」。
- **⚠️ `[]` 是个已结束的 YAML 文档**：dsh 首次启动写出「3 行注释 + `[]`」，直接 `>>` 追加会 `YAMLException`、服务完全起不来。必须按内容分类合并（`apply-profile-patch.js`）。
- **⚠️ `DSH_HOME` 是根，profile 在 `$DSH_HOME/profiles/web`**：写成 `$DSH_HOME/.dsh/profiles/web` 会写成功但 dsh 永远不读。
- **⚠️ 生成型补丁：幂等比内容、归属读字段**：`manifest.name` 不能写路径；存在性看目录、归属看 `dshAndroidPatch` 字段；外来包让路不覆盖。
- **⚠️ `--root` 必须是硬契约**（link/flock/require-builtin/verify-link）：显式给出却定位不到就退 1，不回落生产树；幂等判定要比语义（剥注释/字符串后的真分支/函数定义），不能比子串。
- **⚠️ `ensureFsImport` 只增不删**：同文件仍引用 `link`，删导入会让 dsh 启动即 `ReferenceError`。
- **⚠️ 硬链接验证必须排在 sharp WASM 回退之后**：附件模块 import sharp，先验会误报。
- **⚠️ sharp wasm 版本必须与 sharp 一致**；拷贝前先 `rm -rf`（`cp -r` 会合并旧文件）。
- **⚠️ `patch -p1` 的 cwd 是包目录的父级**，不是包目录本身。
- **⚠️ 报「锚点失配」不等于「功能不可用」**：rg 平台软链自身就能让解析成功，所以源码补丁漂移只 warn，成败交给实测解析。
- **⚠️ 带 token 的日志行可能不止一个 URL**：先取最后一条含 `token=` 的行，再取该行**第一个** URL。

运行期：

- **⚠️ `dsh web` 报 `EADDRINUSE` 不是 dsh 坏了**，是端口已有实例（可能本会话看不到）；`start_dsh.sh` 先探端口，看到就拿不到 token 的旧实例别硬拉。
- **⚠️ `DSH_PORT` 上游不读**：必须显式 `--port`。
- **⚠️ `lib/profile-boot-*.js` 是内容哈希名**：停止梯子依赖其中的二次信号语义，只能通配探测，不能硬编码文件名。
- **⚠️ `koffi` 在 npm 12 上不该进白名单**：白名单内脚本失败会让整次安装退 1；运行期它只在 win32 懒加载。
- **⚠️ pnpm 不是可用的安装后端**：全局 store 符号链接布局让平台包/补丁落点假设失效，且 pnpm 默认拦截 build scripts（`node-pty` 直接缺产物）。已实测 `pnpm add -g` 能装、但 dsh 启动仍失败且补丁脚本报找不到宿主。

## 8. 常用命令

```bash
bash setup.sh                       # 一键安装/升级 + 全量修补
bash setup.sh --verbose
bash ~/dsh/start_dsh.sh
bash ~/dsh/stop_dsh.sh
bash ~/dsh/restart_dsh_now.sh
```

单独重跑某个修补（避免整树重装）：

```bash
bash apply-rg-fix.sh
node patches/patch-dsh-android-link.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/verify-android-link-fix.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/patch-dsh-android-flock.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"
node patches/apply-profile-patch.js --target "$HOME/.dsh/profiles/web/cordis.patch.yml" --layer config/cordis.patch.yml --root "$DSH_DIR"
```

版本核对（脚本里不要写死版本号）：

```bash
node -p "require('$DSH_DIR/package.json').version"
node "$(readlink -f "$(command -v npm)")" view @deepseek-ai/dsh dist-tags
```

## 9. 测试与验证

- **一键检查（每次改动都该跑）**：`bash patches/verify-all-checks.sh [--verbose] [--full]` = 语法 + 静态契约 **40** 条 + **5 个夹具（193 条断言）**；`--full` 追加变异测试（8 个注入回归 + 4 个对照组）。只读或只写临时目录：不跑 setup.sh、不碰 3080、不写 `~/.dsh`。
- 语法：`bash -n setup.sh`、`bash -n apply-*.sh`、三个运行期脚本还要 `dash -n`、`node --check patches/*.js`。
- 幂等：连续跑两次修补，第二次应全部 `[OK]`/`[skip]`。
- **ripgrep**：`apply-rg-fix.sh` 第 3 步用 fresh node 实际解析 `resolveRgPath()` 并打印版本。
- **硬链接**：`patches/verify-android-link-fix.js` 做静态检查 + 临时目录真实运行；必须在 sharp 回退之后。
- **flock**：补丁自带真实加锁自检（首次成功 / 竞争 `EAGAIN`）。
- **require-builtin**：平台包 + 真实 entry 包断言 `backend=napi`/`abi=napi-v9`。
- **⚠️ 版本漂移要端到端验收**：隔离安装（`npm install -g --prefix ~/dsh-verify …`）→ 补丁 `--root` 指向该前缀 → `DSH_HOME=<临时> dsh web --no-open --port 3099` → 校验 token 303、cookie 后 `/` 200、日志零 warn/error。静态全绿 ≠ 能跑。
- **⚠️ 别拿本机 3080 做破坏性实验**：用 `--port 0` / `--port 3099` 临时实例。

## 10. 安全注意（有意为之）

- **`danger-full-access`**：Android/Termux 无 bwrap/landlock，受限模式会让 bash 工具报 `SANDBOX_UNAVAILABLE`，因此必须放开权限模式。**等于关闭进程沙箱，agent 可执行任意命令，仅建议个人设备。**
- 服务只监听 `127.0.0.1`。
- API Key 与 Web 鉴权签名 secret 都在 `~/.dsh`（0600），不进日志/环境变量/仓库。

## 11. 为 dsh 打补丁时应遵循（设计约束）

- 凡涉及 `link()`：会话日志【直接发布】改 `rename()`；no-replace 语义（会话迁移、附件发布/别名、write 新建）在 `EACCES`/`EPERM`/`EMLINK`/`ENOSYS`/`ENOTSUP` 时回退到「O_EXCL 占位 + rename」；附件祖先遍历容忍 `EACCES`/`ENOENT`。
- **原生 addon 的 Android 适配两条路**：① 上游带 `src/*.c`（flock）→ clang 编译成本机 `system.node` 并改加载分支；② 上游只发预编译、不发源码（require-builtin）→ 按 loader 的「平台可选包」约定自建 `<name>-android-arm64`，导出形状过 `validateLoadedBinding()` 即可（纯 JS 亦可，前提是 `--expose-internals`）。
- 终端/平台检测：`process.platform === "android"` 需视同 `"linux"` 处理（见 4c 的通配扫描要求）。
- **不再引入安装后端/前端补丁/性能补丁**：历史上的 pnpm 安装路径、`apply-js-patches.sh`（静态资源缓存头、`newlineCount` 索引循环）、作曲栏回车补丁都已删除；恢复它们需要先证明属于 Android 兼容性必需。

## 12. 重跑 `setup.sh` 之后怎么复验

- **npm 重装清掉自补包是预期**：`npm install -g` 会打印 `removed … changed …`；4/8 的 require-builtin 平台包、flock 的 `system.node` 会重新 `[CREATED]`/`[BUILT]`，不是故障。
- **复验三步（都不改生产文件）**：① `bash patches/verify-all-checks.sh --full`；② 逐个重跑修补步骤必须全 `[OK]`/`[skip]`；③ 核对产物：sharp 与 `@img/sharp-wasm32` 同版本、rg 软链在、`system.node` 可加载、权限层两条齐备且无裸 `[]`。
- **⚠️ `~/dsh/` 三个副本会与仓库漂移**：只有 `setup.sh` 7/8 同步它们；单独改仓库脚本后设备跑的还是旧脚本。同步用 `install -m 700 start_dsh.sh stop_dsh.sh restart_dsh_now.sh ~/dsh/` 并核对 `sha256sum`。
- **判定「运行中的实例是否吃到补丁」**：用 `stat -c '%y' /proc/<pid>` 拿启动时刻（Android 上 `ps -o lstart=` 不可靠），与补丁产物 mtime 比较；决定性证据是 `/proc/<pid>/maps` 里出现 `…/node-addon-system/bin/android-arm64/system.node`。
- **⚠️ 别删认不出的 `$PREFIX/tmp/dsh-*`**：`dsh-spill-*` / `dsh-subprocess-*` / `dsh-workspace-changes-*` 是 dsh 运行期自己的；本项目夹具用可辨识前缀。
- **⚠️ 夹具自身的坑**：假 dsh 的模板字符串转义会让产物语法错；**别用 `pkill -f <pattern>` 清理**（会命中调用它的 shell）；中断留下的假 dsh 会匹配 `DSH_WEB_PATTERN` 导致后续误判——夹具启动前自清并装信号钩子。


<!-- aoci:begin -->
## AOCI 仓库认知

AOCI 为本仓库维护一个稳定、可版本化、可增量更新的仓库级认知层，供模型跨任务复用对系统的理解。

`aoci.txt` 是面向模型的结构化认知索引。它以每个受管理文件、数据库表或其他受管理对象一条独立 Entry 的方式，用符号标签与 F/R/A/S 语义表达对象的核心职责、重要关系、对外契约，以及理解或修改系统时必须知道的非显然约束和设计决策。

Header、目录段和全部 Entry 共同组成完整仓库索引，可以覆盖前端、后端、配置、数据库结构及其他受管理内容。受管理内容发生变化时，通常只需维护受影响的认知条目，不需要重新生成整个索引。

AOCI 提供系统架构、对象职责、重要关系、对外契约和关键约束的高密度视图。

### 工作原理

AOCI 采用“模型生成、模型读取”的认知闭环。

Header、Entry 和 Curation 语义的创作只按当前机器签发的 Plan 与实时 Guide 执行；由 Host 模型基于当前绑定证据独立完成。

Entry 的语义必须来自模型对真实证据的理解。不得仅依据路径、文件名、扩展名、AST、符号列表、依赖扫描、正则、固定模板或规则引擎推导、预填、拼接或改写索引语义。

对 Fresh Bootstrap，只按当前机器签发的 Plan 和实时 Guide 执行。当它们要求创作时，Host 模型创作 Root、Meta、Tag 和 F/R/A/S，提供 authoring-run 声明，并把它绑定到 Plan、Evidence 与完整 Candidate。不得要求 AOCI 填写 `origin=host_model`、制造 Receipt 或把程序生成的 Framework 当作语义。本文件不自行重建 Onboarding 流程。内部批次不是用户决策；只有遇到既有批准边界或真实的安全、漂移、CAS、Recovery 条件才停止。

### 最小使用入口

- `aoci_rules`：取得当前AOCI版本的会话运行合同。
- `aoci_overview`：建立或恢复本仓库的完整认知。
- `aoci_maintain`：受管理对象达到最终稳定状态后检查认知是否需要维护。
- `aoci_update_entry`：提交与当前证据和源码摘要绑定的完整语义更新批次。
- `aoci_report`：仅当当前布局和工具状态支持时，在证据不足、无法可靠生成语义时登记待办，不猜写。

其他MCP工具、CLI命令、参数和专项流程，以当前工具说明、Guide和 `--help` 返回内容为准，不在本文件中重复完整手册。

本区块只规定仓库接入、认知使用和收尾原则。`aoci_rules` 承载当前会话合同，Guide实时输出承载当前Plan的执行顺序与停点，工具Schema、Spec和Validator承载机器结构与判据；Prompt、Description、README和静态文档不能覆盖这些机器事实。

### 建立、生成和恢复认知

1. 每个新的 Agent Run 开始时，应先判断：

   - 本仓库是否已经存在可用的完整AOCI索引；
   - 当前上下文中是否已有与本仓库根、当前索引版本和当前AOCI服务相匹配，并且模型仍可可靠使用的完整仓库认知。

2. 仓库已经存在可用的完整索引，但当前Run没有可靠完整认知时，先调用 `aoci_rules`，再调用 `aoci_overview`。

   完整认知仍可靠时直接复用。局部不确定本身不要求机械重读系统全貌。可靠认知建立后，默认以它作为仓库级系统上下文，只读取当前任务直接需要的源码、测试、配置与契约，只有某个缺失的具体事实可能改变回答或验证结论时才扩大证据范围；AOCI不能替代修改对象与验证行为所需的直接源码证据。

   本Run从已知Host上下文压缩恢复时（包括宿主注入的压缩摘要），必须把此前模型认知视为不可靠。压缩handoff不得保留或摘要正式Whole-Index，也不得保留或摘要任何Overview Header、Entry、Chunk、Challenge或Attestation正文；只能保留安全续接所需的receipt身份、未完成write或Recovery状态，以及立即重载指令。复制进handoff的Whole-Index语义或receipt不能证明恢复后模型的当前认知可靠。若当前上下文已无法可靠保留运行合同，先调用 `aoci_rules`。继续业务任务前，使用 `refresh_reasons=["context_compaction"]` 和新的 `refresh_event_id` 调用普通完整Whole-Index `aoci_overview`（不设置 `check_only` 或设为false）；不得使用 `check_only` 或认知probe。原样跟随每个 `next_cursor` 直到 `completed=true`，确认交付，并且只基于新交付正文提交一次Attestation。完成这次新的完整传输后，即使Attestation为partial或fail也消费该generation，并按既有合同继续source-bound任务，不再自动调用第二次Overview。若该请求返回 `delivery_mode=capacity_stop`，说明Whole-Index装不进本Host的上下文：不得重试或调小 `chunk_tokens`；该停止消费本generation，任务按source-bound继续，且不作无保留的完整系统认知声明。

   AOCI可以针对 `context_compaction`、项目 `cognition_refresh_threshold` 下的机器 `semantic_threshold` 或主要 `phase_transition` 提供checkpoint与认知状态事实。只需要这些紧凑事实时使用 `check_only=true`；这些事实只向Agent提供建议，不替模型决定是否需要系统全貌。

   Agent显式调用普通 `aoci_overview`（未设置 `check_only` 或为false）时，只要能形成一致的CognitionSet，AOCI必须完整交付请求scope。不得因为已有receipt、阈值未达到或没有待处理刷新原因而抑制正文；唯一例外是待处理压缩刷新的上述容量停止。正式认知Dirty或Stale时仍交付正文，但必须标记不可靠。存在未决恢复或无法形成一致snapshot时失败关闭，不返回混合正文。

   普通Overview返回 `continuation_required=true` 时，必须原样提交 `next_cursor` 并自动继续到 `completed=true`。不得询问用户、开始业务任务或给出阶段性系统结论。每块单独一次工具调用；不得在一个脚本里连取多块或合并其输出。缺块、重复、乱序、cursor失败、Index变化或`chunk_tokens`变化时停止本次认知链。Attestation完成前不得用Memory、源码、Spec、`aoci.txt`、历史会话、scope、search或Entry读取修补或补充Whole-Index认知。Challenge ordinal是正式Entry序列中的1-based位置；Header内容、注释、空行、Section/Overview/Chunk Marker、Receipt与Metadata均不计数，Chunk Receipt ordinal使用同一序列。Attestation必须原样回绑本次Challenge发布的当前`index_sha256`、`entry_sequence_sha256`与`entry_count`；旧Index、旧Entry序列、旧数量或旧Attestation均无效。完整链结束后只正式提交一次既有模型认知Attestation；同一响应只允许一次不改变语义答案的JSON Schema或字段格式修正。未达通过（全对的序号不足80%，或对象身份错超过一题）即记为不确定回执，不得语义重试或旁路补答。首次认知失败时还不得执行Root/Meta、Migration、全局布局或其他未重新绑定的系统级决策。上下文压缩刷新若传输完整、认知身份不变、治理对齐且没有Recovery或第三方冲突，即使Attestation为partial或fail也消耗该refresh generation，并继续原任务，不再自动重读Overview。`system_mastery_percent`只自评系统框架——架构、职责、强关系、稳定外部契约以及高熵安全和维护约束——不表示完整实现或运行实况知识；机器索引覆盖率必须分开。默认只向用户输出由本次真实覆盖率、Challenge、块数、Token和掌握度生成的规定成功或失败一句话。Host截断某一块时，用同一cursor重取一次并核对 `chunk_sha256`，服务端返回完全相同的字节。仍被截断才停止，提示用户把 `overview_delivery.chunk_tokens` 设置为更小的合法值后重新开始，不得自动修改。

   加法认知等级必须与严格证明字段分开解释。`delivery_verified`表示已加载Index且Host交付已确认，但完整认知验证仍未完成；应表达为“已加载且交付已验证”，不得描述为“没有认知”或“没有理解系统”。`cognition_verified`要求Attestation通过（Challenge至少80%的ordinal完全正确且对象身份至多失手一处），`cognition_governed`还要求治理对齐。通用完整读取失败句只用于真实交付故障。

   当Overview响应包含可选`cognition-state/v2`投影时，必须分别解释各维度。其Level止于`model_cognition_usable`；`strict_attestation_verified`、`governance_aligned`与`current_system_cognition_reliable`都是独立状态，绝不参与该Level。ordinal、对象身份、Tag或核心F不匹配可以导致严格Attestation失败，而模型认知仍然可用；不得仅凭这种不匹配就宣称模型没有理解系统。只有`current_system_cognition_reliable=true`允许无保留地声称当前完整系统认知可靠。投影缺失时继续使用上述Legacy解释。

   普通的只读审计、分析、检查、不修改代码或不提交、不push，不自动等于严格零写入，也不改变上述认知有效性判断。Codex Memory和历史Skill只能辅助恢复经验、用户偏好与调查方向，不能替代与当前仓库根、索引摘要、AOCI服务身份和认知范围匹配的当前认知收据；项目AGENTS和当前AOCI身份在AOCI状态上优先于历史Memory。

   只有用户明确禁止Ledger、元数据、`.aoci`运行资产及任何文件写入时，才按严格零写入处理。若必要的认知建立与该边界冲突，必须报告冲突并请求用户裁决或建议使用隔离副本，不得静默以Memory替代当前仓库认知。

3. 仓库没有可用的完整索引，或当前只有最小骨架、Header不完整、Entries未完成、必要Curation尚未裁决时，如果需要建立正式完整AOCI索引，先取得 `aoci_rules`，然后进入当前AOCI Guide。由Guide依据仓库真实状态决定下一阶段并完成必要安全步骤。

   `aoci_maintain` 不替代索引建立流程。

   不在本文件中自行重建或硬编码完整索引生成状态机。

4. 在长程任务中，模型负责保留当前认知收据并正确使用刷新门禁：

   - Host报告上下文压缩或模型已知系统全貌丢失时，执行上述强制 `context_compaction` 重载规则；AOCI不能自行推断Host事件；
   - 进入真正的主要阶段时声明 `phase_transition`，不得把函数、测试运行或小步骤当作阶段；
   - 在有用的稳定检查点通过 `check_only=true` 取得机器语义计数；
   - 除已知压缩的强制重载外，由Agent判断当前任务是否需要再次显式获取指定scope或完整Overview；
   - 在维护和对齐完成前，保留AOCI报告的Dirty或Stale可靠性状态。

### 任务收尾与认知维护

5. 纯只读问答、分析、版本核验，或没有产生受AOCI管理对象变化的任务，不需要调用维护工具。当前AOCI版本是任意`aoci_overview` check_only或`aoci_maintain`响应里的`cognition_receipt.mcp_service_version`；二进制路径是项目`.mcp.json`里的`command`，CLI不必在PATH上。

6. 发生受AOCI管理对象变化时，待其达到本次任务的最终稳定状态后，只调用一次 `aoci_maintain`。不要在每次中间修改后逐文件维护。

7. 若维护结果返回真实语义候选，Host 模型必须基于每个候选绑定的对象和必要证据，独立创作完整标签与F/R/A/S更新。通过 `aoci_update_entry` 一次提交当前机器签发批次的完整候选集合，同时原样保留每项路径与对应domain批次身份；`source_sha256` 与 `candidate_id` 可以省略，由服务端按签发的批次取得。`max_entries`只限制单次请求和原子事务，不限制logical plan、Whole-Index或Managed Scope。`remaining`非零时，在当前批次成功Apply后重新调用Maintain并从新preimage继续；绝不能为满足transport上限缩减Index覆盖或自行截取返回批次。

   没有足够证据且当前布局支持 `aoci_report` 时，使用它而不猜测、套用模板或为消除待办而生成缺乏证据的认知。

8. 必须遵守工具返回的结构化状态和安全边界：

   - `repair_required`：只修复明确命中的候选，再重新提交当前机器签发的完整批次；
   - `stopped`：结束当前写入尝试并检查 `failed_step`、错误、正式写入证据与Recovery。auto模式下，已证明零写入则记录closure并重新Plan；完整Intent和可证明postimage则Resume；策略要求Rollback且preimage可证明则精确恢复后重新Plan。只有证据不足、第三方正式字节冲突、需要审批或外部动作，或命中其他真实安全边界时，才停止整个用户任务；
   - 冲突、审批、人工裁决、权限和安全信号不得忽略；
   - 已经对齐后不得重复维护或重复写入；`refresh_ready_for_overview` 是checkpoint事实，由Agent决定是否为下一阶段请求普通完整Overview。

   维护完成后如果又修改了任何受管理对象，之前的维护结果失效，应在新的最终稳定状态重新完成收尾。

9. 用户只限制业务文件范围，但没有明确禁止仓库托管资产时，AOCI托管资产可以在收尾阶段为保持认知一致而更新，并应在审计和提交中与业务文件区分。

   用户明确禁止修改 `aoci.txt`、`.aoci`、元数据或任何额外文件时，以用户限制为准，不得写入，并如实报告剩余不一致。

### 专项流程

初始化、完整索引生成、Header生成、Entries生成、数据库结构索引、Curation、人工评审和故障恢复，只按当前AOCI Guide或工具在对应阶段返回的指令、命令和安全停点执行。

不预加载、不猜测，也不自行重建这些专项流程。平台调用方式、请求格式、批次上限、审批规则、索引格式细节和恢复步骤由对应Guide、工具说明、模型Prompt和CLI帮助按需提供。
<!-- aoci:end -->
