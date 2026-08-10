(function () {
  "use strict";

  const SVG_NS = "http://www.w3.org/2000/svg";
  const directions = new Set(["TB", "TD", "BT", "LR", "RL"]);
  const edgeKinds = {
    "-->": { title: "Arrow", className: "is-arrow" },
    "---": { title: "Line", className: "is-line" },
    "-.->": { title: "Dotted arrow", className: "is-dotted" },
    "==>": { title: "Thick arrow", className: "is-thick" },
  };
  const shapes = {
    rectangle: { title: "Rectangle", open: '["', close: '"]' },
    rounded: { title: "Rounded", open: '("', close: '")' },
    diamond: { title: "Decision", open: '{"', close: '"}' },
    circle: { title: "Circle", open: '(("', close: '"))' },
    stadium: { title: "Pill", open: '(["', close: '"])' },
    subroutine: { title: "Subroutine", open: '[["', close: '"]]' },
    database: { title: "Database", open: '[("', close: '")]' },
  };
  const wrappedShapes = [
    { open: "((", close: "))", shape: "circle" },
    { open: "([", close: "])", shape: "stadium" },
    { open: "[[", close: "]]", shape: "subroutine" },
    { open: "[(", close: ")]", shape: "database" },
    { open: "[", close: "]", shape: "rectangle" },
    { open: "{", close: "}", shape: "diamond" },
    { open: "(", close: ")", shape: "rounded" },
  ];
  let activeEditor = null;

  function skipSpace(text, index) {
    while (index < text.length && /\s/.test(text[index])) index += 1;
    return index;
  }

  function decodeLabel(value) {
    let label = value.trim();
    if (
      label.length >= 2 &&
      ((label[0] === '"' && label[label.length - 1] === '"') ||
        (label[0] === "'" && label[label.length - 1] === "'"))
    ) {
      label = label.slice(1, -1);
    }
    return label
      .replace(/<br\s*\/?\s*>/gi, "\n")
      .replace(/&quot;|#quot;/gi, '"')
      .replace(/&#39;|&apos;/gi, "'")
      .replace(/&#124;|#124;/gi, "|")
      .replace(/&lt;/gi, "<")
      .replace(/&gt;/gi, ">")
      .replace(/&amp;/gi, "&")
      .replace(/\\([\\"'])/g, "$1");
  }

  function readWrapped(text, index, descriptor) {
    const contentStart = index + descriptor.open.length;
    let quote = "";
    let escaped = false;
    for (let cursor = contentStart; cursor <= text.length - descriptor.close.length; cursor += 1) {
      const character = text[cursor];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (character === "\\") {
        escaped = true;
        continue;
      }
      if (quote) {
        if (character === quote) quote = "";
        continue;
      }
      if (character === '"' || character === "'") {
        quote = character;
        continue;
      }
      if (text.startsWith(descriptor.close, cursor)) {
        return {
          label: decodeLabel(text.slice(contentStart, cursor)),
          end: cursor + descriptor.close.length,
        };
      }
    }
    return null;
  }

  function parseNodeAt(text, start) {
    let index = skipSpace(text, start);
    const match = text.slice(index).match(/^([A-Za-z_][A-Za-z0-9_-]*)/);
    if (!match) return null;
    const id = match[1];
    index += id.length;
    index = skipSpace(text, index);
    for (const descriptor of wrappedShapes) {
      if (!text.startsWith(descriptor.open, index)) continue;
      const wrapped = readWrapped(text, index, descriptor);
      if (!wrapped) return { error: "Unclosed node label" };
      return {
        id: id,
        label: wrapped.label || id,
        shape: descriptor.shape,
        explicit: true,
        end: wrapped.end,
      };
    }
    return {
      id: id,
      label: id,
      shape: "rectangle",
      explicit: false,
      end: index,
    };
  }

  function parseEdgeAt(text, start) {
    let index = skipSpace(text, start);
    const kind = Object.keys(edgeKinds).find((candidate) =>
      text.startsWith(candidate, index)
    );
    if (!kind) return null;
    index += kind.length;
    index = skipSpace(text, index);
    let label = "";
    if (text[index] === "|") {
      const end = text.indexOf("|", index + 1);
      if (end < 0) return { error: "Unclosed connection label" };
      label = decodeLabel(text.slice(index + 1, end));
      index = skipSpace(text, end + 1);
    }
    return { kind: kind, label: label, end: index };
  }

  function parseFlowchart(source) {
    const lines = String(source || "").replace(/\r\n?/g, "\n").split("\n");
    let headerIndex = -1;
    let direction = "TB";
    for (let index = 0; index < lines.length; index += 1) {
      if (!lines[index].trim()) continue;
      const header = lines[index]
        .trim()
        .match(/^(?:flowchart|graph)\s+(TD|TB|BT|LR|RL)\s*$/i);
      if (!header || !directions.has(header[1].toUpperCase())) {
        return {
          ok: false,
          reason: "Visual editing is available for flowchart and graph diagrams.",
        };
      }
      headerIndex = index;
      direction = header[1].toUpperCase() === "TD" ? "TB" : header[1].toUpperCase();
      break;
    }
    if (headerIndex < 0) {
      return { ok: false, reason: "Add a flowchart direction before using Visual mode." };
    }

    const nodes = [];
    const nodeByID = new Map();
    const edges = [];
    const addNode = (parsed) => {
      let node = nodeByID.get(parsed.id);
      if (!node) {
        node = {
          id: parsed.id,
          label: parsed.label,
          shape: parsed.shape,
          x: 0,
          y: 0,
        };
        nodes.push(node);
        nodeByID.set(node.id, node);
      } else if (parsed.explicit) {
        node.label = parsed.label;
        node.shape = parsed.shape;
      }
      return node;
    };

    for (let lineIndex = headerIndex + 1; lineIndex < lines.length; lineIndex += 1) {
      const statement = lines[lineIndex].trim();
      if (!statement) continue;
      if (
        statement.startsWith("%%") ||
        /^(?:subgraph|end\b|style\b|classDef\b|class\b|click\b|linkStyle\b|direction\b)/i.test(
          statement
        ) ||
        statement.includes(";") ||
        statement.includes(" & ")
      ) {
        return {
          ok: false,
          reason:
            "This flowchart uses advanced diagram syntax on line " +
            (lineIndex + 1) +
            ". Edit it safely in Code mode.",
        };
      }

      let cursor = 0;
      let current = parseNodeAt(statement, cursor);
      if (!current || current.error) {
        return {
          ok: false,
          reason: "Visual mode could not read line " + (lineIndex + 1) + ".",
        };
      }
      addNode(current);
      cursor = skipSpace(statement, current.end);
      if (cursor === statement.length) continue;

      while (cursor < statement.length) {
        const edge = parseEdgeAt(statement, cursor);
        if (!edge || edge.error) {
          return {
            ok: false,
            reason:
              "Visual mode does not support the connection syntax on line " +
              (lineIndex + 1) +
              ". Use Code mode to preserve it.",
          };
        }
        const target = parseNodeAt(statement, edge.end);
        if (!target || target.error) {
          return {
            ok: false,
            reason: "Visual mode could not read the target on line " + (lineIndex + 1) + ".",
          };
        }
        addNode(target);
        edges.push({
          id: "edge-" + (edges.length + 1),
          from: current.id,
          to: target.id,
          label: edge.label,
          kind: edge.kind,
        });
        current = target;
        cursor = skipSpace(statement, target.end);
      }
    }

    return {
      ok: true,
      model: { direction: direction, nodes: nodes, edges: edges },
    };
  }

  function encodeLabel(label) {
    return String(label || "")
      .replace(/&/g, "&amp;")
      .replace(/"/g, "&quot;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\|/g, "#124;")
      .replace(/\n/g, "<br/>");
  }

  function serializeNode(node) {
    const shape = shapes[node.shape] || shapes.rectangle;
    return node.id + shape.open + encodeLabel(node.label || node.id) + shape.close;
  }

  function serializeFlowchart(model) {
    const lines = ["flowchart " + (directions.has(model.direction) ? model.direction : "TB")];
    model.nodes.forEach((node) => lines.push("  " + serializeNode(node)));
    model.edges.forEach((edge) => {
      const kind = edgeKinds[edge.kind] ? edge.kind : "-->";
      const label = edge.label ? "|" + encodeLabel(edge.label) + "|" : "";
      lines.push("  " + edge.from + " " + kind + label + " " + edge.to);
    });
    return lines.join("\n");
  }

  function element(tagName, className, text) {
    const node = document.createElement(tagName);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function svgElement(tagName, attributes) {
    const node = document.createElementNS(SVG_NS, tagName);
    Object.keys(attributes || {}).forEach((name) => node.setAttribute(name, attributes[name]));
    return node;
  }

  function clamp(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, value));
  }

  function nodeMetrics(node) {
    const labelWidth = clamp(
      112 + Math.max(0, (node.label || "").length - 10) * 3,
      132,
      210
    );
    if (node.shape === "circle") return { width: 84, height: 84 };
    if (node.shape === "diamond") return { width: Math.max(142, labelWidth), height: 84 };
    return { width: labelWidth, height: 56 };
  }

  function autoLayout(model, stageWidth, stageHeight) {
    const nodes = model.nodes;
    if (!nodes.length) {
      return {
        width: Math.max(stageWidth, 600),
        height: Math.max(stageHeight, 360),
      };
    }
    const nodeByID = new Map(nodes.map((node) => [node.id, node]));
    const incoming = new Map(nodes.map((node) => [node.id, 0]));
    const outgoing = new Map(nodes.map((node) => [node.id, []]));
    model.edges.forEach((edge) => {
      if (!nodeByID.has(edge.from) || !nodeByID.has(edge.to)) return;
      incoming.set(edge.to, (incoming.get(edge.to) || 0) + 1);
      outgoing.get(edge.from).push(edge.to);
    });
    const queue = nodes.filter((node) => incoming.get(node.id) === 0).map((node) => node.id);
    const layer = new Map(nodes.map((node) => [node.id, 0]));
    const visited = new Set();
    while (queue.length) {
      const id = queue.shift();
      if (visited.has(id)) continue;
      visited.add(id);
      (outgoing.get(id) || []).forEach((target) => {
        layer.set(target, Math.max(layer.get(target) || 0, (layer.get(id) || 0) + 1));
        incoming.set(target, incoming.get(target) - 1);
        if (incoming.get(target) === 0) queue.push(target);
      });
    }
    let fallbackLayer = Math.max(0, ...Array.from(layer.values()));
    nodes.forEach((node) => {
      if (!visited.has(node.id)) {
        fallbackLayer += 1;
        layer.set(node.id, fallbackLayer);
      }
    });
    const groups = new Map();
    nodes.forEach((node) => {
      const value = layer.get(node.id) || 0;
      if (!groups.has(value)) groups.set(value, []);
      groups.get(value).push(node);
    });
    const layerCount = Math.max(...Array.from(groups.keys())) + 1;
    const maxGroup = Math.max(...Array.from(groups.values()).map((group) => group.length));
    const horizontal = model.direction === "LR" || model.direction === "RL";
    const width = horizontal
      ? Math.max(stageWidth, layerCount * 230 + 100)
      : Math.max(stageWidth, maxGroup * 190 + 100);
    const height = horizontal
      ? Math.max(stageHeight, 360, maxGroup * 92 + 80)
      : Math.max(stageHeight, 360, layerCount * 120 + 80);
    Array.from(groups.keys())
      .sort((left, right) => left - right)
      .forEach((layerIndex) => {
        const group = groups.get(layerIndex);
        group.forEach((node, itemIndex) => {
          const metrics = nodeMetrics(node);
          if (horizontal) {
            const forwardX = 55 + layerIndex * 230;
            node.x = model.direction === "RL" ? width - forwardX - metrics.width : forwardX;
            node.y = (height - group.length * 92) / 2 + itemIndex * 92 + 18;
          } else {
            node.x = (width - group.length * 190) / 2 + itemIndex * 190 + 20;
            const forwardY = 48 + layerIndex * 120;
            node.y = model.direction === "BT" ? height - forwardY - metrics.height : forwardY;
          }
        });
      });
    return { width: width, height: height };
  }

  function edgePath(fromNode, toNode) {
    const fromMetrics = nodeMetrics(fromNode);
    const toMetrics = nodeMetrics(toNode);
    const fromCenter = {
      x: fromNode.x + fromMetrics.width / 2,
      y: fromNode.y + fromMetrics.height / 2,
    };
    const toCenter = {
      x: toNode.x + toMetrics.width / 2,
      y: toNode.y + toMetrics.height / 2,
    };
    const dx = toCenter.x - fromCenter.x;
    const dy = toCenter.y - fromCenter.y;
    let start;
    let end;
    if (Math.abs(dx) >= Math.abs(dy)) {
      start = {
        x: fromCenter.x + (dx >= 0 ? fromMetrics.width / 2 : -fromMetrics.width / 2),
        y: fromCenter.y,
      };
      end = {
        x: toCenter.x + (dx >= 0 ? -toMetrics.width / 2 : toMetrics.width / 2),
        y: toCenter.y,
      };
      const bend = Math.max(42, Math.abs(end.x - start.x) * 0.45);
      return {
        d:
          "M " +
          start.x +
          " " +
          start.y +
          " C " +
          (start.x + (dx >= 0 ? bend : -bend)) +
          " " +
          start.y +
          ", " +
          (end.x + (dx >= 0 ? -bend : bend)) +
          " " +
          end.y +
          ", " +
          end.x +
          " " +
          end.y,
        labelX: (start.x + end.x) / 2,
        labelY: (start.y + end.y) / 2 - 8,
        start: start,
      };
    }
    start = {
      x: fromCenter.x,
      y: fromCenter.y + (dy >= 0 ? fromMetrics.height / 2 : -fromMetrics.height / 2),
    };
    end = {
      x: toCenter.x,
      y: toCenter.y + (dy >= 0 ? -toMetrics.height / 2 : toMetrics.height / 2),
    };
    const bend = Math.max(42, Math.abs(end.y - start.y) * 0.45);
    return {
      d:
        "M " +
        start.x +
        " " +
        start.y +
        " C " +
        start.x +
        " " +
        (start.y + (dy >= 0 ? bend : -bend)) +
        ", " +
        end.x +
        " " +
        (end.y + (dy >= 0 ? -bend : bend)) +
        ", " +
        end.x +
        " " +
        end.y,
      labelX: (start.x + end.x) / 2 + 8,
      labelY: (start.y + end.y) / 2,
      start: start,
    };
  }

  function createEditor(options, parsed) {
    const state = {
      options: options,
      root: element("div", "diagram-editor"),
      mode: parsed.ok ? "visual" : "code",
      model: parsed.ok ? parsed.model : null,
      selectedType: "",
      selectedID: "",
      connectingFrom: "",
      pointerConnection: null,
      expanded: false,
      stageSize: { width: 700, height: 360 },
      nextEdge: parsed.ok ? parsed.model.edges.length + 1 : 1,
    };
    state.root.setAttribute("contenteditable", "false");
    state.root.setAttribute("role", "dialog");
    state.root.setAttribute("aria-label", "Diagram editor");
    state.root.innerHTML =
      '<div class="diagram-editor-header">' +
      '<div class="diagram-mode-picker" role="tablist" aria-label="Diagram editing mode">' +
      '<button type="button" data-diagram-mode="visual" role="tab">Visual</button>' +
      '<button type="button" data-diagram-mode="code" role="tab">Code</button>' +
      "</div>" +
      '<div class="diagram-visual-actions">' +
      '<label>Direction <select data-diagram-direction aria-label="Flow direction">' +
      '<option value="TB">Top to bottom</option>' +
      '<option value="LR">Left to right</option>' +
      '<option value="RL">Right to left</option>' +
      '<option value="BT">Bottom to top</option>' +
      "</select></label>" +
      '<button type="button" data-diagram-add-node>+ Node</button>' +
      '<button type="button" data-diagram-layout title="Arrange nodes automatically">Arrange</button>' +
      "</div>" +
      '<span class="diagram-editor-spacer"></span>' +
      '<button type="button" class="diagram-expand-button" data-diagram-expand aria-label="Expand editor to workspace" aria-pressed="false" title="Expand to workspace">' +
      '<svg class="diagram-expand-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/></svg>' +
      '<svg class="diagram-collapse-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M6 2.5V6H2.5M13.5 6H10V2.5M10 13.5V10h3.5M2.5 10H6v3.5"/></svg>' +
      "</button>" +
      '<button type="button" data-diagram-cancel>Cancel</button>' +
      '<button type="button" class="is-primary" data-diagram-apply>Apply</button>' +
      "</div>" +
      '<div class="diagram-editor-status" role="status" hidden></div>' +
      '<div class="diagram-visual-pane">' +
      '<div class="diagram-canvas" tabindex="0" aria-label="Visual flowchart canvas">' +
      '<div class="diagram-stage"><svg class="diagram-edge-layer" aria-hidden="true"></svg><div class="diagram-node-layer"></div></div>' +
      "</div>" +
      '<div class="diagram-properties" aria-live="polite"></div>' +
      "</div>" +
      '<div class="diagram-code-pane"><textarea aria-label="Diagram source" spellcheck="false"></textarea></div>';
    state.code = state.root.querySelector(".diagram-code-pane textarea");
    state.code.value = options.source || "";
    state.canvas = state.root.querySelector(".diagram-canvas");
    state.stage = state.root.querySelector(".diagram-stage");
    state.edgeLayer = state.root.querySelector(".diagram-edge-layer");
    state.nodeLayer = state.root.querySelector(".diagram-node-layer");
    state.properties = state.root.querySelector(".diagram-properties");
    state.status = state.root.querySelector(".diagram-editor-status");
    state.direction = state.root.querySelector("[data-diagram-direction]");
    state.expandButton = state.root.querySelector("[data-diagram-expand]");

    state.root.querySelectorAll("[data-diagram-mode]").forEach((button) => {
      button.addEventListener("click", () => setMode(state, button.dataset.diagramMode));
    });
    state.root.querySelector("[data-diagram-cancel]").addEventListener("click", () => {
      closeEditor(state);
      if (options.onCancel) options.onCancel();
    });
    state.root.querySelector("[data-diagram-apply]").addEventListener("click", () =>
      applyEditor(state)
    );
    state.root.querySelector("[data-diagram-add-node]").addEventListener("click", () =>
      addNode(state)
    );
    state.root.querySelector("[data-diagram-layout]").addEventListener("click", () => {
      layoutState(state);
      renderGraph(state);
    });
    state.expandButton.addEventListener("click", () => {
      setExpanded(state, !state.expanded);
    });
    state.direction.addEventListener("change", () => {
      state.model.direction = state.direction.value;
      layoutState(state);
      renderGraph(state);
    });
    state.canvas.addEventListener("click", (event) => {
      if (
        event.target === state.canvas ||
        event.target === state.stage ||
        event.target === state.edgeLayer
      ) {
        state.selectedType = "";
        state.selectedID = "";
        state.connectingFrom = "";
        clearStatus(state);
        renderGraph(state);
      }
    });
    state.canvas.addEventListener("keydown", (event) => {
      if ((event.key === "Backspace" || event.key === "Delete") && state.selectedID) {
        event.preventDefault();
        deleteSelection(state);
      }
    });
    // This surface is nested in the rich-editable article. Do not let its
    // controls look like document edits or re-select the surrounding card.
    state.root.addEventListener("click", (event) => event.stopPropagation());
    state.root.addEventListener("input", (event) => event.stopPropagation());
    state.root.addEventListener("change", (event) => event.stopPropagation());
    state.root.addEventListener("keydown", (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault();
        applyEditor(state);
      } else if (event.key === "Escape") {
        event.preventDefault();
        if (state.expanded) {
          setExpanded(state, false);
        } else {
          closeEditor(state);
          if (options.onCancel) options.onCancel();
        }
      }
      event.stopPropagation();
    });

    options.card.classList.add("is-editing-diagram");
    options.card.appendChild(state.root);
    // Force the first layout synchronously. Besides making the editor feel
    // immediate, this also keeps it functional in background/offscreen web
    // views where WebKit is allowed to suspend animation frames.
    if (state.model) layoutState(state);
    setMode(state, state.mode, true);
    if (!parsed.ok) showStatus(state, parsed.reason, "warning");
    return state;
  }

  function setExpanded(state, expanded) {
    if (state.expanded === expanded) return;
    state.expanded = expanded;
    state.root.classList.toggle("is-workspace-expanded", expanded);
    document.documentElement.classList.toggle("diagram-editor-expanded", expanded);
    state.expandButton.setAttribute("aria-pressed", expanded ? "true" : "false");
    state.expandButton.setAttribute(
      "aria-label",
      expanded ? "Return editor to document" : "Expand editor to workspace"
    );
    state.expandButton.title = expanded ? "Return to document (Esc)" : "Expand to workspace";
    if (state.model && state.mode === "visual") {
      layoutState(state);
      renderGraph(state);
    }
  }

  function setMode(state, mode, initial) {
    if (mode === "visual" && state.mode !== "visual") {
      const parsed = parseFlowchart(state.code.value);
      if (!parsed.ok) {
        showStatus(state, parsed.reason, "warning");
        state.code.focus();
        return false;
      }
      state.model = parsed.model;
      state.nextEdge = state.model.edges.length + 1;
      state.selectedID = "";
      state.selectedType = "";
      layoutState(state);
    } else if (mode === "code" && state.mode === "visual" && state.model) {
      state.code.value = serializeFlowchart(state.model);
    }
    state.mode = mode;
    state.root.dataset.mode = mode;
    state.root.querySelectorAll("[data-diagram-mode]").forEach((button) => {
      const selected = button.dataset.diagramMode === mode;
      button.classList.toggle("is-selected", selected);
      button.setAttribute("aria-selected", selected ? "true" : "false");
    });
    state.root.querySelector(".diagram-visual-actions").hidden = mode !== "visual";
    clearStatus(state);
    if (mode === "visual") {
      state.direction.value = state.model.direction;
      renderGraph(state);
      if (!initial) state.canvas.focus();
    } else if (!initial) {
      state.code.focus();
    }
    return true;
  }

  function layoutState(state) {
    const available = Math.max(620, state.canvas.clientWidth || 700);
    const availableHeight = Math.max(360, state.canvas.clientHeight || 360);
    state.stageSize = autoLayout(state.model, available, availableHeight);
  }

  function renderGraph(state) {
    if (!state.model || state.mode !== "visual") return;
    state.stage.style.width = state.stageSize.width + "px";
    state.stage.style.height = state.stageSize.height + "px";
    state.edgeLayer.setAttribute("width", state.stageSize.width);
    state.edgeLayer.setAttribute("height", state.stageSize.height);
    state.edgeLayer.setAttribute("viewBox", "0 0 " + state.stageSize.width + " " + state.stageSize.height);
    renderEdges(state);
    renderNodes(state);
    renderProperties(state);
  }

  function renderEdges(state) {
    state.edgeLayer.replaceChildren();
    const definitions = svgElement("defs");
    const marker = svgElement("marker", {
      id: "diagram-editor-arrow",
      viewBox: "0 0 10 10",
      refX: "8.4",
      refY: "5",
      markerWidth: "7",
      markerHeight: "7",
      orient: "auto-start-reverse",
    });
    marker.appendChild(svgElement("path", { d: "M 0 0 L 10 5 L 0 10 z" }));
    definitions.appendChild(marker);
    state.edgeLayer.appendChild(definitions);
    const nodeByID = new Map(state.model.nodes.map((node) => [node.id, node]));
    state.model.edges.forEach((edge) => {
      const from = nodeByID.get(edge.from);
      const to = nodeByID.get(edge.to);
      if (!from || !to) return;
      const geometry = edgePath(from, to);
      const group = svgElement("g", {
        class:
          "diagram-edge " +
          (edgeKinds[edge.kind] || edgeKinds["-->"]).className +
          (state.selectedType === "edge" && state.selectedID === edge.id ? " is-selected" : ""),
        "data-edge-id": edge.id,
      });
      const visible = svgElement("path", { class: "diagram-edge-path", d: geometry.d });
      if (edge.kind !== "---") visible.setAttribute("marker-end", "url(#diagram-editor-arrow)");
      const hit = svgElement("path", { class: "diagram-edge-hit", d: geometry.d });
      group.append(visible, hit);
      if (edge.label) {
        const label = svgElement("text", {
          class: "diagram-edge-label",
          x: geometry.labelX,
          y: geometry.labelY,
          "text-anchor": "middle",
        });
        label.textContent = edge.label;
        group.appendChild(label);
      }
      hit.addEventListener("click", (event) => {
        event.stopPropagation();
        clearStatus(state);
        state.selectedType = "edge";
        state.selectedID = edge.id;
        state.connectingFrom = "";
        renderGraph(state);
      });
      state.edgeLayer.appendChild(group);
    });
    if (state.pointerConnection) {
      const from = nodeByID.get(state.pointerConnection.from);
      if (from) {
        const metrics = nodeMetrics(from);
        const startX = from.x + metrics.width / 2;
        const startY = from.y + metrics.height / 2;
        state.edgeLayer.appendChild(
          svgElement("path", {
            class: "diagram-edge-path is-connecting",
            d:
              "M " +
              startX +
              " " +
              startY +
              " L " +
              state.pointerConnection.x +
              " " +
              state.pointerConnection.y,
            "marker-end": "url(#diagram-editor-arrow)",
          })
        );
      }
    }
  }

  function renderNodes(state) {
    state.nodeLayer.replaceChildren();
    state.model.nodes.forEach((node) => {
      const metrics = nodeMetrics(node);
      const button = element("button", "diagram-node", node.label || node.id);
      button.type = "button";
      button.dataset.nodeId = node.id;
      button.dataset.shape = node.shape;
      button.style.left = node.x + "px";
      button.style.top = node.y + "px";
      button.style.width = metrics.width + "px";
      button.style.height = metrics.height + "px";
      button.title = node.id + " — drag to move";
      if (state.selectedType === "node" && state.selectedID === node.id) {
        button.classList.add("is-selected");
        const handle = element("span", "diagram-connect-handle", "+");
        handle.setAttribute("aria-label", "Drag to connect this node");
        handle.title = "Drag to another node to connect";
        button.appendChild(handle);
        handle.addEventListener("pointerdown", (event) => beginConnection(state, node, handle, event));
      }
      button.addEventListener("click", (event) => {
        event.stopPropagation();
        if (state.connectingFrom && state.connectingFrom !== node.id) {
          addEdge(state, state.connectingFrom, node.id);
          state.connectingFrom = "";
          return;
        }
        clearStatus(state);
        state.selectedType = "node";
        state.selectedID = node.id;
        renderGraph(state);
      });
      button.addEventListener("dblclick", (event) => {
        event.stopPropagation();
        state.selectedType = "node";
        state.selectedID = node.id;
        renderGraph(state);
        const input = state.properties.querySelector("[data-node-label]");
        if (input) input.focus();
      });
      button.addEventListener("pointerdown", (event) => {
        if (event.target.closest(".diagram-connect-handle") || event.button !== 0) return;
        beginNodeDrag(state, node, button, event);
      });
      state.nodeLayer.appendChild(button);
    });
  }

  function beginNodeDrag(state, node, button, event) {
    event.preventDefault();
    state.selectedType = "node";
    state.selectedID = node.id;
    const start = { x: event.clientX, y: event.clientY, nodeX: node.x, nodeY: node.y };
    button.setPointerCapture(event.pointerId);
    button.classList.add("is-dragging");
    const move = (moveEvent) => {
      const metrics = nodeMetrics(node);
      node.x = clamp(start.nodeX + moveEvent.clientX - start.x, 12, state.stageSize.width - metrics.width - 12);
      node.y = clamp(start.nodeY + moveEvent.clientY - start.y, 12, state.stageSize.height - metrics.height - 12);
      button.style.left = node.x + "px";
      button.style.top = node.y + "px";
      renderEdges(state);
    };
    const finish = () => {
      button.classList.remove("is-dragging");
      button.removeEventListener("pointermove", move);
      button.removeEventListener("pointerup", finish);
      button.removeEventListener("pointercancel", finish);
      renderGraph(state);
    };
    button.addEventListener("pointermove", move);
    button.addEventListener("pointerup", finish);
    button.addEventListener("pointercancel", finish);
  }

  function pointerInStage(state, event) {
    const rect = state.stage.getBoundingClientRect();
    return {
      x: clamp(event.clientX - rect.left, 0, state.stageSize.width),
      y: clamp(event.clientY - rect.top, 0, state.stageSize.height),
    };
  }

  function beginConnection(state, node, handle, event) {
    event.preventDefault();
    event.stopPropagation();
    const point = pointerInStage(state, event);
    state.pointerConnection = { from: node.id, x: point.x, y: point.y };
    handle.setPointerCapture(event.pointerId);
    const move = (moveEvent) => {
      const next = pointerInStage(state, moveEvent);
      state.pointerConnection.x = next.x;
      state.pointerConnection.y = next.y;
      renderEdges(state);
    };
    const finish = (finishEvent) => {
      const target = document.elementFromPoint(finishEvent.clientX, finishEvent.clientY);
      const targetNode = target && target.closest(".diagram-node");
      if (targetNode && targetNode.dataset.nodeId !== node.id) {
        addEdge(state, node.id, targetNode.dataset.nodeId);
      }
      state.pointerConnection = null;
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", finish);
      handle.removeEventListener("pointercancel", finish);
      renderGraph(state);
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", finish);
    handle.addEventListener("pointercancel", finish);
    renderEdges(state);
  }

  function renderProperties(state) {
    state.properties.replaceChildren();
    if (state.selectedType === "node") {
      const node = state.model.nodes.find((item) => item.id === state.selectedID);
      if (!node) return renderPropertiesEmpty(state);
      const heading = element("div", "diagram-properties-title", "Node " + node.id);
      const label = element("label", "diagram-property-field", "Label");
      const input = element("input");
      input.type = "text";
      input.value = node.label;
      input.dataset.nodeLabel = "";
      label.appendChild(input);
      const shapeLabel = element("label", "diagram-property-field", "Shape");
      const select = element("select");
      Object.keys(shapes).forEach((key) => {
        const option = element("option", "", shapes[key].title);
        option.value = key;
        option.selected = key === node.shape;
        select.appendChild(option);
      });
      shapeLabel.appendChild(select);
      const actions = element("div", "diagram-property-actions");
      const connect = element("button", "", "Connect…");
      const duplicate = element("button", "", "Duplicate");
      const remove = element("button", "is-destructive", "Delete");
      [connect, duplicate, remove].forEach((button) => {
        button.type = "button";
        actions.appendChild(button);
      });
      input.addEventListener("input", () => {
        node.label = input.value;
        renderNodes(state);
        renderEdges(state);
      });
      select.addEventListener("change", () => {
        node.shape = select.value;
        renderNodes(state);
        renderEdges(state);
      });
      connect.addEventListener("click", () => {
        state.connectingFrom = node.id;
        showStatus(state, "Click another node to create a connection.", "info");
        renderGraph(state);
      });
      duplicate.addEventListener("click", () => duplicateNode(state, node));
      remove.addEventListener("click", () => deleteSelection(state));
      state.properties.append(heading, label, shapeLabel, actions);
    } else if (state.selectedType === "edge") {
      const edge = state.model.edges.find((item) => item.id === state.selectedID);
      if (!edge) return renderPropertiesEmpty(state);
      const heading = element("div", "diagram-properties-title", edge.from + " → " + edge.to);
      const label = element("label", "diagram-property-field", "Label (optional)");
      const input = element("input");
      input.type = "text";
      input.value = edge.label;
      label.appendChild(input);
      const styleLabel = element("label", "diagram-property-field", "Connection");
      const select = element("select");
      Object.keys(edgeKinds).forEach((key) => {
        const option = element("option", "", edgeKinds[key].title);
        option.value = key;
        option.selected = key === edge.kind;
        select.appendChild(option);
      });
      styleLabel.appendChild(select);
      const actions = element("div", "diagram-property-actions");
      const remove = element("button", "is-destructive", "Delete connection");
      remove.type = "button";
      actions.appendChild(remove);
      input.addEventListener("input", () => {
        edge.label = input.value;
        renderEdges(state);
      });
      select.addEventListener("change", () => {
        edge.kind = select.value;
        renderEdges(state);
      });
      remove.addEventListener("click", () => deleteSelection(state));
      state.properties.append(heading, label, styleLabel, actions);
    } else {
      renderPropertiesEmpty(state);
    }
  }

  function renderPropertiesEmpty(state) {
    const heading = element("div", "diagram-properties-title", "Flowchart");
    const hint = element(
      "p",
      "diagram-properties-hint",
      state.model.nodes.length
        ? "Select a node or connection. Drag the + handle to connect nodes. The saved diagram uses automatic layout."
        : "Add a node to start your flowchart."
    );
    state.properties.append(heading, hint);
  }

  function uniqueNodeID(state) {
    const existing = new Set(state.model.nodes.map((node) => node.id));
    let index = 1;
    while (existing.has("N" + index)) index += 1;
    return "N" + index;
  }

  function addNode(state) {
    const id = uniqueNodeID(state);
    const metrics = nodeMetrics({ label: "New step" });
    const node = {
      id: id,
      label: "New step",
      shape: "rectangle",
      x: clamp(state.canvas.scrollLeft + state.canvas.clientWidth / 2 - metrics.width / 2, 12, state.stageSize.width - metrics.width - 12),
      y: clamp(state.canvas.scrollTop + state.canvas.clientHeight / 2 - metrics.height / 2, 12, state.stageSize.height - metrics.height - 12),
    };
    state.model.nodes.push(node);
    state.selectedType = "node";
    state.selectedID = id;
    clearStatus(state);
    renderGraph(state);
    const input = state.properties.querySelector("[data-node-label]");
    if (input) {
      input.select();
      input.focus();
    }
  }

  function duplicateNode(state, node) {
    const id = uniqueNodeID(state);
    const copy = {
      id: id,
      label: node.label + " copy",
      shape: node.shape,
      x: clamp(node.x + 32, 12, state.stageSize.width - nodeMetrics(node).width - 12),
      y: clamp(node.y + 32, 12, state.stageSize.height - nodeMetrics(node).height - 12),
    };
    state.model.nodes.push(copy);
    state.selectedID = id;
    renderGraph(state);
  }

  function addEdge(state, from, to) {
    const edge = {
      id: "edge-" + state.nextEdge++,
      from: from,
      to: to,
      label: "",
      kind: "-->",
    };
    state.model.edges.push(edge);
    state.selectedType = "edge";
    state.selectedID = edge.id;
    state.connectingFrom = "";
    clearStatus(state);
    renderGraph(state);
  }

  function deleteSelection(state) {
    if (state.selectedType === "node") {
      state.model.nodes = state.model.nodes.filter((node) => node.id !== state.selectedID);
      state.model.edges = state.model.edges.filter(
        (edge) => edge.from !== state.selectedID && edge.to !== state.selectedID
      );
    } else if (state.selectedType === "edge") {
      state.model.edges = state.model.edges.filter((edge) => edge.id !== state.selectedID);
    }
    state.selectedType = "";
    state.selectedID = "";
    state.connectingFrom = "";
    renderGraph(state);
  }

  function showStatus(state, message, kind) {
    state.status.hidden = false;
    state.status.dataset.kind = kind || "info";
    state.status.textContent = message;
  }

  function clearStatus(state) {
    state.status.hidden = true;
    state.status.textContent = "";
    state.status.removeAttribute("data-kind");
  }

  async function applyEditor(state) {
    const source = state.mode === "visual" ? serializeFlowchart(state.model) : state.code.value;
    const button = state.root.querySelector("[data-diagram-apply]");
    button.disabled = true;
    try {
      if (window.mermaid && typeof window.mermaid.parse === "function") {
        await window.mermaid.parse(source);
      }
    } catch (error) {
      const message = error && error.message ? error.message.split("\n")[0] : "Invalid diagram syntax.";
      showStatus(state, "Could not apply: " + message, "error");
      button.disabled = false;
      return;
    }
    closeEditor(state);
    if (state.options.onApply) state.options.onApply(source);
  }

  function closeEditor(state) {
    if (!state || !state.root) return;
    document.documentElement.classList.remove("diagram-editor-expanded");
    state.expanded = false;
    state.options.card.classList.remove("is-editing-diagram");
    state.root.remove();
    if (activeEditor === state) activeEditor = null;
  }

  function open(options) {
    if (!options || !options.card) return null;
    if (activeEditor) closeEditor(activeEditor);
    const parsed = parseFlowchart(options.source || "");
    activeEditor = createEditor(options, parsed);
    return activeEditor;
  }

  window.PreviewMDDiagramEditor = {
    open: open,
    close: function () {
      if (activeEditor) closeEditor(activeEditor);
    },
    parse: parseFlowchart,
    serialize: serializeFlowchart,
  };
})();
