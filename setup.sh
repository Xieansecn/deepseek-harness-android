#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# DeepSeek Harness (dsh) 一键安装脚本 — Android / Termux
# -----------------------------------------------------------------------------
# 安装 @deepseek-ai/dsh 并在 Termux 上跑起来，自动完成全部 Android 兼容修复：
#   1. 安装构建依赖 (cmake/clang/make/binutils/pkg-config/python/nodejs/ripgrep)
#   2. node-gyp 下载 headers 并修补 common.gypi（修 node-pty 构建）
#   3. android30 目标 npm install -g + 校验原生产物（node-pty 必须编译；koffi 走预编译包）
#   4. 后端兼容：session/attachment 的 link→rename/无硬链接回退、fs-local 无硬链接回退、
#      android flock 原生绑定、subprocess android==linux、客户端回车补丁、ripgrep 修复
#   5. sharp wasm 回退（android-arm64 无原生预编译）
#   6. 重建 dsh 包装脚本（--expose-internals，HMR 必需）
#   7. 写入启动/停止脚本 + danger-full-access 权限配置
#   8. 前端移动端适配与 JS 性能补丁（可选，失败不中断）
#
# 用法：bash setup.sh ；之后：bash ~/dsh/start_dsh.sh
# =============================================================================
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
color() {
  [ "$USE_COLOR" -eq 1 ] && printf '\033[%sm' "$1" || true
}
info()  { status_clear; printf '%s==>%s %s\n' "$(color '1;34')" "$(color '0')" "$*"; status_render; }
ok()    { status_clear; printf '%s[v]%s %s\n' "$(color '1;32')" "$(color '0')" "$*"; status_render; }
warn()  { status_clear; printf '%s[!]%s %s\n' "$(color '1;33')" "$(color '0')" "$*"; status_render; }
error() { status_clear; printf '%s[x]%s %s\n' "$(color '1;31')" "$(color '0')" "$*" >&2; status_render; }
step()  {
  status_clear
  printf '\n%s━━ %s ━━%s\n' "$(color '1;36')" "$*" "$(color '0')"
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

# ------------------------------------------------------- 常驻状态指示器
# 从脚本开头一直显示到脚本结束（不是只在长命令期间才出现）：
#   [⠹] 3/10 安装 dsh · 已用 1分02秒
# 实现要点：
#   - 动画由后台 ticker 子 shell 负责，它每 0.15s 读一次 STATUS_FILE 里的文本并重画，
#     所以父 shell 更新状态只需写文件（子 shell 看不到父 shell 的变量更新）。
#   - 状态行常驻在"当前行"，任何正式输出前必须先 status_clear 擦掉它，打完再 status_render
#     补回，否则文字会互相覆盖。info/ok/warn/error/step 已全部按此包装。
#   - 只在 TTY 且非 --verbose 时启用；--verbose 要透传原始输出、非 TTY（重定向/日志）没有
#     光标控制，两者都退回"打印一行静态提示"的老行为。
#   - 耗时直接用 SECONDS：bash 子 shell 会继承并继续累加父 shell 的秒数（已实测）。
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
# 终端列数。取不到就用保守值 40（手机 Termux 竖屏常见宽度）。
# 必须先知道宽度再画：状态行一旦超过终端宽度就会自动折行，而 \r\033[K 只擦得掉当前行的
# 开头，折下去的那截擦不掉——6.7 帧/秒不停重画就会把屏幕一路往下刷（实测 40 列下 4 秒
# 滚屏 23 次，就是用户看到的"刷屏"）。
status_cols() {
  local c=""
  c="$(stty size 2>/dev/null | awk '{print $2}')" || true          # stdin 是终端时最省事
  if [ -z "$c" ]; then c="$(stty size 2>/dev/null </dev/tty | awk '{print $2}')" || true; fi
  # 取不到宽度（无控制终端）就按 30 列保守截断：宁可显示短一点，也绝不折行刷屏。
  # 注意 COLUMNS 不能当兜底——它不会导出给脚本子进程（实测 unset）。
  # 也不要把"过窄"的实测值改大（那等于主动制造折行），测到多少就按多少算。
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
  status_render
  (
    local chars=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 label cols budget maxchars stamp
    # 行内固定开销：'[X] '(4) + ' · '(3) + 时钟 'M:SS'(最长 5) + 安全余量 2 = 14 列
    local reserved=14
    cols="$(status_cols)"
    # 终端被旋转/缩放时内核发 SIGWINCH：bash 会在当前 sleep 结束后立刻跑 trap（≤0.15s），
    # 比等 3s 轮询快得多；下面的轮询只作为兜底。
    trap 'cols="$(status_cols)"' WINCH
    while :; do
      if [ $((i % 20)) -eq 0 ]; then cols="$(status_cols)"; fi   # 约每 3s 复查一次（终端可被旋转/缩放）
      label="$(cat "$STATUS_FILE" 2>/dev/null || true)"
      stamp="$(printf '%d:%02d' $((SECONDS / 60)) $((SECONDS % 60)))"
      budget=$((cols - reserved)); [ "$budget" -lt 6 ] && budget=6
      # 含非 ASCII（本脚本文案多为中文）时按 2 列/字符保守估算，宁可截短也绝不折行。
      # 判定用参数展开而不是 [[ == *[!-~]* ]]：后者在 [[ ]] 里是语法错误，而
      # 【[![:print:]]】在 UTF-8 locale 下会把中文当可打印字符，判不出来。
      if [ -n "${label//[ -~]/}" ]; then maxchars=$((budget / 2)); else maxchars=$budget; fi
      if [ "${#label}" -gt "$maxchars" ]; then label="${label:0:$((maxchars - 1))}…"; fi
      printf '\r\033[K%s[%s]%s %s %s· %s%s' \
        "$(color '1;36')" "${chars[$((i % 10))]}" "$(color '0')" \
        "$label" "$(color '2')" "$stamp" "$(color '0')"
      i=$((i + 1))
      sleep 0.15
    done
  ) &
  STATUS_PID=$!
}
# 停止并擦除状态行；幂等（正常结束与 on_exit 都会调用，第二次是空操作——
# 否则 EXIT trap 会在完成横幅之后又发一次擦行转义）。
status_stop() {
  [ "$STATUS_ON" -eq 1 ] || return 0
  STATUS_ON=0
  if [ -n "$STATUS_PID" ]; then
    kill "$STATUS_PID" 2>/dev/null || true
    wait "$STATUS_PID" 2>/dev/null || true
    STATUS_PID=""
  fi
  printf '\r\033[K'
}
# 长时间命令：状态行常驻时只改文案（动画交给常驻 ticker，避免两个 spinner 抢同一行），
# 非 TTY / --verbose 时退回一行静态提示。
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
    # 标签本身已经带省略号（"正在安装…..."），这里直接原样打印，别再加一个变成"......"
    printf '%s\n' "$label"
  fi
  run_hidden "$@"
}

