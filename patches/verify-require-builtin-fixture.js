#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-require-builtin-fixture.js
 *
 * patch-dsh-android-require-builtin.js 的**夹具自检**：全程只写 mktemp 目录，
 * 不碰真实 dsh 安装树（用例 5 例外，它是只读地断言「真实树未被触碰」）。
 *
 * 为什么需要它：这个补丁的分支（创建 / 刷新 / 让路 / 版本没有该 addon / --root 契约）
 * 都只在特定目录状态下才走到，靠真机很难覆盖；而这些分支的失败模式恰恰是
 * 「把一次健康的安装判成失败」或「覆盖掉别人的包」——必须能离线复现。
 *
 * 用例：
 *   1. 空目录                      → [CREATED] + 退 0 + manifest 元数据正确
 *   2. 本补丁产物被篡改            → [REFRESHED] + 退 0，复跑 [OK]
 *   3. 外来但可用的平台包          → [SKIP] 让路 + 退 0 + 文件未被改动
 *   4. 外来且不可用的平台包        → 退 1，且报错点明「非本补丁生成」
 *   5. dsh 根存在但没有 entry 包（dsh <0.1.7）→ [SKIP] + 退 0（旧实现此处恒退 1）
 *   6. --root 指向非 dsh 目录      → 退 1，且**不回落**到真实安装树
 *   7. 外来包 main 指向别处、无 index.js → 仍让路、不被改写（旧实现会覆盖它）
 *   8. 外来包的描述里恰好含标记串  → 仍让路、不被刷新（旧实现按子串判定会认成「我的」）
 *
 * 用法：node patches/verify-require-builtin-fixture.js [--dsh-root <dsh 安装根>]
 * 退出码：0 = 全部通过；1 = 有断言失败（逐条打印）。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const HERE = path.dirname(fs.realpathSync(__filename));
const PATCH = path.join(HERE, "patch-dsh-android-require-builtin.js");
const ENTRY_PKG = "node-addon-require-builtin";
const LOADER_PKG = "node-addon-native-custom-loader";
const MARKER = "[dsh-android-require-builtin]";
const PLATFORM_PKG = `${ENTRY_PKG}-${process.platform}-${process.arch}`;

let pass = 0;
let fail = 0;
const check = (name, cond, detail = "") => {
	if (cond) {
		pass++;
		console.log(`  [OK]   ${name}`);
	} else {
		fail++;
		console.log(`  [FAIL] ${name}${detail ? ` —— ${detail}` : ""}`);
	}
};

/** 定位真实 dsh 安装根（复制 entry/loader 用；也可用 --dsh-root / DSH_DIR 覆盖）。 */
function findDshRoot() {
	const candidates = [];
	if (process.env.DSH_DIR) candidates.push(process.env.DSH_DIR);
	try {
		candidates.push(path.dirname(path.dirname(path.dirname(require.resolve(`${ENTRY_PKG}/package.json`)))));
	} catch {}
	candidates.push(path.join(path.dirname(path.dirname(process.execPath)), "lib", "node_modules", "@deepseek-ai", "dsh"));
	for (const c of candidates) {
		if (c && fs.existsSync(path.join(c, "node_modules", ENTRY_PKG, "package.json"))) return c;
	}
	return null;
}

/** 造一个假安装根：含真实 entry + loader（两个小包），可选写入 dsh 的 package.json。 */
function makeFixture(dshRoot, { withEntry = true, withDshManifest = false } = {}) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-rb-fixture-"));
	fs.mkdirSync(path.join(root, "node_modules"), { recursive: true });
	if (withDshManifest) {
		fs.writeFileSync(path.join(root, "package.json"), `${JSON.stringify({ name: "@deepseek-ai/dsh", version: "0.1.5-rc.3" }, null, 2)}\n`);
	}
	if (withEntry) {
		for (const pkg of [ENTRY_PKG, LOADER_PKG]) {
			fs.cpSync(path.join(dshRoot, "node_modules", pkg), path.join(root, "node_modules", pkg), { recursive: true });
		}
	}
	return root;
}

/** 写一个平台包；bindingBody 为 index.js/main 目标文件的内容。 */
function writePlatformPkg(root, { main = "index.js", extraManifest = {}, bindingBody, files = {} } = {}) {
	const dir = path.join(root, "node_modules", PLATFORM_PKG);
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(
		path.join(dir, "package.json"),
		`${JSON.stringify({ name: PLATFORM_PKG, version: "9.9.9", main, ...extraManifest }, null, 2)}\n`,
	);
	if (bindingBody !== undefined) {
		const target = path.join(dir, main);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.writeFileSync(target, bindingBody);
	}
	for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), body);
	return dir;
}

