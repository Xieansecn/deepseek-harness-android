#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-pnpm-fixture.js
 *
 * `setup.sh` 的 **pnpm 安装方式 + 安装冲突预检** 夹具自检（不联网、不装包、不碰真实安装树/3080/~/.dsh）。
 *
 * 怎么测：pnpm 的安装/编译步骤太长也太重，不适合当回归测试；真正有契约价值的是**安装前的只读冲突预检**
 * 与「默认 npm 路径行为不变」。因此夹具把 setup.sh 当成黑盒脚本运行，但用两个隔离手段把风险降到零：
 *   1. `DSH_SETUP_PREFLIGHT_ONLY=1`：预检结束就退出，**任何用例都带它**——即使被测逻辑有 bug 也绝不会进入安装步骤；
 *   2. `DSH_SETUP_PREFIX=<临时目录>`：把 DSH_DIR / $PREFIX/bin 指向临时前缀（setup.sh 里的测试钩子），
 *      `HOME` 也指向临时目录，生产安装树与 ~/.dsh 完全不被触碰；
 *   3. `PATH` 只放「工具软链目录 + 每用例自己的假 pnpm 目录」：工具软链目录只有 bash/coreutils/node，
 *      没有真实 `dsh`/`pnpm`，所以用例结果不受本机生产状态影响（生产上装没装 dsh 都一样）。
 *
 * 覆盖：
 *   a) 找不到可运行的 pnpm → 中文提示 + exit 1（且不进入 1/9 安装步骤）；
 *   b) pnpm 主版本 >= 12（Android 原生二进制 store 锁必失败）→ exit 1；< 11（无 allowBuilds 语义）→ exit 1；版本不可解析 → exit 1；
 *   c) 已存在 dsh 安装（无 pnpm 归属标记）→ exit 1；DSH_PM_CONFLICT_OVERRIDE=1 时只警告并继续（预检通过）；
 *   d) PATH 上已有另一个 dsh → exit 1；
 *   e) 无冲突 11.x → 预检通过；`--pnpm` 旗标等价于 DSH_PM=pnpm；
 *   f) 默认 npm 路径不新增预检（存在「冲突」目录也不报错）、只预检模式正常退出；
 *   g) pnpm 壳包装的坏 shebang（#!/usr/bin/env …）不影响使用：解析器应当用 `node <...pnpm.mjs>` 而不是 exec 包装脚本；
 *   h) 冲突预检是只读的：临时前缀内容前后一致，且不创建任何安装目录。
 *
 * 用法：node patches/verify-pnpm-fixture.js
 * 退出码：0 = 全部通过；1 = 有断言失败（逐条打印）。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const HERE = path.dirname(fs.realpathSync(__filename));
const REPO = path.dirname(HERE);
const SETUP = path.join(REPO, "setup.sh");
const PREFIX = process.env.PREFIX || "/data/data/com.termux/files/usr";
const PREFIX_BIN = path.join(PREFIX, "bin");

let pass = 0;
let fail = 0;
const tmpRoots = [];

function ok(msg) {
	pass += 1;
	console.log(`  [PASS] ${msg}`);
}
function bad(msg, detail) {
	fail += 1;
	console.log(`  [FAIL] ${msg}${detail ? ` —— ${detail}` : ""}`);
}
function check(cond, msg, detail) {
	if (cond) ok(msg);
	else bad(msg, detail);
}

/** 建一个临时目录（os.tmpdir() 在 Termux 上就是 $PREFIX/tmp，符合仓库约定）。 */
function mkTmp(tag) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), `dsh-pnpm-fixture-${tag}-`));
	tmpRoots.push(dir);
	return dir;
}

/**
 * 工具软链目录：把 setup.sh 预检路径会用到的基础命令软链进来，**不含 dsh / pnpm**。
 * 这样 PATH 干净且与生产状态无关；setup.sh 的 shebang 是 Termux bash 绝对路径，这里再用 bash <script> 调用一次。
 */
