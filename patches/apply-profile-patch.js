#!/data/data/com.termux/files/usr/bin/node
/**
 * apply-profile-patch.js
 *
 * 把权限层（config/cordis.patch.yml：sandbox-policy = danger-full-access）装进
 * profile 的用户补丁层 ~/.dsh/profiles/web/cordis.patch.yml。
 *
 * 为什么不能只管追加
 * ------------------
 * dsh 自己会在 profile 首次初始化时写入 PROFILE_PATCH_TEMPLATE —— 3 行注释 +
 * 一个空数组文档 `[]`（dsh-app-boot 的 initProfile()；任何一次 dsh 启动，
 * 包括跑失败的那次，都会建出这个文件）。旧版 setup.sh 只 grep
 * "danger-full-access" 就 `>>` 追加，于是在一个【已经结束】的 YAML 文档后面再
 * 挂一条序列项：
 *
 *   # Your patch layer for this dsh profile, ...      <- dsh 模板注释
 *   []
 *   # DeepSeek Harness profile 配置覆盖层（Android/Termux）
 *   - id: sandbox-policy                              <- 解析到这里就炸
 *
 * dsh 报 "YAMLException: end of the stream or a document separator is expected
 * (13:1)"，profile 装载在 boot 之前失败 —— 服务完全起不来，而且从报错里看不出
 * 是「我们自己写的层」出了问题。
 *
 * 本脚本的处理
 * ------------
 * 先按内容分类，再落盘；落盘前后都用 dsh 自己的 loadOverlayPatches() 真解析
 * （`!!js` 标签只有它的 schema 认，普通 yaml.load 会误判）：
 *
 *   目标不存在        -> 写入权限层                                  [CREATED]
 *   空数组模板        -> 整体替换（模板没有可保留的信息）             [REPLACED]
 *   首行残留裸 `[]`   -> 摘掉那个空文档行后继续（本次崩溃的现场修复） [REPAIRED]
 *   真实配置层        -> 追加权限层（保留用户其它层）                 [APPENDED]
 *   已有该权限层      -> 不动（幂等）                                 [OK]
 *
 * 写入前先落到同目录临时文件并校验，校验不过就一个字节都不动原文件、退 1。
 * 写成功后删备份；回滚失败则保留备份并提示人工处理。补丁层坏掉 = dsh 起不来，
 * 属硬阻断，所以这里只报真话，不会「warning 一下假装成功」。
 *
 * 用法：
 *   node patches/apply-profile-patch.js [--target <file>] [--layer <file>] [--root <dsh 安装根>]
 * 退出码：0 = 已就位/已修好；1 = 定位失败、无法修复或校验失败（原文件保持原样）。
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

/** 找不到 config/cordis.patch.yml 时的兜底权限层（与它等价，只是没有注释头）。 */
const FALLBACK_LAYER = "- id: sandbox-policy\n  config:\n    mode: danger-full-access\n";
/** 判定「权限层已就位」的特征串（与旧 setup.sh 的 grep 一致，宁可少写一次）。 */
const LAYER_MARKER = "danger-full-access";
const BACKUP_SUFFIX = ".dsh-android.bak";
/**
 * 层文件里每个条目前的哨兵行：既让人一眼看出「这块是本仓库加的」，也让脚本能把层
 * 切成按条目粒度的块（已有的条目不再重复追加——升级时补的往往只是新增的那一条）。
 */
const ENTRY_SENTINEL = "# >>> dsh-android-layer-entry";
const APP_BOOT_REL = path.join("node_modules", "@deepseek-ai", "dsh-app-boot", "lib", "index.js");

function log(tag, message) {
	console.log(`[${tag.padEnd(8)}] ${message}`);
}

/**
 * 定位 dsh 安装根（只借它自己的解析器做校验，不写它）。
 * `--root` 是硬契约：显式给出却定位不到就报错，不静默回落到别的候选。
 */
