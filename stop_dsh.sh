#!/data/data/com.termux/files/usr/bin/bash
# 停止 dsh web（pid 文件 + 身份二次校验）；慢在等 node 收尾，所以用 kill -0 内建探测 + 一次端口确认。
# 用法：bash stop_dsh.sh；DSH_STOP_TIMEOUT 可调等待秒数。
set -u

BASE="$HOME/dsh"
PORT="${DSH_PORT:-3080}"
URL="http://127.0.0.1:${PORT}"
PID_FILE="$BASE/storage/dsh.pid"
# 进程匹配模式；[b] 括号技巧避免自匹配，可用 DSH_WEB_PATTERN 覆盖。
DSH_WEB_PATTERN="${DSH_WEB_PATTERN:-/lib/node_modules/@deepseek-ai/dsh/lib/[b]in.js web}"
TIMEOUT="${DSH_STOP_TIMEOUT:-10}"

list_pids() {
  pgrep -f "$DSH_WEB_PATTERN" 2>/dev/null || true
}
pid_alive() {
  kill -0 "$1" 2>/dev/null
}
# pid 文件里的 pid 可能被复用给无关进程，kill 前必须先确认它真是 dsh web（与 start_dsh.sh 同一套判定）。
# 杀之前必做身份二次确认：pid 可能被系统复用给无关进程，直接 kill 会误杀。
pid_is_dsh() {
  list_pids | grep -qx "$1" 2>/dev/null && return 0
  ps -p "$1" -o args= 2>/dev/null | grep -q -- "$DSH_WEB_PATTERN"
}

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

# 等主进程退出（kill -0 是内建，零 fork）+ 端口真正释放（restart 紧接着要 bind）。
_waited=0
while [ "$_waited" -lt "$TIMEOUT" ]; do
  _gone=1
  for _p in $TARGETS; do
    if pid_alive "$_p"; then _gone=0; break; fi
  done
  if [ "$_gone" = "1" ] && ! curl -s -o /dev/null --max-time 1 "$URL" 2>/dev/null; then
    break
  fi
  sleep 0.3
  _waited=$((_waited + 1))
done

# 仍未退出 → SIGKILL（dsh 可能卡在插件收尾/子进程上）
_forcelist=""
for _p in $TARGETS; do
  pid_alive "$_p" && _forcelist="$_forcelist $_p"
done
if [ -n "$_forcelist" ]; then
  kill -9 $_forcelist 2>/dev/null || true
  sleep 0.3
fi

rm -f "$PID_FILE"
if [ -n "$(list_pids)" ]; then
  echo "[dsh] 已发送停止信号，但仍有匹配进程存活（可能被忽略/僵死）：$(list_pids | tr '\n' ' ')"
else
  echo "[dsh] 已停止"
fi
