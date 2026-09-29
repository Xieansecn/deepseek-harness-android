#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-profile-patch-fixture.js
 *
 * `patches/apply-profile-patch.js` 的夹具自检：在 `mktemp` 目录里造各种
 * `cordis.patch.yml` 形态，跑真脚本、断言退出码/标签/文件字节与解析结果。
 *
 * 为什么要有它：这个 bug 的代价是「dsh 完全起不来」，而且现场（`~/.dsh`）不能
 * 拿来当实验场。夹具只写临时目录；唯一读真实安装树的地方，是断言真实
 * `~/.dsh/profiles/web/cordis.patch.yml` **未被触碰**。
 *
 * 用例 3 复刻的就是用户踩到的形态：dsh 自己写的空数组模板 + 旧版 setup.sh
 * 追加的权限层 —— 必须先断言它确实解析不了（复现），再断言修好了。
 *
 * 用法：node patches/verify-profile-patch-fixture.js
 * 退出码：0 = 全绿；1 = 有 FAIL。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { pathToFileURL } = require("node:url");

const SCRIPT = path.join(__dirname, "apply-profile-patch.js");
const LAYER = path.join(__dirname, "..", "config", "cordis.patch.yml");
const REAL_PROFILE = path.join(os.homedir(), ".dsh", "profiles", "web", "cordis.patch.yml");
const APP_BOOT_REL = path.join("node_modules", "@deepseek-ai", "dsh-app-boot", "lib", "index.js");

/** dsh initProfile() 写的模板（逐字节取自 dsh-app-boot 的 PROFILE_PATCH_TEMPLATE）。 */
const TEMPLATE =
	"# Your patch layer for this dsh profile, applied after every bundle layer:\n" +
	"# a top-level YAML array of loader patch entries (id-targeted config\n" +
	"# overrides, disables, and insert lists; `!!js` expressions allowed).\n" +
	"[]\n";

const USER_LAYER = "# 用户自己的层\n- id: approval\n  config:\n    policy: never\n- id: session-query-sqlite\n  config:\n    openAt: first-search\n";

let pass = 0;
let fail = 0;

function check(label, ok, detail) {
	if (ok) {
		pass += 1;
		console.log(`  [OK]   ${label}`);
	} else {
		fail += 1;
		console.log(`  [FAIL] ${label}${detail ? ` — ${detail}` : ""}`);
	}
}

function run(target, extra = []) {
	const result = spawnSync(process.execPath, [SCRIPT, "--target", target, "--layer", LAYER, ...extra], { encoding: "utf8" });
	return { rc: result.status, out: result.stdout || "", err: result.stderr || "" };
}

function sha(file) {
	return fs.existsSync(file) ? require("node:crypto").createHash("sha256").update(fs.readFileSync(file)).digest("hex") : "(missing)";
}

function write(file, text, mode = 0o600) {
	fs.writeFileSync(file, text, { mode });
	fs.chmodSync(file, mode);
	return file;
}

/** 用 dsh 自己的解析器读文件：entries / null（解析失败）/ undefined（拿不到解析器）。 */
async function parseEntries(file) {
	if (!parseEntries.loader) {
		const candidates = [];
		try {
			candidates.push(path.dirname(require.resolve("@deepseek-ai/dsh/package.json")));
		} catch {}
		candidates.push(path.join(path.dirname(path.dirname(process.execPath)), "lib", "node_modules", "@deepseek-ai", "dsh"));
		for (const root of candidates) {
			const entry = path.join(root, APP_BOOT_REL);
			if (!fs.existsSync(entry)) continue;
			try {
				const mod = await import(pathToFileURL(entry).href);
				parseEntries.loader = mod.loadOverlayPatches;
				break;
			} catch {}
		}
	}
	if (!parseEntries.loader) return undefined;
	try {
		return parseEntries.loader("dsh", file);
	} catch {
		return null;
	}
}

