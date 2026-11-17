#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-patch-guards-fixture.js
 *
 * `patch-dsh-android-link.js` / `patch-dsh-android-flock.js` 的**守护条件夹具自检**：
 * 全程只在 mktemp 目录里造副本并跑补丁脚本（--root 指向副本），
 * 唯一读真实安装树的地方是「把目标文件复制进夹具」与「断言它在整个过程中哈希未变」。
 *
 * 为什么需要它：这两个脚本各有一个「看起来成功、其实没做事 / 做错地方」的失败模式，
 * 真机上不会暴露（安装树恰好是健康的），只有夹具能离线复现：
 *
 *   1. --root 硬契约   —— 旧实现把 --root 当「候选链第一项」，定位失败就静默回落到生产安装树，
 *                         于是「用夹具在临时目录里验证」的命令实际写生产树（本次审计发现）。
 *   2. 语义幂等判定    —— 旧实现用 `includes("publishNoReplaceNoHardlink")` 判「已修」，
 *                         注释/字符串里出现该标识符就报 [OK]；实测「仅一句注释 + 裸 link」的文件
 *                         曾被判 already-fixed，即真正的损坏被假成功掩盖（本次审计发现）。
 *
 * 用例：
 *   1. link  --root 不存在            → 退 1 + 报错点明 --root + 不打印作业目录
 *   2. link  --root 存在但不是包目录  → 退 1（旧实现在这里静默回落生产树）
 *   3. link  --root 指向临时副本      → 退 0 且打印的作业目录是**副本**（不是生产树）
 *   4. link  会话文件仅有回退调用注释 → 退 2 + [WARN]，**不得**报 already-fixed（缺陷 2 回归）
 *   5. flock --root 不存在            → 退 1
 *   6. flock --root 存在但不是包目录  → 退 1（旧 flock 在这里静默回落生产树）
 *   7. flock --root 指向临时副本      → 先删掉复制来的产物，断言它**真的在副本里编译**（[BUILT]）
 *   8. flock.js 只剩一句 marker 注释  → 退 2 + [WARN]，**不得**报 already-fixed（缺陷 2 的 flock 版）
 *   9. 生产树 5 个目标文件哈希前后一致 + 断言总数达标（防「删断言」式假绿）
 *
 * 用法：node patches/verify-patch-guards-fixture.js
 * 退出码：0 = 全部通过；1 = 有断言失败（逐条打印）。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawnSync } = require("node:child_process");

const HERE = path.dirname(fs.realpathSync(__filename));
const LINK_PATCH = path.join(HERE, "patch-dsh-android-link.js");
const FLOCK_PATCH = path.join(HERE, "patch-dsh-android-flock.js");
const LINK_PKGS = ["dsh-session-persistence-jsonl", "dsh-attachment-local", "dsh-fs-local"];
const FLOCK_PKG = "node-addon-system";
/** 断言总数下限：低于它说明有人删了断言（此时 FAIL 仍可能为 0，必须显式失败）。 */
const EXPECTED_MIN_CHECKS = 52;

let pass = 0;
let fail = 0;
/** 所有自建临时目录登记在这里，`catch` 分支也会清理（不能只在 main 正常返回时清）。 */
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

