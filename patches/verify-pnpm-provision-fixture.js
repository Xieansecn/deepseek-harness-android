#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-pnpm-provision-fixture.js
 *
 * `setup.sh` 的 **pnpm 运行时供给 + 冲突预检** 夹具自检（离线、假 PATH、临时 HOME/PIN/WRAPPER：
 * 不联网、不装包、不碰真实 ~/.local/share/pnpm-pin、~/bin、安装树、~/.dsh、3080）。
 *
 * 背景：dsh ≥0.2.1 的插件市场 / `dsh plugin …` 会 execa("pnpm")，pnpm 11.x 是事实上的**运行期依赖**；
 * setup.sh 的 2.5/9 会「npm --prefix 装 pnpm@11 的 JS build + ~/bin 包装（node 跑 bin/pnpm.mjs）」，
 * 并在任何安装动作之前做只读冲突预检。本夹具只用假 npm / 假 pnpm 覆盖这些分支：
 *
 *   a) PATH 上的 pnpm 主版本 >=12 / <11 / --version 不可用 → exit 1（版本类，不可覆盖）；
 *   b) 包装目录里已有「用户自己的、非本仓库生成」的包装 → exit 1（可 DSH_PNPM_CONFLICT_OVERRIDE=1，写前备份）；
 *      内容等价于本仓库布局的**手工 pin 包装**（本机现状）→ 认领不覆盖；
 *   c) 需要供给但包装目录不在 PATH → exit 1 并给出 export PATH 命令；
 *   d) npm strict-allow-scripts=true → exit 1（会把 SKIP_SCRIPTS 里的 koffi 变硬错误 ESTRICTALLOWSCRIPTS）；
 *   e) 被 ~/bin 遮蔽的 npm 全局 pnpm@12 → 只 warn 不阻断；
 *   f) 缺失时供给：写 pin 目录（假 npm 造）+ 4 个包装（marker / Termux shebang / exec node <mjs> / 755），
 *      验证 `pnpm --version`=11.x 且 PATH 解析到包装；第二次跑幂等（不再调用 npm install）；
 *   g) 本仓库包装损坏 → 修复；用户包装 + 覆盖开关 → 备份后重写；
 *   h) 默认 npm 路径没有新增 pnpm「安装方式」预检（核心行为不变）；冲突预检无副作用（快照一致）。
 *
 * 用法：node patches/verify-pnpm-provision-fixture.js
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
const BASH = path.join(PREFIX_BIN, "bash");
const NODE_BIN = process.execPath;
const TERMUX_SHEBANG = "#!/data/data/com.termux/files/usr/bin/sh";

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

function mkTmp(tag) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), `dsh-pnpm-prov-${tag}-`));
	tmpRoots.push(dir);
	return dir;
}

/** setup.sh 预检路径会用到的基础命令软链目录（不含 npm/pnpm/dsh，避免依赖生产状态）。 */
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
			/* 缺工具会在用例输出里以 command not found 暴露 */
		}
	}
	return dir;
}

/** 假 npm（shell 脚本，Termux 绝对 shebang 可被 setup.sh 直接 exec）：
 *  - `config get strict-allow-scripts` → $FAKE_NPM_STRICT（默认 false）
 *  - `root -g` → $FAKE_NPM_ROOT
 *  - `install --prefix <dir> ... pnpm@<ver>` → 在 <dir> 造一个假 pnpm 包树（bin/pnpm.mjs 打印版本）
 *  - 所有调用追加到 $FAKE_NPM_LOG（用于幂等断言）
 */
