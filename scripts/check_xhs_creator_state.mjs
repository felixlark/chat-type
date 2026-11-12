#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import process from "node:process";
import { setTimeout as delay } from "node:timers/promises";

const DEFAULT_CREATOR_URL = "https://creator.xiaohongshu.com/new/note-manager?source=official";
const DEBUG_HOST = "127.0.0.1";
const DEBUG_PORT = "9223";
const DEBUG_URL = `http://${DEBUG_HOST}:${DEBUG_PORT}`;
const EXPECTED_PROFILE_DIR = "/Users/longbiao/.chrome-use/browser-data/stable";
const CHROME_AUTH_OPEN_URL_CANDIDATES = [
  "/Users/longbiao/.codex/skills/chrome-auth/scripts/open_url.sh",
  "/Users/longbiao/.agents/skills/chrome-auth/scripts/open_url.sh",
  "/Users/longbiao/Projects/chrome-use/skills/chrome-auth/scripts/open_url.sh",
];
const PLACE_BROWSER = "/Users/longbiao/Projects/dock-switch/scripts/place-computer-use-browser.js";

const LOGIN_HINTS = ["短信登录", "登 录", "登录", "验证码", "扫码", "二维码", "解锁创作者专属功能"];
const RISK_HINTS = ["实名", "绑定手机号", "绑定手机", "安全验证", "账号异常", "处罚", "违规", "广告投放", "充值", "付费"];
const AUTH_HINTS = ["笔记管理", "发布笔记", "草稿箱", "发布图文", "上传图文"];
const DEMO_KEYWORDS = ["ChatType", "chat-type", "longbiaochen", "Codex", "F5", "语音输入", "听写", "回填", "剪贴板", "AI时代", "长句"];
let requestedCreatorUrl = DEFAULT_CREATOR_URL;

function parseArgs(argv) {
  const flags = {
    url: DEFAULT_CREATOR_URL,
    open: true,
    repair: true,
    place: true,
    json: true,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--url") {
      flags.url = argv[index + 1] || DEFAULT_CREATOR_URL;
      index += 1;
    } else if (arg === "--no-open") {
      flags.open = false;
    } else if (arg === "--no-repair") {
      flags.repair = false;
    } else if (arg === "--no-place") {
      flags.place = false;
    } else if (arg === "--human") {
      flags.json = false;
    } else if (arg === "--json") {
      flags.json = true;
    } else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return flags;
}

function printUsage() {
  console.log(`Usage:
  node scripts/check_xhs_creator_state.mjs [--json] [--human] [--no-open] [--no-repair] [--no-place] [--url <creator-url>]

Legacy note:
  This script belongs to the old chrome-auth / Chrome for Testing workflow.
  Daily Xiaohongshu operations now use IAB first, official Chrome only for a documented regular-profile exception, and Computer Use for native or same-browser visible recovery.
  Do not use this script as the first step or sole blocker for promotion operations.

Statuses:
  authenticated   Chrome for Testing is on the managed profile and Xiaohongshu creator state is readable.
  login_required  Creator page redirected to login, SMS login, QR code, or verification flow.
  risk_prompt     Real-name, phone binding, security, payment, ad, or platform-risk prompt is visible.
  wrong_profile   127.0.0.1:9223 is owned by the wrong Chrome for Testing profile.
  no_session      No Chrome DevTools endpoint is available and --no-open was used.
  unknown         Page loaded, but the safe state could not be classified.`);
}

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...options,
  }).trim();
}

function resolveFirstExisting(paths) {
  return paths.find((path) => existsSync(path)) || null;
}

function listChromeProcesses() {
  const output = run("ps", ["-axo", "pid=,command="]);
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const match = line.match(/^(\d+)\s+(.+)$/);
      return match ? { pid: Number(match[1]), command: match[2] } : null;
    })
    .filter(Boolean);
}

function isChromeForTestingRoot(command) {
  return (
    command.includes("Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing") &&
    !command.includes("Helper") &&
    command.includes(`--remote-debugging-port=${DEBUG_PORT}`)
  );
}

function getEndpointOwners() {
  return listChromeProcesses()
    .filter((item) => isChromeForTestingRoot(item.command))
    .map((item) => ({
      pid: item.pid,
      expectedProfile: item.command.includes(`--user-data-dir=${EXPECTED_PROFILE_DIR}`),
      hasUserDataDir: item.command.includes("--user-data-dir="),
    }));
}

async function fetchJson(url, timeoutMs = 1500) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) {
      throw new Error(`${response.status} ${response.statusText}`);
    }
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}

