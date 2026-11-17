#!/data/data/com.termux/files/usr/bin/bash
# 对已安装的 dsh 运行时 bundle 应用 JS 性能补丁；幂等：已应用则 [skip]。
# 用法：bash apply-js-patches.sh
#
# 两个补丁（都面向 0.2.2-rc.1 / 0.2.2-rc.3）：
#   01-frontend-static-cache        —— /assets/ 内容哈希资源加 immutable 缓存头。
#   03-client-modules-newline-count —— newlineCount() 的 for-of 改 charCodeAt 索引循环（版本无关兜底）。
# 历史上还有一个 02-client-modules-lazy-compose（客户端 combo 按需构建，只对 0.1.5 线有效）；
# 0.1.7 起上游用原生 lazyBody 实现同一优化，锚点消失，该补丁与「弃用围栏」机制已删除。
#
# 输出：已应用/已存在 [skip]、应用成功 [ok]、失配或写失败 [FAIL]（退非 0）。
# 逐字节核对方式：npm pack 对应版本源码 → 正向打补丁 → 与安装树 diff。
set -euo pipefail

DSH_PACKAGES_DIR="${DSH_PACKAGES_DIR:-/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai}"
HERE="$(cd "$(dirname "$0")" && pwd)"

PATCHES=(01-frontend-static-cache 03-client-modules-newline-count)

[ -d "$DSH_PACKAGES_DIR" ] || { echo "[apply-js-patches] 未找到 dsh 安装目录: $DSH_PACKAGES_DIR"; exit 1; }

applied=0; skipped=0; failed=0
for name in "${PATCHES[@]}"; do
  p="$HERE/patches/$name.patch"
  [ -f "$p" ] || { echo "  [FAIL] 缺少补丁文件 $p"; failed=$((failed+1)); continue; }

# 幂等判定：能反向 dry-run 说明已经打过；正向 dry-run 才允许落盘。
# ⚠️ patch -p1 的 cwd 必须是**包目录的父级**（=$DSH_PACKAGES_DIR），不是包目录本身：
#    补丁里的路径是 a/dsh-client-modules/lib/index.js，-p1 后相对父级才对得上。
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
