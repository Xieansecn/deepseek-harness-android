#!/data/data/com.termux/files/usr/bin/node
/**
 * patch-dsh-android-link.js
 *
 * 修复 Android/Termux 上 link(2) 被 SELinux 拒绝导致的 EACCES 报错：
 *
 *   EACCES: permission denied, link '.../session.jsonl.zstd.xxx.tmp' -> '.../session.jsonl.zstd'
 *
 * 根因：部分 Android 设备（含大量原厂 ROM）的 SELinux 对 app 私有数据全局禁止硬链接，
 * 任何 link() 都返回 EACCES（rename() 正常）。dsh 三处用 link() 做“原子发布 / no-replace”
 * 的路径都会因此失败：
 *
 *   1. dsh-session-persistence-jsonl/lib/index.js —— 会话日志发布 + 历史会话迁移发布
 *   2. dsh-attachment-local/lib/index.js           —— 附件内容寻址发布与别名发布
 *   3. dsh-fs-local/lib/index.js                   —— write 工具“新建文件”（createIfAbsent 分支）
 *
 * 修补策略（版本兼容、幂等）：
 *   - 会话日志的【直接发布】link(tmp, finalPath) -> rename(tmp, finalPath)（与上游 rc.6+ 修复一致）；
 *   - 所有“no-replace”语义的 link 发布（会话迁移 publishCurrentExclusive、附件发布/别名）
 *     在 link 因 EACCES/EPERM/EMLINK/ENOSYS/ENOTSUP 失败时，回退到
 *     “O_CREAT|O_EXCL 原子占位 + 同目录 rename 原子填充”的无硬链接发布，
 *     保留“不覆盖已存在文件”的语义；
 *   - 附件祖先遍历容忍 EACCES/EPERM/ENOSYS。
 *
 * 关键：ensureFsImport 只“追加”node:fs/promises 的导入名，绝不删除 link ——
 * 因为部分 dsh 版本（如 0.1.5-rc.1）在 defaultFileSystem / publishCurrentExclusive
 * 中仍引用 link，删除导入会导致模块加载即抛 “link is not defined”。
 *
 * 用法：
 *   node patch-dsh-android-link.js [--root <@deepseek-ai 包目录>]
 *
 * 默认自动定位：npm 全局安装（npm root -g）下的 dsh 依赖目录；也可用 --root 指向
 * 目标机器的 <...>/@deepseek-ai 目录（例如把本脚本拷到部署机上执行）。
 * 重复执行安全：已修补的文件会跳过。
 *
 * 修补后需要重启 dsh 进程才生效（代码在启动时加载）。
 */
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execSync } = require("node:child_process");

/** 把名字追加进 node:fs/promises 的导入（已存在则跳过；只增不删，避免制造未定义引用）。 */
function ensureFsImport(src, addNames) {
	return src.replace(/^(import \{)([^}]*)(\} from "node:fs\/promises";)$/m, (whole, pre, body, post) => {
		const names = body.split(",").map((s) => s.trim()).filter(Boolean);
		for (const name of addNames) if (!names.includes(name)) names.push(name);
		return pre + names.join(", ") + post;
	});
}

/**
 * 无硬链接的 no-replace 发布回退：O_CREAT|O_EXCL 原子占位（目标已存在时返回 false），
 * 再用同目录 rename 原子填充。占位与填充之间崩溃会留下空占位文件，已在错误路径尽力清理。
 * 依赖调用方文件里可用的 open / rename / rm。
 * @returns true 表示已发布（tempPath 已被消费）；false 表示目标已存在（tempPath 仍在）。
 */
const HARD_LINK_HELPERS = [
	"/** [dsh-android-link-fix] link(2) 被拒绝或不支持的错误码：Android SELinux 全局禁硬链接（EACCES），部分 FUSE 挂载未实现（ENOSYS/ENOTSUP）。 */",
	"function isHardLinkUnavailable(error) {",
	"\treturn error instanceof Error && typeof error.code === \"string\" && (error.code === \"EACCES\" || error.code === \"EPERM\" || error.code === \"EMLINK\" || error.code === \"ENOSYS\" || error.code === \"ENOTSUP\" || error.code === \"EOPNOTSUPP\");",
	"}",
	"/**",
	" * [dsh-android-link-fix] 无硬链接的 no-replace 发布回退：先用 O_CREAT|O_EXCL 原子占位（EEXIST 表示目标已存在），",
	" * 再用同目录 rename 原子填充。占位与填充之间崩溃会留下空占位文件，已在错误路径尽力清理。",
	" * @returns true 表示已发布（tempPath 已被消费）；false 表示目标已存在（tempPath 仍在）。",
	" */",
	"async function publishNoReplaceNoHardlink(tempPath, absolutePath) {",
	"\tlet guard;",
	"\ttry {",
	"\t\tguard = await open(absolutePath, \"wx\", 384);",
	"\t} catch (error) {",
	"\t\tif (error instanceof Error && \"code\" in error && error.code === \"EEXIST\") return false;",
	"\t\tthrow error;",
	"\t}",
	"\ttry {",
	"\t\tawait guard.close();",
	"\t\tawait rename(tempPath, absolutePath);",
	"\t} catch (error) {",
	"\t\tawait rm(absolutePath, { force: true }).catch(() => {});",
	"\t\tthrow error;",
	"\t}",
	"\treturn true;",
	"}",
].join("\n");

