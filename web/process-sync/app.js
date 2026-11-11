"use strict";

const byId = (id) => document.getElementById(id);
const state = { csrf: "", data: null, tab: "audit", fingerprint: "", polling: false, auditEvents: [], modalPreparing: false, modalScope: null, modalEvents: new Set(), modalReadyHash: "" };
const utcInput = (date) => date.toISOString().slice(0, -1);
byId("end-time").value = utcInput(new Date(Date.now() - 60000));
byId("start-time").value = utcInput(new Date(Date.now() - 86400000));

function showError(message) {
  byId("error").textContent = message || "";
  byId("error").hidden = !message;
}

async function api(path, body = {}, extraHeaders = {}) {
  const response = await fetch(`/api/${path}`, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", "X-CSRF-Token": state.csrf, ...extraHeaders },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  if (!response.ok) {
    const failure = await response.json();
    throw new Error(failure.error || `Local request failed (${response.status}).`);
  }
  return response;
}

function text(tag, value, className) {
  const node = document.createElement(tag);
  node.textContent = value == null ? "" : String(value);
  if (className) node.className = className;
  return node;
}

function processName(id) {
  return state.data?.processes?.find((process) => process.typeId === id)?.name || id;
}

function setStep(step) {
  for (const name of ["connect", "scope", "review", "result"]) {
    const node = byId(`step-${name}`);
    if (name === step) node.setAttribute("aria-current", "step");
    else node.removeAttribute("aria-current");
  }
}

function populateProcesses(processes) {
  const previous = byId("source").value;
  byId("source").replaceChildren(new Option("Select a universal process", ""));
  for (const process of processes.filter((item) => item.customizationType === "inherited")) {
    byId("source").add(new Option(`${process.name} (${process.typeId.slice(0, 8)})`, process.typeId));
  }
  byId("source").value = previous;
  byId("inventory-count").textContent = `${processes.length} processes`;
  renderTargets();
}

function renderTargets() {
  const selected = new Set([...byId("targets").querySelectorAll("input:checked")].map((input) => input.value));
  const source = state.data?.processes?.find((process) => process.typeId === byId("source").value);
  byId("source-id").textContent = source?.typeId || "";
  byId("source-name").textContent = source?.name || "No process selected";
  byId("targets").replaceChildren();
  const targets = (state.data?.processes || []).filter((process) => process.customizationType === "inherited" && process.typeId !== source?.typeId && (!source || process.parentProcessTypeId === source.parentProcessTypeId));
  for (const process of targets) {
    const label = document.createElement("label");
    label.className = "target-choice";
    const input = document.createElement("input");
    input.type = "checkbox";
    input.value = process.typeId;
    input.checked = selected.has(process.typeId);
    input.disabled = !source;
    input.addEventListener("change", updateScopeCount);
    const details = text("span", process.name);
    details.append(text("small", process.typeId));
    label.append(input, details);
    byId("targets").append(label);
  }
  if (!targets.length) byId("targets").append(text("p", "No compatible inherited processes.", "empty-state"));
  updateScopeCount();
}

function updateScopeCount() {
  byId("scope-summary").textContent = `${byId("targets").querySelectorAll("input:checked").length} children selected`;
}

function invalidatePreview() {
  if (!state.data?.preview) return;
  state.data.preview = null;
  state.fingerprint = "";
  byId("review-section").hidden = true;
  byId("writer-pat").value = "";
  byId("approved-hash").value = "";
  setStep("scope");
}

function badge(value, kind = "neutral") {
  return text("span", value, `badge ${kind}`);
}

function valuesCell(before, after) {
  const details = document.createElement("details");
  details.append(text("summary", "Old / New"), text("pre", JSON.stringify({ old: before ?? null, new: after ?? null }, null, 2)));
  return details;
}

