// Flycut web history. Data goes into the page only as text (textContent), never as HTML. A credential's
// text is never in the page until Reveal is clicked; Hide takes it out again, and Copy without showing it
// fetches it straight to the clipboard.
"use strict";

const state = { list: 0, query: "", machine: "", offset: 0, clippings: [], selected: null, version: "", matched: 0 };
const $ = (id) => document.getElementById(id);

function element(tag, props = {}, ...children) {
	const node = document.createElement(tag);
	for (const [key, value] of Object.entries(props)) {
		if (key === "class") node.className = value;
		else if (key === "text") node.textContent = value;
		else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
		else node.setAttribute(key, value);
	}
	node.append(...children.filter((c) => c !== null && c !== undefined));
	return node;
}

async function api(path, options = {}) {
	const response = await fetch(path, { credentials: "same-origin", ...options });
	if (response.status === 401) {
		location.href = "login";
		throw new Error("signed out");
	}
	if (!response.ok) throw new Error(`${response.status} ${(await response.text()).trim()}`);
	return response;
}

const post = (path, body) => api(path, {
	method: "POST", headers: { "Content-Type": "application/json", "X-Flycut": "1" }, body: JSON.stringify(body),
});

function machineName(machine) {
	return machine.replace(/-[0-9a-f]{8}$/, "");
}

function relativeTime(ts) {
	if (!ts) return "";
	const age = Date.now() / 1000 - ts;
	if (age < 60) return "just now";
	if (age < 3600) return `${Math.floor(age / 60)} min ago`;
	if (age < 86400) return `${Math.floor(age / 3600)} h ago`;
	if (age < 7 * 86400) return `${Math.floor(age / 86400)} d ago`;
	return new Date(ts * 1000).toLocaleString();
}

function byteCount(n) {
	if (n < 1000) return `${n} bytes`;
	if (n < 1e6) return `${Math.round(n / 1e3)} KB`;
	return `${(n / 1e6).toFixed(1)} MB`;
}

function subtitle(c) {
	return [machineName(c.machine), c.app, relativeTime(c.ts), c.length > 200 ? `${c.length} characters` : null]
		.filter(Boolean).join(" · ");
}

const masked = (c) => `•••••••• credential, ${c.length} characters`;

function row(c) {
	const title = c.credential ? masked(c) : c.title || "(empty)";
	const li = element("li", { class: [c.credential ? "credential" : "", c.described ? "described" : ""].join(" ").trim(), tabindex: "-1" },
		element("span", { class: "title", text: title }),
		element("span", { class: "subtitle", text: subtitle(c) }));
	li.addEventListener("click", () => select(c));
	c.node = li;
	return li;
}

function query() {
	const params = new URLSearchParams({ list: state.list, offset: state.offset });
	if (state.query) params.set("q", state.query);
	if (state.machine) params.set("machine", state.machine);
	return `api/clippings?${params}`;
}

async function load(append = false) {
	if (!append) state.offset = 0;
	const data = await (await api(query())).json();
	state.version = data.version;
	state.matched = data.matched;
	if (!append) {
		state.clippings = [];
		$("clippings").replaceChildren();
	}
	for (const c of data.clippings) {
		state.clippings.push(c);
		$("clippings").append(row(c));
	}
	state.offset = state.clippings.length;
	$("more").hidden = state.clippings.length >= data.matched;
	$("count").textContent = data.matched === data.total ? `${data.total} clippings` : `${data.matched} of ${data.total} clippings`;
	updateMachines(data.machines);
	const keep = state.selected && state.clippings.find((c) => c.id === state.selected.id);
	if (keep) markSelected(keep);
	else if (!append) state.clippings.length ? select(state.clippings[0]) : showPlaceholder();
}

function updateMachines(machines) {
	const select = $("machine");
	const known = new Set([...select.options].map((o) => o.value));
	for (const machine of Object.keys(machines).sort()) {
		if (!known.has(machine)) select.append(element("option", { value: machine, text: machineName(machine) }));
	}
}

function showPlaceholder() {
	state.selected = null;
	$("detail").replaceChildren(element("p", { class: "placeholder", text: "Nothing here." }));
}

function markSelected(c) {
	for (const node of $("clippings").querySelectorAll(".selected")) node.classList.remove("selected");
	c.node.classList.add("selected");
	c.node.scrollIntoView({ block: "nearest" });
}

async function select(c) {
	state.selected = c;
	markSelected(c);
	const detail = await (await api(`api/clipping?${new URLSearchParams({ list: c.list, id: c.id })}`)).json();
	if (state.selected !== c) return;
	renderDetail(c, detail);
}

function blobURL(c, item, rep, download) {
	const params = new URLSearchParams({ list: c.list, id: c.id, item, rep });
	if (download) params.set("download", "1");
	return `api/blob?${params}`;
}

