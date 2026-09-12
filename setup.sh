#!/data/data/com.termux/files/usr/bin/bash
# DeepSeek Harness 一键安装脚本（Android/Termux）：安装 @deepseek-ai/dsh 并打上全部 Android 兼容补丁（幂等，可反复重跑）。
# 用法：bash setup.sh [--verbose]；装完用 bash ~/dsh/start_dsh.sh 启动。
set -euo pipefail

# ---------------------------------------------------------------- 输出/日志
# 默认只输出摘要，原始命令输出写入 ~/dsh/setup.log；--verbose 可透传原始输出。
SETUP_LOG="$HOME/dsh/setup.log"
mkdir -p "$HOME/dsh"
: > "$SETUP_LOG"
START_TIME="$(date +%s)"

VERBOSE=0
if [ "${1:-}" = "--verbose" ] || [ "${SETUP_VERBOSE:-0}" = "1" ]; then
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
# 全脚本唯一的 EXIT trap：擦状态行 → 清理临时文件 → 失败时打印日志尾部。
# ⚠️ 必须写 tail -25 "$SETUP_LOG" >&2：重定向从左到右生效，2>/dev/null >&2 会把日志整个吞掉。
on_exit() {
  local rc=$?
  status_stop                 # 先擦掉常驻状态行，否则失败日志会叠在它上面
  if [ -n "$STATUS_FILE" ]; then rm -f "$STATUS_FILE" 2>/dev/null || true; fi
  if [ -n "$DSH_TMP" ]; then rm -f "$DSH_TMP" 2>/dev/null || true; fi
  if [ "$rc" -ne 0 ]; then
    printf '\n%s[x]%s 安装失败（退出码 %s），最近日志：\n' "$C_RED" "$C_RST" "$rc" >&2
    if [ -s "$SETUP_LOG" ]; then tail -25 "$SETUP_LOG" >&2; fi
  fi
}
trap on_exit EXIT
status_start   # 状态指示器从这里开始，一直显示到脚本结束（见末尾 status_stop）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # 脚本真实目录（脚本中段会 cd，须用绝对路径）
DSH_NPM="@deepseek-ai/dsh"
DSH_DIR="/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh"
INSTALL_DIR="$HOME/dsh"
# ⚠️ 一律用真实绝对路径 /data/data/com.termux/files/usr/bin：/usr 在部分命名空间不可解析（实测 No such file or directory）。
PREFIX_BIN="/data/data/com.termux/files/usr/bin"
DSH_CMD="$PREFIX_BIN/dsh"

# 0 锚点预检：升级重跑时先只读检查各补丁锚点是否还在，非致命。
anchor_precheck() {
  [ -d "$DSH_DIR/node_modules/@deepseek-ai" ] || return 0
  step "0/9 锚点预检"
  local missing=0 path spec
  for spec in \
    'dsh-client-ui-conversation/lib/client.js|dsh-android: 普通回车换行|dsh-client-ui-conversation 回车补丁标记' \
    'dsh-tool-fs-search/lib/index.js|resolveSystemRg|dsh-tool-fs-search resolveSystemRg 回退' \
    'dsh-session-persistence-jsonl/lib/index.js|publishNoReplaceNoHardlink|dsh-session-persistence 无硬链接迁移回退' \
    'dsh-attachment-local/lib/index.js|publishNoReplaceNoHardlink|dsh-attachment-local 无硬链接发布回退' \
    'dsh-fs-local/lib/index.js|publishNoReplaceNoHardlink|dsh-fs-local 无硬链接发布回退' \
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
      warn "  [warn] $label 未检测到锚点（$marker）。对应补丁可能需更新锚点或已由上游原生实现。"
      missing=$((missing+1))
    fi
  done
  [ "$missing" -eq 0 ] && ok "  所有关键锚点就位" || true
}
anchor_precheck

