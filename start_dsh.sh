#!/data/data/com.termux/files/usr/bin/bash
# 启动/复用 dsh web：取带 token 的鉴权 URL，校验通过后按包名优先用 Via 打开浏览器。
# 用法：bash start_dsh.sh [--no-open]；只用 POSIX sh 语法，快靠少起子进程（fork+exec 约 19ms），别在轮询里反复起 grep/curl。
set -u

# 启动计时（2 位小数）：bash 的 EPOCHREALTIME 是内建变量、零 fork；sh 上没有时退回 date +%s%N。
# 内部统一折成微秒整数，避免浮点小数的 locale 差异；只在开头/收尾各取一次，不在轮询里。
now_us() {
  _sec=""
  _frac=""
  if [ -n "${EPOCHREALTIME:-}" ]; then
    _ns="$EPOCHREALTIME"
    case "$_ns" in *.*) ;; *) _ns="${_ns}.0" ;; esac
    _sec="${_ns%%.*}"
    _frac="${_ns#*.}"
  else
    _ns="$(date +%s%N 2>/dev/null || true)"
    case "$_ns" in
      ''|*[!0-9]*) _sec="$(date +%s 2>/dev/null || true)"; _frac="0" ;;
      *) _sec="${_ns%?????????}"; _frac="${_ns#"$_sec"}" ;;
    esac
  fi
  case "$_sec" in ''|*[!0-9]*) _sec=0 ;; esac
  case "$_frac" in ''|*[!0-9]*) _frac=0 ;; esac
  while [ "${#_frac}" -lt 6 ]; do _frac="${_frac}0"; done
  _tail="${_frac#??????}"
  _frac="${_frac%"$_tail"}"
  printf '%s' "$(( _sec * 1000000 + 1$_frac - 1000000 ))"
}
elapsed_seconds() {
  _us=$(( $(now_us) - T_START_US ))
  [ "$_us" -ge 0 ] 2>/dev/null || _us=0
  _cs=$(( (_us + 5000) / 10000 ))
  printf '%d.%02d' "$(( _cs / 100 ))" "$(( _cs % 100 ))"
}
report_elapsed() {
  [ -n "${T_START_US:-}" ] || return 0
  printf '[dsh] 本次耗时 %s 秒\n' "$(elapsed_seconds)"
}
T_START_US="$(now_us)"

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
# 当前在跑的 dsh web pid：pid 文件里经身份校验的那个，否则取 pgrep 的第一个。
# wait_for_token 拿它给 `tail --pid`：进程一死 tail 立即退出，不用等满 READY_TIMEOUT。
running_pid() {
  if [ -f "$PID_FILE" ]; then
    _rp="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$_rp" ] && kill -0 "$_rp" 2>/dev/null && pid_is_dsh "$_rp"; then
      printf '%s' "$_rp"
      return 0
    fi
  fi
  list_pids | head -1
}
# 本次等待从日志的哪个字节开始：失败时只贴本次启动新增的内容，不把上一轮的旧报错/旧 token 混进来。
LOG_OFF=0
mark_log_offset() {
  LOG_OFF="$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')"
  case "$LOG_OFF" in ''|*[!0-9]*) LOG_OFF=0 ;; esac
}
tail_log_since() {
  tail -c "+$((LOG_OFF + 1))" "$LOG_FILE" 2>/dev/null | tail -n "${1:-20}"
}