const TOOLS = [
	"bash", "sh", "node", "mkdir", "date", "mktemp", "tail", "head", "grep", "tr",
	"readlink", "dirname", "basename", "rm", "cat", "sed", "awk", "chmod", "sleep",
	"mv", "cp", "sort", "wc", "cut", "env", "true", "false",
];
function makeToolbin(root) {
	const dir = path.join(root, "toolbin");
	fs.mkdirSync(dir, { recursive: true });
	for (const t of TOOLS) {
		const real = path.join(PREFIX_BIN, t);
		if (!fs.existsSync(real)) continue;
		try {
			fs.symlinkSync(real, path.join(dir, t));
		} catch {
			/* 软链失败就跳过：缺少的基础命令会在用例输出里以 command not found 暴露 */
		}
	}
	return dir;
}

/** 写一个假 pnpm：壳包装脚本（shebang 故意写成 Termux 不可解析的 #!/usr/bin/env sh）+ 内部真入口 .mjs。 */
function makeFakePnpm(root, version, opts = {}) {
	const dir = path.join(root, "pnpmbin");
	fs.mkdirSync(dir, { recursive: true });
	const mjs = path.join(dir, "fake-pnpm.mjs");
	fs.writeFileSync(
		mjs,
		[
			`const v = process.env.FAKE_PNPM_VERSION || "11.27.1";`,
			`if (process.argv[2] === "--version") { console.log(v); process.exit(0); }`,
			`process.exit(0);`,
			``,
		].join("\n"),
	);
	const wrapper = path.join(dir, "pnpm");
	// ⚠️ 故意用坏 shebang：验证 setup.sh 不会直接 exec 包装脚本，而是从内容里解析出 .mjs 用 node 跑。
	fs.writeFileSync(wrapper, `#!/usr/bin/env sh\nexec ${process.execPath} ${mjs} "$@"\n`);
	fs.chmodSync(wrapper, 0o755);
	// 个别用例需要「直接执行回退」不可用（模拟真坏包）：不再提供可执行位。
	if (opts.breakDirectExec) fs.chmodSync(wrapper, 0o644);
	return dir;
}

/** 建一个假前缀（可选：预置一个 dsh 目录 / pnpm 归属标记）。 */
function makeFakePrefix(root, opts = {}) {
	const prefix = path.join(root, "prefix");
	fs.mkdirSync(path.join(prefix, "bin"), { recursive: true });
	if (opts.withDsh) {
		const dsh = path.join(prefix, "lib", "node_modules", "@deepseek-ai", "dsh");
		fs.mkdirSync(path.join(dsh, "lib"), { recursive: true });
		fs.writeFileSync(path.join(dsh, "package.json"), JSON.stringify({ name: "@deepseek-ai/dsh", version: "0.0.0" }));
		fs.writeFileSync(path.join(dsh, "lib", "bin.js"), "/* fake dsh entry */\n");
		if (opts.pnpmOwned) fs.writeFileSync(path.join(dsh, ".dsh-android-pm"), "pnpm\n");
	}
	return prefix;
}

/** 递归快照目录内容（路径 → 文件内容/type），用于断言「预检只读」。 */
function snapshot(dir) {
	const out = [];
	const walk = (d) => {
		let ents = [];
		try {
			ents = fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
		} catch {
			return;
		}
		if (ents.length === 0) out.push(`${path.relative(dir, d)}|empty`);
		for (const e of ents) {
			const p = path.join(d, e.name);
			const rel = path.relative(dir, p);
			if (e.isDirectory()) {
				out.push(`${rel}|dir`);
				walk(p);
			} else if (e.isSymbolicLink()) {
				out.push(`${rel}|link:${fs.readlinkSync(p)}`);
			} else {
				let buf = "";
				try {
					buf = fs.readFileSync(p).toString("base64");
				} catch {
					buf = "<unreadable>";
				}
				out.push(`${rel}|file:${buf}`);
			}
		}
	};
	walk(dir);
	return out.join("\n");
}

/**
 * 跑一次 setup.sh（预检模式）。所有用例共用同一套隔离：临时 HOME + 临时前缀 + 干净 PATH。
 * @returns {{rc:number, out:string}}
 */
