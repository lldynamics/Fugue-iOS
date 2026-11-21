package com.iosbox.app.ui.chat

import java.util.Base64

/**
 * Builds hardened offline HTML documents for HTML / SVG / Mermaid artifacts,
 * matching iOS `ArtifactDocumentBuilder` CSP & WebRTC lockdown rules.
 */
object ArtifactDocumentBuilder {
    val previewableLanguages: Set<String> = setOf("html", "htm", "svg", "mermaid")

    fun isPreviewable(language: String): Boolean =
        previewableLanguages.contains(language.trim().lowercase())

    fun allowsJavaScript(language: String): Boolean =
        language.trim().lowercase() != "svg"

    private const val SCRIPT_CSP =
        """<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; media-src data:; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; worker-src 'none'; child-src 'none'; base-uri 'none';"><meta http-equiv="x-dns-prefetch-control" content="off">"""

    private const val NO_SCRIPT_CSP =
        """<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; media-src data:; connect-src 'none'; form-action 'none'; worker-src 'none'; child-src 'none'; base-uri 'none';"><meta http-equiv="x-dns-prefetch-control" content="off">"""

    const val WEBRTC_GUARD_JS: String =
        "try{Object.defineProperty(window,'RTCPeerConnection',{value:undefined,configurable:false,writable:false});Object.defineProperty(window,'webkitRTCPeerConnection',{value:undefined,configurable:false,writable:false});}catch(_){}"

    private const val WEBRTC_GUARD_SCRIPT = "<script>$WEBRTC_GUARD_JS</script>"