# 日志里【最后一条】带 token URL，仅用于复用已在运行的服务。
# ⚠️ 取该行里的【第一个】URL：dsh 在绑定 0.0.0.0 时会追加 " (LAN: <url>)"，
# 若按全文件 tail -1 取匹配就会拿到 LAN 地址（loopback 部署下本不该用它）。
last_auth_url() {
  grep -E 'token=' "$LOG_FILE" 2>/dev/null | tail -1 \
    | grep -oE 'https?://[^/[:space:]]*/\?token=[A-Za-z0-9_-]+' 2>/dev/null | head -1
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
# 降级原因要报真话：日志里最后一条 token 可能是旧进程留下的（校验会 401），不能一律说成 no-token。
  [ -n "$AUTH_URL" ] || AUTH_URL="$(last_auth_url)"
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
  # 降级必须打印**具体原因**，且机器可 grep：没有 token 行 → no-token；有 token 行但校验不过 → HTTP <码>。
  if [ -z "$AUTH_CODE" ] || [ "$AUTH_CODE" = "no-token" ]; then
    _why="no-token（日志里还没有带 token 的 URL）"
  else
    _why="HTTP ${AUTH_CODE}（日志里的 token URL 未返回 303/302）"
  fi
  echo "[dsh] 打开裸 URL $_target —— 未能使用带 token 的地址：${_why}（浏览器已有登录 cookie 时仍可用；否则请重启服务：bash ~/dsh/restart_dsh_now.sh；日志：$LOG_FILE）"
  open_url "$_target"
}

# 打印/复制/打开带 token URL；排查提示（PWA 绕行 + 剪贴板）默认不打印，DSH_HINTS=1 才显示。
# 剪贴板一次要 0.75s 且会读回校验（失败不谎报），自动打开浏览器时纯属浪费，故默认不碰。
announce_and_open() {
  if [ "$NO_OPEN" = "1" ] || [ "${DSH_NO_OPEN:-0}" = "1" ]; then
    echo "[dsh] 服务已就绪（--no-open / DSH_NO_OPEN=1，未打开浏览器）：$1"
    return 0
  fi
  echo "[dsh] 打开 (带 token) $1"
  if [ "${DSH_HINTS:-0}" = "1" ] && [ "$OPEN_HOST" = "127.0.0.1" ]; then
    echo "[dsh] 若浏览器落在裸地址/显示 401（退回系统默认浏览器且该 origin 装过 PWA 时会发生：PWA 按 start_url 打开会丢掉 token），依次试："
    echo "[dsh]   1) DSH_ORIGIN=localhost bash ~/dsh/start_dsh.sh     # 换 origin，绕开 PWA（已验证可用）"
    echo "[dsh]   2) DSH_NO_OPEN=1 bash ~/dsh/start_dsh.sh            # 只打印 URL，自己粘到浏览器新标签页"
    echo "[dsh]   3) DSH_OPEN_APP=com.android.chrome bash ~/dsh/start_dsh.sh   /   DSH_OPEN_CHOOSER=1 ..."
  fi
  if [ "${DSH_HINTS:-0}" = "1" ]; then
    copy_url "$1" && echo "[dsh] 已复制该 URL 到剪贴板"
  fi
  open_url "$1"
}

# 流式跟随日志等 token：读到新打印的带 token 行即写 RESULT_FILE。
# ⚠️ 读循环用 FIFO 留在当前 shell（见下方 TAIL_PIPE 注释）：`tail -f | while` 的子 shell 会吞掉 break，
#    让「看见启动失败立刻退出」失效。结果与原因都经文件传回（RESULT_FILE / FAIL_FILE / PORT_FILE）。
_tmp_dir="${TMPDIR:-$HOME/.cache}"
RESULT_FILE="$_tmp_dir/dsh_start_url.$$"
if ! : > "$RESULT_FILE" 2>/dev/null; then
  RESULT_FILE="$BASE/storage/.dsh_start_url.$$"
  : > "$RESULT_FILE" 2>/dev/null || RESULT_FILE="/dev/null"
