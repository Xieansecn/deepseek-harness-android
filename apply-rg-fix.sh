#!/data/data/com.termux/files/usr/bin/bash
# 修复 grep/glob 报 "ripgrep launch failed"：@vscode/ripgrep 无 Android 平台包，软链平台包到系统 rg 并给 resolveRgPath() 加回退。
# 用法：bash apply-rg-fix.sh；幂等，dsh 更新清空 node_modules 后必须重跑。
#
# resolveRgPath() 的宿主随上游重构搬过家（不按版本号分支，按「文件存在 + 语义形状」定位）：
#   - ≤ 0.2.2-rc.1 / 0.2.1 线：定义在 dsh-tool-fs-search/lib/index.js
#   - 0.2.2-rc.3+           ：拆进新包 dsh-util-ripgrep/lib/index.js（tool-fs-search 只 import 并再导出）
# 两处都是候选：存在哪个就修哪个，都存在就都修；验证时以 tool-fs-search 实际引用的一方为准。
set -euo pipefail

DSH_ROOT="${DSH_ROOT:-/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh}"
SEARCH_LIB="$DSH_ROOT/node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js"
UTIL_RG_LIB="$DSH_ROOT/node_modules/@deepseek-ai/dsh-util-ripgrep/lib/index.js"
PLATFORM_BIN="$DSH_ROOT/node_modules/@vscode/ripgrep-android-arm64/bin"

echo "==> DSH root: $DSH_ROOT"
if [ ! -d "$DSH_ROOT" ]; then
	echo "ERROR: DSH_ROOT not found: $DSH_ROOT" >&2
	exit 1
fi
# resolveRgPath() 的两代落点都收进候选；一个都找不到说明 dsh 安装不完整（grep/glob 工具包本身缺失）。
TARGET_LIBS=()
[ -f "$SEARCH_LIB" ] && TARGET_LIBS+=("$SEARCH_LIB")
[ -f "$UTIL_RG_LIB" ] && TARGET_LIBS+=("$UTIL_RG_LIB")
if [ "${#TARGET_LIBS[@]}" -eq 0 ]; then
	echo "ERROR: 找不到 resolveRgPath() 的宿主包（dsh 安装不完整？）：$SEARCH_LIB | $UTIL_RG_LIB" >&2
	exit 1
fi
# 验证落点 = 搜索工具**实际引用**的 resolveRgPath 实现：
#   0.2.2-rc.3+ 的 tool-fs-search 从 dsh-util-ripgrep import（此时只验证 util 包）；
#   旧线 tool-fs-search 自己定义并导出 resolveRgPath（没有 util 包）。
VERIFY_LIB="${TARGET_LIBS[${#TARGET_LIBS[@]}-1]}"
if [ -f "$SEARCH_LIB" ]; then
	if grep -qF '@deepseek-ai/dsh-util-ripgrep' "$SEARCH_LIB" 2>/dev/null; then
		[ -f "$UTIL_RG_LIB" ] && VERIFY_LIB="$UTIL_RG_LIB"
	else
		grep -qF 'function resolveRgPath' "$SEARCH_LIB" 2>/dev/null && VERIFY_LIB="$SEARCH_LIB"
	fi
fi

# ---- 0. locate a system rg ----
RG="${RG_PATH:-$(command -v rg || true)}"
if [ -z "$RG" ] || [ ! -x "$RG" ]; then
	echo "ERROR: no usable system rg (install it: pkg install ripgrep)" >&2
	exit 1
fi
echo "==> system rg: $RG ($("$RG" --version | head -1))"

# ---- 1. platform binary symlink (what @vscode/ripgrep expects) ----
echo "==> step 1/3: symlink packaged platform rg -> system rg"
mkdir -p "$PLATFORM_BIN"
ln -sf "$RG" "$PLATFORM_BIN/rg"

# 1. 软链平台包到系统 rg（@vscode/ripgrep 期望的路径）
echo "==> step 2/3: patch resolveRgPath() fallback"
node - "${TARGET_LIBS[@]}" <<'JS'
const fs = require('fs');
// One or both hosts of resolveRgPath(): tool-fs-search (old) and util-ripgrep (0.2.2-rc.3+).
const libs = process.argv.slice(2);

const ORIG = [
  'function resolveRgPath() {',
  '\trgPathPromise ??= import("@vscode/ripgrep").then((module) => module.rgPath);',
  '\treturn rgPathPromise;',
  '}',
].join('\n');

