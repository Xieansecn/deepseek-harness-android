#!/data/data/com.termux/files/usr/bin/bash
# 重启 dsh web：停止段复用 stop_dsh.sh，启动段复用 start_dsh.sh --no-open，日志写同一个 dsh.log。
# 用法：bash restart_dsh_now.sh（不打开浏览器；带 token 打开请用 start_dsh.sh）。
set -u

BASE="$HOME/dsh"
WEB_LOG="$BASE/storage/dsh.log"
RESTART_LOG="$BASE/storage/dsh_restart.log"
PID_FILE="$BASE/storage/dsh.pid"
PORT="${DSH_PORT:-3080}"
URL="http://127.0.0.1:${PORT}"
mkdir -p "$BASE/storage"
umask 077
cd "$BASE" || exit 1

echo "$(date '+%F %T') restart begin" >> "$RESTART_LOG"

# 先停旧进程（含 pid 身份二次确认）；stop 会把 pid 文件删掉
bash "$BASE/stop_dsh.sh" >/dev/null 2>&1 || true
rm -f "$PID_FILE"

if ! bash "$BASE/start_dsh.sh" --no-open >>"$RESTART_LOG" 2>&1; then
  echo "$(date '+%F %T') restart FAILED: start_dsh.sh 未能在限定时间内取到带 token URL" >> "$RESTART_LOG"
  echo "[dsh] 重启失败：服务未就绪，详见 $RESTART_LOG"
  exit 1
fi

# start_dsh.sh --no-open 只有在真的拿到可用 token URL 时才成功返回，这里再确认一次端口
_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$URL" 2>/dev/null || true)"
echo "$(date '+%F %T') restarted pid=$(cat "$PID_FILE" 2>/dev/null || echo '?') http=${_code:-no-response}" >> "$RESTART_LOG"
if [ -z "$_code" ]; then
  echo "[dsh] 重启后 $PORT 无响应，详见 $RESTART_LOG"
  exit 1
fi
echo "[dsh] 重启完成，网页: $URL"
echo "[dsh] 需要带 token 打开浏览器时执行: bash ~/dsh/start_dsh.sh"