function runSetup(env, args = []) {
	const home = mkTmp("home");
	fs.mkdirSync(path.join(home, "dsh"), { recursive: true });
	const childEnv = {
		...process.env,
		HOME: home,
		NO_COLOR: "1",
		SETUP_VERBOSE: "0",
		DSH_PM: "npm",
		DSH_SETUP_PREFLIGHT_ONLY: "1",
		DSH_PM_CONFLICT_OVERRIDE: "0",
		DSH_VERSION: "",
		DSH_PNPM_BIN: "",
		DSH_SETUP_PREFIX: "",
		FAKE_PNPM_VERSION: "",
		...env,
	};
	for (const k of Object.keys(childEnv)) {
		if (childEnv[k] === "") delete childEnv[k];
	}
	const r = spawnSync(path.join(PREFIX_BIN, "bash"), [SETUP, ...args], {
		cwd: REPO,
		env: childEnv,
		timeout: 120000,
		encoding: "utf8",
	});
	return { rc: r.status ?? -1, out: `${r.stdout || ""}${r.stderr || ""}` };
}

/** 一个用例的公共骨架：准备 fake pnpm/fake prefix → 跑 → 断言。 */
function caseRun({ name, version = "11.27.1", withDsh = false, pnpmOwned = false, env = {}, args = [], pnpm = true, tools = true, dshOnPath = false }) {
	const root = mkTmp(name);
	const toolbin = tools ? makeToolbin(root) : null;
	const pnpmbin = pnpm ? makeFakePnpm(root, version) : null;
	const fakePrefix = makeFakePrefix(root, { withDsh, pnpmOwned });
	const special = path.join(root, "specialbin");
	fs.mkdirSync(special, { recursive: true });
	if (dshOnPath) {
		// 模拟 PATH 上更靠前的另一个 dsh（如 ~/bin/dsh）
		fs.writeFileSync(path.join(special, "dsh"), "#!/data/data/com.termux/files/usr/bin/sh\nexit 0\n");
		fs.chmodSync(path.join(special, "dsh"), 0o755);
	}
	const pathParts = [special];
	if (pnpmbin) pathParts.push(pnpmbin);
	if (toolbin) pathParts.push(toolbin);
	const before = snapshot(fakePrefix);
	const res = runSetup(
		{
			PATH: pathParts.join(path.delimiter),
			DSH_SETUP_PREFIX: fakePrefix,
			FAKE_PNPM_VERSION: version,
			DSH_PM: "pnpm",   // 本夹具大多测 pnpm 路径；测默认 npm 路径的用例在 env 里传 DSH_PM: ""
			...env,
		},
		args,
	);
	return { ...res, root, fakePrefix, before, after: snapshot(fakePrefix) };
}

