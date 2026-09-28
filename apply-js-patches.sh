#!/data/data/com.termux/files/usr/bin/bash
# 对已安装的 dsh 运行时 bundle 应用 JS 性能补丁；幂等：已应用则 [skip]。
# 用法：bash apply-js-patches.sh
#
# 两个区：
#   活跃清单 PATCHES           —— 锚点有效的补丁，失配即 [FAIL] 并让脚本退非 0。
#   已弃用围栏 DEPRECATED_PATCHES —— 锚点已失效（上游已重构/已原生实现）但为**旧版本线**保留的补丁。
#     围栏规则：能命中就照打（旧线仍有效，报 [ok]）；命中不了只报 [deprecated] 且**不计失败**。
#     ⚠️ 锚点失效后**不要**留在活跃清单里——每次安装刷一条 [FAIL] 会让 setup.sh 8/9 报警，
#     久而久之变成「狼来了」，真正需要人看的失配会被淹没。要么移进围栏，要么删掉。
#     移进围栏时必须写清 deprecated_reason()：失配原因 + 复活条件（见 AGENTS §12）。
#
# 三种输出：已应用/已存在 [skip]、应用成功 [ok]、失配或写失败 [FAIL]（仅活跃清单会让退出码非 0）。
# 逐字节核对方式：npm pack 对应版本源码 → 正向打补丁 → 与安装树 diff。
set -euo pipefail

DSH_PACKAGES_DIR="${DSH_PACKAGES_DIR:-/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai}"
HERE="$(cd "$(dirname "$0")" && pwd)"

PATCHES=(01-frontend-static-cache 02-client-modules-lazy-compose 03-client-modules-newline-count)
# ⚠️ PATCHES 的**顺序即语义**：02 与 03 改的是同一段 newlineCount，必须 02 先、03 后
# （02 全量惰性化+索引循环，03 只补索引循环；03 先跑会让 02 的上下文失配）。
# 围栏只改变「报告与退出码语义」，**不得改变执行顺序**——别按活跃/弃用分区重排。
DEPRECATED_PATCHES=(02-client-modules-lazy-compose)

[ -d "$DSH_PACKAGES_DIR" ] || { echo "[apply-js-patches] 未找到 dsh 安装目录: $DSH_PACKAGES_DIR"; exit 1; }

# 弃用原因 + 复活条件（围栏里的补丁必须各有一条）。
deprecated_reason() {
  case "$1" in
    02-client-modules-lazy-compose)
      echo "0.1.7 起上游用原生 lazyBody 实现了 combo 按需构建（同一优化），锚点随之消失；仅 0.1.5 线仍可能需要"
      ;;
    *)
      echo "锚点已失效（未登记原因，请补 deprecated_reason）"
      ;;
  esac
}

is_deprecated() {
  local n
  for n in "${DEPRECATED_PATCHES[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

applied=0; skipped=0; failed=0; deprecated=0
for name in "${PATCHES[@]}"; do
  p="$HERE/patches/$name.patch"
  [ -f "$p" ] || { echo "  [FAIL] 缺少补丁文件 $p"; failed=$((failed+1)); continue; }
  dep=0; is_deprecated "$name" && dep=1

# 幂等判定：能反向 dry-run 说明已经打过；正向 dry-run 才允许落盘。
# ⚠️ patch -p1 的 cwd 必须是**包目录的父级**（=$DSH_PACKAGES_DIR），不是包目录本身：
#    补丁里的路径是 a/dsh-client-modules/lib/index.js，-p1 后相对父级才对得上。
  if (cd "$DSH_PACKAGES_DIR" && patch -p1 -N -s -R --dry-run -i "$p" < /dev/null) >/dev/null 2>&1; then
    echo "  [skip] $name 已应用"
    skipped=$((skipped+1))
  elif (cd "$DSH_PACKAGES_DIR" && patch -p1 -N -s --dry-run -i "$p" < /dev/null) >/dev/null 2>&1; then
    if (cd "$DSH_PACKAGES_DIR" && patch -p1 -N -s -i "$p" < /dev/null) >/dev/null 2>&1; then
      if [ "$dep" = 1 ]; then
        echo "  [ok]   $name 已应用（弃用围栏：在目标版本上仍然有效）"
      else
        echo "  [ok]   $name 已应用"
      fi
      applied=$((applied+1))
    else
      echo "  [FAIL] $name 应用失败"
      failed=$((failed+1))
    fi
  elif [ "$dep" = 1 ]; then
    echo "  [deprecated] $name 锚点已失效：$(deprecated_reason "$name")"
    deprecated=$((deprecated+1))
  else
    echo "  [FAIL] $name 锚点失配（dsh 版本漂移？）——跳过，不影响 dsh 本身运行"
    failed=$((failed+1))
  fi
done

echo "[apply-js-patches] 完成：应用 $applied，跳过 $skipped，失败 $failed，弃用 $deprecated"
[ "$failed" -eq 0 ]