    private val LEADING_COMMENTS_REGEX = Regex("^\\s*(?:<!--[\\s\\S]*?-->\\s*)+")
    private val DOCTYPE_REGEX = Regex("^\\s*<!doctype\\b[^>]*>", RegexOption.IGNORE_CASE)
    private val SVG_SCRIPT_PAIRED_REGEX = Regex("<script\\b[^>]*>.*?</script\\s*>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    private val SVG_SCRIPT_OPEN_CLOSE_REGEX = Regex("</?script\\b[^>]*>", RegexOption.IGNORE_CASE)

    fun injectHeadPolicy(rawHTML: String, policy: String): String {
        var remainder = LEADING_COMMENTS_REGEX.replaceFirst(rawHTML, "")
        val doctypeMatch = DOCTYPE_REGEX.find(remainder)
        if (doctypeMatch != null) {
            remainder = remainder.substring(doctypeMatch.range.last + 1)
        }
        return "<!doctype html><head>$policy</head>$remainder"
    }

    fun htmlDocument(language: String, code: String): String {
        return when (language.trim().lowercase()) {
            "html", "htm" -> {
                val lower = code.lowercase()
                if (lower.contains("<html") || lower.contains("<!doctype")) {
                    injectHeadPolicy(code, SCRIPT_CSP + WEBRTC_GUARD_SCRIPT)
                } else {
                    """
                    <!doctype html>
                    <html>
                    <head>
                    $SCRIPT_CSP
                    $WEBRTC_GUARD_SCRIPT
                    <meta name="viewport" content="width=device-width, initial-scale=1.0">
                    <style>
                    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, Roboto, sans-serif; }
                    body { margin: 16px; line-height: 1.5; }
                    </style>
                    </head>
                    <body>
                    $code
                    </body>
                    </html>
                    """.trimIndent()
                }
            }

            "svg" -> {
                val noPaired = SVG_SCRIPT_PAIRED_REGEX.replace(code, "")
                val sanitizedSVG = SVG_SCRIPT_OPEN_CLOSE_REGEX.replace(noPaired, "")
                val svgBase64 = Base64.getEncoder().encodeToString(sanitizedSVG.toByteArray(Charsets.UTF_8))
                """
                <!doctype html>
                <html>
                <head>
                $NO_SCRIPT_CSP
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>
                :root { color-scheme: light dark; }
                html, body { margin: 0; padding: 12px; display: flex; justify-content: center; align-items: flex-start; min-height: 100vh; box-sizing: border-box; }
                img { max-width: 100%; height: auto; }
                </style>
                </head>
                <body>
                <img src="data:image/svg+xml;base64,$svgBase64" alt="SVG Preview" />
                </body>
                </html>
                """.trimIndent()
            }

            "mermaid" -> {
                val escaped = code
                    .replace("&", "&amp;")
                    .replace("<", "&lt;")
                    .replace(">", "&gt;")
                """
                <!doctype html>
                <html>
                <head>
                $SCRIPT_CSP
                $WEBRTC_GUARD_SCRIPT
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>
                :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, Roboto, sans-serif; }
                body { margin: 14px; background: transparent; color: #1c1c1e; }
                @media (prefers-color-scheme: dark) {
                  body { color: #f2f2f7; }
                  .node-box { fill: #2c2c2e !important; stroke: #6e6eff !important; }
                  .node-text { fill: #f2f2f7 !important; }
                  .edge-line { stroke: #98989d !important; }
                  .edge-label { fill: #d1d1d6 !important; }
                  .edge-bg { fill: #1c1c1e !important; }
                  .seq-actor { fill: #2c2c2e !important; stroke: #6e6eff !important; }
                  .seq-life { stroke: #636366 !important; }
                  .fallback { background: #2c2c2e !important; color: #f2f2f7 !important; }
                }
                svg { width: 100%; height: auto; overflow: visible; }
                .fallback { padding: 12px; border-radius: 10px; background: #f2f2f7; font-family: ui-monospace, monospace; font-size: 12px; white-space: pre-wrap; }
                </style>
                </head>
                <body>
                <div id="diagram"></div>
                <pre id="raw" style="display:none">$escaped</pre>
                <script>
                (function() {
                  const src = document.getElementById('raw').textContent.trim();
                  const lines = src.split(/\r?\n/).map(l => l.trim()).filter(l => l && !l.startsWith('%%'));
                  const mount = document.getElementById('diagram');
                  const svgNS = 'http://www.w3.org/2000/svg';

                  function el(tag, attrs, text) {
                    const n = document.createElementNS(svgNS, tag);
                    for (const [k, v] of Object.entries(attrs || {})) n.setAttribute(k, String(v));
                    if (text !== undefined) n.textContent = text;
                    return n;
                  }

                  function renderFallback() {
                    const pre = document.createElement('pre');
                    pre.className = 'fallback';
                    pre.textContent = src;
                    mount.appendChild(pre);
                  }

                  if (!lines.length) { renderFallback(); return; }

                  if (/^sequenceDiagram\b/i.test(lines[0])) {
                    const actors = [];
                    const actorLabels = {};
                    const msgs = [];
                    function addActor(id, label) {
                      if (!id) return;
                      if (!actors.includes(id)) actors.push(id);
                      if (label) actorLabels[id] = label.trim();
                      else if (!actorLabels[id]) actorLabels[id] = id;
                    }
                    for (const line of lines.slice(1)) {
                      const p = line.match(/^(?:participant|actor)\s+([^\s]+)(?:\s+as\s+(.+))?$/i);
                      if (p) { addActor(p[1].trim(), p[2] ? p[2].trim() : p[1].trim()); continue; }
                      const m = line.match(/^([^\s-]+)\s*(->>|-->>|->|-->)\s*([^:]+):\s*(.*)$/);
                      if (m) {
                        const a = m[1].trim(), b = m[3].trim();
                        addActor(a); addActor(b);
                        msgs.push({ from: a, to: b, dashed: m[2].startsWith('--'), text: m[4].trim() });
                      }
                    }
                    if (!actors.length || !msgs.length) { renderFallback(); return; }
                    const colW = 140, padX = 30, topY = 20, boxH = 34, stepY = 48;
                    const width = Math.max(320, actors.length * colW + padX * 2);
                    const height = topY + boxH + msgs.length * stepY + 40;
                    const svg = el('svg', { viewBox: `0 0 ${'$'}{width} ${'$'}{height}` });
                    const defs = el('defs');
                    const marker = el('marker', { id: 'arrow', markerWidth: 8, markerHeight: 8, refX: 7, refY: 3.5, orient: 'auto' });
                    marker.appendChild(el('path', { d: 'M0,0 L8,3.5 L0,7 Z', fill: '#636366' }));
                    defs.appendChild(marker);
                    svg.appendChild(defs);
                    const xOf = {};
                    actors.forEach((a, i) => {
                      const cx = padX + i * colW + colW / 2;
                      xOf[a] = cx;
                      svg.appendChild(el('rect', { class: 'seq-actor', x: cx - 52, y: topY, width: 104, height: boxH, rx: 8, fill: '#eef2ff', stroke: '#4f46e5', 'stroke-width': 1.5 }));
                      svg.appendChild(el('text', { class: 'node-text', x: cx, y: topY + 21, 'text-anchor': 'middle', 'font-size': 12, 'font-weight': 600, fill: '#1c1c1e' }, (actorLabels[a] || a).slice(0, 14)));
                      svg.appendChild(el('line', { class: 'seq-life', x1: cx, y1: topY + boxH, x2: cx, y2: height - 16, stroke: '#c7c7cc', 'stroke-dasharray': '4,4' }));
                    });
                    msgs.forEach((m, idx) => {
                      const y = topY + boxH + 34 + idx * stepY;
                      const x1 = xOf[m.from], x2 = xOf[m.to];
                      svg.appendChild(el('line', { class: 'edge-line', x1, y1: y, x2, y2: y, stroke: '#636366', 'stroke-width': 1.5, 'stroke-dasharray': m.dashed ? '5,4' : '', 'marker-end': 'url(#arrow)' }));
                      svg.appendChild(el('text', { class: 'edge-label', x: (x1 + x2) / 2, y: y - 7, 'text-anchor': 'middle', 'font-size': 11, fill: '#3a3a3c' }, m.text.slice(0, 32)));
                    });
                    mount.appendChild(svg);
                    return;
                  }

                  const stateHeader = /^stateDiagram(?:-v2)?\b/i.test(lines[0]);
                  const classHeader = /^classDiagram\b/i.test(lines[0]);
                  const headerMatch = lines[0].match(/^(?:flowchart|graph)\s+(TD|TB|LR|RL|BT)\b/i);
                  if (!headerMatch && !stateHeader && !classHeader) { renderFallback(); return; }
                  const dir = headerMatch ? headerMatch[1].toUpperCase() : 'TD';
                  const horizontal = dir === 'LR' || dir === 'RL';
                  const nodes = new Map();
                  const edges = [];

                  function measureTextWidth(str) {
                    let w = 0;
                    for (const ch of str) { w += ch.charCodeAt(0) > 0x2E7F ? 13.5 : 7.5; }
                    return w;
                  }

                  function ensureNode(id, label, members) {
                    const cleanID = id.trim();
                    if (!cleanID) return '';
                    if (!nodes.has(cleanID)) {
                      nodes.set(cleanID, { id: cleanID, label: label || cleanID, members: members || [], level: 0 });
                    } else {
                      const cur = nodes.get(cleanID);
                      if (label && label !== cleanID) cur.label = label;
                      if (members && members.length) cur.members.push(...members);
                    }
                    return cleanID;
                  }

                  function parseNode(token) {
                    const t = token.trim();
                    if (stateHeader && t === '[*]') return ensureNode('__start_end__', '●');
                    const m = t.match(/^([A-Za-z0-9_\u4e00-\u9fa5]+)\s*(?:\[(.*?)\]|\((.*?)\)|\{(.*?)\})?$/);
                    const id = m ? m[1] : t.replace(/[^A-Za-z0-9_\u4e00-\u9fa5]/g, '_');
                    const rawLabel = (m && (m[2] || m[3] || m[4])) ? (m[2] || m[3] || m[4]) : id;
                    const label = rawLabel.replace(/^["']|["']$/g, '');
                    return ensureNode(id, label);
                  }

                  if (classHeader) {
                    let activeClass = null;
                    for (const line of lines.slice(1)) {
                      if (activeClass) {
                        if (line === '}') { activeClass = null; continue; }
                        ensureNode(activeClass, activeClass, [line]);
                        continue;
                      }
                      const blockStart = line.match(/^class\s+([A-Za-z0-9_\u4e00-\u9fa5]+)\s*\{$/);
                      if (blockStart) { activeClass = ensureNode(blockStart[1], blockStart[1]); continue; }
                      const memberLine = line.match(/^([A-Za-z0-9_\u4e00-\u9fa5]+)\s*:\s*(.+)$/);
                      if (memberLine && !line.includes('--') && !line.includes('..')) {
                        ensureNode(memberLine[1], memberLine[1], [memberLine[2].trim()]);
                        continue;
                      }
                      const rel = line.match(/^([A-Za-z0-9_\u4e00-\u9fa5]+)\s*(?:<\|--|--\|>|\*--|o--|-->|\.\.>|--|\.\.)\s*([A-Za-z0-9_\u4e00-\u9fa5]+)(?:\s*:\s*(.+))?$/);
                      if (rel) {
                        const f = ensureNode(rel[1], rel[1]);
                        const t = ensureNode(rel[2], rel[2]);
                        edges.push({ from: f, to: t, label: (rel[3] || '').trim() });
                      }
                    }
                  } else if (stateHeader) {
                    for (const line of lines.slice(1)) {
                      const alias = line.match(/^state\s+"([^"]+)"\s+as\s+([A-Za-z0-9_\u4e00-\u9fa5]+)$/i);
                      if (alias) { ensureNode(alias[2], alias[1]); continue; }
                      const tr = line.match(/^(\[\*\]|[A-Za-z0-9_\u4e00-\u9fa5]+)\s*-->\s*(\[\*\]|[A-Za-z0-9_\u4e00-\u9fa5]+)(?:\s*:\s*(.+))?$/);
                      if (tr) {
                        const f = parseNode(tr[1]);
                        const t = parseNode(tr[2]);
                        if (f && t) edges.push({ from: f, to: t, label: (tr[3] || '').trim() });
                      }
                    }
                  } else {
                    for (const line of lines.slice(1)) {
                      if (/^(?:subgraph|end|style|classDef|class|click|linkStyle|direction)\b/i.test(line)) continue;
                      const e = line.match(/^(.+?)\s*(?:-->|---|==>|-\.->)\s*(?:\|([^|]+)\|\s*)?(.+)$/);
                      if (e) {
                        const from = parseNode(e[1]);
                        const to = parseNode(e[3]);
                        if (from && to) edges.push({ from, to, label: (e[2] || '').trim() });
                      } else if (/^[A-Za-z0-9_\u4e00-\u9fa5]+\s*[\[\(\{]/.test(line)) {
                        parseNode(line);
                      }
                    }
                  }

                  if (!nodes.size) { renderFallback(); return; }
                  for (let pass = 0; pass < nodes.size; pass++) {
                    for (const e of edges) {
                      const f = nodes.get(e.from), t = nodes.get(e.to);
                      if (f && t && f.id !== t.id && t.level <= f.level) t.level = Math.min(nodes.size, f.level + 1);
                    }
                  }
                  let maxLabelWidth = 132;
                  let maxMemberCount = 0;
                  for (const n of nodes.values()) {
                    maxLabelWidth = Math.max(maxLabelWidth, Math.min(280, measureTextWidth(n.label) + 28));
                    maxMemberCount = Math.max(maxMemberCount, (n.members || []).length);
                  }
                  const levels = new Map();
                  for (const n of nodes.values()) {
                    if (!levels.has(n.level)) levels.set(n.level, []);
                    levels.get(n.level).push(n);
                  }
                  const maxPerLevel = Math.max(...[...levels.values()].map(a => a.length));
                  const boxW = Math.round(maxLabelWidth);
                  const boxH = 42 + Math.min(maxMemberCount, 5) * 16;
                  const gapX = 52, gapY = 48, pad = 24;
                  const sortedLevels = [...levels.keys()].sort((a, b) => a - b);
                  const totalCols = horizontal ? sortedLevels.length : maxPerLevel;
                  const totalRows = horizontal ? maxPerLevel : sortedLevels.length;
                  const width = pad * 2 + totalCols * boxW + Math.max(0, totalCols - 1) * gapX;
                  const height = pad * 2 + totalRows * boxH + Math.max(0, totalRows - 1) * gapY;

                  for (const [lvlIdx, lvl] of sortedLevels.entries()) {
                    const group = levels.get(lvl);
                    group.forEach((n, idx) => {
                      const spanCount = group.length;
                      if (horizontal) {
                        const col = dir === 'RL' ? (sortedLevels.length - 1 - lvlIdx) : lvlIdx;
                        const offset = ((maxPerLevel - spanCount) * (boxH + gapY)) / 2;
                        n.x = pad + col * (boxW + gapX);
                        n.y = pad + offset + idx * (boxH + gapY);
                      } else {
                        const row = dir === 'BT' ? (sortedLevels.length - 1 - lvlIdx) : lvlIdx;
                        const offset = ((maxPerLevel - spanCount) * (boxW + gapX)) / 2;
                        n.x = pad + offset + idx * (boxW + gapX);
                        n.y = pad + row * (boxH + gapY);
                      }
                    });
                  }

                  const svg = el('svg', { viewBox: `0 0 ${'$'}{width} ${'$'}{height}` });
                  const defs = el('defs');
                  const marker = el('marker', { id: 'm-arrow', markerWidth: 8, markerHeight: 8, refX: 7, refY: 3.5, orient: 'auto' });
                  marker.appendChild(el('path', { d: 'M0,0 L8,3.5 L0,7 Z', fill: '#636366' }));
                  defs.appendChild(marker);
                  svg.appendChild(defs);

                  for (const e of edges) {
                    const f = nodes.get(e.from), t = nodes.get(e.to);
                    if (!f || !t) continue;
                    const x1 = horizontal ? f.x + boxW : f.x + boxW / 2;
                    const y1 = horizontal ? f.y + boxH / 2 : f.y + boxH;
                    const x2 = horizontal ? t.x : t.x + boxW / 2;
                    const y2 = horizontal ? t.y + boxH / 2 : t.y;
                    svg.appendChild(el('line', { class: 'edge-line', x1, y1, x2, y2, stroke: '#636366', 'stroke-width': 1.6, 'marker-end': 'url(#m-arrow)' }));
                    if (e.label) {
                      const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
                      const lbl = e.label.slice(0, 26);
                      const lw = Math.max(44, Math.min(180, measureTextWidth(lbl) + 14));
                      svg.appendChild(el('rect', { class: 'edge-bg', x: mx - lw / 2, y: my - 9, width: lw, height: 18, rx: 4, fill: '#ffffff' }));
                      svg.appendChild(el('text', { class: 'edge-label', x: mx, y: my + 4, 'text-anchor': 'middle', 'font-size': 10, fill: '#3a3a3c' }, lbl));
                    }
                  }

                  for (const n of nodes.values()) {
                    svg.appendChild(el('rect', { class: 'node-box', x: n.x, y: n.y, width: boxW, height: boxH, rx: 10, fill: '#eef2ff', stroke: '#4f46e5', 'stroke-width': 1.5 }));
                    const hasMembers = n.members && n.members.length > 0;
                    const titleY = hasMembers ? (n.y + 20) : (n.y + boxH / 2 + 4);
                    svg.appendChild(el('text', { class: 'node-text', x: n.x + boxW / 2, y: titleY, 'text-anchor': 'middle', 'font-size': 12, 'font-weight': hasMembers ? 600 : 500, fill: '#1c1c1e' }, n.label.slice(0, 34)));
                    if (hasMembers) {
                      n.members.slice(0, 5).forEach((mStr, mIdx) => {
                        svg.appendChild(el('text', { class: 'edge-label', x: n.x + 10, y: n.y + 38 + mIdx * 15, 'font-size': 10, fill: '#3a3a3c' }, mStr.slice(0, 34)));
                      });
                    }
                  }
                  mount.appendChild(svg);
                })();
                </script>
                </body>
                </html>
                """.trimIndent()
            }

            else -> code
        }
    }
}