# ---------------------------------------------------------------- 1/9 依赖
step "1/9 安装构建依赖"
run_hidden pkg update -y || true
run_hidden pkg install -y cmake clang make binutils pkg-config python nodejs ripgrep

command -v node >/dev/null 2>&1 || { warn "node 未安装，重试安装 nodejs..."; run_hidden pkg install -y nodejs; }
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
  info "默认 npm 源较慢，自动切换到 npmmirror 镜像 (registry.npmmirror.com)"
  export npm_config_registry="https://registry.npmmirror.com"
fi
if is_slow "https://nodejs.org/dist/"; then
  info "nodejs.org 较慢，node-gyp 下载 Node headers 自动切换到 npmmirror 镜像"
  export npm_config_disturl="https://npmmirror.com/mirrors/node/"
fi

# ------------------------------------------------------- 2/9 准备 gyp 补丁
step "2/9 准备 Node headers"
# node-gyp 缓存的 common.gypi 引用了 android_ndk_path，Termux 无 NDK 必须补空定义，否则 node-pty 构建失败。
run_hidden_spinner "  正在下载 Node headers（约 1 分钟）..." timeout 300 npx --yes node-gyp install || true

GYP_GIPI="$HOME/.cache/node-gyp/$NODE_VER/include/node/common.gypi"
if [ -f "$GYP_GIPI" ]; then
  info "检查 common.gypi：Termux 无 NDK，需补 android_ndk_path 空定义（否则 node-pty 构建失败）"
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
    print(ECLR + "  [warn] common.gypi 未找到锚点 %s，跳过（node-pty 可能构建失败）" % ANCHOR, file=sys.stderr)
else:
    open(p, 'w', encoding='utf-8').write(s.replace(ANCHOR, "'variables': {\n    'android_ndk_path%': '',", 1))
    print(CLR + "  patched common.gypi")
PY
else
  warn "未找到 $GYP_GIPI，请确认 node 已安装；可先手动跑一次 `npm i -g @deepseek-ai/dsh` 填充缓存"
fi

# ------------------------------------------------------------- 3/9 正式安装
step "3/9 安装 dsh（可能 5~15 分钟）"
# android30 仅是安全 no-op；绝不可加 --sysroot=$PREFIX 或切 -target aarch64-linux-gnu 上 glibc（会头/库/ABI 混用）。
# 真正需要编译的只有 node-pty（无 android-arm64 预编译），koffi 3.x 走预编译包。
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
EXTRA_FLAGS="-target aarch64-linux-android30 -I$PREFIX/include"
run_hidden_spinner "  正在安装 dsh 和编译原生模块（5~15 分钟）..." \
  env CFLAGS="$EXTRA_FLAGS" CXXFLAGS="$EXTRA_FLAGS" \
  npm install -g --no-audit --no-fund --loglevel=error \
  --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs "$DSH_NPM"
if [ -f "$DSH_DIR/node_modules/node-pty/build/Release/pty.node" ]; then
  ok "  node-pty 编译产物就位 (build/Release/pty.node)"
else
  warn "  [!!] node-pty 原生产物缺失：node-gyp 编译失败（PTY 功能将不可用）"
  warn "       请检查上方 node-pty 编译日志（常见：gyp 缓存未修补或缺 cmake/clang）。建议修复后重跑本脚本。"
  exit 1
fi
if (cd "$DSH_DIR" && node -e "require('node-pty');" >/dev/null 2>&1); then
  ok "  node-pty 可加载"
else
  warn "  [!!] node-pty 产物无法加载（可能 ABI 不匹配），PTY 功能将不可用"
fi
if (cd "$DSH_DIR/node_modules/koffi" && node -e "try{require('koffi');}catch(e){process.exit(1)}" >/dev/null 2>&1); then
  ok "  koffi 预编译包可加载"