function main() {
	if (!fs.existsSync(SETUP)) {
		console.error(`找不到 ${SETUP}`);
		process.exit(1);
	}
	console.log("== pnpm 安装方式 / 安装冲突预检 夹具 ==");

	// ---------------------------------------------------------------- a) pnpm 不可用
	{
		// PATH 上没有 pnpm，且显式给了不存在的 DSH_PNPM_BIN —— 两种失败都要在预检里被抓住。
		const r = caseRun({ name: "no-pnpm", pnpm: false, env: { DSH_PNPM_BIN: "/nonexistent/pnpm-not-here" } });
		check(r.rc === 1, "a1 找不到可运行的 pnpm → exit 1", `rc=${r.rc}`);
		check(r.out.includes("找不到可运行的 pnpm"), "a1 输出中文「找不到可运行的 pnpm」");
		check(r.out.includes("npm install -g pnpm@11"), "a1 给出安装 11.x 的具体方法");
		check(!r.out.includes("1/9"), "a1 在安装步骤之前就退出（无 1/9）");
	}
	{
		// 壳包装存在但内部入口不存在/不可解析 → 同样是「找不到可运行 pnpm」
		const root = mkTmp("broken-pnpm");
		const toolbin = makeToolbin(root);
		const bin = path.join(root, "brokenbin");
		fs.mkdirSync(bin);
		fs.writeFileSync(path.join(bin, "pnpm"), "#!/data/data/com.termux/files/usr/bin/sh\nexit 0\n");
		fs.chmodSync(path.join(bin, "pnpm"), 0o755);
		const fakePrefix = makeFakePrefix(root);
		const r = runSetup({ PATH: `${bin}${path.delimiter}${toolbin}`, DSH_SETUP_PREFIX: fakePrefix, DSH_PM: "pnpm" });
		check(r.rc === 1, "a2 不可执行的 pnpm 包装 → exit 1", `rc=${r.rc}`);
		check(r.out.includes("找不到可运行的 pnpm"), "a2 输出中文「找不到可运行的 pnpm」");
	}

	// ---------------------------------------------------------------- b) 版本线冲突
	{
		const r = caseRun({ name: "pnpm12", version: "12.11.2" });
		check(r.rc === 1, "b1 pnpm 12 → exit 1", `rc=${r.rc}`);
		check(r.out.includes("pnpm 12"), "b1 指明 pnpm 12 不可用");
		check(r.out.includes("ERR_PNPM_STORE_DIR_ACQUIRE_OPERATION_LOCK"), "b1 给出本机实测的 store 锁错误码");
		check(!r.out.includes("1/9"), "b1 在安装步骤之前就退出（无 1/9）");
	}
	{
		const r = caseRun({ name: "pnpm10", version: "10.30.0" });
		check(r.rc === 1, "b2 pnpm 10 → exit 1", `rc=${r.rc}`);
		check(r.out.includes("版本过旧"), "b2 指明版本过旧（缺 allowBuilds/strictDepBuilds 语义）");
	}
	{
		const r = caseRun({ name: "pnpm-badver", version: "not-a-version" });
		check(r.rc === 1, "b3 版本号不可解析 → exit 1", `rc=${r.rc}`);
		check(r.out.includes("无法解析 pnpm 版本"), "b3 输出中文「无法解析 pnpm 版本」");
	}

	// ---------------------------------------------------------------- c) 已存在安装（双包管理器冲突）
	{
		const r = caseRun({ name: "existing-npm-install", withDsh: true });
		check(r.rc === 1, "c1 已存在 dsh 安装 → exit 1", `rc=${r.rc}`);
		check(r.out.includes("已存在 dsh 安装"), "c1 输出中文「已存在 dsh 安装」");
		check(r.out.includes("npm uninstall -g @deepseek-ai/dsh"), "c1 给出清理 npm 安装的具体命令");
		check(!r.out.includes("1/9"), "c1 在安装步骤之前就退出（无 1/9）");
	}
	{
		// 归属标记存在（上次 pnpm 方式装的）→ 不算冲突
		const r = caseRun({ name: "pnpm-owned", withDsh: true, pnpmOwned: true });
		check(r.rc === 0, "c2 带 pnpm 归属标记的旧安装 → 预检通过（exit 0）", `rc=${r.rc}`);
		check(r.out.includes("上一次 pnpm 方式安装"), "c2 说明会原地重建");
	}
	{
		// 覆盖开关：只警告并继续（预检模式最终 exit 0）
		const r = caseRun({ name: "override", withDsh: true, env: { DSH_PM_CONFLICT_OVERRIDE: "1" } });
		check(r.rc === 0, "c3 DSH_PM_CONFLICT_OVERRIDE=1 覆盖共存冲突 → 预检通过", `rc=${r.rc}`);
		check(r.out.includes("DSH_PM_CONFLICT_OVERRIDE=1"), "c3 明确提示已按覆盖开关继续");
		check(r.out.includes("dsh.npm-backup"), "c3 说明旧目录会改名备份（不静默删除）");
	}

	// ---------------------------------------------------------------- d) PATH 上另一个 dsh
	{
		const r = caseRun({ name: "other-dsh-on-path", dshOnPath: true });
		check(r.rc === 1, "d1 PATH 上另一个 dsh → exit 1", `rc=${r.rc}`);
		check(r.out.includes("PATH 上已有另一个 dsh"), "d1 输出中文「PATH 上已有另一个 dsh」");
		check(!r.out.includes("1/9"), "d1 在安装步骤之前就退出（无 1/9）");
	}

	// ---------------------------------------------------------------- e) 无冲突 & 旗标
	{
		const r = caseRun({ name: "clean-pnpm" });
		check(r.rc === 0, "e1 无冲突的 pnpm 11.x → 预检通过（exit 0）", `rc=${r.rc}`);
		check(r.out.includes("版本线检查通过"), "e1 打印版本线检查通过");
		check(r.out.includes("仅预检模式"), "e1 只预检模式正常收尾");
		check(!r.out.includes("0/9"), "e1 预检在锚点预检之前（只读、极快）");
		check(r.out.includes("allowBuilds"), "e1 说明 allow-scripts 已映射到 allowBuilds");
	}
	{
		const r = caseRun({ name: "clean-pnpm-flag", args: ["--pnpm"], env: { DSH_PM: "" } });
		check(r.rc === 0, "e2 --pnpm 旗标等价于 DSH_PM=pnpm（预检通过）", `rc=${r.rc}`);
		check(r.out.includes("包管理器：pnpm"), "e2 确实是 pnpm 模式");
	}
	{
		const r = caseRun({ name: "verbose-flag", args: ["--verbose", "--pnpm"], env: { DSH_PM: "" } });
		check(r.rc === 0, "e3 --verbose 与 --pnpm 可同时使用", `rc=${r.rc}`);
	}

	// ---------------------------------------------------------------- f) 默认 npm 路径行为不变
	{
		// npm 默认模式：即使存在「会冲突」的 dsh 目录也不做新预检（完全维持旧行为）
		const r = caseRun({ name: "npm-default", withDsh: true, env: { DSH_PM: "" } });
		check(r.rc === 0, "f1 默认 npm 模式不做冲突预检（预检模式 exit 0）", `rc=${r.rc}`);
		check(!r.out.includes("包管理器：pnpm"), "f1 npm 模式不打印 pnpm 预检信息");
		check(r.out.includes("仅预检模式"), "f1 只预检模式正常收尾（测试钩子可用）");
	}
	{
		// 非法 DSH_PM 要被明确拒绝
		const r = caseRun({ name: "bad-pm", withDsh: true, env: { DSH_PM: "yarn" } });
		check(r.rc === 1, "f2 非法 DSH_PM → exit 1", `rc=${r.rc}`);
		check(r.out.includes("安装方式无效"), "f2 输出中文「安装方式无效」");
	}

	// ---------------------------------------------------------------- g) 坏 shebang 的壳包装
	{
		// fake pnpm 的 shebang 是坏的（#!/usr/bin/env sh），setup.sh 必须解析出 .mjs 用 node 执行
		const r = caseRun({ name: "bad-shebang" });
		check(r.rc === 0, "g1 坏 shebang 的 pnpm 壳包装仍可用（解析 .mjs 入口）", `rc=${r.rc}`);
		check(r.out.includes("版本线检查通过"), "g1 说明 pnpm 版本识别成功");
	}

	// ---------------------------------------------------------------- h) 预检只读
	{
		// 冲突用例前后：临时前缀内容必须一字节不变，且不产生安装目录
		const r = caseRun({ name: "readonly", withDsh: true });
		check(r.rc === 1, "h1 冲突用例确实退 1", `rc=${r.rc}`);
		check(r.before === r.after, "h1 冲突预检没有改动临时前缀（内容快照一致）");
		const notCreated = !fs.existsSync(path.join(r.fakePrefix, "lib", "node_modules", "@deepseek-ai", "dsh.npm-backup"));
		check(notCreated, "h1 冲突预检没有创建备份/安装目录（无副作用）");
	}
	{
		// 干净用例前后：临时前缀同样不变
		const r = caseRun({ name: "readonly-clean" });
		check(r.rc === 0, "h2 干净预检 exit 0", `rc=${r.rc}`);
		check(r.before === r.after, "h2 预检模式不写任何安装文件（内容快照一致）");
	}

	console.log("");
	console.log(`==== pnpm 夹具检查：PASS=${pass} FAIL=${fail} ====`);
	return fail === 0 ? 0 : 1;
}

let rc = 1;
try {
	rc = main();
} finally {
	for (const d of tmpRoots) {
		try {
			fs.rmSync(d, { recursive: true, force: true });
		} catch {
			/* 清理失败不影响结论 */
		}
	}
}
process.exit(rc);
