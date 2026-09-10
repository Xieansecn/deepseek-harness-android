#!/data/data/com.termux/files/usr/bin/node
/**
 * patch-dsh-android-flock.js
 *
 * 修复 Android/Termux 上 dsh 发消息时报：
 *
 *   Error: flock is not supported on android-arm64
 *
 * 根因：dsh-session-persistence-jsonl 在获取会话写锁时调用
 * `@deepseek-ai/node-addon-system/flock` 的 tryLockExclusive(fd)。该包的
 * lib/flock.js 只接受 platform 为 linux/darwin，且上游只发布
 * linux-{x64,arm64}/darwin-* 预编译包，没有 Android 版；Termux 的
 * process.platform === "android" 因此直接抛 ERR_FLOCK_UNSUPPORTED_PLATFORM。
 *
 * Android bionic 本身支持 flock(2)（已实测）。本脚本：
 *   1. 用 clang 把 node-addon-system 自带的 src/flock.c 编译成本机
 *      system.node（Node-API，Node headers 来自 $PREFIX/include/node 或
 *      ~/.cache/node-gyp/<ver>/include/node）；
 *   2. 把产物放到 <node-addon-system>/bin/android-<arch>/system.node；
 *   3. 就地修补 lib/flock.js：platform === 'android' 时从本地 bin 加载绑定；
 *   4. 运行时自检：真实 open 两个 fd 验证 首次加锁成功、第二次竞争返回 EAGAIN。
 *
 * 幂等：flock.js 已含标记且产物可加载时跳过编译。
 * 用法：node patch-dsh-android-flock.js [--root <@deepseek-ai 包目录>]
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execSync, spawnSync } = require("node:child_process");
const { createRequire } = require("node:module");

const PKG = "node-addon-system";
const MARKER = "[dsh-android-flock]";

function resolveRoot(optRoot) {
	const candidates = [];
	if (optRoot) candidates.push(optRoot);
	try {
		const dshPkg = require.resolve("@deepseek-ai/dsh/package.json");
		candidates.push(path.join(path.dirname(dshPkg), "node_modules", "@deepseek-ai"));
	} catch {}
	try {
		const npmRoot = execSync("npm root -g", { encoding: "utf8" }).trim();
		candidates.push(path.join(npmRoot, "@deepseek-ai", "dsh", "node_modules", "@deepseek-ai"));
	} catch {}
	for (const c of candidates) if (fs.existsSync(path.join(c, PKG, "lib", "flock.js"))) return c;
	return candidates[0] || null;
}

/** 找 Node-API 头文件目录（node_api.h）。 */
function findNodeHeaders() {
	const candidates = [];
	const prefix = process.env.PREFIX || "/data/data/com.termux/files/usr";
	candidates.push(path.join(prefix, "include", "node"));
	candidates.push(path.join(os.homedir(), ".cache", "node-gyp", process.versions.node, "include", "node"));
	const nodedir = process.config && process.config.variables && process.config.variables.nodedir;
	if (nodedir) candidates.push(path.join(nodedir, "include", "node"));
	for (const c of candidates) if (fs.existsSync(path.join(c, "node_api.h"))) return c;
	return null;
}

/** 编译 src/flock.c -> system.node（Node 在加载时解析 napi_* 符号）。 */
function compileAddon(pkgDir, outFile) {
	const headers = findNodeHeaders();
	if (!headers) throw new Error("未找到 Node headers（node_api.h）；请先安装 nodejs 并跑一次 node-gyp install");
	const src = path.join(pkgDir, "src", "flock.c");
	if (!fs.existsSync(src)) throw new Error(`缺少源码 ${src}`);
	fs.mkdirSync(path.dirname(outFile), { recursive: true });
	const args = ["-shared", "-fPIC", "-O2", `-I${headers}`, "-o", outFile, src];
	const result = spawnSync("clang", args, { encoding: "utf8" });
	if (result.error) throw new Error(`无法执行 clang：${result.error.message}`);
	if (result.status !== 0) throw new Error(`clang 编译失败（exit ${result.status}）：${(result.stderr || result.stdout || "").trim()}`);
}

