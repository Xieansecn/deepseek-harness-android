# AGENTS.md

## 仓库定位（这是什么）

`deepseek-harness-android` 是一个**安装与兼容性修补工具包**，用于在 **Android 手机的 Termux 终端**里一键部署并原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`，DeepSeek 官方的 agent harness，类比 Claude Code），通过 Web UI（`http://127.0.0.1:3080`）在手机浏览器中使用。

它不是独立的源码项目。仓库里的代码是**胶水脚本 + 补丁**：它们负责安装上游 `dsh` 包，然后对 **已安装到 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`** 的那份 node_modules 做一系列 Android 兼容修补（直接改写目标文件）。绝大多数改动不落在这份仓库内，而是落在 `dsh` 安装目录里。

> 当前已在 `deepseek-harness 0.1.5-rc.1` 上验证，向下兼容 rc.6 / rc.7 及更早。

## 目录结构

| 路径 | 作用 |
|---|---|
| `setup.sh` | **主入口**。安装构建依赖 → 修补 node-gyp → 编译安装 dsh（android30）→ 应用后端补丁 → sharp wasm 回退 → 重建 `dsh` 包装脚本 → 写入启动/停止/重启脚本与 `danger-full-access` 配置 → 调用各 `apply-*.sh` → 硬链接补丁验证。默认简洁输出，原始命令写入 `~/dsh/setup.log`；支持 `./setup.sh --verbose` 透传原始输出。安装/升级后必须重跑。 |
| `apply-frontend.sh` | 向 `dsh-web-frontend/dist/index.html` 注入移动端 CSS/JS、viewport/manifest 适配（幂等）。 |
| `apply-js-patches.sh` | 应用 JS 性能补丁（幂等）。0.1.2-rc.1 起实际只有 `04`（静态资源 immutable 缓存头）仍生效；`01`/`02`/`03`/`05` 已过时（宿主模块被上游移除/重组或上游已原生实现），按 `SUPERSEDED_NOTE` 自动 `[skip]` 并注明原因。 |
| `apply-rg-fix.sh` | 修复 grep/glob 报 `ripgrep launch failed`（symlink 系统 `rg` + 修补 `resolveRgPath()` 回退；幂等）。 |
| `start_dsh.sh` | 启动/复用 `dsh web` 服务，提取并校验带 token 的鉴权 URL，然后用 `termux-open-url` 打开浏览器。 |
| `stop_dsh.sh` | 按 pid 文件 + 兜底模式安全停止 dsh。 |
| `restart_dsh_now.sh` | 重启 dsh web，使用 `--no-open` 并写入与 `start_dsh.sh` 相同的 `dsh.log`，保证后续能提取当前进程 token。 |
| `patches/` | 补丁源文件：`01`~`05` 为 `apply-js-patches.sh` 用的 `.patch`；`patch-dsh-android-link.js` 为 Android 禁 hardlink 修复（会话直接发布改 `rename()`；no-replace 路径用「O_EXCL 占位+rename」回退）；`patch-dsh-android-flock.js` 为 Android flock 原生绑定（编译 `src/flock.c` + 改 `lib/flock.js`）；`verify-android-link-fix.js` 为硬链接补丁验证脚本（含附件/fs-local 真实运行测试）；`mobile.css`/`mobile.js` 为 `apply-frontend.sh` 注入内容。 |
| `config/cordis.patch.yml` | sandbox `danger-full-access` 配置层，安装到 `~/.dsh/profiles/web/cordis.patch.yml`。 |
| `docs/index.html` | 说明文档站。 |
| `README.md` | 中英文用户文档（安装、修复项、FAQ）。 |

## 新版本 Web 鉴权机制（dsh 0.1.2-rc.1 / rc.7）

dsh Web UI 已从“裸 URL 即可访问”改为 **进程 launch token + 持久化签名 cookie** 的鉴权：

1. 每次 `dsh web` 启动时生成一个内存态 launch token。
2. 服务启动日志打印：
   ```text
   dsh web: http://127.0.0.1:3080/?token=<base64url>
   ```
3. 浏览器访问该 `?token=` URL。
4. 服务端验证 token 后返回 `303`，并设置 `HttpOnly; SameSite=Strict` 的签名 cookie。
5. 之后 `/` 和 `/api` 都走 cookie 鉴权。
6. token 只存在于当前进程，不落盘；签名 secret 存于 `~/.dsh` 的 credentials 中。

因此项目内脚本必须遵守：

- `start_dsh.sh` 必须优先打开日志中的带 token URL，不能只开裸 URL。
- **⚠️ 等 token 必须在整个 `READY_TIMEOUT`（默认 90s）内持续等，不能"端口一响应就倒计时"**：dsh 的端口先开始响应 401，带 token 的 URL 要等 `announceReady()`（整个 plugin loader settle 完）才打印，冷启动实测可达数十秒。早期写成"端口通但 token 无效满 5 次就开裸 URL"，结果冷启动几乎必然打开裸 URL → 401（已用假 dsh 复现并修复）。
- 新脚本会先用 `curl` 验证该 URL 返回 `303/302`，避免日志残留旧进程 token 时打开后仍 401；降级到裸 URL 时必须打印**具体原因**（`no-token` / 实际 HTTP 码），不要只说"若空白/401"。
- token 是**进程级且可重复使用**的（同一 token 连续请求都返回 303，换 cookie 后 303 到干净 `/`），所以校验用的 curl 不会"烧掉"token；303 之后浏览器地址栏显示的是裸 `/`，属正常设计。
- `restart_dsh_now.sh` 必须使用 `--no-open`，并且把 dsh 输出写到同一个 `dsh.log`，否则 `start_dsh.sh` 无法找到当前进程的新 token。
- 不要改动 `dsh-web-frontend` 的界面文件；启动脚本和包装脚本只负责把手动打开的鉴权环节做稳。

## 关键约定与写作规范

- **Shell 为主语言**：`setup.sh` 及 `apply-*.sh` 均是 bash，使用 `set -euo pipefail`；进度用 `info()/warn()/ok()/error()` 输出带前缀的彩色行；主步骤用 `step()` 渲染分隔线；注释用中文。
- **日志约定**：`setup.sh` 默认把原始子命令输出写入 `~/dsh/setup.log`，终端只显示摘要；`--verbose` / `SETUP_VERBOSE=1` 可透传原始输出；`NO_COLOR=1` 或非 TTY 时自动关闭颜色。
- **常驻状态指示器**：TTY 且非 `--verbose` 时，`setup.sh` 有一条**从脚本开头一直显示到结束**的状态行（`[⠹] 当前步骤 · M:SS`），由后台 ticker 子 shell 每 0.15s 重画。改动输出代码时必须遵守：①任何正式输出前先 `status_clear`、打完后 `status_render`（`info/ok/warn/error/step` 已包装），否则会和状态行叠在同一行；②子 shell 看不到父 shell 的变量更新，所以状态文案经 `STATUS_FILE` 传递；③耗时直接用 `SECONDS`（bash 子 shell 会继承并继续累加父 shell 的秒数）；④只有 TTY 才启用，非 TTY / `--verbose` 退回"打印一行静态提示 / 透传原始输出"的老行为；⑤`status_stop` 幂等且由末尾与 `on_exit` 双保险调用；⑥**状态行必须按终端实际宽度截断**（`status_cols()` 读 `stty size`，读不到按 30 列保守处理）——超过终端宽度就会自动折行，而 `\r\033[K` 只擦得掉当前行开头、折下去的那截擦不掉，6.7 帧/秒重画会把屏幕一路往下刷（手机 Termux 竖屏约 40 列，实测未截断时 4 秒滚屏 23 次，就是用户报的"刷屏"）；中文按 2 列/字符估算，含非 ASCII 的判定用参数展开 `${s//[ -~]/}`（`[[ == *[!-~]* ]]` 是语法错误，`[![:print:]]` 在 UTF-8 locale 下判不出中文）。
- **目标文件绝对路径**：所有补丁都针对绝对路径 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/...` 下的已安装文件，不要假设相对路径，也不要 cd 到别处。
- **⚠️ 绝不用 `/usr/bin/dsh` 作读写目标**：`/usr` 在部分 shell/挂载命名空间**不可解析**（实测 `ls /usr` 报 No such file or directory）。写 dsh 命令、启动/停止脚本一律用真实绝对路径 `/data/data/com.termux/files/usr/bin/dsh`（`$PREFIX_BIN/dsh`）。
- **⚠️ 绝不`cat >`覆盖 dsh 命令符号链接**：`@deepseek-ai/dsh` 声明 `"bin":{"dsh":"lib/bin.js"}`，`npm install -g` 会把 `/usr/bin/dsh` 覆盖成【符号链接】→ 指向 `lib/bin.js`。用 `cat >` 写它会 **follow 符号链接、可能覆盖 dsh 真实入口代码（弄坏 dsh）**。**正确做法**：写临时文件 + `mv -f "$DSH_TMP" "$DSH_CMD"` 原子替换——`mv` 用 rename(2) 替换 `$DSH_CMD` 这一目录项本身（无论正则还是符号链接），**不 follow 其目标、不触碰 lib/bin.js**。**绝不要先 `rm -f "$DSH_CMD"`**——先 rm 会在写失败时制造"dsh 命令丢失"的非原子窗口。临时文件由 `on_exit`（全脚本唯一的 EXIT trap）统一清理——**不要**再注册 `trap 'rm -f "$DSH_TMP"' EXIT`，那会覆盖 `on_exit`、吞掉其后所有步骤的失败日志输出；备份 `.dsh-android.bak` 只在验证成功或回滚成功后删除，回滚失败必须保留。**⚠️ `on_exit` 里打印日志尾部必须写 `tail -25 "$SETUP_LOG" >&2`**：重定向从左到右生效，`tail … 2>/dev/null >&2` 会先把 stderr 指向 /dev/null，再把 stdout 复制成同一个 /dev/null，"最近日志"后面永远是空的（实测确认过，已修）。
- **dsh 包装脚本内容**：统一为 `exec node --expose-internals --no-warnings <绝对路径>/lib/bin.js "$@"`。lib/bin.js 的 shebang 是 `#!/usr/bin/env node`，缺 `--expose-internals`，故必须重建包装脚本。
- **进程匹配用 `[b]in.js` 括号技巧**：`pgrep/pkill -f` 可能匹配到含模式串的调用 shell 自身。模式写成 `.../lib/[b]in.js web`（含 dsh 绝对路径 + `web` 子命令），避免自匹配误杀；避免用裸 `-f` 子串。
- **按 pid 文件杀进程前必做身份二次确认**：pid 文件记录的 pid 可能被系统复用给无关进程。kill 前须 `pgrep -f "$DSH_WEB_PATTERN" | grep -qx "$pid"` 或 `ps -p "$pid" -o args= | grep -q "$DSH_WEB_PATTERN"` 确认它确实是 dsh web（与 stop_dsh.sh 一致），否则跳过走兜底匹配。
- **幂等性要求**：所有 `apply-*.sh` 和 `setup.sh` 中的修补必须可重复执行——已应用则跳过（用 grep 特征标记或 `patch -R --dry-run` 检测），内容变化时在原地刷新。新增修补者请保持这一约定。
- **版本漂移容错**：dsh 升级会清空并重组 node_modules，补丁可能失效。若锚点文本找不到，必须打印警告并跳过错（退出码 0），不要强行改写导致整体失败。参考 `apply-js-patches.sh` 的 `SUPERSEDED_NOTE` 模式。
- **不破坏上游**：只做最小侵入式文本替换（`python3` 或 `node` 读改写），替换前用特征字符串确认目标仍在，替换后打印说明。
- **中文注释**：脚本注释与用户提示用中文；`apply-rg-fix.sh` 英文注释遵循其原样。

## 常用命令

```bash
bash setup.sh                       # 一键安装/升级 + 全量修补（简洁模式）
bash setup.sh --verbose             # 同时显示原始子命令输出
bash ~/dsh/start_dsh.sh       # 启动 dsh web 并打开带 token 浏览器
bash ~/dsh/stop_dsh.sh        # 停止
bash ~/dsh/restart_dsh_now.sh # 重启 dsh web
```

后续维护/改动时：

```bash
# 单独重跑某个修补（避免整树重装）
bash apply-rg-fix.sh
bash apply-frontend.sh
bash apply-js-patches.sh
# 硬链接补丁与验证
node patches/patch-dsh-android-link.js --root "$DSH_DIR/node_modules/@deepseek-ai"
node patches/verify-android-link-fix.js --root "$DSH_DIR/node_modules/@deepseek-ai"
# Android flock 原生绑定（编译 + 自检 + 改 flock.js）
node patches/patch-dsh-android-flock.js --root "$DSH_DIR/node_modules/@deepseek-ai"
```

## 测试与验证

- 无明显单测框架。验证依赖真实 Termux+Android 环境实际运行（`dsh web` 起在 `127.0.0.1:3080`）。
- 补丁脚本自身可用**幂等自检**验证：连续跑两次，第二次应全部 `[OK]`/`[skip]`。
- 涉及 `resolveRgPath()` 的改动，`apply-rg-fix.sh` 已在第 3 步用 fresh node subprocess 实际解析并打印版本自证。
- 硬链接补丁验证：`patches/verify-android-link-fix.js` 会做静态检查 + 临时目录真实运行测试（附件保存/去重、fs-local 新建文件在 `link()`=EACCES 下必须成功），**不会读取/修改 `~/.dsh/sessions`**。**⚠️ 它必须在 `setup.sh` 的 sharp WASM 回退之后运行**：附件测试要 `import dsh-attachment-local`，该模块加载时 `import sharp`；`npm install` 清空 node_modules 后 sharp 在回退前必然加载失败，会误报"硬链接修复验证未通过"。
- flock 绑定验证：`patches/patch-dsh-android-flock.js` 自带运行时自检（真实 open 两个 fd：首次加锁成功、第二次竞争返回 `EAGAIN`），失败会非 0 退出。
- 鉴权启动验证：`start_dsh.sh` 的 `auth_url_valid()` 会用 `curl` 验证日志中的 token URL 返回 `303/302`；如果返回 401，说明 token 已过期/日志陈旧，应重启 dsh。

## 安全注意（这个仓库有意为之）

- **`danger-full-access`**：Android/Termux 无 bwrap/landlock 命名空间沙箱，受限权限模式会导致 bash 工具报 `SANDBOX_UNAVAILABLE`。因此必须放开权限模式。**等于关闭进程沙箱，agent 可执行任意命令，仅建议个人设备。**
- 服务只监听 `127.0.0.1`（本机），不走局域网。
- API Key 存于 `~/.dsh/.credentials.yaml`（0600），不进日志、不进进程环境。
- Web 鉴权签名 secret 也存于 `~/.dsh` 的 credentials 中；不要把它写入日志、进程环境或仓库。
- 改动仅应针对上述绝对安装路径下的 dsh 文件，不要改动系统其它位置。

## 为 dsh 打补丁时应遵循（设计约束）

- 凡涉及 `link()`（Android 部分 ROM 通过 SELinux 禁用 hardlink）：会话日志【直接发布】改 `rename()`；带 no-replace 语义的发布（会话迁移、附件发布/别名、write 新建文件）在 link 报 `EACCES`/`EPERM`/`EMLINK`/`ENOSYS`/`ENOTSUP` 时回退到「O_EXCL 占位 + rename」；附件祖先遍历/清理容忍 `EACCES`/`ENOENT`。
- **⚠️ 改 `node:fs/promises` 导入时只增不删**：`patch-dsh-android-link.js` 的 `ensureFsImport()` 只追加名字。曾有版本把 `link` 从导入里删掉，但同文件 `defaultFileSystem` / `publishCurrentExclusive` 仍在引用 `link`，导致 dsh 启动即 `ReferenceError: link is not defined`。删除导入前必须确认全文（含注释外的正文）不再引用它。
- **原生 addon 的 Android 适配**：上游 `@deepseek-ai/node-addon-system` 只发布 linux/darwin 预编译包。`flock` 路径（`patch-dsh-android-flock.js`）用 clang 编译其自带 `src/flock.c` 为 `bin/android-<arch>/system.node`，并改 `lib/flock.js` 在 `android` 下加载本地绑定（Node headers 取 `$PREFIX/include/node` 或 `~/.cache/node-gyp/<ver>/include/node`）。其它原生 addon 若报 “not supported on android-*” 可照此模式处理。
- 终端 / 平台检测：`process.platform === "android"` 需视同 `"linux"` 处理（subprocess、终端检测等）。**⚠️ 锚点可能在内容哈希 bundle 里**：0.1.5-rc.1 起 `createProcessInspector()` 被内联进 `dsh-subprocess-local/lib/runner-launch-*.js`，`lib/index.js` 里已找不到 `new LinuxProcessInspector(...)`。因此 `setup.sh` 的 4c 按通配扫描整个 `lib/` 目录，命中才报成功，未命中明确告警——不要退回「只 grep 单个固定文件 + 无条件打印成功」的写法（那会制造假成功，终端功能静默失效）。
- **补丁必须报真话**：修补步骤只有在确认锚点命中后才可打印成功；锚点未命中要打印 `warn`（按版本漂移约定不中断 setup），绝不可像早期 4c 那样 `str.replace()` 未命中却仍写回文件并打印 “patched”。同理，`anchor_precheck` 的 marker 必须是「打上补丁后才会出现」的特征串，否则预检永远报 OK、掩盖问题。
- 前端适配：viewport 用 `interactive-widget=resizes-content`、`viewport-fit=cover`；manifest `display` 用 `standalone`（保证软键盘跟随）；普通回车=换行、Ctrl/Cmd+Enter=发送；Web Crypto / `AbortSignal.any` 在 LAN HTTP 与旧 WebView 缺失，需注入基于 `crypto.getRandomValues()` 的 polyfill。
- **不要为了鉴权去改动 dsh 前端界面**：前端已经能通过 `?token=` 自动换 cookie。项目脚本只需要保证打开正确的 token URL、日志文件一致、--no-open 不干扰浏览器打开流程。
