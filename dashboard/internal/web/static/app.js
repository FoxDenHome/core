"use strict";

const POLL_MS = 5000;
const SEVERITY = { empty: 0, off: 0, ok: 1, unknown: 2, warn: 3, crit: 4 };
const STATUS_TEXT = { ok: "ok", warn: "warning", crit: "critical", unknown: "unknown", off: "off", empty: "empty" };

let snap = null;
let lastOk = 0;
let selDev = null;
let selSlot = null; // "groupId:slotId"

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const worst = (list) => list.reduce((w, s) => (SEVERITY[s] > SEVERITY[w] ? s : w), "ok");

const HINTS = { bay: "a disk", port: "a port", outlet: "an outlet", led: "an indicator", meter: "a meter" };

const ICONS = {
  ok: '<svg class="ico" viewBox="0 0 12 12"><path d="M2.5 6.2l2.3 2.3 4.7-5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  warn: '<svg class="ico" viewBox="0 0 12 12"><path d="M6 1.5l4.8 9H1.2z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/><path d="M6 5v2.4M6 9v.01" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
  crit: '<svg class="ico" viewBox="0 0 12 12"><path d="M3 3l6 6M9 3l-6 6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  unknown: '<svg class="ico" viewBox="0 0 12 12"><path d="M4.4 4.3a1.7 1.7 0 113 1.1c-.7.5-1.4.8-1.4 1.8M6 9.2v.01" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
  off: "",
  empty: "",
};

/* ---------- data ---------- */

function walk(devs, fn) {
  for (const d of devs) {
    fn(d);
    if (d.children) walk(d.children, fn);
  }
}

// Everything that's polled: rack devices and remote sites.
function allDevices() {
  return [...(snap?.devices ?? []), ...(snap?.remote ?? []).flatMap((s) => s.devices)];
}

function findSite(id) {
  return (snap?.remote ?? []).find((s) => s.devices.some((d) => d.id === id)) ?? null;
}

function findDev(id) {
  let hit = null;
  walk(allDevices(), (d) => { if (d.id === id) hit = d; });
  return hit;
}

// A shelf's status is whatever its worst passenger is.
function statusOf(d) {
  if (d.children?.length) return worst(d.children.map(statusOf));
  return d.state.status;
}

