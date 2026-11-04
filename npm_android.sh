#!/data/data/com.termux/files/usr/bin/bash
# Termux/Android 下的 npm 包装：给所有调用注入 Android 目标编译参数。
#
# 为什么需要它：直接运行 `npm -g update` 时，dsh 依赖里的 koffi@3.1.1 会走
# `cnoke --prebuild` 的本地回退编译。koffi 的 `lib/native/base/base.cc` 调用了
# bionic 的 `statx()`，而该函数只在 `-target aarch64-linux-android30`（且
# `_GNU_SOURCE`）下声明；Termux clang 默认 target 是 android24，于是编译器把
# `statx(...)` 当成结构体聚合初始化，报：
#   cannot initialize a member subobject of type '__u32' ... with an lvalue of type 'const char *'
# setup.sh 已经在 `npm install -g` 命令内联设置了 CFLAGS/CXXFLAGS；但手动
# `npm -g update` 不经过 setup.sh，就会踩到上面的错误。本包装把同一组参数
# 注入任意 npm 调用，保留调用方已有的 CFLAGS/CXXFLAGS。
#
# 用法：
#   bash npm_android.sh -g update
#   bash npm_android.sh install -g @deepseek-ai/dsh
#   bash npm_android.sh install --no-audit --no-fund koffi@3.1.1
#
# 注意：升级 dsh 的完整流程仍应使用 `bash setup.sh`（安装后会重打 Android
# 兼容补丁）；本脚本只解决 npm 原生模块编译阶段的参数问题。
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ANDROID_TARGET="${DSH_ANDROID_TARGET:-aarch64-linux-android30}"

# 把 Android target 与 Termux include 追加到编译参数中；已有则不再重复。
android_compile_flags() {
  local flags="${1:-}"
  case " $flags " in
    *" -target "*) ;;
    *) flags="${flags:+$flags }-target $ANDROID_TARGET" ;;
  esac
  case " $flags " in
    *" -I$PREFIX/include "*) ;;
    *) flags="${flags:+$flags }-I$PREFIX/include" ;;
  esac
  printf '%s' "$flags"
}

CFLAGS="$(android_compile_flags "${CFLAGS:-}")"
CXXFLAGS="$(android_compile_flags "${CXXFLAGS:-}")"
export CFLAGS CXXFLAGS

# Termux 上 npm-cli.js 的 shebang 写死 #!/usr/bin/env node，而部分 Android
# 命名空间里 /usr/bin 不可解析；优先用 `node <npm-cli.js>`（与 setup.sh 一致）。
NPM_CMD=(npm)
if NPM_BIN="$(command -v npm 2>/dev/null)"; then
  NPM_REAL="$(readlink -f "$NPM_BIN" 2>/dev/null || printf '%s' "$NPM_BIN")"
  case "$NPM_REAL" in
    *.js) NPM_CMD=(node "$NPM_REAL") ;;
  esac
fi

exec "${NPM_CMD[@]}" "$@"
