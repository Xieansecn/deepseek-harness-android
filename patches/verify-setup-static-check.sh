#!/data/data/com.termux/files/usr/bin/bash
# setup.sh 与运行期脚本的**静态契约检查**（只读，不跑 setup.sh、不动安装树）。
#
# 为什么需要它：setup.sh 是整条流水线，跑一次要 5~15 分钟且会动全局安装，不适合当回归测试。
# 但它的关键契约（锚点规格、npm 包装、包装脚本原子替换、脚本白名单覆盖、运行期脚本的端口与退出码）
# 都可以只读地钉住——这些正是历史上真出过问题的地方。
#
# 用法：bash patches/verify-setup-static-check.sh
# 退出码：0 = 全部通过；1 = 有失败（逐条打印）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
DSH_DIR="${DSH_DIR:-/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh}"
PKGS="$DSH_DIR/node_modules/@deepseek-ai"
PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [OK]   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1${2:+ —— $2}"; }
chk()  { if [ "$1" = 1 ]; then ok "$2"; else bad "$2" "${3:-}"; fi; }

echo "== setup.sh 静态契约 =="
bash -n "$REPO/setup.sh" 2>/dev/null && chk 1 "setup.sh 语法（bash -n）" || chk 0 "setup.sh 语法（bash -n）"

# 1) 0/9 锚点预检：7 条规格，每条 3 个字段；link 三条必须用「打完补丁才出现」的函数定义串，
#    裸标识符会被「仅含一句注释的半成品」命中（历史缺陷）。
SPEC_COUNT="$(grep -cE "^ *'[^']+\|[^']+\|[^']+'( \\\\|; do)" "$REPO/setup.sh")"
chk "$([ "$SPEC_COUNT" = 7 ] && echo 1 || echo 0)" "0/9 预检规格 7 条（实际 $SPEC_COUNT）"
BARE_ID="$(grep -cE "^ *'dsh-(session-persistence-jsonl|attachment-local|fs-local)/lib/index\.js\|publishNoReplaceNoHardlink\|" "$REPO/setup.sh")"
chk "$([ "$BARE_ID" = 0 ] && echo 1 || echo 0)" "link 预检 marker 不用裸标识符（裸标识符条数 $BARE_ID 应为 0）"
FN_MARK="$(grep -cF 'lib/index.js|async function publishNoReplaceNoHardlink(|' "$REPO/setup.sh")"
chk "$([ "$FN_MARK" = 3 ] && echo 1 || echo 0)" "link 预检 marker 用函数定义串（命中 $FN_MARK/3）"

# 2) npm 必须走 node <npm-cli.js> 包装（Termux 的 /usr/bin/env 不可解析），且不出现裸 npm 调用。
grep -q 'NPM_CMD=(node "\$NPM_REAL")' "$REPO/setup.sh" && chk 1 "npm 走 node 包装（NPM_CMD）" || chk 0 "npm 走 node 包装（NPM_CMD）"
BARE_NPM="$(grep -cE '^[^#"'"'"']*npm (install|i )' "$REPO/setup.sh")"
chk "$([ "$BARE_NPM" = 0 ] && echo 1 || echo 0)" "没有裸 npm 调用（$BARE_NPM 处）"

# 2b) 手动 npm 调用的 Android 编译包装：`npm -g update` 不经过 setup.sh，
#     若没有 -target aarch64-linux-android30，koffi 会在 statx 处编译失败。
chk "$([ -x "$REPO/npm_android.sh" ] && echo 1 || echo 0)" "npm_android.sh 存在且可执行"
grep -q -- '-target aarch64-linux-android30' "$REPO/npm_android.sh" && chk 1 "npm_android.sh 注入 android30 target" || chk 0 "npm_android.sh 注入 android30 target"
grep -q 'android_compile_flags' "$REPO/npm_android.sh" && grep -q 'CXXFLAGS=' "$REPO/npm_android.sh" && chk 1 "npm_android.sh 同时包装 CFLAGS/CXXFLAGS" || chk 0 "npm_android.sh 同时包装 CFLAGS/CXXFLAGS"

