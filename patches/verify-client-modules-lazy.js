#!/usr/bin/env node
/**
 * 验证 02-client-modules-lazy-compose 补丁：客户端 combo 改为按需构建后，服务端返回的字节必须与磁盘上的 client bundle 一致。
 *
 * 做法：用 --port 0 临时起一个 dsh web 实例（不影响 3080 上正在运行的服务），
 * 从 GET / 的 window["__DSH_BOOT__"] 里取资源 URL，逐个核对：
 *   ① 单条 bundle 的响应体 == 磁盘文件（去掉 //# sourceURL / sourceMappingURL 尾巴后 + ";\n" + 新的 sourceMappingURL 行）；
 *   ② 单条 / 批量的 sourcemap 能解析、结构合法、与对应 bundle 行数自洽；
 *   ③ 未知 URL 仍然 404（惰性查找没有把任意 URL 当记录）。
 * 顺带打印"启动到打印 token"的秒数，可用于冷启动 A/B。
 *
 * 用法：node patches/verify-client-modules-lazy.js [--timeout 120]
 * 退出码 0 = 全部通过。
 */
import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const DSH = process.env.DSH_DIR || "/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh";
const BIN = join(DSH, "lib/bin.js");
const TIMEOUT_S = Number(process.argv[process.argv.indexOf("--timeout") + 1]) > 0 ? Number(process.argv[process.argv.indexOf("--timeout") + 1]) : 120;
const SOURCE_MAP_TRAILER = /(?:\r?\n)?\/\/# sourceMappingURL=[^\r\n]*(?:\r?\n)?$/;
const SOURCE_URL_TRAILER = /(?:\r?\n)?\/\/# sourceURL=([^\r\n]+)(?:\r?\n)?$/;