const CURRENT_ORIG = [
  'function resolveRgPath() {',
  '\trgPathPromise ??= Promise.resolve().then(async () => {',
  '\t\tconst executableSidecar = `${process.execPath}-rg`;',
  '\t\tif ("pkg" in process && existsSync(executableSidecar)) return executableSidecar;',
  '\t\treturn (await import("@vscode/ripgrep")).rgPath;',
  '\t});',
  '\treturn rgPathPromise;',
  '}',
].join('\n');

const NEW_ORIG = [
  'function resolveRgPath() {',
  '\trgPathPromise ??= Promise.resolve().then(async () => {',
  '\t\tconst executable = parse(process.execPath);',
  '\t\tconst executableSidecar = process.platform === "win32" ? join(executable.dir, `${executable.name}-rg.exe`) : `${process.execPath}-rg`;',
  '\t\tif ("pkg" in process && existsSync(executableSidecar)) return executableSidecar;',
  '\t\treturn (await import("@vscode/ripgrep")).rgPath;',
  '\t});',
  '\treturn rgPathPromise;',
  '}',
].join('\n');

const PATCHED_OLD = [
  '/**',
  ' * Locate a usable system `rg` binary as a fallback.',
  ' *',
  ' * `@vscode/ripgrep` only publishes prebuilt binaries for darwin/win32/linux;',
  ' * on other platforms (Termux/Android, ...) its platform package is absent and',
  ' * `import("@vscode/ripgrep")` rejects. When that happens the search tools fall',
  ' * back to an `rg` found on `PATH` (or an explicit `RG_PATH`), keeping `grep` /',
  ' * `glob` functional wherever ripgrep is installed system-wide.',
  ' */',
  'async function resolveSystemRg() {',
  '\tif (process.env.RG_PATH) return process.env.RG_PATH;',
  '\ttry {',
  '\t\tconst { execFileSync } = await import("node:child_process");',
  '\t\tconst which = process.platform === "win32" ? "where" : "which";',
  '\t\tconst found = execFileSync(which, ["rg"], { encoding: "utf8" }).split(/\\r?\\n/)[0]?.trim();',
  '\t\tif (found) return found;',
  '\t} catch { /* no `which`/`where`; fall through to bare "rg" via PATH */ }',
  '\treturn "rg";',
  '}',
  'function resolveRgPath() {',
  '\trgPathPromise ??= import("@vscode/ripgrep")',
  '\t\t.then((module) => module.rgPath)',
  '\t\t.catch(() => resolveSystemRg());',
  '\treturn rgPathPromise;',
  '}',
].join('\n');

const PATCHED_CURRENT = [
  '/**',
  ' * Locate a usable system `rg` binary as a fallback.',
  ' *',
  ' * `@vscode/ripgrep` only publishes prebuilt binaries for darwin/win32/linux;',
  ' * on other platforms (Termux/Android, ...) its platform package is absent and',
  ' * `import("@vscode/ripgrep")` rejects. When that happens the search tools fall',
  ' * back to an `rg` found on `PATH` (or an explicit `RG_PATH`), keeping `grep` /',
  ' * `glob` functional wherever ripgrep is installed system-wide.',
  ' */',
  'async function resolveSystemRg() {',
  '\tif (process.env.RG_PATH) return process.env.RG_PATH;',
  '\ttry {',
  '\t\tconst { execFileSync } = await import("node:child_process");',
  '\t\tconst which = process.platform === "win32" ? "where" : "which";',
  '\t\tconst found = execFileSync(which, ["rg"], { encoding: "utf8" }).split(/\\r?\\n/)[0]?.trim();',
  '\t\tif (found) return found;',
  '\t} catch { /* no `which`/`where`; fall through to bare "rg" via PATH */ }',
  '\treturn "rg";',
  '}',
  'function resolveRgPath() {',
  '\trgPathPromise ??= Promise.resolve().then(async () => {',
  '\t\tconst executableSidecar = `${process.execPath}-rg`;',
  '\t\tif ("pkg" in process && existsSync(executableSidecar)) return executableSidecar;',
  '\t\ttry {',
  '\t\t\treturn (await import("@vscode/ripgrep")).rgPath;',
  '\t\t} catch {',
  '\t\t\treturn resolveSystemRg();',
  '\t\t}',
  '\t});',
  '\treturn rgPathPromise;',
  '}',
].join('\n');

