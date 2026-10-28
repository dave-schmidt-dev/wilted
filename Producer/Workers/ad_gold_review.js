// Vanilla JS for Ad Gold Review client
let currentSlug = null;
let currentEpisode = null;
let currentReview = null;
let currentWords = [];
let currentGaps = [];
let selectedRangeId = null;
let stopPlaybackAt = null;
let patternTimer = null;

const audio = document.getElementById("audio-player");
const audioTime = document.getElementById("audio-time");
const showListEl = document.getElementById("show-list");
const emptyStateEl = document.getElementById("empty-state");
const showContentEl = document.getElementById("show-content");
const showNameEl = document.getElementById("show-name");
const episodeTitleEl = document.getElementById("episode-title");
const showStatusBadge = document.getElementById("show-status-badge");
const saveStatusEl = document.getElementById("save-status");
const patternInput = document.getElementById("pattern-input");
const rangesContainer = document.getElementById("ranges-container");
const gapsContainer = document.getElementById("gaps-container");

function formatHms(sec) {
  const s = Math.max(0, Math.floor(sec || 0));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  return `${h}:${m.toString().padStart(2, "0")}:${r.toString().padStart(2, "0")}`;
}

function formatMs(sec) {
  const s = Math.max(0, Math.floor(sec || 0));
  return `${Math.floor(s / 60)}:${(s % 60).toString().padStart(2, "0")}`;
}

audio.ontimeupdate = () => {
  audioTime.textContent = formatHms(audio.currentTime);
  if (stopPlaybackAt !== null && audio.currentTime >= stopPlaybackAt) {
    audio.pause();
    stopPlaybackAt = null;
  }
};

function playSpan(start, stop) {
  audio.currentTime = Math.max(0, start);
  stopPlaybackAt = stop;
  audio.play();
}

function updateBadgeClass(el, status) {
  el.textContent = status;
  el.className = "badge";
  const map = { unreviewed: "badge-unreviewed", "in-progress": "badge-in-progress", confirmed: "badge-confirmed", "needs-second-episode": "badge-needs-second" };
  if (map[status]) el.classList.add(map[status]);
}

async function loadShowList() {
  try {
    const res = await fetch("/api/shows");
    if (!res.ok) return;
    const shows = await res.json();
    showListEl.textContent = "";

    shows.forEach((s) => {
      const li = document.createElement("li");
      li.className = "show-item" + (s.slug === currentSlug ? " active" : "") + (!s.hasLabels ? " disabled" : "");
      li.dataset.testid = "show-" + s.slug;

      const header = document.createElement("div");
      header.className = "show-item-header";
      const title = document.createElement("span");
      title.className = "show-item-title";
      title.textContent = s.show;
      const badge = document.createElement("span");
      updateBadgeClass(badge, s.status);
      header.append(title, badge);

      const meta = document.createElement("div");
      meta.className = "show-item-meta";
      meta.textContent = s.hasLabels ? `Pending: ${s.pendingCount} / ${s.rangeCount}` : "Awaiting labels";
      li.append(header, meta);

      if (s.hasLabels) {
        li.onclick = () => {
          window.location.hash = "#" + s.slug;
          loadShow(s.slug);
        };
      }
      showListEl.appendChild(li);
    });
  } catch (e) {
    console.error("Failed to load show list:", e);
  }
}

async function loadShow(slug) {
  currentSlug = slug;
  stopPlaybackAt = null;
  selectedRangeId = null;
  try {
    const res = await fetch("/api/shows/" + slug);
    if (!res.ok) return;
    const data = await res.json();
    currentEpisode = data.episode;
    currentReview = data.review;
    currentWords = data.words || [];
    currentGaps = data.gaps || [];

    emptyStateEl.style.display = "none";
    showContentEl.style.display = "flex";
    showNameEl.textContent = currentEpisode.show || slug;
    episodeTitleEl.textContent = currentEpisode.title || "";
    updateBadgeClass(showStatusBadge, currentReview.status);

    patternInput.value = currentReview.pattern || "";
    audio.src = "/audio/" + slug;
    audio.load();

    renderRanges();
    renderGaps();
    loadShowList();
  } catch (e) {
    console.error("Failed to load show:", e);
  }
}

async function saveReview() {
  if (!currentSlug || !currentReview) return;
  saveStatusEl.textContent = "Saving...";
  try {
    const res = await fetch(`/api/shows/${currentSlug}/review`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(currentReview),
    });
    if (!res.ok) {
      saveStatusEl.textContent = "Save failed";
      return;
    }
    const data = await res.json();
    currentReview.updatedAt = data.updatedAt;
    saveStatusEl.textContent = "Saved";
    loadShowList();
  } catch (e) {
    saveStatusEl.textContent = "Save failed";
  }
}

function markEdited() {
  if (currentReview.status === "unreviewed") {
    currentReview.status = "in-progress";
    updateBadgeClass(showStatusBadge, currentReview.status);
  }
  saveReview();
  renderRanges();
}

