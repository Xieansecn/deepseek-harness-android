#!/data/data/com.termux/files/usr/bin/bash
# DeepSeek Harness 安装脚本（Android/Termux）：安装 @deepseek-ai/dsh 并应用全部 Android 兼容补丁（幂等，可重复运行）。
# 用法：bash setup.sh [--verbose]。安装完成后，执行 bash ~/dsh/start_dsh.sh 启动服务。
#   --verbose                透传安装命令的原始输出（默认只把原始输出写入 ~/dsh/setup.log）。
#   安装方式只有一种：`npm install -g`（命令与旧版逐字一致）。
#   DSH_SETUP_PREFIX=<dir>    仅测试夹具用：把生产前缀整体换到临时目录，生产环境请勿设置。
set -euo pipefail

# ---------------------------------------------------------------- 输出/日志
# 默认只输出摘要，原始命令输出写入 ~/dsh/setup.log；--verbose 可透传原始输出。
SETUP_LOG="$HOME/dsh/setup.log"
mkdir -p "$HOME/dsh"
: > "$SETUP_LOG"
START_TIME="$(date +%s)"

VERBOSE=0
# 安装方式唯一（npm install -g）；这里只解析 --verbose（参数顺序任意，便于与旧习惯兼容）。
for setup_arg in "$@"; do
  case "$setup_arg" in
    --verbose) VERBOSE=1 ;;
    --pnpm|--npm)
      # 兼容旧调用：安装方式已统一为 npm，不再提供 pnpm 安装路径。
      printf '[x] 参数已废弃：%s。安装方式只有 npm（npm install -g），请直接执行 bash setup.sh [--verbose]。\n' "$setup_arg" >&2
      exit 1 ;;
  esac
done
if [ "${SETUP_VERBOSE:-0}" = "1" ]; then
  VERBOSE=1
fi

USE_COLOR=1
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  USE_COLOR=0
fi
# ANSI 转义预先算成变量：原来每行输出要 $(color …) 起 2~3 个子 shell，ticker 每帧还要 3 个，
# 6.7 帧/秒就白白多出约 20 次 fork+exec/秒。现在输出路径零 fork。
if [ "$USE_COLOR" -eq 1 ]; then
  C_RST=$'\033[0m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'; C_CYAN=$'\033[1;36m'
else
  C_RST=""; C_DIM=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi
# SP_CLEAR：状态行开着时正文前要先擦掉它。必须与正文并进【同一次 printf】——若拆成
# "先 status_clear 再 printf" 就是两次 write，ticker 可能恰好插在中间把状态行画回来，
# 正文便与状态行叠成一行。合并为一次 write 后 tty 层不会交叠两次写。
# export：直接打印的 python 子进程也要读它（见下方各 python 块）。
export SP_CLEAR=""
info()  { printf '%s%s==>%s %s\n' "$SP_CLEAR" "$C_BLUE" "$C_RST" "$*"; status_render; }
ok()    { printf '%s%s[✓]%s %s\n' "$SP_CLEAR" "$C_GREEN" "$C_RST" "$*"; status_render; }
warn()  { printf '%s%s[!]%s %s\n' "$SP_CLEAR" "$C_YELLOW" "$C_RST" "$*"; status_render; }
# error 走 stderr：单独 status_clear（写 stdout），免得把光标控制码混进被重定向的 stderr 文件。
error() { status_clear; printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; status_render; }
step()  {
  printf '%s\n%s━━ %s ━━%s\n' "$SP_CLEAR" "$C_CYAN" "$*" "$C_RST"
  status_step "$*"
}
# 运行子命令：默认全量写入 setup.log，--verbose 时同时透传到终端。
run_hidden() {
  if [ "$VERBOSE" -eq 1 ]; then
    "$@" 2>&1 | tee -a "$SETUP_LOG"
  else
    "$@" >>"$SETUP_LOG" 2>&1
  fi
}