async function saveSealed(c, item, rep) {
	const response = await post("api/reveal-blob", { list: c.list, id: c.id, item: String(item), rep: String(rep) });
	const name = (response.headers.get("Content-Disposition") || "").match(/filename="([^"]+)"/);
	const url = URL.createObjectURL(await response.blob());
	element("a", { href: url, download: name ? name[1] : "clipping" }).click();
	setTimeout(() => URL.revokeObjectURL(url), 10000);
}

function formatsSection(c, formats) {
	if (!formats.length) return null;
	const list = element("ul", { class: "formats" });
	formats.forEach((item, i) => item.forEach((f, r) => {
		const save = f.sealed
			? element("button", { type: "button", class: "link", text: "save (sealed)", onclick: () => saveSealed(c, i, r).catch(showError) })
			: element("a", { href: blobURL(c, i, r, true), text: "save" });
		list.append(element("li", {},
			element("code", { text: f.t }), element("span", { text: ` ${byteCount(f.n)}${formats.length > 1 ? `, item ${i + 1}` : ""} ` }), save));
	}));
	return element("details", {}, element("summary", { text: `${formats.flat().length} formats` }), list);
}

function imagePreview(c, formats) {
	for (const [i, item] of formats.entries()) {
		const r = item.findIndex((f) => f.image);
		if (r >= 0) return element("img", { class: "preview", src: blobURL(c, i, r, false), alt: "image of this clipping" });
	}
	return null;
}

async function copyText(text, button) {
	await navigator.clipboard.writeText(text);
	const label = button.textContent;
	button.textContent = "Copied";
	setTimeout(() => { button.textContent = label; }, 1200);
}

function credentialBody(c) {
	const body = element("pre", { class: "text masked", text: masked(c) });
	const reveal = element("button", { type: "button", text: "Reveal" });
	const copy = element("button", { type: "button", text: "Copy without showing" });
	const fetchText = async () => (await (await post("api/reveal", { list: c.list, id: c.id })).json()).text;
	reveal.addEventListener("click", async () => {
		if (body.classList.contains("masked")) {
			const text = await fetchText().catch(showError);
			if (text === undefined) return;
			body.textContent = text;
			body.classList.remove("masked");
			reveal.textContent = "Hide";
		} else {
			body.textContent = masked(c);
			body.classList.add("masked");
			reveal.textContent = "Reveal";
		}
	});
	copy.addEventListener("click", async () => copyText(await fetchText(), copy).catch(showError));
	return [element("div", { class: "actions" }, reveal, copy), body];
}

function renderDetail(c, detail) {
	const header = element("div", { class: "meta" },
		element("span", { text: subtitle(c) }), element("code", { text: detail.type || "" }));
	const parts = [header];
	if (c.credential) {
		parts.push(...credentialBody(c));
	} else {
		const copy = element("button", { type: "button", text: "Copy text" });
		copy.addEventListener("click", () => copyText(detail.text, copy).catch(showError));
		parts.push(element("div", { class: "actions" }, copy));
		parts.push(imagePreview(c, detail.formats));
		parts.push(element("pre", { class: c.described ? "text described" : "text", text: detail.text }));
	}
	parts.push(formatsSection(c, detail.formats));
	$("detail").replaceChildren(...parts.filter(Boolean));
}

function showError(error) {
	if (error.message === "signed out") return;
	$("detail").prepend(element("p", { class: "error", text: `Something went wrong: ${error.message}` }));
}

function move(by) {
	const i = state.clippings.indexOf(state.selected);
	const next = state.clippings[Math.max(0, Math.min(state.clippings.length - 1, i + by))];
	if (next && next !== state.selected) select(next).catch(showError);
}

let searchTimer;
$("search").addEventListener("input", () => {
	clearTimeout(searchTimer);
	searchTimer = setTimeout(() => { state.query = $("search").value.trim(); load().catch(showError); }, 200);
});
$("machine").addEventListener("change", () => { state.machine = $("machine").value; load().catch(showError); });
$("more").addEventListener("click", () => load(true).catch(showError));
for (const button of document.querySelectorAll("#lists button")) {
	button.addEventListener("click", () => {
		for (const b of document.querySelectorAll("#lists button")) b.classList.toggle("active", b === button);
		state.list = Number(button.dataset.list);
		state.selected = null;
		load().catch(showError);
	});
}
document.addEventListener("keydown", (event) => {
	if (event.key === "/" && document.activeElement !== $("search")) {
		event.preventDefault();
		$("search").focus();
	} else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
		event.preventDefault();
		move(event.key === "ArrowDown" ? 1 : -1);
	} else if (event.key === "Escape" && document.activeElement === $("search")) {
		$("search").value = "";
		$("search").dispatchEvent(new Event("input"));
	}
});

// New copies show up without a reload: the first page is fetched again when the logs changed.
async function refresh() {
	if (document.hidden || state.offset > 200) return;
	const data = await (await api(query().replace(/offset=\d+/, "offset=0"))).json();
	if (data.version !== state.version) await load();
}
setInterval(() => refresh().catch(() => {}), 10000);
document.addEventListener("visibilitychange", () => refresh().catch(() => {}));

load().catch(showError);