# 2c) 原生安装布局（2026-11 起移除 hold/pin）：dsh 必须直接装进 npm 默认全局目录（真实目录），
#     旧版 hold symlink 在安装前摘除；npm 重建 bin link 前必须把 setup.sh 自己的包装脚本移开。
HOLD_REFS="$(grep -cE 'DSH_HOLD|dsh_hold_pin|DSH_STAGE_PREFIX' "$REPO/setup.sh")"
chk "$([ "$HOLD_REFS" = 0 ] && echo 1 || echo 0)" "setup.sh 已移除 hold/pin 机制（残留 $HOLD_REFS 处）"
grep -qxF 'DSH_DIR="/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh"' "$REPO/setup.sh" && chk 1 "dsh 目标是 npm 默认全局目录" || chk 0 "dsh 目标是 npm 默认全局目录"
grep -qF '"${NPM_CMD[@]}" install -g ' "$REPO/setup.sh" && chk 1 "3/9 直接 npm install -g（无暂存前缀）" || chk 0 "3/9 直接 npm install -g（无暂存前缀）"
grep -qF 'if [ -L "$DSH_DIR" ]; then' "$REPO/setup.sh" && chk 1 "安装前摘除旧 hold symlink" || chk 0 "安装前摘除旧 hold symlink"
grep -qF 'DSH_CMD_PREINSTALL_BAK=' "$REPO/setup.sh" && chk 1 "安装前移开 dsh 包装（避免 npm bin link EEXIST）" || chk 0 "安装前移开 dsh 包装（避免 npm bin link EEXIST）"
grep -qF '仍是符号链接' "$REPO/setup.sh" && chk 1 "安装后断言全局 dsh 是真实目录" || chk 0 "安装后断言全局 dsh 是真实目录"
grep -q -- '--ignore-scripts=false' "$REPO/setup.sh" && chk 1 "setup.sh 在 dsh 安装上显式恢复脚本执行" || chk 0 "setup.sh 在 dsh 安装上显式恢复脚本执行"
grep -q -- '--allow-scripts="\$ALLOW_SCRIPTS"' "$REPO/setup.sh" && chk 1 "恢复脚本执行仍受 --allow-scripts 白名单约束" || chk 0 "恢复脚本执行仍受 --allow-scripts 白名单约束"

# 2d) 提示文本里不得出现反引号：bash 会把双引号内的 `cmd` 当**命令替换真的执行**。
#     历史缺陷：2/9 的 warn 写过 `npm i -g @deepseek-ai/dsh`，安装中途偷偷重装了一次未打补丁的
#     dsh（实测报 EEXIST，且把「手动执行命令」提示变成空串）。这类回归只有真跑才暴露，必须静态钉住。
BACKTICK_CMD="$(grep -cE '(^|[^#])(info|ok|warn|error|step) +"[^"]*`' "$REPO/setup.sh")"
chk "$([ "$BACKTICK_CMD" = 0 ] && echo 1 || echo 0)" "提示文本里没有反引号命令替换（$BACKTICK_CMD 处）"

# 3) dsh 命令文件必须原子替换（临时文件 + mv -f），绝不 cat > 覆盖符号链接、也绝不先 rm。
grep -q 'mv -f "\$DSH_TMP" "\$DSH_CMD"' "$REPO/setup.sh" && chk 1 "dsh 包装脚本用 mv -f 原子替换" || chk 0 "dsh 包装脚本用 mv -f 原子替换"
grep -qE 'cat *> *"\$DSH_CMD"' "$REPO/setup.sh" && chk 0 "没有 cat > 覆盖 dsh 命令文件" || chk 1 "没有 cat > 覆盖 dsh 命令文件"
# 「先 rm」才是禁止的：rm 必须出现在 mv -f 原子替换**之后**（回滚路径）或干脆不存在。
RM_LINE="$(grep -nE 'rm -f "\$DSH_CMD"' "$REPO/setup.sh" | head -1 | cut -d: -f1)"
MV_LINE="$(grep -nE 'mv -f "\$DSH_TMP" "\$DSH_CMD"' "$REPO/setup.sh" | head -1 | cut -d: -f1)"
if [ -z "$RM_LINE" ] || [ -n "$MV_LINE" ] && [ "$RM_LINE" -gt "$MV_LINE" ]; then chk 1 "没有「先 rm 后写」dsh 命令文件（rm 在 mv 之后或不存在）"
else chk 0 "没有「先 rm 后写」dsh 命令文件" "rm@${RM_LINE:-?} mv@${MV_LINE:-?}"; fi
grep -q -- '--expose-internals' "$REPO/setup.sh" && chk 1 "包装脚本带 --expose-internals" || chk 0 "包装脚本带 --expose-internals"
grep -q 'PREFIX_BIN="/data/data/com.termux/files/usr/bin"' "$REPO/setup.sh" && chk 1 "dsh 路径用 Termux 绝对路径（不用 /usr/bin）" || chk 0 "dsh 路径用 Termux 绝对路径（不用 /usr/bin）"

# 4) 脚本白名单覆盖：安装树里所有带 install 脚本的包都必须在 ALLOW 或 SKIP 名单里。
if [ -d "$PKGS" ]; then
  ALLOW="$(sed -n 's/^ALLOW_SCRIPTS="\(.*\)"$/\1/p' "$REPO/setup.sh" | head -1)"
  SKIP="$(sed -n 's/^SKIP_SCRIPTS="\(.*\)"$/\1/p' "$REPO/setup.sh" | head -1)"
  UNCOVERED=""
  for pj in "$PKGS"/*/package.json "$DSH_DIR"/node_modules/*/package.json; do
    [ -f "$pj" ] || continue
    if grep -qE '"(pre|post)?install"[[:space:]]*:' "$pj"; then
      name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pj" | head -1)"
      case ",$ALLOW,$SKIP," in *",$name,"*) ;; *) UNCOVERED="$UNCOVERED $name" ;; esac
    fi
  done
  if [ -z "$UNCOVERED" ]; then chk 1 "带 install 脚本的包全部被 ALLOW_SCRIPTS/SKIP_SCRIPTS 覆盖"
  else chk 0 "带 install 脚本的包全部被覆盖" "未覆盖：$UNCOVERED"; fi
