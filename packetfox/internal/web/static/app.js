"use strict";

// ---------- helpers ----------

const $ = (id) => document.getElementById(id);

function h(tag, props, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "text") el.textContent = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k in el && typeof v !== "string") el[k] = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

async function api(path, opts = {}) {
  const init = { ...opts, headers: { "X-PacketFox": "1", ...(opts.headers || {}) } };
  if (opts.json !== undefined) {
    init.method = init.method || "POST";
    init.body = JSON.stringify(opts.json);
    init.headers["Content-Type"] = "application/json";
  }
  const res = await fetch(path, init);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(body.error || res.statusText);
    err.status = res.status;
    throw err;
  }
  return body;
}

function msg(text) { $("sb-msg").textContent = text || ""; }

const STATUS_LABEL = {
  delivered: "delivered", consumed: "to router", dropped: "DROPPED", lost: "LOST",
  "in-flight": "in flight", seen: "seen",
};

function badge(status, text) {
  return h("span", { class: "badge st-" + status, text: text || STATUS_LABEL[status] || status });
}

function fmtTime(ts) {
  const d = new Date(ts * 1000);
  const pad = (n, w = 2) => String(n).padStart(w, "0");
  const frac = (ts % 1).toFixed(6).slice(2);
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${frac}`;
}

function fmtMs(ms) {
  if (ms === undefined || ms === null) return "";
  const a = Math.abs(ms);
  if (a < 1) return (ms * 1000).toFixed(0) + " µs";
  if (a < 1000) return ms.toFixed(a < 10 ? 2 : 1) + " ms";
  return (ms / 1000).toFixed(2) + " s";
}

// ---------- state ----------

const state = {
  inventory: null,
  sessionId: null,
  meta: null,
  running: false,
  filter: "",
  rows: [],
  exhausted: false,
  loading: false,
  selected: null,
  points: {},
  detail: null,
};

const PAGE = 500;
const ROW_H = 20;
const COL_WIDTHS = ["64px", "118px", "190px", "150px", "150px", "80px", "60px", "120px", "auto"];

for (const id of ["cols-head", "cols-body"]) {
  for (const w of COL_WIDTHS) $(id).append(h("col", { style: undefined }));
  [...$(id).children].forEach((c, i) => (c.style.width = COL_WIDTHS[i]));
}

// ---------- sessions ----------

async function loadSessions(selectId) {
  const list = await api("/api/sessions");
  const sel = $("session-select");
  sel.replaceChildren();
  if (list.length === 0) sel.append(h("option", { value: "", text: "No captures yet" }));
  for (const m of list) {
    const label = `${m.id}${m.name ? " — " + m.name : ""} (${m.frames} pkts${m.ended ? "" : ", live"})`;
    sel.append(h("option", { value: m.id, text: label }));
  }
  const want = selectId || state.sessionId || (list[0] && list[0].id);
  if (want) {
    sel.value = want;
    if (want !== state.sessionId) await openSession(want);
  }
}

async function openSession(id) {
  state.sessionId = id;
  state.rows = [];
  state.exhausted = false;
  state.selected = null;
  $("rows").replaceChildren();
  $("list-spacer").style.height = "0px";
  renderPath(null);
  $("tree").replaceChildren();
  $("hex").replaceChildren();
  if (!id) return;
  $("btn-download").href = `/api/sessions/${id}/pcapng`;
  $("btn-download").hidden = false;
  await refreshMeta();
  await fetchMore();
  refreshInsights();
}

async function refreshMeta() {
  if (!state.sessionId) return;
  const meta = await api(`/api/sessions/${state.sessionId}`);
  state.meta = meta;
  state.points = Object.fromEntries((meta.points || []).map((p) => [p.id, p]));
  state.running = !meta.ended;
  $("btn-stop").hidden = !state.running;
  $("btn-delete").hidden = state.running;
  const st = $("capture-status");
  st.className = "status" + (state.running ? " live" : "");
  st.textContent = state.running ? "Capturing" : meta.stop_reason ? `Ended: ${meta.stop_reason}` : "";
  $("sb-frames").textContent = `${meta.frames} packets`;
  const srcs = $("sb-sources");
  srcs.replaceChildren(
    ...(meta.sources || []).map((s) =>
      h("span", { class: "src " + s.state, title: s.message || s.state, text: `${s.device} (${s.packets})` + (s.state === "error" ? `: ${s.message}` : "") }),
    ),
  );
}

// ---------- packet list ----------

function pointLabel(id) {
  return (state.points[id] && state.points[id].label) || id;
}

async function fetchMore() {
  if (state.loading || state.exhausted || !state.sessionId) return;
  state.loading = true;
  const sid = state.sessionId;
  const filter = state.filter;
  try {
    const q = new URLSearchParams({ skip: state.rows.length, limit: PAGE, filter });
    const res = await api(`/api/sessions/${sid}/frames?${q}`);
    if (sid !== state.sessionId || filter !== state.filter) return;
    state.rows.push(...res.rows);
    // While capturing, more may come later
    state.exhausted = res.rows.length < PAGE && !state.running;
    $("list-empty").textContent = state.rows.length === 0 ? (state.running ? "Waiting for packets…" : "No packets match.") : "";
    renderRows();
    if (res.rows.length > 0 && $("follow").checked && state.running) scrollToEnd();
  } catch (e) {
    if (e.status === 422) {
      $("list-empty").textContent = e.message;
    } else {
      msg(e.message);
    }
  } finally {
    state.loading = false;
  }
}

function scrollToEnd() {
  const sc = $("list-scroll");
  sc.scrollTop = sc.scrollHeight;
}

function renderRows() {
  const sc = $("list-scroll");
  const total = state.rows.length;
  $("list-spacer").style.height = total * ROW_H + "px";
  const first = Math.max(0, Math.floor(sc.scrollTop / ROW_H) - 20);
  const last = Math.min(total, Math.ceil((sc.scrollTop + sc.clientHeight) / ROW_H) + 20);
  const body = $("list-body");
  body.style.top = first * ROW_H + "px";
  const tb = $("rows");
  tb.replaceChildren();
  const selJourney = state.detail && state.detail.journey ? state.detail.journey.id : 0;
  for (let i = first; i < last; i++) {
    const r = state.rows[i];
    const tr = h(
      "tr",
      {
        class: [r.num === state.selected ? "sel" : "", selJourney && r.journey === selJourney ? "journey" : ""].join(" "),
        onclick: () => selectFrame(r.num),
      },
      h("td", { text: r.num }),
      h("td", { text: fmtTime(r.ts) }),
      h("td", { text: pointLabel(r.point), title: pointLabel(r.point) }),
      h("td", { text: r.src, title: r.src }),
      h("td", { text: r.dst, title: r.dst }),
      h("td", { text: r.proto }),
      h("td", { text: r.len }),
      h("td", {}, r.journey ? [h("span", { class: "muted", text: `${r.hop}/${r.hops} ` }), badge(r.status)] : ""),
      h("td", { text: r.info, title: r.info }),
    );
    if (r.bg) for (const td of tr.children) td.style.background = "#" + r.bg;
    if (r.fg) for (const td of tr.children) td.style.color = "#" + r.fg;
    tb.append(tr);
  }
}

$("list-scroll").addEventListener("scroll", () => {
  renderRows();
  const sc = $("list-scroll");
  if (sc.scrollTop + sc.clientHeight > sc.scrollHeight - ROW_H * 50) fetchMore();
  if (sc.scrollTop + sc.clientHeight < sc.scrollHeight - ROW_H * 3) $("follow").checked = false;
});

document.addEventListener("keydown", (e) => {
  if (e.target.closest("input, select, textarea, dialog")) return;
  if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
  const i = state.rows.findIndex((r) => r.num === state.selected);
  const next = state.rows[i + (e.key === "ArrowDown" ? 1 : -1)];
  if (!next) return;
  e.preventDefault();
  selectFrame(next.num);
  const sc = $("list-scroll");
  const idx = state.rows.indexOf(next);
  if (idx * ROW_H < sc.scrollTop) sc.scrollTop = idx * ROW_H;
  if ((idx + 1) * ROW_H > sc.scrollTop + sc.clientHeight) sc.scrollTop = (idx + 1) * ROW_H - sc.clientHeight;
});

// ---------- display filter ----------

let checkTimer = null;
$("dfilter").addEventListener("input", () => {
  clearTimeout(checkTimer);
  const f = $("dfilter").value.trim();
  $("dfilter").className = "";
  if (!f || !state.sessionId) return;
  checkTimer = setTimeout(async () => {
    try {
      await api(`/api/sessions/${state.sessionId}/check?` + new URLSearchParams({ filter: f }));
      $("dfilter").className = "valid";
      $("dfilter").title = "";
    } catch (e) {
      $("dfilter").className = "invalid";
      $("dfilter").title = e.message;
    }
  }, 250);
});
$("dfilter").addEventListener("keydown", (e) => { if (e.key === "Enter") applyFilter($("dfilter").value.trim()); });
$("btn-apply").addEventListener("click", () => applyFilter($("dfilter").value.trim()));
$("btn-clear").addEventListener("click", () => { $("dfilter").value = ""; $("dfilter").className = ""; applyFilter(""); });

function applyFilter(f) {
  state.filter = f;
  state.rows = [];
  state.exhausted = false;
  $("list-scroll").scrollTop = 0;
  renderRows();
  fetchMore();
}

// ---------- selected packet ----------

async function selectFrame(num) {
  state.selected = num;
  renderRows();
  try {
    const d = await api(`/api/sessions/${state.sessionId}/frames/${num}`);
    if (state.selected !== num) return;
    state.detail = d;
    renderTree(d.detail);
    renderPath(d);
    renderRows();
  } catch (e) {
    msg(e.message);
  }
}

function renderPath(d) {
  const el = $("path");
  if (!d) {
    el.replaceChildren(h("div", { class: "empty", text: "Select a packet to follow it through the network." }));
    return;
  }
  const j = d.journey;
  if (!j) {
    el.replaceChildren(h("div", { class: "empty", text: `Seen at ${pointLabel(d.point)}. Not an IP packet, so it isn't followed across capture points.` }));
    return;
  }
  const v = j.verdict;
  const head = h(
    "div",
    { class: "path-head" },
    badge(v.status),
    h("span", { class: "verdict", text: v.detail }),
    h("span", { class: "muted", text: `journey #${j.id} · ${j.proto || "IP"} · ${j.hops.length} hop${j.hops.length === 1 ? "" : "s"}` }),
    h("span", { class: "spacer" }),
    h("button", { class: "small", text: "Show journey in list", onclick: () => filterFrames(j.hops.map((x) => x.frame)) }),
  );
  const hops = h("div", { class: "hops" });
  j.hops.forEach((hop, i) => {
    if (i > 0) {
      hops.append(
        h(
          "div",
          { class: "link" },
          h("span", { class: hop.same_clock ? "" : "skew", text: (hop.delta_ms >= 0 ? "+" : "") + fmtMs(hop.delta_ms), title: hop.same_clock ? "Same clock: real transit time" : "Different clocks: includes clock skew between the devices" }),
          h("span", { class: "arrow", text: "→" }),
          hop.nat ? h("span", { class: "muted", text: "NAT" }) : "",
        ),
      );
    }
    const port = (a, p) => (p ? (a.includes(":") ? `[${a}]:${p}` : `${a}:${p}`) : a);
    hops.append(
      h(
        "div",
        { class: "hop" + (hop.frame === d.num ? " current" : ""), onclick: () => selectFrame(hop.frame), title: `Frame ${hop.frame}` },
        h("div", { class: "where", text: pointLabel(hop.point) }),
        h("div", { class: "addr" + (hop.nat ? " nat" : "") }, port(hop.src, hop.sport), " →"),
        h("div", { class: "addr" + (hop.nat ? " nat" : "") }, port(hop.dst, hop.dport)),
        h("div", { class: "ttl", text: `TTL ${hop.ttl} · ${fmtTime(hop.ts)}` }),
      ),
    );
  });
  if (v.status !== "in-flight") {
    hops.append(h("div", { class: "link" }, h("span", { class: "arrow", text: v.status === "delivered" || v.status === "consumed" ? "✓" : "✕" })));
    hops.append(
      h(
        "div",
        { class: "hop end " + v.status },
        h("div", { class: "where", text: STATUS_LABEL[v.status] }),
        v.expected ? h("div", { class: "addr", text: "expected at " + pointLabel(v.expected) }) : "",
      ),
    );
  }
  el.replaceChildren(head, hops);
}

