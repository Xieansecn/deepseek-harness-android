#!/data/data/com.termux/files/usr/bin/bash
# DeepSeek Harness 安装脚本（Android/Termux）：安装 @deepseek-ai/dsh 并应用全部 Android 兼容补丁（幂等，可重复运行）。
# 用法：bash setup.sh [--verbose]。安装完成后，执行 bash ~/dsh/start_dsh.sh 启动服务。
#   --verbose                透传安装命令的原始输出（默认只把原始输出写入 ~/dsh/setup.log）。
#   安装方式只有一种：`npm install -g`（命令与旧版逐字一致）。
#   ── pnpm 运行时（dsh ≥0.2.1 插件市场与 `dsh plugin` 的运行期依赖；2.5/9 自动供给）──
#   DSH_PNPM_PIN_DIR=<dir>    pnpm 安装目录（默认 ~/.local/share/pnpm-pin；npm --prefix 安装 pnpm 11 JS build）。
#   DSH_PNPM_WRAPPER_DIR=<dir> 包装脚本目录（默认 ~/bin；必须位于 PATH，dsh 子进程的 execa("pnpm") 才能找到）。
#   DSH_PNPM_VERSION=<ver>    指定的 pnpm 版本（默认 11.27.1，本机实测可用的 JS build；请勿随意升级至 12.x）。
#   DSH_PNPM_CONFLICT_OVERRIDE=1  pnpm 运行时遇到「用户自有包装 / 不可共存的冲突」时强制继续
#                             （旧包装备份为 .dsh-android.bak）；pnpm 版本类冲突（≥12 / <11 / 不可用）不可覆盖。
#   DSH_SETUP_PREFIX / DSH_SETUP_PREFLIGHT_ONLY / DSH_SETUP_PROVISION_ONLY
#                             仅供测试夹具与排障使用（替换 Termux 前缀 / 仅执行 pnpm 运行时预检 / 仅执行 pnpm 运行时供给），生产环境请勿设置。
set -euo pipefail

# ---------------------------------------------------------------- 输出/日志
# 默认只输出摘要，原始命令输出写入 ~/dsh/setup.log；--verbose 可透传原始输出。
SETUP_LOG="$HOME/dsh/setup.log"
mkdir -p "$HOME/dsh"
: > "$SETUP_LOG"
START_TIME="$(date +%s)"

VERBOSE=0
# 安装方式唯一（npm install -g）；这里只解析 --verbose（参数顺序任意，便于与旧习惯兼容）。
SETUP_PREFLIGHT_ONLY="${DSH_SETUP_PREFLIGHT_ONLY:-0}"
SETUP_PROVISION_ONLY="${DSH_SETUP_PROVISION_ONLY:-0}"   # 仅测试/排障：只跑 pnpm 运行时供给就退出
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
ok()    { printf '%s%s[v]%s %s\n' "$SP_CLEAR" "$C_GREEN" "$C_RST" "$*"; status_render; }
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
DSH_STAGE_PREFIX=""
# 全脚本唯一的 EXIT trap：擦状态行 → 清理临时文件 → 失败时打印日志尾部。
# ⚠️ 必须写 tail -25 "$SETUP_LOG" >&2：重定向从左到右生效，2>/dev/null >&2 会把日志整个吞掉。
on_exit() {
  local rc=$?
  status_stop                 # 先擦掉常驻状态行，否则失败日志会叠在它上面
  if [ -n "$STATUS_FILE" ]; then rm -f "$STATUS_FILE" 2>/dev/null || true; fi
  if [ -n "$DSH_TMP" ]; then rm -f "$DSH_TMP" 2>/dev/null || true; fi
  if [ -n "$DSH_STAGE_PREFIX" ]; then rm -rf "$DSH_STAGE_PREFIX" 2>/dev/null || true; fi
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
# dsh 版本 hold 目录：3/9 先安装到暂存前缀，再移到这里，并把全局 DSH_DIR 变成指向它的
# symlink。npm 的 `update -g` 把全局 symlink 包当作 `file:` 依赖，因此不会再从 registry
# 升级/覆盖 dsh；只有重新运行 setup.sh 才会安装新版本并原子切换 hold 目录。
DSH_HOLD_ROOT="${DSH_HOLD_ROOT:-$HOME/.local/share/dsh-android}"
DSH_HOLD_DIR="${DSH_HOLD_DIR:-$DSH_HOLD_ROOT/dsh}"

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
  DSH_HOLD_ROOT="$DSH_SETUP_PREFIX/.dsh-hold"
  DSH_HOLD_DIR="$DSH_HOLD_ROOT/dsh"
fi
DSH_CMD="$PREFIX_BIN/dsh"

# 把暂存安装树原子地切为全局 dsh 的 symlink：npm -g update 此后只认 file: 依赖，不会升级/覆盖。
dsh_hold_pin() {
  local src="$1"
  local prev="$DSH_DIR.prehold.$$"
  local old="$DSH_HOLD_DIR.old.$$"

  [ -d "$src" ] || { error "  dsh 暂存安装目录不存在：$src"; exit 1; }
  mkdir -p "$DSH_HOLD_ROOT" "$(dirname "$DSH_DIR")"

  if [ -e "$DSH_HOLD_DIR" ] || [ -L "$DSH_HOLD_DIR" ]; then
    mv "$DSH_HOLD_DIR" "$old" || { error "  无法备份旧 dsh hold 目录：$DSH_HOLD_DIR"; exit 1; }
  fi
  if ! mv "$src" "$DSH_HOLD_DIR"; then
    if [ -e "$old" ] || [ -L "$old" ]; then mv "$old" "$DSH_HOLD_DIR" 2>/dev/null || true; fi
    error "  无法把新 dsh 安装树移动到 hold 目录：$DSH_HOLD_DIR"
    exit 1
  fi

  # 关键：移除 hold 包的 bin 字段。setup.sh 会自己写 /usr/bin/dsh 包装脚本来带
  # --expose-internals；如果 package.json 仍有 bin，npm -g update 重建 bin link 时会
  # 与这个包装文件冲突（EEXIST），即使 dsh 本身已是 symlink/file: 依赖。
  node - "$DSH_HOLD_DIR/package.json" <<'JS' || { error "  无法更新 hold 包的 package.json（移除 bin 字段）"; exit 1; }
const fs = require("node:fs");
const path = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(path, "utf8"));
delete pkg.bin;
pkg.dshAndroidHold = true;
fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n");
JS

  if [ -e "$DSH_DIR" ] || [ -L "$DSH_DIR" ]; then
    mv "$DSH_DIR" "$prev" || { error "  无法移开旧全局 dsh 路径：$DSH_DIR"; exit 1; }
  fi
  if ! ln -s "$DSH_HOLD_DIR" "$DSH_DIR"; then
    if [ -e "$prev" ] || [ -L "$prev" ]; then mv "$prev" "$DSH_DIR" 2>/dev/null || true; fi
    error "  无法创建 dsh hold symlink：$DSH_DIR -> $DSH_HOLD_DIR"
    exit 1
  fi

  rm -rf "$prev" "$old"
  ok "  dsh 已 hold：$DSH_DIR -> $DSH_HOLD_DIR（npm -g update 不会升级 dsh；升级只走 setup.sh）"
}