/** dsh-session-persistence-jsonl：历史会话迁移的 no-replace 发布块。 */
const SESSION_OLD_EXCLUSIVE = [
	"\ttry {",
	"\t\tawait internals.fs.link(staged, currentPath);",
	"\t} catch (error) {",
	"\t\t/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */",
	"\t\tif (isEEXIST(error)) return false;",
	"\t\t/* v8 ignore next -- the filesystem error is already complete. */",
	"\t\tthrow error;",
	"\t}",
].join("\n");

const SESSION_NEW_EXCLUSIVE = [
	"\ttry {",
	"\t\tawait internals.fs.link(staged, currentPath);",
	"\t} catch (error) {",
	"\t\tif (isEEXIST(error)) return false;",
	"\t\t/* [dsh-android-link-fix] Android SELinux 等禁硬链接时回退到无硬链接的 no-replace 发布。 */",
	"\t\tif (!isHardLinkUnavailable(error)) throw error;",
	"\t\tif (!(await publishNoReplaceNoHardlink(staged, currentPath))) return false;",
	"\t}",
].join("\n");

/** dsh-attachment-local：staged 对象发布（发布后 staged 应消失）。 */
const ATT_STAGED_OLD = [
	"\t\ttry {",
	"\t\t\tawait link(staged.path, target);",
	"\t\t} catch (error) {",
	"\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */",
	"\t\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EEXIST\")) throw error;",
	"\t\t\tif (await digestFile(target) !== staged.sha256) throw new AttachmentError(\"Stored attachment failed integrity verification.\", \"ATTACHMENT_CORRUPT\");",
	"\t\t}",
	"\t\tawait unlink(staged.path);",
].join("\n");

const ATT_STAGED_NEW = [
	"\t\ttry {",
	"\t\t\tawait link(staged.path, target);",
	"\t\t} catch (error) {",
	"\t\t\tif (error instanceof Error && \"code\" in error && error.code === \"EEXIST\") {",
	"\t\t\t\tif (await digestFile(target) !== staged.sha256) throw new AttachmentError(\"Stored attachment failed integrity verification.\", \"ATTACHMENT_CORRUPT\");",
	"\t\t\t} else if (isHardLinkUnavailable(error)) {",
	"\t\t\t\t/* [dsh-android-link-fix] 禁硬链接时回退到无硬链接 no-replace 发布（staged 被 rename 消费）。 */",
	"\t\t\t\tif (!(await publishNoReplaceNoHardlink(staged.path, target)) && await digestFile(target) !== staged.sha256) throw new AttachmentError(\"Stored attachment failed integrity verification.\", \"ATTACHMENT_CORRUPT\");",
	"\t\t\t} else {",
	"\t\t\t\t/* v8 ignore next -- a non-collision filesystem error propagates unchanged. */",
	"\t\t\t\tthrow error;",
	"\t\t\t}",
	"\t\t}",
	"\t\tawait unlink(staged.path).catch((cleanupError) => {",
	"\t\t\t/* [dsh-android-link-fix] rename 回退发布后 staged 已被移走，ENOENT 属正常。 */",
	"\t\t\tif (!(cleanupError instanceof Error && \"code\" in cleanupError && cleanupError.code === \"ENOENT\")) throw cleanupError;",
	"\t\t});",
].join("\n");

