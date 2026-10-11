#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-test-effectiveness.js
 *
 * **变异测试**：证明 `patches/verify-*-fixture.js` 与 `verify-setup-static-check.sh` 不是"总是绿"的摆设。
 * 做法：把整个仓库 `cp -a` 到临时目录 → 在副本里注入一个**已知回归**（正是历史上真出过的那些）
 * → 从副本里跑对应套件 → 断言**套件必须变红**。最后跑一次「未变异」的对照组，断言必须绿。
 *
 * 覆盖的变异（每条都对应一个真实缺陷或契约）：
 *   1. start_dsh.sh 去掉 `--port "$PORT"`（DSH_PORT 失效）        → runtime 夹具
 *   2. stop_dsh.sh 去掉「进程/端口仍在」的 exit 1                 → runtime 夹具
 *   3. restart_dsh_now.sh 去掉 curl=000 判定                      → runtime 夹具
 *   4. start_dsh.sh 降级原因不带 no-token 码                      → runtime 夹具
 *   5. apply-js-patches.sh 把 03 排到 02 前面（顺序即语义）        → js-patches 夹具
 *   6. apply-js-patches.sh 退出码不看 failed                      → js-patches 夹具
 *   7. setup.sh link 预检 marker 回退成裸标识符                   → 静态契约检查
 *   8. setup.sh 用「先 rm 后写」替换 mv -f 原子替换               → 静态契约检查
 *   9. guards 夹具里删掉 3 条断言                                 → guards 夹具（断言下限）
 *  10. 对照组：不改任何东西                                      → 对应套件必须绿
 *
 * 用法：node patches/verify-test-effectiveness.js
 * 退出码：0 = 每个变异都被抓住且对照组为绿；1 = 有变异没被抓住（测试有盲区）。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const HERE = path.dirname(fs.realpathSync(__filename));
const REPO = path.dirname(HERE);
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-mutation-"));
const CHECK = path.join(HERE, "verify-setup-static-check.sh");

let pass = 0;
let fail = 0;
const note = (ok, name, detail = "") => {
	if (ok) {
		pass++;
		console.log(`  [OK]   ${name}${detail ? ` —— ${detail}` : ""}`);
	} else {
		fail++;
		console.log(`  [FAIL] ${name}${detail ? ` —— ${detail}` : ""}`);
	}
};

/** 复制仓库到独立副本（互不影响）。 */
function cloneRepo(label) {
	const dst = path.join(WORK, `repo-${label}`);
	fs.cpSync(REPO, dst, { recursive: true, dereference: false });
	return dst;
}

function edit(repo, relPath, mutate) {
	const file = path.join(repo, relPath);
	const before = fs.readFileSync(file, "utf8");
	const after = mutate(before);
	if (after === before) throw new Error(`变异没有生效：${relPath}`);
	fs.writeFileSync(file, after);
}

function runSuite(repo, suite) {
	const [cmd, script, ...rest] =
		suite === "runtime"
			? ["node", path.join(repo, "patches", "verify-runtime-scripts-fixture.js")]
			: suite === "jspatches"
				? ["node", path.join(repo, "patches", "verify-js-patches-fixture.js")]
				: suite === "guards"
					? ["node", path.join(repo, "patches", "verify-patch-guards-fixture.js")]
					: suite === "profile"
						? ["node", path.join(repo, "patches", "verify-profile-patch-fixture.js")]
						: ["bash", path.join(repo, "patches", "verify-setup-static-check.sh")];
	const r = spawnSync(cmd, [script, ...rest], { cwd: repo, encoding: "utf8", timeout: 300000 });
	const out = `${r.stdout || ""}${r.stderr || ""}`;
	const firstFail = (out.split("\n").find((l) => l.includes("[FAIL]")) || "").trim();
	return { rc: r.status, firstFail };
}