function filterFrames(nums) {
  const uniq = [...new Set(nums)].slice(0, 2000);
  const f = `frame.number in {${uniq.join(", ")}}`;
  $("dfilter").value = f;
  $("dfilter").className = "valid";
  applyFilter(f);
}

// ---------- detail tree + hex ----------

let hexBytes = null;

function renderTree(detail) {
  const tree = $("tree");
  tree.replaceChildren();
  hexBytes = detail && detail.bytes ? Uint8Array.from(atob(detail.bytes), (c) => c.charCodeAt(0)) : null;
  renderHex(null);
  if (!detail || !detail.tree) return;
  const build = (nodes, depth) =>
    h(
      "ul",
      {},
      nodes.map((n) => {
        const kids = n.n && n.n.length > 0;
        const node = h("div", { class: ["node", n.t === "proto" ? "proto" : "", n.s ? "sev-" + n.s : ""].join(" "), text: n.l, title: n.f || "" });
        const li = h("li", { class: kids ? "has-kids" : "" }, node, kids ? build(n.n, depth + 1) : null);
        node.addEventListener("click", () => {
          tree.querySelectorAll(".node.sel").forEach((x) => x.classList.remove("sel"));
          node.classList.add("sel");
          if (kids) li.classList.toggle("open");
          renderHex(n.h && !n.ds ? n.h : null);
        });
        node.addEventListener("dblclick", () => {
          if (n.f) {
            $("dfilter").value = n.f;
            applyFilter(n.f);
          }
        });
        return li;
      }),
    );
  tree.append(build(detail.tree, 0));
}