# 常驻状态行 [⠹] 步骤 · 已用时间：后台 ticker 每 0.15s 重画；正式输出前用 SP_CLEAR 擦行、打完 status_render。
STATUS_TTY=0
if [ "$VERBOSE" -eq 0 ] && [ -t 1 ]; then STATUS_TTY=1; fi
STATUS_ON=0
STATUS_PID=""
STATUS_FILE=""   # 仅 TTY 模式在 status_start 里创建，避免非 TTY 运行也留临时文件
STATUS_STEP="准备中"
STATUS_OVERRIDE=""
status_render() {
  [ "$STATUS_ON" -eq 1 ] || return 0
  printf '%s' "${STATUS_OVERRIDE:-$STATUS_STEP}" > "$STATUS_FILE" 2>/dev/null || true
}
status_clear() {
  [ "$STATUS_ON" -eq 1 ] || return 0
  printf '\r\033[K'
}
# 终端列数（取不到按 30 列保守处理）：状态行超宽会折行，而 \r\033[K 擦不掉折下去那截 → 刷屏。
status_cols() {
  local c=""
  c="$(stty size 2>/dev/null | awk '{print $2}')" || true          # stdin 是终端时最省事
  if [ -z "$c" ]; then c="$(stty size 2>/dev/null </dev/tty | awk '{print $2}')" || true; fi
  case "$c" in ''|*[!0-9]*) c=30 ;; esac
  [ "$c" -gt 0 ] || c=30
  printf '%s' "$c"
}
# 记录当前主步骤（run_hidden_spinner 的临时文案结束后会回到这里）。
status_step() {
  STATUS_STEP="$1"
  status_render
}
status_start() {
  [ "$STATUS_TTY" -eq 1 ] || return 0
  STATUS_FILE="$(mktemp)"
  STATUS_ON=1
  SP_CLEAR=$'\r\033[K'
  status_render
  (
    local chars=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 label cols budget maxchars stamp
    # 行内固定开销：'[X] '(4) + ' · '(3) + 安全余量 2 = 9 列，另加时钟【实际】宽度。
    # 别把时钟写死成 5 列（M:SS）：跑满 100 分钟后变成 6 列。宽度预算不够时宁可把标签缩到空。
    local reserved=9
    cols="$(status_cols)"
    # 终端被旋转/缩放时内核发 SIGWINCH：bash 会在当前 sleep 结束后立刻跑 trap（≤0.15s），
    # 比等 3s 轮询快得多；下面的轮询只作为兜底。
    trap 'cols="$(status_cols)"' WINCH
    while :; do
      if [ $((i % 20)) -eq 0 ]; then cols="$(status_cols)"; fi   # 约每 3s 复查一次（终端可被旋转/缩放）
      label="$(cat "$STATUS_FILE" 2>/dev/null || true)"
      stamp="$(printf '%d:%02d' $((SECONDS / 60)) $((SECONDS % 60)))"
      budget=$((cols - reserved - ${#stamp}))
      if [ -n "${label//[ -~]/}" ]; then maxchars=$((budget / 2)); else maxchars=$budget; fi
      # 绝不给标签设"最小宽度"下限：那会顶掉宽度预算（曾写 `[ budget -lt 6 ] && budget=6`），
      # 20 列终端 + 6 位时钟就直接超宽折行刷屏。预算不够时让标签退化成空，固定部分优先。
      if [ "$maxchars" -lt 1 ]; then label=""
      elif [ "${#label}" -gt "$maxchars" ]; then label="${label:0:$((maxchars - 1))}…"
      fi
      printf '\r\033[K%s[%s]%s %s %s· %s%s' \
        "$C_CYAN" "${chars[$((i % 10))]}" "$C_RST" \
        "$label" "$C_DIM" "$stamp" "$C_RST"
      i=$((i + 1))
      sleep 0.15
    done
  ) &
  STATUS_PID=$!
}
# 停掉 ticker 并擦掉状态行；幂等（正常结束与 on_exit 都会调用）。
status_stop() {
  [ "$STATUS_ON" -eq 1 ] || return 0
  STATUS_ON=0
  SP_CLEAR=""
  if [ -n "$STATUS_PID" ]; then
    kill "$STATUS_PID" 2>/dev/null || true
    wait "$STATUS_PID" 2>/dev/null || true
    STATUS_PID=""
  fi
  printf '\r\033[K'
}
# 长命令：TTY 下只把状态行文案换成 $label（动画仍归 ticker）；非 TTY 打印一行静态提示；
# --verbose 则原样透传命令输出。
run_hidden_spinner() {
  local label="$1" rc=0
  shift
  if [ "$STATUS_TTY" -eq 1 ]; then
    STATUS_OVERRIDE="$label"
    status_render
    run_hidden "$@" || rc=$?
    STATUS_OVERRIDE=""
    status_render
    return "$rc"
  fi
  if [ "$VERBOSE" -eq 0 ]; then
    # 各调用点的标签已自带省略号（结尾的 "..."），这里原样打印即可，别再加一个变成 "......"
    printf '%s\n' "$label"
  fi
  run_hidden "$@"
}

# 包装脚本临时文件：交给 on_exit 统一清理，这里不再注册 EXIT trap（会覆盖 on_exit、吞掉失败日志）。
DSH_TMP=""
# 安装前被临时移开的 dsh 包装脚本（npm 重建 bin link 时不能与它共存，见 3/8）：
# 安装/重建成功后在 6/8 删除；安装失败则由 on_exit 还原，避免 dsh 命令缺失。
DSH_CMD_PREINSTALL_BAK=""
# 全脚本唯一的 EXIT trap：擦状态行 → 清理临时文件 → 失败时打印日志尾部。
# ⚠️ 必须写 tail -25 "$SETUP_LOG" >&2：重定向从左到右生效，2>/dev/null >&2 会把日志整个吞掉。
on_exit() {
  local rc=$?
  status_stop                 # 先擦掉常驻状态行，否则失败日志会叠在它上面
  if [ -n "$STATUS_FILE" ]; then rm -f "$STATUS_FILE" 2>/dev/null || true; fi
  if [ -n "$DSH_TMP" ]; then rm -f "$DSH_TMP" 2>/dev/null || true; fi
  if [ -n "${DSH_CMD_PREINSTALL_BAK:-}" ]; then
    # 6/8 重建成功时会删除备份并清空变量；走到这里说明安装/重建没有完成 →
    # 把安装前移开的旧包装原子还原（即使 npm 已经建了一个 bin link，也以旧包装为准；
    # 它指向同一个 $DSH_DIR/lib/bin.js，只是多带 --expose-internals）。
    if ! mv -f "$DSH_CMD_PREINSTALL_BAK" "${DSH_CMD:-}" 2>/dev/null; then
      rm -f "$DSH_CMD_PREINSTALL_BAK" 2>/dev/null || true
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    printf '\n%s[x]%s 安装失败（退出码 %s）。最近日志：\n' "$C_RED" "$C_RST" "$rc" >&2
    if [ -s "$SETUP_LOG" ]; then tail -25 "$SETUP_LOG" >&2; fi
  fi
}
trap on_exit EXIT
status_start   # 状态指示器从这里开始，一直显示到脚本结束（见末尾 status_stop）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # 脚本真实目录（脚本中段会 cd，须用绝对路径）
# 默认跟随 npm 的 latest；仅在灰度/回退时用 DSH_VERSION=<ver> 钉版本（<ver> 从 npm 取）。
# ⚠️ 不要在这里写死版本号：写死等于每次升级都得改脚本，也违背「默认跟随 latest」的语义。
if [ -n "${DSH_VERSION:-}" ]; then
  DSH_NPM="@deepseek-ai/dsh@${DSH_VERSION}"
else
  DSH_NPM="@deepseek-ai/dsh"
fi
DSH_DIR="/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh"
INSTALL_DIR="$HOME/dsh"
# 安装布局：dsh 直接安装在 npm 默认全局目录（$PREFIX/lib/node_modules/@deepseek-ai/dsh），
# 是真实目录、不是 symlink。升级 dsh 只能重新运行 setup.sh：`npm -g update` 会绕过这里的
# Android 编译参数与安装后补丁，把 dsh 覆盖成未修补的上游版本（补丁与包装脚本随之丢失）。

# ⚠️ npm 包装（Termux 必踩）：`/usr/bin` 在 Termux 的挂载命名空间里不可解析，而
# npm-cli.js 的 shebang 写死 `#!/usr/bin/env node`，于是直接执行 `npm` 会报
#   bad interpreter: /usr/bin/env: no such file or directory
# （`/usr/bin/env` 不存在；Termux 的 env 在 $PREFIX/bin/env）。实测本机必现，
# 会让第 3 步装 dsh 与第 5 步装 sharp-wasm32 **双双失败**。
# 统一改成 `node <npm-cli.js> …`；若将来 shebang 正常或 npm 不存在则自动回退裸 npm。
NPM_CMD=(npm)
if NPM_BIN="$(command -v npm 2>/dev/null)"; then
  NPM_REAL="$(readlink -f "$NPM_BIN" 2>/dev/null || printf '%s' "$NPM_BIN")"
  case "$NPM_REAL" in
    *.js) NPM_CMD=(node "$NPM_REAL") ;;
  esac
fi
# ⚠️ 一律用真实绝对路径 /data/data/com.termux/files/usr/bin：/usr 在部分命名空间不可解析（实测 No such file or directory）。
PREFIX_BIN="/data/data/com.termux/files/usr/bin"
# 仅测试夹具用：DSH_SETUP_PREFIX 把生产路径整体换到临时目录（夹具里端到端测冲突预检/只预检）。
# 生产不要设置——设置了本脚本就只操作这个临时前缀，绝不碰真实安装树。
if [ -n "${DSH_SETUP_PREFIX:-}" ]; then
  PREFIX_BIN="$DSH_SETUP_PREFIX/bin"
  DSH_DIR="$DSH_SETUP_PREFIX/lib/node_modules/@deepseek-ai/dsh"
fi
DSH_CMD="$PREFIX_BIN/dsh"

# ---------------------------------------- dsh 安装布局（原生 npm 全局目录）
# 3/8 直接 `npm install -g` 到 $DSH_DIR（真实目录）。旧版 setup.sh 留下的 hold symlink
# 会在安装前摘除；安装前还会临时移开 dsh 包装脚本（npm 重建 bin link 时会 EEXIST）。

# 0 锚点预检：升级重跑时先只读检查各补丁锚点是否还在，非致命。
anchor_precheck() {
  [ -d "$DSH_DIR/node_modules/@deepseek-ai" ] || return 0
  step "0/8 锚点预检"
  local missing=0 path spec
  for spec in \
    'dsh-session-persistence-jsonl/lib/index.js|async function publishNoReplaceNoHardlink(|dsh-session-persistence 无硬链接迁移回退' \
    'dsh-attachment-local/lib/index.js|async function publishNoReplaceNoHardlink(|dsh-attachment-local 无硬链接发布回退' \
    'dsh-fs-local/lib/index.js|async function publishNoReplaceNoHardlink(|dsh-fs-local 无硬链接发布回退' \
    'node-addon-system/lib/flock.js|dsh-android-flock|dsh-android-flock Android flock 绑定' \
    'dsh-subprocess-local/lib/runner-launch-*.js|platform === "android"|dsh-subprocess-local android 终端检测'; do
    path="${spec%%|*}"; rest="${spec#*|}"; marker="${rest%%|*}"; label="${rest#*|}"
# path 支持通配，marker 内不可含 "|"（会与分隔符冲突）。
    local hit=0 g
# $DSH_DIR 加引号，$path 故意不加引号以便通配展开。
    for g in "$DSH_DIR/node_modules/@deepseek-ai/"$path; do
      if [ -f "$g" ] && grep -qF "$marker" "$g" 2>/dev/null; then hit=1; fi
    done
    if [ "$hit" -eq 1 ]; then
      ok "  $label"
    else
      warn "  $label：未检测到锚点（$marker）——补丁可能需要重锚，或上游已原生实现。"
      missing=$((missing+1))
    fi
  done
  # 停止梯子依赖上游「重复信号立即强退」语义（profile-boot 的 createProcessShutdown.interrupt → forceExitOnce）。
  # 该文件是内容哈希名（lib/profile-boot-<hash>.js），升级即改名，故按通配探测；漂移只告警——
  # 后果是 stop_dsh.sh 退化为「等满 DSH_STOP_TIMEOUT 再 SIGKILL」，停止变慢但不会失败。
  local pb_hit=0 pg
  for pg in "$DSH_DIR"/lib/profile-boot-*.js; do
    [ -f "$pg" ] || continue
    if grep -qF "createProcessShutdown" "$pg" 2>/dev/null \
       && grep -qF "forceExitOnce" "$pg" 2>/dev/null \
       && grep -qF "interrupt(code)" "$pg" 2>/dev/null; then pb_hit=1; fi
  done
  if [ "$pb_hit" -eq 1 ]; then
    ok "  profile-boot 双信号强退语义（停止梯子前提）"
  else
    warn "  profile-boot：未检测到 interrupt/forceExitOnce，停止将退化为等满超时后 SIGKILL。"
  fi
  # ripgrep 回退锚点：resolveRgPath() 的宿主随上游重构搬过家，两代落点都认（不按版本号分支）——
  # 0.2.2-rc.1：定义在 dsh-tool-fs-search/lib/index.js；
  # 0.2.2-rc.3+ 拆进新包 dsh-util-ripgrep/lib/index.js（tool-fs-search 只 import 并再导出）。
  local rg_hit=0 rgf
  for rgf in "$DSH_DIR/node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js" \
             "$DSH_DIR/node_modules/@deepseek-ai/dsh-util-ripgrep/lib/index.js"; do
    [ -f "$rgf" ] || continue
    if grep -qF "resolveSystemRg" "$rgf" 2>/dev/null; then rg_hit=1; fi
  done
  if [ "$rg_hit" -eq 1 ]; then
    ok "  ripgrep resolveRgPath 回退（dsh-tool-fs-search / dsh-util-ripgrep）"
  else
    warn "  ripgrep：未检测到 resolveRgPath 回退（两代宿主都没有 resolveSystemRg）。"
    missing=$((missing+1))
  fi
  # 0.1.7 新增的原生 addon 家族：node-addon-require-builtin 靠平台可选包
  # node-addon-require-builtin-<platform>-<arch> 提供绑定，上游没有 android 版。缺它时
  # dsh-app-boot 的 internalModules() 会抛 "No usable native binding found"，
  # host preparation 失败、**dsh 完全起不来**。该包不在 @deepseek-ai/ 命名空间下，故单独探测。
  # ⚠️ 平台包名后缀随架构变（android-arm64 / android-arm…），用通配探测、别写死后缀——
  # 写死会让 armv7 上的一次健康安装被预检误报成「dsh 将无法启动」。
  local rb_hit=0 rbg
  for rbg in "$DSH_DIR"/node_modules/node-addon-require-builtin-android-*/index.js; do
    if [ -f "$rbg" ] && grep -qF "dsh-android-require-builtin" "$rbg" 2>/dev/null; then rb_hit=1; fi
  done
  if [ "$rb_hit" -eq 1 ]; then
    ok "  node-addon-require-builtin android 平台包（dsh 启动前提）"
  else
    warn "  node-addon-require-builtin：android 平台包缺失，dsh 将无法启动（No usable native binding found）。"
  fi
  [ "$missing" -eq 0 ] && ok "  锚点全部就位（5 条规格 + 3 项特殊探测）" || true
}
anchor_precheck

# ---------------------------------------------------------------- 1/8 依赖
step "1/8 安装构建依赖"
run_hidden pkg update -y || true
run_hidden pkg install -y cmake clang make binutils pkg-config python nodejs ripgrep

command -v node >/dev/null 2>&1 || { warn "未检测到 node，正在重新安装 nodejs……"; run_hidden pkg install -y nodejs; }
NODE_VER="$(node -v | sed 's/^v//')"
info "  Node.js v${NODE_VER}"

# 检测默认 npm / nodejs.org 太慢就切 npmmirror，仅本次会话生效，不改全局配置。
is_slow() {
  local url="$1" t
  t=$(curl -o /dev/null -s -w '%{time_total}' --max-time 6 "$url" 2>/dev/null)
  [ -z "$t" ] && return 0
  awk -v t="$t" 'BEGIN { exit !(t > 1.0) }'
}
if is_slow "https://registry.npmjs.org/-/ping"; then
  info "  默认 npm 源较慢，本次运行改用 npmmirror 镜像（registry.npmmirror.com）。"
  export npm_config_registry="https://registry.npmmirror.com"
fi
if is_slow "https://nodejs.org/dist/"; then
  info "  nodejs.org 较慢，Node headers 下载改用 npmmirror 镜像。"
  export npm_config_disturl="https://npmmirror.com/mirrors/node/"
fi

# ------------------------------------------------------- 2/8 准备 gyp 补丁
step "2/8 准备 Node headers"
# node-gyp 的 common.gypi 历史上引用 android_ndk_path，Termux 无 NDK 必须补空定义，否则 node-pty 构建失败。
# 但 node-gyp 未显式给 --nodedir 时会直接用 process.config.variables.node_prefix（= $PREFIX）下的
# 自带 headers；Termux 的 nodejs 包带 $PREFIX/include/node，Node 26 的 common.gypi 也已不再引用
# android_ndk_path → 有自带 headers 时无需下载缓存（也避开 npmmirror 缺 SHASUMS256.txt 的失败）。
# ⚠️ 本段提示文本里绝不能用反引号包命令：旧版写 ... `npm i -g @deepseek-ai/dsh` ...，
#    bash 会把它当命令替换**真的执行**，安装中途偷偷重装一次未打补丁的 dsh（实测 2/8 直接报 EEXIST）。
SYS_GIPI="${PREFIX:-/data/data/com.termux/files/usr}/include/node/common.gypi"
GYP_GIPI="$HOME/.cache/node-gyp/$NODE_VER/include/node/common.gypi"

# 幂等补齐 android_ndk_path 空定义；$1 = common.gypi 路径。
patch_common_gypi() {
  info "  common.gypi：补充 android_ndk_path 空定义（Termux 无 NDK）"
  # python 自己往终端打印，擦行字节必须由它一并写出（SP_CLEAR 已 export）：python3 启动约 40ms，
  # ticker 每 0.15s 重画一次，"先 status_clear 再 python 打印"会有约 1/4 概率把正文叠到状态行上。
  python3 - "$1" <<'PY'
import os, sys
CLR = os.environ.get("SP_CLEAR", "")
ECLR = CLR if sys.stderr.isatty() else ""   # stderr 被重定向时不往里写光标控制码
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
ANCHOR = "'variables': {"
if "'android_ndk_path%': ''" in s:
    print(CLR + "  [skip] common.gypi 已修补")
elif ANCHOR not in s:
    print(ECLR + "  [warn] common.gypi 未检测到锚点 %s，已跳过（node-pty 可能构建失败）。" % ANCHOR, file=sys.stderr)
else:
    open(p, 'w', encoding='utf-8').write(s.replace(ANCHOR, "'variables': {\n    'android_ndk_path%': '',", 1))
    print(CLR + "  patched common.gypi")
PY
}

if [ -f "$SYS_GIPI" ]; then
  info "  使用 Termux 自带 Node headers：$SYS_GIPI"
  if grep -q 'android_ndk_path' "$SYS_GIPI" 2>/dev/null && ! grep -q "'android_ndk_path%': ''" "$SYS_GIPI" 2>/dev/null; then
    patch_common_gypi "$SYS_GIPI"
  fi
else
  run_hidden_spinner "  正在下载 Node headers（约 1 分钟）……" timeout 300 npx --yes node-gyp install || true
  if [ -f "$GYP_GIPI" ]; then
    patch_common_gypi "$GYP_GIPI"
  else
    warn "  Node headers 不在 Termux 自带目录（$SYS_GIPI），也没下载到 node-gyp 缓存（$GYP_GIPI）。"
    warn "      下载失败常见原因是镜像缺 SHASUMS256.txt；可手动重试：npx --yes node-gyp install --dist-url=https://nodejs.org/download/release"
    warn "      node-pty 若因此构建失败，3/8 校验产物时会中断并提示，不会静默装出一个不能用的 dsh。"
  fi
fi

# ------------------------------------------------------------- 3/8 正式安装
step "3/8 安装 dsh"
# android30 仅是安全 no-op；绝不可加 --sysroot=$PREFIX 或切 -target aarch64-linux-gnu 上 glibc（会头/库/ABI 混用）。
# 真正需要编译的只有 node-pty（无 android-arm64 预编译），koffi 3.x 走预编译包。
# ⚠️ 手动 `npm -g update` 不经过本脚本，会丢掉这里的 CFLAGS/CXXFLAGS 且覆盖全部安装期补丁；
# dsh 升级只支持 `bash setup.sh`，不要用 npm -g update。
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
EXTRA_FLAGS="-target aarch64-linux-android30 -I$PREFIX/include"
# --allow-scripts 的语义**随 npm 版本不同**（下一行会探测并打印当前策略）：
#   npm 12：白名单内的包脚本【失败】→ 整次 npm install 退 1；白名单外 → 只警告并跳过（白名单是强制的）。
#   npm 11（本机 11.21.1）：白名单是【建议性】的——白名单外的脚本**仍会执行**、只打警告；
#     只有 `strict-allow-scripts=true` 才硬失败（ESTRICTALLOWSCRIPTS，会按安装冲突在预检里拒绝）。
#     本机实测：koffi 3.1.1 的 install 脚本因此真的执行并编译成功、可加载（koffi.load('libc.so') OK）。
# 所以 ALLOW_SCRIPTS 是「可用性风险面 + 完整性清单」：上游新增带构建脚本的包必须同步补进来，
# 否则 npm 12 下原生产物静默缺失、npm 11 下则会有未审批脚本被静默执行——下方的自检负责发现。
# ⚠️ SKIP_SCRIPTS 仍然保留：npm 12 下把 koffi 放进白名单会拖死整次安装；本机 npm 11 虽能编译，
#    但运行期 koffi 只在 win32 分支懒加载，Android 用不到。
# dsh 直接安装到 npm 默认全局目录（原生布局，真实目录）：安装期补丁直接改这棵树，升级只能重跑本脚本。
# 若用户另设了 `ignore-scripts=true`，这里仍显式 `--ignore-scripts=false` 以完成 node-pty 构建。
ALLOW_SCRIPTS="@deepseek-ai/dsh-subprocess-local,node-pty,@google/genai,protobufjs"
# 按设计不进白名单的包（脚本必然失败或纯属多余，宁可让它退化成「npm 警告 + 跳过」）：
#   koffi —— 0.2.0-rc.2 起上游把它【精确钉在 3.1.1】，而 @koromix/koffi-android-arm64 从 3.2.1 才有；
#   3.1.1 的 install 脚本 `cnoke --prebuild` 自愈式回退到本地编译，必死在 bionic 与 glibc 的
#   statx 原型差异上（lib/native/base/base.cc）。实测 `npm install -g --allow-scripts=koffi koffi@3.1.1`
#   退出码 1 —— 白名单里留着它 = 安装必然中断。运行期它只在 win32 分支懒加载，Android 用不到。
SKIP_SCRIPTS="koffi"

# npm allow-scripts 策略探测：npm 11 默认 advisory（白名单建议性、白名单外脚本仍执行、只警告），
# npm 12 起白名单强制。用户显式 strict-allow-scripts=true 会让 SKIP_SCRIPTS 里的 koffi 变成硬错误、
# 整次安装中断，因此在这里当安装冲突直接拒绝（与旧版预检语义一致）。
NPM_STRICT_ALLOW_SCRIPTS="$("${NPM_CMD[@]}" config get strict-allow-scripts 2>/dev/null | tail -1 || true)"
if [ "$NPM_STRICT_ALLOW_SCRIPTS" = "true" ]; then
  error "  npm 配置 strict-allow-scripts=true 会让安装脚本白名单外的包直接失败（koffi 必然中断整次安装）。"
  error "  处置：npm config set strict-allow-scripts false --location=user 后重新运行。"
  exit 1
fi
case "${NPM_STRICT_ALLOW_SCRIPTS:-unknown}" in
  false) info "  npm allow-scripts 策略：advisory（白名单为建议性，白名单外脚本仍会执行）。" ;;
  *)     info "  npm allow-scripts 策略：${NPM_STRICT_ALLOW_SCRIPTS:-未探测到}（按 npm 默认处理）。" ;;
