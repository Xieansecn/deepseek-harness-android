#!/data/data/com.termux/files/usr/bin/bash
# 修复 grep/glob 报 "ripgrep launch failed"：@vscode/ripgrep 无 Android 平台包，软链平台包到系统 rg 并给 resolveRgPath() 加回退。
# 用法：bash apply-rg-fix.sh；幂等，dsh 更新清空 node_modules 后必须重跑。
set -euo pipefail

DSH_ROOT="${DSH_ROOT:-/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh}"
SEARCH_LIB="$DSH_ROOT/node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js"
PLATFORM_BIN="$DSH_ROOT/node_modules/@vscode/ripgrep-android-arm64/bin"

echo "==> DSH root: $DSH_ROOT"
if [ ! -d "$DSH_ROOT" ]; then
	echo "ERROR: DSH_ROOT not found: $DSH_ROOT" >&2
	exit 1
fi
if [ ! -f "$SEARCH_LIB" ]; then
	echo "ERROR: dsh-tool-fs-search lib not found: $SEARCH_LIB" >&2
	exit 1
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
node - "$SEARCH_LIB" <<'JS'
const fs = require('fs');
const lib = process.argv[2];
let src = fs.readFileSync(lib, 'utf8');

if (src.includes('resolveSystemRg')) {
  console.log('    already patched, skipping');
  process.exit(0);
}

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
}

if (!originalFound) {
  console.error('ERROR: original resolveRgPath() not found in ' + lib);
  console.error('The code likely changed in this version; patch manually.');
  process.exit(1);
}
fs.writeFileSync(lib, src);
console.log('    patched OK');
JS

# 3. 验证：用全新 node 子进程实际解析一次 rg 路径并打印版本
echo "==> step 3/3: verify resolution in a fresh node process"
if ! (
  cd "$(dirname "$SEARCH_LIB")"
  node -e "import('./index.js').then(async m=>{const p=await m.resolveRgPath();const {execFileSync}=await import('node:child_process');console.log('    resolved: '+p);console.log('    version:  '+execFileSync(p,['--version']).toString().split(String.fromCharCode(10))[0]);})"
) 2>&1; then
  echo
  echo "ERROR: resolveRgPath() 校验失败。grep/glob 工具在 dsh 里将不可用（ripgrep launch failed）。" >&2
  echo "   可能原因：resolveRgPath() 补丁未命中 dsh-tool-fs-search，或系统 rg 无法执行。" >&2
  echo "   请人工核对 $SEARCH_LIB 的 resolveRgPath()，并确认 $(echo "$RG") --version 可用。" >&2
  echo "   修复前请勿启动 dsh web（否则 grep/glob 会报错）。" >&2
  exit 1
fi

echo
echo "==> DONE. 重启 dsh web 后生效：bash ~/dsh/restart_dsh_now.sh"