function renderHex(range) {
  const el = $("hex");
  el.replaceChildren();
  if (!hexBytes) return;
  const [start, len] = range || [-1, 0];
  const inHl = (i) => i >= start && i < start + len;
  for (let off = 0; off < hexBytes.length; off += 16) {
    const line = h("div");
    line.append(h("span", { class: "off", text: off.toString(16).padStart(4, "0") + "  " }));
    let ascii = [];
    for (let i = off; i < off + 16; i++) {
      if (i >= hexBytes.length) {
        line.append("   ");
        continue;
      }
      const b = hexBytes[i];
      const span = h("span", { text: b.toString(16).padStart(2, "0") });
      if (inHl(i)) span.className = "hl";
      line.append(span, i === off + 7 ? "  " : " ");
      const ch = b >= 32 && b < 127 ? String.fromCharCode(b) : ".";
      ascii.push(inHl(i) ? h("span", { class: "hl", text: ch }) : ch);
    }
    line.append(" ", ...ascii);
    el.append(line);
  }
}

// ---------- insights ----------

async function refreshInsights() {
  const el = $("insights");
  if (!$("insights-toggle").checked || !state.sessionId) return;
  let s;
  try {
    s = await api(`/api/sessions/${state.sessionId}/summary`);
  } catch (e) {
    return;
  }
  const counts = h("div", { class: "counts" }, Object.entries(s.by_status || {}).map(([k, v]) => badge(k, `${STATUS_LABEL[k] || k}: ${v}`)));
  const problems = (s.problems || []).map((p) =>
    h(
      "button",
      { class: "problem", onclick: () => showProblem(p) },
      h("span", { class: "n", text: p.count }),
      badge(p.status),
      " ",
      h("span", { text: p.status === "dropped" ? `in ${pointLabel(p.at).split(" › ")[0]}` : `after ${pointLabel(p.at)}` }),
      h("div", { class: "d", text: p.expected ? `expected at ${pointLabel(p.expected)}` : p.detail }),
    ),
  );
  const lat = h(
    "table",
    { class: "lat" },
    h("tr", {}, h("th", { text: "Hop" }), h("th", { text: "n" }), h("th", { text: "p50" }), h("th", { text: "p95" })),
    (s.latency || []).slice(0, 30).map((l) =>
      h(
        "tr",
        { class: l.same_clock ? "" : "skew", title: l.same_clock ? "Same clock" : "Different clocks: includes clock skew" },
        h("td", { text: `${pointLabel(l.from)} → ${pointLabel(l.to)}` }),
        h("td", { class: "num", text: l.count }),
        h("td", { class: "num", text: fmtMs(l.p50_ms) }),
        h("td", { class: "num", text: fmtMs(l.p95_ms) }),
      ),
    ),
  );
  const m = state.meta || {};
  const f = m.filter || {};
  const desc = [
    (f.hosts || []).join(", "),
    (f.ports || []).length ? "ports " + f.ports.join(",") : "",
    f.protocol,
    f.bpf ? `BPF: ${f.bpf}` : "",
  ].filter(Boolean).join(" · ");
  el.replaceChildren(
    h("h3", { text: "Capture" }),
    h("div", { text: desc || "everything" }),
    h("div", { class: "muted", text: `${(m.points || []).length} capture points · by ${m.user || "?"}` }),
    h("h3", { text: `Journeys (${s.journeys})` }),
    counts,
    h("h3", { text: "Where packets go missing" }),
    ...(problems.length ? problems : [h("div", { class: "muted", text: "Nothing dropped or lost." })]),
    h("h3", { text: "Transit latency" }),
    s.latency && s.latency.length ? lat : h("div", { class: "muted", text: "No packet was seen at two points yet." }),
    h("p", { class: "muted", text: "Italic rows compare different clocks (hosts vs. the TZSP collector) and include their skew. Within one router or one host the numbers are real." }),
  );
}