/** dsh-attachment-local：别名发布（源对象必须保留）。 */
const ATT_ALIAS_OLD = [
	"\t\ttry {",
	"\t\t\tawait link(source, target);",
	"\t\t} catch (error) {",
	"\t\t\t/* v8 ignore next -- Private same-filesystem directories make EEXIST the only recoverable link race. */",
	"\t\t\tif (!(error instanceof Error && \"code\" in error && error.code === \"EEXIST\")) throw error;",
	"\t\t\tif (await digestFile(target) !== sha256) throw new AttachmentError(\"Stored attachment failed integrity verification.\", \"ATTACHMENT_CORRUPT\");",
	"\t\t}",
].join("\n");

const ATT_ALIAS_NEW = [
	"\t\ttry {",
	"\t\t\tawait link(source, target);",
	"\t\t} catch (error) {",
	"\t\t\tif (error instanceof Error && \"code\" in error && error.code === \"EEXIST\") {",
	"\t\t\t\tif (await digestFile(target) !== sha256) throw new AttachmentError(\"Stored attachment failed integrity verification.\", \"ATTACHMENT_CORRUPT\");",
	"\t\t\t} else if (isHardLinkUnavailable(error)) {",
	"\t\t\t\t/* [dsh-android-link-fix] 禁硬链接时：复制源对象到同目录临时文件，再 O_EXCL 占位 + rename 原子发布别名（保留源对象）。 */",
	"\t\t\t\tconst temporary = join(parent, `.dsh-alias-${randomUUID()}.tmp`);",
	"\t\t\t\ttry {",
	"\t\t\t\t\tawait copyFile(source, temporary);",
	"\t\t\t\t\tif (!(await publishNoReplaceNoHardlink(temporary, target)) && await digestFile(target) !== sha256) throw new AttachmentError(\"Stored attachment failed integrity verification.\", \"ATTACHMENT_CORRUPT\");",
	"\t\t\t\t} finally {",
	"\t\t\t\t\tawait rm(temporary, { force: true }).catch(() => {});",
	"\t\t\t\t}",
	"\t\t\t} else {",
	"\t\t\t\t/* v8 ignore next -- a non-collision filesystem error propagates unchanged. */",
	"\t\t\t\tthrow error;",
	"\t\t\t}",
	"\t\t}",
].join("\n");

/** 附件祖先遍历：容忍内核拒绝打开的祖先目录（Android SELinux 禁止 app open 应用前缀之上的系统目录）。 */
const WALK_HELPERS = [
	"/**",
	" * [dsh-android-link-fix] 同 syncDirectory，但容忍内核拒绝打开的祖先目录：Android SELinux 对 app 禁止 open 应用前缀之上的系统目录（EACCES）。",
	" * 拿不到句柄就没有可同步的东西，跳过无害；应用自身的目录仍会照常 fsync。",
	" */",
	"async function syncDirectoryTolerant(path) {",
	"\tif (process.platform === \"win32\") return;",
	"\ttry {",
	"\t\tawait syncDirectory(path);",
	"\t} catch (error) {",
	"\t\tif (error && (error.code === \"EACCES\" || error.code === \"EPERM\" || error.code === \"ENOSYS\")) return;",
	"\t\tthrow error;",
	"\t}",
	"}",
].join("\n");

/** 无硬链接 no-replace 回退：O_CREAT|O_EXCL 原子占位（EEXIST=并发创建者已抢先），再同目录 rename 原子填充。 */
const FALLBACK_HELPERS = [
	"/** [dsh-android-link-fix] link(2) 被拒绝或不支持的错误码：Android SELinux 全局禁硬链接（EACCES），部分 FUSE 挂载未实现（ENOSYS/ENOTSUP）。 */",
	"function isHardLinkUnavailable(error) {",
	"\treturn error instanceof Error && typeof error.code === \"string\" && (error.code === \"EACCES\" || error.code === \"EPERM\" || error.code === \"EMLINK\" || error.code === \"ENOSYS\" || error.code === \"ENOTSUP\" || error.code === \"EOPNOTSUPP\");",
	"}",
	"/**",
	" * [dsh-android-link-fix] 无硬链接的 no-replace 发布回退：先用 O_CREAT|O_EXCL 原子占位（EEXIST 表示并发创建者已抢先），",
	" * 再用同目录 rename 原子填充。占位与填充之间崩溃会留下空占位文件，已在错误路径尽力清理。",
	" */",
	"async function publishNoReplaceNoHardlink(tempPath, absolutePath, displayPath) {",
	"\tlet guard;",
	"\ttry {",
	"\t\tguard = await open(absolutePath, \"wx\", 384);",
	"\t} catch (error) {",
	"\t\tif (isEEXIST(error)) throw new FsError(`cannot overwrite existing \"${displayPath}\" without reading it first`, \"FS_NOT_OBSERVED\", { cause: error });",
	"\t\tthrow new FsError(`cannot write \"${displayPath}\": ${errorMessage(error)}`, \"FS_IO_ERROR\", { cause: error });",
	"\t}",
	"\ttry {",
	"\t\tawait guard.close();",
	"\t\tawait rename(tempPath, absolutePath);",
	"\t} catch (error) {",
	"\t\t/* v8 ignore next -- 占位清理只在 reserve/fill 二次故障时可达 */",
	"\t\tawait rm(absolutePath, { force: true }).catch(() => {});",
	"\t\tthrow error;",
	"\t}",
	"}",
].join("\n");