async function endpointReady() {
  try {
    await fetchJson(`${DEBUG_URL}/json/version`, 1000);
    return true;
  } catch {
    return false;
  }
}

function classifyOwner() {
  const owners = getEndpointOwners();
  const expectedOwners = owners.filter((owner) => owner.expectedProfile);
  if (owners.length === 0) {
    return { status: "no_session", owners };
  }
  if (owners.length === 1 && expectedOwners.length === 1) {
    return { status: "expected_profile", owners };
  }
  return { status: "wrong_profile", owners };
}

async function waitForEndpointGone(timeoutMs = 6000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (!(await endpointReady())) {
      return true;
    }
    await delay(250);
  }
  return false;
}

async function stopWrongProfileOwners(ownerState) {
  for (const owner of ownerState.owners) {
    if (!owner.expectedProfile) {
      try {
        process.kill(owner.pid, "SIGTERM");
      } catch {}
    }
  }
  await waitForEndpointGone();
}

function openManagedCreator(url) {
  const openUrl = resolveFirstExisting(CHROME_AUTH_OPEN_URL_CANDIDATES);
  if (!openUrl) {
    const error = new Error("chrome_auth_open_url_missing");
    error.code = "CHROME_AUTH_OPEN_URL_MISSING";
    throw error;
  }
  run("bash", [openUrl, url], { timeout: 90000 });
}

function placeBrowserWindow() {
  try {
    run("node", [PLACE_BROWSER], { timeout: 8000 });
  } catch {
    // Placement is helpful but not required for auth-state classification.
  }
}

function eventDataToString(event) {
  const data = event && "data" in Object(event) ? event.data : event;
  if (typeof data === "string") {
    return data;
  }
  if (Buffer.isBuffer(data)) {
    return data.toString("utf8");
  }
  if (data instanceof ArrayBuffer) {
    return Buffer.from(data).toString("utf8");
  }
  return String(data);
}

function createProtocolSession(wsUrl) {
  const socket = new WebSocket(wsUrl);
  const pending = new Map();
  let messageId = 1;

  const opened = new Promise((resolve, reject) => {
    socket.addEventListener("open", () => resolve());
    socket.addEventListener("error", () => reject(new Error("WebSocket connection failed")));
  });

  socket.addEventListener("message", (event) => {
    const raw = eventDataToString(event);
    let message;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (!message.id || !pending.has(message.id)) {
      return;
    }
    const item = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) {
      item.reject(new Error(message.error.message || "CDP request failed"));
    } else {
      item.resolve(message.result);
    }
  });

  return {
    async send(method, params = {}) {
      await opened;
      return new Promise((resolve, reject) => {
        const id = messageId;
        messageId += 1;
        pending.set(id, { resolve, reject });
        socket.send(JSON.stringify({ id, method, params }));
      });
    },
    close() {
      socket.close();
    },
  };
}

async function findCreatorTab() {
  let lastError = null;
  const started = Date.now();
  while (Date.now() - started < 20000) {
    try {
      const tabs = await fetchJson(`${DEBUG_URL}/json/list`, 5000);
      const pages = tabs.filter((tab) => tab.type === "page");
      const tab =
        pages.find((page) => (page.url || "").includes("creator.xiaohongshu.com/new/note-manager")) ||
        pages.find((page) => (page.url || "").includes("creator.xiaohongshu.com/login")) ||
        pages.find((page) => (page.url || "").includes("creator.xiaohongshu.com")) ||
        null;
      if (tab) {
        return tab;
      }
    } catch (error) {
      lastError = error;
    }
    await delay(500);
  }
  if (lastError) {
    throw lastError;
  }
  return null;
}

async function snapshotPage(tab) {
  const session = createProtocolSession(tab.webSocketDebuggerUrl);
  try {
    await session.send("Runtime.enable");
    const result = await session.send("Runtime.evaluate", {
      returnByValue: true,
      expression: `(() => {
        const text = document.body ? document.body.innerText : "";
        const lines = text.split(/\\n+/).map((line) => line.trim()).filter(Boolean);
        return {
          url: location.href,
          title: document.title,
          textLength: text.length,
          lines,
        };
      })()`,
    });
    return result.result.value;
  } finally {
    session.close();
  }
}

function containsAny(text, words) {
  const lower = text.toLowerCase();
  return words.filter((word) => lower.includes(word.toLowerCase()));
}

function summarizeLines(lines) {
  return lines
    .filter((line) => !/二维码|验证码|密码|手机号|cookie|token|短信|扫码/i.test(line))
    .filter((line) => !/^[A-Za-z][A-Za-z0-9_-]{0,31}$/.test(line))
    .slice(0, 24);
}

