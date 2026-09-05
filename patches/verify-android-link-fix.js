#!/data/data/com.termux/files/usr/bin/node
/**
 * verify-android-link-fix.js
 *
 * 验证 Android/Termux 上的 dsh link → rename / no-replace 回退补丁是否就位：
 *   - 会话发布（dsh-session-persistence-jsonl）不得再调用 link(tmp, finalPath)
 *   - 附件发布（dsh-attachment-local）不得再调用 link(temporary, target)
 *   - write 工具新建文件（dsh-fs-local）必须带 isHardLinkUnavailable +
 *     publishNoReplaceNoHardlink 回退，并且在模拟 link()=EACCES 时仍能成功写入
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

function checkSession(root) {
const file = path.join(root, "dsh-session-persistence-jsonl", "lib", "index.js");
const src = fs.readFileSync(file, "utf8");
assert(!src.match(/\bawait link\(tmp,\s*finalPath\)/), "会话持久化仍包含 link(tmp, finalPath)");
assert(src.includes("await rename(tmp, finalPath)"), "会话持久化未检测到 rename(tmp, finalPath) 发布");
console.log("[OK] dsh-session-persistence-jsonl 使用 rename 发布，无 link 残留");
}

function checkAttachment(root) {
const file = path.join(root, "dsh-attachment-local", "lib", "index.js");
const src = fs.readFileSync(file, "utf8");
assert(!src.match(/\bawait link\(temporary,\s*target\)/), "附件持久化仍包含 link(temporary, target)");
assert(src.includes("rename(temporary, target)"), "附件持久化未检测到 rename(temporary, target) 发布");
console.log("[OK] dsh-attachment-local 使用 rename 发布，无 link 残留");
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
testFsLocalFallback(root).then(() => {
console.log("\n全部验证通过：会话/附件/fs-local 的 Android link 兼容修复均已就位。");
}).catch((err) => {
console.error(`\n[FAIL] ${err.message}`);
process.exit(1);
});
}

main();