esac
info "  包：${DSH_NPM}"
info "  脚本白名单：${ALLOW_SCRIPTS}"

# npm 重建 bin link 时会与 setup.sh 自己写的 dsh 包装脚本冲突（EEXIST，实测 npm 12 即如此，
# `--no-bin-links` 也挡不住旧链清理）。安装前把旧包装脚本原子移开：失败由 on_exit 还原，
# 成功由 6/8 重建。绝不能先 rm（会制造 dsh 命令缺失窗口）。
# 放在摘除旧 symlink 之前：包装移开失败时旧布局仍完整可用。
if [ -e "$DSH_CMD" ] || [ -L "$DSH_CMD" ]; then
  DSH_CMD_PREINSTALL_BAK="$PREFIX_BIN/.dsh.preinstall.$$"
  if ! mv -f "$DSH_CMD" "$DSH_CMD_PREINSTALL_BAK"; then
    DSH_CMD_PREINSTALL_BAK=""
    error "  无法移开旧 dsh 包装脚本：$DSH_CMD"
    exit 1
  fi
fi

# 旧版 setup.sh 的 hold 布局迁移：历史上 dsh 被移到 ~/.local/share/dsh-android/dsh，
# 全局 $DSH_DIR 只是一个 symlink。原生布局必须是真实目录 → 安装前摘除这个 symlink。
# 只删链接本身，旧安装树不动；6/8 验证新 dsh 可用后会提示如何清理旧树（其中可能还有进程在跑）。
LEGACY_HOLD_DIR=""
if [ -L "$DSH_DIR" ]; then
  LEGACY_HOLD_DIR="$(readlink -f "$DSH_DIR" 2>/dev/null || true)"
  info "  检测到旧版 hold symlink：$DSH_DIR -> ${LEGACY_HOLD_DIR:-?}，改为原生全局安装"
  rm -f "$DSH_DIR" || { error "  无法摘除旧 hold symlink：$DSH_DIR"; exit 1; }