function ago(ts) {
  const t = Date.parse(ts);
  if (!t || t < 0) return "never";
  const s = Math.max(0, Math.round((Date.now() - t) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  return `${Math.round(s / 3600)}h ago`;
}

/* ---------- faceplate ---------- */

function cols(g) {
  return Math.ceil(g.slots.length / Math.max(1, g.rows));
}

function slotHTML(g, s, size, devId) {
  const key = `${g.id}:${s.id}`;
  const picked = size === "full" && selSlot === key ? " picked" : "";
  const data = `data-dev="${esc(devId)}" data-slot="${esc(key)}"`;
  const tip = esc(`${s.label}${s.value ? " · " + s.value : ""} · ${STATUS_TEXT[s.status] ?? s.status}`);
  const tag = size === "full" && s.sections?.length ? "button" : "span";
  const span = s.span > 1 ? ` style="grid-row:span ${s.span}"` : "";
  const common = `class="slot ${g.kind} s-${s.status}${s.span > 1 ? " span" : ""}${picked}" ${data} title="${tip}"${span}`;
  switch (g.kind) {
    case "bay":
      if (size === "full") {
        return `<${tag} ${common}><span class="lbl">${esc(s.label)}</span><span class="row">${ICONS[s.status] ?? ""}<span class="val">${esc(s.status === "empty" ? "empty" : s.value ?? "")}</span></span></${tag}>`;
      }
      return `<${tag} ${common}>${ICONS[s.status] ?? ""}<span class="val">${esc(s.value ?? "")}</span></${tag}>`;
    case "port":
      if (size === "full") return `<${tag} ${common}>${esc(s.label)}<span class="val">${esc(s.value ?? "")}</span></${tag}>`;
      return `<${tag} ${common}></${tag}>`;
    case "outlet":
      if (size === "full") return `<${tag} ${common}>${esc(s.label)}<span class="val">${esc(s.value ?? "—")}</span></${tag}>`;
      return `<${tag} ${common}></${tag}>`;
    case "meter": {
      const pct = Math.max(0, Math.min(100, s.percent ?? 0));
      return `<${tag} ${common}><span class="lbl">${esc(s.label)}</span><span class="bar"><b style="width:${pct}%"></b></span><span class="val">${esc(s.value ?? "—")}</span></${tag}>`;
    }
    case "led":
      return `<${tag} ${common}><i></i>${esc(s.label)}${size === "full" && s.value ? ` <span class="val">${esc(s.value)}</span>` : ""}</${tag}>`;
    default:
      return `<${tag} ${common}>${esc(s.label)}</${tag}>`;
  }
}

function groupHTML(g, size, devId) {
  const vertical = g.kind === "meter" || g.kind === "led";
  const style = vertical
    ? `grid-template-rows:repeat(${g.rows},auto);grid-auto-flow:column`
    : `grid-template-columns:repeat(${cols(g)},auto)`;
  const align = g.align ? ` align-${g.align}` : "";
  const slots = g.slots.map((s) => slotHTML(g, s, size, devId)).join("");
  if (size === "full" && g.label) return `<div class="grp-wrap${align}"><div class="grp-label">${esc(g.label)}</div><div class="grp" style="${style}">${slots}</div></div>`;
  return `<div class="grp${align}" style="${style}">${slots}</div>`;
}

/* ---------- rack ---------- */

function uTop(u, h) {
  return (snap.units - (u + h - 1)) * unitPx() + 6;
}

function unitPx() {
  return parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--u")) || 32;
}

function deviceInner(d) {
  const st = statusOf(d);
  if (d.state.passive && !d.children?.length) {
    return `<div class="dev-id"><div class="dev-name">${esc(d.name)}</div></div><div class="dev-face">${d.module.includes("brush") ? '<div class="brush"></div>' : ""}</div>`;
  }
  const face = (d.state.faceplate ?? []).filter((g) => !g.internal).map((g) => groupHTML(g, "mini", d.id)).join("");
  const sum = esc(d.state.summary ?? "");
  return `
    <div class="dev-id">
      <div class="dev-name"><span class="dot s-${st}"></span>${esc(d.name)}</div>
      <div class="dev-sum">${sum}</div>
    </div>
    <div class="dev-face mini">${face}</div>
    <div class="dev-side">${sum}</div>`;
}

function renderRack() {
  const rack = $("rack");
  const uh = unitPx();
  const taken = new Set();
  for (const d of snap.devices) for (let u = d.u; u < d.u + d.height; u++) taken.add(u);

  let units = "";
  for (let u = snap.units; u >= 1; u--) {
    units += `<div class="unit${taken.has(u) ? " taken" : ""}"><span>${u}</span><span>${u}</span></div>`;
  }

  let devs = "";
  for (const d of snap.devices) {
    const st = statusOf(d);
    const geo = `top:${uTop(d.u, d.height)}px;height:${d.height * uh - 2}px`;
    const h1 = d.height === 1 ? " h1" : "";
    if (d.children?.length) {
      const kids = d.children.map((c) => {
        const cs = statusOf(c);
        return `<div class="dev${h1} s-${cs}${selDev === c.id ? " sel" : ""}" role="button" tabindex="0" data-dev="${esc(c.id)}" style="flex-grow:${c.width}">${deviceInner(c)}</div>`;
      }).join("");
      devs += `<div class="dev shelf s-${st}" style="${geo}" title="${esc(d.name)}">${kids}</div>`;
    } else {
      const passive = d.state.passive ? " passive" : "";
      devs += `<div class="dev${h1}${passive} s-${st}${selDev === d.id ? " sel" : ""}" role="button" tabindex="0" data-dev="${esc(d.id)}" style="${geo}" title="${esc(d.name)} · ${esc(STATUS_TEXT[st])}">${deviceInner(d)}</div>`;
    }
  }
  rack.innerHTML = `<div class="units">${units}</div>${devs}`;

  $("remote").innerHTML = (snap.remote ?? [])
    .map((site) => `
      <div class="site">
        <div class="site-head">${esc(site.name)}</div>
        ${site.devices
          .map((d) => {
            const st = statusOf(d);
            const h1 = d.height === 1 ? " h1" : "";
            return `<div class="dev${h1} s-${st}${selDev === d.id ? " sel" : ""}" role="button" tabindex="0" data-dev="${esc(d.id)}" style="height:${d.height * uh - 2}px">${deviceInner(d)}</div>`;
          })
          .join("")}
      </div>`)
    .join("");
}

function renderTally() {
  const counts = { ok: 0, warn: 0, crit: 0, unknown: 0 };
  walk(allDevices(), (d) => {
    if (d.children?.length || d.state.passive) return;
    const s = d.state.status;
    if (s in counts) counts[s]++;
  });
  $("tally").innerHTML = ["crit", "warn", "unknown", "ok"]
    .filter((s) => counts[s] || s === "ok")
    .map((s) => `<span class="s-${s}"><i></i>${counts[s]} ${STATUS_TEXT[s]}</span>`)
    .join("");
}

/* ---------- details ---------- */

function table(rows) {
  return `<table>${rows.map((r) => `<tr><td>${esc(r.k)}</td><td class="${r.s ? "s-" + r.s : ""}">${esc(r.v)}</td></tr>`).join("")}</table>`;
}

function card(sec) {
  return `<div class="card"><h3>${esc(sec.title)}</h3>${table(sec.rows ?? [])}</div>`;
}

function findSlot(d, key) {
  if (!key) return null;
  const [gid, sid] = key.split(/:(.*)/s);
  const g = (d.state.faceplate ?? []).find((g) => g.id === gid);
  return g?.slots.find((s) => s.id === sid) ?? null;
}

function renderDetail() {
  const pane = $("detail");
  const d = selDev ? findDev(selDev) : null;
  if (!d) {
    pane.innerHTML = overview();
    return;
  }
  const st = statusOf(d);
  const s = d.state;
  const top = findTop(d.id);
  const site = findSite(d.id);
  const range = top ? (top.height > 1 ? `U${top.u}–${top.u + top.height - 1}` : `U${top.u}`) : "";
  const where = site ? `remote · ${site.name}` : top && top.id !== d.id ? `${range} · on ${top.name}` : range;

  let html = `
    <div class="d-head"><h2>${esc(d.name)}</h2>${s.passive ? `<span class="pill s-off">passive</span>` : `<span class="pill s-${st}">${esc(STATUS_TEXT[st])}</span>`}</div>
    <div class="d-meta">
      <span>${esc(where)}</span><span>${esc(d.module)}</span>
      ${d.address ? `<span>${esc(d.address)}</span>` : ""}
      <span>updated ${esc(ago(s.updated))}</span>
    </div>`;
  if (s.summary) html += `<div class="d-sum">${esc(s.summary)}</div>`;
  if (s.error) html += `<div class="err">${esc(s.error)}</div>`;

  if (d.children?.length) {
    html += `<div class="cards"><div class="card"><h3>On this shelf</h3><div class="attn" style="padding:10px">${d.children
      .map((c) => `<button class="s-${statusOf(c)}" data-go="${esc(c.id)}"><span class="dot s-${statusOf(c)}"></span>${esc(c.name)}<span class="what">${esc(c.state.summary ?? "")}</span></button>`)
      .join("")}</div></div></div>`;
    pane.innerHTML = html;
    return;
  }

  const face = s.faceplate ?? [];
  if (face.length) {
    html += `<div class="d-face full">${face.map((g) => groupHTML(g, "full", d.id)).join("")}</div>`;
    const clickable = face.find((g) => g.slots.some((x) => x.sections?.length));
    if (clickable) {
      html += `<div class="d-hint">select ${esc(HINTS[clickable.kind] ?? "a slot")} for details</div>`;
    }
  }

  html += `<div class="cards">`;
  const slot = findSlot(d, selSlot);
  if (slot?.sections?.length) {
    html += `<div class="card focus"><h3><span>${esc(slot.label)} · ${esc(STATUS_TEXT[slot.status])}</span><button class="x" data-close aria-label="Close">×</button></h3><div class="cards-inner">${slot.sections
      .map((sec) => `<div><h4>${esc(sec.title)}</h4>${table(sec.rows ?? [])}</div>`)
      .join("")}</div></div>`;
  }
  html += (s.sections ?? []).map(card).join("");
  html += `</div>`;
  pane.innerHTML = html;
}

function findTop(id) {
  for (const d of snap.devices) {
    if (d.id === id) return d;
    if (d.children?.some((c) => c.id === id)) return d;
  }
  return null;
}

function overview() {
  const items = [];
  walk(allDevices(), (d) => {
    if (d.children?.length || d.state.passive) return;
    const s = d.state;
    if (SEVERITY[s.status] >= SEVERITY.unknown) {
      items.push({ dev: d, slot: null, status: s.status, what: s.error || s.summary || "" });
    }
    for (const g of s.faceplate ?? []) {
      for (const sl of g.slots) {
        if (SEVERITY[sl.status] >= SEVERITY.warn) items.push({ dev: d, slot: `${g.id}:${sl.id}`, label: sl.label, status: sl.status, what: sl.value || "" });
      }
    }
  });
  items.sort((a, b) => SEVERITY[b.status] - SEVERITY[a.status]);
  const body = items.length
    ? `<div class="attn">${items
        .map((i) => `<button class="s-${i.status}" data-go="${esc(i.dev.id)}"${i.slot ? ` data-go-slot="${esc(i.slot)}"` : ""}><span class="dot s-${i.status}"></span><span>${esc(i.dev.name)}${i.label ? " · " + esc(i.label) : ""}</span><span class="what">${esc(i.what)}</span></button>`)
        .join("")}</div>`
    : `<div class="allgood">All devices nominal.</div>`;
  return `<div class="empty-state"><h2>Needs attention</h2>${body}<p style="margin-top:20px;color:var(--faint)">Select a device in the rack for details.</p></div>`;
}

/* ---------- navigation ---------- */

function readHash() {
  const [dev, ...rest] = decodeURIComponent(location.hash.slice(1)).split("/");
  selDev = dev || null;
  selSlot = rest.join("/") || null;
}

function go(dev, slot) {
  const h = dev ? "#" + encodeURIComponent(dev) + (slot ? "/" + encodeURIComponent(slot) : "") : "#";
  if (location.hash !== h) history.pushState(null, "", h);
  readHash();
  render();
}

function render() {
  if (!snap) return;
  document.title = snap.title;
  $("title").textContent = snap.title;
  renderRack();
  renderTally();
  renderDetail();
}

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-close],[data-go],[data-slot],[data-dev]");
  if (!t) return;
  if (t.hasAttribute("data-close")) return go(selDev, null);
  if (t.dataset.go) return go(t.dataset.go, t.dataset.goSlot || null);
  if (t.dataset.slot) {
    const key = t.dataset.slot;
    const same = selDev === t.dataset.dev && selSlot === key;
    return go(t.dataset.dev, same ? null : key);
  }
  if (t.dataset.dev) return go(selDev === t.dataset.dev && !selSlot ? null : t.dataset.dev, null);
});

document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") return go(selSlot ? selDev : null, null);
  if ((e.key === "Enter" || e.key === " ") && e.target.matches?.('[role="button"]')) {
    e.preventDefault();
    e.target.click();
  }
});

window.addEventListener("popstate", () => { readHash(); render(); });

/* ---------- polling ---------- */

async function poll() {
  try {
    const r = await fetch("api/rack", { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    snap = await r.json();
    lastOk = Date.now();
    render();
  } catch (_) {
    /* keep showing the last snapshot */
  }
  updateLive();
}

function updateLive() {
  const live = $("live");
  const stale = !lastOk || Date.now() - lastOk > POLL_MS * 3;
  live.className = "live " + (stale ? "stale" : "ok");
  $("live-text").textContent = lastOk ? (stale ? `stale · ${ago(new Date(lastOk).toISOString())}` : "live") : "connecting…";
}

readHash();
poll();
setInterval(poll, POLL_MS);
setInterval(updateLive, 1000);
