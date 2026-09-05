#!/data/data/com.termux/files/usr/bin/bash
# 重启 DeepSeek Harness (dsh) Web 服务（复用 stop_dsh.sh 停止段，含 pid 身份校验）
set -u

BASE="$HOME/dsh"
WEB_LOG="$BASE/storage/dsh.log"
RESTART_LOG="$BASE/storage/dsh_restart.log"
PID_FILE="$BASE/storage/dsh.pid"
mkdir -p "$BASE/storage"
umask 077

echo "$(date '+%F %T') restart begin" >> "$RESTART_LOG"
bash "$BASE/stop_dsh.sh" >/dev/null 2>&1 || true
rm -f "$PID_FILE"

cd "$BASE" || exit 1
export DSH_PERMISSION_MODE=danger-full-access
# 与 start_dsh.sh 保持一致：--no-open 不交给 dsh 的 open 包，且输出写到同一个 dsh.log，
# 这样 start_dsh.sh 之后能从 dsh.log 提取当前进程的带 token 鉴权 URL。
nohup dsh web --no-open >"$WEB_LOG" 2>&1 &
NEWPID=$!
echo "$NEWPID" > "$PID_FILE"
echo "$(date '+%F %T') restarted pid=$NEWPID" >> "$RESTART_LOG"

for i in $(seq 1 90); do
  if curl -s -o /dev/null --max-time 2 http://127.0.0.1:3080; then
    echo "$(date '+%F %T') ready on 3080" >> "$RESTART_LOG"
    echo "[dsh] 重启完成，网页: http://127.0.0.1:3080"
    echo "[dsh] 如需带 token 打开浏览器，请执行: bash ~/dsh/start_dsh.sh"
    exit 0
  fi
  sleep 1
done
echo "$(date '+%F %T') TIMEOUT waiting for 3080" >> "$RESTART_LOG"
exit 1