const PATCHED_NEW = [
  '/**',
  ' * Locate a usable system `rg` binary as a fallback.',
  ' *',
  ' * `@vscode/ripgrep` only publishes prebuilt binaries for darwin/win32/linux;',
  ' * on other platforms (Termux/Android, ...) its platform package is absent and',
  ' * `import("@vscode/ripgrep")` rejects. When that happens the search tools fall',
  ' * back to an `rg` found on `PATH` (or an explicit `RG_PATH`), keeping `grep` /',
  ' * `glob` functional wherever ripgrep is installed system-wide.',
  ' */',
  'async function resolveSystemRg() {',
  '\tif (process.env.RG_PATH) return process.env.RG_PATH;',
  '\ttry {',
  '\t\tconst { execFileSync } = await import("node:child_process");',
  '\t\tconst which = process.platform === "win32" ? "where" : "which";',
  '\t\tconst found = execFileSync(which, ["rg"], { encoding: "utf8" }).split(/\\r?\\n/)[0]?.trim();',
  '\t\tif (found) return found;',
  '\t} catch { /* no `which`/`where`; fall through to bare "rg" via PATH */ }',
  '\treturn "rg";',
  '}',
  'function resolveRgPath() {',
  '\trgPathPromise ??= Promise.resolve().then(async () => {',
  '\t\tconst executable = parse(process.execPath);',
  '\t\tconst executableSidecar = process.platform === "win32" ? join(executable.dir, `${executable.name}-rg.exe`) : `${process.execPath}-rg`;',
  '\t\tif ("pkg" in process && existsSync(executableSidecar)) return executableSidecar;',
  '\t\ttry {',
  '\t\t\treturn (await import("@vscode/ripgrep")).rgPath;',
  '\t\t} catch {',
  '\t\t\treturn resolveSystemRg();',
  '\t\t}',
  '\t});',
  '\treturn rgPathPromise;',
  '}',
].join('\n');

// 0.1.7-rc.2 起：@vscode/ripgrep 的解析结果外包了一层 electron asar 归一化（先赋给 dependency）。
const NEW_ELECTRON_ORIG = [
  'function resolveRgPath() {',
  '\trgPathPromise ??= Promise.resolve().then(async () => {',
  '\t\tconst executable = parse(process.execPath);',
  '\t\tconst executableSidecar = process.platform === "win32" ? join(executable.dir, `${executable.name}-rg.exe`) : `${process.execPath}-rg`;',
  '\t\tif ("pkg" in process && existsSync(executableSidecar)) return executableSidecar;',
  '\t\tconst dependency = (await import("@vscode/ripgrep")).rgPath;',
  '\t\treturn process.versions.electron === void 0 ? dependency : dependency.replace(/\\.asar(?=[\\\\/])/u, ".asar.unpacked");',
  '\t});',
  '\treturn rgPathPromise;',
  '}',
].join('\n');

const PATCHED_ELECTRON = [
  '/**',
  ' * Locate a usable system `rg` binary as a fallback.',
  ' *',
  ' * `@vscode/ripgrep` only publishes prebuilt binaries for darwin/win32/linux;',
  ' * on other platforms (Termux/Android, ...) its platform package is absent and',
  ' * `import("@vscode/ripgrep")` rejects. When that happens the search tools fall',
  ' * back to an `rg` found on `PATH` (or an explicit `RG_PATH`), keeping `grep` /',
  ' * `glob` functional wherever ripgrep is installed system-wide.',
  ' */',
  'async function resolveSystemRg() {',
  '\tif (process.env.RG_PATH) return process.env.RG_PATH;',
  '\ttry {',
  '\t\tconst { execFileSync } = await import("node:child_process");',
  '\t\tconst which = process.platform === "win32" ? "where" : "which";',
  '\t\tconst found = execFileSync(which, ["rg"], { encoding: "utf8" }).split(/\\r?\\n/)[0]?.trim();',
  '\t\tif (found) return found;',
  '\t} catch { /* no `which`/`where`; fall through to bare "rg" via PATH */ }',
  '\treturn "rg";',
  '}',
  'function resolveRgPath() {',
  '\trgPathPromise ??= Promise.resolve().then(async () => {',
  '\t\tconst executable = parse(process.execPath);',
  '\t\tconst executableSidecar = process.platform === "win32" ? join(executable.dir, `${executable.name}-rg.exe`) : `${process.execPath}-rg`;',
  '\t\tif ("pkg" in process && existsSync(executableSidecar)) return executableSidecar;',
  '\t\ttry {',
  '\t\t\tconst dependency = (await import("@vscode/ripgrep")).rgPath;',
  '\t\t\treturn process.versions.electron === void 0 ? dependency : dependency.replace(/\\.asar(?=[\\\\/])/u, ".asar.unpacked");',
  '\t\t} catch {',
  '\t\t\treturn resolveSystemRg();',
  '\t\t}',
  '\t});',
  '\treturn rgPathPromise;',
  '}',
].join('\n');

