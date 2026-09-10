#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-android-link-fix.js
 *
 * 验证 Android/Termux 上的 dsh link → rename / 无硬链接 no-replace 回退补丁是否就位：
 *   - 会话发布（dsh-session-persistence-jsonl）不得再调用 link(tmp, finalPath)，
 *     且历史迁移 publishCurrentExclusive 必须接入无硬链接回退；
 *   - 附件发布（dsh-attachment-local）必须接入无硬链接回退，且在 link()=EACCES 时
 *     仍能真实保存并去重（临时目录运行测试）；
 *   - write 工具新建文件（dsh-fs-local）必须带 isHardLinkUnavailable +
 *     publishNoReplaceNoHardlink 回退，并且在模拟 link()=EACCES 时仍能成功写入；
 *   - 会话持久化的 node:fs/promises 导入不得在仍引用 link 的情况下漏掉 link。
 *
 * 这个脚本只做静态检查和临时目录运行测试，不读取/修改 ~/.dsh/sessions，
 * 不会破坏任何已有会话。
 *
 * 用法：node patches/verify-android-link-fix.js [--root <@deepseek-ai 包目录>]
 */
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execSync } = require("node:child_process");

function resolveRoot(optRoot) {
	if (optRoot) return optRoot;
	try {
		const npmRoot = execSync("npm root -g", { encoding: "utf8" }).trim();
		return path.join(npmRoot, "@deepseek-ai", "dsh", "node_modules", "@deepseek-ai");
	} catch {
		return null;
	}
}

function assert(cond, msg) {
	if (!cond) throw new Error(msg);
}

const FS_PROMISES_IMPORT = /^import \{([^}]*)\} from "node:fs\/promises";$/m;

/** 从源码里按大括号配平提取一个（async）function 声明，供运行时行为测试使用。 */
function extractFunction(src, name) {
	let start = src.indexOf(`function ${name}(`);
	if (start === -1) throw new Error(`未找到函数 ${name}`);
	if (src.slice(start - 6, start) === "async ") start -= 6;
	let i = src.indexOf("{", start);
	let depth = 0;
	for (; i < src.length; i++) {
		if (src[i] === "{") depth++;
		else if (src[i] === "}") {
			depth--;
			if (depth === 0) return src.slice(start, i + 1);
		}
	}
	throw new Error(`函数 ${name} 大括号不匹配`);
}

/** 若文件正文仍引用 link，则 node:fs/promises 导入必须包含 link（避免 link is not defined）。 */
function assertLinkImportPresent(src, label) {
	const importMatch = src.match(FS_PROMISES_IMPORT);
	assert(importMatch, `${label} 未找到 node:fs/promises 导入行`);
	const imported = importMatch[1].split(",").map((s) => s.trim());
	if (!imported.includes("link")) {
		const body = src.replace(importMatch[0], "");
		assert(!/\blink\b/.test(body), `${label} 正文仍引用 link 但导入缺少 link（link is not defined 风险）`);
	}
}

function checkSession(root) {
	const file = path.join(root, "dsh-session-persistence-jsonl", "lib", "index.js");
	const src = fs.readFileSync(file, "utf8");
	assert(!/\bawait link\(tmp,\s*finalPath\)/.test(src), "会话持久化仍包含 link(tmp, finalPath)");
	assert(src.includes("await rename(tmp, finalPath)"), "会话持久化未检测到 rename(tmp, finalPath) 发布");
	assert(
		src.includes("isHardLinkUnavailable") && src.includes("publishNoReplaceNoHardlink(staged, currentPath)"),
		"会话持久化未接入 publishCurrentExclusive 的无硬链接回退"
	);
	assertLinkImportPresent(src, "会话持久化");
	console.log("[OK] dsh-session-persistence-jsonl 使用 rename 发布 + 迁移无硬链接回退");
}

function checkAttachment(root) {
	const file = path.join(root, "dsh-attachment-local", "lib", "index.js");
	const src = fs.readFileSync(file, "utf8");
	assert(src.includes("isHardLinkUnavailable") && src.includes("publishNoReplaceNoHardlink"), "附件持久化未接入无硬链接回退");
	assert(src.includes("isHardLinkUnavailable(error)"), "附件的 link 失败分支未接入回退");
	assert(/import \{[^}]*\bcopyFile\b[^}]*\} from "node:fs\/promises"/.test(src), "附件别名回退缺少 copyFile 导入");
	console.log("[OK] dsh-attachment-local 已接入无硬链接回退");
}

/**
 * 运行时验证会话迁移的 no-replace 回退：从补丁后的文件提取
 * isHardLinkUnavailable / publishNoReplaceNoHardlink / publishCurrentExclusive，
 * 注入一个恒抛 EACCES 的 link，确认回退能真正发布、且在目标已存在时返回 false。
 */