const FALLBACK_BLOCK_NEW = [
	"\t\tif (createIfAbsent !== void 0) try {",
	"\t\t\tawait linkFile(tempPath, absolutePath);",
	"\t\t} catch (error) {",
	"\t\t\t/* [dsh-android-link-fix] 拒绝 link(2) 的文件系统（Android SELinux、部分 FUSE）回退到无硬链接的 no-replace 发布。 */",
	"\t\t\tif (isHardLinkUnavailable(error)) await publishNoReplaceNoHardlink(tempPath, absolutePath, createIfAbsent.displayPath);",
	"\t\t\telse await throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);",
	"\t\t}",
].join("\n");

const FALLBACK_BLOCK_OLD = [
	"\t\tif (createIfAbsent !== void 0) try {",
	"\t\t\tawait linkFile(tempPath, absolutePath);",
	"\t\t} catch (error) {",
	"\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);",
	"\t\t}",
].join("\n");

const PACKAGES = [
	{
		name: "dsh-session-persistence-jsonl",
		file: "lib/index.js",
		fix(src) {
			let out = src;
			const details = [];
			const directLink = /await link\(tmp,\s*finalPath\)/.test(out);
			const hasExclusiveFallback = out.includes("publishNoReplaceNoHardlink(staged, currentPath)");
			if (!directLink && hasExclusiveFallback) {
				return { status: "already-fixed", detail: "会话发布已用 rename + 无硬链接回退" };
			}
			if (directLink) {
				out = out.replace(/await link\(tmp,\s*finalPath\);/, "await rename(tmp, finalPath);");
				details.push("会话日志发布 link(tmp, finalPath) -> rename(tmp, finalPath)");
			} else if (!out.includes("await rename(tmp, finalPath)")) {
				return { status: "pattern-mismatch", detail: "未找到会话发布调用（link/rename(tmp, finalPath)），跳过，请人工检查" };
			}
			if (!hasExclusiveFallback) {
				if (!out.includes(SESSION_OLD_EXCLUSIVE)) {
					return { status: "pattern-mismatch", detail: "未找到 publishCurrentExclusive 的 link 发布块，跳过，请人工检查" };
				}
				out = out.replace(SESSION_OLD_EXCLUSIVE, SESSION_NEW_EXCLUSIVE);
				const anchor = "async function publishCurrentExclusive(";
				if (!out.includes(anchor)) return { status: "pattern-mismatch", detail: "未找到 publishCurrentExclusive 锚点，跳过，请人工检查" };
				out = out.replace(anchor, HARD_LINK_HELPERS + "\n\n" + anchor);
				details.push("publishCurrentExclusive 接入无硬链接 no-replace 回退");
			}
			out = ensureFsImport(out, ["rename"]);
			return { status: "patched", detail: details.join("；") || "已刷新", src: out };
		},
	},
	{
		name: "dsh-attachment-local",
		file: "lib/index.js",
		fix(src) {
			let out = src;
			const details = [];
			if (out.includes("publishNoReplaceNoHardlink") && out.includes("isHardLinkUnavailable")) {
				return { status: "already-fixed", detail: "附件发布已接入无硬链接回退" };
			}
			// 旧版上游已把 staged 发布改成 rename（无硬链接回退）：保持原样。
			if (out.includes("rename(temporary, target)") && !out.includes("await link(staged.path, target)")) {
				return { status: "already-fixed", detail: "附件发布已用 rename（上游原生修复）" };
			}
			if (!out.includes(ATT_STAGED_OLD)) return { status: "pattern-mismatch", detail: "未找到 publishStagedObject 的 link 发布块，跳过，请人工检查" };
			if (!out.includes(ATT_ALIAS_OLD)) return { status: "pattern-mismatch", detail: "未找到 publishImmutableAlias 的 link 发布块，跳过，请人工检查" };
			out = out.replace(ATT_STAGED_OLD, ATT_STAGED_NEW).replace(ATT_ALIAS_OLD, ATT_ALIAS_NEW);
			out = ensureFsImport(out, ["copyFile"]);
			const anchor = "async function publishImmutableAlias(";
			if (!out.includes(anchor)) return { status: "pattern-mismatch", detail: "未找到 publishImmutableAlias 锚点，跳过，请人工检查" };
			out = out.replace(anchor, HARD_LINK_HELPERS + "\n\n" + anchor);
			details.push("附件发布/别名发布接入无硬链接回退");
			const oldWalk = "\t\tawait syncDirectory(parent);";
			if (out.includes(oldWalk) && !out.includes("syncDirectoryTolerant")) {
				out = out.replace(oldWalk, "\t\tawait syncDirectoryTolerant(parent);");
				out = out.replace("async function ensureDurableDirectory(", WALK_HELPERS + "\n\n" + "async function ensureDurableDirectory(");
				details.push("祖先遍历容忍 EACCES/EPERM/ENOSYS");
			}
			return { status: "patched", detail: details.join("；"), src: out };
		},
	},
	{
		name: "dsh-fs-local",
		file: "lib/index.js",
		fix(src) {
			if (src.includes("publishNoReplaceNoHardlink")) return { status: "already-fixed", detail: "已包含无硬链接发布回退（此前已修补）" };
			if (!src.includes(FALLBACK_BLOCK_OLD)) return { status: "pattern-mismatch", detail: "未找到 createIfAbsent 发布块，跳过，请人工检查该文件" };
			let out = src.replace(FALLBACK_BLOCK_OLD, FALLBACK_BLOCK_NEW);
			const anchor = "async function writeFileAtomic(";
			if (!out.includes(anchor)) return { status: "pattern-mismatch", detail: "未找到 writeFileAtomic 插入锚点，跳过，请人工检查该文件" };
			out = out.replace(anchor, FALLBACK_HELPERS + "\n\n" + anchor);
			return { status: "patched", detail: "write 工具新建文件路径：link 失败时回退到无硬链接 no-replace 发布", src: out };
		},
	},
];

