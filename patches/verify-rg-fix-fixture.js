#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-rg-fix-fixture.js
 *
 * `apply-rg-fix.sh` 的**回退补丁夹具自检**：在临时假安装树里跑真实脚本（DSH_ROOT 指过去），
 * 覆盖「resolveRgPath() 迁居」前后两代布局、幂等、以及平台软链与源码回退两条成功路径。
 *
 * 为什么需要它：dsh 0.2.2-rc.3 把 resolveRgPath() 从 dsh-tool-fs-search 拆到新包
 * @deepseek-ai/dsh-util-ripgrep（tool-fs-search 只 import 再导出）。旧脚本只认 tool-fs-search，
 * 在 rc.3 上会误报「未识别形态」而实际靠平台软链兜底（T3 基线实测）。夹具必须钉住：
 *   1. rc.3 布局：只修 util-ripgrep 宿主，tool-fs-search 消费者**静默跳过**（不刷假漂移 warn）；
 *   2. 旧线布局（<= 0.2.2-rc.1 / 0.2.1）：tool-fs-search 仍是宿主，4 种历史形状都要能修；
 *   3. `--root`（这里走 DSH_ROOT）缺失/两个宿主都不存在 → 退 1；
 *   4. 平台软链成功路径 / 源码回退成功路径 / 漂移但软链兜底成功 / 漂移且解析失败；
 *   5. 幂等（二次运行只报 already patched）与对外提示。
 *
 * 上游形状常量**从 apply-rg-fix.sh 的嵌入 JS 里原样抽取**（单一事实来源，夹具与生产不会分叉）。
 *
 * 用法：node patches/verify-rg-fix-fixture.js
 * 退出码：0 = 全部通过；1 = 有断言失败。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const HERE = path.dirname(fs.realpathSync(__filename));
const REPO = path.dirname(HERE);
const RG_FIX = path.join(REPO, "apply-rg-fix.sh");
/** 「系统 rg」替身：脚本只执行 `<rg> --version`，node 自身即可胜任（与设备上真实 rg 行为同形）。 */
const FAKE_RG = process.execPath;
const EXPECTED_MIN_CHECKS = 30;

let pass = 0;
let fail = 0;
const cleanup = [];
const check = (name, cond, detail = "") => {
	if (cond) {
		pass++;
		console.log(`  [OK]   ${name}`);
	} else {
		fail++;
		console.log(`  [FAIL] ${name}${detail ? ` —— ${detail}` : ""}`);
	}
};

/** 从 apply-rg-fix.sh 抽取嵌入的 node 补丁脚本，并接上导出以复用其形状常量。 */
function loadShapes() {
	const lines = fs.readFileSync(RG_FIX, "utf8").split("\n");
	let start = -1;
	for (let i = 0; i < lines.length; i++) {
		if (lines[i].includes("<<'JS'")) {
			start = i + 1;
			break;
		}
	}
	if (start < 0) throw new Error("apply-rg-fix.sh 里找不到嵌入的 node 补丁脚本（<<'JS'）");
	let end = -1;
	for (let i = start; i < lines.length; i++) {
		if (lines[i] === "JS") {
			end = i;
			break;
		}
	}
	if (end < 0) throw new Error("嵌入 node 脚本没有结束行 JS");
	const dir = tempDir("shapes");
	const file = path.join(dir, "rg-shapes.cjs");
	fs.writeFileSync(
		file,
		lines.slice(start, end).join("\n")
			+ "\nmodule.exports = { ORIG, CURRENT_ORIG, NEW_ORIG, NEW_ELECTRON_ORIG, PATCHED_OLD, PATCHED_CURRENT, PATCHED_NEW, PATCHED_ELECTRON };\n",
	);
	const log = console.log;
	console.log = () => {};
	let shapes;
	try {
		shapes = require(file);
	} finally {
		console.log = log;
	}
	return shapes;
}

function tempDir(label) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), `dsh-rgfix-${label}-`));
	cleanup.push(dir);
	return dir;
}

function writeFile(root, rel, content) {
	const file = path.join(root, rel);
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, content);
	return file;
}

function addPkgJson(root, relDir, name) {
	writeFile(root, path.join(relDir, "package.json"), JSON.stringify({ name, version: "0.0.0", type: "module", main: "lib/index.js" }, null, 2) + "\n");
}