# ---------------------------------------- pnpm 运行时供给（dsh ≥0.2.1 插件功能的运行期依赖）
# 为什么需要：dsh 0.2.1 的 plugin-manager / `dsh plugin …` 会 execa("pnpm") 从 PATH 找 pnpm——
# pnpm 11.x 因此成为**事实上的运行期依赖**（不只是安装工具）。而 pnpm 12 的原生 android-arm64
# 二进制在本机写 store 必失败（ERR_PNPM_STORE_DIR_ACQUIRE_OPERATION_LOCK / lock_shared() not supported），
# 所以统一供给「npm --prefix 装 pnpm@11 的 JS build + 包装脚本用 node 跑 bin/pnpm.mjs」这套本机已验证布局。
# 环境变量：
#   DSH_PNPM_PIN_DIR=<dir>        pnpm 安装目录（默认 ~/.local/share/pnpm-pin；npm --prefix 安装）
#   DSH_PNPM_WRAPPER_DIR=<dir>    包装脚本目录（默认 ~/bin，必须在 PATH 上才能被 dsh 子进程 execa 到）
#   DSH_PNPM_VERSION=<ver>        钉的 pnpm 版本（默认 11.27.1，本机实测可用）
#   DSH_PNPM_CONFLICT_OVERRIDE=1  覆盖「可共存」类冲突（用户自己的包装会被备份为 .dsh-android.bak）；版本类不可覆盖
DSH_PNPM_CONFLICT_OVERRIDE="${DSH_PNPM_CONFLICT_OVERRIDE:-0}"
PNPM_CMD=()
PNPM_VERSION=""
DSH_PNPM_PIN_DIR="${DSH_PNPM_PIN_DIR:-$HOME/.local/share/pnpm-pin}"
DSH_PNPM_WRAPPER_DIR="${DSH_PNPM_WRAPPER_DIR:-$HOME/bin}"
# ⚠️ 默认钉 11.27.1（本机实测可用），而不是浮动的 `pnpm@11`：11.28+ 的 bin/pnpm.mjs 可能改成
#    「查找/下载原生二进制再 spawn」，在 Android 上又会回到 store 锁失败那条路。
DSH_PNPM_VERSION="${DSH_PNPM_VERSION:-11.27.1}"
DSH_PNPM_WRAPPER_MARKER="dsh-android-pnpm-runtime-wrapper"
PNPM_RUNTIME_STATE=""       # ok | reuse | provision | repair（由 pnpm_runtime_preflight 决定）
PNPM_RUNTIME_INFO=""
PNPM_REUSE_SOURCE=""        # reuse：被复用的 pnpm 路径
PNPM_REUSE_VERSION=""       # reuse：该 pnpm 的版本
PNPM_REUSE_ENTRY=""         # reuse：node 入口（.mjs/.cjs），空表示直接 exec 源路径
PNPM_CAND_VERSION=""        # 探测过程中的临时值（pnpm_probe_path 设置）
PNPM_CAND_ENTRY=""
NPM_STRICT_ALLOW_SCRIPTS=""
PNPM_NODE_BIN="$(command -v node 2>/dev/null || true)"
PNPM_RUNTIME_WRAPPERS="pnpm pn pnpx pnx"

# 某个 bin 名对应的包内入口（与 pnpm 包 package.json 的 bin 字段一致）。
pnpm_wrapper_rel() {
  case "$1" in
    pnpm|pn) printf 'bin/pnpm.mjs' ;;
    pnpx|pnx) printf 'bin/pnpx.mjs' ;;
    *) return 1 ;;
  esac
}

# 本仓库生成的包装带固定 marker 注释（判定归属用「内容里的完整 marker」，不是裸子串）。
pnpm_wrapper_is_ours() { [ -f "$1" ] && grep -qF "$DSH_PNPM_WRAPPER_MARKER" "$1" 2>/dev/null; }

pnpm_pin_version() {
  node -p "try{require('$DSH_PNPM_PIN_DIR/node_modules/pnpm/package.json').version}catch(e){''}" 2>/dev/null || true
}

# 目录是否在 PATH 中（按字面与 realpath 两种方式判，防止 symlink 前缀差异）。
dir_in_path() {
  local want="$1" d wreal=""
  wreal="$(readlink -f "$want" 2>/dev/null || printf '%s' "$want")"
  local oldifs="$IFS"
  IFS=':'
  for d in $PATH; do
    if [ "$d" = "$want" ]; then IFS="$oldifs"; return 0; fi
    if [ "$(readlink -f "$d" 2>/dev/null || true)" = "$wreal" ]; then IFS="$oldifs"; return 0; fi
  done
  IFS="$oldifs"
  return 1
}

# 读取 npm 的 --allow-scripts 策略：npm 11 默认 false（白名单是**建议性**的，白名单外脚本仍执行、只警告）；
# npm 12 起白名单才强制；用户可显式设 strict-allow-scripts=true（则白名单外脚本硬失败 → 当安装冲突拒绝）。
pnpm_probe_npm_strict() {
  [ -n "$NPM_STRICT_ALLOW_SCRIPTS" ] && return 0
  local out=""
  out="$("${NPM_CMD[@]}" config get strict-allow-scripts 2>/dev/null | tail -1 || true)"
  case "$out" in
    true|false) NPM_STRICT_ALLOW_SCRIPTS="$out" ;;
    *) NPM_STRICT_ALLOW_SCRIPTS="unknown" ;;
  esac
}

# ---------------------------------------------------------------- pnpm 运行时探测
# 设计原则：**不写死某个 pnpm 路径、也不写死某个具体版本号**——本机可能同时存在多个 pnpm
# （pin 目录的 11.x、~/bin 的包装、$PREFIX/bin 的 npm 全局 12.x、PNPM_HOME 里的……），谁排在 PATH
# 前面就决定 dsh 子进程实际用到哪个。所以这里把所有候选都探一遍、逐个跑 --version，只认 11.x
# （12 在 Android 上写 store 必失败），再决定「直接用 / 复用 / 供给 / 停止」。

# a 目录在 PATH 中是否排在 b 之前（两者都要在 PATH 上）。
dir_precedes_in_path() {
  local a="$1" b="$2" d i=0 ai="" bi="" ar="" br="" hit=""
  ar="$(readlink -f "$a" 2>/dev/null || printf '%s' "$a")"
  br="$(readlink -f "$b" 2>/dev/null || printf '%s' "$b")"
  local oldifs="$IFS"
  IFS=':'
  for d in $PATH; do
    if [ -z "$d" ]; then i=$((i+1)); continue; fi
    hit="$(readlink -f "$d" 2>/dev/null || printf '%s' "$d")"
    if [ -z "$ai" ] && { [ "$d" = "$a" ] || [ "$hit" = "$ar" ]; }; then ai="$i"; fi
    if [ -z "$bi" ] && { [ "$d" = "$b" ] || [ "$hit" = "$br" ]; }; then bi="$i"; fi
    i=$((i+1))
  done
  IFS="$oldifs"
  [ -n "$ai" ] && [ -n "$bi" ] && [ "$ai" -lt "$bi" ]
}

# 探测一个候选路径：能跑则返回 0，并设置 PNPM_CAND_VERSION / PNPM_CAND_ENTRY（node 入口，可能为空）。
pnpm_probe_path() {
  local cand="$1"
  PNPM_CAND_VERSION=""
  PNPM_CAND_ENTRY=""
  PNPM_CAND_CMD=()
  [ -e "$cand" ] || [ -L "$cand" ] || return 1
  resolve_pnpm_cmd "$cand" || return 1
  [ -n "${PNPM_VERSION:-}" ] || return 1
  PNPM_CAND_VERSION="$PNPM_VERSION"
  PNPM_CAND_CMD=("${PNPM_CMD[@]}")
  if [ "${#PNPM_CAND_CMD[@]}" -eq 2 ] && [ "${PNPM_CAND_CMD[0]}" = "node" ]; then
    PNPM_CAND_ENTRY="${PNPM_CAND_CMD[1]}"
  fi
  return 0
}

