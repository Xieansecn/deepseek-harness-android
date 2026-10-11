#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-runtime-scripts-fixture.js
 *
 * `start_dsh.sh` / `stop_dsh.sh` / `restart_dsh_now.sh` 的**夹具自检**：
 * 把一个**假 dsh**（只认 `--port`，按需返回 303/401 并打印带 token 的日志行）放到 PATH 前面，
 * 并把 `HOME` 指向临时目录（于是 `~/dsh` 的日志/pid/副本全在夹具里），从而在**不碰 3080、
 * 不碰真实 ~/dsh** 的前提下验证三个脚本的执行行为与输出信息。
 *
 * 覆盖（每条都对应一个真实踩过的坑或契约）：
 *   1. `--port` 必须真的传给 dsh —— dsh 不读 DSH_PORT 环境变量，只认 `--port`；
 *      不传就会「脚本盯 DSH_PORT、服务却绑 3080」，打印/打开一个没人监听的 URL。
 *   2. 端口先回 401、token 后到（冷启动）时必须继续等，不能「端口一响应就降级裸 URL」。
 *   3. 一直拿不到 token（只有端口响应）→ 降级裸 URL 并打印**具体原因**（no-token）。
 *   4. 停止成功 → 退 0 + `[dsh] 已停止`。
 *   5. 进程停了但端口被别的进程占着 → 必须退 **1** 且信息走 stderr（旧实现退 0）。
 *   6. 重启后端口无响应（curl=000）→ 必须退 **1** 并点明原因（旧实现只看空串，恒不触发）。
 *
 * 用法：node patches/verify-runtime-scripts-fixture.js
 * 退出码：0 = 全部通过；1 = 有断言失败（逐条打印）。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const net = require("node:net");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const HERE = path.dirname(fs.realpathSync(__filename));
const REPO = path.dirname(HERE);
const SCRIPTS = { start: "start_dsh.sh", stop: "stop_dsh.sh", restart: "restart_dsh_now.sh" };
/** pgrep 模式：只匹配**本夹具临时目录**里的假 dsh（`node <home>/fake-dsh.js web --no-open --port N`）。
 *  ⚠️ 不能只写 `fake-dsh\.js web`：任何命令行里恰好带这串的无关进程（包括调用本夹具的 shell）都会被 pkill 误杀。 */
const PATTERN = "dsh-runtime-fixture-[A-Za-z0-9]+/fake-dsh\\.js web";

let pass = 0;
let fail = 0;
const cleanup = [];
/** 夹具自己起过的 pid。⚠️ 不用 `pkill -f <模式>`：任何命令行里恰好带该模式的无关进程（包括调用本夹具的 shell）都会被误杀。 */
const spawnedPids = new Set();
const createdHomes = [];
/** 收集自身与所有祖先进程 pid：按 cmdline 匹配清理时必须排除它们（调用方的命令行可能恰好提到夹具路径）。 */
function ancestorPids() {
	const out = new Set([process.pid]);
	let pid = process.pid;
	for (let i = 0; i < 10; i++) {
		let stat = "";
		try {
			stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
		} catch {
			break;
		}
		const close = stat.lastIndexOf(")");
		const ppid = Number((stat.slice(close + 2).split(" ")[1] || "0"));
		if (!ppid || ppid === 1 || out.has(ppid)) break;
		out.add(ppid);
		pid = ppid;
	}
	return out;
}

/** 列出 /proc 里所有 pid（Termux/Android 是 Linux，/proc 可用）。 */
function procPids() {
	try {
		return fs.readdirSync("/proc").filter((d) => /^\d+$/.test(d)).map(Number);
	} catch {
		return [];
	}
}

/** 只清「本夹具命名空间」的残留：cmdline 引用 `dsh-runtime-fixture-*` 且是假 dsh / 三个运行期脚本之一。
 *  被中断的上一次运行会留下这些进程，它们会匹配 DSH_WEB_PATTERN，让后续用例误判「已有进程在跑」。 */
function cleanupStale() {
	const skip = ancestorPids();
	let killed = 0;
	for (const pid of procPids()) {
		if (skip.has(pid)) continue;
		let cmd = "";
		try {
			cmd = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8");
		} catch {
			continue;
		}
		if (!cmd.includes("dsh-runtime-fixture-")) continue;
		if (!/fake-dsh\.js|\/dsh\/(start|stop|restart)_dsh|restart_dsh_now/.test(cmd)) continue;
		try {
			process.kill(pid, "SIGKILL");
			killed++;
		} catch {}
	}
	const tmp = os.tmpdir();
	let dirs = 0;
	try {
		for (const name of fs.readdirSync(tmp)) {
			if (!name.startsWith("dsh-runtime-fixture-")) continue;
			fs.rmSync(path.join(tmp, name), { recursive: true, force: true });
			dirs++;
		}
	} catch {}
	if (killed || dirs) console.log(`（启动前清理上一次中断的残留：进程 ${killed} 个、目录 ${dirs} 个）`);
}