function resolveRoot(optRoot) {
	const candidates = [];
	if (optRoot) candidates.push(optRoot);
	try {
		const dshPkg = require.resolve("@deepseek-ai/dsh/package.json");
		candidates.push(path.join(path.dirname(dshPkg), "node_modules", "@deepseek-ai"));
	} catch {}
	try {
		const npmRoot = execSync("npm root -g", { encoding: "utf8" }).trim();
		candidates.push(path.join(npmRoot, "@deepseek-ai", "dsh", "node_modules", "@deepseek-ai"));
	} catch {}
	for (const c of candidates) {
		if (PACKAGES.every((p) => fs.existsSync(path.join(c, p.name, p.file)))) return c;
	}
	return candidates[0] || null;
}

function patchPackage(root, spec) {
	const file = path.join(root, spec.name, spec.file);
	if (!fs.existsSync(file)) return { name: spec.name, status: "not-found", detail: `缺少文件: ${file}` };
	let src;
	try {
		src = fs.readFileSync(file, "utf8");
	} catch (error) {
		return { name: spec.name, status: "error", detail: `读取失败: ${error.message}` };
	}
	const result = spec.fix(src);
	if (result.status === "patched") {
		try {
			fs.writeFileSync(file, result.src);
		} catch (error) {
			return { name: spec.name, status: "error", detail: `写入失败: ${error.message}` };
		}
	}
	return { name: spec.name, status: result.status, detail: result.detail, file };
}

function main() {
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
	console.log(`dsh 包目录: ${root}`);
	console.log("");
	let warn = false;
	for (const spec of PACKAGES) {
		const r = patchPackage(root, spec);
		const mark = {
			patched: "[PATCHED ]",
			"already-fixed": "[OK      ]",
			"not-found": "[SKIP    ]",
			"pattern-mismatch": "[WARN    ]",
			error: "[ERROR   ]",
		}[r.status] || "[?????   ]";
		console.log(`${mark} ${r.name}: ${r.detail}`);
		if (r.status === "pattern-mismatch" || r.status === "not-found" || r.status === "error") warn = true;
	}
	console.log("");
	if (warn) {
		console.log("有文件未自动修补，请人工检查。");
		process.exit(2);
	}
	console.log("全部完成。请重启 dsh 进程使修补生效（例如：~/dsh/restart_dsh_now.sh 或重新运行 dsh web）。");
}

main();