# 所有候选 pnpm（顺序即优先级）：PATH 上的每一个（第一个就是 dsh 实际会用到的那一个）、
# 本仓库包装目录、本仓库 pin 目录、PNPM_HOME、npm 全局目录。去重在调用方按 realpath 做。
pnpm_candidates() {
  local d npm_root="" oldifs="$IFS"
  IFS=':'
  for d in $PATH; do
    if [ -n "$d" ] && { [ -e "$d/pnpm" ] || [ -L "$d/pnpm" ]; }; then printf '%s\n' "$d/pnpm"; fi
  done
  IFS="$oldifs"
  printf '%s\n' "$DSH_PNPM_WRAPPER_DIR/pnpm"
  printf '%s\n' "$DSH_PNPM_PIN_DIR/node_modules/pnpm/bin/pnpm.mjs"
  printf '%s\n' "${PNPM_HOME:-$HOME/.local/share/pnpm}/bin/pnpm"
  npm_root="$("${NPM_CMD[@]}" root -g 2>/dev/null | tail -1 || true)"
  if [ -n "$npm_root" ]; then
    printf '%s\n' "$npm_root/pnpm/bin/pnpm.cjs"
    printf '%s\n' "$npm_root/pnpm/bin/pnpm.mjs"
  fi
}

# 我们写的包装能否「压过」当前挡路的 pnpm：包装目录在 PATH 上、且排在它前面；
# 若挡路的正是包装目录里我们自己写的包装，重写即可（不存在遮蔽问题）。
pnpm_can_shadow() {
  local target="${1:-}" wdir="$DSH_PNPM_WRAPPER_DIR" real=""
  dir_in_path "$wdir" || return 1
  [ -n "$target" ] || return 0
  real="$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")"
  case "$real" in
    "$wdir"/*) return 0 ;;
  esac
  dir_precedes_in_path "$wdir" "$(dirname "$target")"
}

# 停止（预检全程只读、未改动任何文件）：说清探测到了什么、为什么不合格、怎么修、修完怎么继续。
pnpm_stop_unusable() {
  error "  pnpm 运行时不可用：未找到可用的 pnpm 11.x。"
  error "  探测范围：PATH 各目录、$DSH_PNPM_WRAPPER_DIR、$DSH_PNPM_PIN_DIR、PNPM_HOME、npm 全局目录。"
  if [ -n "$problems" ]; then
    error "  探测结果："
    while IFS= read -r line; do
      [ -n "$line" ] && error "$line"
    done <<< "$problems"
  fi
  if [ -n "${1:-}" ]; then error "$1"; fi
  error "  为什么要求 11.x：pnpm 12 的 android-arm64 原生二进制在本机写 store 必然失败："
  error "    ERR_PNPM_STORE_DIR_ACQUIRE_OPERATION_LOCK / lock_shared() not supported"
  error "  处置（任选其一；本步骤只读、未改动任何文件，修好后重新运行 bash setup.sh 即可）："
  error "    1) npm install -g pnpm@11              # 把全局 pnpm 换成 11.x（PATH 上换成 11.x 后会被直接复用）"
  error "    2) npm uninstall -g pnpm               # 删掉不可用的 pnpm，本脚本会自动供给 pnpm $DSH_PNPM_VERSION"
  error "    3) 把已有的 pnpm 11.x 放到 PATH 前端；或让 $DSH_PNPM_WRAPPER_DIR 位于 PATH 前端（本脚本会写包装并压过坏的 pnpm）"
  error "  版本类问题不可通过 DSH_PNPM_CONFLICT_OVERRIDE 覆盖。"
  exit 1
}

# pnpm 运行时预检（只读，安装前执行）：探测 + 版本判定 → 状态 ok | reuse | provision | repair；
# 找不到可用版本则中文提示 + exit 1（不产生任何写入）。
pnpm_runtime_preflight() {
  local path_pnpm="" path_ver="" path_usable=0
  local cand="" real_cand="" seen="" usable_path="" usable_ver="" usable_entry=""
  local cand_ver="" cand_maj="" pin_ver="" maj="" real_p="" npm_root="" gver="" gmaj=""
  local problems="" wdir="$DSH_PNPM_WRAPPER_DIR"
  path_pnpm="$(command -v pnpm 2>/dev/null || true)"
  pnpm_probe_npm_strict

  # a) npm strict-allow-scripts=true：会把 SKIP_SCRIPTS 里的 koffi 变成硬错误（ESTRICTALLOWSCRIPTS），
  #    整次 npm install 必然中断 → 配置类冲突，不可覆盖（改回默认 false 即可）。
  if [ "$NPM_STRICT_ALLOW_SCRIPTS" = "true" ]; then
    error "  安装冲突：检测到 npm strict-allow-scripts=true。"
    error "  原因：该设置会把未列入白名单（--allow-scripts）的安装脚本转为硬性错误（ESTRICTALLOWSCRIPTS）；"
    error "  本脚本按设计跳过 koffi 构建（koffi 位于 SKIP_SCRIPTS），因此整次 npm install 将中断。"
    error "  处置：执行 npm config set strict-allow-scripts false --location=user"
    error "        或删除 ~/.npmrc 或项目 .npmrc 中的 strict-allow-scripts=true，随后重新运行本脚本。"
    exit 1
  fi

  # b) PATH 上第一个 pnpm：dsh 子进程实际执行的就是它。
  if [ -n "$path_pnpm" ]; then
    if pnpm_probe_path "$path_pnpm"; then
      path_ver="$PNPM_CAND_VERSION"
      maj="${path_ver%%.*}"
      case "$maj" in
        ''|*[!0-9]*) : ;;
        *) if [ "$maj" -eq 11 ]; then path_usable=1; fi ;;
      esac
    fi
  fi

  # c) 扫描全部候选（去重）：记录第一个可用的 11.x，以及所有不合格来源。
  while IFS= read -r cand; do
    if [ -z "$cand" ]; then continue; fi
    if [ ! -e "$cand" ] && [ ! -L "$cand" ]; then continue; fi
    real_cand="$(readlink -f "$cand" 2>/dev/null || printf '%s' "$cand")"
    case " $seen " in *" $real_cand "*) continue ;; esac
    seen="$seen $real_cand"
    if pnpm_probe_path "$cand"; then
      cand_ver="$PNPM_CAND_VERSION"
      cand_maj="${cand_ver%%.*}"
      case "$cand_maj" in
        ''|*[!0-9]*)
          problems="$problems
    $cand（版本无法解析：'$cand_ver'）" ;;
        *)
          if [ "$cand_maj" -eq 11 ]; then
            if [ -z "$usable_path" ]; then
              usable_path="$cand"; usable_ver="$cand_ver"; usable_entry="$PNPM_CAND_ENTRY"
            fi
          else
            if [ "$cand_maj" -ge 12 ]; then
              problems="$problems
    $cand（pnpm $cand_ver 在本机不可用：写 store 必然失败，需要 11.x）"
            else
              problems="$problems
    $cand（pnpm $cand_ver 版本过低，需要 11.x）"
            fi
          fi ;;
      esac
    else
      problems="$problems
    $cand（不可执行或入口损坏，--version 无法解析）"
    fi
  done < <(pnpm_candidates)

  # d) 判定。
  if [ "$path_usable" -eq 1 ]; then
    PNPM_RUNTIME_STATE="ok"
    PNPM_RUNTIME_INFO="$path_pnpm（pnpm $path_ver）"
  elif [ -n "$usable_path" ]; then
    # 有能用的 11.x，但不在 PATH 首位：写包装指向它，并确认包装能压过挡路的 pnpm。
    if ! dir_in_path "$wdir"; then
      pnpm_stop_unusable "  另外：pnpm 包装目录 $wdir 未加入 PATH，写进去也不会生效。在 ~/.bashrc 追加 export PATH=\"\$HOME/bin:\$PATH\" 后重开终端。"
    fi
    if ! pnpm_can_shadow "$path_pnpm"; then
      pnpm_stop_unusable "  另外：PATH 上第一个 pnpm（$path_pnpm${path_ver:+，pnpm $path_ver}）排在包装目录 $wdir 之前，写包装也压不过它；请换掉它或调整 PATH 顺序。"
    fi
    PNPM_RUNTIME_STATE="reuse"
    PNPM_REUSE_SOURCE="$usable_path"
    PNPM_REUSE_VERSION="$usable_ver"
    PNPM_REUSE_ENTRY="$usable_entry"
  elif [ -n "$problems" ]; then
    # 没有任何可用版本：能自动修（包装压得过坏的 pnpm）就修，否则停止并交给用户。
    if ! pnpm_can_shadow "$path_pnpm"; then
      if ! dir_in_path "$wdir"; then
        pnpm_stop_unusable "  另外：pnpm 包装目录 $wdir 未加入 PATH，写进去也不会生效。在 ~/.bashrc 追加 export PATH=\"\$HOME/bin:\$PATH\" 后重开终端。"
      else
        pnpm_stop_unusable "  另外：PATH 上第一个 pnpm（$path_pnpm${path_ver:+，pnpm $path_ver}）排在包装目录 $wdir 之前，写包装也压不过它；请换掉它（npm install -g pnpm@11 / npm uninstall -g pnpm）或调整 PATH 顺序。"
      fi
    fi
    real_p=""
    if [ -n "$path_pnpm" ]; then real_p="$(readlink -f "$path_pnpm" 2>/dev/null || printf '%s' "$path_pnpm")"; fi
    case "$real_p" in
      "$wdir"/*)
        if pnpm_wrapper_is_ours "$real_p"; then PNPM_RUNTIME_STATE="repair"; else PNPM_RUNTIME_STATE="provision"; fi ;;
      *)
        PNPM_RUNTIME_STATE="provision" ;;
    esac
  else
    # 完全没有 pnpm：自动供给（需要包装目录在 PATH 上才生效）。
    if ! dir_in_path "$wdir"; then
      error "  安装冲突：pnpm 包装目录 $DSH_PNPM_WRAPPER_DIR 未加入 PATH。"
      error "  原因：dsh 的插件功能通过 execa(\"pnpm\") 从 PATH 查找 pnpm；包装写入该目录但 PATH 未包含时不会生效。"
      error "  处置（Termux）：在 ~/.bashrc 中追加一行：  export PATH=\"\$HOME/bin:\$PATH\""
      error "        随后重新打开终端（或执行 source ~/.bashrc），再重新运行本脚本。"
      exit 1
    fi
    PNPM_RUNTIME_STATE="provision"
  fi

  # e) 提醒（不阻断）：npm 全局里被遮蔽的 pnpm；pin 目录里残留的非 11.x。
  npm_root="$("${NPM_CMD[@]}" root -g 2>/dev/null | tail -1 || true)"
  if [ -n "$npm_root" ] && [ -f "$npm_root/pnpm/package.json" ]; then
    gver="$(node -p "try{require('$npm_root/pnpm/package.json').version}catch(e){''}" 2>/dev/null || true)"
    gmaj="${gver%%.*}"
    case "$gmaj" in
      ''|*[!0-9]*) : ;;
      *)
        if [ "$gmaj" -ge 12 ]; then
          if [ "$path_usable" -eq 1 ]; then
            warn "  提醒：npm 全局仍安装 pnpm $gver（$npm_root/pnpm），当前被 PATH 上的 pnpm 11.x 遮蔽；pnpm 12 在本 Android 环境写 store 必然失败（store 锁 / 原生 exe 无 android 构建），请勿让它重新排到 PATH 前端。"
          else
            warn "  提醒：npm 全局仍安装 pnpm $gver（$npm_root/pnpm）；pnpm 12 在本 Android 环境写 store 必然失败（store 锁 / 原生 exe 无 android 构建）。本脚本会用 11.x 包装压过它，别让它排在 PATH 前端；也可执行 npm install -g pnpm@11 换掉。"
          fi
        elif [ "$gmaj" -lt 11 ]; then
          warn "  提醒：npm 全局仍存在旧版 pnpm $gver（$npm_root/pnpm）；建议执行 npm uninstall -g pnpm 清理。"
        fi ;;
    esac
  fi
  if [ "$PNPM_RUNTIME_STATE" != "ok" ] && [ "$PNPM_RUNTIME_STATE" != "reuse" ]; then
    pin_ver="$(pnpm_pin_version)"
    if [ -n "$pin_ver" ]; then
      maj="${pin_ver%%.*}"
      case "$maj" in
        ''|*[!0-9]*) : ;;
        *) if [ "$maj" -ne 11 ]; then
             warn "  提醒：$DSH_PNPM_PIN_DIR 中的 pnpm 版本为 $pin_ver（非 11.x），2.5/9 将重新安装为 $DSH_PNPM_VERSION。"
           fi ;;
      esac
    fi
  fi

  # f) 状态输出（预检只读，真正写入在 2.5/9）。
  case "$PNPM_RUNTIME_STATE" in
    ok)        info "  pnpm 运行时可用（$PNPM_RUNTIME_INFO；dsh 插件市场与 dsh plugin 依赖）。" ;;
    reuse)     info "  pnpm 运行时：复用已有的 pnpm $PNPM_REUSE_VERSION（$PNPM_REUSE_SOURCE），2.5/9 写包装让它在 PATH 中生效（不重新下载）。" ;;
    provision) info "  pnpm 运行时：未找到位于 PATH 首位的可用 pnpm 11.x，2.5/9 将安装 pnpm $DSH_PNPM_VERSION 并写入 $wdir 包装。" ;;
    repair)    info "  pnpm 运行时：本仓库的 pnpm 安装或包装已损坏，2.5/9 将重新安装并修复。" ;;
    *)         error "  pnpm 运行时预检状态异常（$PNPM_RUNTIME_STATE）。"; exit 1 ;;
  esac
}

# 包装文件是否已经在做同一件事（容忍引号/多余空白的差异：用户手写的包装常不写引号）。
pnpm_wrapper_equivalent() {
  local file="$1" cmdline="$2" body="" want=""
  [ -f "$file" ] || return 1
  body="$(tr -d '"' < "$file" 2>/dev/null || true)"
  want="$(printf 'exec %s' "$cmdline" | tr -d '"')"
  case "$body" in
    *"$want"*) return 0 ;;
  esac
  return 1
}

# 写一个包装脚本：<name> <要 exec 的完整命令（不含 "$@"）> <来源/版本说明>
# - 本仓库生成物（带 marker）→ 直接刷新；
# - 内容已等价（例如用户手写的 pin 包装）→ 认领，不改写；
# - 用户自有且不等价的包装 → 冲突（DSH_PNPM_CONFLICT_OVERRIDE=1 时先备份再重写）。
pnpm_write_wrapper() {
  local name="$1" cmdline="$2" label="$3"
  local file="$DSH_PNPM_WRAPPER_DIR/$name" tmp="$DSH_PNPM_WRAPPER_DIR/.$name.dsh-tmp.$$"
  if [ -e "$file" ]; then
    if pnpm_wrapper_is_ours "$file"; then
      :   # 本仓库生成物：刷新即可
    elif pnpm_wrapper_equivalent "$file" "$cmdline"; then
      return 0   # 已等价的包装（如手工 pin 包装）：认领，不覆盖
    elif [ "$DSH_PNPM_CONFLICT_OVERRIDE" = "1" ]; then
      cp -f "$file" "$file.dsh-android.bak" 2>/dev/null || true
      warn "  已备份原有 pnpm 包装至 $file.dsh-android.bak。"
    else
      error "  安装冲突：$file 已存在，但不属于本仓库生成的 pnpm 包装（无 marker，内容亦不等价）。"
      error "  本脚本不会覆盖用户自有包装。处置：请先执行以下操作之一："
      error "    删除或重命名 $file（以及同目录下的 pn、pnpx、pnx 同名文件），然后重新运行本脚本"
      error "    或设置 DSH_PNPM_CONFLICT_OVERRIDE=1（旧文件将备份为 .dsh-android.bak 后重写）"
      exit 1
    fi
  fi
  {
    printf '#!/data/data/com.termux/files/usr/bin/sh\n'
    printf '# %s（由 setup.sh 2.5/9 生成，请勿手动修改；%s）\n' "$DSH_PNPM_WRAPPER_MARKER" "$label"
    printf '# 为什么用 node 跑 pnpm 的 JS 入口：pnpm 12 的原生 android-arm64 二进制在本机写 store 必失败\n'
    printf '#   （ERR_PNPM_STORE_DIR_ACQUIRE_OPERATION_LOCK / lock_shared() not supported）。\n'
    printf '# 解除：rm -f %s/{pnpm,pn,pnpx,pnx}\n' "$DSH_PNPM_WRAPPER_DIR"
    printf 'exec %s "$@"\n' "$cmdline"
  } > "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$file"
}

# pnpm 运行时供给（2.5/9 正式步骤；幂等：已可用则只报 [OK]，不写任何文件）。
pnpm_runtime_provision() {
  step "2.5/9 pnpm 运行时供给（dsh 插件依赖）"
  local pin="$DSH_PNPM_PIN_DIR" wdir="$DSH_PNPM_WRAPPER_DIR" ver="" maj="" name="" rel="" node_bin="$PNPM_NODE_BIN"
  local pkg="" ext="" base="" cmdline=""
  case "$PNPM_RUNTIME_STATE" in
    ok)
      ok "  pnpm 运行时可用（$PNPM_RUNTIME_INFO）。"
      return 0 ;;
    reuse|provision|repair) : ;;
    *)
      error "  pnpm 运行时预检状态异常（$PNPM_RUNTIME_STATE）；请先通过预检，再执行 2.5/9。"
      exit 1 ;;
  esac
  [ -n "$node_bin" ] || node_bin="node"
  mkdir -p "$wdir"

  if [ "$PNPM_RUNTIME_STATE" = "reuse" ]; then
    # 本机已有可用的 11.x（不一定在 PATH 首位）：写包装指向它，不重新下载。
    info "  复用已有的 pnpm $PNPM_REUSE_VERSION：$PNPM_REUSE_SOURCE"
    pkg=""
    ext=""
    if [ -n "$PNPM_REUSE_ENTRY" ]; then
      pkg="$(dirname "$(dirname "$PNPM_REUSE_ENTRY")")"
      base="$(basename "$PNPM_REUSE_ENTRY")"
      ext="${base##*.}"
    fi
    for name in $PNPM_RUNTIME_WRAPPERS; do
      cmdline=""
      case "$name" in
        pnpm|pn)
          if [ -n "$PNPM_REUSE_ENTRY" ]; then
            cmdline="\"$node_bin\" \"$PNPM_REUSE_ENTRY\""
          else
            cmdline="\"$PNPM_REUSE_SOURCE\""
          fi ;;
        *)
          if [ -n "$ext" ] && [ -f "$pkg/bin/pnpx.$ext" ]; then
            cmdline="\"$node_bin\" \"$pkg/bin/pnpx.$ext\""
          else
            continue
          fi ;;
      esac
      pnpm_write_wrapper "$name" "$cmdline" "复用 $PNPM_REUSE_SOURCE（pnpm $PNPM_REUSE_VERSION）"
    done
  else
    info "  正在安装 pnpm $DSH_PNPM_VERSION（npm --prefix $pin；JS build，无原生 exe）……"
    mkdir -p "$pin"
    if ! run_hidden_spinner "  正在安装 pnpm 运行时……" \
        "${NPM_CMD[@]}" install --prefix "$pin" --no-audit --no-fund --loglevel=error "pnpm@$DSH_PNPM_VERSION"; then
      error "  pnpm 运行时安装失败（原因见 $SETUP_LOG）。"
      error "  原因：dsh ≥0.2.1 的插件市场与 dsh plugin 通过 execa(\"pnpm\") 调用 pnpm；缺少运行时将导致上述功能不可用，因此中断安装。"
      exit 1
    fi
    if [ ! -f "$pin/node_modules/pnpm/bin/pnpm.mjs" ]; then
      error "  pnpm 运行时安装完成，但未检测到入口 $pin/node_modules/pnpm/bin/pnpm.mjs（安装目录不符合预期）。"
      exit 1
    fi
    for name in $PNPM_RUNTIME_WRAPPERS; do
      rel="$(pnpm_wrapper_rel "$name")"
      pnpm_write_wrapper "$name" "\"$node_bin\" \"$pin/node_modules/pnpm/$rel\"" "pnpm $DSH_PNPM_VERSION JS build（安装目录 $pin）"
    done
  fi
  # 验证：包装能跑、版本是 11.x、PATH 解析到我们写的包装。
  if ! ver="$("$wdir/pnpm" --version 2>/dev/null | tail -1)" || [ -z "$ver" ]; then
    error "  pnpm 运行时包装不可执行：$wdir/pnpm --version 执行失败。"
    exit 1
  fi
  maj="${ver%%.*}"
  case "$maj" in
    ''|*[!0-9]*) error "  无法解析已安装的 pnpm 版本（'$ver'）。"; exit 1 ;;
  esac
  if [ "$maj" -ne 11 ]; then
    error "  已安装的 pnpm 版本不符合预期：$ver（需要 11.x）。"
    exit 1
  fi
  if [ "$(command -v pnpm 2>/dev/null || true)" != "$wdir/pnpm" ]; then
    error "  pnpm 包装已写入，但 PATH 解析结果不是该包装：$(command -v pnpm 2>/dev/null || echo '（空）')（期望 $wdir/pnpm）。"
    error "  请将 $wdir 置于 PATH 前端（Termux 通常在 ~/.bashrc 中设置 export PATH=\"\$HOME/bin:\$PATH\"），然后重新运行。"
    exit 1
  fi
  PNPM_VERSION="$ver"
  PNPM_CMD=("$wdir/pnpm")   # 供给后即为 dsh 子进程实际解析到的 pnpm
  ok "  pnpm 运行时已就绪（$ver；包装 $wdir/pnpm，安装目录 $pin）。"
}

# pnpm 可执行入口解析：优先 `node <pnpm.mjs/cjs>`，绕开坏 shebang（npm 装的 pnpm 常是 #!/usr/bin/env node，
# 而 Termux 的 /usr/bin/env 不解析）。壳包装（如 ~/bin/pnpm 的 `exec node …/pnpm.mjs "$@"`）从内容里提取入口。
# 成功：PNPM_CMD=(...) / PNPM_VERSION=<ver> 并返回 0；失败返回 1。
resolve_pnpm_cmd() {
  local cand="" real="" entry="" ver=""
  PNPM_CMD=()
  if [ -n "${1:-}" ]; then
    cand="$1"                                  # 显式 candidate（运行时预检用）
    if [ ! -e "$cand" ]; then
      cand="$(command -v "$1" 2>/dev/null || true)"
    fi
    [ -n "$cand" ] || return 1
  else
    cand="$(command -v pnpm 2>/dev/null || true)"
    [ -n "$cand" ] || return 1
  fi
  real="$(readlink -f "$cand" 2>/dev/null || printf '%s' "$cand")"
  case "$real" in
    *.mjs|*.cjs) PNPM_CMD=(node "$real") ;;
    # 极少数 npm 包把 bin 指向 .js；只有确认是 js 文件才算，避免把壳脚本误当 node 入口。
    *.js) [ "$(head -c 2 "$real" 2>/dev/null || true)" != "#!" ] && PNPM_CMD=(node "$real") ;;
  esac
  if [ "${#PNPM_CMD[@]}" -eq 0 ] && [ -f "$cand" ]; then
    # ⚠️ 只从「壳包装」里取绝对路径的 pnpm 入口；相对路径（$basedir/...）不猜，交给直接执行回退。
    entry="$(tr ' \t' '\n\n' < "$cand" 2>/dev/null | grep -E '^/[^[:space:]]*\.(mjs|cjs)$' | head -1 || true)"
    if [ -n "$entry" ] && [ -f "$entry" ]; then
      PNPM_CMD=(node "$entry")
    fi
  fi
  if [ "${#PNPM_CMD[@]}" -gt 0 ]; then
    if ver="$("${PNPM_CMD[@]}" --version 2>/dev/null | tail -1)" && [ -n "$ver" ]; then
      PNPM_VERSION="$ver"
      return 0
    fi
  fi
  # 回退：直接执行原路径（shebang 正常的 pnpm 包装脚本/二进制都走这里）。
  PNPM_CMD=("$cand")
  if ver="$("${PNPM_CMD[@]}" --version 2>/dev/null | tail -1)" && [ -n "$ver" ]; then
    PNPM_VERSION="$ver"
    return 0
  fi
  PNPM_CMD=()
  return 1
}

# pnpm 运行时预检（只读）：dsh ≥0.2.1 的插件功能运行期通过 execa("pnpm") 依赖该运行时。
pnpm_runtime_preflight
# 仅夹具/人工预检：做完上面的（只读）预检就退出，绝不进入安装步骤。
if [ "$SETUP_PREFLIGHT_ONLY" = "1" ]; then
  info "仅预检模式（DSH_SETUP_PREFLIGHT_ONLY=1）：预检已完成，未执行任何安装。"
  exit 0
fi
# 仅夹具/排障：只跑 pnpm 运行时供给（不装 dsh、不碰安装树）。
if [ "$SETUP_PROVISION_ONLY" = "1" ]; then
  pnpm_runtime_provision
  info "仅供给模式（DSH_SETUP_PROVISION_ONLY=1）：pnpm 运行时已就绪，退出（未安装 dsh）。"
  exit 0
fi

# 0 锚点预检：升级重跑时先只读检查各补丁锚点是否还在，非致命。
anchor_precheck() {
  [ -d "$DSH_DIR/node_modules/@deepseek-ai" ] || return 0
  step "0/9 锚点预检"
  local missing=0 path spec
  for spec in \
    'dsh-client-ui-conversation/lib/client.js|dsh-android: 普通回车换行|dsh-client-ui-conversation 回车补丁标记' \
    'dsh-tool-fs-search/lib/index.js|resolveSystemRg|dsh-tool-fs-search resolveSystemRg 回退' \
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
      ok "  [ok]   $label"
    else
      warn "  [warn] $label 未检测到锚点（$marker）。对应补丁可能需要更新锚点，或该功能已由上游原生实现。"
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
    ok "  [ok]   profile-boot 双信号强退语义（停止梯子前提）"
  else
    warn "  [warn] profile-boot 未检测到 interrupt/forceExitOnce（停止操作可能退化为等待 DSH_STOP_TIMEOUT 后兜底）。"
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
    ok "  [ok]   node-addon-require-builtin android 平台包（dsh 启动前提）"
  else
    warn "  [warn] node-addon-require-builtin android 平台包缺失，dsh 将无法启动（No usable native binding found）。"
  fi
  [ "$missing" -eq 0 ] && ok "  所有关键锚点均已就位" || true
}
anchor_precheck

# ---------------------------------------------------------------- 1/9 依赖
step "1/9 安装构建依赖"
run_hidden pkg update -y || true
run_hidden pkg install -y cmake clang make binutils pkg-config python nodejs ripgrep

command -v node >/dev/null 2>&1 || { warn "未检测到 node，正在重新安装 nodejs……"; run_hidden pkg install -y nodejs; }
NODE_VER="$(node -v | sed 's/^v//')"
info "Node.js v${NODE_VER}"

# 检测默认 npm / nodejs.org 太慢就切 npmmirror，仅本次会话生效，不改全局配置。
is_slow() {
  local url="$1" t
  t=$(curl -o /dev/null -s -w '%{time_total}' --max-time 6 "$url" 2>/dev/null)
  [ -z "$t" ] && return 0
  awk -v t="$t" 'BEGIN { exit !(t > 1.0) }'
}
if is_slow "https://registry.npmjs.org/-/ping"; then
  info "默认 npm 源响应较慢，本次运行切换至 npmmirror 镜像（registry.npmmirror.com）。"
  export npm_config_registry="https://registry.npmmirror.com"
fi
if is_slow "https://nodejs.org/dist/"; then
  info "nodejs.org 响应较慢，node-gyp 下载 Node headers 时切换至 npmmirror 镜像。"
  export npm_config_disturl="https://npmmirror.com/mirrors/node/"
fi

# ------------------------------------------------------- 2/9 准备 gyp 补丁
step "2/9 准备 Node headers"
# node-gyp 缓存的 common.gypi 引用了 android_ndk_path，Termux 无 NDK 必须补空定义，否则 node-pty 构建失败。
run_hidden_spinner "  正在下载 Node headers（约 1 分钟）……" timeout 300 npx --yes node-gyp install || true

GYP_GIPI="$HOME/.cache/node-gyp/$NODE_VER/include/node/common.gypi"
if [ -f "$GYP_GIPI" ]; then
  info "检查 common.gypi：Termux 无 NDK，需要补充 android_ndk_path 空定义，否则 node-pty 构建将失败。"
  # python 自己往终端打印，擦行字节必须由它一并写出（SP_CLEAR 已 export）：python3 启动约 40ms，
  # ticker 每 0.15s 重画一次，"先 status_clear 再 python 打印"会有约 1/4 概率把正文叠到状态行上。
  python3 - "$GYP_GIPI" <<'PY'
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
else
  warn "未检测到 $GYP_GIPI，请确认 node 已安装；可先手动执行一次 `npm i -g @deepseek-ai/dsh` 填充缓存。"
fi

# ------------------------------------------------- 2.5/9 pnpm 运行时供给
# dsh 0.2.1 起 plugin-manager / `dsh plugin …` 会 execa("pnpm")；这是运行期依赖，与安装方式无关。
pnpm_runtime_provision

# ------------------------------------------------------------- 3/9 正式安装
step "3/9 安装 dsh（预计耗时 5～15 分钟）"
# android30 仅是安全 no-op；绝不可加 --sysroot=$PREFIX 或切 -target aarch64-linux-gnu 上 glibc（会头/库/ABI 混用）。
# 真正需要编译的只有 node-pty（无 android-arm64 预编译），koffi 3.x 走预编译包。
# ⚠️ 手动 `npm -g update` 不经过本脚本，会丢掉这里的 CFLAGS/CXXFLAGS；koffi 3.1.1
# 回退本地编译会因 bionic 只在 API30 声明 statx() 而失败。手动 npm 请走 npm_android.sh。
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
EXTRA_FLAGS="-target aarch64-linux-android30 -I$PREFIX/include"
# --allow-scripts 的语义**随 npm 版本不同**（2.5/9 会探测并打印当前策略）：
#   npm 12：白名单内的包脚本【失败】→ 整次 npm install 退 1；白名单外 → 只警告并跳过（白名单是强制的）。
#   npm 11（本机 11.21.1）：白名单是【建议性】的——白名单外的脚本**仍会执行**、只打警告；
#     只有 `strict-allow-scripts=true` 才硬失败（ESTRICTALLOWSCRIPTS，会按安装冲突在预检里拒绝）。
#     本机实测：koffi 3.1.1 的 install 脚本因此真的执行并编译成功、可加载（koffi.load('libc.so') OK）。
# 所以 ALLOW_SCRIPTS 是「可用性风险面 + 完整性清单」：上游新增带构建脚本的包必须同步补进来，
# 否则 npm 12 下原生产物静默缺失、npm 11 下则会有未审批脚本被静默执行——下方的自检负责发现。
# ⚠️ SKIP_SCRIPTS 仍然保留：npm 12 下把 koffi 放进白名单会拖死整次安装；本机 npm 11 虽能编译，
#    但运行期 koffi 只在 win32 分支懒加载，Android 用不到。
# dsh 自身采用「hold + 暂存安装」：本节只把新版本装进临时 prefix，成功后整树移到
# $DSH_HOLD_DIR，并把全局 $DSH_DIR 换成 symlink。npm `update -g` 会把它当 file: 依赖，
# 因此不会升级/覆盖 dsh；升级只发生在重新运行 setup.sh 时。若用户另设了
# `ignore-scripts=true`，这里仍显式 `--ignore-scripts=false` 以完成 node-pty 构建。
ALLOW_SCRIPTS="@deepseek-ai/dsh-subprocess-local,node-pty,@google/genai,protobufjs"
# 按设计不进白名单的包（脚本必然失败或纯属多余，宁可让它退化成「npm 警告 + 跳过」）：
#   koffi —— 0.2.0-rc.2 起上游把它【精确钉在 3.1.1】，而 @koromix/koffi-android-arm64 从 3.2.1 才有；
#   3.1.1 的 install 脚本 `cnoke --prebuild` 自愈式回退到本地编译，必死在 bionic 与 glibc 的
#   statx 原型差异上（lib/native/base/base.cc）。实测 `npm install -g --allow-scripts=koffi koffi@3.1.1`
#   退出码 1 —— 白名单里留着它 = 安装必然中断。运行期它只在 win32 分支懒加载，Android 用不到。
SKIP_SCRIPTS="koffi"

# npm allow-scripts 策略探测：npm 11 默认 advisory（白名单建议性、白名单外脚本仍执行、只警告），
# npm 12 起白名单强制；用户显式 strict-allow-scripts=true 已在预检里当安装冲突拒绝，这里只报告。
case "${NPM_STRICT_ALLOW_SCRIPTS:-unknown}" in
  false) info "  npm allow-scripts 策略：advisory（npm 11 语义：白名单为建议性，白名单外脚本仍会执行；koffi 实测可编译）。" ;;
  *)     info "  npm allow-scripts 策略：${NPM_STRICT_ALLOW_SCRIPTS:-未探测到}（按 npm 默认 advisory 处理）。" ;;
esac
info "  安装目标：${DSH_NPM}（安装脚本白名单：${ALLOW_SCRIPTS}）"
DSH_STAGE_PREFIX="$DSH_HOLD_ROOT/.stage.$$"
rm -rf "$DSH_STAGE_PREFIX"
mkdir -p "$DSH_STAGE_PREFIX"
info "  暂存安装：$DSH_STAGE_PREFIX（成功后切换为 hold symlink，失败不影响现有 dsh）"
run_hidden_spinner "  正在安装 dsh 并编译原生模块（预计耗时 5～15 分钟）……" \
  env CFLAGS="$EXTRA_FLAGS" CXXFLAGS="$EXTRA_FLAGS" \
  "${NPM_CMD[@]}" install -g --prefix "$DSH_STAGE_PREFIX" --no-audit --no-fund --loglevel=error \
  --ignore-scripts=false --allow-scripts="$ALLOW_SCRIPTS" "$DSH_NPM"

DSH_STAGE_INSTALL="$DSH_STAGE_PREFIX/lib/node_modules/@deepseek-ai/dsh"
if [ ! -d "$DSH_STAGE_INSTALL" ]; then
  error "  暂存安装完成但未找到 dsh 安装树：$DSH_STAGE_INSTALL"
  exit 1
fi
dsh_hold_pin "$DSH_STAGE_INSTALL"
rm -rf "$DSH_STAGE_PREFIX"
DSH_STAGE_PREFIX=""

if [ -f "$DSH_DIR/node_modules/node-pty/build/Release/pty.node" ]; then
  ok "  node-pty 编译产物已就绪（build/Release/pty.node）"
else
  warn "  node-pty 原生产物缺失：node-gyp 编译失败（PTY 功能将不可用）。"
  warn "        请检查上方 node-pty 编译日志（常见原因：gyp 缓存未修补，或缺少 cmake、clang）；建议修复后重新运行本脚本。"
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
  info "  koffi 原生模块不可用（按设计跳过，不阻断）：上游 0.2.0-rc.2 指定的 3.1.1 无 android 预编译包，"
  info "  且其 install 脚本在 bionic 上编译必然失败；dsh 中 koffi 仅在 win32 分支懒加载，Android 不涉及。"
else
  warn "  koffi 原生模块不可用（不阻断）：上游 0.2.0-rc.2 将 koffi 精确钉在 3.1.1，而 @koromix/koffi-android-arm64"
  warn "  自 3.2.1 起才提供预编译包；3.1.1 的 install 脚本在 bionic 上编译必然失败，因此本脚本将其列入 SKIP_SCRIPTS，"
  warn "  由 npm 仅警告并跳过（列入白名单将导致整次安装返回 1）。dsh 中所有 koffi 调用点均为懒加载且 "
  warn "  仅在 platform === \"win32\" 时执行，Android 运行期不涉及；win32 场景才需要它。"
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
    warn "        处置：请将该包名加入本脚本的 ALLOW_SCRIPTS 后重新运行；若确认其构建在 Android 上必然失败（或运行期不涉及），"
    warn "        应改列入 SKIP_SCRIPTS（npm 仅警告、不中断），请勿放入 ALLOW_SCRIPTS；白名单内脚本失败将导致整次安装返回 1。"
  else
    warn "  安装脚本白名单自检执行异常（退出码 $rc）。"
  fi
fi

# ------------------------------------------------------- 4/9 后端兼容补丁
step "4/9 后端兼容补丁"

# 4-boot: 补 node-addon-require-builtin 的 android 平台包（dsh ≥0.1.7 启动前提）。
#     dsh-app-boot 的 internalModules() 无条件 require 该绑定，而上游只发布
#     darwin/linux-gnu/win32-msvc 预编译包，Termux 上解析不到 →
#     "No usable native binding found" → host preparation 失败、dsh 完全起不来。
#     按 loader 的「平台可选包」约定补一个纯 JS 实现（dsh 包装脚本必带
#     --expose-internals，require("internal/*") 直接可用，免 NDK 交叉编译）。
#     失败必须 exit 1（不能只 warn）：没有它 dsh 根本起不来，
#     与 4f 的 rg 同属「硬阻断」补丁。dsh <0.1.7 时脚本自身 SKIP（退 0）。
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

# 4d 作曲栏回车补丁：普通回车=换行，Ctrl/Cmd+Enter=发送（命中不了要回滚备份，避免静默失败）。
CB="$DSH_DIR/node_modules/@deepseek-ai/dsh-client-ui-conversation/lib/client.js"
CB_BAK="$CB.dsh-android.bak"
if grep -q "dsh-android: 普通回车换行" "$CB" 2>/dev/null; then
  rm -f "$CB_BAK" 2>/dev/null || true   # 已应用：清理历史/残留备份，避免反复升级累积
  ok "  client-ui-conversation 回车补丁已就位"
else
  cp -f "$CB" "$CB_BAK" 2>/dev/null || true
  if ! python3 - "$CB" <<'PY'
import os, sys
CLR = os.environ.get("SP_CLEAR", "")
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'dsh-android: 普通回车换行' in s:
    print(CLR + '  already patched'); sys.exit(0)
entry = 'if (event !== null && isComposingEvent(event, recentlyComposing)) return true;'
if s.count(entry) != 1:
    print(CLR + '  ERROR: 回车处理器入口锚点出现 %d 次，无法唯一配对。' % s.count(entry)); sys.exit(2)
i = s.index(entry)
line_end = s.index('\n', i)
indent = s[s.rindex('\n', 0, i) + 1:i]
if indent.strip():
    print(CLR + '  ERROR: 入口锚点前导非空白，缩进异常。'); sys.exit(2)
guard = (indent + '/* dsh-android: 普通回车换行，Ctrl/Cmd+Enter 发送 */\n'
       + indent + 'if (event?.ctrlKey !== true && event?.metaKey !== true) return false;\n')