function classifyPage(snapshot) {
  const text = snapshot.lines.join("\n");
  const loginHits = containsAny(text, LOGIN_HINTS);
  const riskHits = containsAny(text, RISK_HINTS);
  const authHits = containsAny(text, AUTH_HINTS);
  const demoKeywordHits = containsAny(text, DEMO_KEYWORDS);
  const draftMatch = text.match(/草稿箱\((\d+)\)/);

  if ((snapshot.url || "").includes("/login") || loginHits.length > 0) {
    return {
      status: "login_required",
      loginHits,
      riskHits: [],
      authHits,
      demoKeywordHits,
      draftCount: draftMatch ? Number(draftMatch[1]) : null,
    };
  }
  if (riskHits.length > 0) {
    return {
      status: "risk_prompt",
      loginHits: [],
      riskHits,
      authHits,
      demoKeywordHits,
      draftCount: draftMatch ? Number(draftMatch[1]) : null,
    };
  }
  if ((snapshot.url || "").includes("creator.xiaohongshu.com") && authHits.length > 0) {
    return {
      status: "authenticated",
      loginHits: [],
      riskHits: [],
      authHits,
      demoKeywordHits,
      draftCount: draftMatch ? Number(draftMatch[1]) : null,
    };
  }
  return {
    status: "unknown",
    loginHits,
    riskHits,
    authHits,
    demoKeywordHits,
    draftCount: draftMatch ? Number(draftMatch[1]) : null,
  };
}

function buildResult(overrides) {
  return {
    checkedAt: new Date().toISOString(),
    debugUrl: DEBUG_URL,
    expectedProfileDir: EXPECTED_PROFILE_DIR,
    creatorUrl: requestedCreatorUrl,
    ...overrides,
  };
}

function printResult(result, json) {
  if (json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  console.log(`小红书创作端状态：${result.status}`);
  if (result.page?.url) {
    console.log(`页面：${result.page.url}`);
  }
  if (result.owner?.status) {
    console.log(`Chrome profile：${result.owner.status}`);
  }
}

async function main() {
  const flags = parseArgs(process.argv.slice(2));
  requestedCreatorUrl = flags.url;
  const initialOwner = classifyOwner();
  const ready = await endpointReady();

  if (flags.open && ready && initialOwner.status === "wrong_profile") {
    if (!flags.repair) {
      printResult(buildResult({ status: "wrong_profile", owner: initialOwner }), flags.json);
      return;
    }
    await stopWrongProfileOwners(initialOwner);
  }

  if (flags.open) {
    try {
      openManagedCreator(flags.url);
    } catch (error) {
      if (error.code === "CHROME_AUTH_OPEN_URL_MISSING") {
        printResult(
          buildResult({
            status: "no_session",
            owner: initialOwner,
            reason: "chrome_auth_open_url_missing",
            missingCandidates: CHROME_AUTH_OPEN_URL_CANDIDATES,
          }),
          flags.json,
        );
        return;
      }
      throw error;
    }
    if (flags.place) {
      placeBrowserWindow();
    }
  } else if (!ready) {
    printResult(buildResult({ status: "no_session", owner: initialOwner }), flags.json);
    return;
  }

  const owner = classifyOwner();
  if (owner.status === "wrong_profile") {
    printResult(buildResult({ status: "wrong_profile", owner }), flags.json);
    return;
  }
  if (owner.status === "no_session") {
    printResult(buildResult({ status: "no_session", owner }), flags.json);
    return;
  }

  const tab = await findCreatorTab();
  if (!tab) {
    printResult(buildResult({ status: "unknown", owner, page: null, reason: "creator_tab_not_found" }), flags.json);
    return;
  }

  const snapshot = await snapshotPage(tab);
  const pageState = classifyPage(snapshot);
  printResult(
    buildResult({
      status: pageState.status,
      owner,
      page: {
        url: snapshot.url,
        title: snapshot.title,
        textLength: snapshot.textLength,
        safeLines: summarizeLines(snapshot.lines),
      },
      signals: {
        loginHits: pageState.loginHits,
        riskHits: pageState.riskHits,
        authHits: pageState.authHits,
        demoKeywordHits: pageState.demoKeywordHits,
        draftCount: pageState.draftCount,
      },
    }),
    flags.json,
  );
}

main().catch((error) => {
  const result = buildResult({
    status: "unknown",
    error: error.message,
  });
  console.log(JSON.stringify(result, null, 2));
  process.exitCode = 1;
});
