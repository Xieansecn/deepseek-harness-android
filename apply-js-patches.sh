#!/data/data/com.termux/files/usr/bin/bash
# 对已安装的 dsh 运行时 bundle 应用 JS 性能补丁（patches/01~05.patch）；幂等，过时的自动跳过并注明原因。
# 用法：bash apply-js-patches.sh；当前实际只有 04-frontend-static-cache 仍生效。
set -euo pipefail

DSH_PACKAGES_DIR="${DSH_PACKAGES_DIR:-/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHES=(01-apiproxy-history-slim 02-runtime-incremental-resync 03-connection-history-schema 04-frontend-static-cache 05-client-modules-cache)

# 0.1.2-rc.1 起以下补丁宿主模块已移除/重组或上游已原生实现：跳过不影响运行。
declare -A SUPERSEDED_NOTE=(
  [01-apiproxy-history-slim]="dsh-host-apiproxy 模块已移除，历史页重组到 dsh-api-session-controller"
  [02-runtime-incremental-resync]="dsh-client-runtime 模块已移除，窗口逻辑重组到 dsh-api-session-controller"
  [03-connection-history-schema]="0.1.2-rc.1 已移除对应 schema，无宿主"
  [05-client-modules-cache]="上游已原生实现（IMMUTABLE_CACHE）"
)

[ -d "$DSH_PACKAGES_DIR" ] || { echo "[apply-js-patches] 未找到 dsh 安装目录: $DSH_PACKAGES_DIR"; exit 1; }

applied=0; skipped=0; failed=0
for name in "${PATCHES[@]}"; do
  p="$HERE/patches/$name.patch"
  [ -f "$p" ] || { echo "  [FAIL] 缺少补丁文件 $p"; failed=$((failed+1)); continue; }

  if [ -n "${SUPERSEDED_NOTE[$name]:-}" ]; then
    echo "  [skip] $name 已过时：${SUPERSEDED_NOTE[$name]}"
    skipped=$((skipped+1))
    continue
  fi

  if (cd "$DSH_PACKAGES_DIR" && patch -p1 -N -s -R --dry-run -i "$p" < /dev/null) >/dev/null 2>&1; then
    echo "  [skip] $name 已应用"
    skipped=$((skipped+1))
  elif (cd "$DSH_PACKAGES_DIR" && patch -p1 -N -s --dry-run -i "$p" < /dev/null) >/dev/null 2>&1; then
    if (cd "$DSH_PACKAGES_DIR" && patch -p1 -N -s -i "$p" < /dev/null) >/dev/null 2>&1; then
      echo "  [ok]   $name 已应用"
      applied=$((applied+1))
    else
      echo "  [FAIL] $name 应用失败"
      failed=$((failed+1))
    fi
  else
    echo "  [FAIL] $name 无法应用（dsh 版本不匹配？请先重跑 setup.sh 或升级后重试）"
    failed=$((failed+1))
  fi
done

echo "[apply-js-patches] 完成：应用 $applied，跳过 $skipped，失败 $failed"
[ "$failed" -eq 0 ]
