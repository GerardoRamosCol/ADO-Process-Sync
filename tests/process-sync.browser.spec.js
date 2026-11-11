const { test, expect } = require("@playwright/test");
const { spawn } = require("node:child_process");
const { once } = require("node:events");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");

const sourceId = "11111111-1111-1111-1111-111111111111";
const targetId = "22222222-2222-2222-2222-222222222222";
const parentId = "33333333-3333-3333-3333-333333333333";
const hash = "a".repeat(64);

async function mockApi(page, options = {}) {
  const calls = [];
  const processes = [
    { typeId: sourceId, name: "Universal Engineering", customizationType: "inherited", parentProcessTypeId: parentId },
    { typeId: targetId, name: options.targetName || "Finance & Delivery Child", customizationType: "inherited", parentProcessTypeId: parentId },
    { typeId: "44444444-4444-4444-4444-444444444444", name: "Different System Parent", customizationType: "inherited", parentProcessTypeId: "55555555-5555-5555-5555-555555555555" },
  ];
  const mode = options.mode || "adopt";
  const operation = { targetId, key: "wit:Bug", category: "WorkItemType", method: "PATCH", path: `work/processes/${targetId}/workItemTypes/System.Bug`, before: { description: "Old description" }, body: { description: "Approved description" } };
  const plan = {
    mode, sourceProcessId: sourceId, targetProcessIds: [targetId], blockers: options.blockers || [], deferred: [], noOps: [],
    operations: mode === "sync" && !options.blockers?.length ? [operation] : [],
    changes: mode === "sync" ? [{ key: "wit:Bug", before: operation.before, after: operation.body, evidence: [options.outsideAudit ? "unlisted-event" : "event-1"] }] : [],
    mappings: [{ key: "wit:Bug", source: "System.Bug", target: "System.Bug", targetId }],
    audit: { startTime: "2026-10-29T12:00:00Z", endTime: "2026-10-30T12:00:00Z", pageCount: 2, complete: true, events: [{ id: "event-1", timestamp: "2026-10-30T11:00:00.0000000+00:00", actionId: "Process.WorkItemType.Update", data: { ProcessId: sourceId, WorkItemTypeReferenceName: "System.Bug" } }] },
  };
  const data = { state: "ready", connected: false, organization: "test-org", processes: [], progress: "", error: null, preview: null, result: null, recoveryNeeded: false, expiresAt: new Date(Date.now() + 1800000).toISOString() };
  await page.route("**/api/**", async (route) => {
    const request = route.request();
    const kind = new URL(request.url()).pathname.slice(5);
    const body = request.postDataJSON() || {};
    calls.push({ kind, body });
    if (kind === "session") return route.fulfill({ json: { csrf: "fake-csrf" } });
    if (kind === "connect") { data.connected = true; data.processes = processes; }
    if (kind === "read-audit") {
      data.rawAuditAvailable = true; data.preview = null; data.result = null; data.error = null;
      data.auditRead = { ...body };
    }
    if (kind === "preview") {
      plan.audit.startTime = body.startTime;
      plan.audit.endTime = body.endTime;
      data.rawAuditAvailable = true;
      data.preview = options.previewError ? null : { hash, runId: "20261030T120000Z-local-run", plan };
      data.error = options.previewError || null;
    }
    if (kind === "audit-raw") return route.fulfill({ json: [
      { decoratedAuditLogEntries: [{ ...plan.audit.events[0], data: { ProcessName: "Universal" }, details: '<img src=x onerror="window.injected=true">', category: "Modify", categoryDisplayName: "Modify process", actorDisplayName: "Example Actor" }, { id: "child-event", actionId: "Process.Child.Update", data: { ProcessName: "Child" } }], hasMore: true, continuationToken: "page-2" },
      { decoratedAuditLogEntries: [{ id: "other-event", actionId: "Project.Update" }, { id: "lowercase-event", timestamp: "2026-10-30T12:30:00+02:00", actionId: "Process.Rule.Update", data: { ProcessName: "universal" }, details: "Rule changed", category: "Modify", categoryDisplayName: "Modify process" }], hasMore: false, continuationToken: null },
    ] });
    if (kind === "apply") {
      data.preview = null;
      data.result = {
        status: mode === "adopt" ? "adopted" : "verified",
        message: mode === "adopt" ? "Baseline adopted. No Azure DevOps writes occurred." : "All selected children verified. Baseline advanced.",
        runId: "20261030T120000Z-local-run",
        counts: mode === "adopt" ? [] : [{ targetId, planned: 1, applied: 1, verified: 1, noOp: 0, failed: 0 }],
      };
    }
    if (kind === "logout") { data.connected = false; data.processes = []; data.preview = null; data.result = null; data.rawAuditAvailable = false; }
    return route.fulfill({ json: kind === "status" ? data : { status: "accepted" } });
  });
  return calls;
}