/** 只杀「登记过、且 cmdline 确实引用夹具临时目录」的进程（防 pid 复用误杀）。 */
function killOwnProcesses() {
	for (const pid of spawnedPids) {
		let cmd = "";
		try {
			cmd = fs.readFileSync(`/proc/${pid}/cmdline`, "utf8");
		} catch {
			continue;
		}
		if (!createdHomes.some((h) => cmd.includes(h))) continue;
		try {
			process.kill(pid, "SIGKILL");
		} catch {}
	}
}
const check = (name, cond, detail = "") => {
	if (cond) {
		pass++;
		console.log(`  [OK]   ${name}`);
	} else {
		fail++;
		console.log(`  [FAIL] ${name}${detail ? ` —— ${detail}` : ""}`);
	}
};

/** 找一个空闲端口（绑一下再放掉）。 */
function freePort() {
	return new Promise((resolve) => {
		const srv = net.createServer();
		srv.listen(0, "127.0.0.1", () => {
			const { port } = srv.address();
			srv.close(() => resolve(port));
		});
	});
}

/** 假 dsh 源码：只认 `--port`（与真 dsh 一致），不读 DSH_PORT。 */
const FAKE_DSH = `#!/data/data/com.termux/files/usr/bin/node
"use strict";
const http = require("node:http");
const fs = require("node:fs");
const argv = process.argv.slice(2);
const portIdx = argv.indexOf("--port");
if (portIdx < 0 || !argv[portIdx + 1]) {
  console.error("[fake-dsh] 缺少 --port：真 dsh 不读 DSH_PORT，只认 --port");
  process.exit(2);
}
const port = Number(argv[portIdx + 1]);
if (process.env.FAKE_ARGV_FILE) fs.writeFileSync(process.env.FAKE_ARGV_FILE, argv.join(" "));
const mode = process.env.FAKE_MODE || "serve";
const noteErr = (tag, e) => {
  try { if (process.env.FAKE_STDERR_FILE) fs.appendFileSync(process.env.FAKE_STDERR_FILE, tag + ": " + (e && e.stack || e) + " | "); } catch {}
};
process.on("uncaughtException", (e) => { noteErr("uncaught", e); process.exit(3); });
process.on("unhandledRejection", (e) => { noteErr("unhandled", e); process.exit(4); });
const token = process.env.FAKE_TOKEN || "FAKETOKEN123";
const line = "dsh web: http://127.0.0.1:" + port + "/?token=" + token;
if (mode === "idle") { setTimeout(() => {}, 60000); return; }
const srv = http.createServer((req, res) => {
  if (req.url && req.url.includes("token=" + token)) {
    res.writeHead(303, { Location: "/", "Set-Cookie": "sid=1; HttpOnly; SameSite=Strict" });
    res.end();
    // 首个 token URL 命中后立刻停止监听：之后的 curl 会得到 000（模拟「start 成功后服务随即死掉」）
    if (mode === "die-after-token") srv.close();
    return;
  }
  res.writeHead(401); res.end("unauthorized");
});
srv.listen(port, "127.0.0.1", () => {
  if (mode === "no-token") return;                       // 只有端口响应，永不打印 token
  const delay = Number(process.env.FAKE_TOKEN_DELAY_MS || 0);
  if (delay > 0) setTimeout(() => console.log(line), delay);
  else console.log(line);
});
`;

/** 建一个隔离 HOME：<home>/dsh/{storage,三个脚本,bin/dsh,fake-dsh.js}。 */
function makeHome() {
	const home = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-runtime-fixture-"));
	const base = path.join(home, "dsh");
	fs.mkdirSync(path.join(base, "storage"), { recursive: true });
	for (const f of Object.values(SCRIPTS)) fs.copyFileSync(path.join(REPO, f), path.join(base, f));
	const bin = path.join(home, "bin");
	fs.mkdirSync(bin, { recursive: true });
	const fake = path.join(home, "fake-dsh.js");
	fs.writeFileSync(fake, FAKE_DSH);
	fs.chmodSync(fake, 0o755);
	const wrapper = path.join(bin, "dsh");
	fs.writeFileSync(wrapper, `#!/data/data/com.termux/files/usr/bin/bash\nexec node ${JSON.stringify(fake)} "$@"\n`);
	fs.chmodSync(wrapper, 0o755);
	cleanup.push(home);
	createdHomes.push(home);
	return { home, base, bin, fake, argvFile: path.join(home, "argv.txt") };
}

