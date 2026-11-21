# REPORTS.md — Android/Termux 修改与适配报告

本文件记录**当前**仓库的全部安装期修改、验证证据与升级风险。历史包袱（pnpm 安装后端、pnpm 运行时供给、JS 性能补丁、作曲栏回车补丁、前端注入）已于 **2026-11-21** 删除，见 §4。

## 0. 一页速览

| 项 | 事实 |
|---|---|
| 仓库定位 | 安装期补丁工具包；**只服务 Termux/Android**；**不改动 dsh 前端**；安装后端只有 npm |
| 适配基线 | dsh `0.2.2-rc.5`（npm `latest`）；补丁按语义形状匹配，rc.1 / rc.3 仍支持 |
| 修改总数 | **8 项**（3 个补丁脚本 + 1 个权限层安装器 + 1 个 ripgrep 修复 + 安装/运行期脚本） |
| 硬阻断项 | require-builtin 平台包、ripgrep 实际解析、node-pty 产物、sharp wasm、权限层解析 |
| 只 warn 项 | link、flock、subprocess 平台检测、锚点漂移 |
| 脚本级测试 | 静态契约 **40** 条 + 5 个夹具 **193** 断言 + 变异测试 8 注入 / 4 对照组 |
| 不做 | 前端改动、CSS/JS 注入、性能补丁、pnpm 安装路径 |

## 1. 版本基准与数据来源

| 来源 | 值（2026-11-21 核对） |
|---|---|
| npm registry `@deepseek-ai/dsh` | `latest = next = 0.2.2-rc.5` |
| 上游仓库 `deepseek-harness`（本地 `~/deepseek-harness`，已 pull） | master `2e39e70`；tag `dsh-v0.2.2-rc.5` = `9c2670d` |
| 上游 Android 支持 | 运行时包**零处** android 分支；npm 上**无**任何 `*-android-arm64` 平台包 |
| 本机 | Termux aarch64、无 root；Node `v26.13.1`、npm `12.2.3`、ripgrep `15.2.0` |

⚠️ 版本号只表示「撰写/实测时点」。脚本与补丁**禁止按版本号分支**；升级前后用
`node -p "require('$DSH_DIR/package.json').version"` 与 `npm view @deepseek-ai/dsh dist-tags` 核对。

## 2. 修改全景

### 2.1 修改总表

| # | 目标（安装树内） | 补丁/脚本 | 阶段 | 失败语义 |
|---|---|---|---|---|
| 1 | `<dsh>/node_modules/node-addon-require-builtin-android-arm64`（新建） | `patches/patch-dsh-android-require-builtin.js` | 4/8 | **中断安装**（缺它 dsh 起不来） |
| 2 | `dsh-subprocess-local/lib/*.js` | `setup.sh` 内嵌 python（通配扫描） | 4/8 | warn（终端功能受损） |
| 3 | `node-pty` 构建 | `setup.sh` `ALLOW_SCRIPTS` + 产物校验 | 3/8 | **中断安装** |
| 4 | `@vscode/ripgrep-android-arm64/bin/rg` + `resolveRgPath()` | `apply-rg-fix.sh` | 4/8 | **中断安装**（grep/glob 全废） |
| 5 | `dsh-session-persistence-jsonl` / `dsh-attachment-local` / `dsh-fs-local` | `patches/patch-dsh-android-link.js` | 4/8 | warn |
| 6 | `node-addon-system/lib/flock.js` + `bin/android-<arch>/system.node` | `patches/patch-dsh-android-flock.js` | 4/8 | warn（发消息失败） |
| 7 | `<dsh>/node_modules/@img/sharp-wasm32` + `@emnapi/runtime` | `setup.sh` 5/8 | 5/8 | **中断安装**（附件/图片不可用） |
| 8 | `~/.dsh/profiles/web/cordis.patch.yml` | `patches/apply-profile-patch.js` + `config/cordis.patch.yml` | 7/8 | **中断安装**（权限预设行不激活 / YAML 解析失败） |

