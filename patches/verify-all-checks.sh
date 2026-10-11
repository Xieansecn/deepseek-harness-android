#!/data/data/com.termux/files/usr/bin/bash
# 一条命令跑完全部**脚本级**检查（只读/临时目录；不跑 setup.sh、不碰 3080、不写 ~/.dsh）。
#
# 用法：
#   bash patches/verify-all-checks.sh            # 只打摘要 + 失败项的尾部输出
#   bash patches/verify-all-checks.sh --verbose  # 透传每个套件的完整输出
#
# 套件：
#   1. 语法：bash -n 全部 .sh、dash -n 三个运行期脚本、node --check 全部 patches/*.js
#   2. 静态契约：setup.sh 的锚点规格/npm 包装/原子替换/白名单覆盖 + 运行期脚本端口与退出码
#   3. 夹具：require-builtin(29) / profile(41) / guards(39) / js-patches(21) / runtime-scripts(21)
#   4. --full 追加：变异测试（往副本注入 9 个已知回归，证明套件抓得住；约 5 分钟）
# 退出码：0 = 全绿；1 = 有套件失败。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
VERBOSE=0
FULL=0
for a in "$@"; do
  [ "$a" = "--verbose" ] && VERBOSE=1
  [ "$a" = "--full" ] && FULL=1
done
TMP="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
LOG="$(mktemp "$TMP/dsh-verify-all.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=""

run_suite() { # run_suite <名字> <命令...>
  _name="$1"; shift
  if [ "$VERBOSE" = 1 ]; then
    if "$@"; then rc=0; else rc=$?; fi
  else
    if "$@" >"$LOG" 2>&1; then rc=0; else rc=$?; fi
  fi
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1)); echo "  [OK]   $_name"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $_name"
    echo "  [FAIL] $_name（rc=$rc）"
    if [ "$VERBOSE" != 1 ]; then sed -n '1,200p' "$LOG" | grep -E "\[FAIL\]|ERROR|SyntaxError|FAIL=" | head -12 | sed 's/^/         /'; fi
  fi
}

echo "== 1. 语法 =="
syn=0
for f in "$REPO"/*.sh; do bash -n "$f" 2>/dev/null || { echo "  [FAIL] bash -n $(basename "$f")"; syn=1; }; done
for f in start_dsh.sh stop_dsh.sh restart_dsh_now.sh; do dash -n "$REPO/$f" 2>/dev/null || { echo "  [FAIL] dash -n $f"; syn=1; }; done
for f in "$HERE"/*.js; do node --check "$f" >/dev/null 2>&1 || { echo "  [FAIL] node --check $(basename "$f")"; syn=1; }; done
if [ "$syn" = 0 ]; then PASS=$((PASS + 1)); echo "  [OK]   全部脚本语法通过"; else FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES syntax"; fi

echo "== 2. setup.sh / 运行期脚本静态契约 =="
run_suite "静态契约检查（verify-setup-static-check.sh）" bash "$HERE/verify-setup-static-check.sh"

echo "== 3. 夹具自检 =="
run_suite "apply-js-patches 夹具（21 断言）"            node "$HERE/verify-js-patches-fixture.js"
run_suite "require-builtin 平台包夹具（29 断言）"        node "$HERE/verify-require-builtin-fixture.js"
run_suite "权限层夹具（41 断言）"                        node "$HERE/verify-profile-patch-fixture.js"
run_suite "link/flock 守护条件夹具（39 断言）"           node "$HERE/verify-patch-guards-fixture.js"
run_suite "start/stop/restart 夹具（21 断言）"           node "$HERE/verify-runtime-scripts-fixture.js"

if [ "$FULL" = 1 ]; then
  echo "== 4. 变异测试（证明这套检查抓得住回归）=="
  run_suite "变异测试（9 个注入回归 + 4 个对照组）" node "$HERE/verify-test-effectiveness.js"
fi

echo
echo "==== 脚本级检查：套件 PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" != 0 ]; then
  echo "失败套件：$FAILED_NAMES"
  echo "（加 --verbose 看完整输出）"
  exit 1
fi
echo "全部通过。"