function reviewRows(plan) {
  if (state.tab === "audit") {
    return {
      headers: ["timestamp", "actionId", "details", "category", "categoryDisplayName"],
      rows: state.auditEvents.map((event) => [event.timestamp, event.actionId, event.details, event.category, event.categoryDisplayName]),
    };
  }
  if (state.tab === "changes") {
    return { headers: ["Source Entity", "Values", "Audit Event IDs"], rows: plan.changes.map((change) => [change.key, valuesCell(change.before, change.after), (change.evidence || []).filter(Boolean).join(", ") || "Unresolved"]) };
  }
  if (state.tab === "mappings") {
    return { headers: ["Entity", "Source Identity", "Child Process", "Child Identity"], rows: plan.mappings.map((mapping) => [mapping.key, mapping.source, processName(mapping.targetId), mapping.target]) };
  }
  return {
    headers: ["Child Process", "Entity", "Request", "Values"],
    rows: plan.operations.map((operation) => [processName(operation.targetId), operation.key, `${operation.method} ${operation.path}`, valuesCell(operation.before, operation.body)]),
  };
}

function renderTable() {
  const plan = state.data?.preview?.plan;
  if (!plan) return;
  const { headers, rows } = reviewRows(plan);
  const query = byId("filter").value.toLowerCase();
  byId("table-head").replaceChildren();
  const heading = document.createElement("tr");
  for (const title of headers) {
    const column = text("th", title);
    column.scope = "col";
    heading.append(column);
  }
  byId("table-head").append(heading);
  byId("table-body").replaceChildren();
  let visible = 0;
  for (const row of rows) {
    const searchText = row.map((value) => value instanceof Node ? value.textContent : String(value)).join(" ").toLowerCase();
    if (query && !searchText.includes(query)) continue;
    visible++;
    const tr = document.createElement("tr");
    row.forEach((value, index) => {
      const td = document.createElement("td");
      if (value instanceof Node) td.append(value);
      else td.textContent = value == null ? "" : String(value);
      td.setAttribute("data-label", headers[index]);
      tr.append(td);
    });
    byId("table-body").append(tr);
  }
  byId("empty-table").hidden = visible > 0;
  byId("table-caption").textContent = `${state.tab} review`;
  byId("review-panel").setAttribute("aria-labelledby", `tab-${state.tab}`);
}

function renderPreview(preview) {
  const plan = preview.plan;
  byId("review-section").hidden = false;
  byId("plan-mode").textContent = plan.mode === "adopt" ? "BASELINE ADOPTION" : "AUDIT-LED SYNC";
  byId("run-id").textContent = preview.runId;
  byId("metric-events").textContent = state.auditEvents.length;
  byId("metric-changes").textContent = plan.changes.length;
  byId("metric-operations").textContent = plan.operations.length;
  byId("metric-blockers").textContent = plan.blockers.length;
  byId("audit-window").textContent = `${plan.audit.startTime} to ${plan.audit.endTime} / ${plan.audit.pageCount} complete pages`;
  byId("blockers-section").hidden = !plan.blockers.length;
  byId("blockers").replaceChildren(...plan.blockers.map((message) => text("li", message)));
  byId("baseline-notice").hidden = plan.mode !== "adopt";
  byId("deferred-section").hidden = !plan.deferred.length;
  byId("deferred").replaceChildren(...plan.deferred.map((item) => text("li", `${processName(item.targetId)} / ${item.key}: ${item.reason}`)));
  byId("reconcile").hidden = !state.data.recoveryNeeded;
  byId("approval-form").hidden = plan.blockers.length > 0;
  byId("plan-hash").textContent = preview.hash;
  byId("target-count").textContent = `${plan.targetProcessIds.length} selected children`;
  const needsWriter = plan.mode === "sync" && plan.operations.length > 0;
  byId("writer-label").hidden = !needsWriter;
  byId("writer-pat").required = needsWriter;
  byId("apply-label").textContent = plan.mode === "adopt" ? "Approve & Adopt Baseline" : needsWriter ? "Approve & Synchronize" : "Verify & Advance Checkpoint";
  byId("approval-title").textContent = plan.mode === "adopt" ? "Baseline Approval" : "Exact Plan Approval";
  byId("approved-hash").value = "";
  byId("writer-pat").value = "";
  byId("mappings-confirmed").checked = false;
  byId("confirmed").checked = false;
  renderTable();
}