else
  chk 1 "安装树不存在，跳过白名单覆盖检查（$PKGS）"
fi

echo
echo "== 运行期脚本契约 =="
for f in start_dsh.sh stop_dsh.sh restart_dsh_now.sh; do
  bash -n "$REPO/$f" 2>/dev/null && dash -n "$REPO/$f" 2>/dev/null && chk 1 "$f 语法（bash -n + dash -n）" || chk 0 "$f 语法（bash -n + dash -n）"
  head -1 "$REPO/$f" | grep -q '^#!/data/data/com.termux/files/usr/bin/bash$' && chk 1 "$f shebang 是 Termux 绝对路径" || chk 0 "$f shebang 是 Termux 绝对路径"
done
# dsh 只认 --port，不读 DSH_PORT：launch 必须显式传端口，否则会打印没人监听的 URL（夹具用例 1 守着）。
grep -q 'nohup dsh web --no-open --port "\$PORT"' "$REPO/start_dsh.sh" && chk 1 "start_dsh.sh 把 DSH_PORT 作为 --port 传给 dsh" || chk 0 "start_dsh.sh 把 DSH_PORT 作为 --port 传给 dsh"
grep -q 'no-token（日志里还没有带 token 的 URL）' "$REPO/start_dsh.sh" && chk 1 "降级裸 URL 会打印具体原因 no-token" || chk 0 "降级裸 URL 会打印具体原因 no-token"
grep -q 'explain_busy_port' "$REPO/start_dsh.sh" && grep -q 'if port_up; then' "$REPO/start_dsh.sh" && chk 1 "start 拉起前先探端口（端口被占不再白拉一个）" || chk 0 "start 拉起前先探端口（端口被占不再白拉一个）"
grep -q 'startup failed' "$REPO/start_dsh.sh" && grep -q 'FAIL_FILE' "$REPO/start_dsh.sh" && chk 1 "start 看到 dsh 的启动失败会提前退出" || chk 0 "start 看到 dsh 的启动失败会提前退出"
grep -q '\[ "\$_code" = "000" \]' "$REPO/restart_dsh_now.sh" && chk 1 "restart 把 curl=000 也当失败" || chk 0 "restart 把 curl=000 也当失败"
grep -q '仍在：\$(list_pids' "$REPO/stop_dsh.sh" && grep -q 'exit 1' "$REPO/stop_dsh.sh" && chk 1 "stop 在进程/端口仍在时退 1" || chk 0 "stop 在进程/端口仍在时退 1"
grep -q '>&2' "$REPO/stop_dsh.sh" && chk 1 "stop 的失败信息走 stderr" || chk 0 "stop 的失败信息走 stderr"

echo
echo "== 仓库卫生 =="
ENV_SHEBANG="$(grep -l '^#!/usr/bin/env' "$REPO"/*.sh "$REPO"/patches/*.js 2>/dev/null | wc -l | tr -d ' ')"
chk "$([ "$ENV_SHEBANG" = 0 ] && echo 1 || echo 0)" "没有 /usr/bin/env shebang（$ENV_SHEBANG 处）"
NONEXEC="$(find "$REPO" -maxdepth 2 \( -name '*.sh' -o -name 'patches/*.js' \) ! -perm -u+x 2>/dev/null | wc -l | tr -d ' ')"
chk "$([ "$NONEXEC" = 0 ] && echo 1 || echo 0)" "所有 .sh 与 patches/*.js 有可执行位（$NONEXEC 个缺）"

echo
echo "==== 静态契约检查：PASS=$PASS FAIL=$FAIL ===="
[ "$FAIL" -eq 0 ]