async function connectAndPreview(page, expectPreview = true, keepModal = false) {
  await page.goto("/#key=fake-bootstrap");
  await page.locator("#organization").fill("test-org");
  await page.locator("#reader-pat").fill("offline-fake-reader");
  await page.getByRole("button", { name: "Connect", exact: true }).click();
  await expect(page.locator("#scope-section")).toBeVisible();
  await expect(page.locator("#reader-pat")).toHaveValue("");
  await page.locator("#source").selectOption(sourceId);
  await expect(page.getByText("Different System Parent", { exact: true })).toHaveCount(0);
  await page.locator(`#targets input[value="${targetId}"]`).check();
  await expect(page.locator("#impact")).toHaveCount(0);
  await page.getByRole("button", { name: "Read Audit", exact: true }).click();
  await expect(page.locator("#view-audit-raw")).toBeEnabled();
  await page.locator("#view-audit-raw").click();
  await page.locator("#sync-children").click();
  if (expectPreview) await expect(page.locator("#review-section")).toBeVisible();
  else await expect(page.locator("#error")).not.toBeHidden();
  if (!keepModal) await page.getByRole("dialog").getByRole("button", { name: "Close", exact: true }).click();
}

test("modal Sync Childs resolves audit changes without a separate preview action", async ({ page }) => {
  const calls = await mockApi(page, { mode: "sync" });
  await page.goto("/#key=fake-bootstrap");
  await page.locator("#organization").fill("test-org");
  await page.locator("#reader-pat").fill("offline-fake-reader");
  await page.getByRole("button", { name: "Connect", exact: true }).click();
  await page.locator("#source").selectOption(sourceId);
  await page.getByRole("button", { name: "Read Audit", exact: true }).click();
  await expect(page.locator("#view-audit-raw")).toBeEnabled();
  expect(calls.filter((call) => call.kind === "preview")).toHaveLength(0);
  await page.locator(`#targets input[value="${targetId}"]`).check();
  await page.locator("#view-audit-raw").click();
  await expect(page.locator("#sync-children")).toBeEnabled();
  await expect(page.locator("#audit-sync-children")).toContainText(targetId);
  await page.locator("#sync-children").click();
  await expect(page.locator("#audit-sync-approval #approval-form")).toBeVisible();
  expect(calls.filter((call) => call.kind === "preview")).toHaveLength(1);
  expect(calls.find((call) => call.kind === "preview").body.auditEventIds).toEqual(["lowercase-event", "event-1"]);
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
  await expect(page.locator("#approved-hash")).toBeHidden();
  await expect(page.locator("#mappings-confirmed")).toBeHidden();
  await expect(page.locator("#plan-hash")).toHaveText(hash);
  await expect(page.locator("#approval-confirmation-text")).toContainText("source-to-child mappings");
  await page.locator("#writer-pat").fill("offline-fake-writer");
  await page.locator("#sync-children").click();
  await expect(page.locator("#confirmed")).toBeFocused();
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
  await page.locator("#confirmed").check();
  await page.locator("#sync-children").click();
  await expect(page.locator("#result-status")).toHaveText("verified");
  expect(calls.find((call) => call.kind === "apply").body).toEqual({ hash, confirmed: true, mappingsConfirmed: true, writerPat: "offline-fake-writer" });
  await expect(page.locator("#writer-pat")).toHaveValue("");
});