function renderResult(result) {
  byId("result-section").hidden = false;
  byId("result-status").textContent = result.status;
  byId("result-status").className = `badge ${result.status === "stopped" ? "danger" : result.status === "stage-verified" ? "amber" : ""}`;
  byId("result-message").textContent = result.message;
  byId("result-run").textContent = result.runId ? `Local run: ${result.runId}` : "";
  byId("results-body").replaceChildren();
  for (const count of result.counts || []) {
    const row = document.createElement("tr");
    for (const value of [processName(count.targetId), count.planned, count.applied, count.verified, count.noOp, count.failed]) row.append(text("td", value));
    byId("results-body").append(row);
  }
}

function render(data) {
  const hadConnection = state.data?.connected;
  const priorProcesses = JSON.stringify(state.data?.processes);
  state.data = data;
  const running = data.state === "running";
  byId("busy").hidden = !running;
  byId("progress").textContent = data.progress || "Reading Azure DevOps";
  byId("connect").disabled = running;
  byId("scan").disabled = running;
  byId("apply").disabled = running;
  byId("download").disabled = running;
  byId("reconcile").disabled = running;
  byId("view-audit-raw").disabled = running || !data.connected || !data.rawAuditAvailable;
  if (!data.connected || (!data.rawAuditAvailable && !running && !state.modalPreparing)) {
    byId("audit-raw-dialog").close();
    byId("audit-raw-json").textContent = "";
  }
  byId("logout").disabled = !data.connected && !running;
  byId("scope-form").inert = running;
  byId("approval-form").inert = running;
  byId("session-org").textContent = data.connected ? data.organization : "";
  byId("connection-status").textContent = data.connected ? "Connected" : "Disconnected";
  byId("connection-status").className = `badge ${data.connected ? "" : "neutral"}`;
  byId("connection-section").hidden = data.connected;
  byId("scope-section").hidden = !data.connected;
  if (data.connected && (!hadConnection || JSON.stringify(data.processes) !== priorProcesses)) populateProcesses(data.processes);
  if (data.connected) byId("session-expiry").textContent = `Session expires ${new Date(data.expiresAt).toISOString().slice(11, 16)} UTC`;
  else byId("session-expiry").textContent = "PAT storage: session memory only";
  showError(data.error);
  if (data.preview) {
    if (state.fingerprint !== data.preview.hash) { state.fingerprint = data.preview.hash; renderPreview(data.preview); }
    setStep("review");
  } else {
    byId("review-section").hidden = true;
    state.fingerprint = "";
    setStep(data.connected ? "scope" : "connect");
  }
  if (data.result) { renderResult(data.result); if (!data.preview) setStep("result"); }
  else byId("result-section").hidden = true;
  if (state.modalPreparing && byId("audit-raw-dialog").open) {
    byId("audit-sync-status").textContent = data.progress || "Resolving audit changes for selected children...";
    if (!running) finishModalPreparation();
  }
  return running;
}

async function poll() {
  if (state.polling) return;
  state.polling = true;
  try {
    const data = await (await api("status")).json();
    state.auditEvents = [];
    if (data.connected && data.rawAuditAvailable && data.state !== "running") {
      const pages = await (await api("audit-raw")).json();
      state.auditEvents = universalAuditEvents(pages);
    }
    if (render(data)) window.setTimeout(poll, 800);
  } catch (error) { showError(error.message); }
  finally { state.polling = false; }
}