/** 假 @vscode/ripgrep：与真实包同形——按 `@vscode/ripgrep-<platform>-<arch>/bin/rg` 做 require.resolve。 */
function addVscodeRipgrep(root) {
	addPkgJson(root, "node_modules/@vscode/ripgrep", "@vscode/ripgrep");
	writeFile(root, "node_modules/@vscode/ripgrep/lib/index.js", [
		"import { createRequire } from 'node:module';",
		"const require = createRequire(import.meta.url);",
		"const arch = process.env.npm_config_arch || process.arch;",
		"const binaryName = process.platform === 'win32' ? 'rg.exe' : 'rg';",
		"const platformPkg = '@vscode/ripgrep-' + process.platform + '-' + arch;",
		"let resolved;",
		"try { resolved = require.resolve(platformPkg + '/bin/' + binaryName); }",
		"catch { throw new Error('Could not find ' + platformPkg + '.'); }",
		"export const rgPath = resolved;",
		"",
	].join("\n"));
}

const IMPORTS = [
	'import { existsSync } from "node:fs";',
	'import { join, parse } from "node:path";',
	"let rgPathPromise;",
].join("\n");

const UTIL_RL = "node_modules/@deepseek-ai/dsh-util-ripgrep";
const SEARCH_RL = "node_modules/@deepseek-ai/dsh-tool-fs-search";

/** rc.3+：util-ripgrep 才是 resolveRgPath() 的宿主。 */
function addUtilHost(root, shapes, block = shapes.NEW_ELECTRON_ORIG) {
	addPkgJson(root, UTIL_RL, "@deepseek-ai/dsh-util-ripgrep");
	return writeFile(root, path.join(UTIL_RL, "lib", "index.js"), IMPORTS + "\n" + block + "\nexport { resolveRgPath };\n");
}

/** 旧线：tool-fs-search 自己定义 resolveRgPath()。 */
function addSearchHost(root, shapes, blockName) {
	addPkgJson(root, SEARCH_RL, "@deepseek-ai/dsh-tool-fs-search");
	return writeFile(root, path.join(SEARCH_RL, "lib", "index.js"), IMPORTS + "\n" + shapes[blockName] + "\nexport { resolveRgPath };\n");
}

/** rc.3+：tool-fs-search 只 import/再导出，不含函数定义（消费者）。 */
function addSearchConsumer(root) {
	addPkgJson(root, SEARCH_RL, "@deepseek-ai/dsh-tool-fs-search");
	return writeFile(
		root,
		path.join(SEARCH_RL, "lib", "index.js"),
		'import { resolveRgPath } from "@deepseek-ai/dsh-util-ripgrep";\nexport { resolveRgPath };\n',
	);
}

function runFix(root) {
	return spawnSync("bash", [RG_FIX], {
		encoding: "utf8",
		env: { ...process.env, DSH_ROOT: root, RG_PATH: FAKE_RG },
		timeout: 120000,
	});
}

