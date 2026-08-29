(() => {
  const I18N = {
    zh: {
      docTitle: "一本和 AI 共用的日历",
      unlockSub: "填钥匙，打开这一页",
      tokenLabel: "本机钥匙",
      open: "打开",
      staleFlash: "先刷新，这一本别处改过",
      badToken: "钥匙不对",
      staleBar: "这一本在别处改过，先刷新再动",
      refresh: "刷新",
      rotate: "转",
      scale: "大小",
      addEvent: "写一条安排",
      addNote: "贴一张便签",
      addSticker: "贴纸",
      addPhoto: "拍立得",
      trayHint: "按住拖到这一页上。点空白处放下、收起。",
      putAway: "收起",
      notePlaceholder: "写点什么",
      pageNotReady: "这一页还没准备好",
      stickerFail: "贴纸没贴上",
      editEvent: "改一条",
      newEvent: "写一条",
      title: "标题",
      keyword: "月历短词",
      keywordPh: "空着就从标题收一截",
      start: "开始",
      end: "结束",
      allDay: "全天",
      pin: "日程过多，月历优先显示",
      done: "做完了",
      rail: "钉在右上角（最多三条）",
      save: "放下",
      cancel: "先不写了",
      tear: "撕掉",
      railFull: "右上角最多三条",
      needToken: "先把钥匙填上",
      cantOpen: "打不开",
    },
    en: {
      docTitle: "A calendar shared with an AI",
      unlockSub: "tap the token, then open the page",
      tokenLabel: "local token",
      open: "open",
      staleFlash: "refresh first — this book changed elsewhere",
      badToken: "wrong token",
      staleBar: "this book changed elsewhere — refresh before editing",
      refresh: "refresh",
      rotate: "rotate",
      scale: "size",
      addEvent: "write an event",
      addNote: "stick a note",
      addSticker: "sticker",
      addPhoto: "polaroid",
      trayHint: "hold and drag onto the page. tap empty space to drop and close.",
      putAway: "close",
      notePlaceholder: "write something",
      pageNotReady: "this page isn’t ready yet",
      stickerFail: "sticker didn’t stick",
      editEvent: "edit",
      newEvent: "write",
      title: "title",
      keyword: "month keyword",
      keywordPh: "leave empty to shorten automatically",
      start: "start",
      end: "end",
      allDay: "all day",
      pin: "too many events — pin on the month",
      done: "done",
      rail: "pin to the top-right (max three)",
      save: "put down",
      cancel: "not now",
      tear: "tear off",
      railFull: "top-right only holds three",
      needToken: "fill in the token first",
      cantOpen: "couldn’t open",
    },
  };
  function detectLang() {
    const q = new URLSearchParams(location.search).get("lang");
    if (q === "en" || q === "zh") return q;
    const saved = localStorage.getItem("sharedPageLang");
    if (saved === "en" || saved === "zh") return saved;
    return String(navigator.language || "").toLowerCase().startsWith("zh") ? "zh" : "en";
  }
  let lang = detectLang();
  function tr(key) {
    const pack = I18N[lang] || I18N.en;
    const v = pack[key];
    return v == null ? (I18N.en[key] == null ? key : I18N.en[key]) : v;
  }
  const MONTHS_EN = ["January","February","March","April","May","June","July","August","September","October","November","December"];
  const WEEK_LETTERS = ["M","T","W","T","F","S","S"];
  const WEEKDAYS_EN = ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"];
  function monthName(m) { return MONTHS_EN[m - 1]; }
  function weekLetters() { return WEEK_LETTERS; }
  function weekdayName(i) { return WEEKDAYS_EN[i]; }
  function langToggleHtml() {
    return `<div class="lang" role="group" aria-label="language"><button type="button" data-lang="zh" class="${lang === "zh" ? "on" : ""}">中</button><button type="button" data-lang="en" class="${lang === "en" ? "on" : ""}">EN</button></div>`;
  }
  function applyLangChrome() {
    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
    document.title = tr("docTitle");
    const sub = document.getElementById("unlock-sub");
    if (sub) sub.textContent = tr("unlockSub");
    const lab = document.getElementById("unlock-token-label");
    if (lab) lab.textContent = tr("tokenLabel");
    const open = document.getElementById("open-book");
    if (open) open.textContent = tr("open");
    document.querySelectorAll("[data-lang]").forEach((b) => {
      b.classList.toggle("on", b.dataset.lang === lang);
    });
  }
  function setLang(next) {
    if (next !== "zh" && next !== "en") return;
    if (next === lang) return;
    const box = $("token");
    if (box && box.value.trim()) state.token = box.value.trim();
    lang = next;
    localStorage.setItem("sharedPageLang", lang);
    applyLangChrome();
    closeModal();
    if (state.view === "month") renderMonth();
    else if (state.view === "day") renderDay();
    else renderUnlock();
  }

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
    tokenRequired: false,
    view: "unlock",
    year: 0,
    month: 0,
    day: 1,
    events: [],
    yearEvents: [],
    notes: [],
    placed: [],
    unseen: new Set(),
    clock: "",
    stale: false,
    dirty: false,
    fabOpen: false,
    trayOpen: false,
    activeNote: null,
    editingNote: null,
    activePlaced: null,
    _draggingNote: false,
    _draggingPlaced: false,
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
    if (ev.source === "seed") return "kitty";
    return "master";
  }
  function authorName(a) {
    return a === "kitty" ? "USER" : "ASSISTANT";
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
  const RAIL_DEFAULT = [];
  function metaOf(ev) {
    const raw = ev && ev.metadata;
    if (raw && typeof raw === "object" && !Array.isArray(raw)) return raw;
    if (typeof raw === "string" && raw) {
      try {
        const o = JSON.parse(raw);
        return o && typeof o === "object" ? o : {};
      } catch (_) { return {}; }
    }
    return {};
  }
  function monthKeyword(ev) {
    const k = String(metaOf(ev).keyword || "").trim();
    if (k) return [...k].slice(0, 12).join("");
    const t = String(ev.title || "").trim();
    const chars = [...t];
    return chars.length <= 10 ? t : chars.slice(0, 10).join("");
  }
  function isStampType(ev) {
    return ["birthday", "anniversary"].includes(ev.event_type);
  }
  function monthLines(dayEvents) {
    const items = dayEvents.filter((e) => !isStampType(e));
    if (items.length <= 2) return items;
    const pinned = items.filter((e) => metaOf(e).pin);
    return (pinned.length ? pinned : items).slice(0, 2);
  }
  function railEvents(y) {
    const pool = (state.yearEvents && state.yearEvents.length) ? state.yearEvents : (state.events || []);
    const marks = pool.filter((e) => {
      if (e.status === "deleted") return false;
      if (!isStampType(e)) return false;
      const s = parseUTC(e.starts_at);
      if (!s) return false;
      return inShanghai(s).getUTCFullYear() === y;
    });
    const shown = marks.filter((e) => {
      const rail = metaOf(e).rail;
      if (rail === true) return true;
      if (rail === false) return false;
      return RAIL_DEFAULT.includes(e.title);
    });
    const uniq = [];
    const seen = new Set();
    shown.sort((a, b) => (parseUTC(a.starts_at) || 0) - (parseUTC(b.starts_at) || 0));
    for (const e of shown) {
      if (seen.has(e.title)) continue;
      seen.add(e.title);
      uniq.push(e);
      if (uniq.length === 3) break;
    }
    return uniq;
  }
  function mdOf(ev) {
    const s = inShanghai(parseUTC(ev.starts_at));
    if (!s) return "";
    return `${pad(s.getUTCMonth() + 1)}.${pad(s.getUTCDate())}`;
  }
  async function patchEventMeta(id, partial) {
    const ev = state.events.find((e) => e.id === id);
    const next = Object.assign({}, metaOf(ev), partial);
    await api(`/api/v1/calendar/events/${id}`, { method: "PATCH", body: JSON.stringify({ metadata: next }) });
    if (ev) ev.metadata = next;
    const yev = state.yearEvents.find((e) => e.id === id);
    if (yev) yev.metadata = next;
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
    const method = String(opts.method || "GET").toUpperCase();
    const guarded = method !== "GET" && /\/(events|notes|placed|photos)/.test(path);
    if (guarded && state.stale) {
      flash(tr("staleFlash"));
      throw new Error("stale");
    }
    if (guarded) state._writing = true;
    const headers = Object.assign({ "X-Calendar-Token": state.token }, opts.headers || {});
    if (opts.body && !(opts.body instanceof FormData) && !headers["Content-Type"]) {
      headers["Content-Type"] = "application/json";
    }
    try {
      const res = await fetch(path, Object.assign({}, opts, { headers }));
      if (res.status === 401) throw new Error(tr("badToken"));
      if (!res.ok) {
        let detail = res.statusText;
        try { detail = (await res.json()).detail || detail; } catch (_) {}
        throw new Error(detail);
      }
      if (res.status === 204) return null;
      const ct = res.headers.get("content-type") || "";
      if (ct.includes("application/json")) return res.json();
      return res;
    } finally {
      if (guarded) state._writing = false;
    }
  }

  function qn(n) {
    const x = Number(n);
    return Number.isFinite(x) ? Math.round(x * 10) / 10 : 0;
  }
  function clockOf(events, notes, placed) {
    const ev = (events || []).map((e) => `${e.id}:${e.revision || 0}:${e.title || ""}`).sort().join(",");
    const ns = (notes || []).map((n) => `${n.id}:${n.body || n.comment || ""}:${qn(n.y)}:${n.liked ? 1 : 0}`).sort().join(",");
    const pl = (placed || []).map((p) => `${p.id}:${qn(p.x)}:${qn(p.y)}:${qn(p.rotation)}:${qn(p.scale == null ? 1 : p.scale)}:${qn(p.z)}`).sort().join(",");
    return `${ev}#${ns}#${pl}`;
  }
  function currentClock() {
    if (state.view === "month") {
      return clockOf(state.yearEvents, [], []) + "#" + [...state.unseen].sort().join(",");
    }
    if (state.view === "day") {
      return clockOf(state.events, state.notes, state.placed);
    }
    return "";
  }
  function stampClock() {
    state.clock = currentClock();
    state.stale = false;
    state._pollGen = (state._pollGen || 0) + 1;
    state._quietUntil = Date.now() + 4000;
  }
  function staleBarHtml() {
    return `<div class="stale-bar">${tr("staleBar")}<button type="button" data-refresh>${tr("refresh")}</button></div>`;
  }
  function bindStale(host) {
    host.querySelector("[data-refresh]")?.addEventListener("click", () => refreshNow());
  }
  function showStaleBanner() {
    state.stale = true;
    const host = state.view === "month" ? $("month-view") : $("day-view");
    if (!host || host.hidden) return;
    if (host.querySelector(".stale-bar")) return;
    host.insertAdjacentHTML("afterbegin", staleBarHtml());
    bindStale(host);
  }
  async function refreshNow() {
    state.stale = false;
    closeModal();
    if (state.view === "day") {
      await loadDay();
      renderDay();
    } else {
      await loadMonth();
      renderMonth();
    }
  }
  async function checkStale() {
    if (state.view === "unlock" || state.stale || state._writing) return;
    if (state._draggingNote || state._draggingPlaced) return;
    if (document.hidden) return;
    if (Date.now() < (state._quietUntil || 0)) return;
    const gen = state._pollGen || 0;
    try {
      if (state.view === "month") {
        const y = state.year;
        const q = new URLSearchParams({ from: `${y}-01-01T00:00:00+08:00`, to: `${y + 1}-01-01T00:00:00+08:00`, limit: "500" });
        const [ev, unseen] = await Promise.all([
          api(`/api/v1/calendar/events?${q}`),
          api("/api/v1/calendar/unseen"),
        ]);
        if (gen !== (state._pollGen || 0)) return;
        const remote = clockOf(ev.events || [], [], []) + "#" + (unseen.days || []).slice().sort().join(",");
        if (state.clock && remote !== state.clock) showStaleBanner();
      } else if (state.view === "day") {
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
        if (gen !== (state._pollGen || 0)) return;
        const remote = clockOf(ev.events || [], notes.notes || [], placed.items || []);
        if (state.clock && remote !== state.clock) showStaleBanner();
      }
    } catch (_) {}
  }
  function startWatch() {
    if (state._watch) return;
    state._watch = setInterval(checkStale, 20000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) checkStale(); });
    window.addEventListener("focus", () => checkStale());
  }

  function monthRange(y, m) {
    const from = `${isoDate(y, m, 1)}T00:00:00+08:00`;
    const last = daysInMonth(y, m);
    const next = m === 12 ? `${y + 1}-01-01T00:00:00+08:00` : `${isoDate(y, m + 1, 1)}T00:00:00+08:00`;
    return { from, to: next, last };
  }

  async function loadMonth() {
    const y = state.year;
    const from = `${y}-01-01T00:00:00+08:00`;
    const to = `${y + 1}-01-01T00:00:00+08:00`;
    const q = new URLSearchParams({ from, to, limit: "500" });
    const [ev, unseen] = await Promise.all([
      api(`/api/v1/calendar/events?${q}`),
      api("/api/v1/calendar/unseen"),
    ]);
    state.events = ev.events || [];
    state.yearEvents = state.events;
    state.unseen = new Set(unseen.days || []);
    stampClock();
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
    stampClock();
  }

  function renderUnlock() {
    $("unlock").hidden = false;
    $("month-view").hidden = true;
    $("day-view").hidden = true;
    const box = $("token");
    const typed = box.value.trim();
    if (typed) state.token = typed;
    box.value = state.token;
    const need = !!state.tokenRequired;
    $("unlock-token-label").hidden = !need;
    $("token").hidden = !need;
    applyLangChrome();
  }

  function renderMonth() {
    $("unlock").hidden = true;
    $("day-view").hidden = true;
    const el = $("month-view");
    el.hidden = false;
    const now = todayParts();
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
      const isToday = inMonth && now.y === y && now.m === m && now.day === n;
      cells.push(`<div class="cell${inMonth ? "" : " dim"}${isToday ? " today" : ""}" ${inMonth ? `data-day="${n}"` : ""}>
        ${spans.slice(0, 2).map((s, idx) => `<div class="band ${authorOf(s)}" style="top:${17 + idx * 36}px"></div>`).join("")}
        ${stamp ? `<img class="stamp" src="/assets/stickers/stamp-heart-mini.png" alt="">` : ""}
        <div class="num">${disp}</div>
        <div class="titles">${monthLines(dayEvents).map((e) => {
          const done = !!metaOf(e).done;
          const ink = authorOf(e) === "master" ? "var(--ink-master)" : "var(--ink-kitty)";
          return `<div class="kw${done ? " done" : ""}" style="color:${ink}">${done ? "✓ " : ""}${esc(monthKeyword(e))}</div>`;
        }).join("")}</div>
        ${state.unseen.has(date) ? `<img class="new" src="/assets/stickers/red-exclaim-double.png" alt="">` : ""}
      </div>`);
    }
    el.innerHTML = `
      ${state.stale ? staleBarHtml() : ""}
      <div class="header">
        <div>
          <h1>${monthName(m)}<span class="year">${y}</span></h1>
          <p class="sub">tap a day to open it</p>
          ${langToggleHtml()}
        </div>
        <div class="nav-col">
          <div class="nav">
            <button type="button" data-nav="-1">◀</button>
            <button type="button" data-nav="1">▶</button>
          </div>
          <div class="rail">${railEvents(y).map((e) =>
            `<button type="button" data-rail="${esc(isoDate(inShanghai(parseUTC(e.starts_at)).getUTCFullYear(), inShanghai(parseUTC(e.starts_at)).getUTCMonth() + 1, inShanghai(parseUTC(e.starts_at)).getUTCDate()))}"><span class="md">${mdOf(e)}</span>${esc(e.title)}</button>`
          ).join("")}</div>
        </div>
      </div>
      <div class="card">
        <div class="weekdays">${weekLetters().map((w) => `<span>${w}</span>`).join("")}</div>
        ${Array.from({ length: rows }, (_, r) => `<div class="grid-row">${cells.slice(r * 7, r * 7 + 7).join("")}</div>`).join("")}
        <div class="legend">
          <span><i class="swatch" style="background:var(--ink-kitty)"></i>USER</span>
          <span><i class="swatch" style="background:var(--ink-master)"></i>ASSISTANT</span>
        </div>
      </div>`;
    el.querySelectorAll("[data-nav]").forEach((b) => b.addEventListener("click", () => shiftMonth(Number(b.dataset.nav))));
    el.querySelectorAll("[data-day]").forEach((c) => c.addEventListener("click", () => openDay(Number(c.dataset.day))));
    el.querySelectorAll("[data-rail]").forEach((b) => b.addEventListener("click", () => jumpDate(b.dataset.rail)));
    bindStale(el);
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
      return s && inShanghai(s).getUTCFullYear() === state.year && inShanghai(s).getUTCDate() === day && inShanghai(s).getUTCMonth() + 1 === state.month;
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
    const wd = weekdayName((leadingBlanks(state.year, state.month) + state.day - 1) % 7);
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
      const done = !!metaOf(ev).done;
      return `<div class="event-block ${a}${done ? " done" : ""}" data-event="${esc(ev.id)}" style="top:${top}px;height:${h}px">
        <div class="t">${esc(ev.title)}</div>
        <div class="meta">${pad(sh)}:${pad(sm)}–${pad(Math.floor(endH / 60))}:${pad(endH % 60)} · ${authorName(a)}</div>
      </div>`;
    }).join("");

    const notesHtml = state.notes.filter((n) => !n.deleted_at).map((n, i) => {
      const a = authorOf(n);
      const y = n.y ?? (34 + i * 116);
      const x = noteLeft(n.id);
      const editing = a === "kitty" && state.editingNote === n.id;
      const active = a === "kitty" && state.activeNote === n.id;
      const liked = n.liked ? `<img class="heart" src="/assets/stickers/red-heart-outline.png" alt="">` : "";
      const z = Number(noteXRecord(n.id)?.z || 3);
      const layer = active ? Math.max(z, 20) : z;
      return `<div class="note ${a}${active ? " active" : ""}${editing ? " editing" : ""}" data-note="${esc(n.id)}" data-author="${a}" style="top:${y}px${x == null ? "" : `;left:${x}px`};z-index:${layer}">
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
      const z = Number(item.z || 4);
      const layer = selected ? Math.max(z, 21) : z;
      const handles = selected ? `
        <button type="button" class="x" data-del-placed="${esc(item.id)}">✕</button>
        <button type="button" class="rot" data-rot-placed="${esc(item.id)}" aria-label="${tr("rotate")}"></button>
        <button type="button" class="scl" data-scl-placed="${esc(item.id)}" aria-label="${tr("scale")}"></button>` : "";
      const box = `left:${item.x}px;top:${item.y}px;z-index:${layer};--s:${scale};transform:translate(-50%,-50%) rotate(${rot}deg) scale(${scale})`;
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
      ${state.stale ? staleBarHtml() : ""}
      <button type="button" class="back" id="back-month"><span class="chev">‹</span><span class="mname">${monthName(state.month)}</span></button>
      <div class="week-strip" id="week-strip">${weekStripHtml()}</div>
      <div id="day-sheet">
        <div class="title-row"><span class="big">${monthName(state.month)} ${state.day}</span><span class="wd">${wd}</span></div>
        <div class="all-day">${allday.map((e) => {
          const done = !!metaOf(e).done;
          return `<div class="span${done ? " done" : ""}" data-event="${esc(e.id)}">${esc(e.title)}</div>`;
        }).join("")}</div>
        <div class="timeline" id="timeline">
          ${hours.join("")}
          ${eventHtml}
          ${notesHtml}
          ${placedHtml}
        </div>
      </div>
      <button type="button" class="fab" id="fab">+</button>
      <div class="fab-menu" id="fab-menu" ${state.fabOpen ? "" : "hidden"}>
        <button type="button" data-add="event">${tr("addEvent")}</button>
        <button type="button" data-add="note">${tr("addNote")}</button>
        <button type="button" data-add="sticker">${tr("addSticker")}</button>
        <button type="button" data-add="photo">${tr("addPhoto")}</button>
      </div>
      ${state.trayOpen ? `
      <div class="sticker-tray" id="sticker-tray">
        <p class="hint">${tr("trayHint")} <button type="button" class="tray-close" data-close-tray>${tr("putAway")}</button></p>
        <div class="row">${STICKERS.map((s) =>
          `<button type="button" data-sticker="${s.id}"><img src="/assets/stickers/${s.name}.png" alt=""></button>`
        ).join("")}</div>
      </div>` : ""}`;

    $("back-month").addEventListener("click", () => backToMonth());
    bindStale(el);
    el.querySelectorAll("[data-strip]").forEach((b) => b.addEventListener("click", () => jumpDate(b.dataset.strip)));
    el.querySelectorAll("[data-event]").forEach((b) => b.addEventListener("click", () => openEventEditor(b.dataset.event)));
    bindNotes();
    bindPlaced();
    bindStickerTray();
    $("fab").addEventListener("click", () => {
      if (state.trayOpen) {
        state.trayOpen = false;
        state.fabOpen = true;
        renderDay();
        return;
      }
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
      const now = todayParts();
      const today = y === now.y && m === now.m && day === now.day;
      const selected = i === 0;
      bits.push(`<button type="button" class="strip-cell${out ? " out" : ""}${today ? " today" : ""}" data-strip="${key}">
        <span class="w">${weekLetters()[(d.getUTCDay() + 6) % 7]}</span>
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
  function nextZ() {
    let m = 4;
    for (const p of state.placed) {
      const z = Number(p.z);
      if (Number.isFinite(z) && z > m) m = z;
    }
    return m + 1;
  }
  function raisePlaced(id) {
    const item = state.placed.find((p) => p.id === id);
    if (item) item.z = nextZ();
  }
  function raiseNote(id) {
    const rec = noteXRecord(id);
    const z = nextZ();
    if (rec) rec.z = z;
    else {
      state.placed.push({
        id: uid(),
        kind: "note-x",
        noteId: id,
        z,
      });
    }
  }

  function bindNotes() {
    if (!state._noteBlurBound) {
      state._noteBlurBound = true;
      document.addEventListener("pointerdown", (ev) => blurPage(ev));
    }
    document.querySelectorAll(".note").forEach((node) => {
      const id = node.dataset.note;
      const mine = node.dataset.author === "kitty";
      if (!mine) {
        node.addEventListener("dblclick", async (ev) => {
          ev.preventDefault();
          ev.stopPropagation();
          const n = state.notes.find((x) => x.id === id);
          if (!n) return;
          const next = !n.liked;
          await api(`/api/v1/calendar/notes/${id}`, { method: "PATCH", body: JSON.stringify({ liked: next }) });
          n.liked = next;
          markDirty();
          stampClock();
          renderDay();
        });
      }
      node.addEventListener("pointerdown", (ev) => {
        if (ev.target.closest("[data-del-note]")) return;
        if (mine && state.editingNote === id && ev.target.closest(".body")) return;
        if (!mine && ev.detail >= 2) return;
        ev.stopPropagation();
        if (mine) ev.preventDefault();
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
            raiseNote(id);
            await savePlaced();
            if (!mine) {
              renderDay();
              return;
            }
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
          raiseNote(id);
          const x = parseFloat(node.style.left);
          const y = parseFloat(node.style.top) || 0;
          await saveNotePos(id, x, y);
        };
        window.addEventListener("pointermove", onMove);
        window.addEventListener("pointerup", onUp);
        window.addEventListener("pointercancel", onUp);
      });
      const body = node.querySelector(".body");
      if (mine && body && body.isContentEditable) {
        body.addEventListener("blur", async () => {
          const text = body.innerText.trim() || tr("notePlaceholder");
          const n = state.notes.find((x) => x.id === id);
          if (n) n.body = text;
          markDirty();
          await api(`/api/v1/calendar/notes/${id}`, { method: "PATCH", body: JSON.stringify({ body: text }) });
          stampClock();
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

  function blurPage(ev) {
    if (state._draggingNote || state._draggingPlaced) return;
    if (ev.target.closest(".modal")) return;
    const onNote = ev.target.closest(".note");
    const onPlaced = ev.target.closest("[data-placed]");
    const onTray = ev.target.closest(".sticker-tray");
    const onFab = ev.target.closest(".fab") || ev.target.closest(".fab-menu");
    if (onNote || onFab) return;
    let need = false;
    if (state.activeNote || state.editingNote) {
      if (state.editingNote) {
        const body = document.querySelector(`[data-note="${state.editingNote}"] .body`);
        const n = state.notes.find((x) => x.id === state.editingNote);
        if (body && n) n.body = body.innerText.trim() || n.body;
      }
      state.activeNote = null;
      state.editingNote = null;
      need = true;
    }
    if (state.activePlaced && !onPlaced) {
      state.activePlaced = null;
      need = true;
    }
    if (state.trayOpen && !onTray) {
      state.trayOpen = false;
      need = true;
    }
    if (need) renderDay();
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
    node.style.zIndex = String(item.z || 4);
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
        state._draggingPlaced = true;
        const move = (e) => {
          item.rotation = startRot + (Math.atan2(e.clientY - cy, e.clientX - cx) - start) * 180 / Math.PI;
          applyPlacedStyle(node, item);
        };
        const up = async () => {
          window.removeEventListener("pointermove", move);
          window.removeEventListener("pointerup", up);
          state._draggingPlaced = false;
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
        state._draggingPlaced = true;
        const move = (e) => {
          const dist = Math.hypot(e.clientX - cx, e.clientY - cy);
          item.scale = Math.min(2.4, Math.max(0.4, startScale * dist / startDist));
          applyPlacedStyle(node, item);
        };
        const up = async () => {
          window.removeEventListener("pointermove", move);
          window.removeEventListener("pointerup", up);
          state._draggingPlaced = false;
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
        state._draggingPlaced = true;
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
          state._draggingPlaced = false;
          if (!moved) {
            raisePlaced(id);
            state.activePlaced = id;
            await savePlaced();
            renderDay();
            return;
          }
          raisePlaced(id);
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
    tray.querySelector("[data-close-tray]")?.addEventListener("click", (ev) => {
      ev.stopPropagation();
      state.trayOpen = false;
      renderDay();
    });
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
        state._draggingPlaced = true;
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
          state._draggingPlaced = false;
          ghost.remove();
          const pt = pagePoint(e.clientX || lastX, e.clientY || lastY);
          if (!pt) { flash(tr("pageNotReady")); return; }
          try {
            await dropSticker(st, pt.x, pt.y);
          } catch (err) {
            flash(err.message || tr("stickerFail"));
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
      z: nextZ(),
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
    stampClock();
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
    state.view = "day";
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
    const md = metaOf(ev);
    if (ev) {
      title = ev.title || "";
      allDay = isAllDay(ev);
      const s = inShanghai(parseUTC(ev.starts_at));
      const e = inShanghai(parseUTC(ev.ends_at) || parseUTC(ev.starts_at));
      sh = s.getUTCHours(); sm = s.getUTCMinutes();
      eh = e.getUTCHours(); em = e.getUTCMinutes();
    }
    const stamp = ev && isStampType(ev);
    const railOn = md.rail === true || (md.rail !== false && RAIL_DEFAULT.includes(title));
    openModal(`
      <h2>${ev ? tr("editEvent") : tr("newEvent")}</h2>
      <label>${tr("title")}</label>
      <input id="ev-title" value="${esc(title)}" maxlength="160">
      <label>${tr("keyword")}</label>
      <input id="ev-keyword" value="${esc(md.keyword || "")}" maxlength="12" placeholder="${tr("keywordPh")}">
      <label>${tr("start")}</label>
      <input id="ev-start" type="time" value="${pad(sh)}:${pad(sm)}">
      <label>${tr("end")}</label>
      <input id="ev-end" type="time" value="${pad(eh)}:${pad(em)}">
      <label class="check"><input type="checkbox" id="ev-all" ${allDay ? "checked" : ""}>${tr("allDay")}</label>
      <label class="check"><input type="checkbox" id="ev-pin" ${md.pin ? "checked" : ""}>${tr("pin")}</label>
      <label class="check"><input type="checkbox" id="ev-done" ${md.done ? "checked" : ""}>${tr("done")}</label>
      ${stamp ? `<label class="check"><input type="checkbox" id="ev-rail" ${railOn ? "checked" : ""}>${tr("rail")}</label>` : ""}
      <div class="actions">
        <button type="button" id="ev-save">${tr("save")}</button>
        <button type="button" class="ghost" data-close>${tr("cancel")}</button>
        ${ev ? `<button type="button" class="danger" id="ev-del">${tr("tear")}</button>` : ""}
      </div>`);
    $("modal").querySelector("#ev-save").addEventListener("click", async () => {
      const titleEl = $("modal").querySelector("#ev-title");
      const name = titleEl.value.trim();
      if (!name) { titleEl.focus(); return; }
      const all = $("modal").querySelector("#ev-all").checked;
      const [a, b] = $("modal").querySelector("#ev-start").value.split(":").map(Number);
      const [c, d] = $("modal").querySelector("#ev-end").value.split(":").map(Number);
      const date = isoDate(state.year, state.month, state.day);
      const keyword = $("modal").querySelector("#ev-keyword").value.trim();
      const pin = $("modal").querySelector("#ev-pin").checked;
      const done = $("modal").querySelector("#ev-done").checked;
      const railBox = $("modal").querySelector("#ev-rail");
      if (railBox && railBox.checked) {
        const already = railEvents(state.year).some((e) => e.id === (ev && ev.id));
        if (!already && railEvents(state.year).length >= 3) {
          flash(tr("railFull"));
          return;
        }
      }
      const metadata = Object.assign({}, md, { keyword, pin, done });
      if (railBox) metadata.rail = railBox.checked;
      const body = all
        ? { title: name, precision: "day", starts_at: `${date}T00:00:00+08:00`, ends_at: nextDay(date) + "T00:00:00+08:00", metadata }
        : { title: name, precision: "hour", starts_at: `${date}T${pad(a)}:${pad(b)}:00+08:00`, ends_at: `${date}T${pad(c)}:${pad(d)}:00+08:00`, metadata };
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
      body: JSON.stringify({ body: tr("notePlaceholder"), anchor_date: date, y }),
    });
    state.notes.push(created);
    state.activeNote = created.id;
    state.editingNote = created.id;
    markDirty();
    stampClock();
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
      const id = uid();
      state.placed.push({
        id,
        kind: "photo",
        photoFile: saved.file,
        x: 220,
        y: 280,
        scale: 1,
        rotation: -4,
        placedAt: new Date().toISOString(),
        z: nextZ(),
      });
      state.activePlaced = id;
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
    if (state.tokenRequired && !state.token) { err.textContent = tr("needToken"); return; }
    try {
      await api("/api/v1/calendar/events?limit=1");
    } catch (e) {
      err.textContent = e.message || tr("cantOpen");
      return;
    }
    if (state.token) localStorage.setItem("calendarToken", state.token);
    const now = todayParts();
    state.year = now.y; state.month = now.m; state.day = now.day;
    state.view = "month";
    await loadMonth();
    renderMonth();
    startWatch();
  }

  applyLangChrome();
  document.addEventListener("click", (e) => {
    const b = e.target.closest("[data-lang]");
    if (!b) return;
    e.preventDefault();
    setLang(b.dataset.lang);
  });
  $("open-book").addEventListener("click", openBook);
  $("token").addEventListener("keydown", (e) => { if (e.key === "Enter") openBook(); });

  (async () => {
    const now = todayParts();
    state.year = now.y; state.month = now.m;
    try {
      const ping = await fetch("/api/v1/calendar/ping").then((r) => r.json());
      state.tokenRequired = !!ping.token_required;
    } catch (_) {
      state.tokenRequired = true;
    }
    if (!state.tokenRequired) {
      openBook().catch(() => renderUnlock());
      return;
    }
    if (state.token) {
      openBook().catch(() => renderUnlock());
    } else {
      renderUnlock();
    }
  })();
})();
