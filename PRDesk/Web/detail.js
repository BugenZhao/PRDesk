"use strict";

// Drives the detail pane's conversation and files pages. The app sends whole documents as JSON;
// they are patched in place by block id, so scrolling, expansion and loaded images survive updates.
const PRDesk = (() => {
  const root = document.getElementById("root");
  const post = (message) => window.webkit.messageHandlers.prdesk.postMessage(message);

  // MARK: Shared

  /** Same as Swift's `Date.compactAge`. */
  function compactAge(at) {
    const seconds = Math.max(0, (Date.now() - at) / 1000);
    const minutes = Math.floor(seconds / 60), hours = Math.floor(minutes / 60), days = Math.floor(hours / 24);
    if (seconds < 60) return "now";
    if (seconds < 3600) return `${minutes}m`;
    if (seconds < 86400) return `${hours}h`;
    if (seconds < 60 * 86400) return `${days}d`;
    if (seconds < 365 * 86400) return `${Math.floor(days / 30)}mo`;
    return `${Math.floor(days / 365)}y`;
  }

  function refreshAges(scope) {
    for (const element of scope.querySelectorAll("[data-at]")) {
      const text = compactAge(Number(element.dataset.at)) + " ago";
      if (element.textContent !== text) element.textContent = text;
    }
  }
  setInterval(() => refreshAges(document), 60_000);

  /** Parses HTML without loading anything yet, so images can be made lazy first. */
  function fragment(html) {
    const template = document.createElement("template");
    template.innerHTML = html;
    for (const image of template.content.querySelectorAll("img")) image.loading = "lazy";
    return template.content;
  }

  const escapeHTML = (text) => text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

  /** Whether the user is selecting text inside `element` (a click then shouldn't toggle it). */
  function isSelectingIn(element) {
    const selection = getSelection();
    return selection.type === "Range" && element.contains(selection.anchorNode);
  }

  let userScrolled = false;
  for (const type of ["wheel", "keydown", "mousedown"]) {
    addEventListener(type, () => { userScrolled = true; }, { passive: true, capture: true });
  }

  function scrollToElement(element) {
    const top = element.getBoundingClientRect().top + scrollY - 10;
    scrollTo(0, Math.max(0, top));
  }

  const nearBottom = () => innerHeight + scrollY >= document.documentElement.scrollHeight - 24;

  /** Places `elements` as `container`'s children in order, moving only what is out of place. */
  function arrange(container, elements) {
    let cursor = container.firstChild;
    for (const element of elements) {
      if (element === cursor) {
        cursor = cursor.nextSibling;
      } else {
        container.insertBefore(element, cursor);
      }
    }
    while (cursor) {
      const next = cursor.nextSibling;
      cursor.remove();
      cursor = next;
    }
  }

  // Right-clicking a person offers the app's vote menu instead of WebKit's.
  addEventListener("contextmenu", (event) => {
    const login = event.target.closest("[data-login]");
    if (login) {
      event.preventDefault();
      post({ type: "loginMenu", login: login.dataset.login, x: event.clientX, y: event.clientY });
      return;
    }
    const head = event.target.closest(".fhead");
    if (head && !event.target.closest("a")) {
      event.preventDefault();
      const file = head.parentElement;
      post({ type: "fileMenu", path: file.dataset.path, url: file.dataset.url || "", x: event.clientX, y: event.clientY });
    }
  });

  // MARK: Timeline

  const timeline = {
    key: null,
    /** The shown item's own link. */
    url: null,
    blocks: new Map(),
    /** Expansion the user chose per card, over the default. */
    expanded: new Map(),
    /** Expand all / Collapse all, over the defaults (not over later per-card choices). */
    all: null,
    /** Set when the page opened without new entries, so new ones arriving later can be shown. */
    awaitingNew: false,
    /** Scroll and expansion of items shown before, restored on coming back to them. */
    saved: new Map(),
  };

  /** Remembers `state` under `key`, keeping the most recent few dozen. */
  function remember(saved, key, state) {
    saved.delete(key);
    saved.set(key, state);
    if (saved.size > 50) saved.delete(saved.keys().next().value);
  }

  function isExpanded(element) {
    if (element._block.fixed) return true;
    return timeline.expanded.get(element.dataset.id) ?? timeline.all ?? element._block.expanded;
  }

  function applyExpansion(element) {
    const open = isExpanded(element);
    element.classList.toggle("collapsed", !open);
    if (open && element._bodyStale) {
      element._bodyStale = false;
      element.children[2].replaceChildren(fragment(element._block.body));
    }
  }

  function makeCard(block) {
    const element = document.createElement("article");
    element.dataset.id = block.id;
    element.innerHTML = '<header class="head"></header><div class="preview"></div><div class="body"></div><footer class="foot"></footer>';
    return element;
  }

  function updateCard(element, block) {
    const old = element._block || {};
    element._block = block;
    element.className = "card" + (block.cls ? " " + block.cls : "") + (block.fixed ? " fixed" : "");
    if (old.head !== block.head) {
      element.children[0].innerHTML = block.head;
      refreshAges(element.children[0]);
    }
    if (old.preview !== block.preview) element.children[1].textContent = block.preview || "";
    if (old.foot !== block.foot) element.children[3].innerHTML = block.foot || "";
    // A body is only built once it is shown; collapsed cards stay cheap.
    if (old.body !== block.body) element._bodyStale = true;
    applyExpansion(element);
  }

  function updateRow(element, block) {
    if (element._block && element._block.html === block.html && element._block.cls === block.cls) return;
    element._block = block;
    element.className = block.cls;
    element.innerHTML = block.html;
    refreshAges(element);
  }

  function renderTimeline(data) {
    timeline.url = data.url;
    const reset = data.key !== timeline.key;
    const prior = reset ? timeline.saved.get(data.key) : null;
    if (reset) {
      if (timeline.key !== null) {
        remember(timeline.saved, timeline.key, { scroll: scrollY, expanded: new Map(timeline.expanded), all: timeline.all });
      }
      timeline.key = data.key;
      timeline.blocks.clear();
      timeline.expanded = prior ? new Map(prior.expanded) : new Map();
      timeline.all = prior ? prior.all : null;
      root.replaceChildren();
      userScrolled = false;
    }
    const stickToBottom = !reset && nearBottom() && scrollY > 0;
    const elements = data.blocks.map((block) => {
      let element = timeline.blocks.get(block.id);
      if (element && (element.dataset.type !== block.type)) element = null;
      if (!element) {
        element = block.type === "card" ? makeCard(block) : document.createElement("div");
        element.dataset.id = block.id;
        element.dataset.type = block.type;
        timeline.blocks.set(block.id, element);
      }
      if (block.type === "card") updateCard(element, block); else updateRow(element, block);
      return element;
    });
    const ids = new Set(data.blocks.map((block) => block.id));
    for (const id of [...timeline.blocks.keys()]) if (!ids.has(id)) timeline.blocks.delete(id);
    arrange(root, elements);

    const firstNew = data.firstNew && timeline.blocks.get(data.firstNew);
    if (reset) {
      timeline.awaitingNew = !firstNew && !prior;
      // New entries first; otherwise back where the item was left.
      if (firstNew) scrollToElement(firstNew); else scrollTo(0, prior ? prior.scroll : 0);
    } else if (firstNew && timeline.awaitingNew && !userScrolled) {
      timeline.awaitingNew = false;
      scrollToElement(firstNew);
    } else if (stickToBottom) {
      scrollTo(0, document.documentElement.scrollHeight);
    }
  }

  function toggleCard(element) {
    timeline.expanded.set(element.dataset.id, !isExpanded(element));
    applyExpansion(element);
    // Collapsing a card read from its middle would leave the view far below it.
    if (element.classList.contains("collapsed") && element.getBoundingClientRect().top < 0) scrollToElement(element);
  }

  function setAllCards(open) {
    timeline.expanded.clear();
    timeline.all = open;
    for (const element of timeline.blocks.values()) if (element.dataset.type === "card") applyExpansion(element);
  }

  // MARK: Files

  const files = {
    key: null,
    url: null,
    elements: new Map(),
    expanded: new Map(),
    all: null,
    saved: new Map(),
  };

  const languages = {
    py: "python", pyi: "python", pyx: "python", pxd: "python",
    c: "c", h: "cpp", cc: "cpp", cpp: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp", cu: "cpp", cuh: "cpp", inl: "cpp",
    m: "objectivec", mm: "objectivec", metal: "cpp",
    sh: "bash", bash: "bash", zsh: "bash",
    yml: "yaml", yaml: "yaml", json: "json", jsonl: "json", md: "markdown", rst: "plaintext",
    toml: "ini", ini: "ini", cfg: "ini", rs: "rust", go: "go", java: "java", kt: "kotlin", swift: "swift",
    js: "javascript", mjs: "javascript", cjs: "javascript", ts: "typescript", tsx: "typescript", jsx: "javascript",
    html: "xml", xml: "xml", svg: "xml", css: "css", scss: "scss", sql: "sql", lua: "lua", rb: "ruby", r: "r",
    cmake: "cmake", mk: "makefile", graphql: "graphql", proto: "c",
  };

  function languageFor(path) {
    const name = path.split("/").pop();
    if (name === "CMakeLists.txt") return "cmake";
    if (name === "Makefile") return "makefile";
    if (/^Dockerfile|\.Dockerfile$|^Containerfile/.test(name)) return "dockerfile";
    const extension = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
    const language = languages[extension];
    return language && window.hljs && hljs.getLanguage(language) ? language : null;
  }

  /** Unified-diff patch → lines with old/new numbers. */
  function parsePatch(patch) {
    const lines = [];
    let old = 0, now = 0;
    for (const raw of patch.split("\n")) {
      if (raw.startsWith("@@")) {
        const match = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw);
        if (match) { old = Number(match[1]); now = Number(match[2]); }
        lines.push({ kind: "h", text: raw });
      } else if (raw.startsWith("+")) {
        lines.push({ kind: "a", text: raw.slice(1), now: now++ });
      } else if (raw.startsWith("-")) {
        lines.push({ kind: "d", text: raw.slice(1), old: old++ });
      } else if (raw.startsWith("\\")) {
        // "\ No newline at end of file"
      } else {
        lines.push({ kind: "x", text: raw.slice(1), old: old++, now: now++ });
      }
    }
    return lines;
  }

  /** Splits highlighted HTML into lines, closing and reopening spans across line breaks. */
  function splitHighlighted(html) {
    const lines = [];
    const open = [];
    let line = "";
    for (const token of html.match(/<span[^>]*>|<\/span>|\n|[^<\n]+/g) || []) {
      if (token === "\n") {
        lines.push(line + "</span>".repeat(open.length));
        line = open.join("");
      } else {
        if (token.startsWith("<span")) open.push(token);
        else if (token === "</span>") open.pop();
        line += token;
      }
    }
    lines.push(line + "</span>".repeat(open.length));
    return lines;
  }

  /**
   * Highlights each hunk twice, as the old and as the new code, so constructs spanning lines
   * (strings, comments) color the way they read on each side; returns HTML per line.
   */
  function highlightLines(lines, language) {
    const result = lines.map((line) => escapeHTML(line.text));
    if (!language) return result;
    const hunks = [];
    let current = null;
    lines.forEach((line, index) => {
      if (line.kind === "h") { current = null; return; }
      if (!current) { current = { old: [], now: [] }; hunks.push(current); }
      if (line.kind !== "a") current.old.push(index);
      if (line.kind !== "d") current.now.push(index);
    });
    const apply = (indexes) => {
      if (!indexes.length) return;
      let highlighted;
      try {
        highlighted = hljs.highlight(indexes.map((i) => lines[i].text).join("\n"), { language, ignoreIllegals: true }).value;
      } catch {
        return;
      }
      splitHighlighted(highlighted).forEach((html, i) => { if (i < indexes.length) result[indexes[i]] = html; });
    };
    for (const hunk of hunks) {
      // Context lines take the new side's coloring.
      apply(hunk.old.filter((i) => lines[i].kind === "d").length ? hunk.old : []);
      apply(hunk.now);
    }
    return result;
  }

  /**
   * A wrapped line continues at its own indentation: the leading spaces become non-breaking (so
   * the line can't break right after them) and the indentation turns into a hanging indent.
   */
  function hangingIndent(html, text) {
    const leading = /^[ \t]*/.exec(text)[0];
    if (!leading) return { html, indent: 0 };
    const indent = [...leading].reduce((width, c) => width + (c === "\t" ? 4 : 1), 0);
    const spaces = leading.replaceAll(" ", "&nbsp;");
    // The highlighted HTML may open spans before the indentation.
    return { html: html.replace(/^((?:<span[^>]*>)*)[ \t]+/, (_, spans) => spans + spaces), indent };
  }

  // Copies of the diff get ordinary spaces back.
  addEventListener("copy", (event) => {
    if (document.documentElement.dataset.page !== "files") return;
    const text = getSelection().toString();
    if (!text.includes("\u00a0")) return;
    event.clipboardData.setData("text/plain", text.replaceAll("\u00a0", " "));
    event.preventDefault();
  });

  const linesPerChunk = 200;
  const lineHeight = 16;

  function buildDiff(element) {
    const file = element._file;
    element._built = true;
    const diff = element.children[1];
    if (file.patch == null) {
      diff.innerHTML = '<div class="no-diff">No textual diff (binary or too large).</div>';
      return;
    }
    const lines = parsePatch(file.patch);
    const code = highlightLines(lines, languageFor(file.name));
    const width = String(lines.reduce((max, line) => Math.max(max, line.old || 0, line.now || 0), 0)).length;
    diff.style.setProperty("--nw", `${Math.max(2, width)}ch`);
    diff.style.minHeight = "";
    const parts = ['<div class="lines">'];
    for (let start = 0; start < lines.length; start += linesPerChunk) {
      const count = Math.min(linesPerChunk, lines.length - start);
      parts.push(`<div class="chunk" style="contain-intrinsic-size: auto ${count * lineHeight}px">`);
      for (let i = start; i < start + count; i++) {
        const line = lines[i];
        if (line.kind === "h") {
          parts.push(`<div class="l h">${code[i]}</div>`);
        } else {
          const { html, indent } = hangingIndent(code[i], line.text);
          const style = indent ? ` style="--i: ${indent}ch"` : "";
          parts.push(`<div class="l ${line.kind}"><span class="n" data-n="${line.old ?? ""}"></span><span class="n" data-n="${line.now ?? ""}"></span><span class="c"${style}>${html}</span></div>`);
        }
      }
      parts.push("</div>");
    }
    parts.push("</div>");
    diff.innerHTML = parts.join("");
  }

  // Diffs are built when an expanded file comes near the screen, so Expand all stays instant.
  const builder = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const element = entry.target;
      builder.unobserve(element);
      if (!element._built && !element.classList.contains("collapsed")) buildDiff(element);
    }
  }, { rootMargin: "1500px 0px" });

  function isFileExpanded(element) {
    return files.expanded.get(element.dataset.path) ?? files.all ?? false;
  }

  function applyFileExpansion(element) {
    const open = isFileExpanded(element);
    element.classList.toggle("collapsed", !open);
    if (open && !element._built) {
      // Reserve the diff's height until it is built, so the scroll bar stays honest.
      element.children[1].style.minHeight = `${element._lineCount * lineHeight}px`;
      builder.observe(element);
    }
  }

  function fileHead(file) {
    const slash = file.name.lastIndexOf("/");
    const dir = slash >= 0 ? file.name.slice(0, slash + 1) : "";
    const base = file.name.slice(slash + 1);
    const from = file.previous ? `<span class="dir">${escapeHTML(file.previous)} → </span>` : "";
    return `<i class="sym chev s-chevron-right"></i><i class="sym ${file.symbol}"></i>`
      + `<span class="fname" title="${escapeHTML(file.previous ? `${file.previous} → ${file.name}` : file.name)}">${from}<span class="dir">${escapeHTML(dir)}</span><span class="base">${escapeHTML(base)}</span></span>`
      + `<span class="spacer"></span>`
      + `<span class="fstat c-green">+${file.additions}</span><span class="fstat c-red">−${file.deletions}</span>`
      + (file.url ? `<a class="icon-link" href="${escapeHTML(file.url)}" title="Open on GitHub"><i class="sym s-arrow-up-right"></i></a>` : "");
  }

  function renderFiles(data) {
    files.url = data.url;
    const reset = data.key !== files.key;
    const prior = reset ? files.saved.get(data.key) : null;
    if (reset) {
      if (files.key !== null) {
        remember(files.saved, files.key, { scroll: scrollY, expanded: new Map(files.expanded), all: files.all });
      }
      files.key = data.key;
      files.elements.clear();
      files.expanded = prior ? new Map(prior.expanded) : new Map();
      files.all = prior ? prior.all : null;
      root.replaceChildren();
    }
    const elements = data.files.map((file) => {
      let element = files.elements.get(file.name);
      if (element && element._file.patch !== file.patch) {
        builder.unobserve(element);
        element = null;
      }
      if (!element) {
        element = document.createElement("section");
        element.className = "file collapsed";
        element.dataset.path = file.name;
        element.innerHTML = '<header class="fhead"></header><div class="diff"></div>';
        element._lineCount = file.patch == null ? 2 : file.patch.split("\n").length;
        files.elements.set(file.name, element);
      }
      if (!element._file || fileHead(element._file) !== fileHead(file)) element.children[0].innerHTML = fileHead(file);
      element._file = file;
      element.dataset.url = file.url || "";
      applyFileExpansion(element);
      return element;
    });
    const names = new Set(data.files.map((file) => file.name));
    for (const name of [...files.elements.keys()]) if (!names.has(name)) files.elements.delete(name);
    arrange(root, elements);
    if (reset) scrollTo(0, prior ? prior.scroll : 0);
  }

  function toggleFile(element) {
    files.expanded.set(element.dataset.path, !isFileExpanded(element));
    applyFileExpansion(element);
    if (element.classList.contains("collapsed") && element.getBoundingClientRect().top < 0) scrollToElement(element);
  }

  /** Builds every expanded diff in slices of a few milliseconds, so find can reach them all. */
  function buildExpandedFiles() {
    const pending = [...files.elements.values()].filter((element) => !element._built && !element.classList.contains("collapsed"));
    const slice = () => {
      const start = performance.now();
      while (pending.length && performance.now() - start < 12) {
        const element = pending.shift();
        if (element._built || element.classList.contains("collapsed")) continue;
        builder.unobserve(element);
        buildDiff(element);
      }
      if (pending.length) setTimeout(slice, 0);
    };
    slice();
  }

  function setAllFiles(open) {
    files.expanded.clear();
    files.all = open;
    for (const element of files.elements.values()) applyFileExpansion(element);
  }

  // MARK: Clicks

  /**
   * The issue or PR a link points to, if it is in a repository the app shows (vllm and the parity
   * agent's fork).
   */
  function itemLink(href) {
    const repos = document.documentElement.dataset.repos.toLowerCase().split(" ");
    const match = /^https:\/\/github\.com\/([^/]+\/[^/]+)\/(?:pull|issues)\/(\d+)(\/[^?#]*)?(?:\?[^#]*)?(#.+)?$/i.exec(href);
    if (!match || !repos.includes(match[1].toLowerCase())) return null;
    return { repo: match[1].toLowerCase(), number: match[2], subpage: match[3] && match[3] !== "/", hash: match[4] };
  }

  /** Expands and scrolls to the comment a link's anchor names, if this page shows it. */
  function revealAnchor(hash) {
    const anchor = document.querySelector(`a.icon-link[href$="${CSS.escape(hash)}"]`);
    const card = anchor && anchor.closest(".card");
    if (!card) return false;
    timeline.expanded.set(card.dataset.id, true);
    applyExpansion(card);
    scrollToElement(anchor.closest(".rc") || card);
    return true;
  }

  /**
   * Links to those repositories' issues and PRs open in the app; a link into the item already shown
   * scrolls to its comment. ⌘-click, the ↗ buttons and other links go to the browser.
   */
  function handleLink(event, link) {
    if (event.metaKey || event.shiftKey || event.altKey || link.closest(".icon-link")) return;
    const target = itemLink(link.href);
    if (!target) return;
    const current = itemLink((document.documentElement.dataset.page === "files" ? files.url : timeline.url) || "");
    if (current && target.repo === current.repo && target.number === current.number) {
      if (target.hash ? revealAnchor(target.hash) : !target.subpage) event.preventDefault();
      return;
    }
    event.preventDefault();
    post({ type: "openItem", repo: target.repo, number: Number(target.number) });
  }

  addEventListener("click", (event) => {
    if (event.button !== 0) return;
    const link = event.target.closest("a[href]");
    if (link) {
      handleLink(event, link);
      return;
    }
    // A person's name or avatar opens their GitHub profile.
    const person = event.target.closest("[data-login]");
    if (person) {
      post({ type: "openProfile", login: person.dataset.login });
      return;
    }
    if (event.target.closest(".login")) return;
    const reactAdd = event.target.closest(".react-add");
    if (reactAdd) {
      const rect = reactAdd.getBoundingClientRect();
      post({ type: "reactionMenu", subject: reactAdd.dataset.subject, x: rect.left, y: rect.bottom + 2 });
      return;
    }
    const reaction = event.target.closest(".reaction");
    if (reaction) {
      post({ type: "react", subject: reaction.dataset.subject, content: reaction.dataset.content });
      return;
    }
    const head = event.target.closest(".card:not(.fixed) > .head, .card > .preview");
    if (head && !isSelectingIn(head)) {
      toggleCard(head.parentElement);
      return;
    }
    const fileHead = event.target.closest(".fhead");
    if (fileHead && !isSelectingIn(fileHead)) toggleFile(fileHead.parentElement);
  });

  post({ type: "ready" });

  return {
    renderTimeline,
    setAllCards,
    renderFiles,
    setAllFiles,
    buildExpandedFiles,
    setWrap(wrap) { document.documentElement.classList.toggle("nowrap", !wrap); },
  };
})();