function run(h, script, args = [], { port, timeoutMs = 30000, extraEnv = {} } = {}) {
	const r = spawnSync("bash", [path.join(h.base, script), ...args], {
		encoding: "utf8",
		timeout: timeoutMs,
		env: {
			...process.env,
			HOME: h.home,
			PATH: `${h.bin}:${process.env.PATH}`,
			DSH_PORT: String(port),
			DSH_WEB_PATTERN: PATTERN,
			DSH_NO_OPEN: "1",
			DSH_READY_TIMEOUT: "6",
			FAKE_ARGV_FILE: h.argvFile,
			FAKE_STDERR_FILE: path.join(h.home, "fake-stderr.txt"),
			...extraEnv,
		},
	});
	const pidFile = path.join(h.base, "storage", "dsh.pid");
	if (fs.existsSync(pidFile)) {
		const pid = Number(fs.readFileSync(pidFile, "utf8").trim());
		if (Number.isInteger(pid) && pid > 0) spawnedPids.add(pid);
	}
	if (process.env.FIXTURE_DEBUG === "1") {
		const log = path.join(h.base, "storage", "dsh.log");
		const fakeErr = path.join(h.home, "fake-stderr.txt");
		console.log(`  --- [debug] ${script} rc=${r.status} argv=${fs.existsSync(h.argvFile) ? fs.readFileSync(h.argvFile, "utf8") : "(none)"}`);
		console.log(`  --- [debug] dsh.log: ${fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").slice(-6).join(" | ") : "(none)"}`);
		console.log(`  --- [debug] fake-stderr: ${fs.existsSync(fakeErr) ? fs.readFileSync(fakeErr, "utf8").trim() : "(none)"}`);
	}
	return r;
}

const alive = (pattern) => {
	const r = spawnSync("pgrep", ["-f", pattern], { encoding: "utf8" });
	return (r.stdout || "").trim().length > 0;
};