# 包装脚本临时文件（6/10 赋值）。由 on_exit 统一清理——这样 6/10 不需要再注册一个
# EXIT trap 去覆盖它（早先版本在 6/10 用 `trap 'rm -f "$DSH_TMP"' EXIT` 覆盖了本 trap，
# 导致其后所有步骤失败时不再打印日志尾部）。
DSH_TMP=""
on_exit() {
  local rc=$?
  status_stop                 # 先擦掉常驻状态行，否则失败日志会叠在它上面
  if [ -n "$STATUS_FILE" ]; then rm -f "$STATUS_FILE" 2>/dev/null || true; fi
  if [ -n "$DSH_TMP" ]; then rm -f "$DSH_TMP" 2>/dev/null || true; fi
  if [ "$rc" -ne 0 ]; then
    printf '\n%s[x]%s 安装失败（退出码 %s），最近日志：\n' "$(color '1;31')" "$(color '0')" "$rc" >&2
    # ⚠️ 不能写 `tail ... 2>/dev/null >&2`：重定向从左到右生效，`2>/dev/null` 先把 stderr
    # 指向 /dev/null，`>&2` 再把 stdout 复制成同一个 /dev/null，日志尾部会被整个吞掉
    # （实测过：横幅照常打印、"最近日志："后面永远是空的）。
    if [ -s "$SETUP_LOG" ]; then tail -25 "$SETUP_LOG" >&2; fi
  fi
}
trap on_exit EXIT
status_start   # 状态指示器从这里开始，一直显示到脚本结束（见末尾 status_stop）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # 脚本真实目录（脚本中段会 cd，须用绝对路径）
DSH_NPM="@deepseek-ai/dsh"
DSH_DIR="/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh"
INSTALL_DIR="$HOME/dsh"
# Termux 真实的 bin 目录绝对路径。注意：不要用 "/usr/bin/..." —— /usr 在某些 shell /
# 挂载命名空间不可解析（实测 /usr/bin 报 No such file or directory），而
# /data/data/com.termux/files/usr/bin 才是真正的 bin 目录，稳定可写。
PREFIX_BIN="/data/data/com.termux/files/usr/bin"
DSH_CMD="$PREFIX_BIN/dsh"