s = s[:line_end + 1] + guard + s[line_end + 1:]
open(p, 'w', encoding='utf-8').write(s)
print(CLR + '  patched client-ui-conversation (Enter=newline, Ctrl+Enter=send)')
PY
  then
    rc=$?
    warn "  client-ui-conversation 回车补丁未生效（退出码 $rc），已回滚备份。"
    cp -f "$CB_BAK" "$CB" 2>/dev/null || true
    warn "  该补丁影响安卓输入法回车误发送，必须修复后方可正常使用。请人工核对锚点后重新运行 setup.sh。"
    exit 1
  else
    rm -f "$CB_BAK" 2>/dev/null || true   # 验证成功后才删除备份
    ok "  client-ui-conversation 回车补丁已应用"
  fi
fi

# 4f ripgrep 修复：npm install 会清空 node_modules，每次更新后都必须重跑（脚本幂等）。
# ⚠️ apply-rg-fix.sh 内部已把「锚点漂移」降级为非致命（软链本身即可让 @vscode/ripgrep 解析成功），
#    所以它非 0 退出只代表 resolveRgPath() 真解析不通（grep/glob 全废），此时必须中断。
RG_FIX="$SCRIPT_DIR/apply-rg-fix.sh"
if [ -f "$RG_FIX" ]; then
  info "4f/9 应用 grep/glob ripgrep 修复（dsh-rg-fix）"
  if run_hidden env DSH_ROOT="$DSH_DIR" bash "$RG_FIX"; then
    ok "  ripgrep 修复完成"
  else
    error "  ripgrep 修复失败：resolveRgPath() 实际解析不通过，grep/glob 将不可用（详见 $SETUP_LOG）。"
    exit 1
  fi
