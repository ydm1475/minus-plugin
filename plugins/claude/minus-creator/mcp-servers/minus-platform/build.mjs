// 把 index.js 打成自包含单文件 dist/minus-platform.cjs（依赖内联）。
//
// 为什么是 target:node12 而不是更高：客户端 spawn MCP 时用的是 launchd PATH 上的
// node，可能很旧（实测有 v13）。index.js 用了 ?./?? 和 ESM，老 node 会在「解析阶段」
// 就 SyntaxError 崩溃，根本到不了我们的版本自检。target:node12 把这些语法降级，让
// 老 node 也能解析到下面 banner 注入的自检，给一句人话报错。
//
// 自检行为硬下限是 18（global fetch 需要 18），但文案一律以「建议 Node 24」为主，
// 18 只是兜底，不强调（与平台 NODE_FLOOR=24 一致）。

import { build } from "esbuild";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

// 版本号单源于 lib/toolchain.sh：构建时用一行正则读出，烘进 banner，不再内联字面量。
// NODE_RUNTIME_FLOOR=跑 bundle 的硬下限（global fetch 需 18）；NODE_TARGET=推荐口径。
const here = dirname(fileURLToPath(import.meta.url));
const toolchain = readFileSync(join(here, "..", "..", "lib", "toolchain.sh"), "utf8");
const readVar = (k, fb) => (toolchain.match(new RegExp(`^${k}=(\\d+)`, "m"))?.[1] ?? fb);
const MIN_MAJOR = readVar("NODE_RUNTIME_FLOOR", "18");
const NODE_RECO = readVar("NODE_TARGET", "24");

// ES5 写法（不能用 ?./??/模板串里的可选链），保证在任何老 node 上都能执行到。
const banner = `(function () {
  var v = (process.versions && process.versions.node) || "0";
  var major = parseInt(String(v).split(".")[0], 10) || 0;
  if (major < ${MIN_MAJOR}) {
    console.error(
      "[minus-platform] 建议使用 Node ${NODE_RECO}，当前 v" +
        v +
        "（" +
        process.execPath +
        "）过旧。请升级到 Node ${NODE_RECO}（最低 " +
        ${MIN_MAJOR} +
        "）后重试。"
    );
    process.exit(1);
  }
})();`;

await build({
  entryPoints: ["index.js"],
  bundle: true,
  platform: "node",
  format: "cjs",
  target: "node12",
  outfile: "dist/minus-platform.cjs",
  banner: { js: banner },
});

console.error("[build] dist/minus-platform.cjs 生成完成");