# ---------------------------------------------------------------- 0 锚点预检（升级场景）
# 只读检查当前已装 dsh 里各版本敏感锚点是否存在，给出醒目提示。
# 用于「升级 dsh 后重跑 setup.sh」：若锚点已漂移，可在漫长安装前先告知，
# 避免装完才发现某个补丁没打上。非致命——真正的中断判定在各修补点各自完成
# （node-pty 缺失 exit 1、入口补丁未命中 exit 1、rg 修复失败 exit 1）。
# 全新安装（尚无已装 dsh）时不检测，直接跳过。
anchor_precheck() {
  [ -d "$DSH_DIR/node_modules/@deepseek-ai" ] || return 0
  step "0/10 锚点预检"
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
    # path 支持通配（0.1.5-rc.1 起 subprocess 锚点在内容哈希 bundle：runner-launch-*.js）。
    # 注意 marker 内不可含 "|"（会与上面的分隔符冲突）。
    local hit=0 g
    # 注意："$DSH_DIR/..." 保持引号，$path 故意不加引号以便通配展开。
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

# ---------------------------------------------------------------- 1/10 依赖
step "1/10 安装构建依赖"
run_hidden pkg update -y || true
run_hidden pkg install -y cmake clang make binutils pkg-config python nodejs ripgrep

command -v node >/dev/null 2>&1 || { warn "node 未安装，重试安装 nodejs..."; run_hidden pkg install -y nodejs; }
NODE_VER="$(node -v | sed 's/^v//')"
info "Node.js v${NODE_VER}"

# --------------------------------------------------- 智能换源（国内用户友好）
# 检测默认 npm / nodejs.org 是否太慢，慢则自动切换到 npmmirror 镜像。
# 仅通过环境变量作用于本次安装会话，不改动全局 npm 配置。
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

# ------------------------------------------------------- 2/10 准备 gyp 补丁
step "2/10 准备 Node headers"
# node-gyp 首次构建会把 node headers 解压到缓存，其中 common.gypi 引用了
# android_ndk_path 变量；Termux 无 NDK 该变量未定义 → 必须修补缓存文件。
# 这里用 `node-gyp install` 只下载 headers（远快于整树 npm install），随后打补丁。
# 若此处卡住：多为网络问题，检查能否访问 nodejs.org；超时 300s 后自动跳过并告警。
run_hidden_spinner "  正在下载 Node headers（约 1 分钟）..." timeout 300 npx --yes node-gyp install || true

GYP_GIPI="$HOME/.cache/node-gyp/$NODE_VER/include/node/common.gypi"
if [ -f "$GYP_GIPI" ]; then
  info "修补 common.gypi: 定义 android_ndk_path 为空（修 node-pty 的 Undefined variable 错误）"
  status_clear   # 下面 python 直接往终端打印，先擦掉常驻状态行免得两行文字叠在一起
  python3 - "$GYP_GIPI" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if "'android_ndk_path%': ''" not in s:
    s = s.replace("'variables': {", "'variables': {\n    'android_ndk_path%': '',", 1)
    open(p, 'w', encoding='utf-8').write(s)
print("  patched common.gypi")
PY
else
  warn "未找到 $GYP_GIPI，请确认 node 已安装；可先手动跑一次 `npm i -g @deepseek-ai/dsh` 填充缓存"
fi

# ------------------------------------------------------------- 3/10 正式安装
step "3/10 安装 dsh（可能 5~15 分钟）"
# -target aarch64-linux-android30 在标准 Termux（纯 bionic、无 NDK）下仅是安全 no-op
# （数字只改 __ANDROID_MIN_SDK_VERSION__ 宏）。绝不可加 --sysroot=$PREFIX 或
# -target aarch64-linux-gnu 切 glibc（会引入 /usr/glibc/include 造成头/库/ABI 混用）。
# 真正需 node-gyp 编译的只有 node-pty（无 android-arm64 预编译）；koffi 3.x 走预编译包。
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

# ------------------------------------------------------- 4/10 后端兼容补丁
step "4/10 后端兼容补丁"

# 4a: Android 禁 hardlink 全链路修复（会话发布/迁移、附件发布/别名、write 新建文件）。
#     会话日志【直接发布】改 rename()；所有 no-replace 语义的 link 发布在
#     EACCES/EPERM/EMLINK/ENOSYS/ENOTSUP 时回退到“O_EXCL 占位 + rename 填充”。
#     幂等；已验证 dsh 0.1.5-rc.1，向下兼容 rc.6/rc.7。详见 patches/patch-dsh-android-link.js
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

# 4a-verify 不在这里跑：它要等到 sharp WASM 回退（下面 step 5/10）之后。
# 原因：验证脚本的附件测试会 import dsh-attachment-local，而该模块在加载时 import sharp；
# npm install 会清空 node_modules，sharp 在 step 5 之前必然加载失败，于是每次全新安装/升级
# 都会打出"硬链接修复验证未通过"的假失败。见 step 5/10 之后的 verify 段。

# 4b: Android flock 原生绑定（修发消息时 "flock is not supported on android-arm64"）。
#     node-addon-system 无 Android 预编译包，用 clang 编译其自带 src/flock.c 成本机
#     system.node，并让 lib/flock.js 在 android 下加载本地绑定；幂等，含真实加锁自检。
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

# 4c: subprocess 终端检测 android 视同 linux
# 注意：0.1.5-rc.1 起 createProcessInspector() 被内联进【内容哈希 bundle】
# （lib/runner-launch-*.js），锚点已不在 lib/index.js。因此按通配扫描整个 lib 目录，
# 命中才报成功；未命中明确告警（而非像早先那样无条件打印"已修补"的假成功）。
SP_LIB="$DSH_DIR/node_modules/@deepseek-ai/dsh-subprocess-local/lib"
status_clear   # python 的 patched/[skip]/[warn] 直接写终端，先擦掉常驻状态行
if python3 - "$SP_LIB" <<'PY'
import glob, os, sys
lib = sys.argv[1]
anchor = 'if (platform === "linux") return new LinuxProcessInspector(arch, internals);'
patched = 'if (platform === "linux" || platform === "android") return new LinuxProcessInspector(arch, internals);'
files = sorted(glob.glob(os.path.join(lib, "*.js")))
if any(patched in open(f, encoding="utf-8").read() for f in files):
    print("  [skip] subprocess 终端检测已是 android≡linux")
    sys.exit(0)
hits = 0
for f in files:
    s = open(f, encoding="utf-8").read()
    if anchor in s:
        open(f, "w", encoding="utf-8").write(s.replace(anchor, patched))
        print("  patched %s (android→linux)" % os.path.basename(f))
        hits += 1
if hits == 0:
    print("  [warn] 未找到 subprocess 终端检测锚点（dsh 版本漂移），终端功能可能不可用", file=sys.stderr)
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

# 4d: 作曲栏回车补丁——安卓输入法回车误发送，改为"普通回车=换行，Ctrl/Cmd+Enter=发送"。
# 锚点取 registerComposerKeymap 的 ENTER 处理器开头"composing-check 行"（版本稳定、唯一）。
# 命中即失败并回滚备份，避免静默失败。
CB="$DSH_DIR/node_modules/@deepseek-ai/dsh-client-ui-conversation/lib/client.js"
CB_BAK="$CB.dsh-android.bak"
if grep -q "dsh-android: 普通回车换行" "$CB" 2>/dev/null; then
  rm -f "$CB_BAK" 2>/dev/null || true   # 已应用：清理历史/残留备份，避免反复升级累积
  ok "  client-ui-conversation 回车补丁已就位"
else
  cp -f "$CB" "$CB_BAK" 2>/dev/null || true
  status_clear   # python 的 patched/ERROR 直接写终端，先擦掉常驻状态行
  if ! python3 - "$CB" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'dsh-android: 普通回车换行' in s:
    print('  already patched'); sys.exit(0)
entry = 'if (event !== null && isComposingEvent(event, recentlyComposing)) return true;'
if s.count(entry) != 1:
    print('  ERROR: 回车处理器入口锚点出现 %d 次，无法唯一配对' % s.count(entry)); sys.exit(2)
i = s.index(entry)
line_end = s.index('\n', i)
indent = s[s.rindex('\n', 0, i) + 1:i]
if indent.strip():
    print('  ERROR: 入口锚点前导非空白，缩进异常'); sys.exit(2)
guard = (indent + '/* dsh-android: 普通回车换行，Ctrl/Cmd+Enter 发送 */\n'
       + indent + 'if (event?.ctrlKey !== true && event?.metaKey !== true) return false;\n')
s = s[:line_end + 1] + guard + s[line_end + 1:]
open(p, 'w', encoding='utf-8').write(s)
print('  patched client-ui-conversation (Enter=newline, Ctrl+Enter=send)')
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

# 4f: grep/glob ripgrep 修复（dsh-rg-fix）
# npm install 会清空 dsh 的 node_modules，@vscode/ripgrep 的 Android 平台包
# 在 Termux 上本来就不存在；每次 setup.sh 更新 dsh 后都必须重新应用：
#   1) @vscode/ripgrep-android-arm64/bin/rg -> 系统 rg
#   2) dsh-tool-fs-search resolveRgPath() 回退到系统 rg
# 脚本幂等，可重复执行；若中途失败会中断 setup（避免带病启动）。
RG_FIX="$SCRIPT_DIR/apply-rg-fix.sh"
if [ -f "$RG_FIX" ]; then
  info "4f/10 应用 grep/glob ripgrep 修复（dsh-rg-fix）"
  run_hidden bash "$RG_FIX"
  ok "  ripgrep 修复完成"
else
  warn "  缺少 apply-rg-fix.sh，跳过 grep/glob ripgrep 修复"
fi

# ------------------------------------------------------ 5/10 sharp wasm 回退
step "5/10 sharp WASM 回退"
SHARP_VER="$(node -e "console.log(require('$DSH_DIR/node_modules/sharp/package.json').version)" 2>/dev/null || true)"
if [ -d "$DSH_DIR/node_modules/@img/sharp-wasm32" ]; then
  ok "  sharp-wasm32 已就位 (v${SHARP_VER:-未知})"
elif [ -z "$SHARP_VER" ]; then
  # 读不到 sharp 版本就不能猜：装错版本的 wasm 比不装更糟（ABI/协议不匹配）。
  warn "  无法确定 sharp 版本（sharp 未安装？），跳过 sharp-wasm32 回退"
else
  # 在临时目录里装 wasm 包，再拷进 dsh 的 node_modules。npm 输出写入 setup.log：
  # 早先把输出丢进 /dev/null，装失败时 set -e 只会抛一句无线索的"安装失败"，日志尾部也是空的。
  SWTMP="$(mktemp -d)"
  if ! ( cd "$SWTMP" && npm init -y >/dev/null 2>&1 && npm install "@img/sharp-wasm32@$SHARP_VER" ) >>"$SETUP_LOG" 2>&1; then
    rm -rf "$SWTMP"
    error "  sharp-wasm32@${SHARP_VER} 安装失败（原因见 $SETUP_LOG）。sharp 无 Android 原生包，缺 wasm 会让附件模块加载失败。"
    exit 1
  fi
  mkdir -p "$DSH_DIR/node_modules/@img"
  cp -r "$SWTMP/node_modules/@img/sharp-wasm32" "$DSH_DIR/node_modules/@img/"
  # @emnapi/runtime 是 sharp-wasm32 的运行时依赖，缺它 wasm 加载即失败——这里的错误不能吞。
  cp -r "$SWTMP/node_modules/@emnapi" "$DSH_DIR/node_modules/"
  rm -rf "$SWTMP"
  ok "  sharp-wasm32@${SHARP_VER} 已安装"
fi

# 4a-verify: 快速验证 link→rename / no-replace 回退补丁确实就位。
# 只做静态检查和临时目录写入测试，不触碰 ~/.dsh/sessions，不破坏现有会话。
# ⚠️ 必须放在 sharp WASM 回退之后：验证脚本的附件测试会 import dsh-attachment-local，
# 而它 import sharp；sharp 不可加载时该测试必然抛 Could not load the "sharp" module，
# 变成每次安装/升级都误报"硬链接修复验证未通过"的假失败。
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

# ------------------------------------------------------ 6/10 dsh 包装脚本
step "6/10 dsh 包装脚本"
# 背景：@deepseek-ai/dsh 包声明 "bin":{"dsh":"lib/bin.js"}，npm install -g 会把
# $DSH_CMD 覆盖成【符号链接】指向 lib/bin.js；而 lib/bin.js 的 shebang 是
# #!/usr/bin/env node，且缺 --expose-internals（HMR 必需）。所以必须重建为
# "exec node --expose-internals --no-warnings <abs bin.js> "$@"" 的 sh 包装。
# 防破坏要点：
#   - 写目标一律用【真实绝对路径】$DSH_CMD，绝不用 /usr/bin/dsh（/usr 不可靠）。
#   - 用 mv -f 原子替换 $DSH_CMD 这一目录项本身，绝不 follow 其目标、绝不先 rm
#     制造 dsh 命令丢失窗口。
#   - 重建前备份【符号链接本身】而非其目标，失败可精确回滚。
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
  # 原子替换：mv -f 用 rename(2) 替换 $DSH_CMD 这一目录项本身（无论它是正则文件还是符号链接），
  # 不 follow 其目标、不触碰 lib/bin.js。因此【不需要】先 rm——先 rm 反而制造了"断电/磁盘满时
  # dsh 命令丢失"的非原子窗口。临时文件由 trap 清理；备份只在验证成功后才删除。
  # 临时文件由函数顶部的 on_exit（EXIT trap）统一清理，此处不再注册 trap。
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

# ----------------------------------------------------- 7/10 启动/停止/重启脚本
step "7/10 启动/停止/重启脚本"
mkdir -p "$INSTALL_DIR/storage"
cp "$SCRIPT_DIR/start_dsh.sh"         "$INSTALL_DIR/start_dsh.sh"
cp "$SCRIPT_DIR/stop_dsh.sh"          "$INSTALL_DIR/stop_dsh.sh"
cp "$SCRIPT_DIR/restart_dsh_now.sh"   "$INSTALL_DIR/restart_dsh_now.sh"
chmod +x "$INSTALL_DIR/start_dsh.sh" "$INSTALL_DIR/stop_dsh.sh" "$INSTALL_DIR/restart_dsh_now.sh"

# 权限模式：Android 上 bwrap/landlock 命名空间沙箱不可用，bash 工具需
# danger-full-access 才能执行。写入 profile 配置层 + 启动脚本环境变量双保险。
# 配置层文本取自仓库内的 config/cordis.patch.yml（唯一来源，勿在此处重复维护）。
# ⚠️ 目标文件可能含用户自己的其它配置层（approval、session-query-sqlite 等）：
# 缺失时【追加】一层，绝不用 `cat >` 整体重写（那会静默清掉用户的配置）。
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

# ------------------------------------------------------- 8/10 前端适配(可选)
# 前端适配与 JS 性能补丁属于「增强」而非「必需」，失败不应中断已可用的 dsh。
# 因此这里捕获返回值并醒目警告，但【继续执行】到完成横幅——避免因可选修补失败
# 而让 setup 中断在半途（那才会留下更糟的半完成状态）。真正核心的失败
# （node-pty 缺失、入口补丁未命中、rg 修复失败）已在前面用 exit 1 拦截。
if [ -f "$SCRIPT_DIR/apply-frontend.sh" ]; then
  step "8/10 前端移动端适配"
  if run_hidden bash "$SCRIPT_DIR/apply-frontend.sh"; then
    ok "  前端移动端适配完成"
  else
    warn "  [!!] apply-frontend.sh 退出码非 0。前端移动端适配可能未完全生效，但不影响 dsh 核心功能。"
    warn "       如需重试，请单独运行: bash $SCRIPT_DIR/apply-frontend.sh"
  fi
fi

# -------------------------------------------------- 9/10 JS 性能补丁(可选)
if [ -f "$SCRIPT_DIR/apply-js-patches.sh" ]; then
  step "9/10 JS 性能补丁"
  if run_hidden bash "$SCRIPT_DIR/apply-js-patches.sh"; then
    ok "  JS 性能补丁完成"
  else
    warn "  [!!] apply-js-patches.sh 退出码非 0。性能补丁可能部分未应用（多为 dsh 版本已原生实现），不影响核心功能。"
    warn "       可单独重试: bash $SCRIPT_DIR/apply-js-patches.sh"
  fi
fi

# ---------------------------------------------------------------- 10/10 完成
ELAPSED="$(( $(date +%s) - START_TIME ))"
step "10/10 完成"
# 状态指示器到此为止：先擦掉常驻状态行，再打完成横幅，否则横幅会和它叠在同一行。
status_stop
printf '%s════════════════════════════════════════%s\n' "$(color '1;36')" "$(color '0')"
printf '%s  安装完成 ✅%s\n' "$(color '1;32')" "$(color '0')"
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
printf '%s════════════════════════════════════════%s\n' "$(color '1;36')" "$(color '0')"