function makeFakeNpm(root) {
	const dir = path.join(root, "npmbin");
	fs.mkdirSync(dir, { recursive: true });
	const npm = path.join(dir, "npm");
	fs.writeFileSync(
		npm,
		[
			TERMUX_SHEBANG,
			'if [ -n "${FAKE_NPM_LOG:-}" ]; then printf \'%s\\n\' "$*" >> "$FAKE_NPM_LOG"; fi',
			'case "${1:-}" in',
			'  config)',
			'    if [ "${2:-}" = get ] && [ "${3:-}" = strict-allow-scripts ]; then printf \'%s\\n\' "${FAKE_NPM_STRICT:-false}"; fi',
			'    exit 0 ;;',
			'  root)',
			'    printf \'%s\\n\' "${FAKE_NPM_ROOT:-/nonexistent-npm-root}"',
			'    exit 0 ;;',
			'  install)',
			'    shift',
			'    prefix=""; ver="11.27.1"',
			'    while [ $# -gt 0 ]; do',
			'      case "$1" in',
			'        --prefix) prefix="${2:-}"; shift 2 ;;',
			'        pnpm@*) ver="${1#pnpm@}"; shift ;;',
			'        *) shift ;;',
			'      esac',
			'    done',
			'    [ -n "$prefix" ] || exit 1',
			'    mkdir -p "$prefix/node_modules/pnpm/bin"',
			'    printf \'{"name":"pnpm","version":"%s"}\\n\' "$ver" > "$prefix/node_modules/pnpm/package.json"',
			'    for f in pnpm pnpx; do',
			'      cat > "$prefix/node_modules/pnpm/bin/$f.mjs" <<EOF',
			'if (process.argv[2] === "--version") { console.log("$ver"); process.exit(0); }',
			'process.exit(0);',
			'EOF',
			'    done',
			'    exit 0 ;;',
			'esac',
			'exit 0',
			"",
		].join("\n"),
	);
	fs.chmodSync(npm, 0o755);
	return dir;
}

/** 造一个「PATH 上的 pnpm」：壳包装 exec node <mjs>（故意用坏 shebang，证明 setup.sh 解析 mjs 入口）。 */
function makePnpmOnPath(root, version, opts = {}) {
	const dir = path.join(root, "pathpnpm");
	fs.mkdirSync(dir, { recursive: true });
	const mjs = path.join(dir, "fake-pnpm.mjs");
	fs.writeFileSync(
		mjs,
		[`if (process.argv[2] === "--version") { console.log("${version}"); process.exit(0); }`, "process.exit(0);", ""].join("\n"),
	);
	const wrapper = path.join(dir, "pnpm");
	fs.writeFileSync(wrapper, `#!/usr/bin/env sh\nexec ${NODE_BIN} ${mjs} "$@"\n`);
	fs.chmodSync(wrapper, opts.nonExecutable ? 0o644 : 0o755);
	// 坏 pnpm：--version 不输出任何东西
	if (opts.silent) fs.writeFileSync(mjs, "process.exit(0);\n");
	return dir;
}

/** 在 PIN_DIR 里造一个假 pnpm 包树（版本由 package.json 决定；bin/*.mjs 打印版本）。 */
function makeFakePin(pinDir, version) {
	const pkg = path.join(pinDir, "node_modules", "pnpm");
	fs.mkdirSync(path.join(pkg, "bin"), { recursive: true });
	fs.writeFileSync(path.join(pkg, "package.json"), JSON.stringify({ name: "pnpm", version }));
	const body = `if (process.argv[2] === "--version") { console.log("${version}"); process.exit(0); }\nprocess.exit(0);\n`;
	fs.writeFileSync(path.join(pkg, "bin", "pnpm.mjs"), body);
	fs.writeFileSync(path.join(pkg, "bin", "pnpx.mjs"), body);
	return pinDir;
}

/** 造一个「已有的 pnpm 包装」：等价 = 指向 PIN_DIR 里正确的 mjs；非等价 = 指向别处。
 *  marker=true 时写入本仓库 marker（模拟本仓库生成物）。 */
function makeWrapper(wrapDir, name, targetMjs, opts = {}) {
	fs.mkdirSync(wrapDir, { recursive: true });
	const file = path.join(wrapDir, name);
	const lines = [TERMUX_SHEBANG];
	if (opts.marker) lines.push(`# dsh-android-pnpm-runtime-wrapper（setup.sh 2.5/9 生成，勿手改）`);
	else lines.push(`# 用户自己手工写的 pnpm 包装（无本仓库 marker）`);
	lines.push(`exec ${NODE_BIN} ${targetMjs} "$@"`);
	fs.writeFileSync(file, lines.join("\n") + "\n");
	fs.chmodSync(file, 0o755);
	return file;
}