async function showProblem(p) {
  const q = new URLSearchParams({ status: p.status, at: p.at, limit: 300 });
  const js = await api(`/api/sessions/${state.sessionId}/journeys?${q}`);
  const frames = js.flatMap((j) => j.hops.map((x) => x.frame));
  if (frames.length) {
    filterFrames(frames);
    selectFrame(js[0].hops[js[0].hops.length - 1].frame);
  }
}

$("insights-toggle").addEventListener("change", () => {
  $("insights").hidden = !$("insights-toggle").checked;
  refreshInsights();
});

// ---------- capture dialog ----------

const dlg = {
  targets: [], // {label, addrs}
  selected: new Set(),
};

function endpointByName(name) {
  return (state.inventory.endpoints || []).find((e) => e.name === name);
}

function endpointAddrs(e) {
  return e.interfaces.flatMap((i) => i.addresses.map((a) => a.split("/")[0]));
}

function addTarget(raw) {
  raw = raw.trim();
  if (!raw) return;
  const name = raw.split(" ")[0];
  const e = endpointByName(name);
  if (e) {
    dlg.targets.push({ label: e.name, addrs: endpointAddrs(e), endpoint: e });
  } else if (/^[0-9a-fA-F:.]+(\/\d+)?$/.test(raw)) {
    dlg.targets.push({ label: raw, addrs: [raw] });
  } else {
    $("capture-error").textContent = `Unknown host "${raw}"`;
    return;
  }
  $("capture-error").textContent = "";
  $("target-input").value = "";
  renderTargets();
}