另：`dsh` 命令包装脚本（6/8）重建为 `exec node --expose-internals --no-warnings <dsh>/lib/bin.js "$@"`。**它是 #1 的强绑定前提**：纯 JS 平台包依赖 `require("internal/*")`。

### 2.2 逐项根因

1. **require-builtin**：上游 0.1.7 引入的原生 addon 家族用 `<name>-<platform>-<arch>` 解析平台包，android 落到 `android-arm64` 槽位但上游不发布；`dsh-app-boot` 的 `internalModules()` 无条件 require → host preparation 直接失败。上游**不发源码**，只能按 loader 约定自建平台包（纯 JS，导出形状过 `validateLoadedBinding()`）。
2. **subprocess 平台检测**：`createProcessInspector()` 只认 linux/darwin/win32，Android 直接 `throw terminal inspection is unsupported on platform android`。补丁把 `android` 视同 `linux`。
3. **node-pty**：`prebuilds/` 有 linux/darwin/win32，没有 `android-arm64`；安装脚本被 npm 白名单放行后用 Termux headers 编译，3/8 校验 `pty.node` 可加载。
4. **ripgrep**：`@vscode/ripgrep` 只做 `require.resolve('@vscode/ripgrep-android-arm64/bin/rg')`；平台包不存在。软链系统 rg 即可解析，源码回退是双保险。
5. **link**：部分 ROM 的 SELinux 对 app 私有数据禁止硬链接（本机 `fs.link()` 实测 `EACCES`）。dsh 用 `link()` 做原子发布与 no-replace，必须回退到 `rename` / 「O_EXCL 占位 + rename」。
6. **flock**：`node-addon-system/lib/flock.js` 只接受 linux/darwin；bionic 支持 `flock(2)`，本地编译即可。
7. **sharp**：`libvips` 无 android 预编译，`sharp` 报 `Could not load the "sharp" module using the android-arm64 runtime`；同版本 wasm32 可用。
8. **权限层**：Android 无 bwrap/landlock，`sandbox-policy` 必须是 `danger-full-access`；0.2.0 起上游 `permission` 按 `sandbox + approval` 组合反查预设，**两条必须成对**。dsh 自己写出的 `[]` 空数组模板是「已结束的文档」，直接 `>>` 追加会让 profile 解析失败、服务起不来。

## 3. 验证证据（2026-11-21）

**隔离 npm 安装（不碰生产树、不碰 3080）**

```bash
npm install -g --prefix ~/dsh-verify/npm @deepseek-ai/dsh@0.2.2-rc.5 \
  --allow-scripts=@deepseek-ai/dsh-subprocess-local,node-pty,@google/genai,protobufjs
# → added 664 packages in 2m；只有 koffi 被按设计跳过
```

逐项执行本仓库补丁（`--root` 指向该隔离树）：

| 步骤 | 结果 |
|---|---|
| require-builtin 平台包 | `[CREATED ]` + `entry 包加载成功：backend=napi abi=napi-v9` + `internalModules()` 自检通过 |
| link | 三个包全 `[PATCHED ]` |
| flock | `[BUILT ] system.node` + 运行时自检（首次加锁成功 / 竞争 EAGAIN）+ `[PATCHED ] flock.js` |
| ripgrep | 两代落点命中；fresh node 解析 `rg` 15.2.0 |
| node-pty | `require('node-pty')` 成功（`spawn` 可用） |
| sharp | `@img/sharp-wasm32@0.35.5` + `@emnapi` 安装后 `require('sharp')` 成功 |
| 权限层 | `[CREATED ]`（隔离 HOME） |
| Web 链路 | `token → 303`、cookie 后 `/` → `200`、日志零 warn/error |

**脚本级检查**：`bash patches/verify-all-checks.sh` → `PASS=7 FAIL=0`；静态契约 `PASS=40 FAIL=0`。

