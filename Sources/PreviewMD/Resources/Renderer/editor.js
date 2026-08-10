(function () {
  "use strict";

  const article = document.getElementById("preview-document");
  if (!article) return;

  let editable = false;
  let currentMarkdown = "";
  let emitTimer = 0;
  let pendingHistoryBoundary = false;
  let domChanged = false;
  let savedRange = null;
  let selectedObject = null;
  let inserterTarget = null;
  let imagePickerPending = false;
  let splitSelectionFrame = 0;
  let splitScrollFrame = 0;
  let ignoreSplitSelectionUntil = 0;
  let ignoreSplitScrollUntil = 0;
  let splitSynchronizedRange = null;

  const keyboardObjectSelector =
    ".frontmatter-card, .table-scroll, .code-card, .diagram-card, .katex-display, .katex, img, hr:not(.footnotes-sep)";
  const listItemBlockTags = new Set([
    "address",
    "article",
    "aside",
    "blockquote",
    "div",
    "dl",
    "fieldset",
    "figure",
    "footer",
    "form",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "header",
    "hr",
    "main",
    "nav",
    "ol",
    "p",
    "pre",
    "section",
    "table",
    "ul",
  ]);

  const textToolbar = makeTextToolbar();
  const objectToolbar = makeObjectToolbar();
  const blockInserter = makeBlockInserter();
  const splitSyncCaret = makeSplitSyncCaret();

  function makeSplitSyncCaret() {
    const caret = document.createElement("div");
    caret.className = "split-sync-caret";
    caret.setAttribute("aria-hidden", "true");
    caret.setAttribute("contenteditable", "false");
    caret.hidden = true;
    document.body.appendChild(caret);
    return caret;
  }

  function makeTextToolbar() {
    const toolbar = document.createElement("div");
    toolbar.id = "selection-toolbar";
    toolbar.className = "editor-bubble-toolbar";
    toolbar.setAttribute("role", "toolbar");
    toolbar.setAttribute("aria-label", "Text formatting");
    toolbar.setAttribute("contenteditable", "false");
    toolbar.hidden = true;
    toolbar.innerHTML =
      '<select data-editor-block aria-label="Text style">' +
      '<option value="p">Text</option>' +
      '<option value="h1">Heading 1</option>' +
      '<option value="h2">Heading 2</option>' +
      '<option value="h3">Heading 3</option>' +
      '<option value="h4">Heading 4</option>' +
      '<option value="h5">Heading 5</option>' +
      '<option value="h6">Heading 6</option>' +
      '<option value="blockquote">Quote</option>' +
      '<option value="pre">Code block</option>' +
      "</select>" +
      '<span class="editor-toolbar-separator"></span>' +
      '<button type="button" data-editor-command="bold" aria-label="Bold" title="Bold (⌘B)"><strong>B</strong></button>' +
      '<button type="button" data-editor-command="italic" aria-label="Italic" title="Italic (⌘I)"><em>I</em></button>' +
      '<button type="button" data-editor-command="strikeThrough" aria-label="Strikethrough" title="Strikethrough"><s>S</s></button>' +
      '<button type="button" data-editor-action="inline-code" aria-label="Inline code" title="Inline code"><span class="editor-code-icon">&lt;/&gt;</span></button>' +
      '<button type="button" data-editor-action="link" aria-label="Link" title="Link (⌘K)">↗</button>' +
      '<span class="editor-toolbar-separator"></span>' +
      '<button type="button" data-editor-command="insertUnorderedList" aria-label="Bulleted list" title="Bulleted list">•≡</button>' +
      '<button type="button" data-editor-command="insertOrderedList" aria-label="Numbered list" title="Numbered list">1≡</button>' +
      '<button type="button" data-editor-action="task-list" aria-label="Task list" title="Task list">☑</button>';
    document.body.appendChild(toolbar);

    toolbar.addEventListener("mousedown", (event) => {
      if (event.target.closest("select")) return;
      event.preventDefault();
    });

    toolbar.addEventListener("click", (event) => {
      const commandButton = event.target.closest("[data-editor-command]");
      const actionButton = event.target.closest("[data-editor-action]");
      restoreSelection();

      if (commandButton) {
        document.execCommand(commandButton.dataset.editorCommand, false, null);
        scheduleChange(true, true);
        updateSelectionToolbar();
      } else if (actionButton) {
        performTextAction(actionButton.dataset.editorAction);
      }
    });

    toolbar.querySelector("[data-editor-block]").addEventListener("change", (event) => {
      restoreSelection();
      if (event.target.value === "pre") {
        convertSelectionToCodeBlock();
      } else {
        document.execCommand("formatBlock", false, event.target.value);
      }
      scheduleChange(true, true);
      updateSelectionToolbar();
    });

    return toolbar;
  }

  function makeObjectToolbar() {
    const toolbar = document.createElement("div");
    toolbar.id = "object-toolbar";
    toolbar.className = "editor-bubble-toolbar editor-object-toolbar";
    toolbar.setAttribute("role", "toolbar");
    toolbar.setAttribute("aria-label", "Object actions");
    toolbar.setAttribute("contenteditable", "false");
    toolbar.hidden = true;
    toolbar.innerHTML =
      '<span class="editor-object-label">Object</span>' +
      '<span class="editor-toolbar-separator"></span>' +
      '<button type="button" data-object-action="edit">Edit</button>' +
      '<button type="button" data-object-action="add-row">+ Row</button>' +
      '<button type="button" data-object-action="remove-row">− Row</button>' +
      '<button type="button" data-object-action="add-column">+ Column</button>' +
      '<button type="button" data-object-action="remove-column">− Column</button>' +
      '<button type="button" data-object-action="align-left" aria-label="Align column left">←</button>' +
      '<button type="button" data-object-action="align-center" aria-label="Align column center">↔</button>' +
      '<button type="button" data-object-action="align-right" aria-label="Align column right">→</button>' +
      '<span class="editor-toolbar-separator"></span>' +
      '<button type="button" data-object-action="delete" class="editor-destructive">Delete</button>';
    document.body.appendChild(toolbar);

    toolbar.addEventListener("mousedown", (event) => event.preventDefault());
    toolbar.addEventListener("click", (event) => {
      const button = event.target.closest("[data-object-action]");
      if (!button || !selectedObject) return;
      performObjectAction(button.dataset.objectAction);
    });
    return toolbar;
  }

  function makeBlockInserter() {
    const inserter = document.createElement("div");
    inserter.id = "block-inserter";
    inserter.className = "editor-block-inserter";
    inserter.setAttribute("contenteditable", "false");
    inserter.hidden = true;
    inserter.innerHTML =
      '<button type="button" class="editor-block-add" aria-label="Insert Markdown block" aria-expanded="false" title="Insert Markdown block">+</button>' +
      '<div class="editor-insert-menu" role="menu" aria-label="Insert Markdown" hidden>' +
      '<div class="editor-insert-menu-title">Insert</div>' +
      insertMenuSection(
        "Basic",
        [
          ["text", "¶", "Text"],
          ["heading-1", "H1", "Heading 1"],
          ["heading-2", "H2", "Heading 2"],
          ["heading-3", "H3", "Heading 3"],
          ["heading-4", "H4", "Heading 4"],
          ["heading-5", "H5", "Heading 5"],
          ["heading-6", "H6", "Heading 6"],
          ["quote", "❝", "Quote"],
        ]
      ) +
      insertMenuSection(
        "Lists",
        [
          ["bullet-list", "•", "Bulleted list"],
          ["numbered-list", "1.", "Numbered list"],
          ["task-list", "☑", "Task list"],
        ]
      ) +
      insertMenuSection(
        "Data & media",
        [
          ["table", "▦", "Table"],
          ["code", "</>", "Code block"],
          ["mermaid", "◇", "Diagram"],
          ["image", "▧", "Image from File…"],
          ["image-url", "⌁", "Image from URL…"],
          ["link", "↗", "Link"],
          ["math", "∑", "Math block"],
          ["divider", "—", "Divider"],
        ]
      ) +
      insertMenuSection(
        "Callouts",
        [
          ["alert-note", "i", "Note"],
          ["alert-tip", "✦", "Tip"],
          ["alert-important", "!", "Important"],
          ["alert-warning", "△", "Warning"],
          ["alert-caution", "⚠", "Caution"],
        ]
      ) +
      insertMenuSection(
        "Advanced",
        [
          ["footnote", "¹", "Footnote"],
          ["frontmatter", "YML", "Frontmatter"],
          ["raw-markdown", "MD", "Markdown block"],
        ]
      ) +
      "</div>";
    document.body.appendChild(inserter);

    inserter.addEventListener("mousedown", (event) => {
      if (!event.target.closest(".editor-insert-menu textarea")) {
        event.preventDefault();
      }
    });
    inserter.querySelector(".editor-block-add").addEventListener("click", () => {
      const menu = inserter.querySelector(".editor-insert-menu");
      const shouldOpen = menu.hidden;
      menu.hidden = !shouldOpen;
      inserter
        .querySelector(".editor-block-add")
        .setAttribute("aria-expanded", shouldOpen ? "true" : "false");
      if (shouldOpen) positionBlockInserter(inserterTarget);
    });
    inserter.querySelector(".editor-insert-menu").addEventListener("click", (event) => {
      const item = event.target.closest("[data-insert-block]");
      if (!item) return;
      insertBlock(item.dataset.insertBlock);
    });
    return inserter;
  }

  function insertMenuSection(title, items) {
    return (
      '<div class="editor-insert-section">' +
      '<div class="editor-insert-section-title">' +
      title +
      "</div>" +
      items
        .map(
          (item) =>
            '<button type="button" role="menuitem" data-insert-block="' +
            item[0] +
            '">' +
            '<span class="editor-insert-icon">' +
            item[1] +
            "</span>" +
            "<span>" +
            item[2] +
            "</span>" +
            "</button>"
        )
        .join("") +
      "</div>"
    );
  }

  function updateBlockInserter() {
    if (imagePickerPending) {
      hideBlockInserter(false);
      return;
    }
    if (
      !editable ||
      document.querySelector(".editor-object-source, .editor-markdown-composer")
    ) {
      hideBlockInserter(!document.querySelector(".editor-markdown-composer"));
      return;
    }

    const openMenu = blockInserter.querySelector(".editor-insert-menu");
    if (
      !openMenu.hidden &&
      inserterTarget &&
      document.contains(inserterTarget)
    ) {
      blockInserter.hidden = false;
      positionBlockInserter(inserterTarget);
      return;
    }

    const selection = window.getSelection();
    const target = emptyLineForSelection(selection);
    if (!target) {
      hideBlockInserter();
      return;
    }

    if (inserterTarget && inserterTarget !== target) {
      closeInsertMenu();
    }
    clearObjectSelection();
    inserterTarget = target;
    blockInserter.hidden = false;
    positionBlockInserter(target);
  }

  function emptyLineForSelection(selection) {
    if (
      !selectionInsideArticle(selection) ||
      !selection.isCollapsed ||
      !selection.anchorNode
    ) {
      return null;
    }

    const anchor =
      selection.anchorNode.nodeType === Node.ELEMENT_NODE
        ? selection.anchorNode
        : selection.anchorNode.parentElement;
    if (!anchor || anchor.closest("[contenteditable='false'], pre, table, .footnotes")) {
      return null;
    }

    const block = anchor.closest("p, div, h1, h2, h3, h4, h5, h6, blockquote");
    if (!block || block.parentElement !== article) return null;
    if (
      block.querySelector(
        "img, table, hr, input, .code-card, .diagram-card, .katex, [data-editor-insert-markdown]"
      )
    ) {
      return null;
    }

    const text = (block.textContent || "").replace(/[\s\u200b\ufeff]/g, "");
    return text ? null : block;
  }

  function positionBlockInserter(target) {
    if (!target || !document.contains(target) || blockInserter.hidden) return;
    const rect = target.getBoundingClientRect();
    const buttonSize = 28;
    const left = Math.max(8, rect.left - buttonSize - 8);
    const top = Math.max(
      8,
      Math.min(
        window.innerHeight - buttonSize - 8,
        rect.top + Math.max(0, (rect.height - buttonSize) / 2)
      )
    );
    blockInserter.style.left = Math.round(left) + "px";
    blockInserter.style.top = Math.round(top) + "px";

    const menu = blockInserter.querySelector(".editor-insert-menu");
    if (!menu.hidden) {
      menu.style.maxHeight = Math.max(220, window.innerHeight - 32) + "px";
      menu.classList.toggle(
        "opens-upward",
        top + Math.min(520, menu.scrollHeight) > window.innerHeight - 16
      );
    }
  }

  function hideBlockInserter(resetTarget) {
    blockInserter.hidden = true;
    closeInsertMenu();
    if (resetTarget !== false) inserterTarget = null;
  }

  function closeInsertMenu() {
    const menu = blockInserter.querySelector(".editor-insert-menu");
    menu.hidden = true;
    blockInserter
      .querySelector(".editor-block-add")
      .setAttribute("aria-expanded", "false");
  }

  function insertBlock(action) {
    const target =
      inserterTarget && document.contains(inserterTarget)
        ? inserterTarget
        : emptyLineForSelection(window.getSelection());
    if (!target) return null;

    if (action === "text") {
      const paragraph = document.createElement("p");
      paragraph.appendChild(document.createElement("br"));
      target.replaceWith(paragraph);
      inserterTarget = paragraph;
      closeInsertMenu();
      placeCaretAtStart(paragraph);
      updateBlockInserter();
      return currentMarkdown;
    }
    if (action === "raw-markdown") {
      openMarkdownComposer(target);
      return null;
    }
    if (action === "frontmatter") {
      const markdown = flushEditor();
      if (/^---\n/.test(markdown)) {
        window.alert("This document already has frontmatter.");
        return null;
      }
      const next =
        "---\ntitle: \"Document title\"\ndate: " +
        new Date().toISOString().slice(0, 10) +
        "\nstatus: draft\n---\n\n" +
        markdown.replace(/^\s+/, "");
      hideBlockInserter();
      if (window.previewmdRefreshEditor) window.previewmdRefreshEditor(next);
      return next;
    }
    if (action === "image") {
      return requestNativeImage(target);
    }

    const snippet = markdownSnippetFor(action);
    if (snippet === null) {
      updateBlockInserter();
      return null;
    }
    return replaceEmptyLineWithMarkdown(target, snippet);
  }

  function markdownSnippetFor(action) {
    const headingMatch = action.match(/^heading-([1-6])$/);
    if (headingMatch) {
      return "#".repeat(Number(headingMatch[1])) + " Heading " + headingMatch[1];
    }

    const snippets = {
      quote: "> Quote",
      "bullet-list": "- List item",
      "numbered-list": "1. List item",
      "task-list": "- [ ] Task",
      table:
        "| Column 1 | Column 2 | Column 3 |\n" +
        "| --- | --- | --- |\n" +
        "|  |  |  |",
      code: "```\n\n```",
      mermaid: "```mermaid\nflowchart LR\n  A[Start] --> B[End]\n```",
      divider: "---",
      "alert-note": "> [!NOTE]\n> Note",
      "alert-tip": "> [!TIP]\n> Tip",
      "alert-important": "> [!IMPORTANT]\n> Important",
      "alert-warning": "> [!WARNING]\n> Warning",
      "alert-caution": "> [!CAUTION]\n> Caution",
    };
    if (Object.prototype.hasOwnProperty.call(snippets, action)) {
      return snippets[action];
    }

    if (action === "image-url") {
      const source = window.prompt("Image address", "https://");
      if (source === null) return null;
      const alt = window.prompt("Alternative text", "Image");
      if (alt === null) return null;
      const title = window.prompt("Image title (optional)", "");
      if (title === null) return null;
      return (
        "![" +
        alt.replace(/]/g, "\\]") +
        "](" +
        source.trim() +
        (title.trim() ? ' "' + title.trim().replace(/"/g, '\\"') + '"' : "") +
        ")"
      );
    }

    if (action === "link") {
      const label = window.prompt("Link text", "Link");
      if (label === null) return null;
      const href = window.prompt("Link address", "https://");
      if (href === null) return null;
      return "[" + label.replace(/]/g, "\\]") + "](" + href.trim() + ")";
    }

    if (action === "math") {
      const source = window.prompt("Math expression", "x^2");
      return source === null ? null : "$$\n" + source + "\n$$";
    }

    if (action === "footnote") {
      const requestedLabel = window.prompt("Footnote label", "note");
      if (requestedLabel === null) return null;
      const label =
        requestedLabel.trim().replace(/[\]\s]+/g, "-").replace(/^-+|-+$/g, "") ||
        "note";
      const body = window.prompt("Footnote text", "Footnote text.");
      if (body === null) return null;
      return "Reference[^" + label + "]\n\n[^" + label + "]: " + body;
    }

    return null;
  }

  function requestNativeImage(target) {
    const handler =
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.pickImage;
    if (!handler) {
      const snippet = markdownSnippetFor("image-url");
      return snippet === null
        ? null
        : replaceEmptyLineWithMarkdown(target, snippet);
    }

    imagePickerPending = true;
    inserterTarget = target;
    hideBlockInserter(false);
    handler.postMessage({});
    return null;
  }

  function insertPickedImage(source, alt) {
    imagePickerPending = false;
    const target = inserterTarget;
    if (!target || !document.contains(target)) {
      inserterTarget = null;
      return null;
    }
    const safeAlt = (alt || "Image").replace(/]/g, "\\]");
    return replaceEmptyLineWithMarkdown(
      target,
      "![" + safeAlt + "](" + source + ")"
    );
  }

  function cancelPickedImage() {
    imagePickerPending = false;
    const target = inserterTarget;
    if (target && document.contains(target)) {
      placeCaretAtStart(target);
      updateBlockInserter();
    } else {
      hideBlockInserter();
    }
  }

  function replaceEmptyLineWithMarkdown(target, snippet) {
    const placeholder = document.createElement("div");
    placeholder.dataset.editorInsertMarkdown = snippet;
    placeholder.setAttribute("contenteditable", "false");
    placeholder.setAttribute("aria-label", "Inserted Markdown block");
    target.replaceWith(placeholder);
    hideBlockInserter();
    scheduleChange(false, true);
    const markdown = flushEditor();
    if (window.previewmdRefreshEditor) {
      window.previewmdRefreshEditor(markdown);
    }
    return markdown;
  }

  function openMarkdownComposer(target) {
    if (document.querySelector(".editor-markdown-composer")) return;
    closeInsertMenu();
    hideBlockInserter(false);

    const composer = document.createElement("div");
    composer.className = "editor-markdown-composer";
    composer.setAttribute("contenteditable", "false");
    composer.setAttribute("role", "dialog");
    composer.setAttribute("aria-label", "Insert Markdown block");
    composer.innerHTML =
      '<div class="editor-markdown-composer-card">' +
      '<div class="editor-markdown-composer-header">' +
      "<strong>Insert Markdown</strong>" +
      "<span></span>" +
      '<button type="button" data-composer-cancel>Cancel</button>' +
      '<button type="button" data-composer-apply class="is-primary">Insert</button>' +
      "</div>" +
      '<textarea aria-label="Markdown source" spellcheck="false" placeholder="Paste or write any Markdown block…"></textarea>' +
      '<div class="editor-markdown-composer-hint">⌘↵ to insert · Esc to cancel</div>' +
      "</div>";
    document.body.appendChild(composer);
    const textarea = composer.querySelector("textarea");
    textarea.focus();

    const close = () => {
      composer.remove();
      inserterTarget = target;
      placeCaretAtStart(target);
      updateBlockInserter();
    };
    const apply = () => {
      const snippet = textarea.value.trim();
      composer.remove();
      if (!snippet) {
        inserterTarget = target;
        placeCaretAtStart(target);
        updateBlockInserter();
        return;
      }
      replaceEmptyLineWithMarkdown(target, snippet);
    };
    composer
      .querySelector("[data-composer-cancel]")
      .addEventListener("click", close);
    composer
      .querySelector("[data-composer-apply]")
      .addEventListener("click", apply);
    textarea.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault();
        apply();
      } else if (event.key === "Escape") {
        event.preventDefault();
        close();
      }
    });
  }

  function placeCaretAtStart(node) {
    placeCaretAtEdge(node, false);
  }

  function placeCaretAtEdge(node, atEnd) {
    clearObjectSelection();
    article.focus();
    const selection = window.getSelection();
    const range = document.createRange();
    const textNode = editableEdgeTextNode(node, atEnd);
    if (textNode) {
      const offset = atEnd ? textNode.nodeValue.length : 0;
      range.setStart(textNode, offset);
      range.collapse(true);
    } else {
      range.selectNodeContents(node);
      range.collapse(atEnd);
    }
    selection.removeAllRanges();
    selection.addRange(range);
    node.scrollIntoView({ block: "nearest" });
  }

  function editableEdgeTextNode(node, atEnd) {
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, {
      acceptNode(textNode) {
        const parent = textNode.parentElement;
        if (
          !parent ||
          parent.closest(
            "[contenteditable='false'], .heading-anchor, .copy-code, .alert-title, .footnote-backref"
          )
        ) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    let result = null;
    while (walker.nextNode()) {
      result = walker.currentNode;
      if (!atEnd) break;
    }
    return result;
  }

  function topLevelBlock(node) {
    let element =
      node && node.nodeType === Node.ELEMENT_NODE
        ? node
        : node && node.parentElement;
    if (!element || element === article || !article.contains(element)) return null;
    while (element.parentElement && element.parentElement !== article) {
      element = element.parentElement;
    }
    return element.parentElement === article ? element : null;
  }

  function adjacentTopLevelBlock(block, forward) {
    const blocks = Array.from(article.children);
    const index = blocks.indexOf(block);
    if (index < 0) return null;
    return blocks[index + (forward ? 1 : -1)] || null;
  }

  function keyboardNavigationObject(node) {
    if (!node || !node.matches) return null;
    if (node.matches(".katex")) {
      return node.closest(".katex-display") || node;
    }
    return node.matches(keyboardObjectSelector) ? node : null;
  }

  function navigationObjectForBlock(block) {
    if (!block) return null;
    const direct = keyboardNavigationObject(block);
    if (direct) return direct;

    const candidate = block.querySelector(keyboardObjectSelector);
    if (!candidate) return null;
    const copy = block.cloneNode(true);
    copy.querySelectorAll(keyboardObjectSelector).forEach((node) => node.remove());
    copy.querySelectorAll("br").forEach((node) => node.remove());
    return (copy.textContent || "").trim()
      ? null
      : keyboardNavigationObject(candidate);
  }

  function transitionToBlock(block, forward) {
    if (!block) return;
    const object = navigationObjectForBlock(block);
    if (object) {
      selectObject(object);
      object.scrollIntoView({ block: "nearest" });
    } else {
      placeCaretAtEdge(block, !forward);
    }
  }

  function placeCaretBesideObject(object, after) {
    clearObjectSelection();
    article.focus();
    const selection = window.getSelection();
    const range = document.createRange();
    if (after) {
      range.setStartAfter(object);
    } else {
      range.setStartBefore(object);
    }
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
    object.scrollIntoView({ block: "nearest" });
  }

  function isObjectOnlyBlock(block) {
    return navigationObjectForBlock(block) !== null;
  }

  function selectionBlock(selection) {
    if (!selection || !selection.anchorNode) return null;
    if (selection.anchorNode !== article) {
      return topLevelBlock(selection.anchorNode);
    }
    const children = Array.from(article.children);
    const offset = Math.min(selection.anchorOffset, children.length - 1);
    return offset >= 0 ? children[offset] : null;
  }

  function isCaretAtDOMEdge(range, block, atEnd) {
    try {
      const remainder = document.createRange();
      remainder.selectNodeContents(block);
      if (atEnd) {
        remainder.setStart(range.endContainer, range.endOffset);
      } else {
        remainder.setEnd(range.startContainer, range.startOffset);
      }
      return !remainder.toString().replace(/[\s\u200b\ufeff]/g, "");
    } catch (_) {
      return false;
    }
  }

  function isCaretOnEdgeLine(selection, block, atEnd) {
    const range = selection.getRangeAt(0);
    if (isCaretAtDOMEdge(range, block, atEnd)) return true;

    const caretRect = usefulRangeRect(range);
    if (!caretRect) return false;
    const contents = document.createRange();
    contents.selectNodeContents(block);
    const rects = Array.from(contents.getClientRects()).filter(
      (rect) => rect.width || rect.height
    );
    if (!rects.length) return false;
    const firstTop = Math.min(...rects.map((rect) => rect.top));
    const lastBottom = Math.max(...rects.map((rect) => rect.bottom));
    const tolerance = Math.max(3, (caretRect.height || 16) * 0.65);
    return atEnd
      ? caretRect.bottom >= lastBottom - tolerance
      : caretRect.top <= firstTop + tolerance;
  }

  function textOffsetWithin(node, range) {
    try {
      const prefix = document.createRange();
      prefix.selectNodeContents(node);
      prefix.setEnd(range.startContainer, range.startOffset);
      return prefix.toString().length;
    } catch (_) {
      return 0;
    }
  }

  function placeCaretAtTextOffset(node, requestedOffset) {
    clearObjectSelection();
    article.focus();
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT, {
      acceptNode(textNode) {
        const parent = textNode.parentElement;
        return parent && !parent.closest("[contenteditable='false']")
          ? NodeFilter.FILTER_ACCEPT
          : NodeFilter.FILTER_REJECT;
      },
    });
    let remaining = Math.max(0, requestedOffset);
    let textNode = null;
    let offset = 0;
    while (walker.nextNode()) {
      textNode = walker.currentNode;
      if (remaining <= textNode.nodeValue.length) {
        offset = remaining;
        break;
      }
      remaining -= textNode.nodeValue.length;
      offset = textNode.nodeValue.length;
    }

    const selection = window.getSelection();
    const range = document.createRange();
    if (textNode) {
      range.setStart(textNode, Math.min(offset, textNode.nodeValue.length));
      range.collapse(true);
    } else {
      range.selectNodeContents(node);
      range.collapse(true);
    }
    selection.removeAllRanges();
    selection.addRange(range);
    node.scrollIntoView({ block: "nearest" });
  }

  function handleTableArrowNavigation(event, selection) {
    const anchor =
      selection.anchorNode.nodeType === Node.ELEMENT_NODE
        ? selection.anchorNode
        : selection.anchorNode.parentElement;
    const cell = anchor && anchor.closest("td, th");
    if (!cell) return false;

    const row = cell.parentElement;
    const table = cell.closest("table");
    if (!row || !table) return false;
    const rows = Array.from(table.rows);
    const rowIndex = rows.indexOf(row);
    const cellIndex = Array.from(row.cells).indexOf(cell);
    const forward = event.key === "ArrowDown" || event.key === "ArrowRight";
    const range = selection.getRangeAt(0);

    if (event.key === "ArrowUp" || event.key === "ArrowDown") {
      if (!isCaretOnEdgeLine(selection, cell, forward)) return false;
      const targetRow = rows[rowIndex + (forward ? 1 : -1)];
      event.preventDefault();
      if (!targetRow) {
        const tableBlock = topLevelBlock(table);
        transitionToBlock(
          adjacentTopLevelBlock(tableBlock, forward),
          forward
        );
        return true;
      }

      const targetCell =
        targetRow.cells[Math.min(cellIndex, targetRow.cells.length - 1)];
      if (!targetCell) return true;
      const offset = textOffsetWithin(cell, range);
      placeCaretAtTextOffset(targetCell, offset);
      selectObject(targetCell);
      return true;
    }

    if (
      (event.key === "ArrowLeft" || event.key === "ArrowRight") &&
      isCaretAtDOMEdge(range, cell, forward)
    ) {
      let targetRow = row;
      let targetCell = row.cells[cellIndex + (forward ? 1 : -1)];
      if (!targetCell) {
        targetRow = rows[rowIndex + (forward ? 1 : -1)];
        if (targetRow) {
          targetCell = forward
            ? targetRow.cells[0]
            : targetRow.cells[targetRow.cells.length - 1];
        }
      }
      if (!targetCell) return false;
      event.preventDefault();
      placeCaretAtEdge(targetCell, !forward);
      selectObject(targetCell);
      return true;
    }

    return false;
  }

  function listItemOwnTextNodes(item) {
    const nodes = [];
    const walker = document.createTreeWalker(item, NodeFilter.SHOW_TEXT, {
      acceptNode(textNode) {
        const parent = textNode.parentElement;
        if (
          !parent ||
          parent.closest("li") !== item ||
          parent.closest("[contenteditable='false']")
        ) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function listItemTextLength(item) {
    return listItemOwnTextNodes(item).reduce(
      (length, node) => length + node.nodeValue.length,
      0
    );
  }

  function listItemCaretOffset(item, range) {
    try {
      const prefix = document.createRange();
      prefix.selectNodeContents(item);
      prefix.setEnd(range.startContainer, range.startOffset);
      const fragment = prefix.cloneContents();
      fragment
        .querySelectorAll("ul, ol, [contenteditable='false']")
        .forEach((node) => node.remove());
      return (fragment.textContent || "").length;
    } catch (_) {
      return 0;
    }
  }

  function placeCaretInListItem(item, requestedOffset) {
    clearObjectSelection();
    article.focus();
    const textNodes = listItemOwnTextNodes(item);
    let remaining = Math.max(0, requestedOffset);
    let target = textNodes[0] || null;
    let offset = 0;
    for (const textNode of textNodes) {
      target = textNode;
      if (remaining <= textNode.nodeValue.length) {
        offset = remaining;
        break;
      }
      remaining -= textNode.nodeValue.length;
      offset = textNode.nodeValue.length;
    }

    const selection = window.getSelection();
    const range = document.createRange();
    if (target) {
      range.setStart(target, Math.min(offset, target.nodeValue.length));
      range.collapse(true);
    } else {
      const content = item.querySelector(":scope > p") || item;
      range.selectNodeContents(content);
      range.collapse(true);
    }
    selection.removeAllRanges();
    selection.addRange(range);
    item.scrollIntoView({ block: "nearest" });
  }

  function isCaretOnListItemEdge(selection, item, atEnd) {
    const range = selection.getRangeAt(0);
    const offset = listItemCaretOffset(item, range);
    const length = listItemTextLength(item);
    if (atEnd ? offset >= length : offset <= 0) return true;

    const caretRect = usefulRangeRect(range);
    if (!caretRect) return false;
    const rects = [];
    listItemOwnTextNodes(item).forEach((textNode) => {
      const textRange = document.createRange();
      textRange.selectNodeContents(textNode);
      rects.push(
        ...Array.from(textRange.getClientRects()).filter(
          (rect) => rect.width || rect.height
        )
      );
    });
    if (!rects.length) return false;
    const firstTop = Math.min(...rects.map((rect) => rect.top));
    const lastBottom = Math.max(...rects.map((rect) => rect.bottom));
    const tolerance = Math.max(3, (caretRect.height || 16) * 0.65);
    return atEnd
      ? caretRect.bottom >= lastBottom - tolerance
      : caretRect.top <= firstTop + tolerance;
  }

  function listEdgeItem(block, forward) {
    if (!block || !block.matches("ul, ol")) return null;
    const items = Array.from(block.querySelectorAll("li"));
    return forward ? items[0] || null : items[items.length - 1] || null;
  }

  function handleListArrowNavigation(event, selection) {
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return false;
    const anchor =
      selection.anchorNode.nodeType === Node.ELEMENT_NODE
        ? selection.anchorNode
        : selection.anchorNode.parentElement;
    const focusedCheckbox =
      event.target &&
      event.target.matches &&
      event.target.matches('input[type="checkbox"]');
    const item =
      (focusedCheckbox && event.target.closest("li")) ||
      (anchor && anchor.closest("li"));
    if (!item) return false;

    const forward = event.key === "ArrowDown";
    if (
      !focusedCheckbox &&
      !isCaretOnListItemEdge(selection, item, forward)
    ) {
      return false;
    }

    const listBlock = topLevelBlock(item);
    if (!listBlock || !listBlock.matches("ul, ol")) return false;
    const items = Array.from(listBlock.querySelectorAll("li"));
    const index = items.indexOf(item);
    if (index < 0) return false;

    const offset = focusedCheckbox
      ? 0
      : listItemCaretOffset(item, selection.getRangeAt(0));
    let targetItem = items[index + (forward ? 1 : -1)] || null;
    let adjacent = null;
    if (!targetItem) {
      adjacent = adjacentTopLevelBlock(listBlock, forward);
      targetItem = listEdgeItem(adjacent, forward);
    }

    event.preventDefault();
    if (targetItem) {
      placeCaretInListItem(targetItem, offset);
    } else if (adjacent) {
      const object = navigationObjectForBlock(adjacent);
      if (object) {
        selectObject(object);
        object.scrollIntoView({ block: "nearest" });
      } else {
        placeCaretAtTextOffset(adjacent, offset);
      }
    }
    return true;
  }

  function handleArrowNavigation(event) {
    if (
      event.shiftKey ||
      event.metaKey ||
      event.ctrlKey ||
      event.altKey ||
      !["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.key)
    ) {
      return false;
    }

    const activeObject = keyboardNavigationObject(selectedObject);
    if (activeObject) {
      event.preventDefault();
      const forward = event.key === "ArrowDown" || event.key === "ArrowRight";
      const block = topLevelBlock(activeObject);
      if (
        (event.key === "ArrowLeft" || event.key === "ArrowRight") &&
        block &&
        !isObjectOnlyBlock(block)
      ) {
        placeCaretBesideObject(activeObject, forward);
        return true;
      }
      transitionToBlock(adjacentTopLevelBlock(block, forward), forward);
      return true;
    }

    const selection = window.getSelection();
    if (
      !selectionInsideArticle(selection) ||
      !selection.isCollapsed ||
      !selection.rangeCount
    ) {
      return false;
    }
    if (handleListArrowNavigation(event, selection)) return true;
    if (handleTableArrowNavigation(event, selection)) return true;
    const block = selectionBlock(selection);
    if (!block) return false;

    const forward = event.key === "ArrowDown" || event.key === "ArrowRight";
    const vertical = event.key === "ArrowUp" || event.key === "ArrowDown";
    const range = selection.getRangeAt(0);
    const atEdge = vertical
      ? isCaretOnEdgeLine(selection, block, forward)
      : isCaretAtDOMEdge(range, block, forward);
    if (!atEdge) return false;

    const adjacent = adjacentTopLevelBlock(block, forward);
    const listItem = vertical ? listEdgeItem(adjacent, forward) : null;
    if (listItem) {
      event.preventDefault();
      placeCaretInListItem(listItem, textOffsetWithin(block, range));
      return true;
    }
    const object = navigationObjectForBlock(adjacent);
    if (!object) return false;
    event.preventDefault();
    selectObject(object);
    object.scrollIntoView({ block: "nearest" });
    return true;
  }

  function setEditable(value) {
    editable = value === true;
    article.contentEditable = editable ? "true" : "false";
    article.spellcheck = editable;
    article.classList.toggle("is-editable", editable);
    document.documentElement.dataset.editable = editable ? "true" : "false";

    article
      .querySelectorAll(".code-toolbar, .diagram-label, .copy-code, .table-expand")
      .forEach((node) => {
        node.setAttribute("contenteditable", "false");
      });
    article
      .querySelectorAll(
        ".frontmatter-card, .code-card, .diagram-card, img, .katex, hr, .footnote-backref"
      )
      .forEach((node) => node.setAttribute("contenteditable", "false"));
    article.querySelectorAll('input[type="checkbox"]').forEach((checkbox) => {
      checkbox.disabled = !editable;
    });

    if (!editable) {
      imagePickerPending = false;
      if (window.PreviewMDDiagramEditor) window.PreviewMDDiagramEditor.close();
      hideToolbars();
      clearObjectSelection();
      const composer = document.querySelector(".editor-markdown-composer");
      if (composer) composer.remove();
    }
  }

  function editorDidRender(markdown, shouldEdit) {
    currentMarkdown = markdown || "";
    domChanged = false;
    if (shouldEdit === true && !article.firstChild) {
      article.innerHTML = "<p><br></p>";
    }
    savedRange = null;
    inserterTarget = null;
    imagePickerPending = false;
    clearSplitCounterpartIndicator();
    clearObjectSelection();
    hideBlockInserter();
    setEditable(shouldEdit === true);
    window.requestAnimationFrame(() => {
      postSplitSyncMessage({ kind: "ready" });
    });
  }

  function scheduleChange(immediate, historyBoundary) {
    if (!editable) return;
    domChanged = true;
    pendingHistoryBoundary = pendingHistoryBoundary || historyBoundary === true;
    window.clearTimeout(emitTimer);
    if (immediate) {
      emitChange();
    } else {
      emitTimer = window.setTimeout(emitChange, 0);
    }
  }

  function emitChange() {
    window.clearTimeout(emitTimer);
    emitTimer = 0;
    if (!domChanged) return currentMarkdown;
    const markdown = serializeDocument();
    if (markdown === currentMarkdown) {
      pendingHistoryBoundary = false;
      domChanged = false;
      return markdown;
    }
    const historyBoundary = pendingHistoryBoundary;
    pendingHistoryBoundary = false;
    domChanged = false;
    currentMarkdown = markdown;
    refreshSplitSourcePositions();
    if (
      window.webkit &&
      window.webkit.messageHandlers &&
      window.webkit.messageHandlers.editorChange
    ) {
      window.webkit.messageHandlers.editorChange.postMessage({
        markdown: markdown,
        historyBoundary: historyBoundary,
      });
    }
    return markdown;
  }

  function flushEditor() {
    window.clearTimeout(emitTimer);
    emitTimer = 0;
    if (!domChanged) return currentMarkdown;
    const markdown = serializeDocument();
    if (markdown !== currentMarkdown) {
      const historyBoundary = pendingHistoryBoundary;
      pendingHistoryBoundary = false;
      currentMarkdown = markdown;
      refreshSplitSourcePositions();
      if (
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.editorChange
      ) {
        window.webkit.messageHandlers.editorChange.postMessage({
          markdown: markdown,
          historyBoundary: historyBoundary,
        });
      }
    } else {
      pendingHistoryBoundary = false;
    }
    domChanged = false;
    return markdown;
  }

  function selectionInsideArticle(selection) {
    if (!selection || selection.rangeCount === 0) return false;
    const range = selection.getRangeAt(0);
    return article.contains(range.commonAncestorContainer);
  }

  function updateSelectionToolbar() {
    if (!editable || document.querySelector(".editor-object-source")) {
      textToolbar.hidden = true;
      return;
    }

    const selection = window.getSelection();
    if (!selectionInsideArticle(selection) || selection.isCollapsed) {
      textToolbar.hidden = true;
      return;
    }

    const range = selection.getRangeAt(0);
    const rect = usefulRangeRect(range);
    if (!rect || (!rect.width && !rect.height)) {
      textToolbar.hidden = true;
      return;
    }

    savedRange = range.cloneRange();
    clearObjectSelection();
    textToolbar.hidden = false;
    syncToolbarState(selection.anchorNode);
    positionToolbar(textToolbar, rect);
  }

  function usefulRangeRect(range) {
    const rect = range.getBoundingClientRect();
    if (rect.width || rect.height) return rect;
    const rects = range.getClientRects();
    return rects.length ? rects[0] : null;
  }

  function syncToolbarState(anchorNode) {
    const element =
      anchorNode && anchorNode.nodeType === Node.ELEMENT_NODE
        ? anchorNode
        : anchorNode && anchorNode.parentElement;
    const block = element && element.closest("h1, h2, h3, h4, h5, h6, blockquote, pre, p");
    const select = textToolbar.querySelector("[data-editor-block]");
    if (block && Array.from(select.options).some((option) => option.value === block.tagName.toLowerCase())) {
      select.value = block.tagName.toLowerCase();
    } else {
      select.value = "p";
    }

    textToolbar.querySelectorAll("[data-editor-command]").forEach((button) => {
      const command = button.dataset.editorCommand;
      if (!["bold", "italic", "strikeThrough"].includes(command)) return;
      button.classList.toggle("is-active", document.queryCommandState(command));
    });
  }

  function restoreSelection() {
    if (!savedRange) return;
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(savedRange);
  }

  function performTextAction(action) {
    if (action === "inline-code") {
      wrapSelectionWithCode();
    } else if (action === "link") {
      const selection = window.getSelection();
      const existing =
        selection && selection.anchorNode
          ? (selection.anchorNode.nodeType === Node.ELEMENT_NODE
              ? selection.anchorNode
              : selection.anchorNode.parentElement
            ).closest("a")
          : null;
      const initial = existing ? existing.getAttribute("href") || "" : "";
      const href = window.prompt("Link address", initial || "https://");
      if (href === null) return;
      if (!href.trim()) {
        document.execCommand("unlink", false, null);
      } else {
        document.execCommand("createLink", false, href.trim());
      }
      scheduleChange(true, true);
    } else if (action === "task-list") {
      document.execCommand("insertUnorderedList", false, null);
      const selection = window.getSelection();
      const anchor =
        selection && selection.anchorNode.nodeType === Node.TEXT_NODE
          ? selection.anchorNode.parentElement
          : selection && selection.anchorNode;
      const item = anchor && anchor.closest && anchor.closest("li");
      if (item && !item.querySelector(':scope > input[type="checkbox"], :scope > p > input[type="checkbox"]')) {
        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.setAttribute("aria-label", "Not completed");
        const target = item.querySelector(":scope > p") || item;
        target.insertBefore(checkbox, target.firstChild);
        item.classList.add("task-list-item");
        item.parentElement && item.parentElement.classList.add("task-list");
      }
      scheduleChange(true, true);
    }
    updateSelectionToolbar();
  }

  function wrapSelectionWithCode() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return;
    const range = selection.getRangeAt(0);
    const existing =
      range.commonAncestorContainer.nodeType === Node.ELEMENT_NODE
        ? range.commonAncestorContainer.closest && range.commonAncestorContainer.closest("code")
        : range.commonAncestorContainer.parentElement.closest("code");

    if (existing && !existing.closest("pre")) {
      const parent = existing.parentNode;
      while (existing.firstChild) parent.insertBefore(existing.firstChild, existing);
      parent.removeChild(existing);
    } else {
      const code = document.createElement("code");
      try {
        range.surroundContents(code);
      } catch (_) {
        code.appendChild(range.extractContents());
        range.insertNode(code);
      }
      selection.removeAllRanges();
      const nextRange = document.createRange();
      nextRange.selectNodeContents(code);
      selection.addRange(nextRange);
      savedRange = nextRange.cloneRange();
    }
    scheduleChange(true, true);
  }

  function convertSelectionToCodeBlock() {
    document.execCommand("formatBlock", false, "pre");
    const selection = window.getSelection();
    const anchor =
      selection && selection.anchorNode && selection.anchorNode.nodeType === Node.TEXT_NODE
        ? selection.anchorNode.parentElement
        : selection && selection.anchorNode;
    const pre = anchor && anchor.closest && anchor.closest("pre");
    if (!pre || pre.closest(".code-card")) return;

    const card = document.createElement("div");
    card.className = "code-card";
    card.setAttribute("contenteditable", "false");
    const toolbar = document.createElement("div");
    toolbar.className = "code-toolbar";
    toolbar.setAttribute("contenteditable", "false");
    toolbar.innerHTML = "<span>code</span>";
    const codePre = document.createElement("pre");
    const code = document.createElement("code");
    code.className = "hljs";
    code.textContent = pre.textContent;
    codePre.appendChild(code);
    card.append(toolbar, codePre);
    pre.replaceWith(card);
    selectObject(card);
  }

  function selectObject(node) {
    if (!editable || !node) return;
    clearObjectSelection();
    selectedObject = node;
    selectedObject.classList.add("editor-selected-object");
    textToolbar.hidden = true;
    if (keyboardNavigationObject(node)) {
      article.focus({ preventScroll: true });
    }

    const type = objectType(node);
    objectToolbar.querySelector(".editor-object-label").textContent = objectLabel(type);
    objectToolbar.querySelectorAll("[data-object-action]").forEach((button) => {
      const action = button.dataset.objectAction;
      const tableAction = [
        "add-row",
        "remove-row",
        "add-column",
        "remove-column",
        "align-left",
        "align-center",
        "align-right",
      ].includes(action);
      button.hidden = tableAction && type !== "table";
      if (action === "edit") {
        button.hidden = ![
          "frontmatter",
          "image",
          "code",
          "diagram",
          "math",
          "link",
        ].includes(type);
      }
    });

    objectToolbar.hidden = false;
    positionToolbar(objectToolbar, node.getBoundingClientRect());
  }

  function clearObjectSelection() {
    if (selectedObject) selectedObject.classList.remove("editor-selected-object");
    selectedObject = null;
    objectToolbar.hidden = true;
  }

  function objectType(node) {
    if (!node) return "object";
    if (node.matches(".frontmatter-card")) return "frontmatter";
    if (node.matches("td, th, .table-scroll")) return "table";
    if (node.matches("img")) return "image";
    if (node.matches(".code-card")) return "code";
    if (node.matches(".diagram-card")) return "diagram";
    if (node.matches(".katex, .katex-display")) return "math";
    if (node.matches("a")) return "link";
    if (node.matches("hr")) return "divider";
    return "object";
  }

  function objectLabel(type) {
    return {
      frontmatter: "Frontmatter",
      table: "Table",
      image: "Image",
      code: "Code",
      diagram: "Diagram",
      math: "Math",
      link: "Link",
      divider: "Divider",
    }[type] || "Object";
  }

  function positionToolbar(toolbar, rect) {
    toolbar.style.visibility = "hidden";
    toolbar.hidden = false;
    const width = toolbar.offsetWidth;
    const height = toolbar.offsetHeight;
    const margin = 10;
    const left = Math.max(margin, Math.min(window.innerWidth - width - margin, rect.left + rect.width / 2 - width / 2));
    let top = rect.top - height - 10;
    if (top < margin) top = Math.min(window.innerHeight - height - margin, rect.bottom + 10);
    toolbar.style.left = Math.round(left) + "px";
    toolbar.style.top = Math.round(top) + "px";
    toolbar.style.visibility = "visible";
  }

  function performObjectAction(action) {
    if (!selectedObject) return;
    const type = objectType(selectedObject);
    if (action === "delete") {
      const target =
        type === "table"
          ? selectedObject.closest(".table-scroll") || selectedObject
          : selectedObject;
      target.remove();
      clearObjectSelection();
      scheduleChange(true, true);
      return;
    }

    if (action === "edit") {
      editObject(selectedObject, type);
      return;
    }

    if (type === "table") {
      editTable(selectedObject, action);
    }
  }

  function editObject(node, type) {
    if (type === "image") {
      const currentSource = window.previewmdOriginalImageSource
        ? window.previewmdOriginalImageSource(node)
        : node.getAttribute("src") || "";
      const source = window.prompt("Image path or address", currentSource);
      if (source === null) return;
      const alt = window.prompt("Alternative text", node.getAttribute("alt") || "");
      if (alt === null) return;
      const title = window.prompt("Image title (optional)", node.getAttribute("title") || "");
      if (title === null) return;
      if (window.previewmdSetImageSource) {
        window.previewmdSetImageSource(node, source.trim());
      } else {
        node.setAttribute("src", source.trim());
      }
      node.setAttribute("alt", alt);
      if (title.trim()) node.setAttribute("title", title.trim());
      else node.removeAttribute("title");
      scheduleChange(true, true);
      selectObject(node);
    } else if (type === "link") {
      const href = window.prompt("Link address", node.getAttribute("href") || "");
      if (href === null) return;
      if (href.trim()) node.setAttribute("href", href.trim());
      else {
        const parent = node.parentNode;
        while (node.firstChild) parent.insertBefore(node.firstChild, node);
        node.remove();
      }
      scheduleChange(true, true);
    } else if (type === "diagram" && window.PreviewMDDiagramEditor) {
      openDiagramEditor(node);
    } else if (type === "code" || type === "diagram" || type === "frontmatter") {
      openObjectSourceEditor(node, type);
    } else if (type === "math") {
      const katex = node.matches(".katex") ? node : node.querySelector(".katex");
      const annotation = katex && katex.querySelector('annotation[encoding="application/x-tex"]');
      const source = window.prompt("Math expression", annotation ? annotation.textContent : "");
      if (source === null) return;
      if (annotation) annotation.textContent = source;
      node.dataset.mathSource = source;
      scheduleChange(true, true);
      refreshFromCurrentDOM();
    }
  }

  function openDiagramEditor(node) {
    const mermaid = node.querySelector(".mermaid");
    if (!mermaid) return;
    const source = mermaid.dataset.source || mermaid.textContent;
    objectToolbar.hidden = true;
    window.PreviewMDDiagramEditor.open({
      card: node,
      source: source,
      onCancel: function () {
        if (node.isConnected) selectObject(node);
      },
      onApply: function (nextSource) {
        mermaid.dataset.source = nextSource;
        mermaid.textContent = nextSource;
        mermaid.classList.remove("rendered", "diagram-error");
        scheduleChange(true, true);
        refreshFromCurrentDOM();
      },
    });
  }

  function openObjectSourceEditor(node, type) {
    const existing = node.querySelector(".editor-object-source");
    if (existing) return;
    const source =
      type === "frontmatter"
        ? decodeURIComponent(node.dataset.frontmatterSource || "")
        : type === "diagram"
        ? node.querySelector(".mermaid").dataset.source || node.querySelector(".mermaid").textContent
        : node.querySelector("code").textContent;
    const language =
      type === "code"
        ? ((node.querySelector("code").className.match(/language-([^\s]+)/) || [])[1] || "")
        : "mermaid";

    const panel = document.createElement("div");
    panel.className = "editor-object-source";
    panel.setAttribute("contenteditable", "false");
    panel.innerHTML =
      '<div class="editor-object-source-header">' +
      '<input type="text" class="editor-object-language" aria-label="Language" spellcheck="false">' +
      '<span class="editor-object-source-spacer"></span>' +
      '<button type="button" data-source-cancel>Cancel</button>' +
      '<button type="button" data-source-apply class="is-primary">Apply</button>' +
      "</div>" +
      '<textarea aria-label="Source" spellcheck="false"></textarea>';
    panel.querySelector(".editor-object-language").value = language;
    panel.querySelector(".editor-object-language").hidden = type !== "code";
    panel.querySelector("textarea").value = source;
    node.appendChild(panel);
    objectToolbar.hidden = true;
    panel.querySelector("textarea").focus();

    panel.querySelector("[data-source-cancel]").addEventListener("click", () => {
      panel.remove();
      selectObject(node);
    });
    panel.querySelector("[data-source-apply]").addEventListener("click", () => {
      const nextSource = panel.querySelector("textarea").value;
      if (type === "frontmatter") {
        let normalized = nextSource.trim();
        if (!normalized.startsWith("---")) normalized = "---\n" + normalized;
        if (!normalized.endsWith("---")) normalized += "\n---";
        node.dataset.frontmatterSource = encodeURIComponent(normalized);
      } else if (type === "diagram") {
        const mermaid = node.querySelector(".mermaid");
        mermaid.dataset.source = nextSource;
        mermaid.textContent = nextSource;
        mermaid.classList.remove("rendered", "diagram-error");
      } else {
        const code = node.querySelector("code");
        const nextLanguage = panel.querySelector(".editor-object-language").value.trim().toLowerCase();
        code.textContent = nextSource;
        code.className = "hljs" + (nextLanguage ? " language-" + nextLanguage : "");
        const label = node.querySelector(".code-toolbar > span");
        if (label) label.textContent = nextLanguage || "code";
      }
      panel.remove();
      scheduleChange(true, true);
      refreshFromCurrentDOM();
    });
    panel.querySelector("textarea").addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault();
        panel.querySelector("[data-source-apply]").click();
      } else if (event.key === "Escape") {
        event.preventDefault();
        panel.querySelector("[data-source-cancel]").click();
      }
    });
  }

  function refreshFromCurrentDOM() {
    const markdown = flushEditor();
    if (window.previewmdRefreshEditor) {
      window.previewmdRefreshEditor(markdown);
    }
  }

  function editTable(node, action) {
    const table = node.closest("table") || node.querySelector("table");
    if (!table) return;
    const cell = node.closest("td, th") || table.querySelector("td, th");
    const row = cell && cell.closest("tr");
    const cellIndex = cell ? cell.cellIndex : 0;

    if (action.startsWith("align-")) {
      const alignment = action.slice("align-".length);
      Array.from(table.rows).forEach((tableRow) => {
        if (tableRow.cells[cellIndex]) tableRow.cells[cellIndex].style.textAlign = alignment;
      });
    } else if (action === "add-row") {
      const reference = row || table.rows[table.rows.length - 1];
      const next = reference.cloneNode(true);
      next.querySelectorAll("td, th").forEach((item) => {
        item.innerHTML = "<br>";
      });
      reference.parentNode.insertBefore(next, reference.nextSibling);
    } else if (action === "remove-row") {
      if (row && table.rows.length > 2) row.remove();
    } else if (action === "add-column") {
      Array.from(table.rows).forEach((tableRow) => {
        const reference = tableRow.cells[Math.min(cellIndex, tableRow.cells.length - 1)];
        const next = reference.cloneNode(false);
        next.innerHTML = "<br>";
        reference.parentNode.insertBefore(next, reference.nextSibling);
      });
    } else if (action === "remove-column") {
      if (table.rows[0] && table.rows[0].cells.length > 1) {
        Array.from(table.rows).forEach((tableRow) => {
          if (tableRow.cells[cellIndex]) tableRow.cells[cellIndex].remove();
        });
      }
    }
    if (window.previewmdRefreshTableLayout) {
      window.previewmdRefreshTableLayout();
    }
    scheduleChange(true, true);
    selectObject(cell && document.contains(cell) ? cell : table.closest(".table-scroll"));
  }

  function serializeDocument() {
    const blocks = [];
    Array.from(article.childNodes).forEach((node) => {
      const value = serializeBlock(node).trimEnd();
      if (value) blocks.push(value);
    });
    return blocks.join("\n\n").replace(/\n{4,}/g, "\n\n\n") + (blocks.length ? "\n" : "");
  }

  function serializeBlock(node) {
    if (node.nodeType === Node.TEXT_NODE) return escapeText(node.nodeValue.trim());
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    if (node.matches(".editor-object-source, .code-toolbar, .diagram-label")) return "";
    if (node.dataset.editorInsertMarkdown !== undefined) {
      return node.dataset.editorInsertMarkdown;
    }
    if (node.matches(".frontmatter-card")) {
      return decodeURIComponent(node.dataset.frontmatterSource || "");
    }

    const tag = node.tagName.toLowerCase();
    if (/^h[1-6]$/.test(tag)) {
      return "#".repeat(Number(tag[1])) + " " + serializeChildrenInline(node).trim();
    }
    if (tag === "p") return serializeChildrenInline(node).trim();
    if (tag === "blockquote") return serializeBlockquote(node);
    if (tag === "ul" || tag === "ol") return serializeList(node);
    if (node.matches(".code-card")) return serializeCodeCard(node);
    if (node.matches(".diagram-card")) return serializeDiagramCard(node);
    if (node.matches(".table-scroll") || tag === "table") return serializeTable(node);
    if (tag === "pre") {
      const code = node.querySelector("code");
      return fencedCode(code ? code.textContent : node.textContent, languageForCode(code));
    }
    if (tag === "hr") return node.classList.contains("footnotes-sep") ? "" : "---";
    if (tag === "section" && node.classList.contains("footnotes")) return serializeFootnotes(node);
    if (tag === "div" && !hasDirectBlockChildren(node)) {
      return serializeChildrenInline(node).trim();
    }
    if (tag === "div" || tag === "section" || tag === "article") {
      return Array.from(node.childNodes)
        .map(serializeBlock)
        .filter(Boolean)
        .join("\n\n");
    }
    return serializeChildrenInline(node).trim();
  }

  function serializeChildrenInline(parent) {
    return Array.from(parent.childNodes).map(serializeInline).join("");
  }

  function serializeInline(node) {
    if (node.nodeType === Node.TEXT_NODE) return escapeText(node.nodeValue);
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    if (
      node.matches(
        ".heading-anchor, .copy-code, .alert-title, .footnote-backref, .editor-object-source"
      )
    ) {
      return "";
    }

    const tag = node.tagName.toLowerCase();
    if (tag === "br") return "  \n";
    if (tag === "strong" || tag === "b") return wrapInline("**", serializeChildrenInline(node));
    if (tag === "em" || tag === "i") return wrapInline("*", serializeChildrenInline(node));
    if (tag === "del" || tag === "s" || tag === "strike") {
      return wrapInline("~~", serializeChildrenInline(node));
    }
    if (tag === "code" && !node.closest("pre")) return serializeInlineCode(node.textContent);
    if (tag === "img") return serializeImage(node);
    if (tag === "input" && node.type === "checkbox") return "";
    if (node.classList.contains("katex") || node.classList.contains("katex-display")) {
      return serializeMath(node);
    }
    if (node.classList.contains("footnote-ref")) {
      const label =
        node.dataset.footnoteLabel ||
        (node.textContent.match(/\[([^\]]+)\]/) || [null, "1"])[1];
      return "[^" + label + "]";
    }
    if (tag === "a") {
      const label = serializeChildrenInline(node);
      const href = node.getAttribute("href") || "";
      const title = node.getAttribute("title");
      return "[" + label + "](" + href + (title ? ' "' + title.replace(/"/g, '\\"') + '"' : "") + ")";
    }
    return serializeChildrenInline(node);
  }

  function wrapInline(marker, content) {
    return content ? marker + content + marker : "";
  }

  function escapeText(value) {
    return (value || "")
      .replace(/\\/g, "\\\\")
      .replace(/([*_[\]`])/g, "\\$1");
  }

  function serializeInlineCode(value) {
    const runs = (value.match(/`+/g) || []).map((run) => run.length);
    const fence = "`".repeat(Math.max(1, runs.length ? Math.max.apply(null, runs) + 1 : 1));
    const padding = value.startsWith("`") || value.endsWith("`") ? " " : "";
    return fence + padding + value + padding + fence;
  }

  function serializeImage(node) {
    const alt = (node.getAttribute("alt") || "").replace(/]/g, "\\]");
    const source = window.previewmdOriginalImageSource
      ? window.previewmdOriginalImageSource(node)
      : node.getAttribute("src") || "";
    const title = node.getAttribute("title");
    return "![" + alt + "](" + source + (title ? ' "' + title.replace(/"/g, '\\"') + '"' : "") + ")";
  }

  function serializeMath(node) {
    const source =
      node.dataset.mathSource ||
      ((node.querySelector && node.querySelector('annotation[encoding="application/x-tex"]')) || {})
        .textContent ||
      "";
    const display = node.classList.contains("katex-display") || !!node.closest(".katex-display");
    return display ? "$$\n" + source + "\n$$" : "$" + source + "$";
  }

  function serializeBlockquote(node) {
    const alertClass = Array.from(node.classList).find((name) => name.startsWith("alert-"));
    const children = Array.from(node.children).filter(
      (child) => !child.classList.contains("alert-title")
    );
    const body = children.map(serializeBlock).filter(Boolean).join("\n\n");
    const marker = alertClass ? "[!" + alertClass.slice(6).toUpperCase() + "]\n" : "";
    return (marker + body)
      .split("\n")
      .map((line) => "> " + line)
      .join("\n");
  }

  function serializeList(list) {
    return Array.from(list.children)
      .filter((item) => item.tagName && item.tagName.toLowerCase() === "li")
      .map((item, index) => serializeListItem(item, list, index))
      .join("\n");
  }

  function serializeListItem(item, list, index) {
    const checkbox = item.querySelector(
      ':scope > input[type="checkbox"], :scope > p > input[type="checkbox"]'
    );
    const ordered = list.tagName.toLowerCase() === "ol";
    const start = Number(list.getAttribute("start") || 1);
    const prefix = checkbox
      ? "- [" + (checkbox.checked ? "x" : " ") + "] "
      : ordered
        ? start + index + ". "
        : "- ";
    const direct = Array.from(item.childNodes).filter(
      (child) =>
        !(
          child.nodeType === Node.ELEMENT_NODE &&
          (child.matches("ul, ol") ||
            (child.matches("input") && child.type === "checkbox"))
        )
    );
    let content = serializeListItemContent(direct);
    const continuation = " ".repeat(prefix.length);
    content = content
      .split("\n")
      .map((line, lineIndex) => (lineIndex ? continuation + line : line))
      .join("\n");

    const nested = Array.from(item.children).filter((child) => child.matches("ul, ol"));
    const nestedText = nested
      .map((child) =>
        serializeList(child)
          .split("\n")
          .map((line) => "    " + line)
          .join("\n")
      )
      .join("\n");
    return prefix + content + (nestedText ? "\n" + nestedText : "");
  }

  function serializeListItemContent(nodes) {
    const blocks = [];
    let inline = "";
    const flushInline = () => {
      const value = inline.trim();
      if (value) blocks.push(value);
      inline = "";
    };

    nodes.forEach((node) => {
      if (isInlineListItemNode(node)) {
        inline += serializeInline(node);
        return;
      }
      flushInline();
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const value =
        node.tagName.toLowerCase() === "p"
          ? serializeChildrenInline(node).trim()
          : serializeBlock(node).trim();
      if (value) blocks.push(value);
    });
    flushInline();
    return blocks.join("\n\n");
  }

  function isInlineListItemNode(node) {
    if (node.nodeType === Node.TEXT_NODE) return true;
    if (node.nodeType !== Node.ELEMENT_NODE) return false;
    return !listItemBlockTags.has(node.tagName.toLowerCase());
  }

  function hasDirectBlockChildren(node) {
    return Array.from(node.children).some((child) =>
      listItemBlockTags.has(child.tagName.toLowerCase())
    );
  }

  function serializeCodeCard(card) {
    const code = card.querySelector("code");
    return fencedCode(code ? code.textContent : "", languageForCode(code));
  }

  function serializeDiagramCard(card) {
    const diagram = card.querySelector(".mermaid");
    const source = diagram ? diagram.dataset.source || diagram.textContent : "";
    return fencedCode(source, "mermaid");
  }

  function languageForCode(code) {
    if (!code) return "";
    return ((code.className.match(/language-([^\s]+)/) || [])[1] || "").trim();
  }

  function fencedCode(source, language) {
    const runs = (source.match(/`{3,}/g) || []).map((run) => run.length);
    const fence = "`".repeat(Math.max(3, runs.length ? Math.max.apply(null, runs) + 1 : 3));
    return fence + (language || "") + "\n" + source.replace(/\n$/, "") + "\n" + fence;
  }

  function serializeTable(wrapper) {
    const table = wrapper.matches("table") ? wrapper : wrapper.querySelector("table");
    if (!table || !table.rows.length) return "";
    const rows = Array.from(table.rows);
    const headerRow = table.tHead && table.tHead.rows.length ? table.tHead.rows[0] : rows[0];
    const bodyRows = rows.filter((row) => row !== headerRow);
    const headers = Array.from(headerRow.cells).map(serializeTableCell);
    const separators = Array.from(headerRow.cells).map((cell) => {
      const align = (cell.style.textAlign || cell.getAttribute("align") || "").toLowerCase();
      if (align === "center") return ":---:";
      if (align === "right") return "---:";
      if (align === "left") return ":---";
      return "---";
    });
    const lines = [tableLine(headers), tableLine(separators)];
    bodyRows.forEach((row) => {
      const cells = Array.from(row.cells).map(serializeTableCell);
      while (cells.length < headers.length) cells.push("");
      lines.push(tableLine(cells.slice(0, headers.length)));
    });
    return lines.join("\n");
  }

  function serializeTableCell(cell) {
    return serializeChildrenInline(cell)
      .trim()
      .replace(/\n/g, "<br>")
      .replace(/\|/g, "\\|");
  }

  function tableLine(cells) {
    return "| " + cells.join(" | ") + " |";
  }

  function serializeFootnotes(section) {
    const items = section.querySelectorAll(".footnote-item");
    return Array.from(items)
      .map((item, index) => {
        const label =
          item.dataset.footnoteLabel ||
          (item.id || "").replace(/^fn/, "") ||
          String(index + 1);
        const body = Array.from(item.childNodes)
          .map(serializeBlock)
          .filter(Boolean)
          .join("\n\n");
        return (
          "[^" +
          label +
          "]: " +
          body
            .split("\n")
            .map((line, lineIndex) => (lineIndex ? "    " + line : line))
            .join("\n")
        );
      })
      .join("\n\n");
  }

  function handleMarkdownTypingShortcut(event) {
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return false;
    if (event.key !== " " && event.key !== "Enter") return false;
    const selection = window.getSelection();
    if (!selectionInsideArticle(selection) || !selection.isCollapsed || !selection.rangeCount) {
      return false;
    }
    const block = selectionBlock(selection);
    if (!block || block.tagName.toLowerCase() !== "p" || block.parentElement !== article) {
      return false;
    }
    const range = selection.getRangeAt(0);
    if (!isCaretAtDOMEdge(range, block, true)) return false;
    const marker = (block.textContent || "").trim();

    if (event.key === "Enter" && (/^```[A-Za-z0-9_-]*$/.test(marker) || marker === "---")) {
      event.preventDefault();
      const snippet = marker === "---" ? "---" : marker + "\n\n```";
      replaceEmptyLineWithMarkdown(block, snippet);
      return true;
    }
    if (event.key !== " ") return false;

    let replacement = null;
    let caretTarget = null;
    const heading = marker.match(/^(#{1,6})$/);
    if (heading) {
      replacement = document.createElement("h" + heading[1].length);
      caretTarget = replacement;
    } else if (marker === ">") {
      replacement = document.createElement("blockquote");
      const paragraph = document.createElement("p");
      replacement.appendChild(paragraph);
      caretTarget = paragraph;
    } else if (["-", "*", "+", "1."].includes(marker)) {
      replacement = document.createElement(marker === "1." ? "ol" : "ul");
      const item = document.createElement("li");
      replacement.appendChild(item);
      caretTarget = item;
    } else if (/^- \[[ xX]\]$/.test(marker)) {
      replacement = document.createElement("ul");
      replacement.className = "task-list";
      const item = document.createElement("li");
      item.className = "task-list-item";
      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = /[xX]/.test(marker);
      checkbox.setAttribute(
        "aria-label",
        checkbox.checked ? "Completed" : "Not completed"
      );
      item.appendChild(checkbox);
      replacement.appendChild(item);
      caretTarget = item;
    }

    if (!replacement || !caretTarget) return false;
    event.preventDefault();
    caretTarget.appendChild(document.createElement("br"));
    block.replaceWith(replacement);
    placeCaretAtStart(caretTarget);
    scheduleChange(true, true);
    return true;
  }

  function directTaskCheckbox(item) {
    return item && item.querySelector(
      ':scope > input[type="checkbox"], :scope > p > input[type="checkbox"]'
    );
  }

  function prepareContinuedTaskItem(item) {
    let checkbox = directTaskCheckbox(item);
    if (!checkbox) {
      checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      const target = item.querySelector(":scope > p") || item;
      target.insertBefore(checkbox, target.firstChild);
    }
    checkbox.checked = false;
    checkbox.disabled = false;
    checkbox.setAttribute("aria-label", "Not completed");
    item.classList.add("task-list-item");
    item.parentElement && item.parentElement.classList.add("task-list");
  }

  function handleTaskListReturn(event) {
    if (
      event.key !== "Enter" ||
      event.shiftKey ||
      event.metaKey ||
      event.ctrlKey ||
      event.altKey
    ) {
      return false;
    }
    const selection = window.getSelection();
    if (!selectionInsideArticle(selection) || !selection.isCollapsed || !selection.rangeCount) {
      return false;
    }
    const anchor =
      selection.anchorNode.nodeType === Node.TEXT_NODE
        ? selection.anchorNode.parentElement
        : selection.anchorNode;
    const item = anchor && anchor.closest && anchor.closest("li");
    if (!item || !directTaskCheckbox(item) || listItemTextLength(item) === 0) {
      return false;
    }

    event.preventDefault();
    document.execCommand("insertParagraph", false, null);
    const nextSelection = window.getSelection();
    const nextAnchor =
      nextSelection && nextSelection.anchorNode
        ? nextSelection.anchorNode.nodeType === Node.TEXT_NODE
          ? nextSelection.anchorNode.parentElement
          : nextSelection.anchorNode
        : null;
    const nextItem = nextAnchor && nextAnchor.closest && nextAnchor.closest("li");
    if (nextItem && nextItem !== item) {
      prepareContinuedTaskItem(nextItem);
    }
    scheduleChange(true, true);
    return true;
  }

  function insertPlainTextAtSelection(text) {
    const selection = window.getSelection();
    if (!selectionInsideArticle(selection) || !selection.rangeCount) return false;
    const originalBlock = selectionBlock(selection);
    const range = selection.getRangeAt(0);
    range.deleteContents();
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);

    const normalized = (text || "").replace(/\r\n?|\u0085|\u2028|\u2029/g, "\n");
    let followsInsertedBreak = false;
    normalized.split(/(\n+)/).forEach((part) => {
      if (!part) return;
      if (part[0] !== "\n") {
        if (
          !followsInsertedBreak ||
          !document.execCommand("insertText", false, part)
        ) {
          insertPlainTextNodeAtSelection(part);
        }
        followsInsertedBreak = false;
        return;
      }
      const command = part.length === 1 ? "insertLineBreak" : "insertParagraph";
      document.execCommand(command, false, null);
      followsInsertedBreak = true;
    });
    normalizePastedTopLevelBlocks();
    if (
      normalized &&
      originalBlock &&
      originalBlock.parentElement === article &&
      !(originalBlock.textContent || "").trim() &&
      !originalBlock.querySelector("br, img, input, table")
    ) {
      originalBlock.remove();
    }
    return true;
  }

  function normalizePastedTopLevelBlocks() {
    Array.from(article.childNodes).forEach((node) => {
      if (node.nodeType === Node.TEXT_NODE) {
        if (!(node.nodeValue || "").trim()) return;
        const paragraph = document.createElement("p");
        node.replaceWith(paragraph);
        paragraph.appendChild(node);
        return;
      }
      if (
        node.nodeType !== Node.ELEMENT_NODE ||
        node.tagName.toLowerCase() !== "div" ||
        node.className ||
        node.hasAttribute("contenteditable") ||
        node.dataset.editorInsertMarkdown !== undefined ||
        hasDirectBlockChildren(node)
      ) {
        return;
      }
      const paragraph = document.createElement("p");
      while (node.firstChild) paragraph.appendChild(node.firstChild);
      node.replaceWith(paragraph);
    });
  }

  function insertPlainTextNodeAtSelection(text) {
    const selection = window.getSelection();
    if (!selectionInsideArticle(selection) || !selection.rangeCount) return false;
    const range = selection.getRangeAt(0);
    const node = document.createTextNode(text);
    range.insertNode(node);
    range.setStartAfter(node);
    range.collapse(true);
    selection.removeAllRanges();
    selection.addRange(range);
    return true;
  }

  function handlePlainTextPaste(event) {
    if (!editable || !event.clipboardData) return false;
    const plainText = event.clipboardData.getData("text/plain");
    const types = event.clipboardData.types
      ? Array.from(event.clipboardData.types)
      : [];
    if (!plainText && types.length && !types.includes("text/plain")) return false;

    event.preventDefault();
    insertPlainTextAtSelection(plainText);
    scheduleChange(true, true);
    window.requestAnimationFrame(updateBlockInserter);
    return true;
  }

  function postSplitSyncMessage(payload) {
    try {
      const handler =
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.splitSync;
      handler && handler.postMessage(payload);
    } catch (_) {}
  }

  function splitSourceLineOffsets() {
    const offsets = [0];
    for (let index = 0; index < currentMarkdown.length; index += 1) {
      const code = currentMarkdown.charCodeAt(index);
      if (code === 13) {
        if (
          index + 1 < currentMarkdown.length &&
          currentMarkdown.charCodeAt(index + 1) === 10
        ) {
          index += 1;
        }
        offsets.push(index + 1);
      } else if (
        code === 10 ||
        code === 0x85 ||
        code === 0x2028 ||
        code === 0x2029
      ) {
        offsets.push(index + 1);
      }
    }
    return offsets;
  }

  function splitSourceLineForOffset(offset, lineOffsets) {
    const normalized = Math.max(
      0,
      Math.min(Number(offset) || 0, currentMarkdown.length)
    );
    let lower = 0;
    let upper = lineOffsets.length;
    while (lower < upper) {
      const middle = lower + Math.floor((upper - lower) / 2);
      if (lineOffsets[middle] <= normalized) lower = middle + 1;
      else upper = middle;
    }
    return Math.max(0, lower - 1);
  }

  function refreshSplitSourcePositions() {
    article
      .querySelectorAll(
        "[data-previewmd-source-start][data-previewmd-source-end]"
      )
      .forEach((element) => {
        delete element.dataset.previewmdSourceStart;
        delete element.dataset.previewmdSourceEnd;
      });
    const lineOffsets = splitSourceLineOffsets();
    let cursor = 0;
    Array.from(article.children).forEach((block) => {
      const source = serializeBlock(block).trimEnd();
      if (!source) return;
      const found = currentMarkdown.indexOf(source, cursor);
      if (found < cursor) return;
      const sourceEnd = found + source.length;
      setSplitSourcePosition(block, found, sourceEnd, lineOffsets);
      if (block.matches("ul, ol")) {
        refreshSplitListSourcePositions(
          block,
          found,
          sourceEnd,
          lineOffsets,
          0
        );
      }
      cursor = sourceEnd;
    });
  }

  function setSplitSourcePosition(element, sourceStart, sourceEnd, lineOffsets) {
    const startLine = splitSourceLineForOffset(sourceStart, lineOffsets);
    const endLine =
      splitSourceLineForOffset(Math.max(sourceStart, sourceEnd - 1), lineOffsets) + 1;
    element.dataset.previewmdSourceStart = String(startLine);
    element.dataset.previewmdSourceEnd = String(endLine);
  }

  function refreshSplitListSourcePositions(
    list,
    sourceStart,
    sourceEnd,
    lineOffsets,
    depth
  ) {
    const items = Array.from(list.children).filter(
      (item) => item.tagName && item.tagName.toLowerCase() === "li"
    );
    let cursor = sourceStart;
    items.forEach((item, index) => {
      const itemSource = indentSplitListSource(
        serializeListItem(item, list, index),
        depth
      );
      const found = currentMarkdown.indexOf(itemSource, cursor);
      const itemEnd = found + itemSource.length;
      if (found < cursor || itemEnd > sourceEnd) return;
      setSplitSourcePosition(item, found, itemEnd, lineOffsets);

      let nestedCursor = found;
      Array.from(item.children)
        .filter((child) => child.matches("ul, ol"))
        .forEach((nestedList) => {
          const nestedSource = indentSplitListSource(
            serializeList(nestedList),
            depth + 1
          );
          const nestedFound = currentMarkdown.indexOf(nestedSource, nestedCursor);
          const nestedEnd = nestedFound + nestedSource.length;
          if (nestedFound < nestedCursor || nestedEnd > itemEnd) return;
          setSplitSourcePosition(nestedList, nestedFound, nestedEnd, lineOffsets);
          refreshSplitListSourcePositions(
            nestedList,
            nestedFound,
            nestedEnd,
            lineOffsets,
            depth + 1
          );
          nestedCursor = nestedEnd;
        });
      cursor = itemEnd;
    });
  }

  function indentSplitListSource(source, depth) {
    const indentation = " ".repeat(Math.max(0, depth) * 4);
    if (!indentation) return source;
    return source
      .split("\n")
      .map((line) => indentation + line)
      .join("\n");
  }

  function splitSourceBounds(element, lineOffsets) {
    if (!element) return null;
    const startLine = Number(element.dataset.previewmdSourceStart);
    const endLine = Number(element.dataset.previewmdSourceEnd);
    if (!Number.isFinite(startLine) || !Number.isFinite(endLine)) return null;
    const start = lineOffsets[Math.max(0, Math.floor(startLine))] ?? 0;
    const end =
      lineOffsets[Math.max(0, Math.floor(endLine))] ?? currentMarkdown.length;
    return { startLine, endLine, start, end };
  }

  function splitMappedElements() {
    return Array.from(
      article.querySelectorAll(
        "[data-previewmd-source-start][data-previewmd-source-end]"
      )
    );
  }

  function splitTextNodes(element) {
    const nodes = [];
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT, {
      acceptNode(textNode) {
        const parent = textNode.parentElement;
        if (
          !parent ||
          parent.closest(
            ".heading-anchor, .copy-code, .code-toolbar, .diagram-label, " +
              ".table-expand, .alert-title, .footnote-backref, .editor-object-source"
          )
        ) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function splitTextMappings(element, lineOffsets) {
    const bounds = splitSourceBounds(element, lineOffsets);
    if (!bounds) return [];
    let cursor = bounds.start;
    const mappings = [];
    splitTextNodes(element).forEach((node) => {
      const value = node.nodeValue || "";
      if (!value) return;
      const found = currentMarkdown.indexOf(value, cursor);
      if (found < cursor || found + value.length > bounds.end) return;
      mappings.push({
        node,
        sourceStart: found,
        sourceEnd: found + value.length,
      });
      cursor = found + value.length;
    });
    return mappings;
  }

  function splitMappedElementForNode(node) {
    const element =
      node && node.nodeType === Node.ELEMENT_NODE
        ? node
        : node && node.parentElement;
    return element && element.closest
      ? element.closest(
          "[data-previewmd-source-start][data-previewmd-source-end]"
        )
      : null;
  }

  function splitSourceOffsetForDOMPoint(node, offset, lineOffsets) {
    const element = splitMappedElementForNode(node);
    const bounds = splitSourceBounds(element, lineOffsets);
    if (!element || !bounds) return null;
    const mappings = splitTextMappings(element, lineOffsets);
    if (node && node.nodeType === Node.TEXT_NODE) {
      const mapping = mappings.find((candidate) => candidate.node === node);
      if (mapping) {
        return Math.min(
          mapping.sourceEnd,
          mapping.sourceStart + Math.max(0, Number(offset) || 0)
        );
      }
    }
    return bounds.start;
  }

  function splitDOMPointForSourceOffset(offset, lineOffsets) {
    const line = splitSourceLineForOffset(offset, lineOffsets);
    const candidates = splitMappedElements()
      .map((element) => ({
        element,
        bounds: splitSourceBounds(element, lineOffsets),
      }))
      .filter(
        (candidate) =>
          candidate.bounds &&
          line >= candidate.bounds.startLine &&
          line < candidate.bounds.endLine
      )
      .sort((left, right) => {
        const leftSpan = left.bounds.endLine - left.bounds.startLine;
        const rightSpan = right.bounds.endLine - right.bounds.startLine;
        if (leftSpan !== rightSpan) return leftSpan - rightSpan;
        if (left.element.contains(right.element)) return 1;
        if (right.element.contains(left.element)) return -1;
        return 0;
      });

    for (const candidate of candidates) {
      const mappings = splitTextMappings(candidate.element, lineOffsets);
      const mapping = mappings.find(
        (item) => offset >= item.sourceStart && offset <= item.sourceEnd
      );
      if (mapping) {
        return {
          node: mapping.node,
          offset: Math.max(
            0,
            Math.min(
              mapping.node.nodeValue.length,
              offset - mapping.sourceStart
            )
          ),
        };
      }
    }

    const fallback = candidates[0];
    if (!fallback) return null;
    const mappings = splitTextMappings(fallback.element, lineOffsets);
    if (mappings.length) {
      const first = mappings[0];
      const last = mappings[mappings.length - 1];
      return offset <= first.sourceStart
        ? { node: first.node, offset: 0 }
        : { node: last.node, offset: last.node.nodeValue.length };
    }
    return { node: fallback.element, offset: 0 };
  }

  function currentSplitSelection() {
    const selection = window.getSelection();
    if (!selectionInsideArticle(selection) || !selection.rangeCount) return null;
    const range = selection.getRangeAt(0);
    const lineOffsets = splitSourceLineOffsets();
    const anchor = splitSourceOffsetForDOMPoint(
      range.startContainer,
      range.startOffset,
      lineOffsets
    );
    const focus = splitSourceOffsetForDOMPoint(
      range.endContainer,
      range.endOffset,
      lineOffsets
    );
    if (anchor === null || focus === null) return null;
    return { start: Math.min(anchor, focus), end: Math.max(anchor, focus) };
  }

  function clearSplitCounterpartIndicator() {
    splitSynchronizedRange = null;
    splitSyncCaret.hidden = true;
    if (window.CSS && CSS.highlights) {
      CSS.highlights.delete("split-sync-selection");
    }
  }

  function splitCaretRect(range) {
    const direct = range.getBoundingClientRect();
    if (direct.height > 0) return direct;
    const node = range.startContainer;
    const offset = range.startOffset;
    if (node && node.nodeType === Node.TEXT_NODE && node.nodeValue.length) {
      const probe = range.cloneRange();
      if (offset < node.nodeValue.length) {
        probe.setEnd(node, offset + 1);
        const rect = probe.getBoundingClientRect();
        return {
          left: rect.left,
          top: rect.top,
          height: rect.height,
        };
      }
      if (offset > 0) {
        probe.setStart(node, offset - 1);
        const rect = probe.getBoundingClientRect();
        return {
          left: rect.right,
          top: rect.top,
          height: rect.height,
        };
      }
    }
    const element =
      node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentElement;
    const fallback = element ? element.getBoundingClientRect() : direct;
    return {
      left: fallback.left,
      top: fallback.top,
      height: fallback.height,
    };
  }

  function updateSplitCounterpartIndicator() {
    if (!splitSynchronizedRange) return;
    if (!splitSynchronizedRange.collapsed) {
      splitSyncCaret.hidden = true;
      if (window.CSS && CSS.highlights) {
        CSS.highlights.set(
          "split-sync-selection",
          new Highlight(splitSynchronizedRange)
        );
      }
      return;
    }

    if (window.CSS && CSS.highlights) {
      CSS.highlights.delete("split-sync-selection");
    }
    const rect = splitCaretRect(splitSynchronizedRange);
    splitSyncCaret.style.left = Math.round(rect.left) + "px";
    splitSyncCaret.style.top = Math.round(rect.top) + "px";
    splitSyncCaret.style.height = Math.max(14, Math.round(rect.height)) + "px";
    splitSyncCaret.hidden = false;
  }

  function applySplitSelection(position) {
    if (!position) return false;
    const start = Math.max(
      0,
      Math.min(Number(position.start) || 0, currentMarkdown.length)
    );
    const end = Math.max(
      start,
      Math.min(Number(position.end) || start, currentMarkdown.length)
    );
    const lineOffsets = splitSourceLineOffsets();
    const startPoint = splitDOMPointForSourceOffset(start, lineOffsets);
    const endPoint = splitDOMPointForSourceOffset(end, lineOffsets);
    if (!startPoint || !endPoint) return false;
    try {
      const range = document.createRange();
      range.setStart(startPoint.node, startPoint.offset);
      range.setEnd(endPoint.node, endPoint.offset);
      ignoreSplitSelectionUntil = performance.now() + 120;
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      splitSynchronizedRange = range.cloneRange();
      updateSplitCounterpartIndicator();
      return true;
    } catch (_) {
      return false;
    }
  }

  function currentSplitScrollPosition() {
    const anchorY = splitScrollAnchor();
    const candidates = splitMappedElements()
      .map((element) => ({
        element,
        rect: element.getBoundingClientRect(),
        startLine: Number(element.dataset.previewmdSourceStart),
        endLine: Number(element.dataset.previewmdSourceEnd),
      }))
      .filter(
        (candidate) =>
          candidate.rect.height > 0 &&
          Number.isFinite(candidate.startLine) &&
          Number.isFinite(candidate.endLine)
      );
    if (!candidates.length) return null;
    const containing = candidates.filter(
      (candidate) =>
        candidate.rect.top <= anchorY && candidate.rect.bottom >= anchorY
    );
    const pool = containing.length ? containing : candidates;
    pool.sort((left, right) => {
      if (containing.length) {
        const leftSpan = left.endLine - left.startLine;
        const rightSpan = right.endLine - right.startLine;
        if (leftSpan !== rightSpan) return leftSpan - rightSpan;
      }
      return (
        Math.abs(left.rect.top - anchorY) -
        Math.abs(right.rect.top - anchorY)
      );
    });
    const target = pool[0];
    const ratio = Math.max(
      0,
      Math.min(
        1,
        (anchorY - target.rect.top) / Math.max(1, target.rect.height)
      )
    );
    const span = Math.max(1, target.endLine - target.startLine);
    const lastLine = Math.max(target.startLine, target.endLine - 1);
    return {
      sourceLine: Math.max(
        target.startLine,
        Math.min(lastLine, target.startLine + ratio * span - 0.5)
      ),
    };
  }

  function applySplitScrollPosition(position) {
    const sourceLine = Number(position && position.sourceLine);
    if (!Number.isFinite(sourceLine)) return false;
    const candidates = splitMappedElements()
      .map((element) => ({
        element,
        rect: element.getBoundingClientRect(),
        startLine: Number(element.dataset.previewmdSourceStart),
        endLine: Number(element.dataset.previewmdSourceEnd),
      }))
      .filter(
        (candidate) =>
          Number.isFinite(candidate.startLine) &&
          Number.isFinite(candidate.endLine)
      );
    if (!candidates.length) return false;
    const containing = candidates.filter(
      (candidate) =>
        sourceLine >= candidate.startLine && sourceLine < candidate.endLine
    );
    const pool = containing.length ? containing : candidates;
    pool.sort((left, right) => {
      if (containing.length) {
        const leftSpan = left.endLine - left.startLine;
        const rightSpan = right.endLine - right.startLine;
        if (leftSpan !== rightSpan) return leftSpan - rightSpan;
      }
      const leftDistance = Math.min(
        Math.abs(sourceLine - left.startLine),
        Math.abs(sourceLine - left.endLine)
      );
      const rightDistance = Math.min(
        Math.abs(sourceLine - right.startLine),
        Math.abs(sourceLine - right.endLine)
      );
      return leftDistance - rightDistance;
    });
    const target = pool[0];
    const span = Math.max(1, target.endLine - target.startLine);
    const ratio = Math.max(
      0,
      Math.min(1, (sourceLine - target.startLine + 0.5) / span)
    );
    const anchorY = splitScrollAnchor();
    const top =
      window.scrollY +
      target.rect.top +
      ratio * target.rect.height -
      anchorY;
    ignoreSplitScrollUntil = performance.now() + 120;
    const previousScrollBehavior = document.documentElement.style.scrollBehavior;
    document.documentElement.style.scrollBehavior = "auto";
    window.scrollTo(0, Math.max(0, top));
    document.documentElement.style.scrollBehavior = previousScrollBehavior;
    return true;
  }

  function splitScrollAnchor() {
    return Math.max(0, window.innerHeight * 0.5);
  }

  function scheduleSplitSelectionPublication() {
    if (splitSelectionFrame) return;
    splitSelectionFrame = window.requestAnimationFrame(() => {
      splitSelectionFrame = 0;
      if (performance.now() < ignoreSplitSelectionUntil) return;
      const position = currentSplitSelection();
      if (position) {
        clearSplitCounterpartIndicator();
        postSplitSyncMessage({ kind: "selection", ...position });
      }
    });
  }

  function scheduleSplitScrollPublication() {
    if (splitScrollFrame) return;
    splitScrollFrame = window.requestAnimationFrame(() => {
      splitScrollFrame = 0;
      if (performance.now() < ignoreSplitScrollUntil) return;
      const position = currentSplitScrollPosition();
      if (position) {
        postSplitSyncMessage({ kind: "scroll", ...position });
      }
    });
  }

  function handleInlineMarkdownTypingShortcut() {
    const selection = window.getSelection();
    if (!selectionInsideArticle(selection) || !selection.isCollapsed || !selection.rangeCount) {
      return false;
    }
    const textNode = selection.anchorNode;
    if (!textNode || textNode.nodeType !== Node.TEXT_NODE) return false;
    const parent = textNode.parentElement;
    if (
      !parent ||
      parent.closest("a, code, pre, [contenteditable='false'], .frontmatter-card")
    ) {
      return false;
    }

    const prefix = textNode.nodeValue.slice(0, selection.anchorOffset);
    const patterns = [
      { expression: /\[([^\]\n]+)\]\(([^)\s]+)\)$/, tag: "a" },
      { expression: /\*\*([^*\n]+)\*\*$/, tag: "strong" },
      { expression: /__([^_\n]+)__$/, tag: "strong" },
      { expression: /~~([^~\n]+)~~$/, tag: "s" },
      { expression: /`([^`\n]+)`$/, tag: "code" },
      { expression: /\*([^*\n]+)\*$/, tag: "em" },
      { expression: /_([^_\n]+)_$/, tag: "em" },
    ];

    for (const pattern of patterns) {
      const match = prefix.match(pattern.expression);
      if (!match) continue;
      const start = match.index;
      if (start > 0 && !/[\s([{"'“‘]/.test(prefix[start - 1])) continue;
      if (
        pattern.tag === "a" &&
        /^\s*(?:javascript|data|vbscript):/i.test(match[2])
      ) {
        return false;
      }

      const token = textNode.splitText(start);
      token.splitText(match[0].length);
      const element = document.createElement(pattern.tag);
      element.textContent = match[1];
      if (pattern.tag === "a") element.setAttribute("href", match[2]);
      token.replaceWith(element);
      placeCaretBesideObject(element, true);
      return true;
    }
    return false;
  }

  article.addEventListener("input", () => {
    handleInlineMarkdownTypingShortcut();
    scheduleChange(false, false);
    window.requestAnimationFrame(updateBlockInserter);
  });
  article.addEventListener("change", (event) => {
    if (event.target.matches('input[type="checkbox"]')) scheduleChange(true, true);
  });
  article.addEventListener("paste", handlePlainTextPaste);
  article.addEventListener("click", (event) => {
    if (!editable) return;
    const anchor = event.target.closest("a");
    if (anchor) event.preventDefault();

    const object = event.target.closest(
      ".frontmatter-card, td, th, img, .code-card, .diagram-card, .katex-display, .katex, hr:not(.footnotes-sep), a"
    );
    const selection = window.getSelection();
    if (object && (!selection || selection.isCollapsed)) {
      selectObject(object);
    } else if (!event.target.closest(".editor-bubble-toolbar")) {
      clearObjectSelection();
    }
    window.requestAnimationFrame(updateBlockInserter);
  });
  article.addEventListener("keydown", (event) => {
    if (!editable) return;
    if (handleTaskListReturn(event)) {
      window.requestAnimationFrame(updateBlockInserter);
      return;
    }
    if (handleMarkdownTypingShortcut(event)) {
      window.requestAnimationFrame(updateBlockInserter);
      return;
    }
    const modifier = event.metaKey || event.ctrlKey;
    if (modifier && event.key.toLowerCase() === "b") {
      event.preventDefault();
      document.execCommand("bold", false, null);
      scheduleChange(true, true);
    } else if (modifier && event.key.toLowerCase() === "i") {
      event.preventDefault();
      document.execCommand("italic", false, null);
      scheduleChange(true, true);
    } else if (modifier && event.key.toLowerCase() === "k") {
      event.preventDefault();
      const selection = window.getSelection();
      if (selection && !selection.isCollapsed) {
        savedRange = selection.getRangeAt(0).cloneRange();
        performTextAction("link");
      }
    } else if (handleArrowNavigation(event)) {
      window.requestAnimationFrame(updateBlockInserter);
      return;
    } else if (event.key === "Escape") {
      hideToolbars();
      clearObjectSelection();
    }
    window.requestAnimationFrame(updateBlockInserter);
  });
  document.addEventListener("selectionchange", () => {
    scheduleSplitSelectionPublication();
    window.requestAnimationFrame(() => {
      updateSelectionToolbar();
      updateBlockInserter();
    });
  });
  window.addEventListener(
    "scroll",
    () => {
      scheduleSplitScrollPublication();
      updateSplitCounterpartIndicator();
      if (!textToolbar.hidden) updateSelectionToolbar();
      if (!objectToolbar.hidden && selectedObject) {
        positionToolbar(objectToolbar, selectedObject.getBoundingClientRect());
      }
      if (!blockInserter.hidden) positionBlockInserter(inserterTarget);
    },
    { passive: true }
  );
  window.addEventListener("resize", () => {
    hideToolbars();
    window.requestAnimationFrame(updateBlockInserter);
  });

  function hideToolbars() {
    textToolbar.hidden = true;
    objectToolbar.hidden = true;
    hideBlockInserter();
  }

  window.previewmdSetEditable = setEditable;
  window.previewmdEditorDidRender = editorDidRender;
  window.previewmdFlushEditor = flushEditor;
  window.previewmdSerializeEditor = serializeDocument;
  window.previewmdInsertBlock = insertBlock;
  window.previewmdInsertPickedImage = insertPickedImage;
  window.previewmdCancelPickedImage = cancelPickedImage;
  window.previewmdUpdateBlockInserter = updateBlockInserter;
  window.previewmdCurrentSplitSelection = currentSplitSelection;
  window.previewmdApplySplitSelection = applySplitSelection;
  window.previewmdClearSplitSynchronization = clearSplitCounterpartIndicator;
  window.previewmdCurrentSplitScrollPosition = currentSplitScrollPosition;
  window.previewmdApplySplitScrollPosition = applySplitScrollPosition;
  window.previewmdAvailableBlocks = function () {
    return Array.from(
      blockInserter.querySelectorAll("[data-insert-block]"),
      (item) => item.dataset.insertBlock
    );
  };
  window.previewmdUndo = function () {
    if (editable) {
      document.execCommand("undo", false, null);
      scheduleChange(true, true);
    }
  };
  window.previewmdRedo = function () {
    if (editable) {
      document.execCommand("redo", false, null);
      scheduleChange(true, true);
    }
  };
})();