function resolveDshRoot(optRoot) {
	const hasAppBoot = (root) => Boolean(root) && fs.existsSync(path.join(root, APP_BOOT_REL));
	// `--root` 是硬契约：显式给出就只用它，定位不到即失败，不静默回落到别的候选
	// （旧行为会让「夹具测试不碰生产树」变成假话）。
	if (optRoot) return hasAppBoot(optRoot) ? optRoot : null;
	const candidates = [];
	try {
		candidates.push(path.dirname(require.resolve("@deepseek-ai/dsh/package.json")));
	} catch {}
	// 不走 `npm root -g`：Termux 上 /usr/bin 不可解析，npm-cli.js 的 shebang
	// `#!/usr/bin/env node` 会让直接执行 npm 报 "bad interpreter"。全局 node_modules
	// 可由当前 node 路径直接推出：<prefix>/bin/node -> <prefix>/lib/node_modules。
	candidates.push(path.join(path.dirname(path.dirname(process.execPath)), "lib", "node_modules", "@deepseek-ai", "dsh"));
	for (const candidate of candidates) if (hasAppBoot(candidate)) return candidate;
	return null;
}

/** 动态加载 dsh 自己的 loadOverlayPatches（ESM）；拿不到就返回 null，调用方退化为结构检查。 */
async function loadOverlayParser(dshRoot) {
	if (!dshRoot) return null;
	try {
		const mod = await import(pathToFileURL(path.join(dshRoot, APP_BOOT_REL)).href);
		return typeof mod.loadOverlayPatches === "function" ? mod.loadOverlayPatches : null;
	} catch (error) {
		log("WARN", `加载 dsh 解析器失败（${error.message}），退化为结构检查`);
		return null;
	}
}

/** 用 dsh 的解析器读文件：{ ok:true, entries } / { ok:false, error, degraded? }。 */
function parseWith(loadOverlayPatches, file) {
	if (!loadOverlayPatches) return { ok: false, degraded: true, error: new Error("no-parser") };
	try {
		return { ok: true, entries: loadOverlayPatches("dsh", file) };
	} catch (error) {
		return { ok: false, error };
	}
}

/**
 * 退化路径（拿不到 dsh 解析器时）的结构检查：跳过注释/空行后的首字符必须是
 * `-`（块序列）或 `[`（流序列）。
 */
function structureLooksLikeArray(text) {
	for (const raw of text.split("\n")) {
		const line = raw.trim();
		if (line === "" || line.startsWith("#")) continue;
		return line.startsWith("-") || line.startsWith("[");
	}
	return false;
}

/**
 * 摘掉「首个非注释行就是裸 `[]`」那个空文档行。
 * 这正是旧 setup.sh 追加造成的形态：`[]` 结束了第一个文档，后面再跟序列项即非法。
 */
function stripLeadingEmptyArrayDoc(text) {
	const lines = text.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		const line = lines[i].trim();
		if (line === "" || line.startsWith("#")) continue;
		if (line !== "[]") return { removed: false, text };
		lines.splice(i, 1);
		return { removed: true, text: lines.join("\n") };
	}
	return { removed: false, text };
}

