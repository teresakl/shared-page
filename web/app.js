(() => {
  const MONTHS_EN = ["January","February","March","April","May","June","July","August","September","October","November","December"];
  const WEEK_LETTERS = ["M","T","W","T","F","S","S"];
  const WEEKDAYS_EN = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"];
  const STICKERS = [
    { id: "5713CA70-0000-4000-A000-000000000001", name: "halftone-cat-sleeping", w: 86 },
    { id: "5713CA70-0000-4000-A000-000000000002", name: "halftone-camera", w: 72 },
    { id: "5713CA70-0000-4000-A000-000000000003", name: "halftone-coffee-cup", w: 64 },
    { id: "5713CA70-0000-4000-A000-000000000004", name: "admit-one-ticket", w: 110 },
    { id: "5713CA70-0000-4000-A000-000000000005", name: "red-heart-outline", w: 56 },
  ];
  function stickerOf(id) {
    return STICKERS.find((s) => s.id === id) || STICKERS[0];
  }
  const ROW_H = 52;
  const FIRST_HOUR = 6;
  const LAST_HOUR = 23;
  const TIMELINE_H = 10 + (LAST_HOUR - FIRST_HOUR + 1) * ROW_H + 96;

  const $ = (id) => document.getElementById(id);
  const state = {
    token: localStorage.getItem("calendarToken") || "",
    view: "unlock",
    year: 0,
    month: 0,
    day: 1,
    events: [],
    notes: [],
    placed: [],
    unseen: new Set(),
    dirty: false,
    fabOpen: false,
    trayOpen: false,
    activeNote: null,
    editingNote: null,
    activePlaced: null,
    _draggingNote: false,
    _noteBlurBound: false,
  };

  const nowSH = () => new Date(Date.now() + 8 * 3600 * 1000);
  function todayParts() {
    const d = nowSH();
    return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, day: d.getUTCDate() };
  }
  function pad(n) { return String(n).padStart(2, "0"); }
  function isoDate(y, m, d) { return `${y}-${pad(m)}-${pad(d)}`; }
  function daysInMonth(y, m) { return new Date(y, m, 0).getDate(); }
  function leadingBlanks(y, m) {
    const js = new Date(y, m - 1, 1).getDay();
    return (js + 6) % 7;
  }
  function parseUTC(s) {
    if (!s) return null;
    const d = new Date(s);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  function inShanghai(dt) {
    return new Date(dt.getTime() + 8 * 3600 * 1000);
  }
  function authorOf(ev) {
    const a = String(ev.created_by || ev.author || "").toLowerCase();
    if (a === "kitty") return "kitty";
    if (a === "master" || a === "assistant") return "master";
    return "auto";
  }
  function authorName(a) {
    return a === "kitty" ? "USER" : a === "master" ? "ASSISTANT" : "AUTO";
  }
  function isSpan(ev) {
    const md = ev.metadata || {};
    if (md.kind === "span") return true;
    const s = parseUTC(ev.starts_at);
    const e = parseUTC(ev.ends_at);
    if (!s || !e) return false;
    return (e - s) > 26 * 3600 * 1000;
  }
  function isAllDay(ev) {
    return ev.precision === "day" || ev.event_type === "period";
  }
  function yOf(hour, minute) {
    return 10 + (hour - FIRST_HOUR) * ROW_H + (minute / 60) * ROW_H;
  }
  function esc(s) {
    return String(s ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  function uid() {
    if (globalThis.crypto && typeof crypto.randomUUID === "function") {
      try { return crypto.randomUUID(); } catch (_) {}
    }
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === "x" ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  function flash(msg) {
    let n = document.getElementById("flash");
    if (!n) {
      n = document.createElement("div");
      n.id = "flash";
      n.className = "flash";
      document.body.appendChild(n);
    }
    n.textContent = msg;
    n.hidden = false;
    clearTimeout(flash._t);
    flash._t = setTimeout(() => { n.hidden = true; }, 2400);
  }

  async function api(path, opts = {}) {
    const headers = Object.assign({ "X-Calendar-Token": state.token }, opts.headers || {});
    if (opts.body && !(opts.body instanceof FormData) && !headers["Content-Type"]) {
      headers["Content-Type"] = "application/json";
    }
    const res = await fetch(path, Object.assign({}, opts, { headers }));
    if (res.status === 401) throw new Error("钥匙不对");
    if (!res.ok) {
      let detail = res.statusText;
      try { detail = (await res.json()).detail || detail; } catch (_) {}
      throw new Error(detail);
    }
    if (res.status === 204) return null;
    const ct = res.headers.get("content-type") || "";
    if (ct.includes("application/json")) return res.json();
    return res;
  }

  function monthRange(y, m) {
    const from = `${isoDate(y, m, 1)}T00:00:00+08:00`;
    const last = daysInMonth(y, m);
    const next = m === 12 ? `${y + 1}-01-01T00:00:00+08:00` : `${isoDate(y, m + 1, 1)}T00:00:00+08:00`;
    return { from, to: next, last };
  }

  async function loadMonth() {
    const { from, to } = monthRange(state.year, state.month);
    const q = new URLSearchParams({ from, to, limit: "500" });
    const [ev, unseen] = await Promise.all([
      api(`/api/v1/calendar/events?${q}`),
      api("/api/v1/calendar/unseen"),
    ]);
    state.events = ev.events || [];
    state.unseen = new Set(unseen.days || []);
  }

  async function loadDay() {
    const date = isoDate(state.year, state.month, state.day);
    const next = new Date(Date.UTC(state.year, state.month - 1, state.day + 1));
    const from = `${date}T00:00:00+08:00`;
    const to = `${next.getUTCFullYear()}-${pad(next.getUTCMonth() + 1)}-${pad(next.getUTCDate())}T00:00:00+08:00`;
    const q = new URLSearchParams({ from, to, limit: "200" });
    const nq = new URLSearchParams({ date, limit: "200" });
    const [ev, notes, placed] = await Promise.all([
      api(`/api/v1/calendar/events?${q}`),
      api(`/api/v1/calendar/notes?${nq}`),
      api(`/api/v1/calendar/placed/${date}`),
    ]);
    state.events = ev.events || [];
    state.notes = notes.notes || [];
    state.placed = placed.items || [];
    await api("/api/v1/calendar/unseen/seen", { method: "POST", body: JSON.stringify({ date }) });
    state.unseen.delete(date);
  }

  function renderUnlock() {
    $("unlock").hidden = false;
    $("month-view").hidden = true;
    $("day-view").hidden = true;
    $("token").value = state.token;
  }

  function renderMonth() {
    $("unlock").hidden = true;
    $("day-view").hidden = true;
    const el = $("month-view");
    el.hidden = false;
    const t = todayParts();
    const y = state.year, m = state.month;
    const blanks = leadingBlanks(y, m);
    const dim = daysInMonth(y, m);
    const prevDim = daysInMonth(m === 1 ? y - 1 : y, m === 1 ? 12 : m - 1);
    const rows = Math.ceil((blanks + dim) / 7);
    const cells = [];
    for (let i = 0; i < rows * 7; i++) {
      const n = i - blanks + 1;
      const inMonth = n >= 1 && n <= dim;
      const disp = inMonth ? n : (n < 1 ? prevDim + n : n - dim);
      const date = inMonth ? isoDate(y, m, n) : "";
      const dayEvents = inMonth ? eventsOnDay(n) : [];
      const spans = inMonth ? spansCovering(n) : [];
      const stamp = inMonth && dayEvents.some((e) => ["birthday", "anniversary"].includes(e.event_type));
      const isToday = inMonth && t.y === y && t.m === m && t.day === n;
      cells.push(`<div class="cell${inMonth ? "" : " dim"}${isToday ? " today" : ""}" ${inMonth ? `data-day="${n}"` : ""}>
        ${spans.slice(0, 2).map((s, idx) => `<div class="band ${authorOf(s)}" style="top:${17 + idx * 36}px"></div>`).join("")}
        ${stamp ? `<img class="stamp" src="/assets/stickers/stamp-heart-mini.png" alt="">` : ""}
        <div class="num">${disp}</div>
        <div class="titles">${dayEvents.slice(0, 4).map((e) =>
          `<div style="color:${authorOf(e) === "master" ? "var(--ink-master)" : authorOf(e) === "auto" ? "var(--ink-system)" : "var(--ink-kitty)"}">${esc(e.title)}</div>`
        ).join("")}</div>
        ${state.unseen.has(date) ? `<img class="new" src="/assets/stickers/red-exclaim-double.png" alt="">` : ""}
      </div>`);
    }
    el.innerHTML = `
      <div class="header">
        <div>
          <h1>${MONTHS_EN[m - 1]}<span class="year">${y}</span></h1>
          <p class="sub">tap a day to open it</p>
        </div>
        <div class="nav">
          <button type="button" data-nav="-1">◀</button>
          <button type="button" data-nav="1">▶</button>
        </div>
      </div>
      <div class="card">
        <div class="weekdays">${WEEK_LETTERS.map((w) => `<span>${w}</span>`).join("")}</div>
        ${Array.from({ length: rows }, (_, r) => `<div class="grid-row">${cells.slice(r * 7, r * 7 + 7).join("")}</div>`).join("")}
        <div class="legend">
          <span><i class="swatch" style="background:var(--ink-kitty)"></i>USER</span>
          <span><i class="swatch" style="background:var(--ink-master)"></i>ASSISTANT</span>
          <span><i class="swatch" style="background:var(--ink-system)"></i>AUTO</span>
        </div>
      </div>`;
    el.querySelectorAll("[data-nav]").forEach((b) => b.addEventListener("click", () => shiftMonth(Number(b.dataset.nav))));
    el.querySelectorAll("[data-day]").forEach((c) => c.addEventListener("click", () => openDay(Number(c.dataset.day))));
  }

  function eventsOnDay(day) {
    const start = Date.parse(`${isoDate(state.year, state.month, day)}T00:00:00+08:00`);
    const end = start + 24 * 3600 * 1000;
    return state.events.filter((ev) => {
      if (ev.status && ev.status !== "active") return false;
      if (isSpan(ev) || ev.event_type === "period") return false;
      const s = parseUTC(ev.starts_at);
      const e = parseUTC(ev.ends_at) || s;
      if (!s) return false;
      return s.getTime() < end && e.getTime() > start && !isAllDay(ev);
    }).concat(state.events.filter((ev) => {
      if (ev.status && ev.status !== "active") return false;
      if (isSpan(ev) || ev.event_type === "period") return false;
      if (!isAllDay(ev)) return false;
      const s = parseUTC(ev.starts_at);
      return s && inShanghai(s).getUTCDate() === day && inShanghai(s).getUTCMonth() + 1 === state.month;
    }));
  }

  function spansCovering(day) {
    const start = Date.parse(`${isoDate(state.year, state.month, day)}T00:00:00+08:00`);
    const end = start + 24 * 3600 * 1000;
    return state.events.filter((ev) => {
      if (ev.status && ev.status !== "active") return false;
      if (!(isSpan(ev) || ev.event_type === "period")) return false;
      const s = parseUTC(ev.starts_at);
      const e = parseUTC(ev.ends_at);
      return s && e && s.getTime() < end && e.getTime() > start;
    });
  }

  function renderDay() {
    $("unlock").hidden = true;
    $("month-view").hidden = true;
    const el = $("day-view");
    el.hidden = false;
    const date = isoDate(state.year, state.month, state.day);
    const wd = WEEKDAYS_EN[(leadingBlanks(state.year, state.month) + state.day - 1) % 7];
    const hours = [];
    for (let h = FIRST_HOUR; h <= LAST_HOUR; h++) {
      const y = yOf(h, 0);
      hours.push(`<div class="hour-line" style="top:${y}px"></div>
        <div class="hour-lab" style="top:${y}px">${pad(h)}</div>`);
    }
    const timed = state.events.filter((ev) => ev.status !== "deleted" && !isAllDay(ev) && !isSpan(ev));
    const allday = state.events.filter((ev) => ev.status !== "deleted" && (isAllDay(ev) || isSpan(ev)));
    const eventHtml = timed.map((ev) => {
      const s = inShanghai(parseUTC(ev.starts_at));
      const e = inShanghai(parseUTC(ev.ends_at) || parseUTC(ev.starts_at));
      const sh = s.getUTCHours(), sm = s.getUTCMinutes();
      const dur = Math.max(1, Math.round((e - s) / 60000));
      const top = yOf(sh, sm);
      const h = Math.max(34, dur / 60 * ROW_H - 3);
      const a = authorOf(ev);
      const endH = sh * 60 + sm + dur;
      return `<div class="event-block ${a}" data-event="${esc(ev.id)}" style="top:${top}px;height:${h}px">
        <div class="t">${esc(ev.title)}</div>
        <div class="meta">${pad(sh)}:${pad(sm)}–${pad(Math.floor(endH / 60))}:${pad(endH % 60)} · ${authorName(a)}</div>
      </div>`;
    }).join("");

    const notesHtml = state.notes.filter((n) => !n.deleted_at).map((n, i) => {
      const a = authorOf(n);
      const y = n.y ?? (34 + i * 116);
      const x = noteLeft(n.id);
      const editing = state.editingNote === n.id;
      const active = state.activeNote === n.id;
      const liked = n.liked ? `<img class="heart" src="/assets/stickers/red-heart-outline.png" alt="">` : "";
      return `<div class="note ${a}${active ? " active" : ""}${editing ? " editing" : ""}" data-note="${esc(n.id)}" style="top:${y}px${x == null ? "" : `;left:${x}px`}">
        <div class="tape"></div>
        ${active ? `<button type="button" class="x" data-del-note="${esc(n.id)}">✕</button>` : ""}
        <div class="body" ${editing ? "contenteditable" : ""}>${esc(n.body || n.comment || "")}</div>
        ${liked}
      </div>`;
    }).join("");

    const placedHtml = state.placed.filter((item) => item.kind !== "note-x").map((item) => {
      const rot = item.rotation || 0;
      const scale = item.scale || 1;
      const selected = state.activePlaced === item.id;
      const handles = selected ? `
        <button type="button" class="x" data-del-placed="${esc(item.id)}">✕</button>
        <button type="button" class="rot" data-rot-placed="${esc(item.id)}" aria-label="转"></button>
        <button type="button" class="scl" data-scl-placed="${esc(item.id)}" aria-label="大小"></button>` : "";
      const box = `left:${item.x}px;top:${item.y}px;--s:${scale};transform:translate(-50%,-50%) rotate(${rot}deg) scale(${scale})`;
      if (item.kind === "photo") {
        return `<div class="placed photo${selected ? " selected" : ""}" data-placed="${esc(item.id)}" style="${box}">
          ${handles}
          <div class="frame">
            <img class="shot" src="/media/photos/${esc(item.photoFile)}" alt="">
            <img class="frame-img" src="/assets/stickers/instax-mini-frame.png" alt="">
          </div>
        </div>`;
      }
      const st = stickerOf(item.stickerID);
      const w = st.w || 72;
      return `<div class="placed sticker${selected ? " selected" : ""}" data-placed="${esc(item.id)}" style="${box};width:${w}px">
        ${handles}
        <img src="/assets/stickers/${st.name}.png" alt="" style="width:100%">
      </div>`;
    }).join("");

    el.innerHTML = `
      <button type="button" class="back" id="back-month"><span class="chev">‹</span><span class="mname">${MONTHS_EN[state.month - 1]}</span></button>
      <div class="week-strip" id="week-strip">${weekStripHtml()}</div>
      <div id="day-sheet">
        <div class="title-row"><span class="big">${MONTHS_EN[state.month - 1]} ${state.day}</span><span class="wd">${wd}</span></div>
        <div class="all-day">${allday.map((e) => `<div class="span">${esc(e.title)}</div>`).join("")}</div>
        <div class="timeline" id="timeline">
          ${hours.join("")}
          ${eventHtml}
          ${notesHtml}
          ${placedHtml}
        </div>
      </div>
      <button type="button" class="fab" id="fab">+</button>
      <div class="fab-menu" id="fab-menu" ${state.fabOpen ? "" : "hidden"}>
        <button type="button" data-add="event">写一条安排</button>
        <button type="button" data-add="note">贴一张便签</button>
        <button type="button" data-add="sticker">贴纸</button>
        <button type="button" data-add="photo">拍立得</button>
      </div>
      ${state.trayOpen ? `
      <div class="sticker-tray" id="sticker-tray">
        <p class="hint">按住拖到这一页上；点选以后，上面转，右下角拉大拉小，叉可以撕掉</p>
        <div class="row">${STICKERS.map((s) =>
          `<button type="button" data-sticker="${s.id}"><img src="/assets/stickers/${s.name}.png" alt=""></button>`
        ).join("")}</div>
      </div>` : ""}`;

    $("back-month").addEventListener("click", () => backToMonth());
    el.querySelectorAll("[data-strip]").forEach((b) => b.addEventListener("click", () => jumpDate(b.dataset.strip)));
    el.querySelectorAll("[data-event]").forEach((b) => b.addEventListener("click", () => openEventEditor(b.dataset.event)));
    bindNotes();
    bindPlaced();
    bindStickerTray();
    $("fab").addEventListener("click", () => {
      state.fabOpen = !state.fabOpen;
      $("fab-menu").hidden = !state.fabOpen;
    });
    el.querySelectorAll("[data-add]").forEach((b) => b.addEventListener("click", () => {
      state.fabOpen = false;
      const kind = b.dataset.add;
      if (kind === "event") openEventEditor(null);
      if (kind === "note") addNote();
      if (kind === "sticker") openStickerTray();
      if (kind === "photo") pickPhoto();
    }));
  }

  function weekStripHtml() {
    const center = new Date(Date.UTC(state.year, state.month - 1, state.day));
    const bits = [];
    for (let i = -10; i <= 16; i++) {
      const d = new Date(center.getTime() + i * 86400000);
      const y = d.getUTCFullYear(), m = d.getUTCMonth() + 1, day = d.getUTCDate();
      const key = isoDate(y, m, day);
      const out = m !== state.month;
      const t = todayParts();
      const today = y === t.y && m === t.m && day === t.day;
      const selected = i === 0;
      bits.push(`<button type="button" class="strip-cell${out ? " out" : ""}${today ? " today" : ""}" data-strip="${key}">
        <span class="w">${WEEK_LETTERS[(d.getUTCDay() + 6) % 7]}</span>
        <span class="dwrap">${selected ? `<img src="/assets/stickers/pink-date-circle.png" alt="">` : ""}<span class="d">${day}</span></span>
      </button>`);
    }
    return bits.join("");
  }

  function noteXRecord(noteId) {
    return state.placed.find((p) => p.kind === "note-x" && p.noteId === noteId);
  }
  function noteLeft(noteId) {
    const rec = noteXRecord(noteId);
    return rec && Number.isFinite(rec.x) ? rec.x : null;
  }

  function bindNotes() {
    if (!state._noteBlurBound) {
      state._noteBlurBound = true;
      document.addEventListener("pointerdown", (ev) => {
        if (state._draggingNote) return;
        blurNotes(ev);
      });
    }
    document.querySelectorAll(".note").forEach((node) => {
      const id = node.dataset.note;
      node.addEventListener("pointerdown", (ev) => {
        if (ev.target.closest("[data-del-note]")) return;
        if (state.editingNote === id && ev.target.closest(".body")) return;
        ev.preventDefault();
        ev.stopPropagation();
        const tl = $("timeline");
        const maxX = Math.max(8, (tl ? tl.clientWidth : 390) - node.offsetWidth - 8);
        const startX = ev.clientX;
        const startY = ev.clientY;
        const ox = node.offsetLeft;
        const oy = parseFloat(node.style.top) || node.offsetTop;
        let moved = false;
        state._draggingNote = true;
        const onMove = (e) => {
          const dx = e.clientX - startX;
          const dy = e.clientY - startY;
          if (Math.hypot(dx, dy) > 6) moved = true;
          if (!moved) return;
          const nx = Math.min(maxX, Math.max(8, ox + dx));
          const ny = Math.min(Math.max(0, oy + dy), TIMELINE_H - 96);
          node.style.left = `${nx}px`;
          node.style.top = `${ny}px`;
        };
        const onUp = async () => {
          window.removeEventListener("pointermove", onMove);
          window.removeEventListener("pointerup", onUp);
          window.removeEventListener("pointercancel", onUp);
          state._draggingNote = false;
          if (!moved) {
            if (state.activeNote === id) {
              state.editingNote = id;
              renderDay();
              requestAnimationFrame(() => document.querySelector(`[data-note="${id}"] .body`)?.focus());
            } else {
              state.activeNote = id;
              state.editingNote = null;
              renderDay();
            }
            return;
          }
          const x = parseFloat(node.style.left);
          const y = parseFloat(node.style.top) || 0;
          await saveNotePos(id, x, y);
        };
        window.addEventListener("pointermove", onMove);
        window.addEventListener("pointerup", onUp);
        window.addEventListener("pointercancel", onUp);
      });
      const body = node.querySelector(".body");
      if (body && body.isContentEditable) {
        body.addEventListener("blur", async () => {
          const text = body.innerText.trim() || "写点什么";
          await api(`/api/v1/calendar/notes/${id}`, { method: "PATCH", body: JSON.stringify({ body: text }) });
          const n = state.notes.find((x) => x.id === id);
          if (n) n.body = text;
          markDirty();
        });
      }
    });
    document.querySelectorAll("[data-del-note]").forEach((b) => b.addEventListener("click", async (e) => {
      e.stopPropagation();
      const nid = b.dataset.delNote;
      await api(`/api/v1/calendar/notes/${nid}`, { method: "DELETE" });
      state.notes = state.notes.filter((n) => n.id !== nid);
      state.placed = state.placed.filter((p) => !(p.kind === "note-x" && p.noteId === nid));
      state.activeNote = null;
      state.editingNote = null;
      await savePlaced();
      markDirty();
      renderDay();
    }));
  }

  async function saveNotePos(id, x, y) {
    await api(`/api/v1/calendar/notes/${id}`, { method: "PATCH", body: JSON.stringify({ y }) });
    const n = state.notes.find((item) => item.id === id);
    if (n) n.y = y;
    let rec = noteXRecord(id);
    if (!rec) {
      rec = { id: uid(), kind: "note-x", noteId: id, x, y };
      state.placed.push(rec);
    } else {
      rec.x = x;
      rec.y = y;
    }
    await savePlaced();
    markDirty();
  }

  function blurNotes(ev) {
    if (ev.target.closest(".note") || ev.target.closest(".fab") || ev.target.closest(".fab-menu") || ev.target.closest(".modal")) return;
    if (state.activeNote || state.editingNote) {
      state.activeNote = null;
      state.editingNote = null;
      renderDay();
    }
  }

  function pagePoint(clientX, clientY) {
    const tl = $("timeline");
    if (!tl) return null;
    const r = tl.getBoundingClientRect();
    const tray = $("sticker-tray");
    const trayTop = tray ? tray.getBoundingClientRect().top : window.innerHeight;
    const visibleTop = Math.max(8, -r.top + 8);
    const visibleBottom = Math.min(TIMELINE_H - 8, trayTop - r.top - 16);
    let x = clientX - r.left;
    let y = clientY - r.top;
    if (clientY < r.top) y = visibleTop + 36;
    if (clientY >= trayTop || y > visibleBottom) y = Math.max(visibleTop + 36, visibleBottom - 48);
    return {
      x: Math.min(Math.max(8, x), Math.max(8, tl.clientWidth - 8)),
      y: Math.min(Math.max(8, y), TIMELINE_H - 8),
    };
  }

  function applyPlacedStyle(node, item) {
    const rot = item.rotation || 0;
    const scale = item.scale || 1;
    node.style.left = `${item.x}px`;
    node.style.top = `${item.y}px`;
    node.style.setProperty("--s", String(scale));
    node.style.transform = `translate(-50%, -50%) rotate(${rot}deg) scale(${scale})`;
  }

  function bindPlaced() {
    const handleSel = "[data-del-placed],[data-rot-placed],[data-scl-placed]";
    document.querySelectorAll("[data-del-placed]").forEach((b) => {
      b.addEventListener("pointerdown", (ev) => ev.stopPropagation());
      b.addEventListener("click", async (ev) => {
        ev.stopPropagation();
        const id = b.dataset.delPlaced;
        state.placed = state.placed.filter((p) => p.id !== id);
        state.activePlaced = null;
        await savePlaced();
        renderDay();
      });
    });
    document.querySelectorAll("[data-rot-placed]").forEach((b) => {
      b.addEventListener("pointerdown", (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const item = state.placed.find((p) => p.id === b.dataset.rotPlaced);
        const node = b.closest("[data-placed]");
        if (!item || !node) return;
        const r = node.getBoundingClientRect();
        const cx = r.left + r.width / 2;
        const cy = r.top + r.height / 2;
        const start = Math.atan2(ev.clientY - cy, ev.clientX - cx);
        const startRot = item.rotation || 0;
        const move = (e) => {
          item.rotation = startRot + (Math.atan2(e.clientY - cy, e.clientX - cx) - start) * 180 / Math.PI;
          applyPlacedStyle(node, item);
        };
        const up = async () => {
          window.removeEventListener("pointermove", move);
          window.removeEventListener("pointerup", up);
          await savePlaced();
        };
        window.addEventListener("pointermove", move);
        window.addEventListener("pointerup", up);
      });
    });
    document.querySelectorAll("[data-scl-placed]").forEach((b) => {
      b.addEventListener("pointerdown", (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const item = state.placed.find((p) => p.id === b.dataset.sclPlaced);
        const node = b.closest("[data-placed]");
        if (!item || !node) return;
        const r = node.getBoundingClientRect();
        const cx = r.left + r.width / 2;
        const cy = r.top + r.height / 2;
        const startDist = Math.hypot(ev.clientX - cx, ev.clientY - cy) || 1;
        const startScale = item.scale || 1;
        const move = (e) => {
          const dist = Math.hypot(e.clientX - cx, e.clientY - cy);
          item.scale = Math.min(2.4, Math.max(0.4, startScale * dist / startDist));
          applyPlacedStyle(node, item);
        };
        const up = async () => {
          window.removeEventListener("pointermove", move);
          window.removeEventListener("pointerup", up);
          await savePlaced();
        };
        window.addEventListener("pointermove", move);
        window.addEventListener("pointerup", up);
      });
    });
    document.querySelectorAll("[data-placed]").forEach((node) => {
      const id = node.dataset.placed;
      node.addEventListener("pointerdown", (ev) => {
        if (ev.target.closest(handleSel)) return;
        ev.preventDefault();
        ev.stopPropagation();
        const item = state.placed.find((p) => p.id === id);
        if (!item) return;
        const startX = ev.clientX;
        const startY = ev.clientY;
        const ox = item.x;
        const oy = item.y;
        let moved = false;
        const onMove = (e) => {
          const dx = e.clientX - startX;
          const dy = e.clientY - startY;
          if (Math.hypot(dx, dy) > 6) moved = true;
          if (!moved) return;
          item.x = Math.min(394, Math.max(8, ox + dx));
          item.y = Math.min(TIMELINE_H - 8, Math.max(8, oy + dy));
          applyPlacedStyle(node, item);
        };
        const onUp = async () => {
          window.removeEventListener("pointermove", onMove);
          window.removeEventListener("pointerup", onUp);
          if (!moved) {
            state.activePlaced = state.activePlaced === id ? null : id;
            renderDay();
            return;
          }
          await savePlaced();
        };
        window.addEventListener("pointermove", onMove);
        window.addEventListener("pointerup", onUp);
      });
      node.addEventListener("wheel", (ev) => {
        if (state.activePlaced !== id) return;
        ev.preventDefault();
        const item = state.placed.find((p) => p.id === id);
        if (!item) return;
        if (ev.shiftKey) item.rotation = (item.rotation || 0) + (ev.deltaY > 0 ? 8 : -8);
        else item.scale = Math.min(2.4, Math.max(0.4, (item.scale || 1) * (ev.deltaY > 0 ? 0.94 : 1.06)));
        applyPlacedStyle(node, item);
        clearTimeout(node._saveT);
        node._saveT = setTimeout(() => savePlaced(), 180);
      }, { passive: false });
    });
  }

  function bindStickerTray() {
    const tray = $("sticker-tray");
    if (!tray) return;
    tray.querySelectorAll("[data-sticker]").forEach((btn) => {
      btn.addEventListener("pointerdown", (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const st = STICKERS.find((s) => s.id === btn.dataset.sticker);
        if (!st) return;
        const ghost = document.createElement("img");
        ghost.className = "ghost-sticker";
        ghost.src = `/assets/stickers/${st.name}.png`;
        ghost.style.left = `${ev.clientX}px`;
        ghost.style.top = `${ev.clientY}px`;
        document.body.appendChild(ghost);
        let lastX = ev.clientX;
        let lastY = ev.clientY;
        const onMove = (e) => {
          lastX = e.clientX;
          lastY = e.clientY;
          ghost.style.left = `${lastX}px`;
          ghost.style.top = `${lastY}px`;
        };
        const finish = async (e) => {
          window.removeEventListener("pointermove", onMove);
          window.removeEventListener("pointerup", finish);
          window.removeEventListener("pointercancel", finish);
          ghost.remove();
          const pt = pagePoint(e.clientX || lastX, e.clientY || lastY);
          if (!pt) { flash("这一页还没准备好"); return; }
          try {
            await dropSticker(st, pt.x, pt.y);
          } catch (err) {
            flash(err.message || "贴纸没贴上");
          }
        };
        window.addEventListener("pointermove", onMove);
        window.addEventListener("pointerup", finish);
        window.addEventListener("pointercancel", finish);
      }, { passive: false });
    });
  }

  async function dropSticker(st, x, y) {
    const id = uid();
    state.placed.push({
      id,
      kind: "sticker",
      stickerID: st.id,
      x,
      y,
      scale: 1,
      rotation: (Math.random() * 10) - 5,
      placedAt: new Date().toISOString(),
    });
    state.activePlaced = id;
    await savePlaced();
    renderDay();
    requestAnimationFrame(() => {
      document.querySelector(`[data-placed="${id}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" });
    });
  }

  async function savePlaced() {
    const date = isoDate(state.year, state.month, state.day);
    await api(`/api/v1/calendar/placed/${date}`, { method: "PUT", body: JSON.stringify({ items: state.placed }) });
    markDirty();
  }

  function markDirty() { state.dirty = true; }

  async function uploadPage() {
    if (!state.dirty) return;
    const sheet = $("day-sheet");
    if (!sheet || !window.html2canvas) return;
    const canvas = await window.html2canvas(sheet, {
      backgroundColor: "#ffffff",
      scale: 2,
      useCORS: true,
    });
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
    if (!blob) return;
    const date = isoDate(state.year, state.month, state.day);
    const fd = new FormData();
    fd.append("file", blob, `${date}.png`);
    await api(`/api/v1/calendar/pages/${date}/render`, {
      method: "POST",
      body: fd,
    });
    state.dirty = false;
  }

  async function shiftMonth(delta) {
    state.month += delta;
    if (state.month < 1) { state.month = 12; state.year -= 1; }
    if (state.month > 12) { state.month = 1; state.year += 1; }
    await loadMonth();
    renderMonth();
  }

  async function openDay(day) {
    state.day = day;
    state.view = "day";
    state.dirty = false;
    state.activeNote = null;
    state.editingNote = null;
    state.fabOpen = false;
    await loadDay();
    renderDay();
    requestAnimationFrame(() => {
      const sel = document.querySelector("[data-strip].today, [data-strip] img");
      const strip = $("week-strip");
      const cur = strip && strip.querySelector(`[data-strip="${isoDate(state.year, state.month, state.day)}"]`);
      if (cur) cur.scrollIntoView({ inline: "center", block: "nearest" });
    });
  }

  async function jumpDate(key) {
    await uploadPage();
    const [y, m, d] = key.split("-").map(Number);
    state.year = y; state.month = m; state.day = d;
    await loadDay();
    renderDay();
  }

  async function backToMonth() {
    await uploadPage();
    state.view = "month";
    state.trayOpen = false;
    state.activePlaced = null;
    await loadMonth();
    renderMonth();
  }

  function openModal(html) {
    const modal = $("modal");
    modal.hidden = false;
    modal.innerHTML = `<div class="sheet">${html}</div>`;
    modal.querySelector("[data-close]")?.addEventListener("click", closeModal);
    modal.addEventListener("click", (e) => { if (e.target === modal) closeModal(); });
  }
  function closeModal() {
    $("modal").hidden = true;
    $("modal").innerHTML = "";
  }

  function openEventEditor(id) {
    const ev = id ? state.events.find((e) => e.id === id) : null;
    let sh = 20, sm = 0, eh = 21, em = 0, allDay = false, title = "";
    if (ev) {
      title = ev.title || "";
      allDay = isAllDay(ev);
      const s = inShanghai(parseUTC(ev.starts_at));
      const e = inShanghai(parseUTC(ev.ends_at) || parseUTC(ev.starts_at));
      sh = s.getUTCHours(); sm = s.getUTCMinutes();
      eh = e.getUTCHours(); em = e.getUTCMinutes();
    }
    openModal(`
      <h2>${ev ? "改一条" : "写一条"}</h2>
      <label>标题</label>
      <input id="ev-title" value="${esc(title)}" maxlength="160">
      <label><input type="checkbox" id="ev-all" ${allDay ? "checked" : ""}> 全天</label>
      <label>开始</label>
      <input id="ev-start" type="time" value="${pad(sh)}:${pad(sm)}">
      <label>结束</label>
      <input id="ev-end" type="time" value="${pad(eh)}:${pad(em)}">
      <div class="actions">
        <button type="button" id="ev-save">放下</button>
        <button type="button" class="ghost" data-close>先不写了</button>
        ${ev ? `<button type="button" class="danger" id="ev-del">撕掉</button>` : ""}
      </div>`);
    $("modal").querySelector("#ev-save").addEventListener("click", async () => {
      const titleEl = $("modal").querySelector("#ev-title");
      const name = titleEl.value.trim();
      if (!name) { titleEl.focus(); return; }
      const all = $("modal").querySelector("#ev-all").checked;
      const [a, b] = $("modal").querySelector("#ev-start").value.split(":").map(Number);
      const [c, d] = $("modal").querySelector("#ev-end").value.split(":").map(Number);
      const date = isoDate(state.year, state.month, state.day);
      const body = all
        ? { title: name, precision: "day", starts_at: `${date}T00:00:00+08:00`, ends_at: nextDay(date) + "T00:00:00+08:00" }
        : { title: name, precision: "hour", starts_at: `${date}T${pad(a)}:${pad(b)}:00+08:00`, ends_at: `${date}T${pad(c)}:${pad(d)}:00+08:00` };
      if (ev) await api(`/api/v1/calendar/events/${ev.id}`, { method: "PATCH", body: JSON.stringify(body) });
      else await api("/api/v1/calendar/events", { method: "POST", body: JSON.stringify(body) });
      closeModal();
      markDirty();
      await loadDay();
      renderDay();
    });
    $("modal").querySelector("#ev-del")?.addEventListener("click", async () => {
      await api(`/api/v1/calendar/events/${ev.id}`, { method: "DELETE" });
      closeModal();
      markDirty();
      await loadDay();
      renderDay();
    });
  }

  function nextDay(date) {
    const [y, m, d] = date.split("-").map(Number);
    const dt = new Date(Date.UTC(y, m - 1, d + 1));
    return isoDate(dt.getUTCFullYear(), dt.getUTCMonth() + 1, dt.getUTCDate());
  }

  async function addNote() {
    const date = isoDate(state.year, state.month, state.day);
    const y = 34 + state.notes.length * 116;
    const created = await api("/api/v1/calendar/notes", {
      method: "POST",
      body: JSON.stringify({ body: "写点什么", anchor_date: date, y }),
    });
    state.notes.push(created);
    state.activeNote = created.id;
    state.editingNote = created.id;
    markDirty();
    renderDay();
    requestAnimationFrame(() => document.querySelector(`[data-note="${created.id}"] .body`)?.focus());
  }

  function openStickerTray() {
    state.trayOpen = !state.trayOpen;
    state.fabOpen = false;
    renderDay();
  }

  function pickPhoto() {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "image/*";
    input.addEventListener("change", async () => {
      const file = input.files && input.files[0];
      if (!file) return;
      const blob = await compressPhoto(file);
      const fd = new FormData();
      fd.append("file", blob, "photo.jpg");
      const saved = await api("/api/v1/calendar/photos", { method: "POST", body: fd });
      state.placed.push({
        id: uid(),
        kind: "photo",
        photoFile: saved.file,
        x: 220,
        y: 280,
        scale: 1,
        rotation: -4,
        placedAt: new Date().toISOString(),
      });
      await savePlaced();
      renderDay();
    });
    input.click();
  }

  async function compressPhoto(file) {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bmp.width * scale);
    canvas.height = Math.round(bmp.height * scale);
    canvas.getContext("2d").drawImage(bmp, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.86));
    return blob;
  }

  async function openBook() {
    const err = $("unlock-err");
    err.textContent = "";
    const typed = $("token").value.trim();
    if (typed) state.token = typed;
    if (!state.token) { err.textContent = "先把钥匙填上"; return; }
    try {
      await api("/api/v1/calendar/events?limit=1");
    } catch (e) {
      err.textContent = e.message || "打不开";
      return;
    }
    localStorage.setItem("calendarToken", state.token);
    const t = todayParts();
    state.year = t.y; state.month = t.m; state.day = t.day;
    state.view = "month";
    await loadMonth();
    renderMonth();
  }

  $("open-book").addEventListener("click", openBook);
  $("token").addEventListener("keydown", (e) => { if (e.key === "Enter") openBook(); });

  const t = todayParts();
  state.year = t.y; state.month = t.m;
  if (state.token) {
    openBook().catch(() => renderUnlock());
  } else {
    renderUnlock();
  }
})();