fi

# DSH_SETUP_PREFIX 是测试夹具钩子：此时把 npm 的全局前缀也指到临时目录，保持隔离。
NPM_INSTALL_PREFIX_ARGS=()
if [ -n "${DSH_SETUP_PREFIX:-}" ]; then
  NPM_INSTALL_PREFIX_ARGS=(--prefix "$DSH_SETUP_PREFIX")
fi
info "  目录：$DSH_DIR（npm 全局真实目录）"
run_hidden_spinner "  正在安装 dsh 并编译原生模块（预计耗时 5～15 分钟）……" \
  env CFLAGS="$EXTRA_FLAGS" CXXFLAGS="$EXTRA_FLAGS" \
  "${NPM_CMD[@]}" install -g --no-audit --no-fund --loglevel=error "${NPM_INSTALL_PREFIX_ARGS[@]}" \
  --ignore-scripts=false --allow-scripts="$ALLOW_SCRIPTS" "$DSH_NPM"

if [ ! -d "$DSH_DIR" ]; then
  error "  安装完成但未找到 dsh 安装树：$DSH_DIR"
  exit 1
fi
if [ -L "$DSH_DIR" ]; then
  error "  安装后全局 dsh 仍是符号链接（旧 hold 布局未摘除？）：$DSH_DIR -> $(readlink "$DSH_DIR" 2>/dev/null || echo '?')"
  exit 1