function entriesOf(entries) {
	return Array.isArray(entries) ? entries.map((entry) => entry && entry.id).join(",") : "(not-array)";
}

function noLeftovers(dir) {
	return fs.readdirSync(dir).filter((name) => name.includes(".dsh-android.bak") || name.includes(".tmp-"));
}

async function main() {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-profile-patch-fixture-"));
	const realBefore = sha(REAL_PROFILE);

	console.log("用例 1：目标不存在 → 写入权限层");
	{
		const target = path.join(root, "case1.yml");
		const result = run(target);
		const entries = await parseEntries(target);
		check("退出码 0", result.rc === 0, `rc=${result.rc}`);
		check("报 [CREATED]", result.out.includes("[CREATED ]"));
		check("解析为 sandbox-policy + approval 两条", entriesOf(entries) === "sandbox-policy,approval", entriesOf(entries));
		check("权限位 0600", (fs.statSync(target).mode & 0o777) === 0o600, (fs.statSync(target).mode & 0o777).toString(8));
	}

	console.log("用例 2：dsh 的空数组模板 → 整体替换（不能追加！）");
	{
		const target = write(path.join(root, "case2.yml"), TEMPLATE);
		const result = run(target);
		const entries = await parseEntries(target);
		check("退出码 0", result.rc === 0, `rc=${result.rc}`);
		check("报 [REPLACED]", result.out.includes("[REPLACED]"), result.out.trim().split("\n").pop());
		check("解析为 sandbox-policy + approval 两条", entriesOf(entries) === "sandbox-policy,approval", entriesOf(entries));
		check("文件里不再有裸 `[]` 文档行", !fs.readFileSync(target, "utf8").split("\n").some((line) => line.trim() === "[]"));
	}

	console.log("用例 3：模板 + 旧版追加（用户踩到的崩溃现场）→ 定点修复");
	{
		const target = write(path.join(root, "case3.yml"), `${TEMPLATE}\n${fs.readFileSync(LAYER, "utf8")}`);
		const broken = await parseEntries(target);
		check("修复前确实解析不了（复现崩溃）", broken === null, `entries=${entriesOf(broken)}`);
		const result = run(target);
		const entries = await parseEntries(target);
		check("退出码 0", result.rc === 0, `rc=${result.rc}`);
		check("报 [REPAIRED]", result.out.includes("[REPAIRED]"), result.out.trim().split("\n").pop());
		check("修复后解析为 sandbox-policy + approval（并补齐缺失的 approval）", entriesOf(entries) === "sandbox-policy,approval", entriesOf(entries));
		check("无备份/临时文件残留", noLeftovers(root).length === 0, noLeftovers(root).join(","));
	}

	console.log("用例 4：真实用户层 → 追加权限层并保留原条目");
	{
		const target = write(path.join(root, "case4.yml"), USER_LAYER);
		const before = sha(target);
		const result = run(target);
		const entries = await parseEntries(target);
		check("退出码 0", result.rc === 0, `rc=${result.rc}`);
		check("报 [APPENDED]", result.out.includes("[APPENDED]"), result.out.trim().split("\n").pop());
		check("解析为 3 条且前两条是用户自己的", entriesOf(entries) === "approval,session-query-sqlite,sandbox-policy", entriesOf(entries));
		check("原内容被保留（前缀一致）", fs.readFileSync(target, "utf8").startsWith(USER_LAYER), "前缀不一致");
		check("文件确实变了", sha(target) !== before);
	}

	console.log("用例 5：已装过权限层 → 幂等不动");
	{
		const target = path.join(root, "case4.yml");
		const before = sha(target);
		const result = run(target);
		check("退出码 0", result.rc === 0, `rc=${result.rc}`);
		check("报 [OK]", result.out.includes("[OK      ]"), result.out.trim().split("\n").pop());
		check("文件字节未变", sha(target) === before);
	}

	console.log("用例 6：不可解析的用户文件 → 报错退 1 且一个字节都不动");
	{
		const target = write(path.join(root, "case6.yml"), "foo: [unclosed\n");
		const before = sha(target);
		const result = run(target);
		check("退出码 1", result.rc === 1, `rc=${result.rc}`);
		check("报 [ERROR]", result.out.includes("[ERROR   ]"));
		check("原文件字节未变", sha(target) === before);
		check("无备份/临时文件残留", noLeftovers(root).length === 0, noLeftovers(root).join(","));
	}

	console.log("用例 7：--root 硬契约（指到空目录必须报错退 1）");
	{
		const target = write(path.join(root, "case7.yml"), TEMPLATE);
		const empty = fs.mkdtempSync(path.join(os.tmpdir(), "not-a-dsh-root-"));
		const result = run(target, ["--root", empty]);
		check("退出码 1", result.rc === 1, `rc=${result.rc}`);
		check("报 [ERROR] 且提到 --root", result.out.includes("[ERROR   ]") && result.out.includes("--root"), result.out.trim().split("\n").pop());
		check("目标未被改写", fs.readFileSync(target, "utf8") === TEMPLATE);
		fs.rmSync(empty, { recursive: true, force: true });
	}

	console.log("用例 9：旧版留下的单条层（只有 sandbox-policy）→ 只补 approval，不重复 sandbox-policy");
	{
		const target = write(path.join(root, "case9.yml"), "# 旧版层\n- id: sandbox-policy\n  config:\n    mode: danger-full-access\n");
		const result = run(target);
		const text = fs.readFileSync(target, "utf8");
		const entries = await parseEntries(target);
		check("退出码 0", result.rc === 0, `rc=${result.rc}`);
		check("报 [APPENDED]", result.out.includes("[APPENDED]"), result.out.trim().split("\n").pop());
		check("两条层齐备", entriesOf(entries) === "sandbox-policy,approval", entriesOf(entries));
		check("sandbox-policy 没有被重复追加", text.split("- id: sandbox-policy").length - 1 === 1, "重复了");
		check("approval 已补上", text.includes("policy: never"));
	}

	console.log("用例 10：两条都已在 → 幂等不动");
	{
		const target = path.join(root, "case9.yml");
		const before = sha(target);
		const result = run(target);
		check("退出码 0", result.rc === 0, `rc=${result.rc}`);
		check("报 [OK]", result.out.includes("[OK      ]"), result.out.trim().split("\n").pop());
		check("文件字节未变", sha(target) === before);
	}

	console.log("用例 11：用户自己配了别的沙箱模式 → 不塞 approval（尊重用户选择）");
	{
		const text = "# 用户自己配的\n- id: sandbox-policy\n  config:\n    mode: workspace-write\n";
		const target = write(path.join(root, "case11.yml"), text);
		const before = sha(target);
		const result = run(target);
		check("退出码 0", result.rc === 0, `rc=${result.rc}`);
		check("报 [OK] 且说明未追加", result.out.includes("[OK      ]") && result.out.includes("未追加 approval"), result.out.trim().split("\n").pop());
		check("文件字节未变", sha(target) === before);
	}

	console.log("用例 8：不碰真实 profile（~/.dsh 哈希前后一致）");
	{
		check("真实 cordis.patch.yml 未被触碰", sha(REAL_PROFILE) === realBefore, `${realBefore} → ${sha(REAL_PROFILE)}`);
		check("临时目录里没有备份残留", noLeftovers(root).length === 0, noLeftovers(root).join(","));
	}

	fs.rmSync(root, { recursive: true, force: true });
	console.log(`\n==== 夹具自检：PASS=${pass} FAIL=${fail} ====`);
	if (fail > 0) process.exit(1);
}

main().catch((error) => {
	console.error(`[ERROR   ] ${error.stack || error.message}`);
	process.exit(1);
});
