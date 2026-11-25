import SwiftUI
import WebKit
import UIKit

enum ArtifactDocumentBuilder {
    static let previewableLanguages: Set<String> = ["html", "htm", "svg", "mermaid"]

    static func isPreviewable(language: String) -> Bool {
        previewableLanguages.contains(language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func supportedMermaidDiagramKind(in code: String) -> String? {
        let firstLine = code
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("%%") }
            ?? ""
        let lower = firstLine.lowercased()
        if lower.hasPrefix("sequencediagram") { return "sequenceDiagram" }
        if lower.hasPrefix("statediagram") { return "stateDiagram" }
        if lower.hasPrefix("classdiagram") { return "classDiagram" }
        if lower.hasPrefix("flowchart") || lower.hasPrefix("graph ") { return "flowchart" }
        if lower == "pie" || lower.hasPrefix("pie ") { return "pie" }
        if lower == "gantt" || lower.hasPrefix("gantt ") { return "gantt" }
        if lower.hasPrefix("erdiagram") { return "erDiagram" }
        if lower == "mindmap" || lower.hasPrefix("mindmap ") { return "mindmap" }
        return nil
    }

    private static let scriptCSP = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; media-src data:; script-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; worker-src 'none'; child-src 'none'; base-uri 'none';"><meta http-equiv="x-dns-prefetch-control" content="off">"#
    private static let noScriptCSP = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:; media-src data:; connect-src 'none'; form-action 'none'; worker-src 'none'; child-src 'none'; base-uri 'none';"><meta http-equiv="x-dns-prefetch-control" content="off">"#
    static let webrtcGuardJS = #"try{Object.defineProperty(window,'RTCPeerConnection',{value:undefined,configurable:false,writable:false});Object.defineProperty(window,'webkitRTCPeerConnection',{value:undefined,configurable:false,writable:false});}catch(_){}"#
    private static let webrtcGuardScript = "<script>\(webrtcGuardJS)</script>"

    static func allowsJavaScript(for language: String) -> Bool {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "svg"
    }

    /// Prepends `<head>` policy right after an optional leading `<!doctype html>` while stripping
    /// leading HTML comments, ensuring neither `<!-- <head> -->` comments nor pre-`<head>` `<script>`
    /// tags can ever bypass or precede CSP and WebRTC lockdown.
    private static func injectHeadPolicy(_ rawHTML: String, policy: String) -> String {
        var remainder = rawHTML
        if let leadingComments = try? NSRegularExpression(pattern: #"^\s*(?:<!--[\s\S]*?-->\s*)+"#),
           let match = leadingComments.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
           let range = Range(match.range, in: remainder) {
            remainder.removeSubrange(range)
        }
        if let doctype = try? NSRegularExpression(pattern: #"^\s*<!doctype\b[^>]*>"#, options: [.caseInsensitive]),
           let match = doctype.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
           let range = Range(match.range, in: remainder) {
            let afterDoctype = String(remainder[range.upperBound...])
            return "<!doctype html><head>\(policy)</head>" + afterDoctype
        }
        return "<!doctype html><head>\(policy)</head>" + remainder
    }

    static func htmlDocument(language: String, code: String) -> String {
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lang {
        case "html", "htm":
            let lower = code.lowercased()
            if lower.contains("<html") || lower.contains("<!doctype") {
                return injectHeadPolicy(code, policy: scriptCSP + webrtcGuardScript)
            }
            return """
            <!doctype html>
            <html>
            <head>
            \(scriptCSP)
            \(webrtcGuardScript)
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 16px; line-height: 1.5; }
            </style>
            </head>
            <body>
            \(code)
            </body>
            </html>
            """

        case "svg":
            var sanitizedSVG = code
            if let pairedScript = try? NSRegularExpression(pattern: #"(?is)<script\b[^>]*>.*?</script\s*>"#) {
                sanitizedSVG = pairedScript.stringByReplacingMatches(
                    in: sanitizedSVG,
                    range: NSRange(sanitizedSVG.startIndex..., in: sanitizedSVG),
                    withTemplate: ""
                )
            }
            if let selfClosingOrOpenScript = try? NSRegularExpression(pattern: #"(?is)</?script\b[^>]*>"#) {
                sanitizedSVG = selfClosingOrOpenScript.stringByReplacingMatches(
                    in: sanitizedSVG,
                    range: NSRange(sanitizedSVG.startIndex..., in: sanitizedSVG),
                    withTemplate: ""
                )
            }
            let svgBase64 = Data(sanitizedSVG.utf8).base64EncodedString()
            return """
            <!doctype html>
            <html>
            <head>
            \(noScriptCSP)
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; padding: 12px; display: flex; justify-content: center; align-items: flex-start; min-height: 100vh; box-sizing: border-box; }
            img { max-width: 100%; height: auto; }
            </style>
            </head>
            <body>
            <img src="data:image/svg+xml;base64,\(svgBase64)" alt="SVG Preview" />
            </body>
            </html>
            """

        case "mermaid":
            let escaped = code
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return """
            <!doctype html>
            <html>
            <head>
            \(scriptCSP)
            \(webrtcGuardScript)
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
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
              .subgraph-box { fill: rgba(110,110,255,0.08) !important; stroke: #6e6eff !important; }
              .gantt-row-alt { fill: rgba(255,255,255,0.04) !important; }
              .fallback { background: #2c2c2e !important; color: #f2f2f7 !important; }
            }
            svg { width: 100%; height: auto; overflow: visible; }
            .fallback { padding: 12px; border-radius: 10px; background: #f2f2f7; font-family: ui-monospace, monospace; font-size: 12px; white-space: pre-wrap; }
            </style>
            </head>
            <body>
            <div id="diagram"></div>
            <pre id="raw" style="display:none">\(escaped)</pre>
            <script>
            (function() {
              const src = document.getElementById('raw').textContent.trim();
              const rawLines = src.split(/\\r?\\n/).filter(l => l.trim() && !l.trim().startsWith('%%'));
              const lines = rawLines.map(l => l.trim());
              const mount = document.getElementById('diagram');
              const svgNS = 'http://www.w3.org/2000/svg';
              const palette = ['#4f46e5', '#0ea5e9', '#10b981', '#f59e0b', '#ec4899', '#8b5cf6', '#14b8a6', '#ef4444'];

              function el(tag, attrs, text) {
                const n = document.createElementNS(svgNS, tag);
                if (tag === 'svg') {
                  n.setAttribute('xmlns', svgNS);
                }
                for (const [k, v] of Object.entries(attrs || {})) n.setAttribute(k, String(v));
                if (text !== undefined) n.textContent = text;
                return n;
              }

              function measureTextWidth(str) {
                let w = 0;
                for (const ch of String(str || '')) { w += ch.charCodeAt(0) > 0x2E7F ? 13.5 : 7.5; }
                return w;
              }

              function renderFallback() {
                const pre = document.createElement('pre');
                pre.className = 'fallback';
                pre.textContent = src;
                mount.appendChild(pre);
              }

              if (!lines.length) { renderFallback(); return; }

              // 1. Pie Chart
              if (/^pie\\b/i.test(lines[0])) {
                let title = '';
                const items = [];
                for (const line of lines.slice(1)) {
                  const tm = line.match(/^title\\s+(.+)$/i);
                  if (tm) { title = tm[1].trim(); continue; }
                  const kv = line.match(/^"([^"]+)"\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)$/);
                  if (kv) {
                    const val = parseFloat(kv[2]);
                    if (isFinite(val) && val > 0) items.push({ label: kv[1], value: val });
                  }
                }
                if (!items.length) { renderFallback(); return; }
                const total = items.reduce((s, x) => s + x.value, 0);
                const r = 92, cx = 128, cy = (title ? 136 : 114);
                const legendX = 246;
                const width = 460;
                const height = Math.max(cy + r + 24, (title ? 58 : 34) + items.length * 24 + 24);
                const svg = el('svg', { viewBox: `0 0 ${width} ${height}` });
                if (title) {
                  svg.appendChild(el('text', { class: 'node-text', x: width / 2, y: 24, 'text-anchor': 'middle', 'font-size': 14, 'font-weight': 600, fill: '#1c1c1e' }, title.slice(0, 42)));
                }
                let angle = -Math.PI / 2;
                items.forEach((item, idx) => {
                  const frac = item.value / total;
                  const sweep = frac * Math.PI * 2;
                  const color = palette[idx % palette.length];
                  if (items.length === 1) {
                    svg.appendChild(el('circle', { cx, cy, r, fill: color }));
                  } else {
                    const x1 = cx + r * Math.cos(angle), y1 = cy + r * Math.sin(angle);
                    const x2 = cx + r * Math.cos(angle + sweep), y2 = cy + r * Math.sin(angle + sweep);
                    const large = sweep > Math.PI ? 1 : 0;
                    const d = `M ${cx} ${cy} L ${x1.toFixed(2)} ${y1.toFixed(2)} A ${r} ${r} 0 ${large} 1 ${x2.toFixed(2)} ${y2.toFixed(2)} Z`;
                    svg.appendChild(el('path', { d, fill: color, stroke: '#ffffff', 'stroke-width': 1.5 }));
                  }
                  const ly = (title ? 54 : 30) + idx * 24;
                  svg.appendChild(el('rect', { x: legendX, y: ly - 10, width: 12, height: 12, rx: 3, fill: color }));
                  const pct = Math.round(frac * 100);
                  svg.appendChild(el('text', { class: 'node-text', x: legendX + 18, y: ly, 'font-size': 11.5, fill: '#1c1c1e' }, `${item.label.slice(0, 18)} (${pct}%)`));
                  angle += sweep;
                });
                mount.appendChild(svg);
                return;
              }

              // 2. Gantt Chart
              if (/^gantt\\b/i.test(lines[0])) {
                let title = '';
                let section = '';
                const tasks = [];
                let cursorDay = 0;
                for (const line of lines.slice(1)) {
                  const tm = line.match(/^title\\s+(.+)$/i);
                  if (tm) { title = tm[1].trim(); continue; }
                  const sm = line.match(/^section\\s+(.+)$/i);
                  if (sm) { section = sm[1].trim(); continue; }
                  if (/^(?:dateFormat|axisFormat|excludes|todayMarker|tickInterval)\\b/i.test(line)) continue;
                  const colon = line.indexOf(':');
                  if (colon > 0) {
                    const name = line.slice(0, colon).trim();
                    const rest = line.slice(colon + 1).trim();
                    const durMatch = rest.match(/(\\d+)\\s*([dwmh])/i);
                    let dur = durMatch ? parseInt(durMatch[1], 10) : 3;
                    if (durMatch && durMatch[2].toLowerCase() === 'w') dur *= 7;
                    dur = Math.max(1, Math.min(dur, 60));
                    const isDone = /\\bdone\\b/i.test(rest);
                    const isCrit = /\\bcrit\\b/i.test(rest);
                    tasks.push({ section, name, start: cursorDay, duration: dur, isDone, isCrit });
                    cursorDay += Math.max(1, Math.round(dur * 0.75));
                  }
                }
                if (!tasks.length) { renderFallback(); return; }
                const maxEnd = Math.max(...tasks.map(t => t.start + t.duration), 5);
                const labelW = 136, chartW = 290, pad = 18, rowH = 28;
                const topY = title ? 42 : 18;
                const width = pad * 2 + labelW + chartW;
                const height = topY + tasks.length * rowH + 24;
                const svg = el('svg', { viewBox: `0 0 ${width} ${height}` });
                if (title) {
                  svg.appendChild(el('text', { class: 'node-text', x: width / 2, y: 22, 'text-anchor': 'middle', 'font-size': 14, 'font-weight': 600, fill: '#1c1c1e' }, title.slice(0, 44)));
                }
                tasks.forEach((t, idx) => {
                  const y = topY + idx * rowH;
                  if (idx % 2 === 1) {
                    svg.appendChild(el('rect', { class: 'gantt-row-alt', x: pad, y, width: labelW + chartW, height: rowH, rx: 4, fill: '#f7f7fa' }));
                  }
                  svg.appendChild(el('text', { class: 'node-text', x: pad + 6, y: y + 18, 'font-size': 11, fill: '#1c1c1e' }, t.name.slice(0, 18)));
                  const bx = pad + labelW + (t.start / maxEnd) * chartW;
                  const bw = Math.max(14, (t.duration / maxEnd) * chartW);
                  const fill = t.isCrit ? '#ef4444' : (t.isDone ? '#10b981' : palette[idx % palette.length]);
                  svg.appendChild(el('rect', { x: bx, y: y + 5, width: bw, height: 18, rx: 5, fill }));
                });
                mount.appendChild(svg);
                return;
              }

              // 3. Mindmap
              if (/^mindmap\\b/i.test(lines[0])) {
                const nodes = [];
                const stack = [];
                for (const raw of rawLines.slice(1)) {
                  const indent = raw.match(/^(\\s*)/)[1].length;
                  let text = raw.trim().replace(/^root\\s*/i, '').replace(/^[(\\[\\{]+|[)\\]\\}]+$/g, '').trim();
                  if (!text) continue;
                  while (stack.length && stack[stack.length - 1].indent >= indent) stack.pop();
                  const parent = stack.length ? stack[stack.length - 1] : null;
                  const node = { text, indent, depth: parent ? parent.depth + 1 : 0, parent, children: [], branchIdx: 0 };
                  if (parent) {
                    if (parent.depth === 0) node.branchIdx = parent.children.length;
                    else node.branchIdx = parent.branchIdx;
                    parent.children.push(node);
                  }
                  stack.push(node);
                  nodes.push(node);
                }
                if (!nodes.length) { renderFallback(); return; }
                const root = nodes[0];
                let leafY = 0;
                const rowGap = 36, colGap = 150, pad = 24;
                function layout(n) {
                  if (!n.children.length) {
                    n.y = pad + leafY * rowGap;
                    leafY++;
                  } else {
                    n.children.forEach(layout);
                    n.y = (n.children[0].y + n.children[n.children.length - 1].y) / 2;
                  }
                  n.w = Math.max(76, Math.min(136, measureTextWidth(n.text) + 22));
                  n.x = pad + n.depth * colGap;
                }
                layout(root);
                const maxDepth = Math.max(...nodes.map(n => n.depth));
                const width = pad * 2 + (maxDepth + 1) * colGap;
                const height = Math.max(120, pad * 2 + Math.max(1, leafY) * rowGap);
                const svg = el('svg', { viewBox: `0 0 ${width} ${height}` });
                for (const n of nodes) {
                  if (n.parent) {
                    const x1 = n.parent.x + n.parent.w, y1 = n.parent.y + 14;
                    const x2 = n.x, y2 = n.y + 14;
                    const mx = (x1 + x2) / 2;
                    const col = palette[n.branchIdx % palette.length];
                    svg.appendChild(el('path', { d: `M ${x1} ${y1} C ${mx} ${y1}, ${mx} ${y2}, ${x2} ${y2}`, fill: 'none', stroke: col, 'stroke-width': 2 }));
                  }
                }
                for (const n of nodes) {
                  const col = n.depth === 0 ? '#4f46e5' : palette[n.branchIdx % palette.length];
                  svg.appendChild(el('rect', { class: n.depth === 0 ? '' : 'node-box', x: n.x, y: n.y, width: n.w, height: 28, rx: 14, fill: n.depth === 0 ? col : '#eef2ff', stroke: col, 'stroke-width': 1.5 }));
                  svg.appendChild(el('text', { class: n.depth === 0 ? '' : 'node-text', x: n.x + n.w / 2, y: n.y + 18, 'text-anchor': 'middle', 'font-size': 11.5, 'font-weight': n.depth === 0 ? 600 : 500, fill: n.depth === 0 ? '#ffffff' : '#1c1c1e' }, n.text.slice(0, 18)));
                }
                mount.appendChild(svg);
                return;
              }

              // 4. Sequence Diagram
              if (/^sequenceDiagram\\b/i.test(lines[0])) {
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
                  const p = line.match(/^(?:participant|actor)\\s+([^\\s]+)(?:\\s+as\\s+(.+))?$/i);
                  if (p) { addActor(p[1].trim(), p[2] ? p[2].trim() : p[1].trim()); continue; }
                  const m = line.match(/^([^\\s-]+)\\s*(->>|-->>|->|-->)\\s*([^:]+):\\s*(.*)$/);
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
                const svg = el('svg', { viewBox: `0 0 ${width} ${height}` });
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

              // 5. Flowchart / State / Class / ER Diagram
              const stateHeader = /^stateDiagram(?:-v2)?\\b/i.test(lines[0]);
              const classHeader = /^classDiagram\\b/i.test(lines[0]);
              const erHeader = /^erDiagram\\b/i.test(lines[0]);
              const headerMatch = lines[0].match(/^(?:flowchart|graph)\\s+(TD|TB|LR|RL|BT)\\b/i);
              if (!headerMatch && !stateHeader && !classHeader && !erHeader) { renderFallback(); return; }
              const dir = headerMatch ? headerMatch[1].toUpperCase() : (erHeader ? 'LR' : 'TD');
              const horizontal = dir === 'LR' || dir === 'RL';
              const nodes = new Map();
              const edges = [];
              const subgraphs = [];
              let activeSubgraph = null;

              function ensureNode(id, label, members, shape) {
                const cleanID = id.trim();
                if (!cleanID) return '';
                if (!nodes.has(cleanID)) {
                  nodes.set(cleanID, { id: cleanID, label: label || cleanID, members: members || [], shape: shape || 'rect', level: 0 });
                } else {
                  const cur = nodes.get(cleanID);
                  if (label && label !== cleanID) cur.label = label;
                  if (members && members.length) cur.members.push(...members);
                  if (shape && shape !== 'rect') cur.shape = shape;
                }
                if (activeSubgraph && !activeSubgraph.nodes.includes(cleanID)) {
                  activeSubgraph.nodes.push(cleanID);
                }
                return cleanID;
              }

              function parseNode(token) {
                const t = token.trim();
                if (stateHeader && t === '[*]') return ensureNode('__start_end__', '●', [], 'pill');
                const stadium = t.match(/^([A-Za-z0-9_\\u4e00-\\u9fa5]+)\\s*\\(\\[(.*?)\\]\\)$/);
                if (stadium) return ensureNode(stadium[1], stadium[2].replace(/^["']|["']$/g, ''), [], 'pill');
                const m = t.match(/^([A-Za-z0-9_\\u4e00-\\u9fa5]+)\\s*(?:\\[(.*?)\\]|\\((.*?)\\)|\\{(.*?)\\})?$/);
                const id = m ? m[1] : t.replace(/[^A-Za-z0-9_\\u4e00-\\u9fa5]/g, '_');
                const shape = (m && m[4]) ? 'diamond' : ((m && m[3]) ? 'pill' : 'rect');
                const rawLabel = (m && (m[2] || m[3] || m[4])) ? (m[2] || m[3] || m[4]) : id;
                const label = rawLabel.replace(/^["']|["']$/g, '');
                return ensureNode(id, label, [], shape);
              }

              if (erHeader) {
                let activeEntity = null;
                for (const line of lines.slice(1)) {
                  if (activeEntity) {
                    if (line === '}') { activeEntity = null; continue; }
                    ensureNode(activeEntity, activeEntity, [line]);
                    continue;
                  }
                  const blockStart = line.match(/^([A-Za-z0-9_\\u4e00-\\u9fa5-]+)\\s*\\{$/);
                  if (blockStart) { activeEntity = ensureNode(blockStart[1], blockStart[1]); continue; }
                  const rel = line.match(/^([A-Za-z0-9_\\u4e00-\\u9fa5-]+)\\s+([|o}{]{1,2}[.-]{2}[|o}{]{1,2})\\s+([A-Za-z0-9_\\u4e00-\\u9fa5-]+)(?:\\s*:\\s*(.+))?$/);
                  if (rel) {
                    const f = ensureNode(rel[1], rel[1]);
                    const t = ensureNode(rel[3], rel[3]);
                    const lbl = (rel[4] || rel[2]).replace(/^["']|["']$/g, '').trim();
                    edges.push({ from: f, to: t, label: lbl, dashed: rel[2].includes('..') });
                  }
                }
              } else if (classHeader) {
                let activeClass = null;
                for (const line of lines.slice(1)) {
                  if (activeClass) {
                    if (line === '}') { activeClass = null; continue; }
                    ensureNode(activeClass, activeClass, [line]);
                    continue;
                  }
                  const blockStart = line.match(/^class\\s+([A-Za-z0-9_\\u4e00-\\u9fa5]+)\\s*\\{$/);
                  if (blockStart) { activeClass = ensureNode(blockStart[1], blockStart[1]); continue; }
                  const memberLine = line.match(/^([A-Za-z0-9_\\u4e00-\\u9fa5]+)\\s*:\\s*(.+)$/);
                  if (memberLine && !line.includes('--') && !line.includes('..')) {
                    ensureNode(memberLine[1], memberLine[1], [memberLine[2].trim()]);
                    continue;
                  }
                  const rel = line.match(/^([A-Za-z0-9_\\u4e00-\\u9fa5]+)\\s*(<\\|--|--\\|>|\\*--|o--|-->|\\.\\.>|--|\\.\\.)\\s*([A-Za-z0-9_\\u4e00-\\u9fa5]+)(?:\\s*:\\s*(.+))?$/);
                  if (rel) {
                    const f = ensureNode(rel[1], rel[1]);
                    const t = ensureNode(rel[3], rel[3]);
                    edges.push({ from: f, to: t, label: (rel[4] || '').trim(), dashed: rel[2].includes('..') });
                  }
                }
              } else if (stateHeader) {
                for (const line of lines.slice(1)) {
                  const alias = line.match(/^state\\s+"([^"]+)"\\s+as\\s+([A-Za-z0-9_\\u4e00-\\u9fa5]+)$/i);
                  if (alias) { ensureNode(alias[2], alias[1]); continue; }
                  const tr = line.match(/^(\\[\\*\\]|[A-Za-z0-9_\\u4e00-\\u9fa5]+)\\s*-->\\s*(\\[\\*\\]|[A-Za-z0-9_\\u4e00-\\u9fa5]+)(?:\\s*:\\s*(.+))?$/);
                  if (tr) {
                    const f = parseNode(tr[1]);
                    const t = parseNode(tr[2]);
                    if (f && t) edges.push({ from: f, to: t, label: (tr[3] || '').trim(), dashed: false });
                  }
                }
              } else {
                for (const line of lines.slice(1)) {
                  const sg = line.match(/^subgraph\\s+(.+)$/i);
                  if (sg) {
                    const title = sg[1].replace(/^[^\\[]*\\[|\\]$/g, '').replace(/^["']|["']$/g, '').trim();
                    activeSubgraph = { title, nodes: [] };
                    subgraphs.push(activeSubgraph);
                    continue;
                  }
                  if (/^end\\b/i.test(line)) { activeSubgraph = null; continue; }
                  if (/^(?:style|classDef|class|click|linkStyle|direction)\\b/i.test(line)) continue;
                  const e = line.match(/^(.+?)\\s*(-->|---|==>|-\\.->)\\s*(?:\\|([^|]+)\\|\\s*)?(.+)$/);
                  if (e) {
                    const from = parseNode(e[1]);
                    const to = parseNode(e[4]);
                    if (from && to) edges.push({ from, to, label: (e[3] || '').trim(), dashed: e[2] === '-.->' });
                  } else if (/^[A-Za-z0-9_\\u4e00-\\u9fa5]+\\s*[\\[\\(\\{]/.test(line)) {
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
              const boxH = 44 + Math.min(maxMemberCount, 5) * 16;
              const gapX = 54, gapY = 50, pad = 28;
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

              const svg = el('svg', { viewBox: `0 0 ${width} ${height}` });
              const defs = el('defs');
              const marker = el('marker', { id: 'm-arrow', markerWidth: 8, markerHeight: 8, refX: 7, refY: 3.5, orient: 'auto' });
              marker.appendChild(el('path', { d: 'M0,0 L8,3.5 L0,7 Z', fill: '#636366' }));
              defs.appendChild(marker);
              svg.appendChild(defs);

              // Render subgraph backdrop frames
              for (const sg of subgraphs) {
                const members = sg.nodes.map(id => nodes.get(id)).filter(Boolean);
                if (!members.length) continue;
                const minX = Math.min(...members.map(m => m.x)) - 14;
                const minY = Math.min(...members.map(m => m.y)) - 22;
                const maxX = Math.max(...members.map(m => m.x + boxW)) + 14;
                const maxY = Math.max(...members.map(m => m.y + boxH)) + 14;
                svg.appendChild(el('rect', { class: 'subgraph-box', x: minX, y: minY, width: maxX - minX, height: maxY - minY, rx: 12, fill: 'rgba(79,70,229,0.05)', stroke: '#818cf8', 'stroke-width': 1.2, 'stroke-dasharray': '5,4' }));
                svg.appendChild(el('text', { class: 'edge-label', x: minX + 10, y: minY + 14, 'font-size': 10.5, 'font-weight': 600, fill: '#4f46e5' }, sg.title.slice(0, 28)));
              }

              for (const e of edges) {
                const f = nodes.get(e.from), t = nodes.get(e.to);
                if (!f || !t) continue;
                const x1 = horizontal ? f.x + boxW : f.x + boxW / 2;
                const y1 = horizontal ? f.y + boxH / 2 : f.y + boxH;
                const x2 = horizontal ? t.x : t.x + boxW / 2;
                const y2 = horizontal ? t.y + boxH / 2 : t.y;
                svg.appendChild(el('line', { class: 'edge-line', x1, y1, x2, y2, stroke: '#636366', 'stroke-width': 1.6, 'stroke-dasharray': e.dashed ? '5,4' : '', 'marker-end': 'url(#m-arrow)' }));
                if (e.label) {
                  const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
                  const lbl = e.label.slice(0, 26);
                  const lw = Math.max(44, Math.min(180, measureTextWidth(lbl) + 14));
                  svg.appendChild(el('rect', { class: 'edge-bg', x: mx - lw / 2, y: my - 9, width: lw, height: 18, rx: 4, fill: '#ffffff' }));
                  svg.appendChild(el('text', { class: 'edge-label', x: mx, y: my + 4, 'text-anchor': 'middle', 'font-size': 10, fill: '#3a3a3c' }, lbl));
                }
              }

              for (const n of nodes.values()) {
                if (n.shape === 'diamond') {
                  const cx = n.x + boxW / 2, cy = n.y + boxH / 2;
                  const pts = `${cx},${n.y - 4} ${n.x + boxW + 6},${cy} ${cx},${n.y + boxH + 4} ${n.x - 6},${cy}`;
                  svg.appendChild(el('polygon', { class: 'node-box', points: pts, fill: '#eef2ff', stroke: '#4f46e5', 'stroke-width': 1.5 }));
                } else {
                  const rx = n.shape === 'pill' ? boxH / 2 : 10;
                  svg.appendChild(el('rect', { class: 'node-box', x: n.x, y: n.y, width: boxW, height: boxH, rx, fill: '#eef2ff', stroke: '#4f46e5', 'stroke-width': 1.5 }));
                }
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
            """

        default:
            return code
        }
    }
}

struct ArtifactPreviewSheet: View {
    let language: String
    let code: String
    @Environment(\.dismiss) private var dismiss
    @State private var showSource = false
    @State private var snapshotFileURL: URL?
    @State private var svgExportURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showSource {
                    ScrollView([.horizontal, .vertical]) {
                        Text(SyntaxHighlighter.highlight(code: code, cacheable: false))
                            .font(.footnote.monospaced())
                            .padding(14)
                            .textSelection(.enabled)
                    }
                } else {
                    SandboxedArtifactWebView(
                        html: ArtifactDocumentBuilder.htmlDocument(language: language, code: code),
                        allowsJavaScript: ArtifactDocumentBuilder.allowsJavaScript(for: language),
                        onSnapshotURL: { url in snapshotFileURL = url },
                        onSVGExportURL: { url in svgExportURL = url }
                    )
                }
            }
            .navigationTitle(language.uppercased())
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "svg",
                   let data = code.data(using: .utf8) {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Fugue-Artifact-\(UUID().uuidString.prefix(8)).svg")
                    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    svgExportURL = url
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("视图", selection: $showSource) {
                        Text("预览").tag(false)
                        Text("源码").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if snapshotFileURL != nil || svgExportURL != nil {
                        Menu {
                            if let snapshotFileURL {
                                ShareLink(item: snapshotFileURL) {
                                    Label("导出 PNG 图片", systemImage: "photo")
                                }
                            }
                            if let svgExportURL {
                                ShareLink(item: svgExportURL) {
                                    Label("导出 SVG 矢量图", systemImage: "doc.richtext")
                                }
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("导出图表")
                    }
                }
            }
        }
    }
}

struct SandboxedArtifactWebView: UIViewRepresentable {
    let html: String
    let allowsJavaScript: Bool
    var onSnapshotURL: ((URL?) -> Void)? = nil
    var onSVGExportURL: ((URL?) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onSnapshotURL: onSnapshotURL, onSVGExportURL: onSVGExportURL)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        config.userContentController.addUserScript(WKUserScript(
            source: ArtifactDocumentBuilder.webrtcGuardJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear

        let blockRules = """
        [{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]
        """
        let coordinator = context.coordinator
        let initialHTML = html
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "iOSBoxOfflineArtifactRules",
            encodedContentRuleList: blockRules
        ) { list, _ in
            Task { @MainActor in
                // Fail closed: never load untrusted markup without the network-blocking rule list.
                guard let list else { return }
                webView.configuration.userContentController.add(list)
                coordinator.ruleListInstalled = true
                let targetHTML = coordinator.pendingHTML ?? initialHTML
                coordinator.loadedHTML = targetHTML
                coordinator.allowNextLoadHTML = true
                webView.loadHTMLString(targetHTML, baseURL: nil)
            }
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        if context.coordinator.ruleListInstalled {
            if context.coordinator.loadedHTML != html {
                context.coordinator.loadedHTML = html
                context.coordinator.allowNextLoadHTML = true
                uiView.loadHTMLString(html, baseURL: nil)
            }
        } else {
            context.coordinator.pendingHTML = html
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSnapshotURL: ((URL?) -> Void)?
        let onSVGExportURL: ((URL?) -> Void)?
        var ruleListInstalled = false
        var loadedHTML: String?
        var pendingHTML: String?
        var allowNextLoadHTML = false

        init(onSnapshotURL: ((URL?) -> Void)?, onSVGExportURL: ((URL?) -> Void)?) {
            self.onSnapshotURL = onSnapshotURL
            self.onSVGExportURL = onSVGExportURL
        }

        static func shouldAllowNavigation(
            url: URL?,
            navigationType: WKNavigationType,
            isMainFrame: Bool,
            allowInitialAboutBlank: inout Bool
        ) -> Bool {
            guard isMainFrame,
                  navigationType == .other,
                  allowInitialAboutBlank,
                  url?.absoluteString.lowercased() == "about:blank" else {
                return false
            }
            allowInitialAboutBlank = false
            return true
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isMain = navigationAction.targetFrame?.isMainFrame ?? false
            if Self.shouldAllowNavigation(
                url: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                isMainFrame: isMain,
                allowInitialAboutBlank: &allowNextLoadHTML
            ) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let onSnapshotURL {
                webView.takeSnapshot(with: nil) { image, _ in
                    guard let data = image?.pngData() else { return }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Fugue-Artifact-\(UUID().uuidString.prefix(8)).png")
                    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    Task { @MainActor in
                        onSnapshotURL(url)
                    }
                }
            }
            if let onSVGExportURL {
                let serializerJS = """
                (function() {
                  const svg = document.querySelector('svg');
                  if (!svg) return '';
                  if (!svg.getAttribute('xmlns')) svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
                  const vb = (svg.getAttribute('viewBox') || '').trim().split(/\\s+/);
                  if (vb.length === 4) {
                    if (!svg.getAttribute('width')) svg.setAttribute('width', vb[2]);
                    if (!svg.getAttribute('height')) svg.setAttribute('height', vb[3]);
                  }
                  return '<?xml version="1.0" encoding="UTF-8"?>\\n' + new XMLSerializer().serializeToString(svg);
                })();
                """
                webView.evaluateJavaScript(serializerJS) { result, _ in
                    guard let svgMarkup = result as? String,
                          svgMarkup.contains("<svg"),
                          let data = svgMarkup.data(using: .utf8) else { return }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Fugue-Diagram-\(UUID().uuidString.prefix(8)).svg")
                    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    Task { @MainActor in
                        onSVGExportURL(url)
                    }
                }
            }
        }
    }
}