fi
# 端口标记：等 token 结束后才探一次端口（有响应=服务起了但没给 token，没响应=服务没起来）。
PORT_FILE="${RESULT_FILE}.port"
# 启动失败标记：日志里出现 dsh 的 startup failed 报告时立刻写它，免得白等满 READY_TIMEOUT。
FAIL_FILE="${RESULT_FILE}.fail"
# 流式跟随日志用的 FIFO：
# ⚠️ 读循环必须留在当前 shell。用 `tail -f | while ...` 时循环在子 shell 里，break 只结束子 shell、
#    tail 仍被 timeout 挂着，脚本照样等满 READY_TIMEOUT（实测 dsh 已报 startup failed 却还要空等 90s）。
TAIL_PIPE="${RESULT_FILE}.pipe"
TAIL_PID=""
# 要盯的 dsh pid（已运行的或本次拉起的）：交给 `tail --pid`，进程死掉就结束等待。
WATCH_PID=""
cleanup_tmp() {
  [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null
  rm -f "$RESULT_FILE" "$PORT_FILE" "$FAIL_FILE" "$TAIL_PIPE"
  # 计时打在 EXIT 上：成功/失败/复用/超时/中断都只打印一次，不会漏也不会重复。
  report_elapsed
}
trap cleanup_tmp EXIT INT TERM HUP

wait_for_token() {
  # 同一进程里可能等两次（「现有进程没就绪 → 自动重启」分支）：上一次收尾会把 TAIL_PIPE 清成空、
  # 标记文件也可能残留，不在这里重置就会 `mkfifo ''` 立刻失败 → 重启那条路必然打成「启动超时」。
  TAIL_PIPE="${RESULT_FILE}.pipe"
  : > "$RESULT_FILE" 2>/dev/null || true
  : > "$FAIL_FILE" 2>/dev/null || true
  : > "$PORT_FILE" 2>/dev/null || true
  _seen=0
  _url=""
  if ! command -v mkfifo >/dev/null 2>&1 || ! mkfifo "$TAIL_PIPE" 2>/dev/null; then
    TAIL_PIPE=""
    return 1
  fi
# `tail --pid` 是 GNU coreutils 的扩展（Termux 自带）：dsh 进程一死 tail 立刻退出，
# 读循环随即 EOF，于是「启动到一半就崩（YAML 错、原生绑定缺失…）」不用白等满 READY_TIMEOUT。
  _pid_arg=""
  if [ -n "$WATCH_PID" ] && tail --help 2>/dev/null | grep -q -- '--pid'; then
    _pid_arg="--pid=$WATCH_PID"
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$READY_TIMEOUT" tail -n 0 -f $_pid_arg "$LOG_FILE" 2>/dev/null >"$TAIL_PIPE" &
  else
    tail -n 0 -f $_pid_arg "$LOG_FILE" 2>/dev/null >"$TAIL_PIPE" &
  fi
  TAIL_PID=$!
# 等 token → 打开；返回 0 表示拿到带 token URL，3 表示 dsh 自己报了启动失败。
# 「startup failed」那行只是开头：继续读到 dsh 打印的 "Full diagnostics:" 才算错误块收完。
  while IFS= read -r _line; do
    _seen=$((_seen + 1))
    case "$_line" in
      *token=*)
# 同一行可能带 " (LAN: <url>)" 后缀：只取第一个 URL（loopback 部署下 LAN 地址不该交给浏览器）。
        _url="$(printf '%s\n' "$_line" | grep -oE 'https?://[^/[:space:]]*/\?token=[A-Za-z0-9_-]+' 2>/dev/null | head -1)"
        if [ -n "$_url" ] && check_url "$_url"; then
          printf '%s' "$_url" > "$RESULT_FILE"
          break
        fi
        ;;
      *"startup failed"*|*"could not write startup diagnostics"*|*"Full diagnostics:"*)
        [ -s "$FAIL_FILE" ] || printf '%s' "$_line" > "$FAIL_FILE"
        case "$_line" in
          *"Full diagnostics:"*|*"could not write startup diagnostics"*) break ;;
        esac
        ;;
    esac
  done < "$TAIL_PIPE"
  kill "$TAIL_PID" 2>/dev/null || true
  TAIL_PID=""
  [ -n "$TAIL_PIPE" ] && rm -f "$TAIL_PIPE"
  TAIL_PIPE=""
  [ -s "$RESULT_FILE" ] && return 0
# 进程已经在给出 token 前退出：崩了，而不是「还在冷启动」——拿日志末尾当原因报出去。
  if [ ! -s "$FAIL_FILE" ] && [ -n "$WATCH_PID" ] && ! kill -0 "$WATCH_PID" 2>/dev/null; then
    printf 'dsh 进程（pid %s）在给出带 token 的 URL 之前就退出了' "$WATCH_PID" > "$FAIL_FILE"
  fi
  [ -s "$FAIL_FILE" ] && return 3
  if port_up; then printf 'up' > "$PORT_FILE"; fi
  [ -s "$PORT_FILE" ] && return 2
  return 1
}

