/* Rendering bridge. Swift calls window.Scivane.* through evaluateJavaScript; the page reports
   its scroll position back through webkit.messageHandlers.scivane. */

(function () {
  "use strict";

  const md = window.markdownit({
    html: true,        // the OCR model emits HTML tables
    linkify: true,
    breaks: false,
    typographer: false // no smart punctuation: OCR output must stay faithful
  });

// Parse TeX before Markdown consumes underscores, braces and backslashes.
function mathHTML(content, display) {
  try { return katex.renderToString(content, {displayMode: display, throwOnError: false, trust: false}); }
  catch (_) { return md.utils.escapeHtml(content); }
}
md.inline.ruler.before('escape', 'scivane_math', function(state, silent) {
  const rest = state.src.slice(state.pos);
  const open = ['$$', '\\(', '\\[', '$'].find(d => rest.startsWith(d));
  if (!open) return false;
  const close = open === '\\(' ? '\\)' : open === '\\[' ? '\\]' : open;
  if (open === '$' && /\s/.test(rest[1] || ' ')) return false;
  let end = state.src.indexOf(close, state.pos + open.length);
  while (end > 0 && state.src[end - 1] === '\\') end = state.src.indexOf(close, end + close.length);
  if (end < 0 || (open === '$' && /\s/.test(state.src[end - 1]))) return false;
  if (!silent) {
    const token = state.push('scivane_math', '', 0);
    token.content = state.src.slice(state.pos + open.length, end);
    token.meta = {display: open === '$$' || open === '\\['};
  }
  state.pos = end + close.length;
  return true;
});
md.renderer.rules.scivane_math = (tokens, idx) => mathHTML(tokens[idx].content, tokens[idx].meta.display);
md.block.ruler.before('fence', 'scivane_math_block', function(state, start, end, silent) {
  const offset = state.bMarks[start] + state.tShift[start];
  const first = state.src.slice(offset, state.eMarks[start]);
  const open = first.startsWith('$$') ? '$$' : first.startsWith('\\[') ? '\\[' : null;
  if (!open) return false;
  const close = open === '$$' ? '$$' : '\\]';
  const finish = state.src.indexOf(close, offset + open.length);
  if (finish < 0) return false;
  let last = start;
  while (last + 1 < end && state.eMarks[last] < finish + close.length) last++;
  if (state.src.slice(finish + close.length, state.eMarks[last]).trim()) return false;
  if (silent) return true;
  const token = state.push('scivane_math_block', '', 0);
  token.content = state.src.slice(offset + open.length, finish);
  token.block = true; token.map = [start, last + 1];
  state.line = last + 1;
  return true;
});
md.renderer.rules.scivane_math_block = (tokens, idx) => mathHTML(tokens[idx].content, true);

  const doc = document.getElementById("doc");
  const empty = document.getElementById("empty");

  /* UI language, not the paper's language (which is detected from the text and drives
     hyphenation, see setPage). The template is in Chinese; the app calls setLanguage("en"). */
  const UI = {
    zh: {
      page: function (n) { return "第 " + n + " 页"; },
      emptyTitle: "等待识别",
      emptySub: "左侧载入文档后，这里会逐页出现结果"
    },
    en: {
      page: function (n) { return "Page " + n; },
      emptyTitle: "Not recognized yet",
      emptySub: "Load a document on the left; its pages appear here as they're recognized"
    }
  };
  let ui = UI.zh;

  const KATEX_DELIMS = [
    { left: "$$", right: "$$", display: true },
    { left: "\\[", right: "\\]", display: true },
    { left: "\\(", right: "\\)", display: false },
    { left: "$", right: "$", display: false }
  ];

  let assetBase = null;
  let documentBase = null;

  // The viewer is file://; OCR images live on the local API, not /assets on disk.
  function resolveImages(scope) {
    if (!assetBase) return;
    scope.querySelectorAll("img").forEach(function (img) {
      const path = img.dataset.scivaneAssetPath || img.getAttribute("src") || "";
      if (!path.startsWith("/assets/")) {
        if (documentBase && !/^[a-z][a-z0-9+.-]*:/i.test(path)) img.setAttribute("src", new URL(path, documentBase).href);
        return;
      }
      img.dataset.scivaneAssetPath = path;
      img.setAttribute("src", new URL(path, assetBase).href);
    });
  }

  let currentPage = 0;
  let observer = null;
  let suppressReport = false;
  /** whether the paper's language has been decided (see setPage) */
  let langSettled = false;

  function post(payload) {
    try {
      window.webkit.messageHandlers.scivane.postMessage(payload);
    } catch (e) { /* no bridge when the page is opened on its own for debugging */ }
  }

  function showDoc(show) {
    doc.hidden = !show;
    empty.style.display = show ? "none" : "";
  }

  function pageEl(index) {
    return doc.querySelector('.page[data-page="' + index + '"]');
  }

  /** Table normalisation. The model emits bare HTML with inline styles (border=1,
   * style='text-align:center') that override the stylesheet, and header rows made of <td>.
   * Strip them, add the semantics, and wrap the table in a horizontally scrolling container. */
  function normaliseTables(scope) {
    scope.querySelectorAll("table").forEach(function (t) {
      // drop inline styles and presentational attributes
      t.querySelectorAll("*").forEach(function (el) {
        el.removeAttribute("style");
        el.removeAttribute("align");
        el.removeAttribute("bgcolor");
        el.removeAttribute("width");
      });
      ["border", "style", "cellpadding", "cellspacing", "align", "width"].forEach(function (a) {
        t.removeAttribute(a);
      });

      // promote the first row to a header so the thead rules apply
      if (!t.querySelector("thead")) {
        const first = t.querySelector("tr");
        if (first && first.children.length) {
          const thead = document.createElement("thead");
          Array.from(first.children).forEach(function (cell) {
            if (cell.tagName === "TH") return;
            const th = document.createElement("th");
            th.innerHTML = cell.innerHTML;
            if (cell.hasAttribute("colspan")) th.setAttribute("colspan", cell.getAttribute("colspan"));
            if (cell.hasAttribute("rowspan")) th.setAttribute("rowspan", cell.getAttribute("rowspan"));
            cell.replaceWith(th);
          });
          thead.appendChild(first);
          t.insertBefore(thead, t.firstChild);
        }
      }

      // Right-align numeric columns. Only when every cell looks numeric (signs, %, ± deviation,
      // parentheses, asterisks allowed); a single text cell keeps the whole column left-aligned.
      const numeric = /^[-+±(]?\s*\d[\d\s,.]*(\s*[%‰]|\s*±\s*[\d.]+|\s*\)|\s*\*+)?$/;
      const bodyRows = Array.from(t.tBodies).reduce(function (all, b) {
        return all.concat(Array.from(b.rows));
      }, []);
      const columnCount = bodyRows.reduce(function (n, r) {
        return Math.max(n, r.cells.length);
      }, 0);
      for (let c = 0; c < columnCount; c++) {
        const cells = bodyRows.map(function (r) { return r.cells[c]; }).filter(Boolean);
        // a single cell isn't a column of numbers
        if (cells.length < 2) continue;
        const allNumeric = cells.every(function (cell) {
          const text = cell.textContent.trim();
          return text === "" || numeric.test(text);
        });
        if (!allNumeric) continue;
        cells.forEach(function (cell) { cell.classList.add("num"); });
        const head = t.tHead && t.tHead.rows[0] && t.tHead.rows[0].cells[c];
        if (head) head.classList.add("num");
      }

      if (t.parentElement && t.parentElement.classList.contains("table-wrap")) return;
      const w = document.createElement("div");
      w.className = "table-wrap";
      t.parentNode.insertBefore(w, t);
      w.appendChild(t);
    });
  }

  function typeset(scope) {
    if (!window.renderMathInElement) return;
    try {
      window.renderMathInElement(scope, {
        delimiters: KATEX_DELIMS,
        throwOnError: false,
        ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code"]
      });
    } catch (e) { /* one broken formula must not blank the page */ }
  }

  function ensureObserver() {
    if (observer) return;
    observer = new IntersectionObserver(function (entries) {
      if (suppressReport) return;
      let best = null;
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        if (!best || e.intersectionRatio > best.intersectionRatio) best = e;
      });
      if (!best) return;
      const n = parseInt(best.target.dataset.page, 10);
      if (n && n !== currentPage) {
        currentPage = n;
        markCurrent(n);
        post({ type: "pageVisible", page: n });
      }
    }, { rootMargin: "-15% 0px -60% 0px", threshold: [0, 0.1, 0.5] });
  }

  function markCurrent(n) {
    doc.querySelectorAll(".page.is-current").forEach(function (el) {
      el.classList.remove("is-current");
    });
    const el = pageEl(n);
    if (el) el.classList.add("is-current");
  }

  const Scivane = {
    setAssetBase: function (base) {
      const url = new URL(base);
      if (url.protocol !== "http:" && url.protocol !== "https:" && url.protocol !== "scivane-asset:") return;
      assetBase = url.protocol === "scivane-asset:" ? url.href : url.origin;
      resolveImages(doc);
    },
    /** start a new document */
    reset: function (total) {
      doc.innerHTML = "";
      currentPage = 0;
      langSettled = false;
      showDoc(false);
      if (observer) { observer.disconnect(); observer = null; }
      this.total = total || 0;
    },

    /** write (or overwrite) one page */
    setPage: function (index, markdown) {
      ensureObserver();
      showDoc(true);

      let el = pageEl(index);
      if (!el) {
        el = document.createElement("section");
        el.className = "page";
        el.dataset.page = String(index);
        el.id = "page-" + index;
        // insert by page number, so pages arriving out of order still line up
        let anchor = null;
        doc.querySelectorAll(".page").forEach(function (p) {
          if (anchor === null && parseInt(p.dataset.page, 10) > index) anchor = p;
        });
        doc.insertBefore(el, anchor);
        observer.observe(el);
      }

      const body = document.createElement("div");
      body.className = "page-body";
      body.innerHTML = md.render(markdown || "");
body.querySelectorAll('script,iframe,object,embed,form,style,link,meta,base').forEach(el => el.remove());
body.querySelectorAll('*').forEach(el => Array.from(el.attributes).forEach(a => {
  if (/^on/i.test(a.name) || /^(javascript|vbscript):/i.test(a.value.trim())) el.removeAttribute(a.name);
}));
resolveImages(body);

      // Hyphenation needs the language: `hyphens: auto` only works when the browser knows it, and
      // justified text without hyphenation opens rivers. The template says lang="zh" but most
      // papers are English, so decide from the text: under 5% CJK means English (Chinese doesn't
      // hyphenate, so erring towards English is cheap). Short pages decide nothing.
      if (!langSettled) {
        const sample = body.textContent || "";
        const cjk = (sample.match(/[一-鿿]/g) || []).length;
        document.documentElement.lang = cjk > sample.length * 0.05 ? "zh" : "en";
        langSettled = sample.length > 40;
      }

      normaliseTables(body);
      typeset(body);

      el.innerHTML = "";
      const mark = document.createElement("div");
      mark.className = "page-mark";
      mark.textContent = ui.page(index);
      el.appendChild(mark);
      el.appendChild(body);
      el.dataset.state = "done";
    },

    /** scroll to a page requested by the PDF side, without reporting back (no loop) */
    setDocumentBase: function (base) { documentBase = base || null; document.body.classList.toggle("markdown-document", !!documentBase); },
    scrollToPage: function (index) {
      const el = pageEl(index);
      if (!el) return;
      suppressReport = true;
      currentPage = index;
      markCurrent(index);
      el.scrollIntoView({ behavior: "smooth", block: "start" });
      setTimeout(function () { suppressReport = false; }, 700);
    },

    setTheme: function (theme) {
      document.documentElement.setAttribute("data-theme", theme);
    },

    setFontSize: function (px) {
      document.body.style.fontSize = px + "px";
    },

    /** UI language: the empty state and page labels; existing pages relabel without relayout */
    setLanguage: function (lang) {
      ui = UI[lang] || UI.zh;
      empty.querySelector(".empty-title").textContent = ui.emptyTitle;
      empty.querySelector(".empty-sub").textContent = ui.emptySub;
      doc.querySelectorAll(".page").forEach(function (el) {
        const mark = el.querySelector(".page-mark");
        if (mark) mark.textContent = ui.page(el.dataset.page);
      });
    },

    /** highlight all matches; returns the count */
    find: function (query) {
      this.clearFind();
      if (!query) return 0;
      const rx = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi");
      let count = 0;
      const walker = document.createTreeWalker(doc, NodeFilter.SHOW_TEXT, {
        acceptNode: function (node) {
          if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
          const p = node.parentElement;
          if (!p || p.closest(".katex, script, style")) return NodeFilter.FILTER_REJECT;
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      const targets = [];
      while (walker.nextNode()) {
        if (rx.test(walker.currentNode.nodeValue)) targets.push(walker.currentNode);
        rx.lastIndex = 0;
      }
      targets.forEach(function (node) {
        const frag = document.createDocumentFragment();
        let last = 0, m;
        rx.lastIndex = 0;
        while ((m = rx.exec(node.nodeValue)) !== null) {
          frag.appendChild(document.createTextNode(node.nodeValue.slice(last, m.index)));
          const mk = document.createElement("mark");
          mk.className = "hit";
          mk.textContent = m[0];
          frag.appendChild(mk);
          last = m.index + m[0].length;
          count++;
          if (m[0].length === 0) rx.lastIndex++;
        }
        frag.appendChild(document.createTextNode(node.nodeValue.slice(last)));
        node.parentNode.replaceChild(frag, node);
      });
      const first = doc.querySelector("mark.hit");
      if (first) first.scrollIntoView({ behavior: "smooth", block: "center" });
      return count;
    },

    clearFind: function () {
      doc.querySelectorAll("mark.hit").forEach(function (m) {
        const t = document.createTextNode(m.textContent);
        m.parentNode.replaceChild(t, m);
      });
      doc.normalize();
    }
  };

  window.Scivane = Scivane;
  post({ type: "ready" });
})();