else
  warn "  缺少 apply-rg-fix.sh，已跳过 grep/glob ripgrep 修复。"
fi

# ------------------------------------------------------ 5/9 sharp wasm 回退
step "5/9 sharp WASM 回退"
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

# ------------------------------------------------------ 6/9 dsh 包装脚本
step "6/9 dsh 包装脚本"
# 6/9 重建 dsh 包装脚本（npm 会把 dsh 覆盖成指向 lib/bin.js 的符号链接，缺 --expose-internals）。
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

# ----------------------------------------------------- 7/9 启动/停止/重启脚本
step "7/9 启动/停止/重启脚本"
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

# -------------------------------------------------- 8/9 JS 性能补丁(可选)
# 属增强项：失败只警告、继续执行，避免留下半完成状态。
if [ -f "$SCRIPT_DIR/apply-js-patches.sh" ]; then
  step "8/9 JS 性能补丁"
  if run_hidden env DSH_PACKAGES_DIR="$DSH_DIR/node_modules/@deepseek-ai" bash "$SCRIPT_DIR/apply-js-patches.sh"; then
    ok "  JS 性能补丁完成"
  else
    warn "  apply-js-patches.sh 退出码非 0。请查看上方标 [FAIL] 的条目：可能为真实锚点失配（上游重构）或应用失败（[deprecated] 表示弃用围栏中的旧补丁，不属于问题）；不影响核心功能。"
    warn "       可单独重试：bash $SCRIPT_DIR/apply-js-patches.sh"
  fi