async function testSessionMigrationFallback(root) {
	const file = path.join(root, "dsh-session-persistence-jsonl", "lib", "index.js");
	const src = fs.readFileSync(file, "utf8");
	const { open, rename, rm } = await import("node:fs/promises");
	const factory = new Function(
		"open", "rename", "rm", "isEEXIST", "syncDirectory", "dirname",
		`${extractFunction(src, "isHardLinkUnavailable")}\n`
		+ `${extractFunction(src, "publishNoReplaceNoHardlink")}\n`
		+ `${extractFunction(src, "publishCurrentExclusive")}\n`
		+ "return publishCurrentExclusive;"
	);
	const publishCurrentExclusive = factory(
		open, rename, rm,
		(error) => error instanceof Error && error.code === "EEXIST",
		async () => {},
		path.dirname
	);
	const internals = {
		platform: "linux",
		fs: {
			link: async () => {
				const err = new Error("simulated EACCES: link is blocked by SELinux");
				err.code = "EACCES";
				throw err;
			},
		},
	};
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-session-link-verify-"));
	try {
		const target = path.join(tmp, "session.jsonl.zstd");
		const staged = path.join(tmp, "staged.tmp");
		fs.writeFileSync(staged, "session-bytes");
		assert(await publishCurrentExclusive(staged, target, internals) === true, "会话迁移回退未返回已发布");
		assert(fs.readFileSync(target, "utf8") === "session-bytes", "会话迁移回退写入的内容不一致");
		assert(!fs.existsSync(staged), "会话迁移回退后 staged 未被消费");

		const staged2 = path.join(tmp, "staged2.tmp");
		fs.writeFileSync(staged2, "other-bytes");
		assert(await publishCurrentExclusive(staged2, target, internals) === false, "目标已存在时未返回 false（no-replace 语义丢失）");
		assert(fs.existsSync(staged2), "目标已存在时 staged 不应被消费");
		console.log("[OK] dsh-session-persistence-jsonl 在 link()=EACCES 时通过 O_EXCL+rename 回退发布迁移会话（no-replace 保持）");
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

/** 真实保存一个附件：本机 link() 被 SELinux 拒绝，正好触发无硬链接回退。 */async function testAttachmentFallback(root) {
	const mod = await import(path.join(root, "dsh-attachment-local", "lib", "index.js"));
	const Store = mod.LocalAttachmentStore || mod.default;
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-att-link-verify-"));
	const store = new Store({ reflect: { provide() {} } }, { dshHome: tmp });
	try {
		const data = Buffer.from("android hardlink fallback attachment");
		const ref = await store.saveFile({ data, name: "hello.txt" });
		const got = fs.readFileSync(store.fileHostPath(ref));
		assert(got.equals(data), "附件回退保存的内容不一致");
		const ref2 = await store.saveFile({ data, name: "hello.txt" });
		assert(String(ref2.attachmentId) === String(ref.attachmentId), "附件去重引用不一致");
		console.log("[OK] dsh-attachment-local 在 link()=EACCES 时通过 复制+O_EXCL+rename 回退保存并去重成功");
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

async function testFsLocalFallback(root) {
	const mod = await import(path.join(root, "dsh-fs-local", "lib", "index.js"));
	const LocalFileSystem = mod.LocalFileSystem || mod.default;
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "dsh-link-fix-verify-"));
	const target = path.join(tmp, "new-file.txt");
	const mockCtx = {
		reflect: {
			provide() {},
		},
	};
	const fsx = new LocalFileSystem(mockCtx, {
		cwd: tmp,
		diffBasisMaxBytes: 10 * 1024 * 1024,
	});
	fsx.internals.linkFile = async () => {
		const err = new Error("simulated EACCES: link is blocked by SELinux");
		err.code = "EACCES";
		throw err;
	};
	try {
		await fsx.writeText({
			targetKey: target,
			displayPath: target,
		}, "hello from android link fallback", {
			kind: "createIfAbsent",
		});
		const content = fs.readFileSync(target, "utf8");
		assert(content === "hello from android link fallback", "fs-local 回退写入的内容不一致");
		const leftovers = fs.readdirSync(tmp).filter((name) => name.startsWith(".new-file.txt."));
		assert(leftovers.length === 0, `fs-local 回退写入后残留 staging 目录: ${leftovers.join(", ")}`);
		console.log("[OK] dsh-fs-local 在 link()=EACCES 时通过 O_EXCL+rename 回退成功写入");
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

async function main() {
	const argv = process.argv.slice(2);
	let optRoot = null;
	for (let i = 0; i < argv.length; i++) {
		if (argv[i] === "--root") optRoot = argv[++i];
	}
	const root = resolveRoot(optRoot);
	if (!root) {
		console.error("无法定位 dsh 安装目录。请用 --root 指定 <...>/@deepseek-ai 包目录。");
		process.exit(1);
	}
	if (!fs.existsSync(path.join(root, "dsh-session-persistence-jsonl")) ||
		!fs.existsSync(path.join(root, "dsh-attachment-local")) ||
		!fs.existsSync(path.join(root, "dsh-fs-local"))) {
		console.error(`[FAIL] 目标目录不完整: ${root}`);
		process.exit(1);
	}
	console.log(`验证 dsh 包目录: ${root}`);
	checkSession(root);
	checkAttachment(root);
	const fsLocalSrc = fs.readFileSync(path.join(root, "dsh-fs-local", "lib", "index.js"), "utf8");
	assert(fsLocalSrc.includes("isHardLinkUnavailable") && fsLocalSrc.includes("publishNoReplaceNoHardlink"), "dsh-fs-local 缺少硬链接回退 helpers");
	assert(fsLocalSrc.includes("isHardLinkUnavailable(error)") && fsLocalSrc.includes("await publishNoReplaceNoHardlink("), "dsh-fs-local 的 link 失败分支未接入回退");
	console.log("[OK] dsh-fs-local 已接入 isHardLinkUnavailable + publishNoReplaceNoHardlink");
	await testSessionMigrationFallback(root);
	await testAttachmentFallback(root);
	await testFsLocalFallback(root);
	console.log("\n全部验证通过：会话/附件/fs-local 的 Android link 兼容修复均已就位。");
}

main().catch((err) => {
	console.error(`\n[FAIL] ${err.message}`);
	process.exit(1);
});