fi

if [ -f "$DSH_DIR/node_modules/node-pty/build/Release/pty.node" ]; then
  ok "  node-pty 编译产物已就绪（build/Release/pty.node）"
else
  warn "  node-pty 原生产物缺失：node-gyp 编译失败（PTY 功能将不可用）。"
  warn "      请检查上方 node-pty 编译日志（常见原因：gyp 缓存未修补，或缺少 cmake、clang）；建议修复后重新运行本脚本。"
  exit 1
fi
if (cd "$DSH_DIR" && node -e "require('node-pty');" >/dev/null 2>&1); then
  ok "  node-pty 模块可正常加载"
else
  warn "  node-pty 产物无法加载（疑似 ABI 不匹配），PTY 功能将不可用。"
fi
# koffi 是否「按设计跳过」：bash 原生模式匹配，不起子进程。
case ",$SKIP_SCRIPTS," in *,koffi,*) KOFFI_SKIPPED=1 ;; *) KOFFI_SKIPPED=0 ;; esac
if (cd "$DSH_DIR/node_modules/koffi" && node -e "try{require('koffi');}catch(e){process.exit(1)}" >/dev/null 2>&1); then
  ok "  koffi 预编译包可正常加载"
elif [ "$KOFFI_SKIPPED" -eq 1 ]; then
  # 预期内：不进白名单 → 装脚本被 npm 跳过 → 没有原生模块。只报一行，不当告警喊。
  info "  koffi 原生模块不可用（按设计跳过）：3.1.1 无 android 预编译包，且只在 win32 分支懒加载。"
else
  warn "  koffi 原生模块不可用（不阻断）：3.1.1 无 android 预编译包、install 脚本在 bionic 上必然失败，所以列入 SKIP_SCRIPTS；"
  warn "  放进白名单会让整次安装退 1。dsh 只在 win32 分支懒加载它，Android 运行期不涉及。"
fi

