#!/data/data/com.termux/files/usr/bin/bash
# 启动 DeepSeek Harness (dsh) 原生 Web UI 并在本机浏览器打开（https://www.termux.com）
set -u

PORT=3080
URL="http://127.0.0.1:${PORT}"
BASE="$HOME/dsh"
LOG_FILE="$BASE/storage/dsh.log"
PID_FILE="$BASE/storage/dsh.pid"
DSH_WEB_PATTERN="/lib/node_modules/@deepseek-ai/dsh/lib/[b]in.js web"
mkdir -p "$BASE/storage"
umask 077

# Android/Termux 无 bwrap/landlock，需放开沙箱权限模式才能执行 bash 工具
export DSH_PERMISSION_MODE=danger-full-access

if ! command -v dsh >/dev/null 2>&1; then
  echo "[dsh] 未找到 dsh 命令，请先运行 setup.sh"
  exit 1
fi

# 提取 dsh 启动时打印的【带 token 启动 URL】——这是浏览器换取登录 cookie 的唯一入口。
# dsh 默认 printUrl=true（不论是否 --no-open 都会打印）：`dsh web: http://.../?token=...`。
# 日志会累积历史进程的 token，这里取【最后一条】匹配——即当前运行进程的 token。
auth_url() {
  grep -oE 'https?://[^/[:space:]]*/\?token=[A-Za-z0-9_-]+' "$LOG_FILE" 2>/dev/null | tail -1
}

# 新鉴权中，带 token 的根 URL 会返回 303 并 Set-Cookie；这里用 curl 验证 token
# 是否真的属于当前进程，避免日志里残留旧进程 token 时打开后仍显示 401。
auth_url_valid() {
  local au code
  au="$(auth_url)"
  [ -n "$au" ] || return 1
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$au" 2>/dev/null || true)"
  [ "$code" = "303" ] || [ "$code" = "302" ]
}

# 打开浏览器：优先打开已经由 curl 验证过可用、能换取登录 cookie 的带 token URL；
# 日志里暂没抓到/已验证失败时退回裸 URL 并提示（可能 401，需手动使用带 token 地址）。
open_gui() {
  local au
  au="$(auth_url)"
  if auth_url_valid; then
    echo "[dsh] 打开 (带 token) $au"
    termux-open-url "$au"
    return 0
  fi
  echo "[dsh] 打开 $URL（若空白/401，请重启服务以获取当前进程的新 token；日志：$LOG_FILE）"
  termux-open-url "$URL"
}

# 端口就绪判断：服务只要响应任意状态码即视为就绪（HTTP 401 = 鉴权护栏已生效=服务已起）。
# 不依赖日志行（避免 node 输出重定向到文件时的缓冲区延迟误判）。
server_up() {
  curl -s -o /dev/null --max-time 2 "$URL" 2>/dev/null
}

# 若 3080 已在响应（或 dsh 进程确在运行）则视为"已在运行"，直接打开，不重复拉起
is_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  pgrep -f "$DSH_WEB_PATTERN" >/dev/null 2>&1
}

# 限时等待就绪；优先等带 token 且能通过 303 校验的 URL 出现，避免打开无效鉴权地址。
wait_ready() {
  local i seen=0
  for i in $(seq 1 30); do
    if server_up; then
      if auth_url_valid; then
        open_gui
        return 0
      fi
      seen=$((seen + 1))
      if [ "$seen" -ge 5 ]; then
        # 服务已起来但日志里没有可用的 token，先退化为裸 URL 并提示。
        open_gui
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

if server_up; then
  echo "[dsh] 已在运行，直接打开"
  open_gui
  exit 0
fi

if is_running; then
  echo "[dsh] dsh 进程在但 3080 未响应，等待其就绪..."
  if wait_ready; then
    exit 0
  fi
  echo "[dsh] 进程未在限定时间内就绪，尝试重启"
  bash "$BASE/stop_dsh.sh" >/dev/null 2>&1 || true
fi

if server_up; then
  open_gui
  exit 0
fi

# --no-open：dsh 不再尝试用 open 包打开浏览器（Termux 上不可靠、且会让非默认浏览器收不到
# token），改由本脚本提取带 token 的 URL 后用 termux-open-url 打开。
nohup dsh web --no-open >"$LOG_FILE" 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"
echo "[dsh] 启动中 (pid $NEW_PID)... 日志: $LOG_FILE"

wait_ready || {
  echo "[dsh] 启动超时，最近日志："
  tail -20 "$LOG_FILE"
  echo "[dsh] 若提示缺少模型密钥，请在 Web UI 的 Models 页面配置 DeepSeek API Key"
  exit 1
}
