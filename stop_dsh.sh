#!/data/data/com.termux/files/usr/bin/bash
# 停止 dsh web（pid 文件 + 身份二次校验）。
# 耗时全在等 node 收尾：SIGTERM 后它要 2~4s 才优雅退出，但 dsh 自己的"二次 Ctrl-C"语义是第二次信号立即强退（实测 0.17s）。
# 所以梯子是：优雅窗口 DSH_STOP_GRACE 秒 → 补发一次 SIGTERM（dsh 自己强退，比 SIGKILL 干净）→ DSH_STOP_TIMEOUT 秒后 SIGKILL 兜底。
# 轮询只用 kill -0 内建（不起 curl/pgrep），端口只在最后确认一次。
# 用法：bash stop_dsh.sh；DSH_STOP_GRACE / DSH_STOP_TIMEOUT 可调（秒，可含小数）。
set -u

BASE="$HOME/dsh"
PORT="${DSH_PORT:-3080}"
URL="http://127.0.0.1:${PORT}"
PID_FILE="$BASE/storage/dsh.pid"
# 进程匹配模式；[b] 括号技巧避免自匹配，可用 DSH_WEB_PATTERN 覆盖。
DSH_WEB_PATTERN="${DSH_WEB_PATTERN:-/lib/node_modules/@deepseek-ai/dsh/lib/[b]in.js web}"
GRACE="${DSH_STOP_GRACE:-1.5}"
TIMEOUT="${DSH_STOP_TIMEOUT:-6}"

list_pids() {
  pgrep -f "$DSH_WEB_PATTERN" 2>/dev/null || true
}
pid_alive() {
  kill -0 "$1" 2>/dev/null
}
# pid 文件里的 pid 可能被复用给无关进程，kill 前必须先确认它真是 dsh web（与 start_dsh.sh 同一套判定）。
pid_is_dsh() {
  list_pids | grep -qx "$1" 2>/dev/null && return 0
  ps -p "$1" -o args= 2>/dev/null | grep -q -- "$DSH_WEB_PATTERN"
}
any_alive() {
  for _p in $TARGETS; do
    pid_alive "$_p" && return 0
  done
  return 1
}
# 秒（可含小数）→ 0.1s 步数；非法值退回默认。
steps() {
  case "$1" in ''|*[!0-9.]*) set -- "$2" ;; esac
  awk -v s="$1" 'BEGIN { n = s * 10; printf "%d", (n < 0 ? 0 : n) }'
}
GRACE_STEPS="$(steps "$GRACE" 1.5)"
TIMEOUT_STEPS="$(steps "$TIMEOUT" 5)"

PIDFILE_PID=""
if [ -f "$PID_FILE" ]; then
  PIDFILE_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
fi

# 目标 pid 集合 = pgrep 精确匹配（完整 cmdline）+ pid 文件里经身份校验的 pid（去重）
TARGETS=""
for _p in $(list_pids); do
  TARGETS="$TARGETS $_p"
done
if [ -n "$PIDFILE_PID" ] && pid_alive "$PIDFILE_PID" && pid_is_dsh "$PIDFILE_PID"; then
  case " $TARGETS " in
    *" $PIDFILE_PID "*) ;;
    *) TARGETS="$TARGETS $PIDFILE_PID" ;;
  esac
fi
TARGETS="${TARGETS# }"

if [ -z "$TARGETS" ]; then
  [ -n "$PIDFILE_PID" ] && echo "[dsh] pid 文件里的进程（pid=$PIDFILE_PID）不是 dsh web，已忽略"
  rm -f "$PID_FILE"
  echo "[dsh] 未发现运行中的 dsh"
  exit 0
fi

kill $TARGETS 2>/dev/null || true

# 1) 优雅窗口：只等进程自己走（kill -0 是内建，零 fork）
_i=0
while [ "$_i" -lt "$GRACE_STEPS" ] && any_alive; do
  sleep 0.1
  _i=$((_i + 1))
done

# 2) 还活着 → 补发一次 SIGTERM：dsh 收到第二次退出信号会立即强退（它自己的设计，SIGKILL 之外最干净的方式）
if any_alive; then
  echo "[dsh] 优雅退出超时（${GRACE}s），补发 SIGTERM 立即退出"
  kill $TARGETS 2>/dev/null || true
  _i=0
  while [ "$_i" -lt 10 ] && any_alive; do
    sleep 0.1
    _i=$((_i + 1))
  done
fi

# 3) 仍不退（僵死/忽略信号）→ SIGKILL 兜底，最多再等 DSH_STOP_TIMEOUT
if any_alive; then
  _forcelist=""
  for _p in $TARGETS; do
    pid_alive "$_p" && _forcelist="$_forcelist $_p"
  done
  if [ -n "$_forcelist" ]; then
    echo "[dsh] 进程未响应信号，SIGKILL：$_forcelist"
    kill -9 $_forcelist 2>/dev/null || true
    _i=0
    while [ "$_i" -lt "$TIMEOUT_STEPS" ] && any_alive; do
      sleep 0.1
      _i=$((_i + 1))
    done
  fi
fi

rm -f "$PID_FILE"
# 端口只在最后确认一次（restart 紧接着要 bind）；进程都没了还占着端口才需要提示。
if any_alive || curl -s -o /dev/null --max-time 1 "$URL" 2>/dev/null; then
  echo "[dsh] 已发送停止信号，但进程/端口仍在：$(list_pids | tr '\n' ' ')"
else
  echo "[dsh] 已停止"
fi