else
  warn "  koffi 预编译包无法加载（koffi 3.x 走 @koromix/koffi-*，无需本地编译）"
  warn "  若 dsh 在 win32 场景用到 koffi，对应功能会异常；请检查是否装了 @koromix/koffi-android-arm64。"
fi

# ------------------------------------------------------- 4/9 后端兼容补丁
step "4/9 后端兼容补丁"

# 4a 禁硬链接全链路修复（会话/附件发布、迁移、write 新建文件）；详见 patches/patch-dsh-android-link.js。
HLFIX="$SCRIPT_DIR/patches/patch-dsh-android-link.js"
if [ -f "$HLFIX" ]; then
  if run_hidden node "$HLFIX" --root "$DSH_DIR/node_modules/@deepseek-ai"; then
    ok "  android 硬链接修复完成（session / attachment / fs-local）"
  else
    warn "  硬链接修复脚本报告异常（dsh 版本不匹配？请人工检查）"
  fi
else
  warn "  缺少 patches/patch-dsh-android-link.js，跳过硬链接修复"
fi

# 4a-verify 必须等 sharp WASM 回退（step 5）之后再跑，否则附件测试 import sharp 失败会误报验证未通过。

# 4b flock 原生绑定：node-addon-system 无 Android 预编译包，用 clang 编译其 src/flock.c 成本机 system.node 供 lib/flock.js 加载。
FLOCKFIX="$SCRIPT_DIR/patches/patch-dsh-android-flock.js"
if [ -f "$FLOCKFIX" ]; then
  if run_hidden node "$FLOCKFIX" --root "$DSH_DIR/node_modules/@deepseek-ai"; then
    ok "  android flock 原生绑定完成（会话写锁可用）"
  else
    warn "  [!!] flock 修复脚本报告异常（发消息会失败，请人工检查）"
  fi
else
  warn "  缺少 patches/patch-dsh-android-flock.js，跳过 flock 修复"
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
    print(ECLR + "  [warn] 未找到 subprocess 终端检测锚点（dsh 版本漂移），终端功能可能不可用", file=sys.stderr)
    sys.exit(3)
PY
then
  ok "  subprocess-local 终端检测 android 视同 linux"
else
  rc=$?
  if [ "$rc" -eq 3 ]; then
    warn "  [!!] subprocess-local 终端检测补丁未命中锚点（dsh 版本漂移），终端功能可能不可用；请人工检查 $SP_LIB"
  else
    warn "  [!!] subprocess-local 补丁执行异常（退出码 $rc）"
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
    print(CLR + '  ERROR: 回车处理器入口锚点出现 %d 次，无法唯一配对' % s.count(entry)); sys.exit(2)
i = s.index(entry)
line_end = s.index('\n', i)
indent = s[s.rindex('\n', 0, i) + 1:i]
if indent.strip():
    print(CLR + '  ERROR: 入口锚点前导非空白，缩进异常'); sys.exit(2)
guard = (indent + '/* dsh-android: 普通回车换行，Ctrl/Cmd+Enter 发送 */\n'
       + indent + 'if (event?.ctrlKey !== true && event?.metaKey !== true) return false;\n')
s = s[:line_end + 1] + guard + s[line_end + 1:]
open(p, 'w', encoding='utf-8').write(s)
print(CLR + '  patched client-ui-conversation (Enter=newline, Ctrl+Enter=send)')
PY
  then
    rc=$?
    warn "  client-ui-conversation 回车补丁未生效（退出码 $rc），回滚备份"
    cp -f "$CB_BAK" "$CB" 2>/dev/null || true
    warn "  该补丁影响安卓输入法回车误发送，必须修复后才能正常使用。请人工核对锚点后重跑 setup.sh。"
    exit 1
  else
    rm -f "$CB_BAK" 2>/dev/null || true   # 验证成功后才删除备份
    ok "  client-ui-conversation 回车补丁已应用"
  fi
fi