async function startJob(path, body) {
  showError("");
  byId("busy").hidden = false;
  byId("progress").textContent = "Starting request";
  for (const id of ["connect", "scan", "apply", "reconcile"]) byId(id).disabled = true;
  try { await api(path, body); await poll(); }
  catch (error) {
    byId("busy").hidden = true;
    for (const id of ["connect", "scan", "apply", "reconcile"]) byId(id).disabled = false;
    showError(error.message);
    if (state.modalPreparing) {
      state.modalPreparing = false;
      byId("audit-sync-status").textContent = error.message;
      byId("sync-children").disabled = false;
    }
  }
}

byId("connect-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const readerPat = byId("reader-pat").value;
  byId("reader-pat").value = "";
  await startJob("connect", { organization: byId("organization").value.trim(), readerPat });
});

byId("source").addEventListener("change", () => {
  for (const input of byId("targets").querySelectorAll("input")) input.checked = false;
  renderTargets();
});
byId("scope-form").addEventListener("input", invalidatePreview);
byId("end-now").addEventListener("click", () => { byId("end-time").value = utcInput(new Date()); invalidatePreview(); });

byId("scope-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const start = new Date(`${byId("start-time").value}Z`);
  const end = new Date(`${byId("end-time").value}Z`);
  if (!(start < end) || start < new Date(Date.now() - 90 * 86400000) || end > new Date()) { showError("Choose increasing UTC times within the past 90 days."); return; }
  await startJob("read-audit", { sourceProcessId: byId("source").value, startTime: start.toISOString(), endTime: end.toISOString() });
});

byId("approval-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (byId("audit-raw-dialog").open) {
    const blocker = modalPlanBlocker();
    if (blocker || state.modalReadyHash !== state.data?.preview?.hash) { byId("audit-sync-status").textContent = blocker || "The plan changed. Close this dialog and read audit again."; return; }
    if (!byId("confirmed").checked) return;
    byId("approved-hash").value = state.modalReadyHash;
    byId("mappings-confirmed").checked = true;
  }
  if (byId("approved-hash").value !== state.data?.preview?.hash) {
    const message = "Approval SHA256 does not match the displayed exact plan.";
    showError(message);
    if (byId("audit-raw-dialog").open) byId("audit-sync-status").textContent = message;
    return;
  }
  const approval = { hash: byId("approved-hash").value, confirmed: byId("confirmed").checked, mappingsConfirmed: byId("mappings-confirmed").checked, writerPat: byId("writer-pat").value };
  byId("writer-pat").value = "";
  if (byId("audit-raw-dialog").open) byId("audit-raw-dialog").close();
  await startJob("apply", approval);
});

function selectedChildren() {
  return [...byId("targets").querySelectorAll("input:checked")].map((input) => input.value);
}

function modalPlanBlocker() {
  const plan = state.data?.preview?.plan;
  if (!plan) return state.data?.error || "No change plan could be prepared. No writes occurred.";
  const selected = selectedChildren();
  if (!state.data.connected || state.data.state === "running" || !state.modalScope || plan.sourceProcessId !== state.modalScope.sourceProcessId || plan.sourceProcessId !== byId("source").value || selected.length !== plan.targetProcessIds.length || selected.some((id) => !plan.targetProcessIds.includes(id))) return "The selected source or children changed. Read audit again.";
  if (plan.blockers.length) return `Synchronization blocked: ${plan.blockers.join(" ")}`;
  if (!plan.audit.complete || Date.parse(plan.audit.startTime) !== Date.parse(state.modalScope.startTime) || Date.parse(plan.audit.endTime) !== Date.parse(state.modalScope.endTime) || Date.parse(plan.audit.startTime) !== Date.parse(`${byId("start-time").value}Z`) || Date.parse(plan.audit.endTime) !== Date.parse(`${byId("end-time").value}Z`)) return "The audit window changed or is incomplete. Read audit again.";
  for (const operation of plan.operations) {
    const change = plan.changes.find((item) => item.key === operation.key);
    if (!selected.includes(operation.targetId) || !change?.evidence?.length || change.evidence.some((id) => !state.modalEvents.has(id))) return "A planned change has no matching event in the displayed Universal Audit Events. Read audit again before synchronizing.";
  }
  return "";
}

