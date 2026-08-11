(function () {
  "use strict";

  const root = document.documentElement;
  const shell = document.getElementById("preview-shell");
  const article = document.getElementById("preview-document");
  const errorBox = document.getElementById("render-error");
  const progress = document.getElementById("reading-progress");
  let renderVersion = 0;
  let activeSearchText = "";
  let lastRenderOptions = null;
  let printRestoreOptions = null;
  let externalChangeTargets = [];

  const escapeHtml = (value) =>
    value
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");

  function extractFrontmatter(markdown) {
    const normalized = markdown || "";
    const lines = normalized.split("\n");
    if (lines[0] !== "---") return { body: normalized, html: "", lineOffset: 0 };

    const closingIndex = lines.slice(1).findIndex((line) => line.trim() === "---");
    if (closingIndex < 0) return { body: normalized, html: "", lineOffset: 0 };
    const end = closingIndex + 1;
    const source = lines.slice(0, end + 1).join("\n");
    const fields = lines.slice(1, end);
    const rows = fields
      .map((line) => {
        const match = line.match(/^([A-Za-z0-9_.-]+):\s*(.*)$/);
        if (!match) return "";
        const rawValue = match[2].trim();
        const value = rawValue.replace(/^(\"|')(.*)\1$/, "$2");
        return (
          '<div class="frontmatter-row"><dt>' +
          escapeHtml(match[1]) +
          "</dt><dd>" +
          escapeHtml(value || "—") +
          "</dd></div>"
        );
      })
      .filter(Boolean)
      .join("");
    const fallback = fields.length
      ? '<pre class="frontmatter-raw">' + escapeHtml(fields.join("\n")) + "</pre>"
      : "";
    const bodyLines = lines.slice(end + 1);
    let lineOffset = end + 1;
    if (bodyLines[0] === "") {
      bodyLines.shift();
      lineOffset += 1;
    }
    return {
      body: bodyLines.join("\n"),
      lineOffset: lineOffset,
      html:
        '<aside class="frontmatter-card" contenteditable="false" ' +
        'data-previewmd-source-start="0" data-previewmd-source-end="' +
        lineOffset +
        '" data-frontmatter-source="' +
        encodeURIComponent(source) +
        '"><div class="frontmatter-label">Document metadata</div><dl>' +
        (rows || fallback) +
        "</dl></aside>",
    };
  }

  const customVariableNames = [
    "--font-body",
    "--font-display",
    "--body-size",
    "--body-leading",
    "--accent",
    "--page",
    "--ink",
  ];

  function applyCustomPreset(preset, isDark) {
    customVariableNames.forEach((name) => root.style.removeProperty(name));
    if (!preset) return;
    root.style.setProperty("--font-body", fontFamily(preset.bodyFont));
    root.style.setProperty("--font-display", fontFamily(preset.headingFont));
    root.style.setProperty("--body-size", Number(preset.bodySize || 16) + "px");
    root.style.setProperty("--body-leading", Number(preset.lineHeight || 1.68));
    root.style.setProperty("--accent", preset.accentHex || "#5B5CE2");
    root.style.setProperty(
      "--page",
      isDark ? preset.darkPageHex || "#1D1E22" : preset.lightPageHex || "#FFFFFF"
    );
    root.style.setProperty(
      "--ink",
      isDark ? preset.darkInkHex || "#ECECF1" : preset.lightInkHex || "#24262D"
    );
  }

  function fontFamily(value) {
    return {
      system: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif',
      rounded: 'ui-rounded, "SF Pro Rounded", -apple-system, sans-serif',
      serif: '"New York", "Iowan Old Style", Charter, Georgia, ui-serif, serif',
      mono: '"SFMono-Regular", "SF Mono", ui-monospace, Menlo, monospace',
    }[value] || '-apple-system, BlinkMacSystemFont, sans-serif';
  }

  /// Builds the card for one fenced or indented code block.
  ///
  /// Deliberately not wired up as markdown-it's `highlight` option. That hook
  /// wraps whatever it returns in `<pre><code>` unless the string already starts
  /// with `<pre`, and these cards start with a `<div>`. The result was an inline
  /// `<code>` element holding a block-level child, which the browser splits into
  /// two empty fragments — one above the card and one below — each still
  /// carrying the padding, border and background of the inline-code style. Those
  /// were the small stubs that used to bracket every code block and diagram.
  function renderCodeCard(source, language, attributes) {
    const normalized = (language || "").trim().toLowerCase();
    const tokenAttributes = attributes || "";

    if (normalized === "mermaid") {
      return (
        '<div class="diagram-card"' + tokenAttributes + ">" +
        '<div class="diagram-label"><span>Diagram</span></div>' +
        '<pre class="mermaid">' +
        escapeHtml(source) +
        "</pre></div>"
      );
    }

    let highlighted = escapeHtml(source);
    try {
      if (normalized && window.hljs.getLanguage(normalized)) {
        highlighted = window.hljs.highlight(source, {
          language: normalized,
          ignoreIllegals: true,
        }).value;
      } else {
        highlighted = window.hljs.highlightAuto(source).value;
      }
    } catch (_) {}

    const label = normalized || "code";
    return (
      '<div class="code-card"' + tokenAttributes + ">" +
      '<div class="code-toolbar"><span>' +
      escapeHtml(label) +
      '</span><button class="copy-code" type="button" aria-label="Copy code">' +
      '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M5 4V2.8C5 1.8 5.8 1 6.8 1h6.4c1 0 1.8.8 1.8 1.8v6.4c0 1-.8 1.8-1.8 1.8H12V9.5h1.2c.2 0 .3-.1.3-.3V2.8c0-.2-.1-.3-.3-.3H6.8c-.2 0-.3.1-.3.3V4H5Z"/><path d="M2.8 5h6.4c1 0 1.8.8 1.8 1.8v6.4c0 1-.8 1.8-1.8 1.8H2.8c-1 0-1.8-.8-1.8-1.8V6.8C1 5.8 1.8 5 2.8 5Zm0 1.5c-.2 0-.3.1-.3.3v6.4c0 .2.1.3.3.3h6.4c.2 0 .3-.1.3-.3V6.8c0-.2-.1-.3-.3-.3H2.8Z"/></svg>' +
      "<span>Copy</span></button></div>" +
      '<pre><code class="hljs language-' +
      escapeHtml(normalized) +
      '">' +
      highlighted +
      "</code></pre></div>"
    );
  }

  const md = window.markdownit({
    html: false,
    linkify: true,
    typographer: true,
    breaks: false,
  });

  // markdown-it rejects file: URLs by default together with executable schemes.
  // PreviewMD deliberately supports local images, so allow only this additional
  // non-executable scheme while preserving the built-in javascript/vbscript
  // protection and the narrow data:image allowlist.
  const defaultValidateLink = md.validateLink.bind(md);
  md.validateLink = function (value) {
    return /^file:/i.test(value.trim()) || defaultValidateLink(value);
  };

  // Own both code paths so nothing re-introduces the wrapper: fenced blocks and
  // the indented kind, which markdown-it renders through a separate rule.
  md.renderer.rules.fence = function (tokens, index, options, env, self) {
    const token = tokens[index];
    const info = (token.info || "").trim();
    return renderCodeCard(
      token.content,
      info.split(/\s+/)[0] || "",
      self.renderAttrs(token)
    );
  };

  md.renderer.rules.code_block = function (tokens, index, options, env, self) {
    return renderCodeCard(tokens[index].content, "", self.renderAttrs(tokens[index]));
  };

  if (window.markdownitFootnote) {
    md.use(window.markdownitFootnote);

    const defaultFootnoteRef = md.renderer.rules.footnote_ref;
    if (defaultFootnoteRef) {
      md.renderer.rules.footnote_ref = function (tokens, index, options, env, self) {
        const html = defaultFootnoteRef(tokens, index, options, env, self);
        const meta = tokens[index].meta || {};
        const label = meta.label || String((meta.id || 0) + 1);
        return html.replace(
          '<sup class="footnote-ref">',
          '<sup class="footnote-ref" data-footnote-label="' +
            escapeHtml(String(label)) +
            '">'
        );
      };
    }

    const defaultFootnoteOpen = md.renderer.rules.footnote_open;
    if (defaultFootnoteOpen) {
      md.renderer.rules.footnote_open = function (tokens, index, options, env, self) {
        const html = defaultFootnoteOpen(tokens, index, options, env, self);
        const meta = tokens[index].meta || {};
        const label = meta.label || String((meta.id || 0) + 1);
        return html.replace(
          'class="footnote-item"',
          'class="footnote-item" data-footnote-label="' +
            escapeHtml(String(label)) +
            '"'
        );
      };
    }
  }

  const defaultHeadingOpen =
    md.renderer.rules.heading_open ||
    function (tokens, index, options, env, self) {
      return self.renderToken(tokens, index, options);
    };

  md.renderer.rules.heading_open = function (tokens, index, options, env, self) {
    const headingIndex = env.headingIndex || 0;
    tokens[index].attrSet("id", "heading-" + headingIndex);
    env.headingIndex = headingIndex + 1;
    return defaultHeadingOpen(tokens, index, options, env, self);
  };

  const tableExpandIcon =
    '<svg viewBox="0 0 16 16" aria-hidden="true">' +
    '<path d="M6.25 2.25h-4v4M2.5 2.5l4.1 4.1M9.75 13.75h4v-4M13.5 13.5l-4.1-4.1"/>' +
    "</svg>";
  const tableCollapseIcon =
    '<svg viewBox="0 0 16 16" aria-hidden="true">' +
    '<path d="M6.5 6.5h-4v-4M2.75 6.25l4.1-4.1M9.5 9.5h4v4M13.25 9.75l-4.1 4.1"/>' +
    "</svg>";

  md.renderer.rules.table_open = function (tokens, index, options, env, self) {
    return (
      '<div class="table-scroll"' + self.renderAttrs(tokens[index]) + ">" +
      '<div class="table-viewport" tabindex="0" role="region" aria-label="Scrollable table">' +
      '<div class="table-sizer"><table>'
    );
  };
  md.renderer.rules.table_close = function () {
    return (
      "</table></div></div>" +
      '<button class="table-expand" type="button" contenteditable="false" ' +
      'aria-expanded="false" aria-label="Expand table" title="Expand table">' +
      tableExpandIcon +
      "</button></div>"
    );
  };

  const externalChangeTokenTypes = new Set([
    "heading_open",
    "paragraph_open",
    "table_open",
    "fence",
    "code_block",
    "hr",
  ]);

  const sourcePositionTokenTypes = new Set([
    "heading_open",
    "paragraph_open",
    "blockquote_open",
    "bullet_list_open",
    "ordered_list_open",
    "list_item_open",
    "table_open",
    "fence",
    "code_block",
    "hr",
  ]);

  function markSourcePositionTokens(tokens, lineOffset) {
    tokens.forEach((token) => {
      if (
        !sourcePositionTokenTypes.has(token.type) ||
        !Array.isArray(token.map) ||
        token.hidden
      ) {
        return;
      }
      token.attrSet(
        "data-previewmd-source-start",
        String(token.map[0] + lineOffset)
      );
      token.attrSet(
        "data-previewmd-source-end",
        String(token.map[1] + lineOffset)
      );
    });
  }

  function preferredChangeKind(kinds) {
    if (kinds.includes("modified")) return "modified";
    if (kinds.includes("added")) return "added";
    return "removed";
  }

  function markExternalChangeTokens(tokens, changes, lineOffset) {
    const assignments = new Map();
    const frontmatterIndexes = [];
    const candidates = tokens
      .map((token, index) => ({ token: token, index: index }))
      .filter(
        (candidate) =>
          externalChangeTokenTypes.has(candidate.token.type) &&
          Array.isArray(candidate.token.map)
      );

    (changes || []).forEach((change, changeIndex) => {
      const newStart = Math.max(0, Number(change.newStart) || 0);
      const newEnd = Math.max(newStart, Number(change.newEnd) || newStart);

      if (newStart < lineOffset && newEnd <= lineOffset) {
        frontmatterIndexes.push(changeIndex);
        return;
      }

      const bodyStart = Math.max(0, newStart - lineOffset);
      const bodyEnd = Math.max(bodyStart, newEnd - lineOffset);
      const overlapping = candidates.filter((candidate) => {
        const tokenStart = candidate.token.map[0];
        const tokenEnd = candidate.token.map[1];
        if (bodyEnd === bodyStart) {
          return tokenStart <= bodyStart && tokenEnd >= bodyStart;
        }
        return tokenStart < bodyEnd && tokenEnd > bodyStart;
      });

      let targets = overlapping;
      if (!targets.length && candidates.length) {
        const distance = (candidate) => {
          const tokenStart = candidate.token.map[0];
          const tokenEnd = candidate.token.map[1];
          if (bodyStart < tokenStart) return tokenStart - bodyStart;
          if (bodyStart > tokenEnd) return bodyStart - tokenEnd;
          return 0;
        };
        const nearestDistance = Math.min.apply(null, candidates.map(distance));
        const nearest = candidates.filter(
          (candidate) => distance(candidate) === nearestDistance
        );
        const shortestSpan = Math.min.apply(
          null,
          nearest.map((candidate) => candidate.token.map[1] - candidate.token.map[0])
        );
        targets = nearest.filter(
          (candidate) =>
            candidate.token.map[1] - candidate.token.map[0] === shortestSpan
        ).slice(0, 1);
      }

      targets.forEach((candidate) => {
        const assignment = assignments.get(candidate.index) || [];
        assignment.push(changeIndex);
        assignments.set(candidate.index, assignment);
      });
    });

    assignments.forEach((indexes, tokenIndex) => {
      const token = tokens[tokenIndex];
      token.attrSet("data-previewmd-change-indexes", indexes.join(" "));
      token.attrSet(
        "data-previewmd-change-kind",
        preferredChangeKind(indexes.map((index) => changes[index].kind))
      );
    });

    return frontmatterIndexes;
  }

  function indexExternalChangeTargets(changes, frontmatterIndexes) {
    externalChangeTargets = (changes || []).map(() => []);
    const frontmatter = article.querySelector(".frontmatter-card");
    if (frontmatter && frontmatterIndexes.length) {
      frontmatter.dataset.previewmdChangeIndexes = frontmatterIndexes.join(" ");
      frontmatter.dataset.previewmdChangeKind = preferredChangeKind(
        frontmatterIndexes.map((index) => changes[index].kind)
      );
    }

    article
      .querySelectorAll("[data-previewmd-change-indexes]")
      .forEach((element) => {
        (element.dataset.previewmdChangeIndexes || "")
          .split(/\s+/)
          .filter(Boolean)
          .map(Number)
          .forEach((index) => {
            if (externalChangeTargets[index]) {
              externalChangeTargets[index].push(element);
            }
          });
      });
  }

  window.previewmdSelectExternalChange = function (index, shouldScroll) {
    article
      .querySelectorAll(".is-active-external-change")
      .forEach((element) => element.classList.remove("is-active-external-change"));

    const normalizedIndex = Number(index);
    if (!Number.isInteger(normalizedIndex) || !externalChangeTargets[normalizedIndex]) {
      return false;
    }

    const targets = externalChangeTargets[normalizedIndex];
    targets.forEach((element) => element.classList.add("is-active-external-change"));
    if (shouldScroll && targets[0]) {
      targets[0].scrollIntoView({ behavior: "smooth", block: "center" });
    }
    return targets.length > 0;
  };

  function setTableExpanded(wrapper, expanded) {
    const button = wrapper.querySelector(":scope > .table-expand");
    if (!button) return;
    wrapper.classList.toggle("is-expanded", expanded);
    layoutTable(wrapper);
    button.setAttribute("aria-expanded", expanded ? "true" : "false");
    button.setAttribute("aria-label", expanded ? "Collapse table" : "Expand table");
    button.setAttribute("title", expanded ? "Collapse table" : "Expand table");
    button.innerHTML = expanded ? tableCollapseIcon : tableExpandIcon;
  }

  window.addEventListener("resize", function () {
    enhanceTables();
  });

  function articleContentWidth() {
    const style = window.getComputedStyle(article);
    return Math.max(
      0,
      article.clientWidth -
        parseFloat(style.paddingLeft || "0") -
        parseFloat(style.paddingRight || "0")
    );
  }

  function wideTableSurface() {
    const shellStyle = window.getComputedStyle(shell);
    const shellRect = shell.getBoundingClientRect();
    const articleStyle = window.getComputedStyle(article);
    const articleRect = article.getBoundingClientRect();
    const surfaceLeft =
      shellRect.left + parseFloat(shellStyle.paddingLeft || "0");
    const surfaceRight =
      shellRect.right - parseFloat(shellStyle.paddingRight || "0");
    const textLeft =
      articleRect.left + parseFloat(articleStyle.paddingLeft || "0");
    return {
      width: Math.max(0, surfaceRight - surfaceLeft),
      leadingGutter: Math.max(0, textLeft - surfaceLeft),
    };
  }

  function layoutTable(wrapper) {
    const table = wrapper.querySelector("table");
    const sizer = wrapper.querySelector(".table-sizer");
    const firstRow = table && table.rows[0];
    const columnCount = Math.max(1, firstRow ? firstRow.cells.length : 1);
    const firstCell = firstRow && firstRow.cells[0];
    const computedCellWidth = firstCell
      ? parseFloat(window.getComputedStyle(firstCell).minWidth || "0")
      : 0;
    const readableColumnWidth = Math.max(144, computedCellWidth || 0);
    const expanded = wrapper.classList.contains("is-expanded");
    const contentWidth = articleContentWidth();
    const baseTableWidth = columnCount * readableColumnWidth;
    const tableWidth = columnCount *
      (expanded ? Math.max(220, readableColumnWidth) : readableColumnWidth);
    const shouldUseWideSurface = expanded || baseTableWidth > contentWidth + 1;

    if (sizer) sizer.style.minWidth = tableWidth + "px";
    wrapper.classList.toggle("is-wide", shouldUseWideSurface);
    if (shouldUseWideSurface) {
      const surface = wideTableSurface();
      wrapper.style.width = Math.max(contentWidth, surface.width) + "px";
      wrapper.style.marginLeft = -surface.leadingGutter + "px";
      wrapper.style.setProperty(
        "--table-leading-gutter",
        surface.leadingGutter + "px"
      );
    } else {
      wrapper.style.width = "";
      wrapper.style.marginLeft = "";
      wrapper.style.removeProperty("--table-leading-gutter");
    }
  }

  function enhanceTables() {
    article.querySelectorAll(".table-scroll").forEach(layoutTable);
  }

  window.previewmdRefreshTableLayout = enhanceTables;

  article.addEventListener("click", function (event) {
    const button = event.target.closest(".table-expand");
    if (!button || !article.contains(button)) return;
    const wrapper = button.closest(".table-scroll");
    if (!wrapper) return;
    event.preventDefault();
    event.stopPropagation();
    setTableExpanded(wrapper, !wrapper.classList.contains("is-expanded"));
  });

  const defaultImage =
    md.renderer.rules.image ||
    function (tokens, index, options, env, self) {
      return self.renderToken(tokens, index, options);
    };

  function routedImageSource(source) {
    const scheme = window.previewmdLocalImageScheme;
    if (!scheme || !source) return source;
    const protocol = source.match(/^([a-z][a-z0-9+.-]*):/i);
    if (protocol && protocol[1].toLowerCase() !== "file") return source;
    return scheme + "://resource?source=" + encodeURIComponent(source);
  }

  function setImageSource(image, source) {
    const originalSource = source || "";
    const routedSource = routedImageSource(originalSource);
    if (routedSource !== originalSource) {
      image.dataset.previewmdSource = originalSource;
    } else {
      delete image.dataset.previewmdSource;
    }
    image.setAttribute("src", routedSource);
  }

  md.renderer.rules.image = function (tokens, index, options, env, self) {
    const source = tokens[index].attrGet("src") || "";
    if (
      /^https?:\/\/(?:img\.)?shields\.io\//i.test(source) ||
      /^https?:\/\/(?:badgen\.net|badge\.fury\.io)\//i.test(source) ||
      /\/badge\.svg(?:[?#]|$)/i.test(source)
    ) {
      tokens[index].attrJoin("class", "markdown-badge");
    }
    const routedSource = routedImageSource(source);
    if (routedSource !== source) {
      tokens[index].attrSet("data-previewmd-source", source);
      tokens[index].attrSet("src", routedSource);
    }
    tokens[index].attrSet("loading", "lazy");
    tokens[index].attrSet("decoding", "async");
    return defaultImage(tokens, index, options, env, self);
  };

  window.previewmdOriginalImageSource = function (image) {
    return image.dataset.previewmdSource || image.getAttribute("src") || "";
  };
  window.previewmdSetImageSource = setImageSource;

  const defaultLinkOpen =
    md.renderer.rules.link_open ||
    function (tokens, index, options, env, self) {
      return self.renderToken(tokens, index, options);
    };
  md.renderer.rules.link_open = function (tokens, index, options, env, self) {
    const href = tokens[index].attrGet("href") || "";
    if (/^(https?:|mailto:)/i.test(href)) {
      tokens[index].attrSet("target", "_blank");
      tokens[index].attrSet("rel", "noopener noreferrer");
    }
    return defaultLinkOpen(tokens, index, options, env, self);
  };

  function enhanceTaskLists() {
    article.querySelectorAll("li").forEach((item) => {
      const target = item.querySelector(":scope > p") || item;
      const walker = document.createTreeWalker(target, NodeFilter.SHOW_TEXT);
      const textNode = walker.nextNode();
      if (!textNode) return;
      const match = textNode.nodeValue.match(/^\s*\[([ xX])\]\s+/);
      if (!match) return;

      textNode.nodeValue = textNode.nodeValue.slice(match[0].length);
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = match[1].toLowerCase() === "x";
      checkbox.disabled = true;
      checkbox.setAttribute("aria-label", checkbox.checked ? "Completed" : "Not completed");
      target.insertBefore(checkbox, target.firstChild);
      item.classList.add("task-list-item");
      item.parentElement && item.parentElement.classList.add("task-list");
    });
  }

  function enhanceAlerts() {
    const labels = {
      NOTE: ["Note", "info"],
      TIP: ["Tip", "lightbulb"],
      IMPORTANT: ["Important", "important"],
      WARNING: ["Warning", "warning"],
      CAUTION: ["Caution", "caution"],
    };

    article.querySelectorAll("blockquote").forEach((quote) => {
      const firstParagraph = quote.querySelector(":scope > p:first-child");
      if (!firstParagraph) return;
      const match = firstParagraph.textContent.match(/^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*/i);
      if (!match) return;

      const key = match[1].toUpperCase();
      const walker = document.createTreeWalker(firstParagraph, NodeFilter.SHOW_TEXT);
      const textNode = walker.nextNode();
      if (textNode) {
        textNode.nodeValue = textNode.nodeValue.replace(
          new RegExp("^\\s*\\[!" + key + "\\]\\s*", "i"),
          ""
        );
      }

      quote.classList.add("markdown-alert", "alert-" + key.toLowerCase());
      const title = document.createElement("div");
      title.className = "alert-title";
      title.textContent = labels[key][0];
      quote.insertBefore(title, quote.firstChild);
    });
  }

  function addHeadingAnchors() {
    article.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((heading) => {
      const anchor = document.createElement("a");
      anchor.className = "heading-anchor";
      anchor.href = "#" + heading.id;
      anchor.setAttribute("aria-label", "Link to this heading");
      anchor.textContent = "#";
      heading.appendChild(anchor);
    });
  }

  function setCodeCopyHandlers() {
    article.querySelectorAll(".copy-code").forEach((button) => {
      button.addEventListener("click", () => {
        const code = button.closest(".code-card").querySelector("code").textContent;
        if (window.webkit && window.webkit.messageHandlers.copyText) {
          window.webkit.messageHandlers.copyText.postMessage(code);
        } else if (navigator.clipboard) {
          navigator.clipboard.writeText(code);
        }
        const label = button.querySelector("span:last-child");
        const old = label.textContent;
        label.textContent = "Copied";
        button.classList.add("copied");
        window.setTimeout(() => {
          label.textContent = old;
          button.classList.remove("copied");
        }, 1400);
      });
    });
  }

  const clipboardAssetURLPrefix = "previewmd-copy-asset:";
  let clipboardAssetSequence = 0;

  function portableCopyAtomicRoot(node) {
    const element =
      node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
    if (!element) return null;
    const displayMath = element.closest(".katex-display");
    return displayMath || element.closest(".katex, .diagram-card, img");
  }

  function rangeForPortableCopy() {
    const selection = window.getSelection();
    if (selection && selection.rangeCount && !selection.isCollapsed) {
      const range = selection.getRangeAt(0);
      const common =
        range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
          ? range.commonAncestorContainer
          : range.commonAncestorContainer.parentElement;
      if (common && (common === article || article.contains(common))) {
        const adjusted = range.cloneRange();
        const startObject = portableCopyAtomicRoot(range.startContainer);
        const endObject = portableCopyAtomicRoot(range.endContainer);
        if (startObject && article.contains(startObject)) adjusted.setStartBefore(startObject);
        if (endObject && article.contains(endObject)) adjusted.setEndAfter(endObject);
        return adjusted;
      }
    }

    // The visual editor represents selected formulas, diagrams, images, and
    // tables as objects rather than DOM text selections. Cmd-C should still
    // copy that object through the same portable path.
    const selectedObject = article.querySelector(".editor-selected-object");
    if (!selectedObject) return null;
    const range = document.createRange();
    range.selectNode(selectedObject);
    return range;
  }

  function rangeIntersectsNode(range, node) {
    try {
      return range.intersectsNode(node);
    } catch (_) {
      return false;
    }
  }

  function mathSource(node) {
    const annotation = node.querySelector(
      '.katex-mathml annotation[encoding="application/x-tex"]'
    );
    return annotation ? annotation.textContent.trim() : "Formula";
  }

  function serializedDiagramSVG(node) {
    const source = node.querySelector(".mermaid svg");
    if (!source) return "";
    const svg = source.cloneNode(true);
    if (!svg.getAttribute("xmlns")) {
      svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    }
    return new XMLSerializer().serializeToString(svg);
  }

  function fittedPortableCopySize(width, height, maxWidth, maxHeight) {
    const safeWidth = Math.max(1, Number(width) || 1);
    const safeHeight = Math.max(1, Number(height) || 1);
    const scale = Math.min(1, maxWidth / safeWidth, maxHeight / safeHeight);
    return {
      width: Math.max(1, safeWidth * scale),
      height: Math.max(1, safeHeight * scale),
    };
  }

  function portableCopyDisplaySize(kind, rootNode, isBlock, width, height) {
    if (kind === "diagram") {
      return fittedPortableCopySize(width, height, 420, 320);
    }
    if (kind === "math") {
      return isBlock
        ? fittedPortableCopySize(width, height, 420, 112)
        : fittedPortableCopySize(width, height, 280, 42);
    }
    if (rootNode.classList.contains("markdown-badge")) {
      return fittedPortableCopySize(width, height, 180, 20);
    }
    return isBlock
      ? fittedPortableCopySize(width, height, 360, 360)
      : fittedPortableCopySize(width, height, 240, 80);
  }

  function visibleMathBounds(rootNode, fallbackNode) {
    const html = rootNode.querySelector(".katex-html");
    if (!html) return fallbackNode.getBoundingClientRect();
    const rows = Array.from(html.children).filter(
      (child) => child.classList.contains("base") || child.classList.contains("tag")
    );
    if (!rows.length) return html.getBoundingClientRect();

    let left = Infinity;
    let top = Infinity;
    let right = -Infinity;
    let bottom = -Infinity;
    rows.forEach((row) => {
      const rect = row.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      left = Math.min(left, rect.left);
      top = Math.min(top, rect.top);
      right = Math.max(right, rect.right);
      bottom = Math.max(bottom, rect.bottom);
    });
    if (!Number.isFinite(left)) return html.getBoundingClientRect();
    return { width: right - left, height: bottom - top };
  }

  function collectPortableCopyAssets(range) {
    const roots = [];
    article.querySelectorAll(".katex-display").forEach((node) => roots.push(node));
    article.querySelectorAll(".katex").forEach((node) => {
      if (!node.closest(".katex-display")) roots.push(node);
    });
    article.querySelectorAll(".diagram-card, img").forEach((node) => roots.push(node));
    roots.sort((left, right) => {
      if (left === right) return 0;
      return left.compareDocumentPosition(right) & Node.DOCUMENT_POSITION_FOLLOWING
        ? -1
        : 1;
    });

    const assets = [];
    const markedRoots = [];
    roots.forEach((rootNode) => {
      if (!rangeIntersectsNode(range, rootNode)) return;

      const id =
        "asset-" + Date.now().toString(36) + "-" + (++clipboardAssetSequence).toString(36);
      let kind = "image";
      let label = rootNode.getAttribute("alt") || "Image";
      let snapshotNode = rootNode;
      let svg = "";
      let markup = "";
      let isBlock = false;

      if (rootNode.classList.contains("katex-display")) {
        kind = "math";
        const source = mathSource(rootNode);
        label = source === "Formula" ? source : "$$" + source + "$$";
        snapshotNode = rootNode.querySelector(".katex") || rootNode;
        isBlock = true;
      } else if (rootNode.classList.contains("katex")) {
        kind = "math";
        const source = mathSource(rootNode);
        label = source === "Formula" ? source : "$" + source + "$";
      } else if (rootNode.classList.contains("diagram-card")) {
        kind = "diagram";
        label = "Diagram";
        snapshotNode = rootNode.querySelector(".mermaid svg") || rootNode;
        svg = serializedDiagramSVG(rootNode);
        isBlock = true;
      } else {
        isBlock = window.getComputedStyle(rootNode).display === "block";
      }

      // A display KaTeX node is a full-width centering container. Measuring
      // that wrapper would create a page-wide attachment with a small formula
      // floating in the middle. Measure the visible glyph run instead while
      // retaining the complete KaTeX markup for the snapshot.
      const rect =
        kind === "math"
          ? visibleMathBounds(rootNode, snapshotNode)
          : snapshotNode.getBoundingClientRect();
      const capturePadding = kind === "math" ? 4 : 0;
      const captureWidth = Math.max(1, rect.width + capturePadding);
      const captureHeight = Math.max(1, rect.height + capturePadding);
      const displaySize = portableCopyDisplaySize(
        kind,
        rootNode,
        isBlock,
        captureWidth,
        captureHeight
      );
      // Even when the renderer can expose the original vector, composite rich
      // text needs a raster representation. Pages expands SVG attachments from
      // RTFD into their internal XML/CSS instead of treating them as artwork.
      // Native code snapshots this markup for the embedded representation and
      // keeps `svg` only as an additional type when this is the sole object.
      markup = snapshotNode.outerHTML;
      rootNode.setAttribute("data-previewmd-copy-asset-id", id);
      markedRoots.push(rootNode);
      assets.push({
        id: id,
        kind: kind,
        label: label,
        width: captureWidth,
        height: captureHeight,
        displayWidth: displaySize.width,
        displayHeight: displaySize.height,
        svg: svg,
        markup: markup,
        isBlock: isBlock,
      });
    });
    return { assets: assets, markedRoots: markedRoots };
  }

  function simplifyPortableCopyFragment(fragment, assets) {
    const container = document.createElement("div");
    container.appendChild(fragment);
    const assetsByID = new Map(assets.map((asset) => [asset.id, asset]));

    container
      .querySelectorAll(
        ".heading-anchor, .copy-code, .code-toolbar, .diagram-label, .table-expand, " +
          ".editor-bubble-toolbar, .editor-object-source, .editor-block-inserter, " +
          ".editor-markdown-composer, .diagram-editor, .footnote-backref"
      )
      .forEach((node) => node.remove());

    container.querySelectorAll(".code-card").forEach((card) => {
      const pre = card.querySelector("pre");
      if (pre) card.replaceWith(pre);
    });
    container.querySelectorAll(".table-scroll").forEach((wrapper) => {
      const table = wrapper.querySelector("table");
      if (table) wrapper.replaceWith(table);
    });
    container.querySelectorAll('input[type="checkbox"]').forEach((checkbox) => {
      checkbox.replaceWith(document.createTextNode(checkbox.checked ? "☑ " : "☐ "));
    });

    container.querySelectorAll("[data-previewmd-copy-asset-id]").forEach((node) => {
      const id = node.getAttribute("data-previewmd-copy-asset-id");
      const asset = assetsByID.get(id);
      if (!asset) {
        node.remove();
        return;
      }
      const image = document.createElement("img");
      image.setAttribute("src", clipboardAssetURLPrefix + id);
      image.setAttribute("alt", asset.label);
      image.setAttribute(
        "width",
        String(Math.max(1, Math.round(asset.displayWidth)))
      );
      image.setAttribute(
        "height",
        String(Math.max(1, Math.round(asset.displayHeight)))
      );
      image.setAttribute(
        "style",
        asset.isBlock
          ? "display:block;max-width:100%;height:auto;margin:9pt auto 12pt;page-break-inside:avoid;"
          : "display:inline-block;max-width:100%;height:auto;vertical-align:-0.18em;"
      );
      node.replaceWith(image);
    });

    // A range can begin inside a contenteditable=false object. In that case
    // cloneContents may omit the marked outer node. Never let a partial KaTeX
    // or diagram implementation leak into portable HTML; keep a semantic text
    // fallback instead.
    container.querySelectorAll(".katex-display").forEach((node) => {
      const source = mathSource(node);
      node.replaceWith(document.createTextNode(source === "Formula" ? source : "$$" + source + "$$"));
    });
    container.querySelectorAll(".katex").forEach((node) => {
      const source = mathSource(node);
      node.replaceWith(document.createTextNode(source === "Formula" ? source : "$" + source + "$"));
    });
    container.querySelectorAll(".diagram-card, .mermaid").forEach((node) => {
      node.replaceWith(document.createTextNode("[Diagram]"));
    });

    const allowedAttributes = {
      A: new Set(["href", "title"]),
      BLOCKQUOTE: new Set(["cite"]),
      TD: new Set(["colspan", "rowspan"]),
      TH: new Set(["colspan", "rowspan", "scope"]),
      OL: new Set(["start"]),
      LI: new Set(["value"]),
      IMG: new Set(["src", "alt", "width", "height", "style"]),
    };
    container.querySelectorAll("*").forEach((element) => {
      if (
        element.tagName === "A" &&
        /^\s*(?:javascript|vbscript|data):/i.test(element.getAttribute("href") || "")
      ) {
        element.removeAttribute("href");
      }
      const allowed = allowedAttributes[element.tagName] || new Set();
      Array.from(element.attributes).forEach((attribute) => {
        if (!allowed.has(attribute.name.toLowerCase())) {
          element.removeAttribute(attribute.name);
        }
      });
    });

    return container;
  }

  function plainTextForPortableCopy(container) {
    const copy = container.cloneNode(true);
    copy.querySelectorAll("table").forEach((table) => {
      const rows = Array.from(table.rows, (row) =>
        Array.from(row.cells, (cell) => cell.textContent.trim()).join("\t")
      );
      table.replaceWith(document.createTextNode("\n" + rows.join("\n") + "\n"));
    });
    copy.querySelectorAll("img").forEach((image) => {
      image.replaceWith(document.createTextNode(image.getAttribute("alt") || "Image"));
    });

    copy.style.position = "fixed";
    copy.style.left = "-100000px";
    copy.style.top = "0";
    copy.style.width = "720px";
    copy.style.whiteSpace = "pre-wrap";
    document.body.appendChild(copy);
    const text = copy.innerText;
    copy.remove();
    return text
      .replace(/\u00a0/g, " ")
      .replace(/[ \t]+\n/g, "\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }

  function portableClipboardHTML(container) {
    return (
      '<!doctype html><html><head><meta charset="utf-8"><style>' +
      "html,body{margin:0;padding:0;background:#fff;color:#24262d;}" +
      "body{font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;" +
      "font-size:12.5pt;line-height:1.48;}" +
      "p{margin:0 0 9pt;}h1,h2,h3,h4,h5,h6{margin:16pt 0 7pt;line-height:1.2;" +
      "font-weight:700;page-break-after:avoid;}h1{font-size:24pt;}h2{font-size:19pt;}" +
      "h3{font-size:15.5pt;}h4,h5,h6{font-size:13pt;}a{color:#3f51c6;text-decoration:underline;}" +
      "ul,ol{margin:0 0 10pt;padding-left:24pt;}li{margin:2pt 0;}" +
      "blockquote{margin:10pt 0;padding:7pt 11pt;border-left:3pt solid #a1a1aa;" +
      "background:#f7f7f8;color:#4b5563;}pre{margin:10pt 0;padding:9pt;border:0.75pt solid #d4d4d8;" +
      "background:#f7f7f8;font-family:Menlo,Monaco,monospace;font-size:10pt;white-space:pre-wrap;}" +
      "code{font-family:Menlo,Monaco,monospace;font-size:.9em;}" +
      "table{border-collapse:collapse;margin:10pt 0;max-width:100%;}th,td{border:0.75pt solid #c7c7cc;" +
      "padding:5pt 7pt;text-align:left;vertical-align:top;}th{background:#f1f1f3;font-weight:650;}" +
      "img{max-width:100%;}hr{border:0;border-top:0.75pt solid #c7c7cc;margin:14pt 0;}" +
      "</style></head><body><!--StartFragment-->" +
      container.innerHTML +
      "<!--EndFragment--></body></html>"
    );
  }

  function wholeDocumentRange() {
    const range = document.createRange();
    range.selectNodeContents(article);
    return range;
  }

  function buildPortableClipboardPayload(options) {
    const configuration = options || {};
    const range = configuration.wholeDocument
      ? wholeDocumentRange()
      : rangeForPortableCopy();
    if (!range || range.collapsed) return null;
    const collection = collectPortableCopyAssets(range);
    let fragment;
    try {
      fragment = range.cloneContents();
    } finally {
      collection.markedRoots.forEach((node) =>
        node.removeAttribute("data-previewmd-copy-asset-id")
      );
    }

    const container = simplifyPortableCopyFragment(fragment, collection.assets);
    const referencedIDs = new Set(
      Array.from(container.querySelectorAll("img"), (image) =>
        (image.getAttribute("src") || "").startsWith(clipboardAssetURLPrefix)
          ? (image.getAttribute("src") || "").slice(clipboardAssetURLPrefix.length)
          : ""
      ).filter(Boolean)
    );
    const assets = collection.assets.filter((asset) => referencedIDs.has(asset.id));

    const probe = container.cloneNode(true);
    const probeAssets = Array.from(probe.querySelectorAll("img"));
    probeAssets.forEach((node) => node.remove());
    const standaloneAssetID =
      assets.length === 1 && probeAssets.length === 1 && !probe.textContent.trim()
        ? assets[0].id
        : null;

    let markdown = "";
    try {
      markdown = configuration.wholeDocument && window.previewmdSerializeEditor
        ? window.previewmdSerializeEditor()
        : window.previewmdSerializeFragment
          ? window.previewmdSerializeFragment(container)
          : plainTextForPortableCopy(container);
    } catch (_) {
      markdown = plainTextForPortableCopy(container);
    }

    return {
      html: portableClipboardHTML(container),
      plainText: plainTextForPortableCopy(container),
      markdown: markdown,
      assets: assets,
      standaloneAssetID: standaloneAssetID,
      destination: configuration.destination || "automatic",
      suggestedName: configuration.suggestedName || "PreviewMD Document.docx",
    };
  }

  function handlePortableCopy(event) {
    const payload = buildPortableClipboardPayload({ destination: "automatic" });
    if (!payload) return;

    let handler = null;
    try {
      handler =
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.copyRichText;
    } catch (_) {}

    if (event.clipboardData) {
      event.preventDefault();
      // In PreviewMD, native code owns the pasteboard transaction so WebKit's
      // delayed commit cannot race the resolved RTFD assets. Keep this branch
      // only as a portable fallback when the renderer has no native bridge.
      if (!handler) {
        event.clipboardData.setData("text/plain", payload.plainText);
        if (!payload.assets.length) {
          event.clipboardData.setData("text/html", payload.html);
        }
      }
    }

    try {
      if (handler) handler.postMessage(payload);
    } catch (_) {
      if (event.clipboardData) {
        event.clipboardData.setData("text/plain", payload.plainText);
        if (!payload.assets.length) {
          event.clipboardData.setData("text/html", payload.html);
        }
      }
    }
  }

  article.addEventListener("copy", handlePortableCopy);
  window.previewmdBuildClipboardPayload = buildPortableClipboardPayload;
  window.previewmdAdvancedCopy = function (destination, suggestedName) {
    const payload = buildPortableClipboardPayload({
      destination: destination,
      suggestedName: suggestedName,
    });
    if (!payload) return false;
    try {
      const handler =
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.copyRichText;
      if (!handler) return false;
      handler.postMessage(payload);
      return true;
    } catch (_) {
      return false;
    }
  };
  window.previewmdExportDOCX = function (suggestedName) {
    const payload = buildPortableClipboardPayload({
      destination: "exportDOCX",
      wholeDocument: true,
      suggestedName: suggestedName,
    });
    if (!payload) return false;
    try {
      const handler =
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.copyRichText;
      if (!handler) return false;
      handler.postMessage(payload);
      return true;
    } catch (_) {
      return false;
    }
  };

  let clipboardSnapshotStage = null;
  window.previewmdFinishClipboardAssetSnapshot = function () {
    if (clipboardSnapshotStage) clipboardSnapshotStage.remove();
    clipboardSnapshotStage = null;
  };
  window.previewmdPrepareClipboardAssetSnapshot = async function (
    markup,
    requestedWidth,
    requestedHeight
  ) {
    window.previewmdFinishClipboardAssetSnapshot();
    const width = Math.min(
      Math.max(1, Math.ceil(Number(requestedWidth) || 1)),
      Math.max(1, window.innerWidth)
    );
    const height = Math.min(
      Math.max(1, Math.ceil(Number(requestedHeight) || 1)),
      Math.max(1, window.innerHeight)
    );
    const stage = document.createElement("div");
    stage.setAttribute("contenteditable", "false");
    stage.setAttribute("aria-hidden", "true");
    stage.style.position = "fixed";
    stage.style.left = Math.max(0, window.innerWidth - width) + "px";
    stage.style.top = Math.max(0, window.innerHeight - height) + "px";
    stage.style.zIndex = "2147483647";
    stage.style.display = "flex";
    stage.style.boxSizing = "border-box";
    stage.style.width = width + "px";
    stage.style.height = height + "px";
    stage.style.alignItems = "center";
    stage.style.justifyContent = "center";
    stage.style.overflow = "hidden";
    stage.style.background = "#fff";
    stage.style.color = "#24262d";
    stage.style.fontFamily =
      '-apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif';
    stage.innerHTML = markup;
    const directImage = stage.querySelector(":scope > img");
    if (directImage) {
      directImage.style.display = "block";
      directImage.style.maxWidth = "100%";
      directImage.style.maxHeight = "100%";
      directImage.style.objectFit = "contain";
    }
    document.body.appendChild(stage);
    clipboardSnapshotStage = stage;

    const images = Array.from(stage.querySelectorAll("img"));
    images.forEach((image) => { image.loading = "eager"; });
    const readiness = Promise.all(images.map((image) => {
      if (image.complete) return Promise.resolve();
      return new Promise((resolve) => {
        image.addEventListener("load", resolve, { once: true });
        image.addEventListener("error", resolve, { once: true });
      });
    }));
    await Promise.race([
      readiness,
      new Promise((resolve) => setTimeout(resolve, 1200)),
    ]);
    await Promise.race([
      new Promise((resolve) => requestAnimationFrame(resolve)),
      new Promise((resolve) => setTimeout(resolve, 80)),
    ]);
    const rect = stage.getBoundingClientRect();
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  };

  async function renderDiagrams(version, isDark) {
    if (!window.mermaid) return;

    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: isDark ? "dark" : "base",
      suppressErrorRendering: true,
      fontFamily:
        '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif',
      themeVariables: isDark
        ? {
            primaryColor: "#282b3f",
            primaryTextColor: "#f1f2f7",
            primaryBorderColor: "#747be8",
            lineColor: "#8b91a8",
            secondaryColor: "#242d38",
            tertiaryColor: "#30293e",
          }
        : {
            primaryColor: "#f0efff",
            primaryTextColor: "#26263a",
            primaryBorderColor: "#6966df",
            lineColor: "#73788a",
            secondaryColor: "#eef7ff",
            tertiaryColor: "#fff4ec",
          },
    });

    const diagrams = Array.from(article.querySelectorAll(".mermaid"));
    for (let index = 0; index < diagrams.length; index += 1) {
      if (version !== renderVersion) return;
      const node = diagrams[index];
      const source = node.textContent;
      node.dataset.source = source;
      try {
        const result = await window.mermaid.render(
          "previewmd-diagram-" + version + "-" + index,
          source
        );
        node.innerHTML = result.svg;
        node.classList.add("rendered");
      } catch (error) {
        node.classList.add("diagram-error");
        node.textContent = source;
        const card = node.closest(".diagram-card");
        if (card) {
          const label = card.querySelector(".diagram-label span");
          label.textContent = "Diagram syntax error";
        }
      }
    }
  }

  function renderMath() {
    if (!window.renderMathInElement) return;
    window.renderMathInElement(article, {
      delimiters: [
        { left: "$$", right: "$$", display: true },
        { left: "\\[", right: "\\]", display: true },
        { left: "\\(", right: "\\)", display: false },
        { left: "$", right: "$", display: false },
      ],
      ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code"],
      throwOnError: false,
      strict: false,
    });
  }

  function parseSearchQuery(query) {
    const normalized = (query || "").trim().replace(/\s+/g, " ");
    if (!normalized) return { components: [], preferredPhrase: "" };

    const components = [];
    const seen = new Set();
    const expression = /"([^"]+)"|(\S+)/g;
    let match;
    while ((match = expression.exec(normalized)) !== null) {
      const value = (match[1] || match[2] || "").trim().replace(/\s+/g, " ");
      const key = value.toLocaleLowerCase();
      if (value && !seen.has(key)) {
        seen.add(key);
        components.push(value);
      }
    }

    return {
      components: components,
      preferredPhrase:
        !normalized.includes('"') && components.length > 1 ? normalized : "",
    };
  }

  function findInDocument(query) {
    activeSearchText = query || "";
    if (window.CSS && CSS.highlights) {
      CSS.highlights.delete("search-result");
    }
    const normalized = activeSearchText.trim();
    if (!normalized) return;

    const searchQuery = parseSearchQuery(normalized);
    if (!searchQuery.components.length) return;

    if (!(window.CSS && CSS.highlights && window.Highlight)) {
      window.find(
        searchQuery.preferredPhrase || searchQuery.components[0],
        false,
        false,
        true,
        false,
        true,
        false
      );
      return;
    }

    const textNodes = [];
    const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        if (node.parentElement.closest("script, style")) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });

    while (walker.nextNode()) {
      textNodes.push(walker.currentNode);
    }

    function rangesFor(needles) {
      const ranges = [];
      const foldedNeedles = needles.map(function (needle) {
        return needle.toLocaleLowerCase();
      });

      for (const node of textNodes) {
        const haystack = node.nodeValue.toLocaleLowerCase();
        const matches = [];
        for (const needle of foldedNeedles) {
          let start = 0;
          while ((start = haystack.indexOf(needle, start)) !== -1) {
            matches.push({ start: start, length: needle.length });
            start += needle.length;
          }
        }
        matches.sort(function (left, right) {
          return left.start - right.start;
        });
        for (const match of matches) {
          const range = new Range();
          range.setStart(node, match.start);
          range.setEnd(node, match.start + match.length);
          ranges.push(range);
        }
      }
      return ranges;
    }

    let ranges = searchQuery.preferredPhrase
      ? rangesFor([searchQuery.preferredPhrase])
      : [];
    if (!ranges.length) {
      ranges = rangesFor(searchQuery.components);
    }

    if (ranges.length) {
      CSS.highlights.set("search-result", new Highlight(...ranges));
      const marker = document.createElement("span");
      marker.style.position = "absolute";
      marker.style.pointerEvents = "none";
      ranges[0].insertNode(marker);
      marker.scrollIntoView({ behavior: "smooth", block: "center" });
      marker.remove();
    }
  }

  function updateProgress() {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    const ratio = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0;
    progress.style.transform = "scaleX(" + ratio + ")";
  }

  window.addEventListener("scroll", updateProgress, { passive: true });

  window.previewmdFind = findInDocument;
  window.previewmdScrollTo = function (targetID) {
    const target = document.getElementById(targetID);
    target && target.scrollIntoView({ behavior: "smooth", block: "start" });
  };
  window.previewmdSetLayout = function (readingWidth, paperCanvas, topInset, fluidWidth) {
    root.dataset.paper = paperCanvas ? "true" : "false";
    root.dataset.width = fluidWidth ? "fluid" : "fixed";
    root.style.setProperty("--reading-width", readingWidth + "px");
    root.style.setProperty("--top-inset", (topInset || 0) + "px");
    window.requestAnimationFrame(enhanceTables);
  };

  window.previewmdRender = async function (options) {
    lastRenderOptions = Object.assign({}, options);
    const version = ++renderVersion;
    const isDark =
      options.theme === "dark" ||
      (options.theme === "system" && options.systemDark === true);

    root.dataset.theme = isDark ? "dark" : "light";
    root.dataset.style = options.readingStyle || "modern";
    applyCustomPreset(
      options.readingStyle === "custom" ? options.customReadingPreset : null,
      isDark
    );
    window.previewmdSetLayout(
      options.readingWidth,
      options.paperCanvas,
      options.topInset,
      options.readingWidthIsFluid === true
    );
    activeSearchText = options.searchText || "";
    errorBox.hidden = true;

    try {
      const frontmatter = extractFrontmatter(options.markdown || "");
      const renderEnvironment = { headingIndex: 0 };
      const tokens = md.parse(frontmatter.body, renderEnvironment);
      markSourcePositionTokens(tokens, frontmatter.lineOffset);
      const frontmatterChangeIndexes = markExternalChangeTokens(
        tokens,
        options.externalChanges || [],
        frontmatter.lineOffset
      );
      article.innerHTML =
        frontmatter.html + md.renderer.render(tokens, md.options, renderEnvironment);
      indexExternalChangeTargets(
        options.externalChanges || [],
        frontmatterChangeIndexes
      );
      enhanceTables();
      enhanceTaskLists();
      enhanceAlerts();
      addHeadingAnchors();
      setCodeCopyHandlers();
      renderMath();
      await renderDiagrams(version, isDark);

      if (version !== renderVersion) return;
      window.previewmdSelectExternalChange(options.externalChangeSelection, false);
      findInDocument(activeSearchText);
      if (options.outlineTarget) {
        window.previewmdScrollTo(options.outlineTarget);
      }
      if (window.previewmdEditorDidRender) {
        window.previewmdEditorDidRender(options.markdown || "", options.editable === true);
      }
      updateProgress();
    } catch (error) {
      errorBox.hidden = false;
      errorBox.textContent = "Preview couldn’t be rendered: " + error.message;
    }
  };

  window.previewmdRefreshEditor = function (markdown) {
    if (!lastRenderOptions) return;
    const options = Object.assign({}, lastRenderOptions, { markdown: markdown });
    window.previewmdRender(options);
  };

  window.previewmdPreparePrint = async function (options) {
    if (!lastRenderOptions) return;
    printRestoreOptions = Object.assign({}, lastRenderOptions);
    const printOptions = Object.assign({}, lastRenderOptions, {
      editable: false,
      theme: options.theme || "light",
      readingStyle: options.style || "modern",
      customReadingPreset: options.customPreset || null,
      paperCanvas: false,
      readingWidthIsFluid: true,
      topInset: 0,
      searchText: "",
      outlineTarget: null,
      externalChanges: [],
      externalChangeSelection: null,
    });
    await window.previewmdRender(printOptions);
  };

  window.previewmdFinishPrint = async function () {
    if (!printRestoreOptions) return;
    const restore = printRestoreOptions;
    printRestoreOptions = null;
    await window.previewmdRender(restore);
  };
})();