function renderTargets() {
  $("targets").replaceChildren(
    ...dlg.targets.map((t, i) =>
      h(
        "span",
        { class: "chip" },
        h("span", { text: t.label }),
        t.endpoint ? h("span", { class: "addrs", text: t.addrs.join(" ") }) : "",
        h("button", { type: "button", text: "×", title: "Remove", onclick: () => { dlg.targets.splice(i, 1); renderTargets(); } }),
      ),
    ),
  );
}

$("btn-add-target").addEventListener("click", () => addTarget($("target-input").value));
$("target-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    e.preventDefault();
    addTarget($("target-input").value);
  }
});
$("target-input").addEventListener("change", () => {
  if (endpointByName($("target-input").value.split(" ")[0])) addTarget($("target-input").value);
});

function renderDevices() {
  const wrap = $("devices");
  wrap.replaceChildren();
  for (const d of state.inventory.devices) {
    const box = h("div", { class: "device" });
    const pts = h("div", { class: "pts" });
    const kind = { router: "router · TZSP", agent: "host · tcpdump", ap: "UniFi AP · tcpdump" }[d.kind];
    const discover = async () => {
      pts.replaceChildren(h("span", { class: "muted", text: "Discovering…" }));
      try {
        const nd = await api(`/api/devices/${encodeURIComponent(d.name)}/discover`, { method: "POST" });
        Object.assign(d, nd);
      } catch (e) {
        d.error = e.message;
      }
      fillPoints();
    };
    const fillPoints = () => {
      pts.replaceChildren();
      if (d.error) pts.append(h("div", { class: "err", text: d.error }));
      if (!d.points || d.points.length === 0) {
        if (!d.error) pts.append(h("span", { class: "muted", text: d.kind === "router" ? "" : "Not discovered yet" }));
        return;
      }
      const q = (search.value || "").toLowerCase();
      let lastNs = null;
      for (const p of d.points) {
        const nsLabel = p.netns_label || p.netns || "root netns";
        if (q && !`${nsLabel} ${p.iface} ${p.if_kind || ""}`.toLowerCase().includes(q)) continue;
        if (d.kind === "agent" && p.netns !== lastNs) {
          lastNs = p.netns;
          pts.append(h("div", { class: "ns", text: nsLabel, title: p.netns || "root netns" }));
        }
        const cb = h("input", { type: "checkbox", checked: dlg.selected.has(p.id) });
        cb.addEventListener("change", () => (cb.checked ? dlg.selected.add(p.id) : dlg.selected.delete(p.id)));
        p._cb = cb;
        const pf = p.if_kind === "sriov-pf";
        pts.append(
          h(
            "label",
            { title: pf ? "SR-IOV PF: traffic of its VFs is switched in the NIC and never shows up here. Capture the VF in the service's netns instead." : "" },
            cb,
            h("span", { text: p.chain ? (p.chain === "prerouting" ? "in (prerouting)" : "out (postrouting)") : p.iface }),
            p.if_kind ? h("span", { class: "ifkind" + (pf ? " warn" : ""), text: pf ? "SR-IOV PF ⚠" : p.if_kind }) : "",
            p.up === false ? h("span", { class: "ifkind", text: "down" }) : "",
          ),
        );
      }
    };
    const search = h("input", { type: "search", class: "pt-search", placeholder: "Filter namespaces and interfaces", hidden: d.kind !== "agent" });
    search.addEventListener("input", () => fillPoints());
    d._discover = discover;
    d._fill = fillPoints;
    box.append(
      h(
        "div",
        { class: "device-head" },
        h("span", { text: d.name }),
        h("span", { class: "kind", text: kind }),
        h("span", { class: "spacer" }),
        d.kind !== "router" ? h("button", { type: "button", class: "small", text: d.points && d.points.length ? "Refresh" : "Discover", onclick: discover }) : "",
      ),
      search,
      pts,
    );
    fillPoints();
    wrap.append(box);
  }
}

