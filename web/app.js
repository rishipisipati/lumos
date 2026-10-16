const q = document.getElementById("q");
const rows = document.getElementById("rows");
const empty = document.getElementById("empty");
const counts = document.getElementById("counts");
const timing = document.getElementById("timing");
const message = document.getElementById("message");
const hidden = document.getElementById("hidden");

let debounceId = 0;
let selected = -1;
let current = [];
let searchGeneration = 0;

function formatCount(value) {
  return value.toLocaleString("en-US");
}

async function fetchJSON(url, options) {
  const response = await fetch(url, options);
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || "Request failed");
  }
  return payload;
}

async function runSearch() {
  const generation = ++searchGeneration;
  const params = new URLSearchParams();
  params.set("q", q.value);
  params.set("limit", "200");
  params.set("offset", "0");
  params.set("hidden", hidden.checked ? "1" : "0");
  const payload = await fetchJSON("/api/search?" + params.toString());
  if (generation !== searchGeneration) {
    return;
  }
  current = payload.results;
  selected = current.length > 0 ? 0 : -1;
  renderRows();
  const resultLabel = q.value.trim() === "" ? "" : formatCount(payload.results.length) + " shown · ";
  counts.textContent = resultLabel + formatCount(payload.objects) + " objects";
  timing.textContent = payload.elapsed_ms + " ms";
}

function renderRows() {
  rows.innerHTML = "";
  empty.classList.toggle("visible", current.length === 0);
  current.forEach((item, index) => {
    const tr = document.createElement("tr");
    if (index === selected) {
      tr.className = "selected";
    }
    tr.innerHTML =
      "<td class=\"col-name\"></td>" +
      "<td class=\"col-path\"></td>" +
      "<td class=\"col-size\"></td>" +
      "<td class=\"col-date\"></td>";
    tr.children[0].textContent = item.name;
    tr.children[1].textContent = item.parent;
    tr.children[2].textContent = item.size_label;
    tr.children[3].textContent = item.modified_label;
    tr.addEventListener("mousedown", () => {
      selected = index;
      renderRows();
    });
    tr.addEventListener("dblclick", () => {
      selected = index;
      openSelected(false);
    });
    rows.appendChild(tr);
  });
}

async function openSelected(reveal) {
  if (selected < 0 || selected >= current.length) {
    return;
  }
  const path = current[selected].path;
  const url = reveal ? "/api/reveal" : "/api/open";
  await fetchJSON(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path: path }),
  });
}

function scheduleSearch() {
  window.clearTimeout(debounceId);
  debounceId = window.setTimeout(() => {
    runSearch().catch((error) => {
      message.textContent = error.message;
    });
  }, 40);
}

async function pollStatus() {
  try {
    const payload = await fetchJSON("/api/status");
    message.textContent = payload.message;
    if (q.value.trim() === "") {
      counts.textContent = formatCount(payload.objects) + " objects";
    }
  } catch (error) {
    message.textContent = error.message;
  }
}

q.addEventListener("input", scheduleSearch);
hidden.addEventListener("change", scheduleSearch);
q.addEventListener("keydown", (event) => {
  if (event.key === "ArrowDown") {
    event.preventDefault();
    selected = Math.min(current.length - 1, selected + 1);
    renderRows();
  } else if (event.key === "ArrowUp") {
    event.preventDefault();
    selected = Math.max(0, selected - 1);
    renderRows();
  } else if (event.key === "Enter") {
    event.preventDefault();
    openSelected(event.metaKey).catch((error) => {
      message.textContent = error.message;
    });
  } else if (event.key === "Escape") {
    q.value = "";
    scheduleSearch();
  }
});

q.focus();
runSearch().catch((error) => {
  message.textContent = error.message;
});
pollStatus();
window.setInterval(pollStatus, 1500);
