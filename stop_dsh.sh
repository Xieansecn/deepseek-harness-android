#!/data/data/com.termux/files/usr/bin/bash
# 停止 DeepSeek Harness (dsh) Web 服务
set -u

BASE="$HOME/dsh"
PID_FILE="$BASE/storage/dsh.pid"
# [b] 括号技巧：进程匹配模式不会"自匹配" pgrep/pkill 自身的命令行，避免误杀运行本脚本的终端。
# 匹配的是真实 dsh 进程 cmdline：node --expose-internals .../lib/bin.js web
DSH_WEB_PATTERN="/lib/node_modules/@deepseek-ai/dsh/lib/[b]in.js web"

stopped=0

# 优先：读 pid 文件，精确 kill（校验仍存活）
if [ -f "$PID_FILE" ]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # 二次确认该 pid 确实是 dsh web（避免误杀被 pid 文件占用的同名 pid）
    if ! pgrep -f "$DSH_WEB_PATTERN" | grep -qx "$pid" 2>/dev/null && ! ps -p "$pid" -o args= 2>/dev/null | grep -q "$DSH_WEB_PATTERN"; then
      echo "[dsh] pid 文件指向非 dsh 进程（pid=$pid），跳过，改由兜底匹配"
    else
      kill "$pid" 2>/dev/null || true
      stopped=1
    fi
  fi
  rm -f "$PID_FILE"
fi

# 兜底：按绝对路径 + web 子命令精确匹配（兼容无 pid 文件的旧安装）
if pgrep -f "$DSH_WEB_PATTERN" >/dev/null 2>&1; then
  pkill -f "$DSH_WEB_PATTERN" 2>/dev/null || true
  stopped=1
fi

if [ "$stopped" -eq 1 ]; then
  # 等待进程真正退出再返回：restart_dsh_now.sh 紧接着就拉起新进程，若此时 3080 仍被
  # 旧进程占用，新进程 bind 失败，而 restart 只看端口响应就误报"重启完成"。
  for _ in $(seq 1 30); do
    pgrep -f "$DSH_WEB_PATTERN" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -f "$DSH_WEB_PATTERN" >/dev/null 2>&1; then
    pkill -9 -f "$DSH_WEB_PATTERN" 2>/dev/null || true
    sleep 0.2
  fi
  echo "[dsh] 已停止"
else
  echo "[dsh] 未发现运行中的 dsh"
fi