function setModalApproval(enabled) {
  byId("approval-hash-label").hidden = enabled;
  byId("approved-hash").required = !enabled;
  byId("approval-mappings-label").hidden = enabled;
  byId("mappings-confirmed").required = !enabled;
  byId("approval-confirmation-text").textContent = enabled
    ? "I approve the exact plan identified by the SHA256 above, its source-to-child mappings, and the impact on projects using the selected children."
    : "I approve this exact plan for the selected children.";
}

function finishModalPreparation() {
  state.modalPreparing = false;
  const blocker = modalPlanBlocker();
  byId("sync-children").disabled = Boolean(blocker);
  if (blocker) { byId("audit-sync-status").textContent = blocker; return; }
  const preview = state.data.preview;
  const plan = preview.plan;
  state.modalReadyHash = preview.hash;
  byId("audit-sync-status").textContent = plan.mode === "adopt" ? "First run: approve baseline adoption only. This does not apply the listed historical events or change child templates." : `${plan.operations.length} supported operations / ${plan.deferred.length} deferred changes. Confirm the exact changes before applying.`;
  byId("audit-sync-plan-section").hidden = false;
  byId("audit-sync-plan-section").open = true;
  byId("audit-sync-plan").textContent = JSON.stringify({ changes: plan.changes, mappings: plan.mappings, operations: plan.operations, deferred: plan.deferred, noOps: plan.noOps, impact: plan.impact }, null, 2);
  byId("sync-children-label").textContent = plan.mode === "adopt" ? "Approve Baseline" : plan.operations.length ? "Confirm & Sync Childs" : "Verify Children";
  byId("audit-sync-approval").append(byId("approval-form"));
  setModalApproval(true);
}

byId("sync-children").addEventListener("click", async () => {
  if (state.modalPreparing) return;
  if (state.modalReadyHash) { byId("approval-form").requestSubmit(); return; }
  const targetProcessIds = selectedChildren();
  const audit = state.modalScope;
  if (!targetProcessIds.length || !audit || !state.modalEvents.size) { byId("audit-sync-status").textContent = "Select child processes and read audit before synchronizing."; return; }
  if (audit.sourceProcessId !== byId("source").value || Date.parse(audit.startTime) !== Date.parse(`${byId("start-time").value}Z`) || Date.parse(audit.endTime) !== Date.parse(`${byId("end-time").value}Z`)) { byId("audit-sync-status").textContent = "The source or audit window changed. Read audit again."; return; }
  state.modalPreparing = true;
  byId("sync-children").disabled = true;
  byId("audit-sync-status").textContent = "Resolving audit changes for selected children...";
  await startJob("preview", { ...audit, targetProcessIds, auditEventIds: [...state.modalEvents] });
});

function universalAuditEvents(pages) {
  return pages.flatMap((page) => (page.value ?? page).decoratedAuditLogEntries ?? [])
    .filter((entry) => {
      const name = entry.data?.ProcessName ?? entry.ProcessName;
      return typeof name === "string" && name.toLowerCase() === "universal";
    })
    .sort((first, second) => {
      const firstTime = Date.parse(first.timestamp);
      const secondTime = Date.parse(second.timestamp);
      if (!Number.isFinite(firstTime)) return Number.isFinite(secondTime) ? 1 : 0;
      if (!Number.isFinite(secondTime)) return -1;
      return firstTime - secondTime;
    });
}

