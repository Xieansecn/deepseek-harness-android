#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-composer-enter-fixture.js
 *
 * setup.sh 4d「作曲栏回车补丁」的**锚点/产物夹具自检**：
 * 从 setup.sh 里**原样抽取**嵌入的 python 补丁逻辑（单一事实来源，避免夹具与生产逻辑分叉），
 * 再对两代上游产物形状各跑一遍，验证「普通回车=换行、Ctrl/Cmd+Enter=发送」语义与失败/幂等行为。
 *
 * 为什么需要它：dsh 0.2.2-rc.3 起 dsh-client-ui-conversation/lib/client.js 被压成**单行**产物，
 * 旧锚点（多行格式化版）在 rc.3 上出现 0 次 → setup.sh 按既有硬阻断语义 exit 1（T3 基线实测）。
 * 该补丁不能只测「真机安装树」（换版本即失效），必须在夹具里同时钉住：
 *   A 多行格式化产物（0.2.2-rc.1）→ 独占一行 + 同缩进插入（历史插入点：
 *     IME guard 之后、菜单 arbitrate('enter') 之前，旧线设备上已在运行的行为，保持不变）；
 *   B 压缩单行产物（0.2.2-rc.3+）→ 无行边界，guard 内联接在【菜单仲裁块之后、原生
 *     preventDefault 之前】：菜单（slash/@）打开时普通回车先被菜单消费，未被消费才交给
 *     Lexical 原生换行，Ctrl/Cmd+Enter 继续 submit；
 * 以及标记幂等、歧义锚点拒绝、上下文不是 enter 仲裁分支时拒绝、失败时零改写。
 *
 * 用法：node patches/verify-composer-enter-fixture.js
 * 退出码：0 = 全部通过；1 = 有断言失败。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const HERE = path.dirname(fs.realpathSync(__filename));
const REPO = path.dirname(HERE);
const SETUP = path.join(REPO, "setup.sh");
const MARKER = "dsh-android: 普通回车换行";
const GUARD_FORMATTED = "if (event?.ctrlKey !== true && event?.metaKey !== true) return false;";
const GUARD_MINIFIED = "if(event?.ctrlKey!==true&&event?.metaKey!==true)return false;";
const EXPECTED_MIN_CHECKS = 22;

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

/** 从 setup.sh 抽取 4d 的 python heredoc（唯一事实来源）。 */
function extractComposerPython() {
	const lines = fs.readFileSync(SETUP, "utf8").split("\n");
	let start = -1;
	for (let i = 0; i < lines.length; i++) {
		if (lines[i].includes('python3 - "$CB"') && lines[i].includes("<<'PY'")) {
			start = i + 1;
			break;
		}
	}
	if (start < 0) throw new Error("setup.sh 里找不到 4d 的 python heredoc（python3 - \"$CB\" <<'PY'）");
	let end = -1;
	for (let i = start; i < lines.length; i++) {
		if (lines[i] === "PY") {
			end = i;
			break;
		}
	}
	if (end < 0) throw new Error("4d python heredoc 没有结束行 PY");
	return lines.slice(start, end).join("\n") + "\n";
}

function tempDir(label) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), `dsh-composer-${label}-`));
	cleanup.push(dir);
	return dir;
}

/** 运行抽取出来的 python 补丁（与 setup.sh 里同参数：python3 <script> <client.js>）。 */
function runPatch(script, target) {
	return spawnSync("python3", [script, target], { encoding: "utf8", env: { ...process.env, SP_CLEAR: "" } });
}

const FORMATTED_OK = [
	"/** 合成产物：多行格式化（0.2.2-rc.1）。 */",
	"export function makeEnterHandler(isComposingEvent, recentlyComposing, handlers) {",
	"\treturn (event) => {",
	"\t\t\t\tif (event !== null && isComposingEvent(event, recentlyComposing)) return true;",
	'\t\t\t\tif (handlers.arbitrate("enter", false) !== "pass") {',
	"\t\t\t\t\tevent?.preventDefault();",
	"\t\t\t\t\treturn true;",
	"\t\t\t\t}",
	"\t\treturn false;",
	"\t};",
	"}",
	"",
].join("\n");