test("modal baseline adoption uses one confirmation and no writer PAT", async ({ page }) => {
  const calls = await mockApi(page);
  await connectAndPreview(page, true, true);
  await expect(page.locator("#sync-children")).toHaveText("Approve Baseline");
  await expect(page.locator("#audit-sync-status")).toContainText("does not apply the listed historical events");
  await expect(page.locator("#approved-hash")).toBeHidden();
  await expect(page.locator("#mappings-confirmed")).toBeHidden();
  await expect(page.locator("#writer-label")).toBeHidden();
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
  await page.locator("#confirmed").check();
  await page.locator("#sync-children").click();
  await expect(page.locator("#result-status")).toHaveText("adopted");
  expect(calls.find((call) => call.kind === "apply").body).toEqual({ hash, confirmed: true, mappingsConfirmed: true, writerPat: "" });
});

test("modal confirmation cannot approve a changed plan hash", async ({ page }) => {
  const calls = await mockApi(page, { mode: "sync" });
  await connectAndPreview(page, true, true);
  await page.locator("#confirmed").check();
  await page.locator("#writer-pat").fill("offline-fake-writer");
  await page.evaluate(() => { state.data.preview.hash = "b".repeat(64); });
  await page.locator("#sync-children").click();
  await expect(page.locator("#audit-sync-status")).toContainText("The plan changed");
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
  await expect(page.getByRole("dialog")).toBeVisible();
});

test("baseline adoption needs exact approval and never a writer PAT", async ({ page }) => {
  const calls = await mockApi(page);
  await connectAndPreview(page);
  await expect(page.locator("#writer-label")).toBeHidden();
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
  await page.locator("#approved-hash").fill("0".repeat(64));
  await page.locator("#mappings-confirmed").check();
  await page.locator("#confirmed").check();
  await page.locator("#apply").click();
  await expect(page.getByRole("alert")).toHaveText("Approval SHA256 does not match the displayed exact plan.");
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
  await page.locator("#approved-hash").fill(hash);
  await page.locator("#apply").click();
  await expect(page.locator("#result-status")).toHaveText("adopted");
  const approved = calls.find((call) => call.kind === "apply").body;
  expect(approved).toEqual({ hash, confirmed: true, mappingsConfirmed: true, writerPat: "" });
});

test("sync review supports mappings, filtering, and a separate cleared writer input", async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const calls = await mockApi(page, { mode: "sync" });
  await connectAndPreview(page);
  await page.getByRole("tab", { name: "Changes", exact: true }).click();
  await page.locator("#table-body summary").click();
  await expect(page.locator("#table-body")).toContainText("Approved description");
  await page.getByRole("tab", { name: "Mappings", exact: true }).click();
  await expect(page.locator("#table-body")).toContainText("System.Bug");
  await page.locator("#filter").fill("no match");
  await expect(page.locator("#empty-table")).toBeVisible();
  await page.locator("#filter").fill("");
  await page.screenshot({ path: testInfo.outputPath("desktop-review.png"), fullPage: true });
  await page.locator("#approved-hash").fill(hash);
  await page.locator("#mappings-confirmed").check();
  await page.locator("#confirmed").check();
  await page.locator("#writer-pat").fill("offline-fake-writer");
  await page.locator("#apply").click();
  await expect(page.locator("#result-status")).toHaveText("verified");
  await expect(page.locator("#writer-pat")).toHaveValue("");
  expect(calls.find((call) => call.kind === "apply").body.writerPat).toBe("offline-fake-writer");
  expect(await page.evaluate(() => [localStorage.length, sessionStorage.length])).toEqual([0, 0]);
});