let patched = 0;
let already = 0;
for (const lib of libs) {
  if (!lib) continue;
  let src;
  try {
    src = fs.readFileSync(lib, 'utf8');
  } catch (error) {
    console.log(`    [warn] cannot read ${lib}: ${error.message}`);
    continue;
  }
  if (src.includes('resolveSystemRg')) {
    console.log(`    already patched, skipping: ${lib}`);
    already++;
    continue;
  }
  // 0.2.2-rc.3+ 的 dsh-tool-fs-search 只 import/再导出 resolveRgPath，不再定义它：
  // 没有函数定义的文件是消费者而不是宿主，静默跳过（不发 warn，避免每次 setup 刷假漂移）。
  if (!/(?:^|\n)\s*(?:async\s+)?function\s+resolveRgPath\s*\(/.test(src)) continue;
  let originalFound = false;
  if (src.includes(ORIG)) {
    src = src.replace(ORIG, PATCHED_OLD);
    originalFound = true;
  } else if (src.includes(CURRENT_ORIG)) {
    src = src.replace(CURRENT_ORIG, PATCHED_CURRENT);
    originalFound = true;
  } else if (src.includes(NEW_ORIG)) {
    src = src.replace(NEW_ORIG, PATCHED_NEW);
    originalFound = true;
  } else if (src.includes(NEW_ELECTRON_ORIG)) {
    src = src.replace(NEW_ELECTRON_ORIG, PATCHED_ELECTRON);
    originalFound = true;
  }
  if (!originalFound) {
    // Anchor drift is not fatal: the step-1 platform symlink alone makes @vscode/ripgrep resolve
    // (it only does require.resolve(`${platformPkg}/bin/rg`)); the source fallback is belt-and-braces.
    // Step 3 decides whether the resolution actually works.
    console.log(`    [warn] unrecognized resolveRgPath() shape (dsh drift), skipping source fallback: ${lib}`);
    continue;
  }
  try {
    fs.writeFileSync(lib, src);
  } catch (error) {
    console.log(`    [error] cannot write ${lib}: ${error.message}`);
    process.exitCode = 1;
    continue;
  }
  console.log(`    patched OK: ${lib}`);
  patched++;
}
if (patched === 0 && already === 0) {
  console.log('           platform symlink is in place; step 3 decides by the actual resolution result');
}
JS

# 3. 验证：用全新 node 子进程实际解析一次 rg 路径并打印版本（验证的是搜索工具实际引用的那个实现）。
echo "==> step 3/3: verify resolution in a fresh node process ($VERIFY_LIB)"
if ! (
  cd "$(dirname "$VERIFY_LIB")"
  node -e "import('./index.js').then(async m=>{if(typeof m.resolveRgPath!=='function')throw new Error('index.js 未导出 resolveRgPath');const p=await m.resolveRgPath();const {execFileSync}=await import('node:child_process');console.log('    resolved: '+p);console.log('    version:  '+execFileSync(p,['--version']).toString().split(String.fromCharCode(10))[0]);})"
) 2>&1; then
  echo
  echo "ERROR: resolveRgPath() 校验失败。grep/glob 工具在 dsh 里将不可用（ripgrep launch failed）。" >&2
  echo "   可能原因：resolveRgPath() 补丁未命中它的宿主包（旧线 dsh-tool-fs-search / 0.2.2-rc.3+ dsh-util-ripgrep），或系统 rg 无法执行。" >&2
  echo "   请人工核对 $VERIFY_LIB 的 resolveRgPath()，并确认 $RG --version 可用。" >&2
  echo "   修复前请勿启动 dsh web（否则 grep/glob 会报错）。" >&2
  exit 1
fi

echo
echo "==> DONE. 重启 dsh web 后生效：bash ~/dsh/restart_dsh_now.sh"