# 安装脚本白名单自检：npm 12 只对 --allow-scripts 内的包跑 install/postinstall，其余静默跳过。
# 上游依赖重组后（0.1.7 新增/改名了一批包）若冒出新的带脚本包，必须在这里被点出来，否则原生产物静默缺失。
if node - "$DSH_DIR/node_modules" "$ALLOW_SCRIPTS" "$SKIP_SCRIPTS" <<'JS'
import fs from "node:fs";
import path from "node:path";
const [root, allowStr, skipStr] = process.argv.slice(2);
const CLR = process.env.SP_CLEAR ?? "";
const allow = new Set(allowStr.split(",").map((s) => s.trim()).filter(Boolean));
const skip = new Set((skipStr ?? "").split(",").map((s) => s.trim()).filter(Boolean));
const found = new Map();
const consider = (dir) => {
  let pkg;
  try { pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")); } catch { return; }
  const hooks = ["preinstall", "install", "postinstall"].filter((h) => typeof pkg.scripts?.[h] === "string");
  if (hooks.length === 0) return;
  const name = pkg.name ?? path.basename(dir);
  if (!found.has(name)) found.set(name, hooks.join("/"));
};
const walk = (dir) => {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    if (!e.isDirectory()) continue;
    if (e.name.startsWith("@")) { walk(path.join(dir, e.name)); continue; }
    consider(path.join(dir, e.name));
  }
};
walk(root);
const lines = [];
for (const [n, h] of found) lines.push(`    ${allow.has(n) ? "[allowed]  " : skip.has(n) ? "[skipped]  " : "[UNCOVERED]"} ${n} (${h})`);
const uncovered = [...found.keys()].filter((n) => !allow.has(n) && !skip.has(n));
const skipped = [...found.keys()].filter((n) => skip.has(n));
if (skipped.length > 0) lines.push(`    [note] ${skipped.length} 个带脚本的包按设计未列入白名单（${skipped.join(", ")}）：npm 仅警告并跳过，详见 setup.sh 的 SKIP_SCRIPTS。`);
if (uncovered.length > 0) {
  lines.push(`    [warn] ${uncovered.length} 个带安装脚本的包未列入白名单，其构建步骤已被 npm 跳过。`);
  console.log(CLR + lines.join("\n"));
  process.exit(3);
}
lines.push(`    [ok] ${found.size - skipped.length} 个带安装脚本的包均在白名单内${skipped.length ? `（另有 ${skipped.length} 个按设计跳过）` : ""}。`);
console.log(CLR + lines.join("\n"));
JS
then
  ok "  安装脚本白名单覆盖完整。"
else
  rc=$?
  if [ "$rc" -eq 3 ]; then
    warn "  有带安装脚本的包未列入 --allow-scripts 白名单（见上表）：其构建步骤被跳过，原生产物可能缺失。"
    warn "      处置：请将该包名加入本脚本的 ALLOW_SCRIPTS 后重新运行；若确认其构建在 Android 上必然失败（或运行期不涉及），"
    warn "      应改列入 SKIP_SCRIPTS（npm 仅警告、不中断），请勿放入 ALLOW_SCRIPTS；白名单内脚本失败将导致整次安装返回 1。"
  else
    warn "  安装脚本白名单自检执行异常（退出码 $rc）。"
  fi
fi

# ------------------------------------------------------- 4/8 后端兼容补丁
step "4/8 后端兼容补丁"

# 4-boot: 补 node-addon-require-builtin 的 android 平台包（dsh ≥0.1.7 启动前提）。
#     dsh-app-boot 的 internalModules() 无条件 require 该绑定，而上游只发布
#     darwin/linux-gnu/win32-msvc 预编译包，Termux 上解析不到 →
#     "No usable native binding found" → host preparation 失败、dsh 完全起不来。
#     按 loader 的「平台可选包」约定补一个纯 JS 实现（dsh 包装脚本必带
#     --expose-internals，require("internal/*") 直接可用，免 NDK 交叉编译）。
#     失败必须 exit 1（不能只 warn）：没有它 dsh 根本起不来，
#     与 4d 的 rg 同属「硬阻断」补丁（rc.1 / rc.3 都必需）。
RBFIX="$SCRIPT_DIR/patches/patch-dsh-android-require-builtin.js"
if [ -f "$RBFIX" ]; then
  if run_hidden node --expose-internals "$RBFIX" --root "$DSH_DIR"; then
    ok "  android require-builtin 平台包已就绪（dsh 启动前提）"
  else
    error "  require-builtin 平台包补丁失败，dsh 将无法启动（No usable native binding found）。"
    exit 1
  fi
else
  error "  缺少 patches/patch-dsh-android-require-builtin.js，dsh 将无法启动。"
  exit 1
fi

# 4a 禁硬链接全链路修复（会话/附件发布、迁移、write 新建文件）；详见 patches/patch-dsh-android-link.js。
HLFIX="$SCRIPT_DIR/patches/patch-dsh-android-link.js"
if [ -f "$HLFIX" ]; then
  if run_hidden node "$HLFIX" --root "$DSH_DIR/node_modules/@deepseek-ai"; then
    ok "  android 硬链接修复完成（session / attachment / fs-local）"
  else
    warn "  硬链接修复脚本报告异常（可能原因：dsh 版本漂移，或目标文件为「仅含回退调用注释」的半成品）。请人工核查，详见 $SETUP_LOG。"
  fi
else
  warn "  缺少 patches/patch-dsh-android-link.js，已跳过硬链接修复。"
fi

# 4a-verify 必须等 sharp WASM 回退（step 5）之后再跑，否则附件测试 import sharp 失败会误报验证未通过。

# 4b flock 原生绑定：node-addon-system 无 Android 预编译包，用 clang 编译其 src/flock.c 成本机 system.node 供 lib/flock.js 加载。
FLOCKFIX="$SCRIPT_DIR/patches/patch-dsh-android-flock.js"
if [ -f "$FLOCKFIX" ]; then
  if run_hidden node "$FLOCKFIX" --root "$DSH_DIR/node_modules/@deepseek-ai"; then
    ok "  android flock 原生绑定完成（会话写锁可用）"
  else
    warn "  flock 修复脚本报告异常（发消息将失败，请人工核查；可能 system.node 已写出但 flock.js 未改写，详见 $SETUP_LOG）。"
  fi
else
  warn "  缺少 patches/patch-dsh-android-flock.js，已跳过 flock 修复。"
fi

# 4c subprocess 终端检测 android 视同 linux：锚点可能内联在内容哈希 bundle 里（lib/runner-launch-*.js），
#     故按通配扫描 whole lib 目录，命中才报成功、未命中明确告警。
SP_LIB="$DSH_DIR/node_modules/@deepseek-ai/dsh-subprocess-local/lib"
if python3 - "$SP_LIB" <<'PY'
import glob, os, sys
CLR = os.environ.get("SP_CLEAR", "")
ECLR = CLR if sys.stderr.isatty() else ""
lib = sys.argv[1]
anchor = 'if (platform === "linux") return new LinuxProcessInspector(arch, internals);'
patched = 'if (platform === "linux" || platform === "android") return new LinuxProcessInspector(arch, internals);'
files = sorted(glob.glob(os.path.join(lib, "*.js")))
if any(patched in open(f, encoding="utf-8").read() for f in files):
    print(CLR + "  [skip] subprocess 终端检测已是 android≡linux")
    sys.exit(0)
hits = 0
for f in files:
    s = open(f, encoding="utf-8").read()
    if anchor in s:
        open(f, "w", encoding="utf-8").write(s.replace(anchor, patched))
        print(CLR + "  patched %s (android→linux)" % os.path.basename(f))
        hits += 1