byId("view-audit-raw").addEventListener("click", async () => {
  const button = byId("view-audit-raw");
  button.disabled = true;
  try {
    const pages = await (await api("audit-raw")).json();
    if (!state.data?.connected || !state.data?.rawAuditAvailable) return;
    const events = universalAuditEvents(pages);
    byId("audit-events-body").replaceChildren(...events.map((entry) => {
      const row = document.createElement("tr");
      for (const field of ["timestamp", "actionId", "details", "category", "categoryDisplayName"]) row.append(text("td", entry[field]));
      return row;
    }));
    byId("audit-events-empty").hidden = events.length > 0;
    byId("audit-raw-json").textContent = JSON.stringify(pages, null, 2);
    state.modalScope = state.data.auditRead ? { ...state.data.auditRead } : null;
    state.modalEvents = new Set(events.map((event) => event.id).filter(Boolean));
    state.modalReadyHash = "";
    byId("audit-sync-children").replaceChildren(...selectedChildren().map((id) => {
      const item = text("li", processName(id));
      item.append(text("small", id, "identifier"));
      return item;
    }));
    byId("sync-children-label").textContent = "Sync Childs";
    byId("sync-children").disabled = !state.modalScope || !state.modalEvents.size || !selectedChildren().length;
    byId("audit-sync-status").textContent = selectedChildren().length ? "Ready to resolve audit changes for the selected children. No writes have occurred." : "Select child processes before synchronizing.";
    byId("audit-sync-plan-section").hidden = true;
    byId("audit-raw-dialog").showModal();
  } catch (error) { showError(error.message); }
  finally { button.disabled = state.data?.state === "running" || !state.data?.connected || !state.data?.rawAuditAvailable; }
});
byId("audit-raw-dialog").addEventListener("close", () => {
  if (byId("audit-sync-approval").contains(byId("approval-form"))) {
    byId("deferred-section").after(byId("approval-form"));
    setModalApproval(false);
    byId("writer-pat").value = "";
    byId("approved-hash").value = "";
    byId("confirmed").checked = false;
    byId("mappings-confirmed").checked = false;
  }
  state.modalPreparing = false;
  state.modalReadyHash = "";
  state.modalScope = null;
  state.modalEvents.clear();
  byId("audit-sync-children").replaceChildren();
  byId("audit-sync-plan").textContent = "";
  byId("audit-raw-json").textContent = "";
  byId("audit-events-body").replaceChildren();
  if (!byId("view-audit-raw").disabled) byId("view-audit-raw").focus();
});
byId("filter").addEventListener("input", renderTable);
const tabs = [...document.querySelectorAll("[data-tab]")];
function selectTab(tab) {
  state.tab = tab.dataset.tab;
  for (const item of tabs) { item.setAttribute("aria-selected", String(item === tab)); item.tabIndex = item === tab ? 0 : -1; }
  renderTable();
}
for (const tab of tabs) {
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    const offset = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
    if (!offset) return;
    event.preventDefault();
    const next = tabs[(tabs.indexOf(tab) + offset + tabs.length) % tabs.length];
    selectTab(next); next.focus();
  });
}
byId("cancel").addEventListener("click", async () => {
  try { await api("cancel"); byId("progress").textContent = "Stopping after current operation"; } catch (error) { showError(error.message); }
});
byId("reconcile").addEventListener("click", () => startJob("reconcile", {}));
byId("logout").addEventListener("click", async () => {
  try { await api("logout"); byId("reader-pat").value = ""; byId("writer-pat").value = ""; await poll(); } catch (error) { showError(error.message); }
});
byId("download").addEventListener("click", async () => {
  try {
    const blob = await (await api("plan")).blob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a"); link.href = url; link.download = "process-sync-plan.json"; link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (error) { showError(error.message); }
});

(async () => {
  try {
    const key = new URLSearchParams(location.hash.slice(1)).get("key") || "";
    history.replaceState(null, "", location.pathname);
    const session = await (await api("session", {}, key ? { "X-Bootstrap-Token": key } : {})).json();
    state.csrf = session.csrf;
    await poll();
  } catch (error) { showError(error.message); }
})();