const sha = (file) => (fs.existsSync(file) ? crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex") : null);

/** 定位真实 <...>/@deepseek-ai 包目录（只做只读源；--root 硬契约禁止脚本自己去找它）。 */
function findPackagesDir() {
	const dshRoot = process.env.DSH_DIR || path.join(path.dirname(path.dirname(process.execPath)), "lib", "node_modules", "@deepseek-ai", "dsh");
	const dir = path.join(dshRoot, "node_modules", "@deepseek-ai");
	if (LINK_PKGS.every((n) => fs.existsSync(path.join(dir, n, "lib", "index.js")))) return dir;
	return null;
}

/** 生产树里本夹具会断言「未被触碰」的 5 个文件。 */
function productionTargets(pkgsDir) {
	return [
		...LINK_PKGS.map((n) => path.join(pkgsDir, n, "lib", "index.js")),
		path.join(pkgsDir, FLOCK_PKG, "lib", "flock.js"),
		path.join(pkgsDir, FLOCK_PKG, "bin", `android-${process.arch}`, "system.node"),
	];
}

const run = (script, args) => spawnSync(process.execPath, [script, ...args], { encoding: "utf8" });

/** 造一个 <tmp>/@deepseek-ai 副本：link 要的三个包 + flock 要的 node-addon-system。 */
function makeCopyRoot(pkgsDir) {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-guards-fixture-"));
	const container = path.join(root, "@deepseek-ai");
	for (const name of LINK_PKGS) {
		const dst = path.join(container, name, "lib");
		fs.mkdirSync(dst, { recursive: true });
		fs.copyFileSync(path.join(pkgsDir, name, "lib", "index.js"), path.join(dst, "index.js"));
	}
	fs.cpSync(path.join(pkgsDir, FLOCK_PKG), path.join(container, FLOCK_PKG), { recursive: true });
	return { root, container };
}

function main() {
	const pkgsDir = findPackagesDir();
	if (!pkgsDir) {
		console.error("[ERROR  ] 未找到真实 dsh 包目录；可用 DSH_DIR=<dsh 安装根> 指定。");
		process.exit(1);
	}
	console.log(`真实包目录（只读源 + 未触碰断言）: ${pkgsDir}`);
	const before = new Map(productionTargets(pkgsDir).map((f) => [f, sha(f)]));
	// 目标文件缺失时 sha()=null，会让「前后一致」变成 null===null 的恒真断言——先显式挡掉。
	for (const file of before.keys()) {
		if (!fs.existsSync(file)) {
			console.log(`  [FAIL] 生产目标缺失，夹具无法给出有效结论: ${file}`);
			fail++;
		}
	}

	// 1) link：--root 不存在 → 硬契约退 1
	{
		console.log("\n用例 1：link --root 不存在 → 退 1，且不回落生产树");
		const r = run(LINK_PATCH, ["--root", path.join(os.tmpdir(), "dsh-guards-does-not-exist")]);
		check("退出码 1", r.status === 1, `rc=${r.status}`);
		check("报错点明 --root", /--root/.test(r.stderr), r.stderr.trim().split("\n")[0] || "");
		check("未打印任何作业目录", !/dsh 包目录:/.test(r.stdout), r.stdout.trim().split("\n")[0] || "");
	}

	// 2) link：--root 存在但不是包目录 → 同样是硬契约
	{
		console.log("\n用例 2：link --root 存在但不是包目录 → 退 1（旧实现在这里静默回落生产树）");
		const empty = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-guards-empty-"));
		cleanup.push(empty);
		const r = run(LINK_PATCH, ["--root", empty]);
		check("退出码 1", r.status === 1, `rc=${r.status}`);
		check("报错说明缺哪些包", /dsh-session-persistence-jsonl/.test(r.stderr), r.stderr.trim().split("\n")[0] || "");
		check("未回落到生产路径", !r.stdout.includes(pkgsDir) && !r.stderr.includes(pkgsDir), r.stdout.trim().split("\n")[0] || "");
	}

	// 3) link：--root 指向临时副本 → 作业目录就是副本
	const copy = makeCopyRoot(pkgsDir);
	cleanup.push(copy.root);
	{
		console.log("\n用例 3：link --root 指向临时副本 → 退 0，作业目录是副本");
		const r = run(LINK_PATCH, ["--root", copy.container]);
		check("退出码 0", r.status === 0, `rc=${r.status} ${r.stderr.trim()}`);
		check("打印的作业目录 = 副本", r.stdout.includes(`dsh 包目录: ${copy.container}`), r.stdout.split("\n")[0] || "");
		check("未出现生产路径", !r.stdout.includes(pkgsDir), r.stdout.split("\n")[0] || "");
	}

	// 3b) link 正向：0.2.2-rc.3 形状的**上游原文块**（三包）→ 全部 [PATCHED] 且可重复执行。
	//     旧夹具只覆盖「安装树已打过补丁」；这里补「全新上游文件」的正向路径，钉住 rc.3 形状
	//     （fs-local 的 options.createIfAbsent 块、attachment 的两处 link 发布、session 的迁移发布）。
	const FRESH_SESSION = [
		'import { link, rename } from "node:fs/promises";',
		"",
		"async function publishCurrentExclusive(staged, currentPath, internals) {",
		"\ttry {",
		"\t\tawait internals.fs.link(staged, currentPath);",
		"\t} catch (error) {",
		"\t\t/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */",
		"\t\tif (isEEXIST(error)) return false;",
		"\t\t/* v8 ignore next -- the filesystem error is already complete. */",
		"\t\tthrow error;",
		"\t}",
		"\tawait syncDirectory(dirname(currentPath), internals);",
		"\treturn true;",
		"}",
		"",
		"async function writeSessionLog(tmp, finalPath) {",
		"\tlet linked = false;",
		"\ttry {",
		"\t\tawait link(tmp, finalPath);",
		"\t\tlinked = true;",
		"\t} finally {",
		"\t\tif (!linked) await rm(tmp, { force: true });",
		"\t}",
		"}",
		"",
	].join("\n");
	const FRESH_ATTACHMENT = [
		'import { chmod, copyFile, link, rename, rm, unlink } from "node:fs/promises";',
		'import { dirname, join, resolve } from "node:path";',
		'import { randomUUID } from "node:crypto";',
		"",
		"async function ensureDurableDirectory(path, boundary) {",
		"\tconst target = resolve(path);",
		"\tconst stop = resolve(boundary);",
		"\tlet level = target;",
		"\twhile (level !== stop) {",
		"\t\tconst parent = dirname(level);",
		"\t\tawait syncDirectory(parent);",
		"\t\tif (parent === level) return;",
		"\t\tlevel = parent;",
		"\t}",
		"}",
		"",
		"async function publishImmutableAlias(root, source, target, sha256) {",
		"\tconst parent = dirname(target);",
		"\ttry {",
		"\t\tawait ensureDurableDirectory(parent, await ensureDurableHome(dirname(dirname(resolve(root)))));",
		"\t\ttry {",
		"\t\t\tawait link(source, target);",
		"\t\t} catch (error) {",
		"\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */",
		'\t\t\tif (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;',
		'\t\t\tif (await digestFile(target) !== sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");',
		"\t\t}",
		"\t} catch (error) {",
		"\t\tthrow error;",
		"\t}",
		"}",
		"",
		"async function publishStagedObject(root, target, staged) {",
		"\tconst parent = dirname(target);",
		"\ttry {",
		"\t\tawait ensureDurableDirectory(parent, staged.boundary);",
		"\t\ttry {",
		"\t\t\tawait link(staged.path, target);",
		"\t\t} catch (error) {",
		"\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */",
		'\t\t\tif (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;',
		'\t\t\tif (await digestFile(target) !== staged.sha256) throw new AttachmentError("Stored attachment failed integrity verification.", "ATTACHMENT_CORRUPT");',
		"\t\t}",
		"\t\tawait unlink(staged.path);",
		"\t} catch (error) {",
		"\t\tthrow error;",
		"\t}",
		"}",
		"",
	].join("\n");
	const FRESH_FS_LOCAL = [
		'import { link, lstat, open, rename, rm } from "node:fs/promises";',
		"",
		"function isEEXIST(error) {",
		'\treturn error instanceof Error && "code" in error && error.code === "EEXIST";',
		"}",
		"function errorMessage(error) {",
		"\treturn error instanceof Error ? error.message : String(error);",
		"}",
		"class FsError extends Error {",
		"\tconstructor(message, code, options) { super(message, options); this.code = code; }",
		"}",
		"async function throwGuardedCreateFailure(error, absolutePath, displayPath, inspectPublicationTarget) {",
		"\tthrow error;",
		"}",
		"",
		"async function writeFileAtomic(absolutePath, content, mode, signal, internals = {}, options = {}) {",
		'\tconst displayPath = options.displayPath ?? absolutePath;',
		"\tconst linkFile = internals.linkFile ?? link;",
		"\tconst inspectPublicationTarget = internals.inspectPublicationTarget ?? ((path) => lstat(path, { bigint: true }));",
		"\ttry {",
		"\t\tif (options.createIfAbsent) try {",
		"\t\t\tawait linkFile(tempPath, absolutePath);",
		"\t\t} catch (error) {",
		"\t\t\tawait throwGuardedCreateFailure(error, absolutePath, displayPath, inspectPublicationTarget);",
		"\t\t}",
		"\t} catch (error) {",
		"\t\tthrow error;",
		"\t}",
		"}",
		"",
	].join("\n");

	const fresh = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-guards-fresh-"));
	cleanup.push(fresh);
	const FRESH_PKGS = [
		["dsh-session-persistence-jsonl", FRESH_SESSION],
		["dsh-attachment-local", FRESH_ATTACHMENT],
		["dsh-fs-local", FRESH_FS_LOCAL],
	];
	for (const [name, content] of FRESH_PKGS) {
		const lib = path.join(fresh, name, "lib");
		fs.mkdirSync(lib, { recursive: true });
		fs.writeFileSync(path.join(lib, "index.js"), content);
		fs.writeFileSync(path.join(fresh, name, "package.json"), JSON.stringify({ type: "module" }) + "\n");
	}
	{
		console.log("\n用例 3b：0.2.2-rc.3 形状上游原文 → 三包全部正向 [PATCHED] + 幂等");
		const r = run(LINK_PATCH, ["--root", fresh]);
		check("退出码 0", r.status === 0, `rc=${r.status} ${r.stderr.trim()}`);
		check("打印的作业目录 = 全新上游树", r.stdout.includes(`dsh 包目录: ${fresh}`), r.stdout.split("\n")[0] || "");
		for (const name of LINK_PKGS) {
			check(`${name} 报 [PATCHED]`, new RegExp(`\\[PATCHED \\] ${name}:`).test(r.stdout), r.stdout.split("\n").find((l) => l.includes(name)) || "");
		}
		const sessionSrc = fs.readFileSync(path.join(fresh, "dsh-session-persistence-jsonl", "lib", "index.js"), "utf8");
		check("session 加了无硬链接 helpers + 迁移回退", sessionSrc.includes("function isHardLinkUnavailable(") && sessionSrc.includes("function publishNoReplaceNoHardlink(") && sessionSrc.includes("publishNoReplaceNoHardlink(staged, currentPath)"));
		check("session 直接发布改 rename", sessionSrc.includes("await rename(tmp, finalPath);") && !sessionSrc.includes("await link(tmp, finalPath);"));
		const attSrc = fs.readFileSync(path.join(fresh, "dsh-attachment-local", "lib", "index.js"), "utf8");
		check("attachment 加了 helpers + 两处回退 + copyFile 导入", attSrc.includes("function isHardLinkUnavailable(") && attSrc.includes("function publishNoReplaceNoHardlink(") && /import \{[^}]*\bcopyFile\b[^}]*\} from "node:fs\/promises"/.test(attSrc));
		check("attachment 祖先遍历容忍 EACCES", attSrc.includes("syncDirectoryTolerant(parent)") && attSrc.includes("async function syncDirectoryTolerant("));
		const fsLocalSrc = fs.readFileSync(path.join(fresh, "dsh-fs-local", "lib", "index.js"), "utf8");
		check("fs-local 加了 helpers + options 形状回退", fsLocalSrc.includes("function isHardLinkUnavailable(") && fsLocalSrc.includes("function publishNoReplaceNoHardlink(") && fsLocalSrc.includes("if (isHardLinkUnavailable(error)) await publishNoReplaceNoHardlink("));
		let syntaxOk = true;
		for (const [name] of FRESH_PKGS) {
			const c = spawnSync(process.execPath, ["--check", path.join(fresh, name, "lib", "index.js")], { encoding: "utf8" });
			if (c.status !== 0) syntaxOk = false;
		}
		check("三包打完后 node --check 通过", syntaxOk);
		const r2 = run(LINK_PATCH, ["--root", fresh]);
		check("二次运行退 0", r2.status === 0, `rc=${r2.status}`);
		check("二次运行三包全部 [OK]（幂等）", (r2.stdout.match(/\[OK      \]/g) || []).length === 3, (r2.stdout.match(/\[OK      \]/g) || []).length + " 个 OK");
	}

	// 4) link：仅出现回退「调用」字样、没有函数定义 → 必须 WARN 而不是假 [OK]（缺陷 2 回归）
	{
		console.log("\n用例 4：link 会话文件只有一句含 publishNoReplaceNoHardlink 的注释 → 退 2 + [WARN]（缺陷 2 回归）");
		const fake = [
			"// NOTE: publishNoReplaceNoHardlink(staged, currentPath) is the new no-replace publisher (upstream prose only).",
			"async function publishCurrentExclusive(tmp, finalPath) {",
			"\tawait rename(tmp, finalPath);",
			"}",
			"",
		].join("\n");
		fs.writeFileSync(path.join(copy.container, "dsh-session-persistence-jsonl", "lib", "index.js"), fake);
		const r = run(LINK_PATCH, ["--root", copy.container]);
		const both = r.stdout + r.stderr;   // 异常项走 stderr（link 与 flock 一致），断言看合并输出
		check("退出码 2（有 WARN）", r.status === 2, `rc=${r.status}`);
		check("会话项报 [WARN]", /\[WARN    \] dsh-session-persistence-jsonl/.test(both), both.split("\n").find((l) => l.includes("dsh-session-persistence-jsonl")) || "");
		check("没有假 already-fixed", !both.includes("会话发布已用 rename + 无硬链接回退"), both.split("\n").find((l) => l.includes("dsh-session-persistence-jsonl")) || "");
		check("失败文件未被写入", fs.readFileSync(path.join(copy.container, "dsh-session-persistence-jsonl", "lib", "index.js"), "utf8") === fake);
	}

	// 4b) link：helper 签名只出现在**模板字符串**里（无真定义）→ 必须 WARN 而不是假 [OK]
	{
		console.log("\n用例 4b：link 附件文件把两个 helper 签名写进模板字符串 → 退 2 + [WARN]（词法剥离回归）");
		const decoy = [
			"const HELP = `",
			"async function isHardLinkUnavailable(error) { return true; }",
			"async function publishNoReplaceNoHardlink(tempPath, absolutePath, displayPath) {}",
			"publishNoReplaceNoHardlink(staged, currentPath)",
			"`;",
			"async function publishStagedObject(staged, target) {",
			"\tawait link(staged.path, target);",
			"}",
			"",
		].join("\n");
		const attFile = path.join(copy.container, "dsh-attachment-local", "lib", "index.js");
		fs.writeFileSync(attFile, decoy);
		const r = run(LINK_PATCH, ["--root", copy.container]);
		const both = r.stdout + r.stderr;
		check("退出码 2（有 WARN）", r.status === 2, `rc=${r.status}`);
		check("附件项报 [WARN]", /\[WARN    \] dsh-attachment-local/.test(both), both.split("\n").find((l) => l.includes("dsh-attachment-local")) || "");
		check("模板串里的签名不算已修", !both.includes("附件发布已接入无硬链接回退"), both.split("\n").find((l) => l.includes("dsh-attachment-local")) || "");
		check("失败文件未被写入", fs.readFileSync(attFile, "utf8") === decoy);
	}

	// 5) flock：--root 不存在 → 硬契约退 1
	{
		console.log("\n用例 5：flock --root 不存在 → 退 1，且不回落生产树");
		const r = run(FLOCK_PATCH, ["--root", path.join(os.tmpdir(), "dsh-guards-does-not-exist")]);
		check("退出码 1", r.status === 1, `rc=${r.status}`);
		check("报错点明 --root 与 flock.js", /--root/.test(r.stderr) && /flock\.js/.test(r.stderr), r.stderr.trim().split("\n")[0] || "");
		check("未打印任何作业目录", !/dsh 包目录:/.test(r.stdout), r.stdout.trim().split("\n")[0] || "");
	}

	// 6) flock：--root 存在但不是包目录 → 硬契约（旧 flock 会静默回落生产树，这才是真缺陷）
	{
		console.log("\n用例 6：flock --root 存在但不是包目录 → 退 1（旧 flock 在此静默回落生产树）");
		const empty = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-guards-empty-flock-"));
		cleanup.push(empty);
		const r = run(FLOCK_PATCH, ["--root", empty]);
		check("退出码 1", r.status === 1, `rc=${r.status}`);
		check("报错点明 --root 与 flock.js", /--root/.test(r.stderr) && /flock\.js/.test(r.stderr), r.stderr.trim().split("\n")[0] || "");
		check("未回落到生产路径", !r.stdout.includes(pkgsDir) && !r.stderr.includes(pkgsDir), r.stdout.trim().split("\n")[0] || "");
	}

	// 7) flock：--root 指向临时副本 → 删掉复制来的产物，验证它**真的在副本里编译**
	{
		console.log("\n用例 7：flock --root 指向临时副本 → 删掉复制产物后仍退 0，且确实在副本内 [BUILT]");
		const outFile = path.join(copy.container, FLOCK_PKG, "bin", `android-${process.arch}`, "system.node");
		fs.rmSync(outFile, { force: true });
		const r = run(FLOCK_PATCH, ["--root", copy.container]);
		check("退出码 0", r.status === 0, `rc=${r.status} ${r.stderr.trim()}`);
		check("打印的作业目录 = 副本", r.stdout.includes(`dsh 包目录: ${copy.container}`), r.stdout.split("\n")[0] || "");
		check("未出现生产路径", !r.stdout.includes(pkgsDir), r.stdout.split("\n")[0] || "");
		check("副本内真的编译（[BUILT]）", /\[BUILT   \]/.test(r.stdout), r.stdout.split("\n").find((l) => l.includes("[BUILT")) || r.stdout.trim());
		check("副本内产出可加载的 system.node", fs.existsSync(outFile));
	}

	// 8) flock：只剩一句 marker 注释（没有真 android 分支）→ 必须 WARN，不得假 [OK]
	{
		console.log("\n用例 8：flock.js 只剩一句 marker 注释 → 退 2 + [WARN]（旧 flock 在此报 [OK]）");
		const flockJs = path.join(copy.container, FLOCK_PKG, "lib", "flock.js");
		const fake = [
			"// [dsh-android-flock] android 分支见下方（其实并没有）",
			"const { platform, arch } = process;",
			"export function loadBinding() {",
			"\tif (platform !== 'linux' && platform !== 'darwin') throw new Error('flock is not supported on android-' + arch);",
			"\treturn internal;",
			"}",
			"",
		].join("\n");
		fs.writeFileSync(flockJs, fake);
		const r = run(FLOCK_PATCH, ["--root", copy.container]);
		check("退出码 2（有 WARN）", r.status === 2, `rc=${r.status}`);
		check("报 [WARN] 而非 [OK] 已包含 android 分支", /\[WARN    \]/.test(r.stdout + r.stderr) && !/已包含 android 分支/.test(r.stdout + r.stderr), (r.stdout + r.stderr).trim().split("\n").pop());
		check("假文件未被改写", fs.readFileSync(flockJs, "utf8") === fake);
	}

	// 8b) flock：分支文本藏在 `label://` 行注释里（旧 stripComments 的 `[^:]` 保护会被绕过）→ 必须 WARN
	{
		console.log("\n用例 8b：flock.js 把 android 分支藏在 `label://` 注释里 → 退 2 + [WARN]（词法剥离回归）");
		const flockJs = path.join(copy.container, FLOCK_PKG, "lib", "flock.js");
		const decoy = [
			"androidHint:// if (platform === 'android') { binding = require('.../bin/android-' + arch + '/system.node'); return binding; }",
			"export function loadBinding() {",
			"\treturn internal;",
			"}",
			"",
		].join("\n");
		fs.writeFileSync(flockJs, decoy);
		const r = run(FLOCK_PATCH, ["--root", copy.container]);
		const both = r.stdout + r.stderr;
		check("退出码 2（有 WARN）", r.status === 2, `rc=${r.status}`);
		check("报 [WARN] 而非假 [OK]", /\[WARN    \]/.test(both) && !/已包含 android 分支/.test(both), both.trim().split("\n").pop());
		check("假文件未被改写", fs.readFileSync(flockJs, "utf8") === decoy);
	}

	// 9) 生产树零改动 + 断言总数下限
	{
		console.log("\n用例 9：生产树 5 个目标文件哈希前后一致（夹具没有写穿）");
		for (const [file, hash] of before) {
			check(`${path.relative(pkgsDir, file)} 未变`, hash !== null && sha(file) === hash, file);
		}
		if (pass < EXPECTED_MIN_CHECKS) {
			console.log(`  [FAIL] 断言数不足：PASS=${pass} < ${EXPECTED_MIN_CHECKS}（有断言被删除或提前跳过）`);
			fail++;
		}
	}

	for (const dir of cleanup) fs.rmSync(dir, { recursive: true, force: true });
	console.log(`\n==== 夹具自检：PASS=${pass} FAIL=${fail}（断言下限 ${EXPECTED_MIN_CHECKS}）====`);
	if (fail > 0) process.exit(1);
}

try {
	main();
} catch (error) {
	// 出错路径也要清理临时目录（旧实现在这里泄漏目录）。
	for (const dir of cleanup) {
		try {
			fs.rmSync(dir, { recursive: true, force: true });
		} catch {}
	}
	console.error(`[ERROR   ] ${error.message}`);
	process.exit(1);
}