if hits == 0:
    print(ECLR + "  [warn] 未检测到 subprocess 终端检测锚点（dsh 版本漂移），终端功能可能不可用。", file=sys.stderr)
    sys.exit(3)
PY
then
  ok "  subprocess-local 终端检测 android 视同 linux"
else
  rc=$?
  if [ "$rc" -eq 3 ]; then
    warn "  subprocess-local 终端检测补丁未命中锚点（dsh 版本漂移），终端功能可能不可用；请人工核查 $SP_LIB。"
  else
    warn "  subprocess-local 补丁执行异常（退出码 $rc）。"
  fi
fi

# 4d ripgrep 修复：npm install 会清空 node_modules，每次更新后都必须重跑（脚本幂等）。
# ⚠️ apply-rg-fix.sh 内部已把「锚点漂移」降级为非致命（软链本身即可让 @vscode/ripgrep 解析成功），
#    所以它非 0 退出只代表 resolveRgPath() 真解析不通（grep/glob 全废），此时必须中断。
RG_FIX="$SCRIPT_DIR/apply-rg-fix.sh"
if [ -f "$RG_FIX" ]; then
  if run_hidden env DSH_ROOT="$DSH_DIR" bash "$RG_FIX"; then
    ok "  grep/glob ripgrep 修复完成（系统 rg 软链 + resolveRgPath 回退）"
  else
    error "  ripgrep 修复失败：resolveRgPath() 实际解析不通过，grep/glob 将不可用（详见 $SETUP_LOG）。"
    exit 1
  fi
else
  warn "  缺少 apply-rg-fix.sh，已跳过 grep/glob ripgrep 修复。"
fi

# ------------------------------------------------------ 5/8 sharp wasm 回退
step "5/8 sharp WASM 回退"
SHARP_VER="$(node -e "console.log(require('$DSH_DIR/node_modules/sharp/package.json').version)" 2>/dev/null || true)"
WASM_VER="$(node -e "console.log(require('$DSH_DIR/node_modules/@img/sharp-wasm32/package.json').version)" 2>/dev/null || true)"
# 只看"目录在不在"会在 sharp 升级后残留旧 wasm 时报假成功（目录在、版本对不上、加载仍然失败）。
# 因此必须比对 wasm 自己的版本与当前 sharp 版本，一致才算就位。
if [ -n "$WASM_VER" ] && [ "$WASM_VER" = "$SHARP_VER" ]; then
  ok "  sharp-wasm32 已就绪（v$WASM_VER）"
elif [ -z "$SHARP_VER" ]; then
  # 读不到 sharp 版本就不能猜：装错版本的 wasm 比不装更糟（ABI/协议不匹配）。
  warn "  无法确定 sharp 版本（可能未安装 sharp），已跳过 sharp-wasm32 回退。"
else
  if [ -n "$WASM_VER" ]; then
    warn "  sharp-wasm32 版本不匹配（wasm $WASM_VER ≠ sharp $SHARP_VER），将重新安装。"
  fi
  # 在临时目录里装 wasm 包，再拷进 dsh 的 node_modules。npm 输出写入 setup.log：
  # 早先把输出丢进 /dev/null，装失败时 set -e 只会抛一句无线索的"安装失败"，日志尾部也是空的。
  SWTMP="$(mktemp -d)"
  if ! ( cd "$SWTMP" && "${NPM_CMD[@]}" init -y >/dev/null 2>&1 && "${NPM_CMD[@]}" install "@img/sharp-wasm32@$SHARP_VER" ) >>"$SETUP_LOG" 2>&1; then
    rm -rf "$SWTMP"
    error "  sharp-wasm32@${SHARP_VER} 安装失败（原因见 $SETUP_LOG）：sharp 无 Android 原生包，缺少 wasm 将导致附件模块加载失败。"
    exit 1
  fi
  mkdir -p "$DSH_DIR/node_modules/@img"
  # 先删旧目录再拷：目标已存在时 `cp -r src dst/` 是把内容【合并】进旧目录，
  # 旧版本的残留文件会留下来（版本混装），所以必须先清掉。
  rm -rf "$DSH_DIR/node_modules/@img/sharp-wasm32"
  cp -r "$SWTMP/node_modules/@img/sharp-wasm32" "$DSH_DIR/node_modules/@img/"
  # @emnapi/runtime 是 sharp-wasm32 的运行时依赖，缺它 wasm 加载即失败——这里的错误不能吞。
  cp -r "$SWTMP/node_modules/@emnapi" "$DSH_DIR/node_modules/"
  rm -rf "$SWTMP"
  ok "  sharp-wasm32@${SHARP_VER} 已安装"
fi

# 4a-verify 快速验证 link→rename / no-replace 回退：只做静态检查 + 临时目录写入，不碰 ~/.dsh/sessions。
HFIX_VERIFY="$SCRIPT_DIR/patches/verify-android-link-fix.js"
if [ -f "$HFIX_VERIFY" ]; then
  if run_hidden node "$HFIX_VERIFY" --root "$DSH_DIR/node_modules/@deepseek-ai"; then
    ok "  android 硬链接修复验证通过（会话/附件/fs-local）"
  else
    warn "  android 硬链接修复验证未通过，请人工核查对应补丁。"
  fi
else
  warn "  缺少 patches/verify-android-link-fix.js，已跳过硬链接修复验证。"
fi

# ------------------------------------------------------ 6/8 dsh 包装脚本
step "6/8 dsh 包装脚本"
# 6/8 重建 dsh 包装脚本（npm 会把 dsh 覆盖成指向 lib/bin.js 的符号链接，缺 --expose-internals）。
# 用 mv -f 原子替换目录项本身，绝不 follow 链接目标、绝不先 rm；备份只备符号链接本身。
DSH_BIN="$DSH_DIR/lib/bin.js"
NODE_BIN="$PREFIX_BIN/node"
if [ ! -x "$NODE_BIN" ] || [ ! -f "$DSH_BIN" ]; then
  warn "  未检测到 node（$NODE_BIN）或 dsh bin.js（$DSH_BIN），已跳过包装脚本重建，保留 $DSH_CMD。"
else
  if [ -L "$DSH_CMD" ]; then
    # 这是 npm install -g 的正常产物（每次升级都会出现），不是错误，故用 info 而非 warn。
    info "  $DSH_CMD 已被 npm 覆盖为符号链接（$(readlink "$DSH_CMD" 2>/dev/null || echo '?')），将重建为独立包装脚本。"
  fi
  DSH_BACKUP="$DSH_CMD.dsh-android.bak"
  if [ -e "$DSH_CMD" ] || [ -L "$DSH_CMD" ]; then
    cp -P -f "$DSH_CMD" "$DSH_BACKUP" 2>/dev/null || true
  fi
  # 临时文件由 on_exit（全脚本唯一的 EXIT trap）统一清理，此处不注册 trap。
  DSH_TMP="$PREFIX_BIN/.dsh-wrapper.tmp.$$"
  cat > "$DSH_TMP" <<EOF
