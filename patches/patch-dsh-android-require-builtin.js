#!/data/data/com.termux/files/usr/bin/node
/**
 * patch-dsh-android-require-builtin.js
 *
 * 修复 dsh ≥0.1.7 在 Android/Termux 上**完全无法启动**：
 *
 *   dsh: fatal uncaught exception: Error: dsh: host preparation failed:
 *     No usable native binding found for node-addon-require-builtin-android-arm64 (auto)
 *
 * 根因（0.1.7 新增的原生 addon 家族）：
 *   - `node-addon-require-builtin` 通过 `node-addon-native-custom-loader`
 *     加载平台包 `<name>-<platform>-<arch>`；上游只发布
 *     darwin/linux-gnu/win32-msvc 七个预编译包，**没有 android**。
 *   - `runtimeSuffix()` 对未知平台回退成 `${process.platform}-${process.arch}`，
 *     Termux 上即 `android-arm64`，于是解析到一个不存在的包。
 *   - published 安装不含 binding.gyp/src（README 明说 “fail closed instead of
 *     compiling unvalidated local binaries”），所以本地构建兜底路径也拿不到源码。
 *   - `@deepseek-ai/dsh-app-boot` 的 `internalModules()` **无条件**
 *     `createRequire(...)("node-addon-require-builtin")`，没有 JS 回退，
 *     于是 host preparation 直接失败 → dsh 起不来。
 *
 * 本脚本按 loader 的「平台可选包」约定补一个 Android 平台包：
 *   1. 在 `<dsh>/node_modules/` 下生成 `node-addon-require-builtin-android-arm64`；
 *   2. 纯 JS 实现 loader 要求的三个导出（requireBuiltin /
 *      isAllowedInternalId / getNativeBindingInfo），abi 声明为 `napi-v9`；
 *   3. 运行时自检：走真实 entry 包，断言 `getBindingInfo()` 与
 *      `internalModules()` 依赖的 5 个 internal 模块成员全部可用。
 *
 * 为什么用纯 JS 而不是编译 .node：上游 native addon 的作用是在**没有**
 * `--expose-internals` 时也能 require `internal/*`；而本项目的 `dsh` 包装脚本
 * 必定带 `--expose-internals`（setup.sh 第 6 步重建，缺了会让 HMR 崩），
 * 该场景下 `require('internal/...')` 直接可用（已在 Node v26.4.0 实测）。
 * loader 的 `tryRequirePackage()` 只按 `validateLoadedBinding()` 校验导出形状，
 * 并不要求文件是 ELF，故 JS 实现完全合法且免去 NDK/交叉编译。
 *
 * 幂等：平台包各文件与脚本模板**逐字节一致**才跳过；不一致（manifest 修正、模板更新、
 * entry 包版本变化）就原地刷新，避免「改了这个脚本但已装设备永远不更新」。
 * 让路：目标目录里若已存在**非本补丁生成**的平台包（例如上游日后真发布了 android
 * 预编译包），一律不覆盖、直接 `[SKIP]`，其可用性仍由 `verify()` 断言——通过则退 0，
 * 加载不了才退 1（不能因为「不是我们造的」就中断一次健康安装）。
 * 版本：dsh <0.1.7 没有这个 addon 家族 → `[SKIP]` 退 0（该分支要求「定位到 dsh 安装根」
 * 与「entry 包存在」解耦，否则恒不可达、会把健康的 0.1.5 回退安装判成失败）。
 * 用法：node patch-dsh-android-require-builtin.js [--root <dsh 安装根>]
 * ⚠️ `--root` 是硬契约：显式给出但定位不到 dsh 安装根时**报错退 1**，不回落到其它候选
 * （否则夹具/多安装场景会静默操作生产树）。
 */
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");

const ENTRY_PKG = "node-addon-require-builtin";
const DSH_PKG = "@deepseek-ai/dsh";
const MARKER = "[dsh-android-require-builtin]";