/** 修补 lib/flock.js，使 android 从本地 bin 加载。 */
function patchFlockJs(src) {
	if (src.includes(MARKER)) return { changed: false, src };
	let out = src;
	if (!out.includes("fileURLToPath")) {
		out = out.replace(
			"import { getSystemErrorName } from 'node:util';",
			"import { getSystemErrorName } from 'node:util';\nimport { fileURLToPath } from 'node:url';"
		);
	}
	// 注入的 android 分支引用 createRequire，必须确保它已从 node:module 导入，
	// 否则未来上游移除该导入时会变成运行期 ReferenceError。
	const MODULE_IMPORT = /import\s*\{([^}]*)\}\s*from\s*['"]node:module['"];?/;
	const moduleMatch = out.match(MODULE_IMPORT);
	if (moduleMatch) {
		if (!/\bcreateRequire\b/.test(moduleMatch[1])) {
			out = out.replace(MODULE_IMPORT, (whole, names) => whole.replace(names, `${names.trim()}, createRequire`));
		}
	} else if (out.includes("import { fileURLToPath } from 'node:url';")) {
		out = out.replace(
			"import { fileURLToPath } from 'node:url';",
			"import { fileURLToPath } from 'node:url';\nimport { createRequire } from 'node:module';"
		);
	} else {
		return { changed: false, src, patternMismatch: true };
	}
	const anchor = "\tconst { platform, arch } = process;\n\tif (platform !== 'linux' && platform !== 'darwin') {";
	const anchorSpaces = "    const { platform, arch } = process;\n    if (platform !== 'linux' && platform !== 'darwin') {";
	const useSpaces = out.includes(anchorSpaces);
	const needle = useSpaces ? anchorSpaces : anchor;
	if (!out.includes(needle)) return { changed: false, src, patternMismatch: true };
	const ind = useSpaces ? "    " : "\t";
	const replacement = [
		`${ind}const { platform, arch } = process;`,
		`${ind}/* ${MARKER} Android/Termux 无上游预编译包，使用本脚本编译的 system.node。 */`,
		`${ind}if (platform === 'android') {`,
		`${ind}${ind}const require = createRequire(import.meta.url);`,
		`${ind}${ind}binding = require(join(dirname(fileURLToPath(import.meta.url)), '..', 'bin', \`android-\${arch}\`, 'system.node'));`,
		`${ind}${ind}return binding;`,
		`${ind}}`,
		`${ind}if (platform !== 'linux' && platform !== 'darwin') {`,
	].join("\n");
	out = out.replace(needle, replacement);
	return { changed: true, src: out };
}

function loadAddon(outFile) {
	const require = createRequire(__filename);
	const binding = require(outFile);
	if (typeof binding.tryLock !== "function") throw new Error("system.node 未导出 tryLock");
	return binding;
}

/** 真实加锁自检：首次成功，第二次竞争返回 EAGAIN(11)/EWOULDBLOCK。 */
async function testLock(binding) {
	const fsp = require("node:fs/promises");
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-flock-verify-"));
	const lockPath = path.join(tmp, "session.lock");
	const a = await fsp.open(lockPath, "w");
	const b = await fsp.open(lockPath, "w");
	try {
		const first = await new Promise((resolve) => binding.tryLock(a.fd, resolve));
		if (first !== 0) throw new Error(`首次 flock 未成功（errno=${first}）`);
		const second = await new Promise((resolve) => binding.tryLock(b.fd, resolve));
		if (second !== 11 && second !== 35) throw new Error(`竞争 flock 未返回 EAGAIN/EWOULDBLOCK（errno=${second}）`);
	} finally {
		await a.close();
		await b.close();
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

async function main() {
	if (process.platform !== "android") {
		console.log(`[SKIP    ] 非 Android 平台（${process.platform}），上游预编译包可用，无需修补`);
		return;
	}
	const argv = process.argv.slice(2);
	let optRoot = null;
	for (let i = 0; i < argv.length; i++) if (argv[i] === "--root") optRoot = argv[++i];
	const root = resolveRoot(optRoot);
	if (!root) {
		console.error("无法定位 dsh 安装目录。请用 --root 指定 <...>/@deepseek-ai 包目录。");
		process.exit(1);
	}
	const pkgDir = path.join(root, PKG);
	const flockJs = path.join(pkgDir, "lib", "flock.js");
	const outFile = path.join(pkgDir, "bin", `android-${process.arch}`, "system.node");
	console.log(`dsh 包目录: ${root}`);
	console.log(`目标产物: ${outFile}`);

	let needCompile = true;
	if (fs.existsSync(outFile)) {
		try {
			loadAddon(outFile);
			needCompile = false;
		} catch {
			needCompile = true;
		}
	}
	if (needCompile) {
		compileAddon(pkgDir, outFile);
		console.log("[BUILT   ] 已编译 system.node");
	} else {
		console.log("[OK      ] 已存在可加载的 system.node");
	}

	const binding = loadAddon(outFile);
	await testLock(binding);
	console.log("[OK      ] flock 绑定运行时自检通过（首次加锁成功 / 竞争返回 EAGAIN）");

	const src = fs.readFileSync(flockJs, "utf8");
	const patched = patchFlockJs(src);
	if (patched.patternMismatch) {
		console.error("[WARN    ] 未找到 lib/flock.js 的平台判断锚点，跳过改写，请人工检查");
		process.exit(2);
	}
	if (patched.changed) {
		fs.writeFileSync(flockJs, patched.src);
		console.log("[PATCHED ] lib/flock.js：android 分支改为加载本地 system.node");
	} else {
		console.log("[OK      ] lib/flock.js 已包含 android 分支");
	}
	console.log("");
	console.log("全部完成。请重启 dsh 进程使修补生效（例如：~/dsh/restart_dsh_now.sh 或重新运行 dsh web）。");
}

main().catch((error) => {
	console.error(`[ERROR   ] ${error.message}`);
	process.exit(1);
});
