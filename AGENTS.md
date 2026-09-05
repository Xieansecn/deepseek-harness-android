# AGENTS.md

## 仓库定位（这是什么）

`deepseek-harness-android` 是一个**安装与兼容性修补工具包**，用于在 **Android 手机的 Termux 终端**里一键部署并原生运行 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`@deepseek-ai/dsh`，DeepSeek 官方的 agent harness，类比 Claude Code），通过 Web UI（`http://127.0.0.1:3080`）在手机浏览器中使用。

它不是独立的源码项目。仓库里的代码是**胶水脚本 + 补丁**：它们负责安装上游 `dsh` 包，然后对 **已安装到 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh`** 的那份 node_modules 做一系列 Android 兼容修补（直接改写目标文件）。绝大多数改动不落在这份仓库内，而是落在 `dsh` 安装目录里。

> 当前最高支持 `deepseek-harness rc.7`，向下兼容 rc.6 及更早。

## 目录结构

| 路径 | 作用 |
|---|---|
| `setup.sh` | **主入口**。安装构建依赖 → 修补 node-gyp → 编译安装 dsh（android30）→ 应用后端补丁 → sharp wasm 回退 → 重建 `dsh` 包装脚本 → 写入启动/停止/重启脚本与 `danger-full-access` 配置 → 调用各 `apply-*.sh` → 硬链接补丁验证。默认简洁输出，原始命令写入 `~/dsh/setup.log`；支持 `./setup.sh --verbose` 透传原始输出。安装/升级后必须重跑。 |
| `apply-frontend.sh` | 向 `dsh-web-frontend/dist/index.html` 注入移动端 CSS/JS、viewport/manifest 适配（幂等）。 |
| `apply-js-patches.sh` | 应用 JS 性能补丁（history 瘦身、重连增量同步、静态缓存头；幂等，已过时的补丁自动跳过并注明原因）。 |
| `apply-rg-fix.sh` | 修复 grep/glob 报 `ripgrep launch failed`（symlink 系统 `rg` + 修补 `resolveRgPath()` 回退；幂等）。 |
| `start_dsh.sh` | 启动/复用 `dsh web` 服务，提取并校验带 token 的鉴权 URL，然后用 `termux-open-url` 打开浏览器。 |
| `stop_dsh.sh` | 按 pid 文件 + 兜底模式安全停止 dsh。 |
| `restart_dsh_now.sh` | 重启 dsh web，使用 `--no-open` 并写入与 `start_dsh.sh` 相同的 `dsh.log`，保证后续能提取当前进程 token。 |
| `patches/` | 补丁源文件：`01`~`05` 为 `apply-js-patches.sh` 用的 `.patch`；`patch-dsh-android-link.js` 为 link→rename 硬链接修复；`verify-android-link-fix.js` 为硬链接补丁验证脚本；`mobile.css`/`mobile.js` 为 `apply-frontend.sh` 注入内容。 |
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
- 新脚本会先用 `curl` 验证该 URL 返回 `303/302`，避免日志残留旧进程 token 时打开后仍 401。
- `restart_dsh_now.sh` 必须使用 `--no-open`，并且把 dsh 输出写到同一个 `dsh.log`，否则 `start_dsh.sh` 无法找到当前进程的新 token。
- 不要改动 `dsh-web-frontend` 的界面文件；启动脚本和包装脚本只负责把手动打开的鉴权环节做稳。

## 关键约定与写作规范

- **Shell 为主语言**：`setup.sh` 及 `apply-*.sh` 均是 bash，使用 `set -euo pipefail`；进度用 `info()/warn()/ok()/error()` 输出带前缀的彩色行；主步骤用 `step()` 渲染分隔线；注释用中文。
- **日志约定**：`setup.sh` 默认把原始子命令输出写入 `~/dsh/setup.log`，终端只显示摘要；`--verbose` / `SETUP_VERBOSE=1` 可透传原始输出；`NO_COLOR=1` 或非 TTY 时自动关闭颜色；长时间步骤（如 npm install、node-gyp）在 TTY 下显示 spinner。
- **目标文件绝对路径**：所有补丁都针对绝对路径 `/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/...` 下的已安装文件，不要假设相对路径，也不要 cd 到别处。
- **⚠️ 绝不用 `/usr/bin/dsh` 作读写目标**：`/usr` 在部分 shell/挂载命名空间**不可解析**（实测 `ls /usr` 报 No such file or directory）。写 dsh 命令、启动/停止脚本一律用真实绝对路径 `/data/data/com.termux/files/usr/bin/dsh`（`$PREFIX_BIN/dsh`）。
- **⚠️ 绝不`cat >`覆盖 dsh 命令符号链接**：`@deepseek-ai/dsh` 声明 `"bin":{"dsh":"lib/bin.js"}`，`npm install -g` 会把 `/usr/bin/dsh` 覆盖成【符号链接】→ 指向 `lib/bin.js`。用 `cat >` 写它会 **follow 符号链接、可能覆盖 dsh 真实入口代码（弄坏 dsh）**。**正确做法**：写临时文件 + `mv -f "$DSH_TMP" "$DSH_CMD"` 原子替换——`mv` 用 rename(2) 替换 `$DSH_CMD` 这一目录项本身（无论正则还是符号链接），**不 follow 其目标、不触碰 lib/bin.js**。**绝不要先 `rm -f "$DSH_CMD"`**——先 rm 会在写失败时制造"dsh 命令丢失"的非原子窗口。临时文件用 `trap 'rm -f "$DSH_TMP"' EXIT` 清理；备份 `.dsh-android.bak` 只在验证成功或回滚成功后删除，回滚失败必须保留。
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
```