#!/data/data/com.termux/files/usr/bin/sh
exec node --expose-internals --no-warnings $DSH_BIN "\$@"
EOF
  chmod +x "$DSH_TMP"
  mv -f "$DSH_TMP" "$DSH_CMD"
  if "$DSH_CMD" --version >/dev/null 2>&1; then
    ok "  dsh $("$DSH_CMD" --version) 可用"
    rm -f "$DSH_BACKUP"
    # 安装前移开的旧包装已完成使命（新包装已原子就位）。
    rm -f "$DSH_CMD_PREINSTALL_BAK" 2>/dev/null || true
    DSH_CMD_PREINSTALL_BAK=""
    # 旧 hold 布局迁移后的冗余安装树：只提示、不自动删（其中可能有正在运行的进程在用旧模块）。
    if [ -n "${LEGACY_HOLD_DIR:-}" ] && [ -d "$LEGACY_HOLD_DIR" ] \
       && grep -q '"dshAndroidHold": true' "$LEGACY_HOLD_DIR/package.json" 2>/dev/null; then
      warn "  旧版 hold 安装树仍占用空间：$LEGACY_HOLD_DIR（迁移前的冗余副本）"
      warn "  请先执行 bash ~/dsh/restart_dsh_now.sh 重启 dsh，确认可用后可删除：rm -rf \"$LEGACY_HOLD_DIR\""
    fi
  else
    warn "  重建后的 dsh 不可用，已回滚旧包装。"
    if [ -e "$DSH_BACKUP" ] || [ -L "$DSH_BACKUP" ]; then
      # ⚠️ 回滚也必须是「原子替换目录项」：mv -f 不 follow 目标，符号链接备份会按符号链接还原。
      #    过去写成 `rm -f "$DSH_CMD"` + `cp -P -f backup cmd`——删完到拷完之间命令是缺失的，
      #    而且目标仍存在时 cp 会跟随符号链接把真实文件覆盖掉。
      if mv -f "$DSH_BACKUP" "$DSH_CMD" 2>/dev/null; then
        warn "  已回滚旧包装"
      else
        warn "  回滚失败，已保留备份供人工恢复：$DSH_BACKUP"
      fi
    fi
    exit 1
  fi
fi

# ----------------------------------------------------- 7/8 启动/停止/重启脚本
step "7/8 启动/停止/重启脚本"
# 三个脚本从仓库复制到 ~/dsh/（真实绝对路径，不依赖 PATH）。
mkdir -p "$INSTALL_DIR/storage"
cp "$SCRIPT_DIR/start_dsh.sh"         "$INSTALL_DIR/start_dsh.sh"
cp "$SCRIPT_DIR/stop_dsh.sh"          "$INSTALL_DIR/stop_dsh.sh"
cp "$SCRIPT_DIR/restart_dsh_now.sh"   "$INSTALL_DIR/restart_dsh_now.sh"
chmod +x "$INSTALL_DIR/start_dsh.sh" "$INSTALL_DIR/stop_dsh.sh" "$INSTALL_DIR/restart_dsh_now.sh"

# 权限模式：Android 无 bwrap/landlock，必须 danger-full-access（文本取自 config/cordis.patch.yml）。
# ⚠️ 不能盲目 `>>` 追加：dsh 首次启动时会自己写一份「空数组文档」模板（3 行注释 + `[]`），
#    在已结束的 YAML 文档后面再追加序列项，整个 profile 就解析不了——
#    `dsh web` 报 YAMLException: end of the stream or a document separator is expected，
#    服务完全起不来（而且报错位置指向我们自己写的那一行）。分类与校验交给
#    patches/apply-profile-patch.js：空数组模板→替换、真实配置层→追加、残留 `[]`→定点修复，
#    落盘前后都用 dsh 自己的 loadOverlayPatches() 真解析校验；坏文件一个字节都不动。
PROFILE_PATCH="$HOME/.dsh/profiles/web/cordis.patch.yml"
SANDBOX_LAYER_FILE="$SCRIPT_DIR/config/cordis.patch.yml"
PROFILE_PATCH_TOOL="$SCRIPT_DIR/patches/apply-profile-patch.js"
if [ -f "$PROFILE_PATCH_TOOL" ]; then
  PATCH_ROOT_ARGS=()
  if [ -f "$DSH_DIR/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js" ]; then
    PATCH_ROOT_ARGS=(--root "$DSH_DIR")   # 只借 dsh 自己的解析器校验；定位不到时脚本自行降级为结构检查
  fi
  if PATCH_OUT="$(node "$PROFILE_PATCH_TOOL" --target "$PROFILE_PATCH" --layer "$SANDBOX_LAYER_FILE" "${PATCH_ROOT_ARGS[@]}" 2>&1)"; then
    printf '%s\n' "$PATCH_OUT" >>"$SETUP_LOG"
    ok "  权限模式已就绪：$(printf '%s' "$PATCH_OUT" | grep -oE '^\[[A-Z]+' | tail -1 | tr -d '[') $PROFILE_PATCH"
  else
    status_clear 2>/dev/null || true
    printf '%s\n' "$PATCH_OUT" >&2
    printf '%s\n' "$PATCH_OUT" >>"$SETUP_LOG"
    error "  权限层写入失败：$PROFILE_PATCH 不是可解析的顶层数组，原文件未被改动。"
    error "       原因：dsh 的 profile 装载将在 boot 前失败（无法启动），因此此处中断而非继续。"
    error "       处置：按上方提示修复该文件（或删除该文件由 dsh 重建），然后重新运行本脚本。"
    exit 1
  fi
else
  error "  缺少 patches/apply-profile-patch.js，无法安全安装权限层（dsh 将无法启动）。"
  exit 1
fi

# ---------------------------------------------------------------- 8/8 完成
ELAPSED="$(( $(date +%s) - START_TIME ))"
step "8/8 完成"
# 状态指示器到此为止：先擦掉常驻状态行，再打完成横幅，否则横幅会和它叠在同一行。
status_stop
printf '%s════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
printf '%s  安装完成%s  ·  耗时 %s\n' "$C_GREEN" "$C_RST" "$(printf '%d分%02d秒' $((ELAPSED / 60)) $((ELAPSED % 60)))"
printf '  安装目录  %s\n' "$DSH_DIR"
printf '  日志      %s\n' "$SETUP_LOG"
printf '\n  下一步\n'
printf '    bash ~/dsh/start_dsh.sh    # 启动并打开带 token 的浏览器\n'
printf '    bash ~/dsh/stop_dsh.sh     # 停止\n'
printf '    在 Web UI 的 Models 页面填写 DeepSeek API Key\n'
printf '\n  注意\n'
printf '    仅监听 127.0.0.1；danger-full-access 已关闭进程沙箱（Android 无替代方案），仅建议个人设备。\n'
printf '    升级 dsh / Node 后重跑 bash setup.sh；不要用 npm -g update（会覆盖补丁）。\n'
printf '%s════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