**⚠️ 未覆盖**：真机全局重装 rc.5（生产仍是 rc.1）、agent 工具链端到端（bash/grep/附件真实调用，需要 API Key）、`--full` 变异测试在本轮未跑。

## 4. 已删除（2026-11-21 修剪）

| 删除项 | 原因 |
|---|---|
| 作曲栏「回车=换行」补丁（曾在 `setup.sh` 4d） | 改的是 `dsh-client-ui-conversation`，属**前端界面行为**，违反「不改前端」 |
| `apply-js-patches.sh` + `patches/01-frontend-static-cache.patch` | 纯性能（`/assets/` immutable 缓存头），非 Android 兼容 |
| `patches/03-client-modules-newline-count.patch` | 纯性能（`newlineCount` 索引循环） |
| `npm_android.sh` | 只为手动 npm 编译 koffi；dsh 运行期不需要 koffi，安装路径只保留 setup.sh |
| `2.5/9` pnpm 运行时供给（含 `DSH_PNPM_*` 环境变量、冲突预检） | 只服务 `dsh plugin` 功能，与 dsh 本体兼容无关；pnpm 全局布局也与补丁落点不兼容 |
| 对应夹具（js-patches 19 / composer 29 / pnpm-provision 76） | 随被测行为一起删除，避免「永远绿的假夹具」 |

## 5. 风险与升级须知

1. **升级入口唯一**：dsh 升级/修复只走 `bash setup.sh`。裸 `npm -g update` 会覆盖全部安装期补丁、丢失 Android 编译参数，并可能与 `dsh` 包装脚本的 bin link 冲突。
2. **版本漂移**：上游若重写 `dsh-subprocess-local`、`dsh-fs-local`、`flock.js`、`getNativeBindingInfo` 形状，锚点会失配。4/8 的 link/flock/subprocess 只 warn（功能受损但能跑），require-builtin 与 ripgrep 会中断安装——这是有意的分级。
3. **布局假设**：补丁脚本写死 `<dsh>/node_modules/@deepseek-ai/...` 与 `<dsh>/node_modules/<platform-pkg>`（npm 全局布局）。**不要**改用 pnpm 安装。
4. **纯 JS 平台包与 `--expose-internals` 强绑定**：6/8 的包装脚本必须保留该参数，否则 dsh 启动即 `Cannot find module 'internal/modules/esm/loader'`（已在 rc.5 复现）。
5. **`koffi` 仍属跳过项**：npm 12 下把它放进 `ALLOW_SCRIPTS` 会让整次安装退 1；运行期只在 win32 分支懒加载。
6. **权限模式**：`danger-full-access` 等于关闭进程沙箱，仅建议个人设备。

## 6. 附录：复现命令

```bash
# 一键脚本级检查（只读 / 临时目录）
bash patches/verify-all-checks.sh
bash patches/verify-all-checks.sh --full

# 隔离安装 + 逐项验证（不碰 3080、不碰生产树）
npm install -g --prefix ~/dsh-verify/npm @deepseek-ai/dsh@0.2.2-rc.5 \
  --allow-scripts=@deepseek-ai/dsh-subprocess-local,node-pty,@google/genai,protobufjs
DSH=~/dsh-verify/npm/lib/node_modules/@deepseek-ai/dsh
node --expose-internals patches/patch-dsh-android-require-builtin.js --root "$DSH"
node patches/patch-dsh-android-link.js  --root "$DSH/node_modules/@deepseek-ai"
node patches/patch-dsh-android-flock.js --root "$DSH/node_modules/@deepseek-ai"
DSH_ROOT="$DSH" bash apply-rg-fix.sh
node patches/apply-profile-patch.js --target "$HOME/dsh-verify/home/profiles/web/cordis.patch.yml" \
  --layer config/cordis.patch.yml --root "$DSH"
DSH_HOME=~/dsh-verify/home node --expose-internals "$DSH/lib/bin.js" web --no-open --port 3099
```
