// scenario.mjs — 剧本 YAML 解析（零依赖的受限 YAML 子集解析器）
// 支持：嵌套 map（2 空格缩进）、字符串/数字/布尔标量、字符串列表（- item）、
// map 列表（- key: val）、块标量（key: | 后接缩进文本）。
// 剧本 schema 固定，不追求通用 YAML 兼容。

import fs from "node:fs";

export function parseYaml(text) {
  const lines = text.split("\n");
  const [value] = parseBlock(lines, 0, 0);
  return value;
}

function indentOf(line) {
  const m = line.match(/^( *)/);
  return m[1].length;
}

function isSkippable(line) {
  const t = line.trim();
  return t === "" || t.startsWith("#");
}

function parseScalar(raw) {
  let s = raw.trim();
  if (s === "") return "";
  // 去掉行尾注释（仅当不在引号内，简化处理：带引号的不剥注释）
  if (!s.startsWith('"') && !s.startsWith("'")) {
    const hash = s.search(/ #/);
    if (hash >= 0) s = s.slice(0, hash).trim();
  }
  if (
    (s.startsWith('"') && s.endsWith('"')) ||
    (s.startsWith("'") && s.endsWith("'"))
  ) {
    return s.slice(1, -1);
  }
  if (s === "true") return true;
  if (s === "false") return false;
  if (s === "null" || s === "~") return null;
  if (/^-?\d+$/.test(s)) return parseInt(s, 10);
  if (/^-?\d+\.\d+$/.test(s)) return parseFloat(s);
  return s;
}

// 解析块标量 |，返回 [text, nextIndex]
function parseBlockScalar(lines, start, parentIndent) {
  const collected = [];
  let i = start;
  let blockIndent = -1;
  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "") {
      collected.push("");
      i++;
      continue;
    }
    const ind = indentOf(line);
    if (ind <= parentIndent) break;
    if (blockIndent === -1) blockIndent = ind;
    collected.push(line.slice(blockIndent));
    i++;
  }
  // 去掉尾部空行
  while (collected.length && collected[collected.length - 1] === "") collected.pop();
  return [collected.join("\n") + "\n", i];
}

// 解析一个块（map 或 list），返回 [value, nextIndex]
function parseBlock(lines, start, indent) {
  let i = start;
  // 跳过空行确定块类型
  while (i < lines.length && isSkippable(lines[i])) i++;
  if (i >= lines.length) return [null, i];

  const isList = lines[i].trim().startsWith("- ") || lines[i].trim() === "-";
  return isList ? parseList(lines, i, indent) : parseMap(lines, i, indent);
}

function parseMap(lines, start, indent) {
  const obj = {};
  let i = start;
  while (i < lines.length) {
    const line = lines[i];
    if (isSkippable(line)) {
      i++;
      continue;
    }
    const ind = indentOf(line);
    if (ind < indent) break;
    if (ind > indent) throw new Error(`意外缩进（第 ${i + 1} 行）: ${line}`);
    const m = line.trim().match(/^([\w][\w.-]*):(.*)$/);
    if (!m) throw new Error(`无法解析的行（第 ${i + 1} 行）: ${line}`);
    const key = m[1];
    const rest = m[2].trim();
    if (rest === "|" || rest === "|-") {
      const [text, next] = parseBlockScalar(lines, i + 1, indent);
      obj[key] = text;
      i = next;
    } else if (rest === "") {
      const [val, next] = parseBlock(lines, i + 1, indent + 2);
      obj[key] = val;
      i = next;
    } else {
      obj[key] = parseScalar(rest);
      i++;
    }
  }
  return [obj, i];
}

function parseList(lines, start, indent) {
  const arr = [];
  let i = start;
  while (i < lines.length) {
    const line = lines[i];
    if (isSkippable(line)) {
      i++;
      continue;
    }
    const ind = indentOf(line);
    if (ind < indent) break;
    const t = line.trim();
    if (!t.startsWith("-")) break;
    const rest = t.slice(1).trim();
    if (rest === "") {
      const [val, next] = parseBlock(lines, i + 1, ind + 2);
      arr.push(val);
      i = next;
    } else if (/^[\w][\w.-]*:/.test(rest)) {
      // 列表项是 map：- key: val，后续更深缩进的行属于同一项
      const itemLines = [" ".repeat(ind + 2) + rest];
      let j = i + 1;
      while (j < lines.length) {
        if (isSkippable(lines[j])) {
          itemLines.push(lines[j]);
          j++;
          continue;
        }
        const jInd = indentOf(lines[j]);
        if (jInd <= ind) break;
        itemLines.push(lines[j]);
        j++;
      }
      const [val] = parseMap(itemLines, 0, ind + 2);
      arr.push(val);
      i = j;
    } else {
      arr.push(parseScalar(rest));
      i++;
    }
  }
  return [arr, i];
}

export function loadScenario(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  const sc = parseYaml(raw);
  // 基本校验
  for (const field of ["name", "brief", "persona", "steps", "answers"]) {
    if (sc[field] === undefined) {
      throw new Error(`剧本缺少必填字段: ${field}（${filePath}）`);
    }
  }
  if (typeof sc.steps !== "number" || sc.steps < 1) {
    throw new Error(`剧本 steps 必须是 >=1 的整数，收到: ${sc.steps}`);
  }
  sc.expect = sc.expect || {};
  sc.transcript_rules = sc.transcript_rules || [];
  return sc;
}