# 4f ripgrep 修复：npm install 会清空 node_modules，每次更新后都必须重跑（脚本幂等，失败即中断 setup）。
RG_FIX="$SCRIPT_DIR/apply-rg-fix.sh"
if [ -f "$RG_FIX" ]; then
  info "4f/9 应用 grep/glob ripgrep 修复（dsh-rg-fix）"
  run_hidden bash "$RG_FIX"
  ok "  ripgrep 修复完成"
else
  warn "  缺少 apply-rg-fix.sh，跳过 grep/glob ripgrep 修复"
fi

# ------------------------------------------------------ 5/9 sharp wasm 回退
step "5/9 sharp WASM 回退"
SHARP_VER="$(node -e "console.log(require('$DSH_DIR/node_modules/sharp/package.json').version)" 2>/dev/null || true)"
WASM_VER="$(node -e "console.log(require('$DSH_DIR/node_modules/@img/sharp-wasm32/package.json').version)" 2>/dev/null || true)"
# 只看"目录在不在"会在 sharp 升级后残留旧 wasm 时报假成功（目录在、版本对不上、加载仍然失败）。
# 因此必须比对 wasm 自己的版本与当前 sharp 版本，一致才算就位。
if [ -n "$WASM_VER" ] && [ "$WASM_VER" = "$SHARP_VER" ]; then
  ok "  sharp-wasm32 已就位 (v$WASM_VER)"
elif [ -z "$SHARP_VER" ]; then
  # 读不到 sharp 版本就不能猜：装错版本的 wasm 比不装更糟（ABI/协议不匹配）。
  warn "  无法确定 sharp 版本（sharp 未安装？），跳过 sharp-wasm32 回退"
else
  if [ -n "$WASM_VER" ]; then
    warn "  sharp-wasm32 版本不匹配（wasm $WASM_VER ≠ sharp $SHARP_VER），重新安装"
  fi
  # 在临时目录里装 wasm 包，再拷进 dsh 的 node_modules。npm 输出写入 setup.log：
  # 早先把输出丢进 /dev/null，装失败时 set -e 只会抛一句无线索的"安装失败"，日志尾部也是空的。
  SWTMP="$(mktemp -d)"
  if ! ( cd "$SWTMP" && npm init -y >/dev/null 2>&1 && npm install "@img/sharp-wasm32@$SHARP_VER" ) >>"$SETUP_LOG" 2>&1; then
    rm -rf "$SWTMP"
    error "  sharp-wasm32@${SHARP_VER} 安装失败（原因见 $SETUP_LOG）。sharp 无 Android 原生包，缺 wasm 会让附件模块加载失败。"
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
    warn "  [!!] android 硬链接修复验证未通过，请人工检查对应补丁"
  fi
else
  warn "  缺少 patches/verify-android-link-fix.js，跳过硬链接修复验证"
fi

# ------------------------------------------------------ 6/9 dsh 包装脚本
step "6/9 dsh 包装脚本"
# 6/9 重建 dsh 包装脚本（npm 会把 dsh 覆盖成指向 lib/bin.js 的符号链接，缺 --expose-internals）。
# 用 mv -f 原子替换目录项本身，绝不 follow 链接目标、绝不先 rm；备份只备符号链接本身。
DSH_BIN="$DSH_DIR/lib/bin.js"
NODE_BIN="$PREFIX_BIN/node"
if [ ! -x "$NODE_BIN" ] || [ ! -f "$DSH_BIN" ]; then
  warn "  [!!] 未找到 node($NODE_BIN) 或 dsh bin.js($DSH_BIN)，跳过包装脚本重建，保留 $DSH_CMD"