async function main() {
	cleanupStale();

	// ---- 场景 1：端口必须显式传给 dsh（否则 DSH_PORT 形同虚设）----
	{
		const port = await freePort();
		console.log(`\n用例 1：start_dsh.sh 必须把 DSH_PORT=${port} 作为 --port 传给 dsh`);
		const h = makeHome();
		const r = run(h, SCRIPTS.start, ["--no-open"], { port });
		const argv = fs.existsSync(h.argvFile) ? fs.readFileSync(h.argvFile, "utf8") : "";
		check("传给 dsh 的参数里有 --port", /--port\s+\d+/.test(argv), `argv=${JSON.stringify(argv)}`);
		check("--port 的值 = DSH_PORT", argv.includes(`--port ${port}`), `argv=${JSON.stringify(argv)}`);
		check("启动成功（退 0）", r.status === 0, `rc=${r.status} stderr=${(r.stderr || "").trim()}`);
		check("打印的 token URL 用的是该端口", (r.stdout || "").includes(`http://127.0.0.1:${port}/?token=`), (r.stdout || "").trim().split("\n").pop());
		run(h, SCRIPTS.stop, [], { port });
	}

	// ---- 场景 2：端口先 401、token 后到 → 必须等，不得降级 ----
	{
		const port = await freePort();
		console.log("\n用例 2：冷启动（端口先响应 401、token 1.5s 后才来）→ 必须等到 token，不降级裸 URL");
		const h = makeHome();
		const r = run(h, SCRIPTS.start, ["--no-open"], { port, extraEnv: { FAKE_MODE: "serve", FAKE_TOKEN_DELAY_MS: "1500" } });
		check("退 0", r.status === 0, `rc=${r.status}`);
		check("输出带 token URL", (r.stdout || "").includes("?token="), (r.stdout || "").trim().split("\n").pop());
		check("没有降级打开裸 URL", !(r.stdout || "").includes("降级打开裸 URL"), (r.stdout || "").trim());
		run(h, SCRIPTS.stop, [], { port });
	}

	// ---- 场景 3：一直没 token → 降级裸 URL 且说明具体原因 ----
	{
		const port = await freePort();
		console.log("\n用例 3：只有端口响应、永不打印 token → 降级裸 URL 并给出具体原因");
		const h = makeHome();
		const r = run(h, SCRIPTS.start, ["--no-open"], { port, timeoutMs: 40000, extraEnv: { FAKE_MODE: "no-token", DSH_READY_TIMEOUT: "3" } });
		check("退 0（按设计降级视为成功）", r.status === 0, `rc=${r.status}`);
		check("打印降级说明", (r.stdout || "").includes("降级打开裸 URL"), (r.stdout || "").trim().split("\n").pop());
		check("原因具体（no-token）", (r.stdout || "").includes("no-token"), (r.stdout || "").trim());
		run(h, SCRIPTS.stop, [], { port });
	}

	// ---- 场景 4：正常启停 → stop 退 0 且报「已停止」----
	{
		const port = await freePort();
		console.log("\n用例 4：正常启动后 stop → 退 0 + [dsh] 已停止");
		const h = makeHome();
		const rs = run(h, SCRIPTS.start, ["--no-open"], { port });
		check("启动退 0", rs.status === 0, `rc=${rs.status}`);
		check("pid 文件已写", fs.existsSync(path.join(h.base, "storage", "dsh.pid")));
		const r = run(h, SCRIPTS.stop, [], { port });
		check("stop 退 0", r.status === 0, `rc=${r.status} stderr=${(r.stderr || "").trim()}`);
		check("输出 [dsh] 已停止", (r.stdout || "").includes("已停止"), (r.stdout || "").trim());
		check("进程确实没了", !alive(PATTERN));
	}

	// ---- 场景 5：进程停了但端口被别的进程占着 → stop 必须退 1（stderr）----
	{
		const port = await freePort();
		console.log("\n用例 5：dsh 进程已停、端口被无关进程占着 → stop 退 1 且信息走 stderr");
		const h = makeHome();
		// 匹配模式的「假 dsh」进程（idle：不监听端口、不打印 token），让 stop 认为有目标可停
		const idle = spawn(process.execPath, [h.fake, "web", "--no-open", "--port", String(port)], {
			detached: true,
			stdio: "ignore",
			env: { ...process.env, FAKE_MODE: "idle", FAKE_ARGV_FILE: h.argvFile },
		});
		idle.unref();
		spawnedPids.add(idle.pid);
		fs.writeFileSync(path.join(h.base, "storage", "dsh.pid"), `${idle.pid}\n`);
		// 无关进程占住端口（cmdline 不匹配 PATTERN）
		const squatter = spawn(process.execPath, ["-e", `require("node:http").createServer((q,s)=>{s.writeHead(401);s.end()}).listen(${port},"127.0.0.1")`], { detached: true, stdio: "ignore" });
		squatter.unref();
		spawnedPids.add(squatter.pid);
		await new Promise((r2) => setTimeout(r2, 900));
		const r = run(h, SCRIPTS.stop, [], { port, extraEnv: { DSH_STOP_GRACE: "0.5", DSH_STOP_TIMEOUT: "1" } });
		check("stop 退 1", r.status === 1, `rc=${r.status}`);
		check("提示走 stderr", (r.stderr || "").includes("仍在"), JSON.stringify((r.stderr || "").trim()));
		try { process.kill(idle.pid, "SIGKILL"); } catch {}
		try { process.kill(squatter.pid, "SIGKILL"); } catch {}
	}

	// ---- 场景 6：重启成功 ----
	{
		const port = await freePort();
		console.log("\n用例 6：restart_dsh_now.sh（假 dsh 正常）→ 退 0 + 重启完成");
		const h = makeHome();
		const r = run(h, SCRIPTS.restart, [], { port, timeoutMs: 40000 });
		check("退 0", r.status === 0, `rc=${r.status} out=${(r.stdout || "").trim()}`);
		check("报「重启完成」", (r.stdout || "").includes("重启完成"), (r.stdout || "").trim().split("\n").pop());
		run(h, SCRIPTS.stop, [], { port });
	}

	// ---- 场景 7：重启后端口无响应（curl=000）→ 必须退 1 并点明原因 ----
	{
		const port = await freePort();
		console.log("\n用例 7：服务拿到 token 后立刻退出（重启后端口 curl=000）→ restart 退 1 且点明原因");
		const h = makeHome();
		const r = run(h, SCRIPTS.restart, [], { port, timeoutMs: 40000, extraEnv: { FAKE_MODE: "die-after-token" } });
		check("退 1", r.status === 1, `rc=${r.status} out=${(r.stdout || "").trim()}`);
		check("点明 curl=000", (r.stdout || "").includes("curl=000"), (r.stdout || "").trim().split("\n").pop());
	}

	if (pass < 21) {
		console.log(`  [FAIL] 断言数不足：PASS=${pass} < 21（有断言被删除或提前跳过）`);
		fail++;
	}
	console.log(`\n==== 夹具自检：PASS=${pass} FAIL=${fail} ====`);
	if (fail > 0) process.exitCode = 1;
}

main()
	.catch((error) => {
		console.error(`[ERROR   ] ${error.message}`);
		fail++;
		process.exitCode = 1;
	})
	.finally(() => {
		// 收尾：只杀夹具自己登记过的进程，再删除临时 HOME（异常路径也执行）。
		killOwnProcesses();
		for (const dir of cleanup) if (dir) fs.rmSync(dir, { recursive: true, force: true });
	});