# A 复用：日志最后一条 token 仍可用就直接打开。
wait_and_open() {
  if [ "$NO_OPEN" != "1" ]; then
    echo "[dsh] 等待就绪（最长 ${READY_TIMEOUT}s）..."
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
  if [ "$_rc" = "3" ]; then
    echo "[dsh] dsh web 没有启动成功（进程已退出或在日志里报了失败），不再空等 ${READY_TIMEOUT}s。" >&2
    echo "[dsh] 失败原因：$(cat "$FAIL_FILE" 2>/dev/null || true)" >&2
    echo "[dsh] 最近日志（$LOG_FILE）：" >&2
    tail_log_since 30 >&2
    echo "[dsh] 完整诊断见 ~/.dsh/logs/startup-*.log" >&2
    return 1
  fi
  return 1
}

# 拉起新进程（--no-open：不让 dsh 自己 open —— 本脚本才能拿带 token URL 按包名递给浏览器）
# ⚠️ 必须把端口显式传给 dsh：dsh 不读 DSH_PORT / PORT 环境变量，只认 `--port`。
#    不传的话「脚本盯 DSH_PORT、服务却绑 3080」，会打印/打开一个没人监听的 URL（夹具用例 1 守着）。
launch() {
  mark_log_offset
  nohup dsh web --no-open --port "$PORT" >>"$LOG_FILE" 2>&1 &
  NEW_PID=$!
  WATCH_PID=$NEW_PID
  echo "$NEW_PID" > "$PID_FILE"
  echo "[dsh] 启动中 (pid $NEW_PID)... 日志: $LOG_FILE"
}

# 端口已被占用、但本机看不到对应的 dsh 进程：再拉起一个只会 EADDRINUSE 失败（实测 dsh 报
# "startup failed ... address already in use"），还要白等一轮冷启动。直接说清现状与可选做法。
explain_busy_port() {
  _who="一个 dsh web 实例"
  if command -v curl >/dev/null 2>&1 && ! curl -s --max-time 2 "$URL" 2>/dev/null | grep -q 'dsh web authentication required'; then
    _who="某个进程"
  fi
  echo "[dsh] 端口 $PORT 已被${_who}占用，但本机看不到它的进程（可能属于另一个用户/应用、root/su，或另一个终端会话）。" >&2
  echo "[dsh] 未启动新实例：再起一个只会因 EADDRINUSE 启动失败，还要白等一轮冷启动。" >&2
  echo "[dsh] 可以这样做：" >&2
  echo "[dsh]   1) 到启动它的窗口结束它，再重跑：bash ~/dsh/start_dsh.sh" >&2
  echo "[dsh]   2) 换端口另起一个：DSH_PORT=3081 bash ~/dsh/start_dsh.sh" >&2
  echo "[dsh]   3) 浏览器已登录（有 cookie）时，直接打开 http://${OPEN_HOST}:${PORT}/ 仍可用" >&2
}

# 有进程在跑但没等到 token：自动重启（旧进程可能没把 URL 写进当前日志）。
if open_if_auth_ready; then
  exit 0
fi

# B: 进程活着但 3080 没响应/没有新 token：不是本次日志写的 URL，跟随日志等它打印
if [ -n "$(running_pid)" ]; then
  WATCH_PID="$(running_pid)"
  mark_log_offset
  if wait_and_open; then exit 0; fi
  echo "[dsh] 现有 dsh 进程未在限定时间内就绪，自动重启"
  bash "$BASE/stop_dsh.sh" >/dev/null 2>&1 || true
fi

# C: 没有本机可见的 dsh 进程。端口若有响应，说明占着它的是「看不到的」实例或别的服务。
if port_up; then
  explain_busy_port
  exit 1
fi

# C2: 端口空闲 → 拉起新进程
launch
if wait_and_open; then exit 0; fi

echo "[dsh] 启动超时，最近日志："
tail_log_since 20
echo "[dsh] 若提示缺少模型密钥，请在 Web UI 的 Models 页面配置 DeepSeek API Key"
exit 1