async function suggestPoints() {
  const inv = state.inventory;
  for (const d of inv.devices) if (d.kind === "router") d.points.forEach((p) => dlg.selected.add(p.id));
  // The hosts behind each target, in their own netns
  const wanted = [];
  for (const t of dlg.targets) {
    if (!t.endpoint) continue;
    const dev = inv.devices.find((d) => d.kind === "agent" && d.name === t.endpoint.system);
    if (dev) wanted.push({ dev, netns: t.endpoint.netns });
  }
  for (const { dev, netns } of wanted) {
    if (!dev.points || dev.points.length === 0) await dev._discover();
    for (const p of dev.points || []) {
      // A service: its own netns (with its VF on SR-IOV hosts). A root
      // netns host: the uplinks.
      const uplink = ["physical", "sriov-pf", "bridge", "vlan", "bond", "device"].includes(p.if_kind || "physical");
      if (netns ? p.netns === netns : p.netns === "" && uplink) dlg.selected.add(p.id);
    }
  }
  inv.devices.forEach((d) => d._fill && d._fill());
}
$("btn-suggest").addEventListener("click", suggestPoints);

async function openCaptureDialog() {
  state.inventory = await api("/api/inventory");
  const dl = $("endpoint-list");
  dl.replaceChildren(
    ...state.inventory.endpoints.map((e) => {
      const fq = e.interfaces.flatMap((i) => i.fqdns)[0] || "";
      return h("option", { value: e.name, text: `${fq} ${endpointAddrs(e).join(" ")}` });
    }),
  );
  const f = $("capture-form");
  if (!f.max_packets.value) f.max_packets.value = state.inventory.limits.max_packets;
  $("capture-error").textContent = "";
  renderTargets();
  renderDevices();
  $("capture-dialog").showModal();
}
$("btn-new").addEventListener("click", () => openCaptureDialog().catch((e) => msg(e.message)));

