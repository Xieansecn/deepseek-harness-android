#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-js-patches-fixture.js
 *
 * `apply-js-patches.sh` 的**夹具自检**：在临时目录里用「安装树反向打补丁」重建出**纯净上游**，
 * 再让脚本正向跑一遍，从而离线验证脚本的判定/退出码/产物，而不依赖设备当前状态或网络。
 *
 * 覆盖：
 *   1. 重建的纯净树确实是上游形态（不含 `CACHE_IMMUTABLE`、`newlineCount` 仍是 for-of）；
 *   2. 全新树：`01[ok] 02[deprecated] 03[ok]` + 退 0，且产物与真实安装树**逐字节一致**；
 *   3. 幂等：再跑一次 → `01[skip] 02[deprecated] 03[skip]` + 退 0；
 *   4. 目标被破坏（删掉 01 打进去的那行）→ `01[FAIL]` + **退 1**；
 *   5. 静态契约：`PATCHES` 顺序里 02 在 03 之前（顺序即语义）、02 在弃用围栏里、退出码只看 failed。
 *
 * 用法：node patches/verify-js-patches-fixture.js
 * 退出码：0 = 全部通过；1 = 有断言失败。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const HERE = path.dirname(fs.realpathSync(__filename));
const REPO = path.dirname(HERE);
const APPLY = path.join(REPO, "apply-js-patches.sh");
const PKG_FILES = ["dsh-host-frontend-static/lib/index.js", "dsh-client-modules/lib/index.js"];

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

/** 安装树的包目录（只读源）。 */
function installedPackagesDir() {
	if (process.env.DSH_INSTALL_PKGS) return process.env.DSH_INSTALL_PKGS;
	return path.join(path.dirname(path.dirname(process.execPath)), "lib", "node_modules", "@deepseek-ai", "dsh", "node_modules", "@deepseek-ai");
}

const runPatch = (work, args) => spawnSync("patch", args, { cwd: work, encoding: "utf8", input: "" });
const runApply = (work) => spawnSync("bash", [APPLY], { encoding: "utf8", env: { ...process.env, DSH_PACKAGES_DIR: work } });

function makeWork(srcPkgs) {
	const work = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-jspatch-fixture-"));
	cleanup.push(work);
	for (const rel of PKG_FILES) {
		const dst = path.join(work, rel);
		fs.mkdirSync(path.dirname(dst), { recursive: true });
		fs.copyFileSync(path.join(srcPkgs, rel), dst);
	}
	return work;
}

