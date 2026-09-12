#!/data/data/com.termux/files/usr/bin/bash
# 启动/复用 dsh web：取带 token 的鉴权 URL，校验通过后按包名优先用 Via 打开浏览器。
# 用法：bash start_dsh.sh [--no-open]；只用 POSIX sh 语法，快靠少起子进程（fork+exec 约 19ms），别在轮询里反复起 grep/curl。
set -u

PORT="${DSH_PORT:-3080}"
URL="http://127.0.0.1:${PORT}"
# 打开给浏览器的 origin；DSH_ORIGIN=localhost 可绕开 PWA 对 ?token= 的 scope 劫持（默认走 Via 不受影响）。
OPEN_HOST="${DSH_ORIGIN:-127.0.0.1}"
BASE="$HOME/dsh"
LOG_FILE="$BASE/storage/dsh.log"
PID_FILE="$BASE/storage/dsh.pid"
# dsh 的 announceReady() 要等 plugin loader settle 才打印 token（冷启动约 9s），端口那之前就开始响应 401。
DSH_WEB_PATTERN="${DSH_WEB_PATTERN:-/lib/node_modules/@deepseek-ai/dsh/lib/[b]in.js web}"
# 进程匹配模式；[b] 括号技巧避免自匹配，可用 DSH_WEB_PATTERN 覆盖以便多安装并存。
READY_TIMEOUT="${DSH_READY_TIMEOUT:-90}"
NO_OPEN=0
AUTH_CODE=""
AUTH_URL=""
mkdir -p "$BASE/storage"
umask 077

# Android/Termux 无 bwrap/landlock，需放开沙箱权限模式才能执行 bash 工具
export DSH_PERMISSION_MODE=danger-full-access

# 只接受纯数字超时值，避免把非法值喂给 timeout / 算术展开
case "$READY_TIMEOUT" in *[!0-9]*|'') READY_TIMEOUT=90 ;; esac
[ "$READY_TIMEOUT" -gt 0 ] 2>/dev/null || READY_TIMEOUT=90

while [ $# -gt 0 ]; do
  case "$1" in
    --no-open) NO_OPEN=1 ;;
    *) echo "[dsh] 未知参数: $1（可用：--no-open）"; exit 2 ;;
  esac
  shift
done

if ! command -v dsh >/dev/null 2>&1; then
  echo "[dsh] 未找到 dsh 命令，请先运行 setup.sh"
  exit 1
fi

# 端口是否响应：优先 bash 内建 /dev/tcp（零 fork），不可用时退回 curl。
HAVE_TCP=0
if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then HAVE_TCP=1; fi
port_up() {
  if [ "$HAVE_TCP" = "1" ]; then
    (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null
  else
    curl -s -o /dev/null --max-time 2 "$URL" 2>/dev/null
  fi
}

# 进程识别（与 stop 同一套）：pid 文件里的 pid 可能被复用，必须先确认它真是 dsh web。
list_pids() {
  pgrep -f "$DSH_WEB_PATTERN" 2>/dev/null || true
}
pid_is_dsh() {
  list_pids | grep -qx "$1" 2>/dev/null && return 0
  ps -p "$1" -o args= 2>/dev/null | grep -q -- "$DSH_WEB_PATTERN"
}
is_running() {
  if [ -f "$PID_FILE" ]; then
    _p="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && pid_is_dsh "$_p"; then return 0; fi
  fi
  [ -n "$(list_pids)" ]
}

# 日志里【最后一条】带 token URL，仅用于复用已在运行的服务。
last_auth_url() {
  grep -oE 'https?://[^/[:space:]]*/\?token=[A-Za-z0-9_-]+' "$LOG_FILE" 2>/dev/null | tail -1
}

# 校验带 token URL 返回 303/302 才算有效；AUTH_CODE 记录失败原因供降级提示。
check_url() {
  if [ -z "$1" ]; then AUTH_CODE="no-token"; return 1; fi
  AUTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null || true)"
  [ -n "$AUTH_CODE" ] || AUTH_CODE="no-response"
  [ "$AUTH_CODE" = "303" ] || [ "$AUTH_CODE" = "302" ]
}
open_if_auth_ready() {
  AUTH_URL="$(last_auth_url)"
  check_url "$AUTH_URL" || return 1
  open_gui "$AUTH_URL"
  return 0
}