/** 该目录是不是 dsh 安装根：自身 package.json 声明为 @deepseek-ai/dsh，或它下面就有 entry 包。 */
function isDshRoot(dir) {
	try {
		if (JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")).name === DSH_PKG) return true;
	} catch {}
	// 兼容 dsh <0.1.7（没有 entry 包）之外的场景与夹具：含 <node_modules>/<ENTRY_PKG> 也算安装根。
	return fs.existsSync(path.join(dir, "node_modules", ENTRY_PKG, "package.json"));
}

/** 从 start 起向上找 dsh 安装根（最多 8 层），找不到返回 null。 */
function findDshRootFrom(start) {
	let dir = path.resolve(start);
	for (let i = 0; i < 8; i++) {
		if (isDshRoot(dir)) return dir;
		const parent = path.dirname(dir);
		if (parent === dir) break;
		dir = parent;
	}
	return null;
}

/**
 * 定位 dsh 安装根。
 * ⚠️ 定位条件**不能**依赖 entry 包存在：dsh <0.1.7 根本没有这个 addon 家族，而那种情况
 * 必须走到 main 里的 `[SKIP]` 退 0（旧实现要求 entry 包存在才返回根，导致 SKIP 分支恒不可达、
 * 直接把一次健康的 0.1.5 回退安装判成安装失败）。
 * ⚠️ 显式 `--root` 是硬契约：定位失败即返回 null（由调用方报错退 1），**不回落到其它候选**——
 * 否则夹具/多安装场景会静默操作生产树。
 */
function resolveDshRoot(optRoot) {
	if (optRoot) return findDshRootFrom(optRoot);
	const candidates = [];
	try {
		// entry 包的 package.json 位于 <dsh>/node_modules/<ENTRY_PKG>/package.json
		candidates.push(path.dirname(path.dirname(path.dirname(require.resolve(`${ENTRY_PKG}/package.json`)))));
	} catch {}
	// 不走 `npm root -g`：Termux 上 /usr/bin 不可解析，npm-cli.js 的 shebang
	// `#!/usr/bin/env node` 会让直接执行 npm 报 "bad interpreter"。全局 node_modules
	// 可由当前 node 路径直接推出：<prefix>/bin/node -> <prefix>/lib/node_modules。
	const globalRoot = path.join(path.dirname(path.dirname(process.execPath)), "lib", "node_modules");
	candidates.push(path.join(globalRoot, DSH_PKG));
	for (const c of candidates) {
		const root = findDshRootFrom(c);
		if (root) return root;
	}
	return null;
}

const BINDING_JS = `"use strict";
/**
 * ${MARKER}
 *
 * Android/Termux 平台包（上游未发布 android 预编译产物）。
 * 由 deepseek-harness-android 的 patches/patch-dsh-android-require-builtin.js 生成。
 *
 * 上游用原生 addon 绕过 --expose-internals 限制来 require("internal/*")。
 * 本项目的 dsh 包装脚本必定以 node --expose-internals 启动（见 setup.sh 第 6 步），
 * 该前提下 require("internal/...") 直接可用，因此这里用等价的纯 JS 实现，
 * 免去 NDK / 交叉编译。导出形状须满足 node-addon-native-custom-loader 的
 * validateLoadedBinding()：requireBuiltin / isAllowedInternalId /
 * getNativeBindingInfo，且 backend ∈ {napi,nodeabi}、abi 与其自洽。
 *
 * 不要手改本文件：重跑上面的补丁脚本即可重新生成。
 */

const NODE_MODULE = require("node:module");

/** 与 loader 的 NAPI_VERSION 保持一致（node-addon-native-custom-loader/lib/index.js）。 */
const BACKEND = "napi";
const ABI = "napi-v9";

function hasExposeInternals() {
	return process.execArgv.some((arg) => arg === "--expose-internals" || arg.startsWith("--expose-internals="));
}

function requireBuiltin(moduleId) {
	if (typeof moduleId !== "string" || moduleId.length === 0) {
		throw new TypeError("requireBuiltin(moduleId): moduleId must be a non-empty string");
	}
	// ① 正常路径：--expose-internals 生效时 require() 即可解析 internal/*
	try {
		return require(moduleId);
	} catch (error) {
		if (!error || error.code !== "MODULE_NOT_FOUND") throw error;
		const first = error;
		// ② 兜底：Module._load 少一层包装，部分 Node 版本上更宽松
		try {
			return NODE_MODULE._load(moduleId, null, false);
		} catch {
			// ③ 纯 JS 没有可靠办法在无 --expose-internals 时拿到 internal/* 的
			//    活实例（process.binding("natives") 只能拿到源码，esm/cjs loader
			//    必须是真实例）。所以这里报出人可读的原因而不是崩栈。
			const hint = hasExposeInternals()
				? "internal 模块解析失败"
				: "当前进程缺少 --expose-internals：dsh 必须以 node --expose-internals 启动（见 setup.sh 第 6 步重建 dsh 包装脚本）";
			const wrapped = new Error(
				"requireBuiltin(" + JSON.stringify(moduleId) + ") 失败：" + first.message + "；" + hint,
			);
			wrapped.code = "ERR_REQUIRE_BUILTIN_UNAVAILABLE";
			throw wrapped;
		}
	}
}

/** 无限制变体（见 upstream README）：任何 id 都放行。 */
function isAllowedInternalId() {
	return true;
}

function getNativeBindingInfo() {
	return {
		mode: "android-termux",
		product: "require-builtin",
		backend: BACKEND,
		abi: ABI,
	};
}

module.exports = {
	requireBuiltin,
	isAllowedInternalId,
	getNativeBindingInfo,
};
`;

/** 平台包 README 内容（补齐的槽位名随架构变，不能写死 android-arm64）。 */
function bindingReadme(pkgName) {
	return `${MARKER}

由 \`deepseek-harness-android\` 的 \`patches/patch-dsh-android-require-builtin.js\` 生成。

上游 \`node-addon-require-builtin\` 为每个平台发布预编译包，但没有 android 版本，
导致 dsh ≥0.1.7 在 Termux 上 host preparation 失败、无法启动。本包按
\`node-addon-native-custom-loader\` 的「平台可选包」约定补齐 \`${pkgName}\` 槽位。
`;
}

/** 平台包的目标文件内容（幂等刷新时逐字节比对的唯一事实来源）。 */
function platformPackageFiles(pkgName, version) {
	const manifest = {
		// ⚠️ 这里必须是包名，不是目录路径：manifest.name 是 npm 元数据，
		// 写成绝对路径会产出非法 manifest（早期版本误传了 pkgDir）。
		name: pkgName,
		version,
		description: `Android/Termux platform package for ${ENTRY_PKG} (generated by deepseek-harness-android).`,
		main: "index.js",
		license: "MIT",
		// 由运行时推导，别写死：armv7 Termux 上目录是 android-arm，写死 arm64 就是假元数据
		// （与早期把 name 写成绝对路径同源的问题）。
		os: [process.platform],
		cpu: [process.arch],
		// 明确标注非上游产物，避免与官方预编译包混淆
		dshAndroidPatch: MARKER,
	};
	return {
		"package.json": `${JSON.stringify(manifest, null, 2)}\n`,
		"index.js": BINDING_JS,
		"README.md": bindingReadme(pkgName),
	};
}

/**
 * 目录里是否已是本补丁生成的平台包（避免覆盖上游日后可能发布的 android 预编译包）。
 * ⚠️ 认 manifest 的专属字段（JSON 字段相等），**不做子串扫描**：旧实现扫 index.js/package.json
 * 里是否出现 MARKER 字符串，任何在描述/注释里恰好提到该标记的他人包都会被误判成「我的」并遭刷新。
 */
function isOurs(pkgDir) {
	try {
		const manifest = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf8"));
		return manifest.dshAndroidPatch === MARKER;
	} catch {
		return false;
	}
}

/** 目录非空（读失败按「有内容」处理，避免误判成空目录而覆盖）。 */
function dirHasContent(dir) {
	try {
		return fs.readdirSync(dir).length > 0;
	} catch {
		return true;
	}
}

/** 各文件都与目标内容逐字节一致才算已就绪。 */
function packageMatches(pkgDir, files) {
	for (const [name, content] of Object.entries(files)) {
		try {
			if (fs.readFileSync(path.join(pkgDir, name), "utf8") !== content) return false;
		} catch {
			return false;
		}
	}
	return true;
}

function writePlatformPackage(pkgDir, files) {
	fs.mkdirSync(pkgDir, { recursive: true });
	for (const [name, content] of Object.entries(files)) {
		fs.writeFileSync(path.join(pkgDir, name), content);
	}
}

/** 走真实 entry 包做自检：loader 的 validateLoadedBinding + dsh-app-boot 的断言。 */
function verify(entryPkgDir) {
	const requireFromEntry = createRequire(path.join(entryPkgDir, "package.json"));
	const addon = requireFromEntry(ENTRY_PKG);

	const info = addon.getBindingInfo();
	if (typeof info !== "object" || info === null) throw new Error("getBindingInfo() 未返回对象");
	if (info.backend !== "napi" || info.abi !== "napi-v9") {
		throw new Error(`getBindingInfo() backend/abi 不合法：${info.backend}/${info.abi}`);
	}
	if (addon.isAllowedInternalId("internal/modules/esm/loader") !== true) {
		throw new Error("isAllowedInternalId() 应恒为 true（无限制变体）");
	}

	// 复刻 @deepseek-ai/dsh-app-boot 的 internalModules() 断言
	const esmModule = addon.requireBuiltin("internal/modules/esm/loader");
	const cjsModule = addon.requireBuiltin("internal/modules/cjs/loader");
	const cjsHelpers = addon.requireBuiltin("internal/modules/helpers");
	const esmUtils = addon.requireBuiltin("internal/modules/esm/utils");
	const esmResolve = addon.requireBuiltin("internal/modules/esm/resolve");

	const esm = esmModule.getOrInitializeCascadedLoader();
	if (typeof esm !== "object" || esm === null) throw new Error("getOrInitializeCascadedLoader() 未返回对象");
	const modern = "getOrCreateModuleJob" in esm;
	if (typeof esm.resolveSync !== "function") throw new Error("esm.resolveSync 缺失");
	if (modern && typeof Reflect.get(esm, "getOrCreateModuleJob") !== "function") {
		throw new Error("esm.getOrCreateModuleJob 缺失");
	}
	if (!modern && typeof Reflect.get(esm, "getModuleJobForImport") !== "function") {
		throw new Error("esm.getModuleJobForImport 缺失");
	}
	if (!modern && typeof Reflect.get(esm, "resolve") !== "function") throw new Error("esm.resolve 缺失");
	if (typeof cjsModule.Module._resolveFilename !== "function") throw new Error("cjs Module._resolveFilename 缺失");
	if (typeof cjsHelpers.getCjsConditions !== "function") throw new Error("getCjsConditions 缺失");
	if (typeof esmUtils.getDefaultConditions !== "function") throw new Error("getDefaultConditions 缺失");
	if (typeof esmResolve.defaultResolve !== "function") throw new Error("esm defaultResolve 缺失");
	if (!Array.isArray(esmUtils.getDefaultConditions())) throw new Error("getDefaultConditions() 应返回数组");

	return { info, modern };
}

function main() {
	if (process.platform !== "android") {
		console.log(`[SKIP    ] 非 Android 平台（${process.platform}），上游预编译包可用，无需补平台包`);
		return;
	}
	const argv = process.argv.slice(2);
	let optRoot = null;
	for (let i = 0; i < argv.length; i++) if (argv[i] === "--root") optRoot = argv[++i];

	const dshRoot = resolveDshRoot(optRoot);
	if (!dshRoot) {
		// 显式 --root 定位失败时**绝不**回落到其它候选：否则夹具/多安装场景会静默操作生产树。
		const why = optRoot
			? `--root 指向的 ${optRoot} 不是 dsh 安装根（该目录或其祖先需满足：package.json 的 name 为 ${DSH_PKG}，或含 node_modules/${ENTRY_PKG}）`
			: `未找到 dsh 安装根（package.json 的 name 为 ${DSH_PKG}）`;
		console.error(`${why}。请用 --root <dsh 安装根> 指定。`);
		process.exit(1);
	}
	const entryPkgDir = path.join(dshRoot, "node_modules", ENTRY_PKG);
	if (!fs.existsSync(path.join(entryPkgDir, "package.json"))) {
		// dsh < 0.1.7 没有这个原生 addon 家族，无需补平台包。
		// 走 SKIP 而非 exit 1：setup.sh 对本脚本的失败是硬中断（dsh 起不来），
		// 不能让「版本还没有这个包」误判成安装失败。
		console.log(`[SKIP    ] ${ENTRY_PKG} 不存在（dsh < 0.1.7 无此原生 addon 家族），无需补平台包`);
		return;
	}
	const version = JSON.parse(fs.readFileSync(path.join(entryPkgDir, "package.json"), "utf8")).version;

	// 与 loader 的 runtimeSuffix() 回退分支一致：未知平台 → `${platform}-${arch}`
	const platformPkgName = `${ENTRY_PKG}-${process.platform}-${process.arch}`;
	const platformPkgDir = path.join(dshRoot, "node_modules", platformPkgName);
	console.log(`dsh 安装根: ${dshRoot}`);
	console.log(`entry 包:   ${ENTRY_PKG}@${version}`);
	console.log(`平台包:     ${platformPkgName}`);

	const files = platformPackageFiles(platformPkgName, version);
	// ⚠️ 存在性判据用**目录**而不是 index.js：他人包若把 main 指到别处（如 prebuilt/*.node）就没有
	// index.js，旧判据会把它当成「不存在」并直接改写掉。
	const existed = fs.existsSync(platformPkgDir);
	const hasContent = existed && dirHasContent(platformPkgDir);
	const foreign = hasContent && !isOurs(platformPkgDir);
	// 非本补丁产物（例如上游日后真发布了 android 预编译包）：不覆盖、直接让路。
	// ⚠️ 这里**不能** throw：setup.sh 的 4-boot 把本脚本非 0 视为硬阻断（error + exit 1），
	// 那会把一次完全健康的安装判成失败。是否真的可用交给下面统一的 verify() 判定——
	// 能加载就 [SKIP] 退 0，加载不了才报错退 1。
	if (foreign) {
		console.log(`[SKIP    ] 平台包已存在但非本补丁生成（manifest 无 dshAndroidPatch=${MARKER}），让路不覆盖`);
	} else if (packageMatches(platformPkgDir, files)) {
		console.log("[OK      ] 平台包已存在且内容一致");
	} else {
		writePlatformPackage(platformPkgDir, files);
		console.log(
			hasContent
				? "[REFRESHED] 平台包内容与脚本模板不一致，已原地刷新"
				: "[CREATED ] 平台包已生成（纯 JS requireBuiltin 实现，abi=napi-v9）",
		);
	}

	let info, modern;
	try {
		({ info, modern } = verify(entryPkgDir));
	} catch (error) {
		if (foreign) {
			throw new Error(
				`已存在的平台包不是本补丁生成的（manifest 无 dshAndroidPatch=${MARKER}）且无法作为可用绑定加载：${error.message}——请人工确认该包来源后重跑`,
			);
		}
		throw error;
	}
	console.log(`[OK      ] entry 包加载成功：backend=${info.backend} abi=${info.abi} source=${info.bindingSource}`);
	console.log(`[OK      ] internalModules() 自检通过（modern loader=${modern}）`);

	const suffix = info.optionalPackageName === platformPkgName ? "" : ` [注意: loader 期望 ${info.optionalPackageName}]`;
	console.log(`全部完成${suffix}。请启动 dsh 验证（例如：bash ~/dsh/start_dsh.sh）。`);
}

try {
	main();
} catch (error) {
	console.error(`[ERROR   ] ${error.message}`);
	process.exit(1);
}