## 测试与验证

- 无明显单测框架。验证依赖真实 Termux+Android 环境实际运行（`dsh web` 起在 `127.0.0.1:3080`）。
- 补丁脚本自身可用**幂等自检**验证：连续跑两次，第二次应全部 `[skip]`。
- 涉及 `resolveRgPath()` 的改动，`apply-rg-fix.sh` 已在第 3 步用 fresh node subprocess 实际解析并打印版本自证。
- 硬链接补丁验证：`patches/verify-android-link-fix.js` 会做静态检查和临时目录写入测试，**不会读取/修改 `~/.dsh/sessions`**。
- 鉴权启动验证：`start_dsh.sh` 的 `auth_url_valid()` 会用 `curl` 验证日志中的 token URL 返回 `303/302`；如果返回 401，说明 token 已过期/日志陈旧，应重启 dsh。

## 安全注意（这个仓库有意为之）

- **`danger-full-access`**：Android/Termux 无 bwrap/landlock 命名空间沙箱，受限权限模式会导致 bash 工具报 `SANDBOX_UNAVAILABLE`。因此必须放开权限模式。**等于关闭进程沙箱，agent 可执行任意命令，仅建议个人设备。**
- 服务只监听 `127.0.0.1`（本机），不走局域网。
- API Key 存于 `~/.dsh/.credentials.yaml`（0600），不进日志、不进进程环境。
- Web 鉴权签名 secret 也存于 `~/.dsh` 的 credentials 中；不要把它写入日志、进程环境或仓库。
- 改动仅应针对上述绝对安装路径下的 dsh 文件，不要改动系统其它位置。

## 为 dsh 打补丁时应遵循（设计约束）

- 凡涉及 `link()`（Android 部分 ROM 通过 SELinux 禁用 hardlink），一律改 `rename()`；write 新建文件用「O_EXCL 占位 + rename」回退；附件祖先遍历/清理容忍 `EACCES`/`ENOENT`。
- 终端 / 平台检测：`process.platform === "android"` 需视同 `"linux"` 处理（subprocess、终端检测等）。
- 前端适配：viewport 用 `interactive-widget=resizes-content`、`viewport-fit=cover`；manifest `display` 用 `standalone`（保证软键盘跟随）；普通回车=换行、Ctrl/Cmd+Enter=发送；Web Crypto / `AbortSignal.any` 在 LAN HTTP 与旧 WebView 缺失，需注入基于 `crypto.getRandomValues()` 的 polyfill。
- **不要为了鉴权去改动 dsh 前端界面**：前端已经能通过 `?token=` 自动换 cookie。项目脚本只需要保证打开正确的 token URL、日志文件一致、--no-open 不干扰浏览器打开流程。