fi

# ---------------------------------------------------------------- 9/9 完成
ELAPSED="$(( $(date +%s) - START_TIME ))"
step "9/9 完成"
# 状态指示器到此为止：先擦掉常驻状态行，再打完成横幅，否则横幅会和它叠在同一行。
status_stop
printf '%s════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
printf '%s  安装完成%s\n' "$C_GREEN" "$C_RST"
printf '  耗时        ：%s\n' "$(printf '%d分%02d秒' $((ELAPSED / 60)) $((ELAPSED % 60)))"
printf '  日志        ：%s\n' "$SETUP_LOG"
printf '\n  后续操作\n'
printf '  1. 执行 bash ~/dsh/start_dsh.sh 启动服务\n'
printf '  2. 通过浏览器打开 http://127.0.0.1:3080\n'
printf '  3. 在 Web UI 的 Models 页面填写 DeepSeek API Key\n'
printf '  4. 执行 bash ~/dsh/stop_dsh.sh 停止服务\n'
printf '\n  注意事项\n'
printf '  - 服务仅监听 127.0.0.1（本机），不通过局域网暴露。\n'
printf '  - API Key 存储于 ~/.dsh/.credentials.yaml（权限 0600），不会写入日志。\n'
printf '  - danger-full-access 已关闭进程沙箱（Android 无替代方案），仅建议在个人设备使用。\n'
printf '  - 升级 dsh 或 Node 后，需要重新运行本脚本。\n'
printf '%s════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