patternInput.oninput = () => {
  currentReview.pattern = patternInput.value;
  if (currentReview.status === "unreviewed") {
    currentReview.status = "in-progress";
    updateBadgeClass(showStatusBadge, currentReview.status);
  }
  clearTimeout(patternTimer);
  patternTimer = setTimeout(saveReview, 500);
};

document.getElementById("btn-confirm-rest").onclick = () => {
  if (!currentReview) return;
  (currentReview.ranges || []).forEach((r) => {
    if (r.decision === "pending") r.decision = "confirmed";
  });
  currentReview.status = "confirmed";
  updateBadgeClass(showStatusBadge, currentReview.status);
  saveReview();
  renderRanges();
};

document.getElementById("btn-second-ep").onclick = () => {
  if (!currentReview) return;
  currentReview.status = "needs-second-episode";
  updateBadgeClass(showStatusBadge, currentReview.status);
  saveReview();
  renderRanges();
};

function addOwnerRange(from, to) {
  const dur = currentEpisode.durationSeconds || 1000;
  const start = Math.min(from, Math.max(0, dur - 1));
  const newRange = {
    id: "owner-" + Date.now() + "-" + Math.random().toString(36).slice(2, 6),
    start_s: start,
    end_s: Math.min(Math.max(to, start + 1), dur),
    kind: "sponsor",
    label: "must-cut",
    decision: "pending",
    origin: "owner",
    opus: null,
  };
  currentReview.ranges.push(newRange);
  selectedRangeId = newRange.id;
  markEdited();
}

document.getElementById("btn-add-ad").onclick = () => {
  if (!currentReview) return;
  const t = audio.currentTime || 0;
  addOwnerRange(t, t + 30);
};

// Moves a range edge to the playhead, for edges the transcript has no words for.
function setEdgeToPlayhead(r, which) {
  const t = Math.round((audio.currentTime || 0) * 100) / 100;
  if (which === "start" && t < r.end_s) r.start_s = t;
  else if (which === "end" && t > r.start_s) r.end_s = t;
  else return;
  markEdited();
}

function renderGaps() {
  gapsContainer.textContent = "";
  if (currentGaps.length === 0) {
    gapsContainer.textContent = "None.";
    return;
  }
  currentGaps.forEach(([start, end]) => {
    const row = document.createElement("div");
    row.className = "gap-row";
    row.dataset.testid = "gap-" + Math.round(start);
    const time = document.createElement("span");
    time.className = "range-time";
    time.textContent = `${formatMs(start)} - ${formatMs(end)} (${(end - start).toFixed(0)}s)`;
    row.appendChild(time);
    addBtn(row, "gap-play", "Play", () => playSpan(start, end));
    addBtn(row, "gap-add", "Add as ad", () => { if (currentReview) addOwnerRange(start, end); });
    gapsContainer.appendChild(row);
  });
}

function addBtn(parent, testid, text, onClick) {
  const btn = document.createElement("button");
  btn.dataset.testid = testid;
  btn.textContent = text;
  btn.onclick = onClick;
  parent.appendChild(btn);
  return btn;
}