function main() {
	const srcPkgs = installedPackagesDir();
	for (const rel of PKG_FILES) {
		if (!fs.existsSync(path.join(srcPkgs, rel))) {
			console.error(`[ERROR  ] 找不到安装树源文件：${path.join(srcPkgs, rel)}（可用 DSH_INSTALL_PKGS 指定）`);
			process.exit(1);
		}
	}

	// 1) 反向应用 01/03，重建纯净上游
	const work = makeWork(srcPkgs);
	const r01 = runPatch(work, ["-p1", "-R", "-N", "-s", "-i", path.join(REPO, "patches", "01-frontend-static-cache.patch")]);
	const r03 = runPatch(work, ["-p1", "-R", "-N", "-s", "-i", path.join(REPO, "patches", "03-client-modules-newline-count.patch")]);
	check("反向应用 01 成功（重建纯净上游）", r01.status === 0, `rc=${r01.status} ${(r01.stderr || "").trim()}`);
	check("反向应用 03 成功（重建纯净上游）", r03.status === 0, `rc=${r03.status} ${(r03.stderr || "").trim()}`);
	const hostSrc = fs.readFileSync(path.join(work, PKG_FILES[0]), "utf8");
	const clientSrc = fs.readFileSync(path.join(work, PKG_FILES[1]), "utf8");
	check("纯净树不含 01 的产物（CACHE_IMMUTABLE）", !hostSrc.includes("CACHE_IMMUTABLE"));
	check("纯净树仍是 for-of（03 未打）", clientSrc.includes("for (const char of value)"), clientSrc.split("\n").find((l) => l.includes("newlineCount")) || "");

	// 2) 全新树正向跑：01[ok] 02[deprecated] 03[ok] + 退 0
	const r1 = runApply(work);
	check("全新树退 0", r1.status === 0, `rc=${r1.status} stderr=${(r1.stderr || "").trim()}`);
	check("报 01[ok]", /\[ok\]\s+01-frontend-static-cache/.test(r1.stdout || ""), (r1.stdout || "").trim().split("\n").find((l) => l.includes("01-")) || "");
	check("报 02[deprecated]", /\[deprecated\]\s+02-client-modules-lazy-compose/.test(r1.stdout || ""), (r1.stdout || "").trim().split("\n").find((l) => l.includes("02-")) || "");
	check("报 03[ok]", /\[ok\]\s+03-client-modules-newline-count/.test(r1.stdout || ""), (r1.stdout || "").trim().split("\n").find((l) => l.includes("03-")) || "");
	check("汇总行「失败 0，弃用 1」", /失败 0，弃用 1/.test(r1.stdout || ""), (r1.stdout || "").trim().split("\n").pop());

	// 3) 产物必须与真实安装树逐字节一致（脚本 ↔ 设备状态闭环）
	for (const rel of PKG_FILES) {
		const a = fs.readFileSync(path.join(work, rel));
		const b = fs.readFileSync(path.join(srcPkgs, rel));
		check(`产物与安装树一致：${rel.split("/")[0]}`, a.equals(b));
	}

	// 4) 幂等：再跑一次 → skip/deprecated/skip + 退 0
	const r2 = runApply(work);
	check("二次运行退 0", r2.status === 0, `rc=${r2.status}`);
	check("01 报 [skip]", /\[skip\]\s+01-frontend-static-cache/.test(r2.stdout || ""), (r2.stdout || "").trim());
	check("03 报 [skip]", /\[skip\]\s+03-client-modules-newline-count/.test(r2.stdout || ""), (r2.stdout || "").trim());
	check("02 仍只报 [deprecated]（不计失败）", /\[deprecated\]/.test(r2.stdout || "") && !/\[FAIL\]/.test(r2.stdout || ""), (r2.stdout || "").trim());

	// 5) 破坏目标 → 必须 [FAIL] + 退 1（且 02 的 deprecated 不该把退出码拉起来）
	const hostFile = path.join(work, PKG_FILES[0]);
	fs.writeFileSync(hostFile, fs.readFileSync(hostFile, "utf8").replace(/^\/\*\* Build assets under \/assets\/.*\n/m, ""));
	const r3 = runApply(work);
	check("破坏后退 1", r3.status === 1, `rc=${r3.status}`);
	check("报 01[FAIL]", /\[FAIL\]\s+01-frontend-static-cache/.test(r3.stdout || ""), (r3.stdout || "").trim().split("\n").find((l) => l.includes("01-")) || "");
	check("汇总行失败 1", /失败 1/.test(r3.stdout || ""), (r3.stdout || "").trim().split("\n").pop());

	// 6) 静态契约（PATCHES 顺序即语义）
	const scriptText = fs.readFileSync(APPLY, "utf8");
	const patchesLine = (scriptText.match(/^PATCHES=\(([^)]*)\)/m) || [])[1] || "";
	const deprecatedLine = (scriptText.match(/^DEPRECATED_PATCHES=\(([^)]*)\)/m) || [])[1] || "";
	check("PATCHES 里 02 在 03 之前（顺序即语义）", patchesLine.indexOf("02-") !== -1 && patchesLine.indexOf("02-") < patchesLine.indexOf("03-"), patchesLine.trim());
	check("02 登记在 DEPRECATED_PATCHES", deprecatedLine.includes("02-client-modules-lazy-compose"), deprecatedLine.trim());
	check("退出码只看 failed（`[ \"$failed\" -eq 0 ]`）", /\[\s*"\$failed"\s*-eq\s*0\s*\]/.test(scriptText));

	if (pass < 21) {
		console.log(`  [FAIL] 断言数不足：PASS=${pass} < 21（有断言被删除或提前跳过）`);
		fail++;
	}
	console.log(`\n==== 夹具自检：PASS=${pass} FAIL=${fail} ====`);
	if (fail > 0) process.exitCode = 1;
}

try {
	main();
} catch (error) {
	console.error(`[ERROR   ] ${error.message}`);
	process.exitCode = 1;
} finally {
	for (const dir of cleanup) fs.rmSync(dir, { recursive: true, force: true });
}