else
  if [ -L "$DSH_CMD" ]; then
    # 这是 npm install -g 的正常产物（每次升级都会出现），不是错误，故用 info 而非 warn。
    info "  $DSH_CMD 被 npm 覆盖为符号链接（$(readlink "$DSH_CMD" 2>/dev/null || echo '?')），重建为独立包装脚本"
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
    warn "  [!!] 重建后的 dsh 不可用，回滚旧包装"
    if [ -e "$DSH_BACKUP" ] || [ -L "$DSH_BACKUP" ]; then
      rm -f "$DSH_CMD"
      if cp -P -f "$DSH_BACKUP" "$DSH_CMD" 2>/dev/null; then
        warn "  已回滚旧包装"
        rm -f "$DSH_BACKUP"
      else
        warn "  [!!] 回滚失败，保留备份供人工恢复: $DSH_BACKUP"
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
# ⚠️ 目标文件可能已有用户其它配置层：缺权限层时【追加】，绝不用 cat > 整体重写。
PROFILE_PATCH="$HOME/.dsh/profiles/web/cordis.patch.yml"
SANDBOX_LAYER_FILE="$SCRIPT_DIR/config/cordis.patch.yml"
if [ -f "$SANDBOX_LAYER_FILE" ]; then
  SANDBOX_LAYER="$(cat "$SANDBOX_LAYER_FILE")"
else
  warn "  缺少 $SANDBOX_LAYER_FILE，使用内联兜底权限层"
  SANDBOX_LAYER='- id: sandbox-policy
  config:
    mode: danger-full-access'
fi
mkdir -p "$(dirname "$PROFILE_PATCH")"
if ! grep -q "danger-full-access" "$PROFILE_PATCH" 2>/dev/null; then
  if [ -s "$PROFILE_PATCH" ]; then
    printf '\n%s\n' "$SANDBOX_LAYER" >> "$PROFILE_PATCH"
    ok "  权限模式已追加到 $PROFILE_PATCH（保留原有配置层）"
  else
    printf '%s\n' "$SANDBOX_LAYER" > "$PROFILE_PATCH"
    ok "  权限模式已写入 $PROFILE_PATCH"
  fi
fi

# -------------------------------------------------- 8/9 JS 性能补丁(可选)
# 属增强项：失败只警告、继续执行，避免留下半完成状态。
if [ -f "$SCRIPT_DIR/apply-js-patches.sh" ]; then
  step "8/9 JS 性能补丁"
  if run_hidden bash "$SCRIPT_DIR/apply-js-patches.sh"; then
    ok "  JS 性能补丁完成"
  else
    warn "  [!!] apply-js-patches.sh 退出码非 0。性能补丁可能部分未应用（多为 dsh 版本已原生实现），不影响核心功能。"
    warn "       可单独重试: bash $SCRIPT_DIR/apply-js-patches.sh"
  fi
fi

# ---------------------------------------------------------------- 9/9 完成
ELAPSED="$(( $(date +%s) - START_TIME ))"
step "9/9 完成"
# 状态指示器到此为止：先擦掉常驻状态行，再打完成横幅，否则横幅会和它叠在同一行。
status_stop
printf '%s════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
printf '%s  安装完成 ✅%s\n' "$C_GREEN" "$C_RST"
printf '  耗时        : %s\n' "$(printf '%d分%02d秒' $((ELAPSED / 60)) $((ELAPSED % 60)))"
printf '  日志        : %s\n' "$SETUP_LOG"
printf '\n  下一步\n'
printf '  1. bash ~/dsh/start_dsh.sh\n'
printf '  2. 打开 http://127.0.0.1:3080\n'
printf '  3. 在 Web UI 的 Models 页面填入 DeepSeek API Key\n'
printf '  4. 停止服务: bash ~/dsh/stop_dsh.sh\n'
printf '\n  注意\n'
printf '  - 服务只监听 127.0.0.1（本机），不走局域网。\n'
printf '  - API Key 存于 ~/.dsh/.credentials.yaml（0600 权限），不进日志。\n'
printf '  - danger-full-access 关闭了进程沙箱（Android 无替代），仅建议个人设备使用。\n'
printf '  - 升级 dsh 或 Node 后需重跑本脚本。\n'
printf '%s════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
