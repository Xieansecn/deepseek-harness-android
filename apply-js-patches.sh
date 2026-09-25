#!/data/data/com.termux/files/usr/bin/bash
# 对已安装的 dsh 运行时 bundle 应用 JS 性能补丁（patches/01~03.patch）；幂等：已应用则 [skip]。
# 用法：bash apply-js-patches.sh
# 补丁分层（版本漂移容错）：
#   01/02 是 0.1.5 线的全量性能补丁（02 含 compose 惰性化，0.1.7 起上游已原生实现 lazyBody，锚点会失配→[FAIL] 跳过）；
#   03 只改 newlineCount，锚点跨 0.1.5/0.1.7 都稳定，是版本无关的兜底性能补丁。
# 逐字节核对方式：npm pack 对应版本源码 → 正向打补丁 → 与安装树 diff。
set -euo pipefail

DSH_PACKAGES_DIR="${DSH_PACKAGES_DIR:-/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHES=(01-frontend-static-cache 02-client-modules-lazy-compose 03-client-modules-newline-count)

[ -d "$DSH_PACKAGES_DIR" ] || { echo "[apply-js-patches] 未找到 dsh 安装目录: $DSH_PACKAGES_DIR"; exit 1; }

applied=0; skipped=0; failed=0
for name in "${PATCHES[@]}"; do
  p="$HERE/patches/$name.patch"
  [ -f "$p" ] || { echo "  [FAIL] 缺少补丁文件 $p"; failed=$((failed+1)); continue; }

# 幂等判定：能反向 dry-run 说明已经打过；正向 dry-run 才允许落盘。
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
    echo "  [FAIL] $name 锚点失配（dsh 版本漂移？）——跳过，不影响 dsh 本身运行"
    failed=$((failed+1))
  fi
done

echo "[apply-js-patches] 完成：应用 $applied，跳过 $skipped，失败 $failed"
[ "$failed" -eq 0 ]