# open_gui 传了 URL 就直接用，避免对同一个 token 重复 curl。
copy_url() {
  command -v termux-clipboard-set >/dev/null 2>&1 || return 1
  command -v termux-clipboard-get >/dev/null 2>&1 || return 1
  printf '%s' "$1" | termux-clipboard-set 2>/dev/null || return 1
  [ "$(termux-clipboard-get 2>/dev/null)" = "$1" ] || return 1
  return 0
}

# 打开浏览器顺序：DSH_OPEN_APP 指定 → Via（默认 mark.via，am start 按包名）→ 系统默认浏览器 → DSH_OPEN_CHOOSER 选择器。
# 不直接用 termux-open-url 的包名参数：它把 am 输出丢进 /dev/null、失败也返回 0，无法回退；am 自身退出码才可信。
open_in_app() {
  timeout 10 am start -a android.intent.action.VIEW -d "$1" "$2" >/dev/null 2>&1
}

open_url() {
  if [ "$NO_OPEN" = "1" ] || [ "${DSH_NO_OPEN:-0}" = "1" ]; then
    echo "[dsh] 未自动打开浏览器；请手动在新标签页打开：$1"
    return 0
  fi
  if [ -n "${DSH_OPEN_APP:-}" ] && command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$1" "$DSH_OPEN_APP"
    return 0
  fi
  if command -v am >/dev/null 2>&1; then
    if open_in_app "$1" "${DSH_VIA_APP:-mark.via}"; then
      return 0
    fi
    echo "[dsh] 未找到 Via（${DSH_VIA_APP:-mark.via}），改用系统默认浏览器"
  fi
  if [ "${DSH_OPEN_CHOOSER:-0}" = "1" ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open --chooser "$1"
    return 0
  fi
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$1"
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1"
    return 0
  fi
  echo "[dsh] 未找到 termux-open-url / xdg-open，请手动在浏览器打开：$1"
}

# 优先已校验过的带 token URL，失败才退回裸 URL（浏览器已有 cookie 时仍可用）。
open_gui() {
  _given="${1:-}"
  if [ -n "$_given" ]; then
    AUTH_URL="$_given"
    announce_and_open "http://${OPEN_HOST}:${PORT}/?token=${AUTH_URL#*token=}"
    return 0
  fi
  if check_url "$AUTH_URL"; then
    announce_and_open "http://${OPEN_HOST}:${PORT}/?token=${AUTH_URL#*token=}"
    return 0
  fi
  _target="http://${OPEN_HOST}:${PORT}/"
  if [ "$AUTH_CODE" = "no-token" ]; then _why="日志里还没有带 token 的 URL"; else _why="日志中的 token URL 返回 ${AUTH_CODE}"; fi
  echo "[dsh] 打开裸 URL $_target —— 未能使用带 token 的地址：${_why}（浏览器已有登录 cookie 时仍可用；否则请重启服务：bash ~/dsh/restart_dsh_now.sh；日志：$LOG_FILE）"
  open_url "$_target"
}

# 打印/复制/打开带 token URL；PWA 排查提示只在默认 origin 且真的会打开浏览器时给。
announce_and_open() {
  if [ "$NO_OPEN" = "1" ] || [ "${DSH_NO_OPEN:-0}" = "1" ]; then
    echo "[dsh] 服务已就绪（--no-open / DSH_NO_OPEN=1，未打开浏览器）：$1"
    return 0
  fi
  echo "[dsh] 打开 (带 token) $1"
  if [ "$OPEN_HOST" = "127.0.0.1" ]; then
    echo "[dsh] 若浏览器落在裸地址/显示 401（退回系统默认浏览器且该 origin 装过 PWA 时会发生：PWA 按 start_url 打开会丢掉 token），依次试："
    echo "[dsh]   1) DSH_ORIGIN=localhost bash ~/dsh/start_dsh.sh     # 换 origin，绕开 PWA（已验证可用）"
    echo "[dsh]   2) DSH_NO_OPEN=1 bash ~/dsh/start_dsh.sh            # 只打印 URL，自己粘到浏览器新标签页"
    echo "[dsh]   3) DSH_OPEN_APP=com.android.chrome bash ~/dsh/start_dsh.sh   /   DSH_OPEN_CHOOSER=1 ..."
  fi
  if copy_url "$1"; then
    echo "[dsh] 已复制该 URL 到剪贴板，可直接粘贴到浏览器新标签页"
  fi
  open_url "$1"
}

# 流式跟随日志等 token：读到新打印的带 token 行即写 RESULT_FILE 返回（不再每秒 grep/curl 轮询）。
# ⚠️ 循环体在管道子 shell 里：return 只结束子 shell，调用方一律以 RESULT_FILE 非空判成功；端口标记只能写 PORT_FILE。
_tmp_dir="${TMPDIR:-$HOME/.cache}"
RESULT_FILE="$_tmp_dir/dsh_start_url.$$"
if ! : > "$RESULT_FILE" 2>/dev/null; then
  RESULT_FILE="$BASE/storage/.dsh_start_url.$$"
  : > "$RESULT_FILE" 2>/dev/null || RESULT_FILE="/dev/null"
fi
# 管道结束后才探一次端口：端口有响应=服务起了但没给 token（降级裸 URL），没响应=服务没起来。
PORT_FILE="${RESULT_FILE}.port"
trap 'rm -f "$RESULT_FILE" "$PORT_FILE"' EXIT INT TERM HUP

wait_for_token() {
  _seen=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$READY_TIMEOUT" tail -n 0 -f "$LOG_FILE" 2>/dev/null
  else
    tail -n 0 -f "$LOG_FILE" 2>/dev/null
  fi | while IFS= read -r _line; do
    _seen=$((_seen + 1))
# 等 token → 打开；返回 0 表示已处理（带 token 或降级裸 URL），1 表示服务没起来。
    case "$_line" in *token=*) ;; *) continue ;; esac
    _url="$(printf '%s\n' "$_line" | grep -oE 'https?://[^/[:space:]]*/\?token=[A-Za-z0-9_-]+' 2>/dev/null | tail -1)"
    [ -n "$_url" ] || continue
    if check_url "$_url"; then
      printf '%s' "$_url" > "$RESULT_FILE"
      return 0
    fi
  done