/** 合成产物：0.2.2-rc.3+ 压缩单行（整文件一行 + 末尾 sourceMappingURL 行）。 */
const MINIFIED_OK = [
	'export const factory = (isComposingEvent, recentlyComposing, handlers) => (event) => {if(event!==null&&(event.altKey||event.ctrlKey))return true;if(event!==null&&isComposingEvent(event,recentlyComposing))return true;if(handlers.arbitrate(' + String.fromCharCode(96) + 'enter' + String.fromCharCode(96) + ',false)!==' + String.fromCharCode(96) + 'pass' + String.fromCharCode(96) + '){event?.preventDefault();return true}event?.preventDefault();if(event?.repeat===true)return true;if(!handlers.canSubmit())return true;handlers.submit(event?.ctrlKey===true||event?.metaKey===true);return true};',
	"//# sourceMappingURL=client.js.map",
].join("\n");

function main() {
	const python = extractComposerPython();
	check("从 setup.sh 抽取到 4d python 逻辑", python.includes("isComposingEvent") && python.includes("arbitrate"), `${python.length} bytes`);
	const dir = tempDir("main");
	const script = path.join(dir, "patch_composer.py");
	fs.writeFileSync(script, python);

	// ---- 用例 1：多行格式化产物（旧线）----
	console.log("\n用例 1：多行格式化产物（0.2.2-rc.1）");
	const fmt = path.join(dir, "formatted.mjs");
	fs.writeFileSync(fmt, FORMATTED_OK);
	const r1 = runPatch(script, fmt);
	const fmtOut = fs.readFileSync(fmt, "utf8");
	check("退出码 0", r1.status === 0, `rc=${r1.status} ${(r1.stderr || "").trim()}`);
	check("写入幂等标记", (fmtOut.match(new RegExp(MARKER, "g")) || []).length === 1, `marker=${(fmtOut.match(new RegExp(MARKER, "g")) || []).length}`);
	check(
		"guard 独占一行且与锚点同缩进",
		fmtOut.includes("\t\t\t\tif (event !== null && isComposingEvent(event, recentlyComposing)) return true;\n"
			+ "\t\t\t\t/* " + MARKER + "，Ctrl/Cmd+Enter 发送 */\n"
			+ "\t\t\t\t" + GUARD_FORMATTED + "\n"),
		JSON.stringify(fmtOut.split("\n").slice(3, 6)),
	);
	check("guard 位于 enter 仲裁分支之前", fmtOut.indexOf(GUARD_FORMATTED) < fmtOut.indexOf('handlers.arbitrate("enter"'));
	const syntax1 = spawnSync(process.execPath, ["--check", fmt], { encoding: "utf8" });
	check("打完后 node --check 通过", syntax1.status === 0, (syntax1.stderr || "").trim().split("\n")[0] || "");

	// ---- 用例 2：压缩单行产物（0.2.2-rc.3+）----
	console.log("\n用例 2：压缩单行产物（0.2.2-rc.3+）");
	const mini = path.join(dir, "minified.mjs");
	fs.writeFileSync(mini, MINIFIED_OK);
	const r2 = runPatch(script, mini);
	const miniOut = fs.readFileSync(mini, "utf8");
	check("退出码 0", r2.status === 0, `rc=${r2.status} ${(r2.stderr || "").trim()}`);
	check("写入幂等标记", miniOut.includes(MARKER), miniOut.slice(0, 120));
	const bq = String.fromCharCode(96);
	check(
		"guard 内联接在菜单仲裁块之后、原生 preventDefault 之前（不引入换行）",
		miniOut.includes("!==\u0060pass\u0060){event?.preventDefault();return true}/* " + MARKER + "，Ctrl/Cmd+Enter 发送 */" + GUARD_MINIFIED + "event?.preventDefault();"),
		miniOut.slice(miniOut.indexOf("handlers.arbitrate("), miniOut.indexOf("handlers.arbitrate(") + 260),
	);
	check("行数不变（单行产物不被拆行）", miniOut.split("\n").length === MINIFIED_OK.split("\n").length, `lines=${miniOut.split("\n").length}`);
	const arbIdx = miniOut.indexOf("handlers.arbitrate(");
	const guardIdx = miniOut.indexOf(GUARD_MINIFIED);
	check("rc.3 语义：菜单 arbitrate 在 guard 之前（菜单回车不被吞）", arbIdx !== -1 && guardIdx > arbIdx, `arbitrate@${arbIdx} guard@${guardIdx}`);
	check("rc.3 语义：guard 之后才到原生 preventDefault", guardIdx !== -1 && miniOut.indexOf("event?.preventDefault()", guardIdx) > guardIdx);
	check("rc.3 语义：guard 不再插在多行 IME 锚点之后", !miniOut.includes("recentlyComposing))return true;/* " + MARKER));
	const syntax2 = spawnSync(process.execPath, ["--check", mini], { encoding: "utf8" });
	check("打完后 node --check 通过", syntax2.status === 0, (syntax2.stderr || "").trim().split("\n")[0] || "");

	// ---- 用例 3：幂等（两代形状重复执行都不重复插入）----
	console.log("\n用例 3：幂等（重复执行不重复插入）");
	const fmtBefore = fs.readFileSync(fmt, "utf8");
	const miniBefore = fs.readFileSync(mini, "utf8");
	const r3a = runPatch(script, fmt);
	const r3b = runPatch(script, mini);
	check("格式化产物二次执行退 0", r3a.status === 0, `rc=${r3a.status}`);
	check("压缩产物二次执行退 0", r3b.status === 0, `rc=${r3b.status}`);
	check("二次执行报 already patched", /already patched/.test(r3a.stdout + r3b.stdout), (r3a.stdout + r3b.stdout).trim());
	check("格式化产物零改写", fs.readFileSync(fmt, "utf8") === fmtBefore);
	check("压缩产物零改写", fs.readFileSync(mini, "utf8") === miniBefore);
	check("guard 全文只出现一次", (fmtOut.match(new RegExp(GUARD_FORMATTED.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) || []).length === 1);

	// ---- 用例 4：锚点歧义 / 缺失 / 上下文不符 → 退 2 且零改写 ----
	console.log("\n用例 4：锚点歧义/缺失/上下文不符 → 退 2 且零改写");
	const bads = [
		["锚点出现两次（歧义）", FORMATTED_OK.replace("\t\treturn false;", "\t\t\t\tif (event !== null && isComposingEvent(event, recentlyComposing)) return true;\n\t\treturn false;")],
		["锚点缺失", "export function nope() { return true; }\n"],
		["锚点后不是 enter 仲裁分支", FORMATTED_OK.replace('handlers.arbitrate("enter", false)', 'handlers.arbitrate("escape", false)')],
	];
	for (const [label, content] of bads) {
		const file = path.join(dir, `bad-${bads.findIndex((b) => b[1] === content)}.mjs`);
		fs.writeFileSync(file, content);
		const r = runPatch(script, file);
		check(`${label} → 退 2`, r.status === 2, `rc=${r.status}`);
		check(`${label} → 零改写`, fs.readFileSync(file, "utf8") === content);
	}

	// ---- 用例 5：setup.sh 里 4d 仍是硬阻断语义（失败要回滚 + exit 1，不能只 warn）----
	console.log("\n用例 5：setup.sh 4d 失败语义（回滚 + exit 1）");
	const setupText = fs.readFileSync(SETUP, "utf8");
	check("失败分支回滚备份", setupText.includes('cp -f "$CB_BAK" "$CB"') || setupText.includes('cp -f "$CB_BAK" "$CB" 2>/dev/null'));
	check("失败分支 exit 1（与 4f 同属硬阻断）", /client-ui-conversation 回车补丁未生效[\s\S]{0,200}exit 1/.test(setupText));
	check("已就位分支清理残留备份", /rm -f "\$CB_BAK"[^\n]*已应用：清理历史\/残留备份/.test(setupText));

	if (pass < EXPECTED_MIN_CHECKS) {
		console.log(`  [FAIL] 断言数不足：PASS=${pass} < ${EXPECTED_MIN_CHECKS}（有断言被删除或提前跳过）`);
		fail++;
	}
	for (const d of cleanup) fs.rmSync(d, { recursive: true, force: true });
	console.log(`\n==== 回车补丁夹具：PASS=${pass} FAIL=${fail}（断言下限 ${EXPECTED_MIN_CHECKS}）====`);
	if (fail > 0) process.exit(1);
}

try {
	main();
} catch (error) {
	for (const d of cleanup) {
		try {
			fs.rmSync(d, { recursive: true, force: true });
		} catch {}
	}
	console.error(`[ERROR   ] ${error.message}`);
	process.exit(1);
}
