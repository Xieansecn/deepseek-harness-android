#!/data/data/com.termux/files/usr/bin/bash
# 启动 DeepSeek Harness (dsh) 原生 Web UI 并在本机浏览器打开（https://www.termux.com）
set -u

PORT=3080
URL="http://127.0.0.1:${PORT}"
BASE="$HOME/dsh"
LOG_FILE="$BASE/storage/dsh.log"
PID_FILE="$BASE/storage/dsh.pid"
DSH_WEB_PATTERN="/lib/node_modules/@deepseek-ai/dsh/lib/[b]in.js web"
# 等 dsh 打印带 token URL 的总时长（秒）。必须足够长：dsh 的 announceReady() 要等整个
# plugin loader settle 才打印 URL，端口在那之前就开始响应 401，冷启动本机实测可达数十秒。
READY_TIMEOUT="${DSH_READY_TIMEOUT:-90}"
AUTH_CODE=""
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
# 失败原因写入全局 AUTH_CODE（no-token / 实际 HTTP 码），供降级提示说清实话。
auth_url_valid() {
  local au code
  au="$(auth_url)"
  if [ -z "$au" ]; then AUTH_CODE="no-token"; return 1; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$au" 2>/dev/null || true)"
  AUTH_CODE="${code:-no-response}"
  [ "$code" = "303" ] || [ "$code" = "302" ]
}

# 打开浏览器：优先打开已经由 curl 验证过可用、能换取登录 cookie 的带 token URL。
# 失败时才退回裸 URL（浏览器已持有登录 cookie 时裸 URL 照常可用），并说明具体原因，
# 不要只说"若空白/401"——那样下次出问题依旧无法判断是 token 没出现还是已失效。
open_gui() {
  local au
  au="$(auth_url)"
  if auth_url_valid; then
    echo "[dsh] 打开 (带 token) $au"
    termux-open-url "$au"
    return 0
  fi
  echo "[dsh] 打开裸 URL $URL —— 未能使用带 token 的地址：$(
    [ "$AUTH_CODE" = "no-token" ] && echo "日志里还没有带 token 的 URL" || echo "日志中的 token URL 返回 ${AUTH_CODE}"
  )（浏览器已有登录 cookie 时仍可用；否则请重启服务：bash ~/dsh/restart_dsh_now.sh；日志：$LOG_FILE）"
  termux-open-url "$URL"
}

# 端口就绪判断：服务只要响应任意状态码即视为就绪（HTTP 401 = 鉴权护栏已生效=服务已起）。
# 不依赖日志行（避免 node 输出重定向到文件时的缓冲区延迟误判）。
server_up() {
  curl -s -o /dev/null --max-time 2 "$URL" 2>/dev/null
}

# 若 3080 已在响应（或 dsh 进程确在运行）则视为"已在运行"，直接打开，不重复拉起。
# pid 文件里的 pid 可能已被系统复用给无关进程，所以必须二次确认它确实是 dsh web
# （与 stop_dsh.sh 相同的身份校验），否则会白等一整个 READY_TIMEOUT。
is_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
      && ps -p "$pid" -o args= 2>/dev/null | grep -q "$DSH_WEB_PATTERN" && return 0
  fi
  pgrep -f "$DSH_WEB_PATTERN" >/dev/null 2>&1
}

# 限时等待就绪，返回 0 表示已处理（无论打开了带 token 还是裸 URL）。
# ⚠️ 不能用"端口已响应就开始倒计时、满 N 次就开裸 URL"的写法：dsh 端口先响应 401，
# 之后（plugin loader settle 完）才打印带 token 的 URL，冷启动这段间隔可达数十秒。
# 因此必须在整个 READY_TIMEOUT 内等「可用的 token URL」，只有端口从未响应才算失败。
wait_ready() {
  local i up=0
  for i in $(seq 1 "$READY_TIMEOUT"); do
    if auth_url_valid; then
      open_gui
      return 0
    fi
    # 只在第一次失败时提示（token 已就绪时上一步就已返回），避免终端看起来像卡住。
    if [ "$i" -eq 1 ]; then
      echo "[dsh] 正在等待 dsh 打印带 token 的鉴权 URL（最长 ${READY_TIMEOUT}s）..."
    fi
    if server_up; then up=$((up + 1)); fi
    sleep 1
  done
  if [ "$up" -gt 0 ]; then
    echo "[dsh] 等待 ${READY_TIMEOUT}s 仍未取到属于当前进程的 token（端口已有响应）。"
    open_gui
    return 0
  fi
  return 1
}

if server_up; then
  # 不在这里"立即打开"：3080 有响应只说明服务在跑，不代表日志里已有属于当前进程的 token。
  # wait_ready 会先试一次（token 已可用就立刻打开），否则等到 token 出现再打开。
  echo "[dsh] 3080 已在响应，打开浏览器"
  if wait_ready; then exit 0; fi
  echo "[dsh] 等待期间服务失去响应，改为重新启动"
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
  if wait_ready; then exit 0; fi
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