# 拉起新进程：--no-open 不让 dsh 自己 open，由本脚本拿带 token URL 交给浏览器。
# 主流程：A 复用已在运行的服务 → B 进程活着就跟随日志等 token → C 没有进程则拉起新进程。
  [ -s "$RESULT_FILE" ] && return 0
  if port_up; then printf 'up' > "$PORT_FILE"; fi
  [ -s "$PORT_FILE" ] && return 2
  return 1
}

# A 复用：日志最后一条 token 仍可用就直接打开。
wait_and_open() {
  if [ "$NO_OPEN" != "1" ]; then
    echo "[dsh] 正在等待 dsh 打印带 token 的鉴权 URL（最长 ${READY_TIMEOUT}s）..."
  fi
  _rc=0
  wait_for_token || _rc=$?
  AUTH_URL="$(cat "$RESULT_FILE" 2>/dev/null || true)"
  if [ -n "$AUTH_URL" ]; then
    if [ "$NO_OPEN" = "1" ]; then
      echo "[dsh] 服务已就绪: $AUTH_URL"
      return 0
    fi
    announce_and_open "http://${OPEN_HOST}:${PORT}/?token=${AUTH_URL#*token=}"
    return 0
  fi
  if [ "$_rc" = "2" ]; then
    echo "[dsh] 等待 ${READY_TIMEOUT}s 仍未取到属于当前进程的 token（端口已有响应），降级打开裸 URL。"
    open_gui
    return 0
  fi
  return 1
}

# 拉起新进程（--no-open：不让 dsh 自己 open —— 本脚本才能拿带 token URL 按包名递给浏览器）
launch() {
  nohup dsh web --no-open >>"$LOG_FILE" 2>&1 &
  NEW_PID=$!
  echo "$NEW_PID" > "$PID_FILE"
  echo "[dsh] 启动中 (pid $NEW_PID)... 日志: $LOG_FILE"
}

# 有进程在跑但没等到 token：自动重启（旧进程可能没把 URL 写进当前日志）。
if open_if_auth_ready; then
  exit 0
fi

# B: 进程活着但 3080 没响应/没有新 token：不是本次日志写的 URL，跟随日志等它打印
if is_running; then
  if wait_and_open; then exit 0; fi
  echo "[dsh] 现有 dsh 进程未在限定时间内就绪，自动重启"
  bash "$BASE/stop_dsh.sh" >/dev/null 2>&1 || true
fi

# C: 没有进程在跑（或刚被停掉）→ 拉起新进程
launch
if wait_and_open; then exit 0; fi

echo "[dsh] 启动超时，最近日志："
tail -20 "$LOG_FILE"
echo "[dsh] 若提示缺少模型密钥，请在 Web UI 的 Models 页面配置 DeepSeek API Key"
exit 1
