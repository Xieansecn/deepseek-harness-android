#!/data/data/com.termux/files/usr/bin/bash
# 对已安装的 dsh 运行时 bundle 应用 JS 性能补丁（patches/01~03.patch）；幂等：已应用则 [skip]。
# 用法：bash apply-js-patches.sh
# 补丁分层（版本漂移容错）：
#   01/02 是 0.1.5 线的全量性能补丁（02 含 compose 惰性化；0.1.7 起上游用原生 lazyBody
#   实现了同一件事，锚点必然失配——由 superseded_by_upstream() 判为 [skip] 而不是失败）；
#   03 只改 newlineCount，锚点跨 0.1.5/0.1.7 都稳定，是版本无关的兜底性能补丁。
# 三种结果：已应用/已存在 [skip]、失配但上游已替代 [skip]、其余 [FAIL]（退出码非 0）。
#   ⚠️ 只有能**证明**「上游已实现同一优化」的补丁才允许走第二个 [skip]：否则真失配会被淹没，
#   退化成「狼来了」。判据必须查实际源码（例如 client-modules 里是否有 function lazyBody）。
# 逐字节核对方式：npm pack 对应版本源码 → 正向打补丁 → 与安装树 diff。
set -euo pipefail

DSH_PACKAGES_DIR="${DSH_PACKAGES_DIR:-/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCHES=(01-frontend-static-cache 02-client-modules-lazy-compose 03-client-modules-newline-count)

[ -d "$DSH_PACKAGES_DIR" ] || { echo "[apply-js-patches] 未找到 dsh 安装目录: $DSH_PACKAGES_DIR"; exit 1; }

# 「上游已原生实现同一优化」的判据：命中则锚点失配算 [skip]（好消息），不计入 failed。
# 注意 cwd 无关：这些检查都按绝对路径读文件，不依赖 patch 的 -p1 语义。
superseded_by_upstream() {
  case "$1" in
    02-client-modules-lazy-compose)
      # 02 的目标是「combo 按需构建」；上游原生 lazyBody 就是同一实现（0.1.7 起）。
      grep -q "function lazyBody" "$DSH_PACKAGES_DIR/dsh-client-modules/lib/index.js" 2>/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

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
  elif superseded_by_upstream "$name"; then
    echo "  [skip] $name 锚点失配，但上游已原生实现同一优化（无需补丁）"
    skipped=$((skipped+1))
  else
    echo "  [FAIL] $name 锚点失配（dsh 版本漂移？）——跳过，不影响 dsh 本身运行"
    failed=$((failed+1))
  fi
done

echo "[apply-js-patches] 完成：应用 $applied，跳过 $skipped，失败 $failed"
[ "$failed" -eq 0 ]