function renderRanges() {
  rangesContainer.textContent = "";
  if (!currentReview || !currentReview.ranges) return;
  currentReview.ranges.sort((a, b) => a.start_s - b.start_s);

  if (!selectedRangeId && currentReview.ranges.length > 0) {
    selectedRangeId = currentReview.ranges[0].id;
  }

  currentReview.ranges.forEach((r) => {
    const row = document.createElement("div");
    row.className = "range-row" + (r.id === selectedRangeId ? " selected" : "");
    row.dataset.testid = "range-" + r.id;
    const conf = r.confidence || (r.opus && r.opus.confidence) || "";
    if (conf === "low") row.classList.add("low-confidence");

    row.onclick = (e) => {
      if (e.target.tagName !== "BUTTON" && !e.target.classList.contains("edge-word")) {
        selectedRangeId = r.id;
        renderRanges();
      }
    };

    const meta = document.createElement("div");
    meta.className = "range-meta";
    const timeSpan = document.createElement("span");
    timeSpan.className = "range-time";
    timeSpan.textContent = `${formatMs(r.start_s)} - ${formatMs(r.end_s)} (${(r.end_s - r.start_s).toFixed(1)}s)`;
    meta.appendChild(timeSpan);

    [r.kind, r.label, conf ? conf + " conf" : "", r.sponsor || (r.opus && r.opus.sponsor) || "", r.decision].forEach((txt) => {
      if (!txt) return;
      const b = document.createElement("span");
      b.className = "badge";
      b.textContent = txt;
      meta.appendChild(b);
    });

    const note = (r.opus && r.opus.note) || r.note;
    if (note) {
      const n = document.createElement("span");
      n.className = "range-note";
      n.textContent = "Note: " + note;
      meta.appendChild(n);
    }
    row.appendChild(meta);

    const actions = document.createElement("div");
    actions.className = "range-actions";
    addBtn(actions, "play-start", "Play start", () => playSpan(r.start_s - 5, r.start_s + 5));
    addBtn(actions, "play-end", "Play end", () => playSpan(r.end_s - 5, r.end_s + 5));
    addBtn(actions, "play-all", "Play all", () => playSpan(r.start_s, r.end_s));
    addBtn(actions, "start-here", "Start = playhead", () => setEdgeToPlayhead(r, "start"));
    addBtn(actions, "end-here", "End = playhead", () => setEdgeToPlayhead(r, "end"));
    addBtn(actions, "confirm", "Confirm", () => { r.decision = "confirmed"; markEdited(); });
    addBtn(actions, "not-ad", "Not an ad", () => { r.label = "not-ad"; r.decision = "confirmed"; markEdited(); });
    addBtn(actions, "either-way", "Either way", () => { r.label = "acceptable-cut"; r.decision = "confirmed"; markEdited(); });
    addBtn(actions, "undo", "Undo", () => {
      r.decision = "pending";
      if (r.origin === "opus" && r.opus) r.label = r.opus.label || "must-cut";
      markEdited();
    });
    if (r.origin === "owner") {
      addBtn(actions, "delete", "Delete", () => {
        currentReview.ranges = currentReview.ranges.filter((x) => x.id !== r.id);
        markEdited();
      });
    }
    row.appendChild(actions);

    renderEdgeLine(row, "Start edge:", r.start_s, (w) => {
      if (w[0] < r.end_s) { r.start_s = w[0]; markEdited(); }
    }, (w) => w[0]);

    renderEdgeLine(row, "End edge:", r.end_s, (w) => {
      if (w[1] > r.start_s) { r.end_s = w[1]; markEdited(); }
    }, (w) => w[1]);

    rangesContainer.appendChild(row);
  });
}

function renderEdgeLine(row, labelText, targetTime, onClick, edgeGetter) {
  const line = document.createElement("div");
  line.className = "edge-line";
  const lbl = document.createElement("span");
  lbl.className = "edge-label";
  lbl.textContent = labelText;
  line.appendChild(lbl);

  const words = currentWords.filter((w) => w[1] >= targetTime - 8 && w[0] <= targetTime + 8);
  let bestWord = null;
  let minDist = Infinity;
  words.forEach((w) => {
    const dist = Math.abs(edgeGetter(w) - targetTime);
    if (dist < minDist) { minDist = dist; bestWord = w; }
  });

  words.forEach((w) => {
    const span = document.createElement("span");
    span.className = "edge-word" + (w === bestWord ? " edge-highlight" : "");
    span.textContent = w[2] + " ";
    span.onclick = () => onClick(w);
    line.appendChild(span);
  });
  row.appendChild(line);
}

window.addEventListener("keydown", (e) => {
  const tag = (e.target && e.target.tagName) || "";
  if (tag === "TEXTAREA" || tag === "INPUT") return;

  if (e.code === "Space") {
    e.preventDefault();
    if (audio.paused) audio.play();
    else audio.pause();
    return;
  }
  if (!currentReview || !currentReview.ranges || currentReview.ranges.length === 0) return;
  const ranges = currentReview.ranges;
  const idx = ranges.findIndex((r) => r.id === selectedRangeId);

  if (e.key === "j" || e.key === "k") {
    e.preventDefault();
    const nextIdx = e.key === "j" ? (idx < ranges.length - 1 ? idx + 1 : 0) : (idx > 0 ? idx - 1 : ranges.length - 1);
    selectedRangeId = ranges[nextIdx].id;
    renderRanges();
    const el = document.querySelector(".range-row.selected");
    if (el) el.scrollIntoView({ block: "nearest" });
  } else if (idx !== -1) {
    const cur = ranges[idx];
    if (e.key === "y") { e.preventDefault(); cur.decision = "confirmed"; markEdited(); }
    else if (e.key === "n") { e.preventDefault(); cur.label = "not-ad"; cur.decision = "confirmed"; markEdited(); }
    else if (e.key === "e") { e.preventDefault(); cur.label = "acceptable-cut"; cur.decision = "confirmed"; markEdited(); }
    else if (e.key === "s") { e.preventDefault(); playSpan(cur.start_s - 5, cur.start_s + 5); }
    else if (e.key === "d") { e.preventDefault(); playSpan(cur.end_s - 5, cur.end_s + 5); }
    else if (e.key === "[") { e.preventDefault(); setEdgeToPlayhead(cur, "start"); }
    else if (e.key === "]") { e.preventDefault(); setEdgeToPlayhead(cur, "end"); }
  }
});

window.addEventListener("DOMContentLoaded", () => {
  loadShowList();
  if (window.location.hash) {
    const slug = window.location.hash.slice(1);
    if (slug) loadShow(slug);
  }
});