$("capture-form").addEventListener("submit", async (e) => {
  if (e.submitter && e.submitter.value !== "start") return;
  e.preventDefault();
  const f = e.target;
  const ports = f.ports.value.split(/[ ,]+/).filter(Boolean).map(Number);
  const req = {
    name: f.name.value.trim(),
    filter: {
      hosts: dlg.targets.flatMap((t) => t.addrs),
      ports,
      protocol: f.protocol.value,
      bpf: f.bpf.value.trim(),
    },
    points: [...dlg.selected],
    snaplen: Number(f.snaplen.value) || 0,
    max_packets: Number(f.max_packets.value) || 0,
    max_duration: f.duration.value.trim(),
  };
  $("btn-start").disabled = true;
  try {
    const meta = await api("/api/capture", { json: req });
    $("capture-dialog").close();
    $("dfilter").value = "";
    state.filter = "";
    $("follow").checked = true;
    await loadSessions(meta.id);
  } catch (err) {
    $("capture-error").textContent = err.message;
  } finally {
    $("btn-start").disabled = false;
  }
});

// ---------- toolbar ----------

$("session-select").addEventListener("change", () => openSession($("session-select").value));
$("btn-stop").addEventListener("click", async () => {
  $("btn-stop").disabled = true;
  msg("Stopping and removing router rules…");
  try {
    await api("/api/capture/stop", { method: "POST" });
    msg("");
  } catch (e) {
    msg(e.message);
  }
  $("btn-stop").disabled = false;
  await refreshMeta();
  state.exhausted = false;
  fetchMore();
  loadSessions();
});
$("btn-delete").addEventListener("click", async () => {
  if (!state.sessionId || !confirm(`Delete capture ${state.sessionId}?`)) return;
  await api(`/api/sessions/${state.sessionId}`, { method: "DELETE" });
  state.sessionId = null;
  await loadSessions();
});

// Splitters resize the pane above them
for (const sp of document.querySelectorAll(".splitter")) {
  sp.addEventListener("pointerdown", (e) => {
    const target = $(sp.dataset.target);
    const startY = e.clientY;
    const startH = target.getBoundingClientRect().height;
    sp.setPointerCapture(e.pointerId);
    const move = (ev) => {
      target.style.flex = "none";
      target.style.height = Math.max(60, startH + ev.clientY - startY) + "px";
      renderRows();
    };
    const up = () => {
      sp.removeEventListener("pointermove", move);
      sp.removeEventListener("pointerup", up);
    };
    sp.addEventListener("pointermove", move);
    sp.addEventListener("pointerup", up);
  });
}
window.addEventListener("resize", renderRows);

// ---------- live polling ----------

let tick = 0;
setInterval(async () => {
  if (!state.sessionId || !state.running) return;
  tick++;
  try {
    await refreshMeta();
    if (state.running || !state.exhausted) {
      if ($("follow").checked) {
        state.exhausted = false;
        await fetchMore();
      }
    }
    if (tick % 3 === 0) refreshInsights();
    if (!state.running) {
      loadSessions();
      refreshInsights();
    }
  } catch (e) {
    msg(e.message);
  }
}, 1000);

(async () => {
  try {
    const who = await api("/api/whoami");
    $("whoami").textContent = who.user;
    const cur = await api("/api/capture");
    await loadSessions(cur.session && cur.session.id);
  } catch (e) {
    msg(e.message);
  }
})();