function snapshot(dir) {
	if (!fs.existsSync(dir)) return "<missing>";
	const out = [];
	const walk = (d) => {
		let ents = [];
		try {
			ents = fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
		} catch {
			return;
		}
		for (const e of ents) {
			const p = path.join(d, e.name);
			const rel = path.relative(dir, p);
			if (e.isDirectory()) {
				out.push(`${rel}|dir`);
				walk(p);
			} else if (e.isSymbolicLink()) out.push(`${rel}|link:${fs.readlinkSync(p)}`);
			else {
				let buf = "";
				try {
					buf = fs.readFileSync(p, "utf8");
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

/** 跑一次 setup.sh（隔离模式）。
 * 所有用例都带 DSH_SETUP_PREFLIGHT_ONLY 或 DSH_SETUP_PROVISION_ONLY —— 即使被测逻辑有 bug 也绝不会进入安装步骤。 */
function runSetup(root, opts = {}) {
	const home = path.join(root, "home");
	fs.mkdirSync(path.join(home, "dsh"), { recursive: true });
	const wrapDir = opts.wrapDir || path.join(root, "wbin");
	const pinDir = opts.pinDir || path.join(root, "pin");
	const pathDirs = [...(opts.pathDirs || [])];
	const childEnv = {
		...process.env,
		HOME: home,
		NO_COLOR: "1",
		SETUP_VERBOSE: "0",
		PATH: pathDirs.join(path.delimiter),
		DSH_PM: "",
		DSH_SETUP_PREFIX: path.join(root, "prefix"),
		DSH_SETUP_PREFLIGHT_ONLY: "0",
		DSH_SETUP_PROVISION_ONLY: "0",
		DSH_PNPM_CONFLICT_OVERRIDE: "0",
		DSH_PNPM_PIN_DIR: pinDir,
		DSH_PNPM_WRAPPER_DIR: wrapDir,
		DSH_PNPM_VERSION: "11.27.1",
		...opts.env,
	};
	for (const k of Object.keys(childEnv)) {
		if (childEnv[k] === "") delete childEnv[k];
	}
	const r = spawnSync(BASH, [SETUP, ...(opts.args || [])], {
		cwd: REPO,
		env: childEnv,
		timeout: 120000,
		encoding: "utf8",
	});
	return { rc: r.status ?? -1, out: `${r.stdout || ""}${r.stderr || ""}`, env: childEnv };
}

function main() {
	if (!fs.existsSync(SETUP)) {
		console.error(`找不到 ${SETUP}`);
		process.exit(1);
	}
	console.log("== pnpm 运行时供给 / 冲突预检 夹具 ==");

	// ---------------------------------------------------------- a) 版本类冲突
	{
		const root = mkTmp("v12");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "12.11.2");
		const r = runSetup(root, { pathDirs: [pnpmbin, npmbin, toolbin], env: { DSH_SETUP_PREFLIGHT_ONLY: "1" } });
		check(r.rc === 1, "a1 PATH 上 pnpm 12 → exit 1", `rc=${r.rc}`);
		check(r.out.includes("pnpm 12"), "a1 指明 pnpm 12 不可用");
		check(r.out.includes("ERR_PNPM_STORE_DIR_ACQUIRE_OPERATION_LOCK"), "a1 给出本机实测的 store 锁错误");
		check(r.out.includes("不可用 DSH_PNPM_CONFLICT_OVERRIDE 覆盖"), "a1 说明版本类冲突不可覆盖");
		check(!r.out.includes("1/9"), "a1 在安装步骤之前退出（无 1/9）");
	}
	{
		const root = mkTmp("v10");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "10.30.0");
		const r = runSetup(root, { pathDirs: [pnpmbin, npmbin, toolbin], env: { DSH_SETUP_PREFLIGHT_ONLY: "1" } });
		check(r.rc === 1, "a2 PATH 上 pnpm 10 → exit 1", `rc=${r.rc}`);
		check(r.out.includes("版本过旧"), "a2 指明版本过旧（缺 allowBuilds/strictDepBuilds 语义）");
	}
	{
		const root = mkTmp("broken");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "11.27.1", { silent: true }); // --version 无输出
		const r = runSetup(root, { pathDirs: [pnpmbin, npmbin, toolbin], env: { DSH_SETUP_PREFLIGHT_ONLY: "1" } });
		check(r.rc === 1, "a3 PATH 上 pnpm --version 不可用 → exit 1", `rc=${r.rc}`);
		check(r.out.includes("不可用"), "a3 指明 pnpm 不可用");
	}

	// ---------------------------------------------------------- b) 包装冲突 / 认领
	{
		// 用户自己的包装：可运行但不是本仓库生成（指向 wrapDir 里另一份 mjs），且内容不等价 → 冲突
		const root = mkTmp("user-wrapper");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const wrapDir = path.join(root, "wbin");
		const userMjs = path.join(root, "user-pnpm.mjs");
		fs.writeFileSync(userMjs, `if (process.argv[2] === "--version") { console.log("11.27.1"); process.exit(0); }\nprocess.exit(0);\n`);
		const file = makeWrapper(wrapDir, "pnpm", userMjs, { marker: false });
		const before = fs.readFileSync(file, "utf8");
		const r = runSetup(root, {
			pathDirs: [wrapDir, npmbin, toolbin],
			wrapDir,
			env: { DSH_SETUP_PREFLIGHT_ONLY: "1" },
		});
		check(r.rc === 1, "b1 用户自己的 pnpm 包装（非本仓库）→ exit 1", `rc=${r.rc}`);
		check(r.out.includes("不是本仓库生成的 pnpm 包装"), "b1 指明包装归属不是本仓库");
		check(fs.readFileSync(file, "utf8") === before, "b1 不会覆盖用户包装（内容不变）");
	}
	{
		// 等价的手工 pin 包装（无 marker）：认领、不覆盖、不报冲突
		const root = mkTmp("adopt");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const wrapDir = path.join(root, "wbin");
		const pinDir = makeFakePin(path.join(root, "pin"), "11.27.1");
		const file = makeWrapper(wrapDir, "pnpm", path.join(pinDir, "node_modules/pnpm/bin/pnpm.mjs"), { marker: false });
		const before = fs.readFileSync(file, "utf8");
		const r = runSetup(root, {
			pathDirs: [wrapDir, npmbin, toolbin],
			wrapDir,
			pinDir,
			env: { DSH_SETUP_PROVISION_ONLY: "1" },
		});
		check(r.rc === 0, "b2 等价的 ~/bin 手工 pin 包装 → 认领（exit 0）", `rc=${r.rc}`);
		check(r.out.includes("pnpm 运行时可用"), "b2 报运行时可用");
		check(fs.readFileSync(file, "utf8") === before, "b2 认领但不改写用户已有包装（内容不变）");
	}
	{
		// 需要供给，但包装目录不在 PATH → 冲突并给 export PATH
		const root = mkTmp("no-path");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const wrapDir = path.join(root, "wbin");
		const r = runSetup(root, {
			pathDirs: [npmbin, toolbin], // 不含 wrapDir
			wrapDir,
			env: { DSH_SETUP_PREFLIGHT_ONLY: "1" },
		});
		check(r.rc === 1, "b3 包装目录不在 PATH → exit 1", `rc=${r.rc}`);
		check(r.out.includes("不在 PATH 上"), "b3 指明包装目录不在 PATH");
		check(r.out.includes("export PATH"), "b3 给出 export PATH=\"$HOME/bin:$PATH\" 的处置");
	}

	// ---------------------------------------------------------- c) npm strict-allow-scripts
	{
		const root = mkTmp("strict");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "11.27.1");
		const r = runSetup(root, {
			pathDirs: [pnpmbin, npmbin, toolbin],
			env: { DSH_SETUP_PREFLIGHT_ONLY: "1", FAKE_NPM_STRICT: "true", FAKE_NPM_ROOT: path.join(root, "no-root") },
		});
		check(r.rc === 1, "c1 npm strict-allow-scripts=true → exit 1", `rc=${r.rc}`);
		check(r.out.includes("strict-allow-scripts=true"), "c1 指明 npm 配置项");
		check(r.out.includes("ESTRICTALLOWSCRIPTS"), "c1 给出会触发的错误码");
		check(r.out.includes("npm config set strict-allow-scripts false"), "c1 给出具体处置命令");
	}
	{
		const root = mkTmp("advisory");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "11.27.1");
		const r = runSetup(root, {
			pathDirs: [pnpmbin, npmbin, toolbin],
			env: { DSH_SETUP_PREFLIGHT_ONLY: "1", FAKE_NPM_STRICT: "false", FAKE_NPM_ROOT: path.join(root, "no-root") },
		});
		check(r.rc === 0, "c2 npm advisory（默认）→ 预检通过", `rc=${r.rc}`);
		check(r.out.includes("pnpm 运行时：可用"), "c2 报 pnpm 运行时可用");
	}

	// ---------------------------------------------------------- d) 被遮蔽的 npm 全局 pnpm 12：只 warn
	{
		const root = mkTmp("shadow");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "11.27.1");
		const npmRoot = path.join(root, "npm-global");
		fs.mkdirSync(path.join(npmRoot, "pnpm"), { recursive: true });
		fs.writeFileSync(path.join(npmRoot, "pnpm/package.json"), JSON.stringify({ name: "pnpm", version: "12.11.2" }));
		const r = runSetup(root, {
			pathDirs: [pnpmbin, npmbin, toolbin],
			env: { DSH_SETUP_PREFLIGHT_ONLY: "1", FAKE_NPM_STRICT: "false", FAKE_NPM_ROOT: npmRoot },
		});
		check(r.rc === 0, "d1 被遮蔽的 npm 全局 pnpm@12 → 只 warn 不阻断（exit 0）", `rc=${r.rc}`);
		check(r.out.includes("12.11.2") && r.out.includes("遮蔽"), "d1 明确提示 pnpm 12 已被遮蔽");
	}

	// ---------------------------------------------------------- e) 缺失时供给 + 幂等 + 验证
	{
		const root = mkTmp("provision");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const wrapDir = path.join(root, "wbin");
		const pinDir = path.join(root, "pin");
		const npmLog = path.join(root, "npm-calls.log");
		fs.writeFileSync(npmLog, "");
		const env = {
			DSH_SETUP_PROVISION_ONLY: "1",
			FAKE_NPM_STRICT: "false",
			FAKE_NPM_ROOT: path.join(root, "no-root"),
			FAKE_NPM_LOG: npmLog,
		};
		const r = runSetup(root, { pathDirs: [wrapDir, npmbin, toolbin], wrapDir, pinDir, env });
		check(r.rc === 0, "e1 缺失 pnpm → 自动供给成功（exit 0）", `rc=${r.rc}`);
		check(r.out.includes("2.5/9"), "e1 走的是 2.5/9 步骤");
		check(r.out.includes("pnpm 运行时就绪"), "e1 报运行时就绪");
		const calls = fs.readFileSync(npmLog, "utf8").split("\n").filter((l) => l.startsWith("install"));
		check(calls.length === 1 && calls[0].includes("pnpm@11.27.1"), "e1 用 npm --prefix 安装 pnpm@11.27.1（一次）", `calls=${calls.length}`);
		let pinVer = "";
		try {
			pinVer = JSON.parse(fs.readFileSync(path.join(pinDir, "node_modules/pnpm/package.json"), "utf8")).version;
		} catch {
			pinVer = "";
		}
		check(pinVer === "11.27.1", "e1 pin 目录里是 pnpm 11.27.1", `ver=${pinVer}`);
		let wrappersOk = true;
		const detail = [];
		for (const name of ["pnpm", "pn", "pnpx", "pnx"]) {
			const f = path.join(wrapDir, name);
			if (!fs.existsSync(f)) {
				wrappersOk = false;
				detail.push(`${name}:missing`);
				continue;
			}
			const body = fs.readFileSync(f, "utf8");
			const rel = name.startsWith("pnpx") || name === "pnx" ? "bin/pnpx.mjs" : "bin/pnpm.mjs";
			const good =
				body.startsWith(TERMUX_SHEBANG) &&
				body.includes("dsh-android-pnpm-runtime-wrapper") &&
				body.includes("exec ") &&
				body.includes(`${pinDir}/node_modules/pnpm/${rel}`) &&
				(fs.statSync(f).mode & 0o111) !== 0;
			if (!good) {
				wrappersOk = false;
				detail.push(`${name}:bad`);
			}
		}
		check(wrappersOk, "e1 写出 4 个包装（marker / Termux shebang / exec node <mjs> / 可执行）", detail.join(","));
		const vr = spawnSync(path.join(wrapDir, "pnpm"), ["--version"], { encoding: "utf8", timeout: 30000 });
		check((vr.stdout || "").trim() === "11.27.1", "e1 包装 pnpm --version = 11.27.1", (vr.stdout || "").trim());
		const which = spawnSync(BASH, ["-c", 'command -v pnpm'], {
			encoding: "utf8",
			timeout: 30000,
			env: { ...process.env, PATH: [wrapDir, npmbin, toolbin].join(path.delimiter) },
		});
		check((which.stdout || "").trim() === path.join(wrapDir, "pnpm"), "e1 PATH 解析到我们写的包装", (which.stdout || "").trim());
		// 幂等：第二次跑不应再调用 npm install，包装内容不变
		const wrapBefore = snapshot(wrapDir);
		const pinBefore = snapshot(pinDir);
		const r2 = runSetup(root, { pathDirs: [wrapDir, npmbin, toolbin], wrapDir, pinDir, env });
		check(r2.rc === 0, "e2 第二次跑幂等（exit 0）", `rc=${r2.rc}`);
		check(r2.out.includes("pnpm 运行时可用"), "e2 直接报可用，不再安装");
		const calls2 = fs.readFileSync(npmLog, "utf8").split("\n").filter((l) => l.startsWith("install"));
		check(calls2.length === 1, "e2 幂等：没有第二次 npm install", `calls=${calls2.length}`);
		check(snapshot(wrapDir) === wrapBefore && snapshot(pinDir) === pinBefore, "e2 幂等：包装与 pin 目录内容不变");
	}

	// ---------------------------------------------------------- f) 本仓库包装损坏 → 修复
	{
		const root = mkTmp("repair");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const wrapDir = path.join(root, "wbin");
		const pinDir = path.join(root, "pin"); // 空 pin：包装 exec 的 mjs 不存在 → --version 失败
		const missingMjs = path.join(pinDir, "node_modules/pnpm/bin/pnpm.mjs");
		makeWrapper(wrapDir, "pnpm", missingMjs, { marker: true });
		const r = runSetup(root, {
			pathDirs: [wrapDir, npmbin, toolbin],
			wrapDir,
			pinDir,
			env: { DSH_SETUP_PROVISION_ONLY: "1", FAKE_NPM_STRICT: "false", FAKE_NPM_ROOT: path.join(root, "no-root") },
		});
		check(r.rc === 0, "f1 本仓库包装损坏 → 2.5/9 自动修复（exit 0）", `rc=${r.rc}`);
		check(r.out.includes("将重装修复") || r.out.includes("运行时就绪"), "f1 预检识别损坏并修复");
		const f = path.join(wrapDir, "pnpm");
		check(fs.existsSync(f) && fs.readFileSync(f, "utf8").includes(`${pinDir}/node_modules/pnpm/bin/pnpm.mjs`), "f1 包装已重写指向新 pin 目录");
	}

	// ---------------------------------------------------------- g) 用户包装 + 覆盖开关 → 备份后重写
	{
		const root = mkTmp("override");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const wrapDir = path.join(root, "wbin");
		const pinDir = path.join(root, "pin");
		const userMjs = path.join(root, "user-pnpm.mjs");
		fs.writeFileSync(userMjs, "process.exit(0);\n");
		const file = makeWrapper(wrapDir, "pnpm", userMjs, { marker: false });
		const r = runSetup(root, {
			pathDirs: [wrapDir, npmbin, toolbin],
			wrapDir,
			pinDir,
			env: {
				DSH_SETUP_PROVISION_ONLY: "1",
				DSH_PNPM_CONFLICT_OVERRIDE: "1",
				FAKE_NPM_STRICT: "false",
				FAKE_NPM_ROOT: path.join(root, "no-root"),
			},
		});
		check(r.rc === 0, "g1 用户包装 + DSH_PNPM_CONFLICT_OVERRIDE=1 → 继续并供给（exit 0）", `rc=${r.rc}`);
		check(fs.existsSync(`${file}.dsh-android.bak`), "g1 旧用户包装已备份为 .dsh-android.bak");
		check(fs.readFileSync(file, "utf8").includes("dsh-android-pnpm-runtime-wrapper"), "g1 新包装带本仓库 marker");
	}

	// ---------------------------------------------------------- h) 默认 npm 路径 / 无副作用
	{
		// 默认 npm 方式：不应出现 pnpm「安装方式」预检（那是 --pnpm 专属）；运行时预检只报可用
		const root = mkTmp("npm-default");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "11.27.1");
		const npmLog = path.join(root, "npm-calls.log");
		fs.writeFileSync(npmLog, "");
		const r = runSetup(root, {
			pathDirs: [pnpmbin, npmbin, toolbin],
			env: {
				DSH_SETUP_PREFLIGHT_ONLY: "1",
				FAKE_NPM_STRICT: "false",
				FAKE_NPM_ROOT: path.join(root, "no-root"),
				FAKE_NPM_LOG: npmLog,
			},
		});
		check(r.rc === 0, "h1 默认 npm 方式预检通过（exit 0）", `rc=${r.rc}`);
		check(!r.out.includes("包管理器：pnpm"), "h1 默认 npm 方式没有 pnpm 安装方式预检");
		check(r.out.includes("仅预检模式"), "h1 只预检模式正常收尾");
		check(fs.readFileSync(npmLog, "utf8").trim() === "" || !fs.readFileSync(npmLog, "utf8").includes("install"), "h1 预检不触发任何 npm install");
	}
	{
		// 冲突预检无副作用：版本冲突用例前后，包装目录与 pin 目录都不应被创建
		const root = mkTmp("readonly");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "12.0.0");
		const wrapDir = path.join(root, "wbin");
		const pinDir = path.join(root, "pin");
		const before = snapshot(wrapDir) + snapshot(pinDir);
		const r = runSetup(root, { pathDirs: [pnpmbin, npmbin, toolbin], wrapDir, pinDir, env: { DSH_SETUP_PREFLIGHT_ONLY: "1" } });
		check(r.rc === 1, "h2 版本冲突用例确实退 1", `rc=${r.rc}`);
		check(snapshot(wrapDir) + snapshot(pinDir) === before, "h2 冲突预检无副作用（包装/pin 目录未被创建或改动）");
	}
	{
		// pnpm 安装方式（--pnpm）下运行时预检同样生效，但「安装方式」预检仍是它自己的输出
		const root = mkTmp("pnpm-mode");
		const toolbin = makeToolbin(root);
		const npmbin = makeFakeNpm(root);
		const pnpmbin = makePnpmOnPath(root, "11.27.1");
		const r = runSetup(root, {
			pathDirs: [pnpmbin, npmbin, toolbin],
			env: {
				DSH_PM: "pnpm",
				DSH_SETUP_PREFLIGHT_ONLY: "1",
				FAKE_NPM_STRICT: "false",
				FAKE_NPM_ROOT: path.join(root, "no-root"),
			},
		});
		check(r.rc === 0, "h3 --pnpm 方式预检通过（空前缀 + pnpm 11）", `rc=${r.rc}`);
		check(r.out.includes("安装前冲突预检"), "h3 同时跑了 pnpm 安装方式预检");
		check(r.out.includes("pnpm 运行时：可用"), "h3 与运行时预检复用同一套解析逻辑");
	}

	console.log("");
	console.log(`==== pnpm 运行时供给夹具：PASS=${pass} FAIL=${fail} ====`);
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