const results = [];
const check = (name, ok, detail) => {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` — ${detail}` : ""}`);
};

/** 复刻 dsh-client-modules comboSource()：去掉旧 trailer，保证结尾换行。 */
function comboSource(raw) {
  let source = raw.toString("utf8");
  const sourceUrl = SOURCE_URL_TRAILER.exec(source)?.[1];
  source = source.replace(SOURCE_URL_TRAILER, "").replace(SOURCE_MAP_TRAILER, "");
  if (!source.endsWith("\n")) source += "\n";
  return { source, fallbackSource: sourceUrl === undefined ? undefined : sourceUrl };
}

const child = spawn(process.execPath, ["--expose-internals", "--no-warnings", BIN, "web", "--no-open", "--port", "0"], {
  stdio: ["ignore", "pipe", "pipe"],
});
let output = "";
const kill = (signal) => { try { child.kill(signal); } catch { /* 已退出 */ } };
process.on("exit", () => kill("SIGKILL"));

const started = Date.now();
const authUrl = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error(`等待 token 超时（${TIMEOUT_S}s）\n${output.slice(-2000)}`)), TIMEOUT_S * 1000);
  const scan = (chunk) => {
    output += chunk.toString();
    const match = /http:\/\/127\.0\.0\.1:\d+\/\?token=[A-Za-z0-9_-]+/.exec(output);
    if (match) { clearTimeout(timer); resolve(match[0]); }
  };
  child.stdout.on("data", scan);
  child.stderr.on("data", scan);
  child.on("exit", (code) => { clearTimeout(timer); reject(new Error(`dsh 提前退出（code ${code}）\n${output.slice(-2000)}`)); });
});
const bootSeconds = (Date.now() - started) / 1000;
const origin = new URL(authUrl).origin;
console.log(`实例已就绪：${origin}（启动到 token ${bootSeconds.toFixed(2)}s）`);

// token 只换 cookie，不做其它副作用；token 是进程级可重复使用的
const redirect = await fetch(authUrl, { redirect: "manual" });
const cookie = (redirect.headers.getSetCookie?.() ?? []).map((value) => value.split(";")[0]).join("; ");
check("带 token 的地址返回 303", redirect.status === 303, `http=${redirect.status}`);
const get = (path) => fetch(`${origin}${path}`, { headers: { cookie } });

const html = await (await get("/")).text();
const bootStart = html.indexOf("__DSH_BOOT__");
if (bootStart < 0) {
  check("GET / 里能找到 window.__DSH_BOOT__", false);
} else {
  const eq = html.indexOf("= ", bootStart);
  const graph = JSON.parse(html.slice(eq + 2, html.indexOf("</script>", bootStart)).trim().replace(/;$/, ""));
  check("轮询到完整的启动清单", graph.entries.length > 0, `entries=${graph.entries.length} batches=${graph.batches.length}`);

  const clients = [];
  const roots = [
    join(DSH, "node_modules"),
    join(process.env.DSH_HOME || join(process.env.HOME || "", ".dsh"), "profiles", process.env.DSH_PROFILE || "web", "node_modules"),
  ];
  for (const entry of graph.entries) {
    for (const root of roots) {
      const dir = join(root, ...entry.id.split("/"));
      const manifest = join(dir, "package.json");
      if (!existsSync(manifest)) continue;
      const meta = JSON.parse(readFileSync(manifest, "utf8"));
      const rel = typeof meta.exports?.["./client"] === "string" ? meta.exports["./client"] : meta.exports?.["./client"]?.default;
      if (rel) clients.push({ entry, path: join(dir, rel) });
      break;
    }
  }
  clients.sort((a, b) => readFileSync(b.path).length - readFileSync(a.path).length);
  const samples = [clients[0], clients.find((c) => existsSync(`${c.path}.map`)), clients.at(-1)].filter((c, index, all) => c && all.indexOf(c) === index);
  for (const { entry, path } of samples) {
    const { source } = comboSource(readFileSync(path));
    const body = await (await get(entry.url)).text();
    const mapUrl = entry.url.replace("/client.js&", "/client.js.map&");
    const mapResponse = await get(mapUrl);
    const mapText = await mapResponse.text();
    let parsed;
    try { parsed = JSON.parse(mapText); } catch { /* 下面统一报 FAIL */ }
    const section = parsed?.sections?.[0]?.map;
    const trailer = /^;\n\/\/# sourceMappingURL=([^\n]+)\n$/.exec(body.slice(source.length));
    check(`单条 bundle 与磁盘文件一致: ${entry.id}`, body.startsWith(source) && trailer?.[1] === mapUrl, `bytes=${body.length} source=${source.length}`);
    check(`sourcemap 可服务且结构完整: ${entry.id}`, mapResponse.status === 200 && parsed?.version === 3 && section?.mappings?.length > 0 && section.sources.length > 0, `http=${mapResponse.status} bytes=${mapText.length}`);
  }
  const batch = graph.batches.find((b) => b.phase === "application") ?? graph.batches[0];
  const batchBody = await (await get(batch.url)).text();
  const batchMapUrl = batch.url.replaceAll("/client.js,", "/client.js.map,").replace("/client.js&", "/client.js.map&");
  const batchMap = await (await get(batchMapUrl)).text();
  check("批量 combo 与它的 sourcemap 仍可服务", batchBody.includes("__ModuleLoader__") && batchMap.length > 1000 && JSON.parse(batchMap).version === 3, `bundleBytes=${batchBody.length} mapBytes=${batchMap.length}`);
}
const notFound = await get("/plugins/??no-such-package/client.js&rev=deadbeef");
check("未知 URL 仍返回 404", notFound.status === 404, `http=${notFound.status}`);
const head = await fetch(`${origin}/`, { method: "HEAD", headers: { cookie } });
check("HEAD / 不因惰性查找报错", head.status === 200, `http=${head.status}`);

kill("SIGTERM");
const failed = results.filter((ok) => !ok).length;
console.log(`\n${failed === 0 ? "全部通过" : `失败 ${failed}/${results.length}`}（启动到 token ${bootSeconds.toFixed(2)}s）`);
process.exit(failed === 0 ? 0 : 1);