function main() {
	const shapes = loadShapes();
	check("从 apply-rg-fix.sh 抽取到 4 种历史形状", ["ORIG", "CURRENT_ORIG", "NEW_ORIG", "NEW_ELECTRON_ORIG"].every((k) => typeof shapes[k] === "string" && shapes[k].includes("resolveRgPath")), Object.keys(shapes).join(","));

	// ---- 用例 1：DSH_ROOT 不存在 / 宿主包全缺 → 硬失败，不静默 ----
	console.log("\n用例 1：DSH_ROOT 不存在 / 宿主包全缺 → 退 1");
	const missingRoot = path.join(os.tmpdir(), "dsh-rgfix-does-not-exist-" + process.pid);
	const r1 = runFix(missingRoot);
	check("DSH_ROOT 不存在 → 退 1", r1.status === 1, `rc=${r1.status}`);
	check("报错点明 DSH_ROOT", /DSH_ROOT not found/.test(r1.stdout + r1.stderr), (r1.stdout + r1.stderr).trim().split("\n")[0] || "");
	const emptyRoot = tempDir("empty");
	const r2 = runFix(emptyRoot);
	check("两个宿主包都不存在 → 退 1", r2.status === 1, `rc=${r2.status}`);
	check("报错点明宿主包", /宿主包/.test(r2.stdout + r2.stderr), (r2.stdout + r2.stderr).trim().split("\n")[0] || "");

	// ---- 用例 2：rc.3+ 布局（util-ripgrep 宿主 + tool-fs-search 消费者 + 平台软链成功路径）----
	console.log("\n用例 2：0.2.2-rc.3+ 布局（util-ripgrep 宿主，消费者静默跳过）");
	const rc3 = tempDir("rc3");
	const rc3Util = addUtilHost(rc3, shapes);
	const rc3Search = addSearchConsumer(rc3);
	const rc3SearchBefore = fs.readFileSync(rc3Search, "utf8");
	addVscodeRipgrep(rc3);
	const r3 = runFix(rc3);
	const rc3Both = (r3.stdout || "") + (r3.stderr || "");
	const rc3UtilSrc = fs.readFileSync(rc3Util, "utf8");
	check("退 0", r3.status === 0, `rc=${r3.status} ${(r3.stderr || "").trim()}`);
	check("真正命中 util-ripgrep 宿主", /patched OK: .*dsh-util-ripgrep/.test(r3.stdout || ""), (r3.stdout || "").split("\n").find((l) => l.includes("patched OK")) || "");
	check("消费者 tool-fs-search 静默跳过（无假 warn）", !/\[warn\]/.test(rc3Both), (rc3Both.split("\n").find((l) => l.includes("warn")) || "(无 warn)"));
	check("消费者文件零改写", fs.readFileSync(rc3Search, "utf8") === rc3SearchBefore);
	check("util 产物含 resolveSystemRg 回退", rc3UtilSrc.includes("resolveSystemRg"));
	check("回退函数只注入一次", (rc3UtilSrc.match(/function resolveSystemRg\(/g) || []).length === 1);
	const platformLink = path.join(rc3, "node_modules/@vscode/ripgrep-android-arm64/bin/rg");
	check("平台包软链已就位", fs.existsSync(platformLink) && fs.lstatSync(platformLink).isSymbolicLink());
	check("step 3 实测解析出 rg 路径", /resolved: \S+/.test(r3.stdout || ""), (r3.stdout || "").split("\n").find((l) => l.includes("resolved:")) || "");
	check("step 3 实测能跑 rg --version", /version:\s+v?\d/.test(r3.stdout || ""), (r3.stdout || "").split("\n").find((l) => l.includes("version:")) || "");
	const r3b = runFix(rc3);
	check("二次运行退 0", r3b.status === 0, `rc=${r3b.status}`);
	check("二次运行报 already patched", /already patched, skipping: .*dsh-util-ripgrep/.test(r3b.stdout || ""), (r3b.stdout || "").split("\n").find((l) => l.includes("already")) || "");
	check("二次运行不重复注入", (fs.readFileSync(rc3Util, "utf8").match(/function resolveSystemRg\(/g) || []).length === 1);

	// ---- 用例 3：旧线布局（tool-fs-search 是宿主）——4 种历史形状逐个正向验证 ----
	console.log("\n用例 3：旧线布局（tool-fs-search 宿主，形状 ORIG / CURRENT_ORIG / NEW_ORIG）");
	for (const shapeName of ["ORIG", "CURRENT_ORIG", "NEW_ORIG"]) {
		const root = tempDir("old-" + shapeName);
		const host = addSearchHost(root, shapes, shapeName);
		addVscodeRipgrep(root);
		const r = runFix(root);
		const src = fs.readFileSync(host, "utf8");
		check(`${shapeName} 形状退 0`, r.status === 0, `rc=${r.status} ${(r.stderr || "").trim()}`);
		check(`${shapeName} 形状命中 tool-fs-search 宿主`, /patched OK: .*dsh-tool-fs-search/.test(r.stdout || ""), (r.stdout || "").split("\n").find((l) => l.includes("patched OK")) || "");
		check(`${shapeName} 形状产物含 resolveSystemRg`, src.includes("resolveSystemRg"));
		check(`${shapeName} 形状 step 3 校验通过`, /resolved: \S+/.test(r.stdout || "") && /version:/.test(r.stdout || ""));
	}

	// ---- 用例 4：无 @vscode/ripgrep 时源码回退独力生效（rc.3 布局）----
	console.log("\n用例 4：平台包缺失时源码回退兜底（util-ripgrep 布局）");
	const fb = tempDir("fallback");
	const fbUtil = addUtilHost(fb, shapes);
	const r4 = runFix(fb);
	check("退 0（回退解析成功）", r4.status === 0, `rc=${r4.status} ${(r4.stderr || "").trim()}`);
	check("util 产物已打补丁", fs.readFileSync(fbUtil, "utf8").includes("resolveSystemRg"));
	check("解析路径 = RG_PATH（回退），而不是打包 rg", (r4.stdout || "").includes("resolved: " + FAKE_RG), (r4.stdout || "").split("\n").find((l) => l.includes("resolved:")) || "");

	// ---- 用例 5：形状漂移 + 平台软链兜底 → warn 但退 0 ----
	console.log("\n用例 5：形状漂移但平台软链兜底 → [warn] 且退 0");
	const drift = tempDir("drift");
	const driftUtil = addUtilHost(drift, shapes, 'async function resolveRgPath() {\n\treturn (await import("@vscode/ripgrep")).rgPath;\n}');
	addVscodeRipgrep(drift);
	const driftBefore = fs.readFileSync(driftUtil, "utf8");
	const r5 = runFix(drift);
	const driftBoth = (r5.stdout || "") + (r5.stderr || "");
	check("退 0", r5.status === 0, `rc=${r5.status}`);
	check("明确报 [warn] 形状漂移", /\[warn\] unrecognized resolveRgPath\(\) shape/.test(driftBoth), (driftBoth.split("\n").find((l) => l.includes("warn")) || "").trim());
	check("漂移文件零改写", fs.readFileSync(driftUtil, "utf8") === driftBefore);
	check("解析仍成功（平台软链兜底）", /resolved: \S+/.test(r5.stdout || ""));

	// ---- 用例 6：形状漂移 + 无平台包 → 解析失败退 1 ----
	console.log("\n用例 6：形状漂移且无平台包 → 退 1（硬阻断语义）");
	const dead = tempDir("dead");
	addUtilHost(dead, shapes, 'async function resolveRgPath() {\n\tthrow new Error("no packaged rg available");\n}');
	const r6 = runFix(dead);
	const deadBoth = (r6.stdout || "") + (r6.stderr || "");
	check("退 1", r6.status === 1, `rc=${r6.status}`);
	check("报 resolveRgPath 校验失败", /resolveRgPath\(\) 校验失败/.test(deadBoth), (deadBoth.trim().split("\n").find((l) => l.includes("ERROR")) || "").trim());
	check("提示人工核对实际宿主包", /dsh-util-ripgrep/.test(deadBoth));

	// ---- 用例 7：静态契约（两代宿主都必须在脚本里；不按版本号分支）----
	console.log("\n用例 7：apply-rg-fix.sh 静态契约");
	const fixText = fs.readFileSync(RG_FIX, "utf8");
	check("脚本同时认定两代宿主路径", fixText.includes("dsh-tool-fs-search/lib/index.js") && fixText.includes("dsh-util-ripgrep/lib/index.js"));
	check("验证落点按「谁定义 resolveRgPath」选择（不是写死顺序）", fixText.includes("function resolveRgPath") && fixText.includes("dsh-util-ripgrep"));
	if (pass < EXPECTED_MIN_CHECKS) {
		console.log(`  [FAIL] 断言数不足：PASS=${pass} < ${EXPECTED_MIN_CHECKS}（有断言被删除或提前跳过）`);
		fail++;
	}
	for (const dir of cleanup) fs.rmSync(dir, { recursive: true, force: true });
	console.log(`\n==== rg 修复夹具：PASS=${pass} FAIL=${fail}（断言下限 ${EXPECTED_MIN_CHECKS}）====`);
	if (fail > 0) process.exit(1);
}

try {
	main();
} catch (error) {
	for (const dir of cleanup) {
		try {
			fs.rmSync(dir, { recursive: true, force: true });
		} catch {}
	}
	console.error(`[ERROR   ] ${error.message}`);
	process.exit(1);
}
