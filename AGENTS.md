# AGENTS.md

给 AI agent 与协作者的维护须知：这套胶水怎么工作、改哪里、别踩什么。面向用户的使用文档在 `README.md`（中英双语）与 `docs/index.html`。

## 1. 仓库定位（这是什么）

`deepseek-harness-android` 是一个**安装与兼容性修补工具包**，用于在 **Android 手机的 Termux** 里一键部署并原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`，DeepSeek 官方的 agent harness，类比 Claude Code），然后通过 Web UI（`http://127.0.0.1:3080`）在手机浏览器里使用。

它不是独立的源码项目。仓库里只有**胶水脚本 + 补丁**：它们负责安装上游 `dsh` 包，再对**已安装到 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`** 的那份文件做 Android 兼容修补（直接改写目标文件）。绝大多数改动不落在这份仓库里，而是落在 `dsh` 安装目录里——**所以「仓库干净」不等于「设备已修好」**：升级 dsh / Node 后必须重跑 `bash setup.sh`。

## 2. 版本基准与已验证状态

- 当前基准：`@deepseek-ai/dsh` **0.2.1-rc.5**（= npm `latest` = `next`；`alpha` 是 `0.2.2-alpha.2`；2026-10 实装核对）。**本机当前就装 rc.5**；**0.2.0-rc.2 线同样支持**（回退验证通过），`0.1.7-rc.2` 线也仍通过同一套补丁与权限层。`node_modules/@deepseek-ai/*` 中 `@deepseek-ai/node-addon-system` 0.1.2；`node-addon-require-builtin` 与 `node-addon-native-custom-loader` 均为 **0.1.9**，且两者是**非 scoped** 包，装在 `<dsh>/node_modules/` 而**不在** `@deepseek-ai/` 下——脚本按运行时推导包名，本行只是实测时点记录。
- **0.2.1 相对 0.2.0 的变化（2026-10 核对：现有补丁全部命中，未改任何锚点；rc.5 再次复核，同样零改动）**：
  1. **依赖闭包 532 → 约 605 个包，直接依赖 +10/−6**（隔离装 rc.2 报 `added 605 packages`；本机重装 rc.5 报 `added 3 / removed 4 / changed 605`——其中 3 个是本项目的自补包）。新增：11 个实验性 bundle、`dsh-plugin-manager`、`dsh-plugin-market*`、`dsh-tool-schedule`/`dsh-tool-terminal`/`dsh-tool-session-query`、`dsh-session-query-sqlite`（用 `node:sqlite`，Node 26 可用）等；移除：`dsh-webhook`/`dsh-webhook-github`、`dsh-hooks-codex`/`dsh-hooks-claude-code`、`dsh-tool-ralph`、`dsh-experimental-schedule-bundle`、`dsh-client-store`/`ui-primitives`/`ui-slots`、`dsh-invariants`、`dsh-hook-protocol`、`dsh-subagent-in-process-driver`。
  2. **`OPTIONAL_BUNDLES` 4 → 12**（全部实验性、默认不启用）；**Web 默认 bundle 不变**；`profile` 权限层、锚点、`internalModules()`/loader 契约、`PROFILE_PATCH_TEMPLATE`、sharp 0.35.5 + wasm32 0.35.5 全部不变。
  3. **版本敏感项**：`cordis` 4.0.5、`chokidar` 5（要求 Node ≥20.19；Node 26 满足）、`openai` 7.x、`pi-ai` 1.3；不变：`koffi` 3.1.1、`node-pty` 1.2.0-beta.15、`sharp` 0.35.5、`node-addon-system` 0.1.2、`node-addon-require-builtin`/`native-custom-loader` 0.1.9。
  4. **`RETIRED_BUNDLES` 迁移**：0.2.1 首次启动会**自动从已有 profile 摘除 `dsh-experimental-schedule-bundle`**（上游正常迁移，**不是错误**，不要当故障排查）。
  5. **新增运行期依赖 pnpm**：0.2.1 引入插件管理器（plugin-manager / plugin-market / `dsh plugin …`），它 `execa("pnpm")` 从 PATH 找 pnpm → **pnpm 11.x 成为 dsh 插件功能的事实运行期依赖**（见 §4 的 pnpm 运行时供给、§7 的 pnpm 12 陷阱）。
  6. **潜伏风险（默认不触发）**：`sherpa-onnx-node`（语音输入，只经默认不选的 `dsh-experimental-voice-input-bundle` 到达）与 `libreoffice-kit`（**没有 android 平台包**，office→pdf 可能不可用）——都是手动启用实验性 bundle 才会碰。
  7. **0.2.1-rc.5 复核（2026-10，本机全量实跑）**：`bash setup.sh` 九步全绿、**锚点零改动**；`apply-js-patches.sh` → `01[skip] 02[deprecated] 03[skip]`（即三个补丁都已就位/已在围栏）；`chokidar` **5.0.0**、`openai` **7.19.0**（与 rc.2 的「chokidar 5 / openai 7.x」一致）；`koffi 3.1.1`、`node-pty 1.2.0-beta.15`、`sharp 0.35.5`、`node-addon-system 0.1.2`、`require-builtin`/`native-custom-loader 0.1.9` **全部不变**；权限层两条仍与 `permission` 预设匹配（启动零告警）。
- **0.2.0 相对 0.1.7 的关键变化（历史，仍适用）**：
  1. **`koffi` 被精确钉在 `3.1.1`**：`@koromix/koffi-android-arm64` 从 3.2.1 才有预编译包；3.1.1 的 `cnoke --prebuild` 会自愈式回退到本地编译，历史上死在 bionic 与 glibc 的 `statx` 原型差异（`lib/native/base/base.cc`）。**npm 12 语义：白名单内脚本失败 → 整次 `npm install` 退 1（`setup.sh` 3/9 中断）；白名单外 → 只警告并跳过。** 因此 koffi 移出 `ALLOW_SCRIPTS`、进 `SKIP_SCRIPTS`。⚠️ **本机（npm 11.21.1）实测修正**：npm 11 的 `--allow-scripts=<list>` 是**建议性**的（未列出的包脚本仍会执行，只打警告；只有 `strict-allow-scripts` 才硬失败），所以这台设备上 **koffi 的 install 脚本实际执行且编译成功、可加载**（`koffi.load('libc.so')` OK）——「Android 上构建必然失败」**不成立**。运行期两种 npm 线都不受影响：dsh 的 koffi 调用点全是懒加载且 `platform === "win32"` 才走。**保留 `SKIP_SCRIPTS` 设计**：npm 12 下白名单才强制，koffi 留在白名单里仍会拖死整次安装；`setup.sh` 增加 npm 策略探测行（advisory / strict），把用户显式设的 `strict-allow-scripts=true` 当安装冲突处理。
  2. **新增 `permission` 行（`@deepseek-ai/dsh-permission-presets`），它按「组合后的 sandbox + approval」反查预设表**：预设 `danger-full-access` 的定义就是 `{sandbox: danger-full-access, approval: never}`。因此权限层必须是**两条**（`sandbox-policy.mode` + `approval.policy`）——只改 sandbox、approval 还是基线的 `ask`，组合即 `custom`：该行不激活并在启动日志里报 `permission: composed sandbox and approval defaults match no preset`（实测 0.2.0-rc.2 复现；补上 approval 后日志零告警）。0.1.7 没有这个校验，两条层在旧线只是「设置审批策略」，行为一致。
  3. **补丁 `01` 重锚**：MIME 表尾的 `.gz`（`application/gzip`）从 0.1.5-rc.3 起就存在，旧 hunk 是靠 GNU patch 默认 fuzz=2 才命中（`-F0`/`git apply` 已失配，上游再插一行就硬 `[FAIL]`）。现在把 `.gz` 写进上下文，**`-F0` 在 0.1.5-rc.3 / 0.1.7-rc.2 / 0.2.0-rc.2 / 0.2.1-rc.2 / 0.2.1-rc.5 上都命中**（实测），产物与旧 fuzz 结果逐字节一致。
  4. **其余不变**（逐项核对过）：`internalModules()` 与 loader 契约 byte-identical、link/flock/4c/4d/rg 锚点全在（4c 在内容哈希 bundle 里，通配已覆盖）、`profile-boot-*.js` 的 `forceExitOnce`/`interrupt(code)` 仍在、`PROFILE_PATCH_TEMPLATE` 仍是「3 行注释 + `[]`」、sharp 0.35.5 + wasm32 0.35.5 可用、全闭包只有 5 个带安装脚本的包。
- **⚠️ 版本号只表示「撰写/实测时点」，绝不能当逻辑依赖**：脚本与补丁一律**不得按版本号分支**（`setup.sh` 默认跟随 npm `latest`，`DSH_VERSION` 只由调用方按需传；补丁靠锚点/形状匹配，不靠版本串）。升级前后都用 `node -p "require('$DSH_DIR/package.json').version"` 与 `npm view @deepseek-ai/dsh dist-tags` 核对**实际**版本，再回来更新本行——在此之前，本行的版本号对代码没有任何约束力。
- **0.1.7 相对 0.1.5 的两处关键变化**：
  1. **新增原生 addon 家族，缺平台包就完全起不来**：`node-addon-require-builtin` 只发 darwin/linux/win32 预编译包、**没有 android**，于是 `dsh-app-boot` 的 `internalModules()`（无条件 require、无 JS 回退）抛 `No usable native binding found` → dsh 起不来。由 `patches/patch-dsh-android-require-builtin.js` 补 android 平台包解决（机制见 §7「平台可选包」与 §11）。
  2. 客户端 combo 惰性化已由上游原生 `lazyBody` 实现，补丁 02 的锚点必然失配（预期；02 已**移入 §12 弃用围栏**，只报 `[deprecated]` 而非失败，不影响运行）；补丁 01/03 仍命中。`resolveRgPath()` 也多了 electron `.asar` 归一化分支。
- **带安装脚本的包（全闭包只有 5 个）**：`@deepseek-ai/dsh-subprocess-local`、`node-pty`、`@google/genai`、`protobufjs` 进 `ALLOW_SCRIPTS`；**`koffi` 进 `SKIP_SCRIPTS`**（npm 12 上放白名单会拖死整次安装；本机 npm 11 advisory 语义下它会真的编译成功，但运行期不需要，见上）。3/9 末尾的自检表把 koffi 标 `[skipped]`、其余不在白名单的标 `[UNCOVERED]` 并退 3。`sharp` 仍走项目自己的 wasm32 回退（0.35.5 → `@img/sharp-wasm32@0.35.5` + `@emnapi/runtime`）。
- **JS 补丁锚点核对（可复现，正向更省事）**：`npm pack` 两个目标包 → 解包 → 对上游源码**正向**打 `patches/01`、`02`、`03` → 与安装树 `diff`。本机对 `0.1.5-rc.3`、`0.2.0-rc.2`、`0.2.1-rc.2` 都验过：安装树 = 上游 + 能命中的补丁，逐字节 IDENTICAL、无额外漂移（其它差异来自第 4 节的 Android 补丁表与应用侧改动）。
- **本机最近一次全量实测（0.2.1-rc.5，2026-10，直接跑 `bash setup.sh`）**：rc=0、耗时 **3m18s**（npm 报 `added 3 / removed 4 / changed 605 packages`，koffi 在本机 npm 11 下真的编译成功）；1/9–9/9 全绿：require-builtin 平台包、link、flock、4c、4d、rg、sharp-wasm32 0.35.5 + 硬链接验证、dsh 包装脚本、权限层 `OK`、JS 补丁（`01[skip] 02[deprecated] 03[skip]`）；端到端 `dsh web`（临时 `DSH_HOME` + `--port 3098`）冷启动到 token **13.9s**、token→**303**、cookie 后 `/`→**200**、日志**零 warn/error**；产物核对：`sharp`/`@img/sharp-wasm32` 均 0.35.5、rg 软链指向系统 `rg`、`bin/android-arm64/system.node` 可 `require`（导出 `tryLock`）、profile 里 `sandbox-policy=danger-full-access` + `approval=never` 齐备且无裸 `[]`。流水看 `git log`。

## 3. 目录结构

| 路径 | 作用 |
|---|---|
| `setup.sh` | **主入口**。0~9 步 + `2.5/9`：pnpm 运行时预检（只读）→ 锚点预检 → 依赖 → Node headers → **2.5/9 pnpm 运行时供给（dsh 插件依赖）** → 安装 dsh（**只有 `npm install -g`**）→ 后端兼容补丁 → sharp WASM 回退 + 硬链接验证 → 重建 `dsh` 包装脚本 → 安装启动/停止/重启脚本与权限层 → JS 性能补丁 → 汇总。默认简洁输出，原始命令写入 `~/dsh/setup.log`；`--verbose` / `SETUP_VERBOSE=1` 透传原始输出。参数只有 `--verbose`：历史上的 `--pnpm` / `--npm`（安装方式）已移除，传入会打印「参数已废弃」并退 1。安装/升级后必须重跑。 |
| `apply-js-patches.sh` | 应用 `patches/01`、`02`、`03` 三个 JS 性能补丁（静态资源 immutable 缓存头；客户端 combo 按需构建，冷启动 22s→12s；`newlineCount` 索引循环）。**分层设计**：`01/02` 面向 0.1.5 线，`03` 与版本无关。**两个区**：活跃清单 `PATCHES`（`[skip]` 已应用 / `[ok]` 成功 / `[FAIL]` 失配或写失败并退非 0）与**已弃用围栏** `DEPRECATED_PATCHES`（锚点已失效但为旧线保留：能命中就照打并标 `[ok]（弃用围栏：在目标版本上仍然有效）`，命中不了只报 `[deprecated]`、**不计失败**；见 §12）。⚠️ `PATCHES` 的**顺序即语义**（02 必须先于 03），围栏只改报告与退出码、不得改执行顺序。 |
| `apply-rg-fix.sh` | 修复 grep/glob 报 `ripgrep launch failed`（软链系统 `rg` 到 `@vscode/ripgrep-android-arm64/bin/rg` + 给 `resolveRgPath()` 加回退，已识别 4 种上游形态）。**锚点漂移不再判死**：软链本身就能让 `@vscode/ripgrep` 解析成功，故未识别形态只 `warn`，成败交给第 3 步 fresh node 的实际解析结果。 |
| `start_dsh.sh` | 启动/复用 `dsh web`：流式读日志取带 token 的鉴权 URL、`curl` 校验 303/302，然后按包名优先用 **Via**（`am start`）打开浏览器，找不到再回退系统默认浏览器。默认静默（提示/剪贴板只在 `DSH_HINTS=1`）。**先探端口再决定是否拉起**：端口已有响应但本机看不到 dsh 进程（另一个用户/应用、`su`、别的会话）→ 不拉起必败的第二个实例，直接打印占用情况 + 「结束旧实例 / `DSH_PORT=3081`」并退 1；**启动失败（日志 `startup failed` 或进程在给 token 前退出）立即报原因**，不等满 `DSH_READY_TIMEOUT`、不降级裸 URL。 |
| `stop_dsh.sh` | 安全停止：pid 文件 + 身份二次确认；梯子是「优雅窗口 `DSH_STOP_GRACE` → 补发一次 `SIGTERM` → `SIGKILL` 兜底」。没有可停的进程但端口仍有响应时，在 stderr 提醒「占用它的进程本机看不到、不受本脚本管理」（仍退 0，保持幂等）。 |
| `restart_dsh_now.sh` | 重启：复用 `stop_dsh.sh` + `start_dsh.sh --no-open`，写 `storage/dsh_restart.log`，最后 `curl` 确认端口。 |
| `config/cordis.patch.yml` | 权限层（**两条**：`sandbox-policy.mode = danger-full-access` + `approval.policy = never`，0.2.0 的 `permission` 行按这两者的组合反查预设），由 `patches/apply-profile-patch.js` **安全合并**进 `~/.dsh/profiles/web/cordis.patch.yml`。每个条目前有一行哨兵 `# >>> dsh-android-layer-entry`：它是层的切块标记，让脚本能按条目粒度补齐缺失项（见 §7 的 `[]` 陷阱）。 |
| `patches/apply-profile-patch.js` | 权限层安装器（`setup.sh` 7/9 调它）。借 dsh 自己的 `loadOverlayPatches()` 解析目标 → **按条目 id 补缺失**：缺文件 `[CREATED]`、空数组模板 `[REPLACED]`、已有层只追加缺的条目、残留裸 `[]` 定点摘除 `[REPAIRED]`、齐备 `[OK]` 不动；用户自配过 `sandbox-policy` 时不塞 `approval`。写盘 = 临时文件 + 校验 + 备份 + `rename` + 复验，坏文件一字节不动并退 1；`[ERROR]/[WARN]` 走 stderr。`--root` 是硬契约。 |
| `patches/01-frontend-static-cache.patch` | 给 `dsh-host-frontend-static` 的 `/assets/` 加 immutable 缓存头、其余 `no-cache`。 |
| `patches/02-client-modules-lazy-compose.patch` | 客户端 combo 按需构建（`dsh-client-modules`），冷启动 22s→12s。**已弃用（在 §12 围栏里）**：0.1.7 起上游原生 `lazyBody` 取代了它，锚点随之消失；0.1.5 线上仍能命中（实测 0.1.5-rc.3 全命中），故保留而不删。 |
| `patches/03-client-modules-newline-count.patch` | 只把 `newlineCount()` 的 for-of 换成 `charCodeAt` 索引循环（10.8MB 实测 302ms→60ms）。锚点跨 0.1.5/0.1.7 稳定，是版本无关的兜底性能补丁；02 已应用时它自动 `[skip]`。 |
| `patches/patch-dsh-android-link.js` | Android 禁 hardlink 修复（会话直接发布改 `rename()`；no-replace 路径用「O_EXCL 占位 + rename」回退）。`--root` 是硬契约（定位不到 → 退 1 不回落）；幂等判定看 helper 的**函数定义**而非子串标记。 |
| `patches/patch-dsh-android-flock.js` | Android flock 原生绑定：clang 编译 `src/flock.c` 为 `bin/android-<arch>/system.node`，改 `lib/flock.js` 在 android 下加载它；自带真实加锁自检。`--root` 同样是硬契约（需含 `node-addon-system/lib/flock.js`，否则退 1 不回落）；幂等判定看**剥离注释后**的真 android 分支（不看 marker）。 |
| `patches/patch-dsh-android-require-builtin.js` | **dsh ≥0.1.7 启动前提**：在 `<dsh>/node_modules/` 生成 `node-addon-require-builtin-android-arm64` 平台包（纯 JS `requireBuiltin` 实现，`backend=napi`/`abi=napi-v9`），补上上游缺失的 android 预编译槽位；自带 `internalModules()` 自检。**失败必须中断安装**（缺它 dsh 起不来）。dsh <0.1.7（没有该 addon 家族）→ `[SKIP]` 退 0，前提是「定位到 dsh 安装根」与「entry 包存在」**解耦**。幂等按**内容**判定：三个文件与脚本模板逐字节一致才 `[OK]`，否则 `[REFRESHED]` 原地刷新（manifest 修正、模板更新、entry 包版本变化都能下发）。归属判定读 manifest 的 `dshAndroidPatch` **字段**、存在性看**目录**；非本补丁生成的包一律让路不覆盖（`[SKIP]`），可用性由同一次 `verify()` 断言——通过退 0、加载不了才退 1。`--root` 是硬契约：显式给出但定位不到 dsh 安装根即报错退 1，**不回落**其它候选。`name`/`os`/`cpu` 由包名与 `process.platform`/`process.arch` 推导，不写死。 |
| `patches/verify-android-link-fix.js` | 硬链接补丁验证（静态检查 + 临时目录真实运行：附件保存/去重、fs-local 新建文件在 `link()`=EACCES 下必须成功）。 |
| `patches/verify-client-modules-lazy.js` | 补丁 02 自检：`--port 0` 起临时实例，逐字节核对单条/批量 bundle 与 sourcemap、未知 URL 404、HEAD 200，并打印启动到 token 的秒数。 |
| `patches/verify-*fixture.js` / `verify-setup-static-check.sh` / `verify-all-checks.sh` | **脚本级测试**（**6 个夹具 / 242 条断言**：js-patches 21、runtime-scripts 36、guards 39、require-builtin 29、profile 41、pnpm-provision 76；外加静态契约 27 条 + 变异 14/14）：require-builtin 平台包、权限层、link/flock 守护条件、js 补丁正向/幂等、start/stop/restart 行为契约（含端口被占/启动失败两个新路径）、pnpm 运行时供给（含旧旗标 `--pnpm`/`--npm` 被拒），以及「往仓库副本注入已知回归必须变红」。一行跑完：`bash patches/verify-all-checks.sh [--verbose] [--full]`；只读或只写临时目录。各夹具用例见 §9。 |
| `docs/index.html` | 说明文档站。 |
| `README.md` | 中英文用户文档（安装、修复项、FAQ、仓库结构）。 |

## 4. 安装/修补流程（`setup.sh`）

**安装方式只有 npm**（`npm install -g` 命令与旧版逐字一致）。历史上的第二种安装后端 `--pnpm`（pnpm 11 非全局 project 安装 + 迁移到 `DSH_DIR`、`DSH_PM`/`DSH_PNPM_BIN`/`DSH_PM_CONFLICT_OVERRIDE`/`.dsh-android-pm` 归属标记/`pnpm-store`）**已整体移除**：产物与 npm 布局逐项一致、却要额外维护版本线校验与一套冲突预检。现在 `--pnpm` / `--npm` 会打印「参数已废弃」并 `exit 1`（不静默改用 npm）。⚠️ **npm 方式并非「零新增」**：`2.5/9` 的 **pnpm 运行时预检 + 供给** 仍会跑（dsh ≥0.2.1 插件功能运行期依赖 pnpm）；PATH 上已有可用 pnpm 11.x 时只报 `[OK]`、不写任何文件。3/9 会打印一行 `allow-scripts` 策略（advisory / strict）。

**pnpm 运行时预检 + 供给**（`pnpm_runtime_preflight()` 只读、`2.5/9` 实际写入；dsh ≥0.2.1 的插件功能 `execa("pnpm")` 需要运行期 pnpm）：

**核心约定：不写死 pnpm 路径、不写死版本号。** 预检用 `pnpm_candidates()` 收集 **PATH 上每一个** `pnpm`（顺序即优先级）、`$DSH_PNPM_WRAPPER_DIR/pnpm`、`$DSH_PNPM_PIN_DIR/node_modules/pnpm/bin/pnpm.mjs`、`${PNPM_HOME:-~/.local/share/pnpm}/bin/pnpm`、npm 全局的 `pnpm/bin/pnpm.{cjs,mjs}`（按 realpath 去重），逐个用 `resolve_pnpm_cmd()` + `--version` 探测，只认 **11.x**，再按四种结局决策（状态机 `ok | reuse | provision | repair`）：

- `ok`：PATH 首位 pnpm 就是可用的 11.x → 不写任何文件。
- `reuse`：**别处**有可用的 11.x（典型：pin 目录早就有 11.x，但 PATH 首位是坏 pnpm 12）→ 写包装指向该入口（`exec "<node>" "<entry>"`），**不重新下载**；`pnpx`/`pnx` 只有在同包 `bin/pnpx.<ext>` 存在时才写。
- `provision`/`repair`：没有任何可用版本，但 `pnpm_can_shadow()` 成立（包装目录在 PATH 上、且排在坏 pnpm 前面；或挡路的正是我们自己写的包装）→ `npm --prefix "$DSH_PNPM_PIN_DIR" install pnpm@"$DSH_PNPM_VERSION"`（默认 pin dir `~/.local/share/pnpm-pin`、版本 **11.27.1**、纯 JS build）并写 `$DSH_PNPM_WRAPPER_DIR`（默认 `~/bin`）下的四个包装：**Termux 绝对 shebang** + `exec "<node>" "<pin>/node_modules/pnpm/bin/{pnpm,pnpx}.mjs" "$@"` + 归属 marker，用它们**压过**坏 pnpm；写完验证 `pnpm --version` 是 11.x 且 PATH 解析到包装，否则 `exit 1`。
- **停止（`pnpm_stop_unusable`，只读，不可用 `DSH_PNPM_CONFLICT_OVERRIDE` 覆盖）**：找不到可用 11.x **且**压不过（包装目录不在 PATH、或排在坏 pnpm 之后）。打印「探测到的每个 pnpm + 版本 + 为何不合格」+ 三条修复（`npm install -g pnpm@11` / `npm uninstall -g pnpm` / 调整 PATH 顺序）+「本步骤只读、未改动任何文件」。**用户修好后重跑必须能继续**——夹具 `i1` 用「先把假 pnpm 写成 12 → 停下 → 改写成 11 → 重跑通过」钉住这条。
- **共存类冲突（`DSH_PNPM_CONFLICT_OVERRIDE=1` 可覆盖）**：要写的包装文件名已被**别人的**等不等价文件占用（无 marker 且 `pnpm_wrapper_equivalent()` 不通过）→ 默认拒绝；覆盖后旧文件备份为 `.dsh-android.bak`。等价的（如用户手写的 pin 包装、引号写法不同）→ **认领、不覆盖**。`ok` 状态下不写文件，因此**别人写的但能正常跑的 11.x 包装会被直接复用**（不再当冲突）。
- **配置类冲突（不可覆盖）**：npm `strict-allow-scripts=true`（会把 `SKIP_SCRIPTS` 的 koffi 变硬错误、整次 npm install 中断）→ 提示 `npm config set strict-allow-scripts false --location=user` 后 `exit 1`。
- 被遮蔽的 npm-global pnpm 12 / pin 目录里的非 11.x → 只 `warn`（文案按 `path_usable` 区分「已被遮蔽」与「将被包装压过」）。
- 幂等：已可用时 `2.5/9` 只报 `[OK]` 不写文件；包装损坏报 `repair` 重写。测试/排障可只跑这一步：`DSH_SETUP_PROVISION_ONLY=1 bash setup.sh`。

| 步骤 | 做什么 |
|---|---|
| `0/9` | **锚点预检** `anchor_precheck()`：只读检查 7 条「路径\|补丁后特征串\|标签」（路径支持通配）+ 1 条 `lib/profile-boot-*.js` 的 `forceExitOnce`/`interrupt(code)` 探测。未命中只 `warn`，不中断。 |
| `1/9` | `pkg update/install`（`cmake clang make binutils pkg-config python nodejs ripgrep`）；探测 npmjs/nodejs.org 是否慢，慢则**仅本次会话** export `npm_config_registry` / `npm_config_disturl` 到 npmmirror。 |
| `2/9` | `npx node-gyp install` 拉 Node headers，再往 `~/.cache/node-gyp/<ver>/include/node/common.gypi` 的 `'variables': {` 后插入 `'android_ndk_path%': ''`（Termux 无 NDK，否则 node-pty 构建失败）。 |
| `2.5/9` | **pnpm 运行时**：按预检状态 `ok`（复用）/ `reuse`（写包装指向已探测到的 11.x，不下载）/ `provision`·`repair`（`npm --prefix "$DSH_PNPM_PIN_DIR" install pnpm@"$DSH_PNPM_VERSION"` 后写 `$DSH_PNPM_WRAPPER_DIR` 包装）；幂等。 |
| `3/9` | `npm install -g @deepseek-ai/dsh`，`CFLAGS/CXXFLAGS=-target aarch64-linux-android30 -I$PREFIX/include`，`--allow-scripts="$ALLOW_SCRIPTS"`（**只放行构建能在 Android 成功的包**；按 npm 12 语义，白名单内脚本失败会让整次安装退 1，白名单外只警告，故 koffi 进 `SKIP_SCRIPTS`）。装完：校验 `node-pty` 的 `build/Release/pty.node` 能加载（缺产物 `exit 1`）；koffi 不可加载时按 `SKIP_SCRIPTS` 判定：是 → `info`（预期内），否 → `warn`；跑**白名单自检**：扫描安装树里所有带 `preinstall/install/postinstall` 的包，标 `[allowed]`/`[skipped]`/`[UNCOVERED]`（后者列出并退 3 → `warn`）；报告实际生效的 npm allow-scripts 策略（advisory / strict——由 `pnpm_probe_npm_strict()` 读 `npm config get strict-allow-scripts`，strict 已在预检里当冲突拒绝）。支持 `DSH_VERSION=<ver>` 钉版本。 |
| `4/9` | 后端兼容补丁，见下表。 |
| `5/9` | **sharp WASM 回退**：比对 `sharp` 与 `@img/sharp-wasm32` 版本，一致才跳过；否则在临时目录装同版本 wasm 包，先 `rm -rf` 再 `cp`（旧目录直接 `cp -r` 是合并、会版本混装），并补 `@emnapi`。之后立刻跑 **硬链接验证**（必须在这一步之后，见第 7 节）。 |
| `6/9` | 重建 `dsh` 包装脚本（`--expose-internals --no-warnings`，临时文件 + `mv -f` 原子替换，绝不 `cat >` 覆盖符号链接）。 |
| `7/9` | 把 `start/stop/restart` 三个脚本拷到 `~/dsh/`；调 `patches/apply-profile-patch.js` 把权限层（`sandbox-policy` + `approval` **两条**）**安全合并**进 `~/.dsh/profiles/web/cordis.patch.yml`（分类 + 按条目补缺失 + 残留 `[]` 定点修复；写前写后都用 dsh 自己的 `loadOverlayPatches()` 校验，不可解析就 `error` + `exit 1`，见 §7 的 `[]` 陷阱）。 |
| `8/9` | `apply-js-patches.sh`（**可选增强**：失败只 `warn`，不中断）。 |
| `9/9` | 完成汇总（耗时、日志、后续操作、注意事项）。 |

`4/9` 的补丁落点：

| 落点 | 方式 | 失败语义 |
|---|---|---|
| `node-addon-require-builtin-android-arm64`（新建平台包，放在 `<dsh>/node_modules/`，**不在** `@deepseek-ai/` 下） | `node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"` | **`error` + `exit 1`**（4-boot，会让安装硬中断）：缺它 dsh 在 host preparation 阶段就抛 `No usable native binding found`，**完全起不来**。dsh <0.1.7（没有该 addon 家族）时脚本自身 `[SKIP]` 退 0（该分支由夹具用例 5 守着） |
| `dsh-session-persistence-jsonl` / `dsh-attachment-local` / `dsh-fs-local` | `node patches/patch-dsh-android-link.js --root …` | 只 `warn`，继续（`--root` 显式给错则脚本自身退 1 且不写任何文件） |
| `node-addon-system`（flock） | `node patches/patch-dsh-android-flock.js --root …` | 只 `warn`，继续（但发消息会失败；`--root` 契约同 link） |
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
- **⚠️ 等 token 必须在整个 `READY_TIMEOUT`（默认 90s）内持续等，不能「端口一响应就倒计时」**：端口先回 401，带 token 的 URL 要等 `announceReady()`（loader settle 完）才打印，冷启动可达十几秒。早期写成「端口通但 token 无效满 5 次就开裸 URL」→ 冷启动几乎必然裸 URL → 401（已用假 dsh 复现并修复）。
- 交给浏览器前先用 `curl` 校验该 URL 返回 `303/302`（避免日志里残留旧进程 token 时打开仍 401）；降级到裸 URL 必须打印**具体原因**（`no-token` / 实际 HTTP 码）。token 是**进程级且可重复使用**的（同一 token 连续请求都返回 303），校验用的 curl 不会「烧掉」它；303 后地址栏显示裸 `/` 属正常设计。
- `restart_dsh_now.sh` 必须用 `--no-open`，并且让 dsh 输出写进同一个 `~/dsh/storage/dsh.log`，否则 `start_dsh.sh` 找不到当前进程的新 token。
- **不要为了鉴权去改 dsh 前端界面文件**：前端已经能通过 `?token=` 自动换 cookie，脚本只要保证打开正确的 URL、日志文件一致。

## 6. 写脚本的约定

### 6.1 语言与输出

- `setup.sh` 与 `apply-*.sh` 是 **bash**：`set -euo pipefail`，进度用 `info()/warn()/ok()/error()`，主步骤用 `step()`；注释与用户提示用中文；`apply-rg-fix.sh` 的英文注释保持原样。
- **脚本头部与权限统一**：所有脚本的 shebang 一律写 **Termux 绝对路径**（`#!/data/data/com.termux/files/usr/bin/bash` 或 `.../node`），**不用 `#!/usr/bin/env …`**（`/usr/bin` 不可解析，见第 7 节）；`.sh` 与 `.js` 一律置**可执行位**（755），于是 `bash x.sh` / `node x.js` / 直接 `./x` 三种调用都成立。新增脚本请照此对齐——`verify-client-modules-lazy.js` 曾是唯一例外（`env` shebang + 644），2026-09 已对齐。
- `start_dsh.sh` / `stop_dsh.sh` / `restart_dsh_now.sh` 的 **body 只用 POSIX sh**（不用 `local` / `[[ ]]` / 数组 / `<<<` / `$SECONDS`；`$(())`、`case`、参数展开都可用），要求 `bash -n` 与 `dash -n` 都能过（shebang 仍是 bash，用户可能用 `sh` 调）。**但“快”不靠换 shell**：实测 bash 空启动 11ms、dash 17ms，真正成本是 **fork+exec ≈19ms**（100×`true` = 1.9s）——禁止在轮询里每次起子进程。等待用 `tail -n 0 -f` 流式读 + `kill -0` 内建探测，端口只探一次。
- `setup.sh` 输出：默认原始子命令输出进 `~/dsh/setup.log`（`run_hidden`），终端只显示摘要；`--verbose` 用 `tee` 透传；`NO_COLOR=1` 或非 TTY 自动关色。ANSI 序列预先算进变量（`C_*`），输出路径零 fork。
- **常驻状态行**（TTY 且非 `--verbose`）：从脚本开头一直显示到结束，后台 ticker 每 0.15s 重画 `[⠹] 当前步骤 · M:SS`。改输出代码时必须遵守：
  1. **⚠️ 正文必须把 `$SP_CLEAR` 并入同一次 `printf`**（`info/ok/warn/step` 已包装）。**不要写「先 `status_clear` 再 printf」**：那是两次 write，ticker 可能恰好插在中间把状态行画回来，正文与状态行叠成一行。`error` 走 stderr，故单独 `status_clear`（不把光标控制码混进被重定向的 stderr）。
  2. python3/node 子进程自己打印时要读 `SP_CLEAR`（已 `export`）；stderr 非 TTY 时不要往里写控制码（见 `ECLR`）。
  3. 子 shell 看不到父 shell 的变量更新，状态文案经 `STATUS_FILE` 传递；耗时直接用 `SECONDS`（bash 子 shell 会继承并继续累加）。
  4. `status_stop` 幂等，由末尾与 `on_exit` 双保险调用；`STATUS_FILE` 只在 TTY 模式创建（非 TTY 运行不留临时文件）。
  5. **⚠️ 状态行必须按终端实际宽度截断**：`status_cols()` 读 `stty size`（读不到按 30 列），预留 `reserved=9` + **时钟实际宽度**（别写死 5 列），中文按 2 列估算，判非 ASCII 用 `${s//[ -~]/}`（`[[ == *[!-~]* ]]` 是语法错误，`[![:print:]]` 在 UTF-8 locale 下判不出中文）。超宽会折行，而 `\r\033[K` 擦不掉折下去那截，6.7 帧/秒重画会一路刷屏（手机竖屏约 40 列，实测 4 秒滚屏 23 次）。**绝不设“最小宽度”下限**（曾写 `budget=6` 兜底，20 列终端直接刷屏）——预算不够就让标签退化成空。trap `WINCH` 立刻重算，另有 ~3s 兜底轮询。

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
- 启动脚本默认静默：PWA 提示与剪贴板复制只在 `DSH_HINTS=1` 时做（`termux-clipboard-set+get` 一次 0.75s，且本机 `get` 读不回；`copy_url` 自带读回校验，失败不谎报）。正常启动只打印两行，复用已跑服务实测 0.16~0.19s。

### 6.4 幂等、版本漂移与文档

- **幂等**：所有 `apply-*.sh` 和 `setup.sh` 中的修补必须可重复执行——已应用则跳过（grep 特征标记 / `patch -R --dry-run`），内容变化时原地刷新。新增修补者请保持这一约定。
- **版本漂移容错**：dsh 升级会清空并重组 node_modules，补丁可能失效。锚点找不到时必须打印警告并跳过、**不落盘**；只有确认锚点命中才可打印成功。`apply-js-patches.sh` 的 `[FAIL]` 与 `setup.sh` 4c 的退出码 3 即此约定。⚠️ 补丁一旦锚点失效，就**移出活跃清单、进 §12 的「已弃用围栏」**：不要留在活跃清单里每次刷 `[FAIL]`——`setup.sh` 8/9 会每次都报警，久了就是「狼来了」，真正需要人看的失配反而被淹没（0.1.7 的补丁 02 正是这么暴露的）。
- **不破坏上游**：只做最小侵入式文本替换；替换前用特征字符串确认目标仍在，替换后打印说明。
- **⚠️ 最终改动必须落在项目内；问题必须在测试环境复现后解决**：权威来源**只有仓库里的** `setup.sh` / `apply-*.sh` / `patches/*`——直接在 dsh 安装树上手工改文件、或跑一次性 shell 命令，都只算**临时验证**，不算完成；必须回填成脚本/补丁，否则下次 `setup.sh` 或升级就丢（第 1 节「仓库干净 ≠ 设备已修好」的镜像：**设备改好 ≠ 仓库改好**）。任何问题都先在**测试环境**复现再动手：优先用夹具（`mktemp` 假安装树 + `--root`，见 `patches/verify-require-builtin-fixture.js`）或 `--port 0` 临时实例，**别把正在跑的 3080 当实验场**；复现不出就先补探针/夹具，别直接改生产文件。
- **文档同步**：改脚本/补丁行为后，同步更新 `README.md`（**中文节 + 英文节都要改**）、`docs/index.html` 对应条目，以及本文件相关段落。三份文档互相引用，只改一处会立刻过时（历史教训：删掉前端注入后仍留了一大堆描述）。
- **项目记忆只有一个落点：本文件**。`AGENTS.md`（尤其第 7 节踩坑清单）就是本仓库的项目记忆，**不要另建 `.ai-memory/`、`memory/` 之类的记忆目录**——正文里「只改一处会立刻过时」同样适用于记忆，多一份存储必然漂移；操作流水交给 `git log`（提交信息已要求写清原因与实测数字），不需要额外的日程日志。
- 提交信息沿用日志里的风格：中文 Conventional Commits（`fix(stop): …` / `docs(readme,docs): …` / `perf(client-modules): …` / `chore: …`），正文写清**原因与实测数字**。

### 6.5 可调环境变量（脚本读取）

| 变量 | 默认 | 位置 | 作用 |
|---|---|---|---|
| `DSH_PORT` | `3080` | start/stop/restart | 服务端口。⚠️ dsh 不读它，`start_dsh.sh` 必须转成 `--port` 传给 dsh（否则会打出没人监听的 URL） |
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
| `DSH_PNPM_PIN_DIR` | `~/.local/share/pnpm-pin` | setup（2.5/9） | pnpm 11 运行时的安装目录（`npm --prefix` 装；纯 JS build，无原生 exe） |
| `DSH_PNPM_WRAPPER_DIR` | `~/bin` | setup（2.5/9） | `pnpm`/`pn`/`pnpx`/`pnx` 包装脚本目录；**必须在 PATH 上**，否则 dsh 子进程 `execa("pnpm")` 找不到（预检会 `exit 1`） |
| `DSH_PNPM_VERSION` | `11.27.1` | setup（2.5/9） | **仅在需要下载时**用的 pnpm 版本（JS build）；探测到本机已有可用 11.x 时会直接复用、忽略此项。**别升 12.x**（Android 不可用）；11.28+ 也可能改回原生二进制路径 |
| `DSH_PNPM_CONFLICT_OVERRIDE` | `0` | setup（pnpm 运行时） | `$DSH_PNPM_WRAPPER_DIR` 下已有**别人的** pnpm 包装时强制继续（旧文件备份 `.dsh-android.bak`）；pnpm 版本类冲突不可覆盖 |
| `DSH_SETUP_PREFIX` / `DSH_SETUP_PREFLIGHT_ONLY` / `DSH_SETUP_PROVISION_ONLY` | 空 / `0` / `0` | setup | **仅测试夹具/排障用**：把生产路径整体换到临时前缀 / 只跑 pnpm 运行时预检就退出 / 只跑 pnpm 运行时供给就退出。**生产不要设置** |
| `DSH_PACKAGES_DIR` | dsh 的 `node_modules/@deepseek-ai` | apply-js-patches | 目标包目录 |
| `DSH_ROOT`、`RG_PATH` | dsh 安装根、`command -v rg` | apply-rg-fix | 目标根、指定系统 rg |
| `DSH_DIR` | dsh 安装根 | verify-client-modules-lazy | 目标根（link/flock/verify-link 用 `--root`） |

## 7. 实测踩坑清单（每条都真的踩过）

Shell 语义：

- **⚠️ 管道子 shell 里 `return 0` 不会从函数返回**：`f(){ … | while read l; do … return 0; done; }` 的 `return` 只结束那个子 shell；循环里对变量赋值也传不回父 shell。判定成功要看**结果文件非空**（`start_dsh.sh` 的 `RESULT_FILE` / `PORT_FILE` 就是干这个的）。**但更隐蔽的是 `break`**：`tail -f … | while` 里的 `break` 只结束子 shell，`tail` 仍被 `timeout` 挂着，pipeline 要等它，于是「看到失败立即退出」依然等满超时（实测 dsh 已报 `startup failed`，脚本却空等 90s）。现在改用 **FIFO + `done < "$TAIL_PIPE"`** 把读循环留在当前 shell，`break` 后用 `kill $TAIL_PID` 真的结束 `tail`。
- **⚠️ `tail -n 0 -f` 只能看到启动后新写入的行，进程瞬崩时会漏掉原因**：launch 与 tail 之间有竞态。双层兜底：① `tail --pid=<dsh pid>`（GNU coreutils，Termux 自带）→ 进程一死 `tail` 立即退出、读循环 EOF；② 循环结束后再 `kill -0 <pid>` 确认「进程不在了」，把「给 token 前就退出」写成失败原因。只靠日志标记会在「YAML 解析错/原生绑定缺失」这类硬崩上白等满 `READY_TIMEOUT`（实测 90s vs 修后 1.7s）。
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

- **⚠️ 报「bad interpreter: /usr/bin/env」不是脚本 bug，是 Termux 的 shebang 陷阱**：任何 shebang 写 `#!/usr/bin/env …` 的可执行文件在 Termux 上都可能直接执行失败（`/usr/bin` 不可解析）。表现因调用方而异（zsh/bash 说 `bad interpreter`、`sh` 说 `not found`），**极易误判成「包没装」**。判断方法：`node "$(command -v <cmd>)" --version` 能跑通就说明是 shebang 问题而非缺包。修法二选一：`node <real>.js <args>`，或 `readlink -f` 后按 `*.js` 分支包装。
- **⚠️ 升级 dsh 后第一件事是「跑起来」，不是「看补丁还在不在」**：0.1.7 引入 `node-addon-require-builtin` 后，**所有 Android 补丁都还在、全部自检通过，但 dsh 依然完全起不来**——因为新原生 addon 家族的 android 平台包缺失，`dsh-app-boot` 的 host preparation 直接失败。所以版本漂移的检查清单必须包含「`dsh web` 真的能起来 + 鉴权 303→cookie→200」，静态锚点检查只能证明「已知问题没复发」，不能证明「能跑」。
- **⚠️ 上游新增 `<name>-<platform>-<arch>` 平台包时，`process.platform === "android"` 会静默落到 `${platform}-${arch}` 回退分支**：`node-addon-native-custom-loader` 的 `runtimeSuffix()` 只特判 `darwin`、`linux`（再拼 libc 后缀）、`win32`，其余一律 `${process.platform}-${process.arch}`。于是解析 `node-addon-require-builtin-android-arm64` 必然失败。**排查这类问题的通用手法**：扫全树 `optionalDependencies` 里形如 `-(darwin|linux|win32|android|freebsd|openbsd)-` 的依赖，逐个 `require.resolve` 探测，列出「声明了但装不上」的清单，比逐个读源码快得多。
- **⚠️ `npm ls` 报 `UNMET DEPENDENCY` 不一定是问题——先看它在哪个依赖段**：`npm install -g` 从不装 `devDependencies`，根包 devDep（含 `@types/*`）必然 UNMET，属良性（实测 0.1.7-rc.2 的 8 条全是它）。判定顺序：① 依赖段（dev/optional → 良性）；② 全树搜是否真有 import；③ 只有 `dependencies` 里「声明了但装不上」才是真问题。别混淆：*缺失的*平台包不会以 UNMET 出现，而**本补丁生成的那个**显示 `extraneous`（与 `@img/sharp-wasm32`、`@vscode/ripgrep-android-arm64` 并列）——这是自补包的正常形态。
- **⚠️ loader 的「平台可选包」通道不要求 `.node` 文件**：`node-addon-native-custom-loader` 的 `tryRequirePackage()` 只按 `validateLoadedBinding()` 校验导出形状（`requireBuiltin`/`isAllowedInternalId` 是函数、`getNativeBindingInfo()` 返回 `{mode,product,backend,abi}` 且 `backend∈{napi,nodeabi}`、`abi` 与 backend 自洽），**不检查文件是不是 ELF**。所以缺预编译包时可以自己写平台包顶上，不必交叉编译。上游之所以用原生 addon，是为了在**没有** `--expose-internals` 时也能 `require("internal/*")`；而本项目 `dsh` 包装脚本必定带 `--expose-internals`（第 6 步重建，缺了 HMR 会崩），该前提下纯 JS 实现完全够用。⚠️ 但纯 JS **没有**可靠的绕过 `--expose-internals` 的办法（`process.binding("natives")` 只给源码，esm/cjs loader 必须是真实例），所以这条路径与「包装脚本必须带 `--expose-internals`」是**强绑定**的，别拆开。
- **⚠️ 硬阻断补丁要和「只 warn」的补丁区分开**：`node-addon-require-builtin` 平台包缺失 = dsh 起不来，必须 `error` + `exit 1`；link/flock 这类「功能受损但能跑」才是 `warn` + 继续。把两者混成一种语义，会出现「setup 全绿但 dsh 根本起不来」或反过来「一个可选功能缺失就中断安装」。
- **⚠️ 「往 dsh 自己写的 YAML 里追加」不是追加那么简单：`[]` 是个已结束的文档**：dsh 首次启动（哪怕跑失败的那次）由 `initProfile()` 写出 `~/.dsh/profiles/web/cordis.patch.yml` = 3 行注释 + `[]`（`PROFILE_PATCH_TEMPLATE`）。旧版 `setup.sh` 只 `grep danger-full-access` 就 `printf … >>` → `dsh web` 报 `YAMLException: end of the stream or a document separator is expected (13:1)`（行号正好落在我们自己写的那一行）——**补丁全在、自检全绿，dsh 依然起不来**（与 require-builtin 同属「跑不起来」级）。修法是「按内容分类」：`apply-profile-patch.js` 空数组模板→替换、真实层→追加、残留裸 `[]`→定点摘除，写前写后都用 dsh 自己的 `loadOverlayPatches()` 校验（`!!js` 标签只有它的 schema 认），坏文件一字节不动（夹具 41 断言）。通用教训：**往上游/用户维护的文件里写内容前先解析一遍再决定怎么合并**；`grep` 能判「已就位」，判不了「怎么合并」。
- **⚠️ `ALLOW_SCRIPTS` 是「可用性风险面」，而 `--allow-scripts` 的语义**随 npm 版本**不同**：**npm 12** 里白名单内脚本失败会让整次安装退 1（实测 `npm install -g --allow-scripts=koffi koffi@3.1.1` → 退 1；`setup.sh` 3/9 在 `set -euo pipefail` 下随即中断），白名单外只 `warn` 并跳过；**npm 11（本机 11.21.1）** 的 `--allow-scripts=<list>` 只是**建议性**的——未列出的包脚本**仍会执行**、只打警告，只有 `--strict-allow-scripts` 才硬失败。**本机实测后果**：`SKIP_SCRIPTS` 里的 koffi 3.1.1 安装脚本真的执行了，而且**编译成功、可加载**（`koffi.load('libc.so')` OK）——「Android 上构建必然失败」的旧结论在本机**不成立**。这不改变设计：`SKIP_SCRIPTS` 保留（npm 12 下白名单才强制，koffi 留在 `ALLOW_SCRIPTS` 仍会拖死整次安装），`setup.sh` 3/9 增加 npm 策略探测行（advisory / strict），并把用户显式设的 `strict-allow-scripts=true` 当安装冲突处理。判据：查平台可选包是否存在（`npm view @koromix/koffi-android-arm64@<ver>` 404 即无）、看失败是否发生在编译期、再确认运行期是否真有调用点（koffi 全是懒加载 + `win32` 门控）。⚠️ 配套自检表语义：koffi 这种「按设计跳过」的包若照旧算 `[UNCOVERED]`，每次安装都喊一次狼——所以引入 `SKIP_SCRIPTS` 并让它标 `[skipped]`。
- **⚠️ `DSH_HOME` 是根，profile 在 `$DSH_HOME/profiles/web`——不是 `$DSH_HOME/.dsh/profiles/web`**：dsh 的 home 目录结构是 `<root>/{profiles,storage,sessions,...}`，默认 `DSH_HOME=~/.dsh`，于是常被记成「`.dsh` 里再套一层 `.dsh`」。写补丁层或做隔离验收时若写成 `$DSH_HOME/.dsh/profiles/web/cordis.patch.yml`，**文件会写成功但 dsh 永远不读它**（静默忽略，既没报错也没生效）——`apply-profile-patch.js --target` 必须直接指向 `$DSH_HOME/profiles/web/cordis.patch.yml`；隔离验收时若把 `DSH_HOME` 指到临时目录，要记得 profile 就在该目录的 `profiles/web` 下。
- **⚠️ 0.2.1 的 `RETIRED_BUNDLES` 迁移是正常行为，不要当报错**：0.2.1 首次启动会把 `dsh-experimental-schedule-bundle` 从已有 profile 的 bundle 列表里自动摘掉（上游内置迁移）。升级后看到 profile 文件被改、或日志里出现 retired/migrat* 相关行，先确认是不是这条迁移再排查。**不要**为了「保持原样」把该 bundle 塞回去。
- **⚠️ pnpm 12 在 Android 上不可用；pnpm 11.x 是 dsh 插件功能的运行期依赖**：0.2.1 的 plugin-manager / `dsh plugin …` 会 `execa("pnpm")` 从 PATH 找 pnpm。pnpm 12 的原生 `pnpm.exe`（android-arm64 无对应构建/写入 store 失败：`ERR_PNPM_STORE_DIR_ACQUIRE_OPERATION_LOCK` / `lock_shared() not supported`）在这台设备上必失败，所以**只用 pnpm 11.x**。注意本机存在**两个 pnpm**：`$PREFIX/bin/pnpm` 是坏的 npm-global **12.11.2**，`~/bin/pnpm` 是手工钉的 **11.27.1** 包装；`~/bin` 在 PATH 中靠前所以生效的是 11——但 `PATH` 顺序变化时坏 pnpm 会冒出来，排查「pnpm 报 store 锁错误」先跑 `command -v pnpm && pnpm --version` 确认解析到哪个。`setup.sh` 的 **pnpm 运行时预检**把 ≥12 当硬冲突（中文提示 + `exit 1`，不可用 `DSH_PNPM_CONFLICT_OVERRIDE` 覆盖）。
- **⚠️ pnpm 运行时探测**绝不能只看 `command -v pnpm` 一个点，也不能把「PATH 首位是 12.x」直接当死结：本机实测 `$PREFIX/bin/pnpm` 是 npm 全局的 **12.15.0**、`~/bin` 里原本的 11.x 包装已经没了，而 `~/.local/share/pnpm-pin` 里其实一直躺着可用的 **11.27.1**。旧逻辑只看 PATH 首位 → 直接 `exit 1`，用户被卡住（「跑不起来」级）。现在把 PATH 每个目录 + pin + `PNPM_HOME` + npm 全局全探一遍，**优先复用已存在的 11.x**（本机就是复用 pin 里那份、零下载），只有「找不到可用版本且压不过坏 pnpm」才停；停止路径**只读**，并在提示里写清三条修复命令 + 「改完重跑即可」，夹具 `i1` 钉住「停下 → 用户换版本 → 重跑通过」。判据口诀：**先找能用的，再决定要不要装，最后才报错**；错误信息必须包含「探测到了什么」与「怎么修」。
- **⚠️ 安装方式已统一为 npm，`--pnpm` 属于「已删除」的能力，不是「被忽略」的参数**：直接忽略会让「以为用 pnpm 装了、其实走 npm」这种静默错误更难查，所以脚本对 `--pnpm` / `--npm` 明确报「参数已废弃」并 `exit 1`（`DSH_PM` / `DSH_PNPM_BIN` / `DSH_PM_CONFLICT_OVERRIDE` 也一并移除，只有 `DSH_PNPM_*` 的**运行时供给**开关还在）。要恢复 pnpm 安装路径请先读 §11 的「安装后端只有 npm」那条。
- **（历史）pnpm 的全局布局与补丁模型不兼容**：这是移除 pnpm 安装方式的技术原因之一——pnpm 全局安装（`$PNPM_HOME/global/v11/<hash>/node_modules` + global virtual store 符号链接）不是补丁期望的嵌套真实目录布局（补丁直接改写 `<dsh>/node_modules/@deepseek-ai/…`），当时只能绕成「非全局 project 安装 + hoisted + 整体 `mv` 到 `DSH_DIR`」。现在只保留 `npm install -g` 的原生布局，不再需要这层迁移。
- **⚠️ 0.2.0 的权限预设按「sandbox + approval 组合」反查，权限层少一条就整行不激活**：`@deepseek-ai/dsh-permission-presets`（行 id `permission`）在构造时用 `derive(EMPTY_KNOBS)` 反查预设表——`danger-full-access` 预设 = `{sandbox: danger-full-access, approval: never}`，而 approval 的基线默认是 `(process.env.DSH_PERMISSION_MODE ?? 'workspace-write') === 'danger-full-access' ? 'never' : 'ask'`。只把 sandbox 设成 danger-full-access（旧版层的做法）→ 组合是 `{danger-full-access, ask}` → 匹配不到任何预设 → 抛 `permission: composed sandbox and approval defaults match no preset`，该行不激活（启动日志 `warning: 1 entry did not activate`），bash 仍能跑但权限预设服务缺失。**这类「上游新增校验把看起来无关的两行配置耦合起来」的变化，静态锚点检查发现不了**——只有真起一次、扫日志才会暴露（与 require-builtin 同类教训）。判据：新版本里出现「按组合状态反查预设/枚举」的插件时，把该组合在补丁层里**成对**写全。
- **⚠️ 生成物的 manifest 要填包名、「幂等」要比内容**：`patch-dsh-android-require-builtin.js` 早期把 `manifest.name` 写成平台包目录的**绝对路径**（非法 npm 元数据），且 `reuse` 只查标记不比内容 → 改了模板但已装设备永远不更新。现在：`platformPackageFiles()` 算内容 → 逐字节一致才 `[OK]`、否则 `[REFRESHED]`；**归属读 manifest 的 `dshAndroidPatch` 字段、存在性看目录**（按 `index.js` 存在性判断会改写 `main` 指向 `prebuilt/` 的外来包；按子串扫会认错描述里恰好提到它的包）；外来包一律**让路不覆盖**（曾写成直接 throw，而 4-boot 把非 0 当硬阻断 → 把上游合法包判成安装失败），可用性交给同一次 `verify()`：能加载就 `[SKIP]` 退 0。`os`/`cpu` 由 `process.platform`/`process.arch` 推导。通用教训：生成型补丁 ① 幂等比内容不比标记；② 「不是我的东西」要么让路要么报错，报错前先确认它真的不可用。
- **⚠️ `--root` 必须是硬契约（覆盖每个「能改生产树」的脚本）；幂等判定要比语义、不能比子串**：link/flock/verify-link/require-builtin 早期把 `--root` 当「候选链第一项」，给了假 root 就**静默回落生产树**并在那里作业——「拿夹具在临时目录里验证」于是变成假话（实测 `--root <tmp>/badroot` 打印的却是生产路径；生产恰好已打补丁才没写坏）。现在显式 `--root` 定位不到一律报错退 1、不回落。require-builtin 还额外要求**定位契约不依赖「正要判断存在性的那个东西」**：早期「找到 entry 包的 `package.json` 才算安装根」让紧随的「entry 包不存在 → `[SKIP]` 退 0」（dsh <0.1.7）**恒不可达**，健康的 0.1.5 回退安装被 4-boot 硬中断；现在按「根 `package.json` 的 `name` 为 `@deepseek-ai/dsh`，或该目录下就有 entry 包」判定，与 entry 包解耦。幂等判定同样：link 曾用 `includes("publishNoReplaceNoHardlink")`、flock 曾用 `includes("[dsh-android-flock]")` 判「已修」——注释/字符串里出现该标识就报 `[OK]`（实测「仅一句注释」的文件被假成功掩盖）；现在两者都先**逐字符状态机剥掉注释与字符串**再判定：link 要两个 helper 的**函数定义**，flock 要 `platform === 'android'` 真分支并加载 `system.node`（marker 只用于注入）。异常项（`[WARN]`/`[ERROR]`）统一走 **stderr**。回归由 `patches/verify-patch-guards-fixture.js`（39 断言，含断言总数下限）守着——拿修复前脚本跑同一夹具有 21 条 FAIL。
- **⚠️ `dsh web` 报 `startup failed … EADDRINUSE` 不是 dsh 坏了，是端口上已经有一个实例**：每个进程的 token 不同，第二个实例必然绑不上 3080（“2 required plugins did not activate”只是 web-runtime 连带等待）。此时**再拉起一个只会重复失败**，而占用端口的进程可能本会话根本看不到（另一个用户/应用、`root`/`su`、另一个终端会话），`pgrep`/`stop_dsh.sh` 都管不了。`start_dsh.sh` 现在**先探端口再决定是否 launch**：看到端口有响应但没有可见 dsh 进程 → 打印占用情况 + 「结束旧实例 / `DSH_PORT=3081`」并退 1（实测 0.24s，旧路径是 90s + 401 页面）。夹具用例 8/9 钉住「不得再拉起」与「启动失败立即报」。
- **⚠️ `DSH_PORT` 必须显式转成 `--port`：上游不读这个环境变量**（dsh 内部零处引用 `DSH_PORT`/`env.PORT`）。`start_dsh.sh` 早期只 `nohup dsh web --no-open` → 改 `DSH_PORT` 后脚本盯新端口、服务仍绑 3080，打印/打开一个没人监听的 URL（夹具用例 1 用「只认 `--port`」的假 dsh 钉住）。同通路上还有两处失败被当成功：降级裸 URL 的空 `AUTH_CODE` 曾打印「返回 (空)」，现固定为 `no-token`/`HTTP <码>`；回滚 dsh 包装脚本曾用 `rm -f` + `cp -P -f`（命令缺失窗口 + 可能 follow 符号链接），现一律 `mv -f` 原子替换。
- **⚠️ 客户端资源 URL 的形态在 0.1.7 变了两处**（`verify-client-modules-lazy.js` 踩了两次）：① 清单 URL 不再带前导 `/`（`plugins/??…`），拼 origin 前必须补斜杠；② 响应体尾部 `sourceMappingURL` 变成 combo 内相对形态（`??….map&rev=`），但**实际可取的 URL 仍须带 `plugins/` 前缀**——从 `??` 处切开分别推导，别写死单一字符串。
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
- **⚠️ `patch -p1` 的 cwd 是包目录的「父级」，不是包目录本身**：补丁里写的是 `a/dsh-client-modules/lib/index.js`，必须 `cd <...>/node_modules/@deepseek-ai`（= `apply-js-patches.sh` 的 `$DSH_PACKAGES_DIR`）再 `-p1`；cd 进包目录本身会永远失配。写核对脚本时路径与 cwd 必须和 `apply-js-patches.sh` 完全一致，否则「红」不代表真有问题（本会话因此误判过两次）。
- **⚠️ 锚点失效的补丁必须「移入已弃用围栏」，不要留在活跃清单里刷失败；而围栏不得改变执行顺序**：失效补丁留在活跃清单 → 每次 `setup.sh` 8/9 都报警 → 报警成为常态 → 真失配被淹没（0.1.7 的补丁 02 就是这样把用户吓到一次）。移进围栏后只报 `[deprecated]`、不计失败（见 §12）。⚠️ 我按「活跃/弃用」重排执行顺序时踩了坑：**02 与 03 改同一段 `newlineCount`，02 必须先于 03**，把 02 挪到后面执行会让它在**老线上也失配**（实测 0.1.5-rc.3：顺序正确时 02 命中、03 自动 `[skip]`；顺序颠倒时 02 报失配）。围栏只改报告与退出码语义。

## 8. 常用命令

```bash
bash setup.sh                       # 一键安装/升级 + 全量修补（简洁模式；安装方式只有 npm）
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
# 权限层安全安装（按内容分类合并 + dsh 解析器校验）与夹具自检（11 用例 / 41 断言）
node patches/apply-profile-patch.js --target "$HOME/.dsh/profiles/web/cordis.patch.yml" --layer config/cordis.patch.yml --root "$DSH_DIR"
node patches/verify-profile-patch-fixture.js
# link/flock 守护条件夹具自检（11 用例 / 39 断言）
node patches/verify-patch-guards-fixture.js
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

- **脚本级一键检查（每次都该跑）**：`bash patches/verify-all-checks.sh [--verbose] [--full]` = 语法 + 静态契约 27 条 + **6 个夹具（242 条断言）**：js-patches 21 / runtime-scripts 36 / guards 39 / require-builtin 29 / profile 41 / **pnpm-provision 76**（全绿输出 **`套件 PASS=8 FAIL=0`**，加 `--full` 为 `PASS=9`）；`--full` 再跑**变异测试**（10 个注入回归必须让对应套件变红 + 4 个对照组为绿，实测 14/14）。**只读或只写临时目录**：不跑 setup.sh、不碰 3080、不写 `~/.dsh`。
- 无单测框架。此外仍需真实 Termux+Android 环境实跑一次（`dsh web` 起在 `127.0.0.1:3080`）。
- **语法自检**：`bash -n setup.sh`、`bash -n apply-*.sh`；三个运行期脚本还要 `dash -n`。
- **幂等自检**：连续跑两次修补，第二次应全部 `[OK]`/`[skip]`。
- **ripgrep**：`apply-rg-fix.sh` 第 3 步用 fresh node 子进程实际解析 `resolveRgPath()` 并打印版本自证。
- **硬链接**：`patches/verify-android-link-fix.js` 做静态检查 + 临时目录真实运行（附件保存/去重、fs-local 新建文件在 `link()`=EACCES 下必须成功），**不读取/修改 `~/.dsh/sessions`**；必须在 sharp 回退之后跑。
- **flock**：`patches/patch-dsh-android-flock.js` 自带运行时自检（真实 open 两个 fd：首次加锁成功、第二次竞争返回 `EAGAIN`），失败非 0 退出。
- **require-builtin（启动前提，优先级最高）**：`node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH_DIR"`——生成/按内容刷新平台包（内容一致 `[OK]`、不一致 `[REFRESHED]`、外来包 `[SKIP]` 让路），再走真实 entry 包断言 `getBindingInfo()`（`backend=napi`/`abi=napi-v9`）与 5 个 internal 模块成员可用。**反例**：`rm -rf` 平台包后 `dsh web` 必须复现 `No usable native binding found`，重跑补丁必须恢复。
- **require-builtin 夹具自检**：`node patches/verify-require-builtin-fixture.js`——**8 用例 / 29 断言**（本机全绿）。覆盖让路、`dsh <0.1.7` 的 `[SKIP]` 退 0、`--root` 硬契约、两个归属判定回归（外部包无 `index.js`、描述含标记串）。只写临时目录并断言真实树未被触碰。
- **权限层夹具自检**：`node patches/verify-profile-patch-fixture.js`——**11 用例 / 41 断言**（本机全绿）：**崩溃现场 `[REPAIRED]`**（先断言确实解析不了再修）、用户层 `[APPENDED]` 原条目逐字保留、旧版单条层只补 `approval`、用户自配沙箱时不塞 `approval`、坏文件退 1 且一字节不动、真实 `~/.dsh` profile 哈希不变。
- **link/flock 守护条件夹具自检**：`node patches/verify-patch-guards-fixture.js`——**11 用例 / 39 断言**（含断言总数下限；本机全绿）：假 `--root` 退 1 不回落、副本内真编译、注释/字符串/`label://` 骗不过幂等判定。修复前脚本跑同一夹具有 21 条 FAIL。
- **pnpm 运行时供给夹具自检**：`node patches/verify-pnpm-provision-fixture.js`——**76 断言**、**离线**（fake `PATH`/`HOME`/`DSH_PNPM_PIN_DIR`/`DSH_PNPM_WRAPPER_DIR`，不碰真实 `~/.local/share/pnpm-pin`、`~/bin`、安装树、3080、`~/.dsh`）。覆盖各冲突分支（`--version` 不可用 / ≥12 / <11、`DSH_PNPM_WRAPPER_DIR` 不在 PATH、别人的包装、`strict-allow-scripts=true`）、被遮蔽 npm-global pnpm 12 只 warn、手工等价 pin 包装被认领不覆盖、`DSH_SETUP_PROVISION_ONLY=1` 供给幂等（第二次只报 `[OK]`）、默认 npm 路径不变（不出现安装方式预检）、旧旗标 `--pnpm` / `--npm` 一律「参数已废弃」退 1；以及 `i` 系列：压不过坏的 pnpm 12 时**停止且零写入**、把假 pnpm 改成 11.x 后**重跑即通过**、包装能压过时自动供给、pin 里已有 11.x 时**复用且不执行 npm install**。
- **⚠️ 版本升级的隔离验收（不碰 3080）**：`npm install -g --prefix ~/dsh-verify @deepseek-ai/dsh@<ver>` → 补丁脚本 `--root` 指向该 prefix（`apply-rg-fix.sh` 的 `DSH_ROOT` 是 dsh 安装根；link/flock/verify-link 才用 `--root <@deepseek-ai>`）→ `DSH_HOME=<临时目录> … web --no-open --port 3099` → 校验 token URL 303、cookie 后 `/` 200、日志零 warn/error。sharp 回退要手动照 5/9 做一遍。
- **⚠️ 版本漂移要端到端验收**：跑完 `setup.sh` 后**必须**真的起一次，确认日志有 `?token=`、token URL 303、换 cookie 后 `/` 200、无 `warn/error/fatal`。静态全绿 ≠ 能跑（0.1.7 的 require-builtin 就是反例）。
- **补丁 02**：`node patches/verify-client-modules-lazy.js`（`--port 0` 临时实例；核对单条/批量 bundle 与 sourcemap、未知 URL 404、HEAD 200，并打印启动到 token 秒数）。手工等价验证（需另起 `--port 3099`）：与未打补丁实例逐字节比对 `__DSH_BOOT__` 里的资源 URL（比对前去掉 `//# sourceMappingURL=` 行）。冷启动实测：未打补丁 22.6s / 打补丁 12.5s。
- **补丁 01/02/03 锚点核对**：见第 2 节：0.1.5 线 `01[ok] 02[ok]（围栏） 03[skip]`；0.1.7+ `01[ok] 02[deprecated] 03[ok]`，已打过则全 `[skip]`（均退 0）。`[deprecated]` 不是问题，`[FAIL]` 才是。
- **安装脚本白名单自检**：`setup.sh` 3/9 末尾标 `[allowed]`/`[skipped]`/`[UNCOVERED]`；出现 `[UNCOVERED]` 说明 npm 跳过了构建，需把包名补进 `ALLOW_SCRIPTS`。
- **鉴权启动**：`start_dsh.sh` 的 `check_url()` 用 `curl` 校验 token URL 返回 303/302；401 说明 token 过期/日志陈旧，应重启 dsh。
- **⚠️ 别拿本机的 3080 做破坏性实验**：这台设备上 3080 往往正跑着当前会话的 GUI，`stop_dsh.sh` / `restart_dsh_now.sh` 会把它一起停掉；验证补丁优先用 `--port 0` / `--port 3099` 的临时实例。

## 10. 安全注意（这个仓库有意为之）

- **`danger-full-access`**：Android/Termux 无 bwrap/landlock 命名空间沙箱，受限权限模式会让 bash 工具报 `SANDBOX_UNAVAILABLE`，因此必须放开权限模式。**等于关闭进程沙箱，agent 可执行任意命令，仅建议个人设备。**
- 服务只监听 `127.0.0.1`（本机），不走局域网。
- API Key 与 Web 鉴权签名 secret 都在 `~/.dsh`（credentials 0600），不进日志/环境变量/仓库；改动只针对上述绝对安装路径下的 dsh 文件。

## 11. 为 dsh 打补丁时应遵循（设计约束）

- 凡涉及 `link()`（Android 部分 ROM 通过 SELinux 禁用 hardlink）：会话日志【直接发布】改 `rename()`；带 no-replace 语义的发布（会话迁移、附件发布/别名、write 新建文件）在 link 报 `EACCES`/`EPERM`/`EMLINK`/`ENOSYS`/`ENOTSUP` 时回退到「O_EXCL 占位 + rename」；附件祖先遍历/清理容忍 `EACCES`/`ENOENT`。
- **原生 addon 的 Android 适配（两条路，按上游是否发布源码选）**：① 上游带 `src/*.c`（`@deepseek-ai/node-addon-system` 的 `flock.c`）→ clang 编译成本机 `system.node`（Node headers 取 `$PREFIX/include/node` 或 `~/.cache/node-gyp/<ver>/include/node`）并改加载分支；② 上游**只有预编译包、不发源码**（`node-addon-require-builtin`，其 README 明说 published install "fail closed instead of compiling unvalidated local binaries"）→ 按 loader 的「平台可选包」约定自建 `<name>-android-arm64` 包，导出形状过 `validateLoadedBinding()` 即可，纯 JS 亦可（前提运行时带 `--expose-internals`）。其它原生 addon 若报 “not supported on android-*” 或 “No usable native binding found” 可照这两条模式处理。
- 终端 / 平台检测：`process.platform === "android"` 需视同 `"linux"` 处理（见第 7 节 4c 的通配扫描要求）。
- **`03-client-modules-newline-count`**：只改 `newlineCount()` 的循环写法（`for (const char of value)` → `charCodeAt` 索引循环），不改语义。它是**版本无关**的兜底性能补丁，锚点在 0.1.5/0.1.7 上都稳定。
- **安装后端只有 npm（不要再引入第二种）**：`npm install -g` 命令**保持逐字不变**——历史教训是把 pnpm 11 当第二后端（非全局 project 安装 + hoisted 布局 + 迁移到 `DSH_DIR` + `allowBuilds` 映射 + `.dsh-android-pm` 归属标记 + 私有 `pnpm-store` + 一整套共存/版本冲突预检）时，产物与 npm 布局逐项一致、收益为零，却让 `setup.sh` 多出上百行维护面与两份夹具。若将来确有需要，理由必须是「npm 装不上」这种硬需求，而不是速度（隔离实测 pnpm 34s vs npm 5~15min 只在**首次**安装有差别，且升级本来就该重装）。
- **pnpm 运行时的设计约束**：dsh ≥0.2.1 的插件功能 `execa("pnpm")` 是**运行期**依赖，所以 `2.5/9` 必须执行（与安装方式无关，现在安装方式只有 npm）；供给的 pnpm 必须是**纯 JS build**（`npm --prefix <pin> install pnpm@11.x`，用 `node <pin>/node_modules/pnpm/bin/pnpm.mjs` 跑），**绝不能用 pnpm 12 的原生 exe**（android 无构建/写 store 必失败）。包装脚本必须：Termux 绝对 shebang、`exec <node> <绝对路径 mjs> "$@"`、带归属 marker（幂等判定 + 不覆盖用户文件）、且 `$DSH_PNPM_WRAPPER_DIR` 必须在 PATH 且排在坏 pnpm 之前。
- **`02-client-modules-lazy-compose`（仅 0.1.5 线，已弃用）**：改 `dsh-client-modules/lib/index.js` 三处——`newlineCount` 改 `charCodeAt` 索引循环；`buildCombo` 行数只数一次；`compose()` 不再为每条记录急切构建 artifact（`singleRecords` + `singleResponses` 按需缓存，`bundleResource` 用 `?? this.singleResponse(url)` 兜底）。背景：启动期间 `ClientModuleRegistry` 会因 `internal/plugin` 事件**全量重组约 10 次**（实测 table 0→48→…→60），10.8MB 源码下一次 compose 约 2s、占冷启动一半以上（实测 22.6s→12.5s）；挂载的 client 插件越多越慢。
- **本仓库不改动 dsh 前端界面文件**：不注入 CSS/JS、不改 `dsh-web-frontend/dist/index.html` 的 viewport、不改 manifest。历史上 `apply-frontend.sh` + `patches/mobile.css`/`mobile.js` 做过移动端适配，因依赖上游类名/DOM 结构、每次升级必漂移且违背「最小侵入」已删除；前端问题提给上游，本仓库只保证启动/鉴权链路与后端兼容修补。

## 12. 已弃用补丁围栏（deprecated fence）

**策略：锚点一旦失效，就移出活跃清单、进这道围栏**（理由见 §6.4：留在清单里会让每次 `setup.sh` 8/9 都报警，真失配反被淹没）。

围栏规则（由 `apply-js-patches.sh` 的 `DEPRECATED_PATCHES` + `deprecated_reason()` 实现）：

- 围栏补丁**仍在 `PATCHES` 的顺序位置上执行**（顺序即语义：02 必须先于 03，两者改同一段 `newlineCount`），
  但报告与退出码语义不同：能命中 → `[ok] …（弃用围栏：在目标版本上仍然有效）`；
  命中不了 → `[deprecated] <原因>`，**不计入 failed、不影响退出码**。
- 每个围栏补丁必须在 `deprecated_reason()` 里写清**为什么失效**与**什么条件下复活**。
- 围栏**只改报告与退出码，不得改执行顺序**（见上）。
- 与「删除」的区别：删除是彻底不再支持（如已删的 apiproxy history slim 那批）；围栏是**保留但降级**，旧版本线仍可能需要。

| 补丁 | 失效版本 | 原因 | 复活条件 |
|---|---|---|---|
| `02-client-modules-lazy-compose` | 0.1.7 | 上游用原生 `lazyBody` 实现了 combo 按需构建（同一优化），补丁锚点随之消失 | 上游移除 `lazyBody`；或仍需支持 0.1.5 线——实测 0.1.5-rc.3 上 01/02/03 仍能全部命中，故保留在围栏里 |

## 13. 重跑 `setup.sh` 之后怎么复验（本轮经验）

- **npm 重装清掉自补包是预期**：`npm install -g` 会打印 `removed 4 packages, and changed 530 packages`（自补包目录也在其中）；故 4-boot/4-link/4-flock/5/9 重报 `[CREATED]/[PATCHED]/[BUILT]` **不是故障**。
- **复验三步（都不改生产文件）**：① `bash patches/verify-all-checks.sh --full`；② 逐个重跑修补步骤，必须全 `[OK]`/`[skip]`（各修补全 `[OK]`/`[skip]`；js `[skip]×2 + [deprecated]×1`，rg `already patched`；**pnpm 运行时 `2.5/9` 报 `[OK]` 且 `command -v pnpm && pnpm --version` 指向 11.x**）；③ 核对产物：sharp 与 `@img/sharp-wasm32` 同版本、rg 软链在、`system.node` 可加载、权限层两条齐备且无裸 `[]`、`~/bin/{pnpm,pn,pnpx,pnx}` 都在且 `~/bin/pnpm --version` 是 11.x。
- **⚠️ `~/dsh/` 三个副本会与仓库漂移**：只有 `setup.sh` 7/9 同步它们，单独改仓库脚本后**设备跑的还是旧脚本**（本轮实测：仓库已修 `--port`，副本没有）。同步用 `install -m 700 start_dsh.sh stop_dsh.sh restart_dsh_now.sh ~/dsh/` 并核对 `sha256sum`；脚本改动不必重启 dsh。
- **判定「运行中的实例是否真吃到补丁」**：`setup` 只改磁盘，进程内存里可能是旧代码。用 `stat -c '%y' /proc/<pid>` 拿启动时刻（⚠️ Android 上 `ps -o lstart=` 给出荒谬时间、`/proc/uptime` 与 `/proc/net/tcp` 都是 Permission denied、也没有 `getconf`），与补丁产物 mtime 比较；决定性证据是 `/proc/<pid>/maps` 里出现 `…/node-addon-system/bin/android-arm64/system.node`。补丁晚于进程启动 → 必须重启。
- **⚠️ 实例不是 `start_dsh.sh` 拉起时，「复用」会白等 90s（已修）**：判据是 `/proc/<pid>/fd` 的 0/1/2 指向 `/dev/pts/*`（该脚本的拉起路径必然把 stdout 重定向进 `dsh.log`）且 `~/dsh/storage/{dsh.log,dsh.pid}` 陈旧。此时 token 只打在它自己的终端，`tail -n 0 -f` 只读新行 → 旧实现会等满 `DSH_READY_TIMEOUT` 再降级裸 URL（401），并且会先拉起一个必然 EADDRINUSE 的实例。现在：没有可见的 dsh 进程、端口却有响应 → 直接打印占用情况 + 「结束旧实例 / `DSH_PORT=3081`」并退 1（1s 内结束）；`stop_dsh.sh` 在没有可见进程时也会在 stderr 提醒端口仍被占。**一律用 `start_dsh.sh` / `restart_dsh_now.sh` 起服务**。
- **⚠️ 别删认不出的 `$PREFIX/tmp/dsh-*`**：`dsh-spill-*`/`dsh-subprocess-*`/`dsh-workspace-changes-*` 是 **dsh 运行期自己的**（spill 是工具输出溢写，可能是孤儿，删了影响回看历史）；本项目夹具用可辨识前缀 `dsh-runtime-fixture-*`、`dsh-mutation-*`、`dsh-verify-all*`、`dsh-js-patches*`、`dsh-guards*`、`dsh-profile*`。
- **⚠️ 夹具自身的坑**：① 夹具里**生成**假 dsh 时的模板字符串转义会让产物语法错（argv 恒空 → 全场景假红）；② **别用 `pkill -f <pattern>` 清理**，它会命中调用它的 shell 自身（本轮真把自己的命令行杀了）——只杀登记过的 pid 并用 `/proc/<pid>/cmdline` 复核；③ 中断留下的假 dsh 会匹配 `DSH_WEB_PATTERN`，让后续 `start_dsh.sh` 误判「已有进程在跑」→ 空等到超时、级联一片红（「上轮全绿这轮红」多半是它）→ 夹具要启动前自清 + 装 SIGINT/SIGTERM 钩子；④ 变异测试的注入串必须与真实文本逐字符一致（`PATCHES=(…)` 是单行），每个 case 包 try/catch。
