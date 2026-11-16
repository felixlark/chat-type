#!/usr/bin/env node

import { existsSync, readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";
import assert from "node:assert/strict";

const root = resolve(import.meta.dirname, "..");
const html = readFileSync(resolve(root, "docs", "index.html"), "utf8");
const assets = [
  resolve(root, "docs", "assets", "chattype-recording.png"),
  resolve(root, "docs", "assets", "chattype-result.png"),
];

function includes(text, label = text) {
  assert.ok(html.includes(text), `landing page must include ${label}`);
}

function hasAnchor(id) {
  const pattern = new RegExp(`id=["']${id}["']`);
  assert.ok(pattern.test(html), `landing page must include #${id}`);
}

function hasHref(href) {
  const pattern = new RegExp(`href=["']${href.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}["']`);
  assert.ok(pattern.test(html), `landing page must link to ${href}`);
}

assert.match(html, /<html\s+lang=["']zh-CN["']/, "landing page should be Chinese-first");
includes("ChatType", "product name");
includes("F5", "F5 workflow");
includes("ChatGPT", "preserved ChatGPT account path");
includes("豆包", "current default provider");
includes("失败不会自动切换服务", "explicit provider selection");
includes("公开 v0.5.1 下载包可能早于当前实现", "source candidate versus public download version");
assert.ok(!html.includes("默认走本机 ChatGPT 登录态"), "landing page must not advertise the retired default");
includes("剪贴板", "clipboard fallback");
includes("不是稳定公开 API", "private backend boundary");
includes("local-first", "local-first positioning");
includes("输入层", "input-layer positioning");
assert.ok(!/Responsay|Fayan|Famo/i.test(html), "landing page must not contain source inspiration brand copy");

for (const id of [
  "hero",
  "demo",
  "why",
  "comparison",
  "model",
  "privacy",
  "trust",
  "download",
]) {
  hasAnchor(id);
}

hasHref("https://github.com/felixlark/chat-type/releases/tag/v0.5.1");
hasHref("https://github.com/felixlark/chat-type");
hasHref("#demo");
hasHref("#download");

assert.ok(!html.includes("#0f1722"), "landing page should not use the old dark launch theme");
assert.ok(!html.includes("border-radius: 28px"), "landing page should avoid oversized card styling");

for (const asset of assets) {
  assert.ok(existsSync(asset), `${asset} must exist`);
  assert.ok(statSync(asset).size > 20_000, `${asset} must be a non-empty image asset`);
}

console.log("landing page content contract passed");