test("blocked plans expose reasons and cannot be approved", async ({ page }) => {
  const calls = await mockApi(page, { mode: "sync", blockers: ["Destructive state deletion is blocked."] });
  await connectAndPreview(page, true, true);
  await expect(page.locator("#audit-sync-status")).toContainText("Destructive state deletion is blocked.");
  await expect(page.locator("#sync-children")).toBeDisabled();
  await expect(page.locator("#blockers")).toContainText("Destructive state deletion is blocked.");
  await expect(page.locator("#approval-form")).toBeHidden();
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
});

test("modal rejects operations outside the displayed Universal audit events", async ({ page }) => {
  const calls = await mockApi(page, { mode: "sync", outsideAudit: true });
  await connectAndPreview(page, true, true);
  await expect(page.locator("#audit-sync-status")).toContainText("no matching event in the displayed Universal Audit Events");
  await expect(page.locator("#sync-children")).toBeDisabled();
  await expect(page.locator("#audit-sync-approval #approval-form")).toHaveCount(0);
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
});

for (const width of [1440, 390]) {
  test(`modal synchronization approval fits and clears on close at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    const calls = await mockApi(page, { mode: "sync" });
    await connectAndPreview(page, true, true);
    const modal = page.getByRole("dialog");
    await expect(page.locator("#audit-sync-approval #approval-form")).toBeVisible();
    await expect(page.locator("#audit-sync-plan")).toContainText("Approved description");
    expect(await modal.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.locator("#writer-pat").fill("offline-fake-writer");
    await page.locator("#confirmed").check();
    await page.locator("#sync-children").scrollIntoViewIfNeeded();
    await page.screenshot({ path: testInfo.outputPath("modal-sync-approval.png") });
    await page.keyboard.press("Escape");
    await expect(modal).not.toBeVisible();
    await expect(page.locator("#writer-pat")).toHaveValue("");
    await expect(page.locator("#approved-hash")).toHaveValue("");
    await expect(page.locator("#audit-sync-plan")).toBeEmpty();
    expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
  });
}

test("process metadata is escaped and mobile layout has no page overflow", async ({ page }, testInfo) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mockApi(page, { mode: "sync", targetName: '<img src=x onerror="window.injected=true">' });
  await connectAndPreview(page);
  await page.getByRole("tab", { name: "Mappings", exact: true }).click();
  await expect(page.locator("#table-body")).toContainText("<img");
  expect(await page.evaluate(() => window.injected)).toBeUndefined();
  expect(await page.locator("#table-body img").count()).toBe(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  expect(await page.locator("img").evaluateAll((images) => images.every((image) => image.complete && image.naturalWidth > 0))).toBe(true);
  await page.screenshot({ path: testInfo.outputPath("mobile-review.png"), fullPage: true });
});

test("disconnect clears the visible authenticated workflow", async ({ page }) => {
  await mockApi(page);
  await connectAndPreview(page);
  await page.getByRole("button", { name: "Disconnect and clear credentials" }).click();
  await expect(page.locator("#connection-section")).toBeVisible();
  await expect(page.locator("#review-section")).toBeHidden();
  await expect(page.locator("#connection-status")).toHaveText("Disconnected");
});

test("editing scope discards the visible approval and entered writer PAT", async ({ page }) => {
  const calls = await mockApi(page, { mode: "sync" });
  await connectAndPreview(page);
  await page.locator("#writer-pat").fill("offline-fake-writer");
  await page.locator("#end-now").click();
  await expect(page.locator("#review-section")).toBeHidden();
  await expect(page.locator("#writer-pat")).toHaveValue("");
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
});

for (const width of [1440, 390]) {
  test(`raw audit modal shows all pages safely at ${width}px`, async ({ page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    const calls = await mockApi(page);
    await connectAndPreview(page);
    await expect(page.locator("#view-audit-raw")).toBeEnabled();
    await expect(page.locator("#metric-events")).toHaveText("2");
    await expect(page.locator("#table-head")).toHaveText("timestampactionIddetailscategorycategoryDisplayName");
    await expect(page.locator("#table-body tr")).toHaveCount(2);
    await expect(page.locator("#table-body tr td:first-child")).toHaveText(["2026-10-30T12:30:00+02:00", "2026-10-30T11:00:00.0000000+00:00"]);
    await expect(page.locator("#table-body tr td:nth-child(2)")).toHaveText(["Process.Rule.Update", "Process.WorkItemType.Update"]);
    await expect(page.locator("#table-body")).not.toContainText("Process.Child.Update");
    await page.getByRole("button", { name: "View Raw Audit JSON" }).click();
    const modal = page.getByRole("dialog", { name: "Raw Audit API Response" });
    await expect(modal).toBeVisible();
    await expect(page.locator("#audit-events-body tr")).toHaveCount(2);
    await expect(modal.getByRole("columnheader", { name: "timestamp", exact: true })).toBeVisible();
    await expect(page.locator("#audit-events-body tr td:first-child")).toHaveText(["2026-10-30T12:30:00+02:00", "2026-10-30T11:00:00.0000000+00:00"]);
    await expect(page.locator("#audit-events-body tr td:nth-child(2)")).toHaveText(["Process.Rule.Update", "Process.WorkItemType.Update"]);
    await expect(page.locator("#audit-events-body")).toContainText("Rule changed");
    await expect(page.locator("#audit-events-body")).toContainText("Modify process");
    await expect(page.locator("#audit-events-body")).not.toContainText("Process.Child.Update");
    await expect(page.locator("#audit-events-body")).not.toContainText("Project.Update");
    await expect(page.locator("#audit-events-body img")).toHaveCount(0);
    const pages = JSON.parse(await page.locator("#audit-raw-json").textContent());
    expect(pages).toHaveLength(2);
    expect(pages[1].decoratedAuditLogEntries[0].actionId).toBe("Project.Update");
    await expect(page.locator("#audit-raw-json")).toContainText("actorDisplayName");
    expect(await page.locator("#audit-raw-json img").count()).toBe(0);
    expect(await page.evaluate(() => window.injected)).toBeUndefined();
    const bounds = await modal.boundingBox();
    expect(bounds.x).toBeGreaterThanOrEqual(0);
    expect(bounds.x + bounds.width).toBeLessThanOrEqual(width);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath("raw-audit-modal.png") });
    await page.keyboard.press("Escape");
    await expect(modal).not.toBeVisible();
    await expect(page.locator("#view-audit-raw")).toBeFocused();
    await expect(page.locator("#audit-raw-json")).toBeEmpty();
    await page.locator("#view-audit-raw").click();
    await modal.getByRole("button", { name: "Close", exact: true }).click();
    await expect(modal).not.toBeVisible();
    await page.locator("#logout").click();
    await expect(page.locator("#view-audit-raw")).toBeDisabled();
  });
}

test("raw audit remains available after snapshot failure", async ({ page }) => {
  const calls = await mockApi(page, { previewError: "Ambiguous or missing identity for Rule. Explicit mapping is required." });
  await connectAndPreview(page, false, true);
  await expect(page.locator("#audit-sync-status")).toContainText("Ambiguous or missing identity for Rule");
  await expect(page.locator("#sync-children")).toBeDisabled();
  expect(calls.filter((call) => call.kind === "apply")).toHaveLength(0);
  await page.getByRole("dialog").getByRole("button", { name: "Close", exact: true }).click();
  await expect(page.locator("#error")).toContainText("Ambiguous or missing identity");
  await expect(page.locator("#review-section")).toBeHidden();
  await page.locator("#view-audit-raw").click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(page.locator("#audit-raw-json")).toContainText("decoratedAuditLogEntries");
});

test("real localhost routes reject missing origin, bootstrap, and arbitrary paths", async ({ request }) => {
  expect((await request.post("/api/session", { data: {} })).status()).toBe(403);
  expect((await request.post("/api/session", { headers: { Origin: "http://127.0.0.1:8895", "X-Bootstrap-Token": "wrong" }, data: {} })).status()).toBe(403);
  expect((await request.post("/api/status", { headers: { Origin: "http://127.0.0.1:8895" }, data: {} })).status()).toBe(403);
  expect((await request.post("/api/audit-raw", { headers: { Origin: "http://127.0.0.1:8895" }, data: {} })).status()).toBe(403);
  expect((await request.get("/README.md")).status()).toBe(403);
  const home = await request.get("/");
  expect(home.headers()["content-security-policy"]).toContain("frame-ancestors 'none'");
  expect(home.headers()["cache-control"]).toBe("no-store");
});

test("real server exchanges its one-time bootstrap for a cookie and enforces CSRF", async ({ playwright }) => {
  const store = await fs.mkdtemp(path.join(os.tmpdir(), "ado-session-test-"));
  const server = spawn("pwsh", ["-NoLogo", "-NoProfile", "-File", "scripts/Start-AdoProcessSyncApp.ps1", "-NoBrowser", "-Port", "8897", "-StoreRoot", store], { cwd: path.resolve(__dirname, ".."), windowsHide: true });
  let context;
  try {
    const launch = await new Promise((resolve, reject) => {
      let output = "";
      const timeout = setTimeout(() => reject(new Error("Local session test server did not start.")), 15000);
      server.once("error", (error) => { clearTimeout(timeout); reject(error); });
      server.once("exit", () => { clearTimeout(timeout); reject(new Error("Local session test server exited before startup.")); });
      server.stdout.on("data", (chunk) => {
        output += chunk.toString();
        const match = output.match(/(http:\/\/127\.0\.0\.1:\d+)\/#key=([a-f0-9]{64})/);
        if (match) { clearTimeout(timeout); resolve({ origin: match[1], key: match[2] }); }
      });
      server.stderr.resume();
    });
    context = await playwright.request.newContext({ baseURL: launch.origin, extraHTTPHeaders: { Origin: launch.origin } });
    const handshake = await context.post("/api/session", { headers: { "X-Bootstrap-Token": launch.key }, data: {} });
    expect(handshake.status()).toBe(200);
    expect(handshake.headers()["set-cookie"]).toContain("HttpOnly; SameSite=Strict");
    const { csrf } = await handshake.json();
    expect((await context.post("/api/status", { data: {} })).status()).toBe(403);
    const state = await context.post("/api/status", { headers: { "X-CSRF-Token": csrf }, data: {} });
    expect(state.status()).toBe(200);
    expect(await state.json()).toMatchObject({ connected: false, state: "ready", preview: null });
    expect((await context.post("/api/audit-raw", { headers: { "X-CSRF-Token": csrf }, data: {} })).status()).toBe(401);
    expect((await context.post("/api/connect", { headers: { "X-CSRF-Token": csrf }, data: { organization: "../escape", readerPat: "offline-fake-reader" } })).status()).toBe(400);
    expect((await context.post("/api/preview", { headers: { "X-CSRF-Token": csrf }, data: {} })).status()).toBe(401);
    expect((await context.post("/api/read-audit", { headers: { "X-CSRF-Token": csrf }, data: {} })).status()).toBe(401);
    const unauthenticated = await playwright.request.newContext({ baseURL: launch.origin, extraHTTPHeaders: { Origin: launch.origin } });
    try { expect((await unauthenticated.post("/api/session", { headers: { "X-Bootstrap-Token": launch.key }, data: {} })).status()).toBe(403); }
    finally { await unauthenticated.dispose(); }
    expect((await context.post("/api/logout", { headers: { "X-CSRF-Token": csrf }, data: {} })).status()).toBe(200);
  } finally {
    if (context) await context.dispose();
    if (server.exitCode === null) { server.kill(); await once(server, "exit"); }
    await fs.rm(store, { recursive: true, force: true });
  }
});