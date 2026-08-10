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