/** 合法绑定：过 loader 的 validateLoadedBinding()。 */
const VALID_BINDING = `module.exports = {
  requireBuiltin: (id) => require(id),
  isAllowedInternalId: () => true,
  getNativeBindingInfo: () => ({ mode: "upstream", product: "require-builtin", backend: "napi", abi: "napi-v9" }),
};\n`;

const runPatch = (root) => spawnSync(process.execPath, ["--expose-internals", PATCH, "--root", root], { encoding: "utf8" });
const sha = (file) => (fs.existsSync(file) ? spawnSync("sha256sum", [file], { encoding: "utf8" }).stdout.trim().split(/\s+/)[0] : "<missing>");
const readJson = (file) => JSON.parse(fs.readFileSync(file, "utf8"));

function main() {
	const argv = process.argv.slice(2);
	for (let i = 0; i < argv.length; i++) if (argv[i] === "--dsh-root") process.env.DSH_DIR = argv[++i];

	const dshRoot = findDshRoot();
	if (!dshRoot) {
		console.error("无法定位真实 dsh 安装根（需含 node_modules/" + ENTRY_PKG + "）。请用 --dsh-root 指定。");
		process.exit(1);
	}
	console.log(`真实 dsh 安装根: ${dshRoot}`);
	console.log(`被测补丁:        ${PATCH}`);
	console.log(`平台包名:        ${PLATFORM_PKG}\n`);

	const realPkgDir = path.join(dshRoot, "node_modules", PLATFORM_PKG);
	const realPkgIndexSha = sha(path.join(realPkgDir, "index.js"));
	const realPkgManifestSha = sha(path.join(realPkgDir, "package.json"));
	const cleanup = [];

	// 1) 空目录 → [CREATED]
	{
		console.log("用例 1：空目录 → [CREATED] + manifest 元数据");
		const root = makeFixture(dshRoot);
		cleanup.push(root);
		const r = runPatch(root);
		const dir = path.join(root, "node_modules", PLATFORM_PKG);
		check("退出码 0", r.status === 0, `rc=${r.status} stderr=${r.stderr.trim()}`);
		check("打印 [CREATED]", r.stdout.includes("[CREATED ]"), r.stdout.trim().split("\n").slice(-1)[0]);
		const manifest = fs.existsSync(path.join(dir, "package.json")) ? readJson(path.join(dir, "package.json")) : {};
		check("manifest.name 是包名", manifest.name === PLATFORM_PKG, `name=${manifest.name}`);
		check("os 来自 process.platform", JSON.stringify(manifest.os) === JSON.stringify([process.platform]), JSON.stringify(manifest.os));
		check("cpu 来自 process.arch", JSON.stringify(manifest.cpu) === JSON.stringify([process.arch]), JSON.stringify(manifest.cpu));
		check("带专属标记字段", manifest.dshAndroidPatch === MARKER, String(manifest.dshAndroidPatch));
	}

	// 2) 篡改本补丁产物 → [REFRESHED]，复跑 [OK] 且不落盘
	{
		console.log("\n用例 2：本补丁产物被篡改 → [REFRESHED]，复跑 [OK] 且不落盘");
		const root = makeFixture(dshRoot);
		cleanup.push(root);
		runPatch(root);
		const dir = path.join(root, "node_modules", PLATFORM_PKG);
		fs.appendFileSync(path.join(dir, "index.js"), "\n// tampered\n");
		const r1 = runPatch(root);
		check("刷新时退出码 0", r1.status === 0, `rc=${r1.status}`);
		check("打印 [REFRESHED]", r1.stdout.includes("[REFRESHED]"), r1.stdout.split("\n").find((l) => l.includes("REFRESH")) || "");
		const before = [sha(path.join(dir, "index.js")), sha(path.join(dir, "package.json")), sha(path.join(dir, "README.md"))];
		const r2 = runPatch(root);
		const after = [sha(path.join(dir, "index.js")), sha(path.join(dir, "package.json")), sha(path.join(dir, "README.md"))];
		check("复跑 [OK] 内容一致", r2.stdout.includes("[OK      ] 平台包已存在且内容一致"), r2.stdout.split("\n")[3] || "");
		check("内容一致时不落盘", JSON.stringify(before) === JSON.stringify(after));
	}

	// 3) 外来但可用 → [SKIP] 让路、退 0、不改文件
	{
		console.log("\n用例 3：外来但可用的平台包 → [SKIP] 让路 + 退 0 + 未被改动");
		const root = makeFixture(dshRoot);
		cleanup.push(root);
		const dir = writePlatformPkg(root, { bindingBody: VALID_BINDING });
		const before = sha(path.join(dir, "package.json"));
		const r = runPatch(root);
		check("退出码 0", r.status === 0, `rc=${r.status} stderr=${r.stderr.trim()}`);
		check("打印 [SKIP] 让路", r.stdout.includes("[SKIP    ] 平台包已存在但非本补丁生成"), r.stdout.split("\n")[3] || "");
		check("package.json 未被改动", sha(path.join(dir, "package.json")) === before);
	}

	// 4) 外来且不可用 → 退 1 且点明原因
	{
		console.log("\n用例 4：外来且不可用的平台包 → 退 1 + 点明「非本补丁生成」");
		const root = makeFixture(dshRoot);
		cleanup.push(root);
		writePlatformPkg(root, { bindingBody: "module.exports = {};\n" });
		const r = runPatch(root);
		check("退出码 1", r.status === 1, `rc=${r.status}`);
		check("报错点明「不是本补丁生成」", r.stderr.includes("不是本补丁生成"), r.stderr.trim());
		check("报错点明「无法作为可用绑定加载」", r.stderr.includes("无法作为可用绑定加载"), r.stderr.trim());
	}

	// 5) dsh <0.1.7：是 dsh 根但没有 entry 包 → 真 SKIP 退 0
	{
		console.log("\n用例 5：dsh 根存在但无 entry 包（dsh <0.1.7）→ [SKIP] + 退 0");
		const root = makeFixture(dshRoot, { withEntry: false, withDshManifest: true });
		cleanup.push(root);
		const r = runPatch(root);
		check("退出码 0（不再硬中断安装）", r.status === 0, `rc=${r.status} stderr=${r.stderr.trim()}`);
		check("打印 [SKIP] 说明无此 addon 家族", r.stdout.includes(`[SKIP    ] ${ENTRY_PKG} 不存在`), r.stdout.trim());
	}

	// 6) --root 契约：非 dsh 目录 → 退 1，且绝不回落触碰真实安装树
	{
		console.log("\n用例 6：--root 指向非 dsh 目录 → 退 1 且不触碰真实安装树");
		const bogus = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-rb-notroot-"));
		cleanup.push(bogus);
		const r = runPatch(bogus);
		check("退出码 1", r.status === 1, `rc=${r.status}`);
		check("报错点明 --root 不是 dsh 安装根", r.stderr.includes("不是 dsh 安装根"), r.stderr.trim());
		check("真实平台包 index.js 未被触碰", sha(path.join(realPkgDir, "index.js")) === realPkgIndexSha);
		check("真实平台包 package.json 未被触碰", sha(path.join(realPkgDir, "package.json")) === realPkgManifestSha);
	}

	// 7) 外来包 main 指向别处、无 index.js → 仍让路（旧实现按 index.js 存在性判定会覆盖它）
	{
		console.log("\n用例 7：外来包无 index.js（main 指向 prebuilt/）→ 仍让路、不被改写");
		const root = makeFixture(dshRoot);
		cleanup.push(root);
		const dir = writePlatformPkg(root, { main: "prebuilt/binding.js", bindingBody: VALID_BINDING });
		const before = sha(path.join(dir, "package.json"));
		const r = runPatch(root);
		check("退出码 0", r.status === 0, `rc=${r.status} stderr=${r.stderr.trim()}`);
		check("打印 [SKIP] 让路", r.stdout.includes("[SKIP    ] 平台包已存在但非本补丁生成"), r.stdout.split("\n")[3] || "");
		check("package.json 未被改写", sha(path.join(dir, "package.json")) === before);
		check("未生成我们的 index.js", !fs.existsSync(path.join(dir, "index.js")));
	}

	// 8) 外来包描述里恰好含标记串 → 仍让路（旧实现按子串判定会认成「我的」并刷新）
	{
		console.log("\n用例 8：外来包描述里恰好含标记串 → 仍让路、不被刷新");
		const root = makeFixture(dshRoot);
		cleanup.push(root);
		const dir = writePlatformPkg(root, { bindingBody: VALID_BINDING, extraManifest: { description: `upstream pkg mentioning ${MARKER} in prose` } });
		const before = sha(path.join(dir, "package.json"));
		const r = runPatch(root);
		check("退出码 0", r.status === 0, `rc=${r.status} stderr=${r.stderr.trim()}`);
		check("仍判为外来并让路", r.stdout.includes("[SKIP    ] 平台包已存在但非本补丁生成"), r.stdout.split("\n")[3] || "");
		check("package.json 未被刷新", sha(path.join(dir, "package.json")) === before);
	}

	for (const dir of cleanup) fs.rmSync(dir, { recursive: true, force: true });
	console.log(`\n==== 夹具自检：PASS=${pass} FAIL=${fail} ====`);
	if (fail > 0) process.exit(1);
}

try {
	main();
} catch (error) {
	console.error(`[ERROR   ] ${error.message}`);
	process.exit(1);
}