/** 变异用例：每条 = 期望「套件必须变红」。 */
const CASES = [
	{
		name: "start_dsh.sh 去掉 --port（DSH_PORT 失效）",
		file: "start_dsh.sh",
		mutate: (s) => s.replace('nohup dsh web --no-open --port "$PORT"', "nohup dsh web --no-open"),
		suite: "runtime",
	},
	{
		name: "stop_dsh.sh 去掉失败时的 exit 1",
		file: "stop_dsh.sh",
		mutate: (s) => s.replace('仍在：$(list_pids | tr \'\\n\' \' \')" >&2\n  exit 1', '仍在：$(list_pids | tr \'\\n\' \' \')" >&2'),
		suite: "runtime",
	},
	{
		name: "restart_dsh_now.sh 去掉 curl=000 判定",
		file: "restart_dsh_now.sh",
		mutate: (s) => s.replace('[ -z "$_code" ] || [ "$_code" = "000" ]', '[ -z "$_code" ]'),
		suite: "runtime",
	},
	{
		name: "start_dsh.sh 降级原因不再打印 no-token",
		file: "start_dsh.sh",
		mutate: (s) => s.replace("no-token（日志里还没有带 token 的 URL）", "日志里还没有带 token 的 URL"),
		suite: "runtime",
	},
	{
		name: "apply-js-patches.sh 把 03 排到 02 前（顺序即语义）",
		file: "apply-js-patches.sh",
		mutate: (s) => s.replace("02-client-modules-lazy-compose 03-client-modules-newline-count", "03-client-modules-newline-count 02-client-modules-lazy-compose"),
		suite: "jspatches",
	},
	{
		name: "apply-js-patches.sh 退出码忽略 failed（报告仍说失败 1）",
		file: "apply-js-patches.sh",
		mutate: (s) => s.replace('echo "[apply-js-patches] 完成', 'failed=0; echo "[apply-js-patches] 完成'),
		suite: "jspatches",
	},
	{
		name: "setup.sh link 预检 marker 回退成裸标识符",
		file: "setup.sh",
		mutate: (s) => s.replace(/\|async function publishNoReplaceNoHardlink\(\|/g, "|publishNoReplaceNoHardlink|"),
		suite: "static",
	},
	{
		name: "setup.sh 用「先 rm 后写」替换 mv -f 原子替换",
		file: "setup.sh",
		mutate: (s) => s.replace('mv -f "$DSH_TMP" "$DSH_CMD"', 'rm -f "$DSH_CMD"\n  cp -f "$DSH_TMP" "$DSH_CMD"'),
		suite: "static",
	},
	{
		name: "guards 夹具删掉 3 条断言（断言下限必须拦住）",
		file: "patches/verify-patch-guards-fixture.js",
		mutate: (s) => {
			let n = 0;
			return s.replace(/^\t*check\(/gm, (m) => (n++ < 3 ? "\tvoid (" : m));
		},
		suite: "guards",
	},
];

console.log("== 变异测试：注入已知回归，套件必须变红 ==");
try {
	// 对照组：不改任何东西 → 套件必须绿
	const control = cloneRepo("control");
	for (const suite of ["runtime", "jspatches", "guards", "static"]) {
		const r = runSuite(control, suite);
		note(r.rc === 0, `对照组（未变异）${suite} 套件为绿`, `rc=${r.rc}`);
	}

	for (const [i, c] of CASES.entries()) {
		try {
			const repo = cloneRepo(String(i + 1));
			edit(repo, c.file, c.mutate);
			const r = runSuite(repo, c.suite);
			note(r.rc !== 0, `${c.name} → ${c.suite} 套件变红`, r.rc !== 0 ? `rc=${r.rc}；${r.firstFail.slice(0, 70)}` : "rc=0（没抓住！）");
		} catch (error) {
			note(false, `${c.name} → ${c.suite} 套件变红`, `变异本身没跑起来：${error.message}`);
		}
	}
} catch (error) {
	console.error(`[ERROR   ] ${error.message}`);
	fail++;
}

fs.rmSync(WORK, { recursive: true, force: true });
console.log(`\n==== 变异测试：PASS=${pass} FAIL=${fail} ====`);
if (fail > 0) process.exit(1);