/** 拿一段文本再解析一次（解析器只接受路径，所以落临时文件）。 */
function parseText(text, loadOverlayPatches) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-profile-patch-"));
	const file = path.join(dir, "cordis.patch.yml");
	try {
		fs.writeFileSync(file, text);
		return parseWith(loadOverlayPatches, file);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

/**
 * 按哨兵把层文本切成条目块（哨兵归入其后的块）。切出来的块数必须与解析出的条目数一致，
 * 否则返回 null，让调用方退回「整层追加」的保守做法（绝不猜）。
 */
function splitLayerChunks(layerText, expectedCount) {
	const chunks = [];
	let current = null;
	for (const line of layerText.split("\n")) {
		if (line.trim() === ENTRY_SENTINEL) {
			if (current) chunks.push(current.join("\n"));
			current = [line];
			continue;
		}
		if (current) current.push(line);
	}
	if (current) chunks.push(current.join("\n"));
	if (chunks.length === 0) return null;
	if (expectedCount !== undefined && chunks.length !== expectedCount) return null;
	return chunks.map((chunk) => `${chunk.replace(/\n*$/, "")}\n`);
}

/** 目标已存在时沿用它的权限位（~/.dsh 下的文件是 0600）；新建按 0600。 */
function fileMode(target) {
	try {
		return fs.statSync(target).mode & 0o777;
	} catch {
		return 0o600;
	}
}

/**
 * 写盘：落同目录临时文件 → 真解析校验（写前）→ 备份 → rename 覆盖 → 复验 → 删备份。
 * 写前校验不过则原文件一个字节都不动。
 */
function writeWithValidation({ target, text, loadOverlayPatches, tag, note, original, mode }) {
	fs.mkdirSync(path.dirname(target), { recursive: true });
	const tmp = path.join(path.dirname(target), `.${path.basename(target)}.tmp-${process.pid}`);
	const filePermissions = mode === undefined ? fileMode(target) : mode;

	if (!loadOverlayPatches && !structureLooksLikeArray(text)) {
		log("ERROR", "结构检查未通过（首个非注释行不是数组），拒绝写入");
		process.exit(1);
	}
	fs.writeFileSync(tmp, text, { mode: filePermissions });
	if (loadOverlayPatches) {
		const check = parseWith(loadOverlayPatches, tmp);
		if (!check.ok) {
			fs.rmSync(tmp, { force: true });
			log("ERROR", `写前校验失败，${target} 未做任何改动：`);
			console.error(String(check.error.message || check.error));
			process.exit(1);
		}
	}

	let backup = null;
	if (original !== undefined) {
		backup = `${target}${BACKUP_SUFFIX}`;
		fs.writeFileSync(backup, original, { mode: filePermissions });
	}
	fs.renameSync(tmp, target);
	fs.chmodSync(target, filePermissions);

	if (loadOverlayPatches) {
		const final = parseWith(loadOverlayPatches, target);
		if (!final.ok) {
			if (backup) {
				try {
					fs.renameSync(backup, target);
					log("ERROR", `写入后校验失败，已回滚原文件：${target}`);
				} catch (error) {
					log("ERROR", `写入后校验失败且回滚失败（备份保留在 ${backup}）：${error.message}`);
				}
			} else {
				fs.rmSync(target, { force: true });
				log("ERROR", "写入后校验失败，已删除刚写入的文件");
			}
			console.error(String(final.error.message || final.error));
			process.exit(1);
		}
	}
	if (backup) fs.rmSync(backup, { force: true });
	log(tag, note);
}

async function main() {
	const argv = process.argv.slice(2);
	let optTarget = null;
	let optLayer = null;
	let optRoot = null;
	for (let i = 0; i < argv.length; i += 1) {
		if (argv[i] === "--target") optTarget = argv[++i];
		else if (argv[i] === "--layer") optLayer = argv[++i];
		else if (argv[i] === "--root") optRoot = argv[++i];
	}

	const target = optTarget || path.join(os.homedir(), ".dsh", "profiles", "web", "cordis.patch.yml");
	const layerFile = optLayer || path.join(__dirname, "..", "config", "cordis.patch.yml");

	let layerText;
	if (fs.existsSync(layerFile)) layerText = fs.readFileSync(layerFile, "utf8");
	else {
		log("WARN", `缺少权限层文件 ${layerFile}，使用内联兜底内容`);
		layerText = FALLBACK_LAYER;
	}
	if (!layerText.endsWith("\n")) layerText += "\n";

	const dshRoot = resolveDshRoot(optRoot);
	if (optRoot && !dshRoot) {
		log("ERROR", `--root ${optRoot} 下找不到 ${APP_BOOT_REL}，无法用 dsh 解析器校验`);
		process.exit(1);
	}
	const loadOverlayPatches = await loadOverlayParser(dshRoot);
	if (!loadOverlayPatches) log("WARN", "未找到 dsh 安装根，本次只做结构检查（无法用 dsh 解析器校验）");

	console.log(`目标补丁层: ${target}`);
	console.log(`权限层来源: ${layerFile}`);

	if (!fs.existsSync(target)) {
		writeWithValidation({ target, text: layerText, loadOverlayPatches, tag: "CREATED", note: "写入权限层" });
		return;
	}

	const original = fs.readFileSync(target, "utf8");
	const mode = fileMode(target);
	const parsed = parseWith(loadOverlayPatches, target);

	let baseText = original;
	let repaired = false;
	let isEmptyTemplate = false;
	let parsedTargetEntries = null;

	if (parsed.ok) {
		isEmptyTemplate = parsed.entries.length === 0;
		parsedTargetEntries = parsed.entries;
	} else if (parsed.degraded) {
		if (!structureLooksLikeArray(original)) {
			log("ERROR", `目标不是顶层数组（结构检查未通过），拒绝改写：${target}`);
			process.exit(1);
		}
		log("WARN", "无解析器，无法分类：按「已有内容」处理（只追加权限层）");
	} else {
		const stripped = stripLeadingEmptyArrayDoc(original);
		const retry = stripped.removed ? parseText(stripped.text, loadOverlayPatches) : { ok: false };
		if (!stripped.removed || !retry.ok) {
			log("ERROR", `无法解析 ${target}，且不是「空数组文档 + 内容」这种可定点修复的形态：`);
			console.error(String(parsed.error.message || parsed.error));
			console.error("  原文件未做任何改动。可先备份，再用 `dsh --profile web --dump-default-config` 诊断，或手工把它修成顶层数组。");
			process.exit(1);
		}
		baseText = stripped.text;
		repaired = true;
		isEmptyTemplate = retry.entries.length === 0;
		parsedTargetEntries = retry.entries;
	}

	// 判定「还缺哪些层」——按条目 id 比，而不是按整串特征：升级时常常只多出那一条
	// （例如 0.2.0 起 approval 必须与 sandbox-policy 成对），整层特征串判定会把这种
	// 「只缺一条」误判成「已就位」。
	const layerParsed = parseText(layerText, loadOverlayPatches);
	const layerEntries = layerParsed.ok ? layerParsed.entries : null;
	const layerChunks = layerEntries ? splitLayerChunks(layerText, layerEntries.length) : null;
	const targetEntries = Array.isArray(parsedTargetEntries) ? parsedTargetEntries : null;
	let missingChunks = null;
	let satisfied = false;
	let ownSandbox = false;

	if (layerEntries && layerChunks && targetEntries) {
		// 用户自己配过 sandbox-policy（模式不是我们要的值）时，不要再塞 approval=never：
		// 那会把他的组合推成「匹配不到预设」——尊重用户的选择，只报一句说明。
		const sandboxEntry = targetEntries.find((entry) => entry && entry.id === "sandbox-policy");
		ownSandbox = sandboxEntry === undefined || sandboxEntry.config?.mode === "danger-full-access";
		const missing = layerEntries
			.map((entry, index) => ({ entry, chunk: layerChunks[index] }))
			.filter(({ entry }) => !targetEntries.some((target) => target && target.id === entry.id))
			// approval 只在沙箱模式也是我们的值时补
			.filter(({ entry }) => entry.id !== "approval" || ownSandbox);
		if (missing.length === 0) satisfied = true;
		else if (targetEntries.length > 0) missingChunks = missing.map(({ chunk }) => chunk).join("");
	} else {
		// 退化路径（拿不到解析器 / 层文件没切出块）：退回老的整串特征判定 + 整层追加
		satisfied = baseText.includes(LAYER_MARKER);
	}

	if (satisfied && !isEmptyTemplate) {
		if (repaired) {
			writeWithValidation({ target, text: baseText, loadOverlayPatches, tag: "REPAIRED", note: "摘除残留的裸 `[]` 空文档行（旧版 setup.sh 追加造成的形态；权限层已在）", original, mode });
			return;
		}
		log("OK", ownSandbox ? "权限层已就位，未改动" : "权限层已就位（沙箱模式是你自己配的，未追加 approval 层），未改动");
		return;
	}

	if (isEmptyTemplate || missingChunks === null) {
		writeWithValidation({ target, text: layerText, loadOverlayPatches, tag: "REPLACED", note: "目标是 dsh 的空数组模板，整体替换为权限层", original, mode });
		return;
	}

	const appended = `${baseText.replace(/\n*$/, "\n")}\n${missingChunks}`;
	const count = missingChunks.split(ENTRY_SENTINEL).length - 1;
	const note = `${repaired ? "摘除残留的裸 `[]` 空文档行，" : ""}保留原有配置层，追加缺失的 ${count} 条权限层`;
	writeWithValidation({ target, text: appended, loadOverlayPatches, tag: repaired ? "REPAIRED" : "APPENDED", note, original, mode });
}

main().catch((error) => {
	log("ERROR", error.stack || error.message);
	process.exit(1);
});
