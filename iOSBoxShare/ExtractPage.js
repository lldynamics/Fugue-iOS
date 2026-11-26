// Safari invokes this packaged script only when the user selects Fugue (夜奔) in Share.
var ExtensionPreprocessingJS = {
    run: function (arguments) {
        try {
            var maxChars = 60000;
            var wasTruncated = false;

            var excludedTags = {
                SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, NAV: 1, HEADER: 1,
                FOOTER: 1, FORM: 1, SVG: 1, TEMPLATE: 1, ASIDE: 1
            };
            var blockTags = {
                P: 1, DIV: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1,
                LI: 1, TR: 1, BLOCKQUOTE: 1, SECTION: 1, ARTICLE: 1, PRE: 1
            };

            function tagNameOf(el) {
                return el && el.tagName ? String(el.tagName).toUpperCase() : "";
            }

            function isNodeSelfHidden(el) {
                if (!el || el.nodeType !== 1) return false;
                if (el.hidden) return true;
                if (el.getAttribute) {
                    var ariaHidden = el.getAttribute("aria-hidden");
                    if (ariaHidden && String(ariaHidden).toLowerCase() === "true") return true;
                    var inlineStyle = el.getAttribute("style");
                    if (inlineStyle && /(?:^|;)\s*(?:display\s*:\s*none|visibility\s*:\s*hidden)\b/i.test(inlineStyle)) {
                        return true;
                    }
                }
                if (el.style && (el.style.display === "none" || el.style.visibility === "hidden")) {
                    return true;
                }
                if (typeof window !== "undefined" && window.getComputedStyle) {
                    try {
                        var cs = window.getComputedStyle(el);
                        if (cs && (cs.display === "none" || cs.visibility === "hidden")) {
                            return true;
                        }
                    } catch (_) {}
                }
                return false;
            }

            function isHiddenOrExcludedInAncestors(el, stopAt) {
                var cur = el;
                while (cur && cur !== stopAt && cur.nodeType === 1) {
                    if (excludedTags[tagNameOf(cur)] || isNodeSelfHidden(cur)) {
                        return true;
                    }
                    cur = cur.parentElement || cur.parentNode;
                }
                return false;
            }

            function hasAncestorInSet(el, list) {
                var cur = el ? (el.parentElement || el.parentNode) : null;
                while (cur) {
                    for (var i = 0; i < list.length; i++) {
                        if (list[i] === cur) return true;
                    }
                    cur = cur.parentElement || cur.parentNode;
                }
                return false;
            }

            function normalizeSegments(segments) {
                var merged = [];
                for (var i = 0; i < segments.length; i++) {
                    var seg = segments[i];
                    if (!seg.text) continue;
                    if (merged.length > 0 && merged[merged.length - 1].kind === seg.kind) {
                        merged[merged.length - 1].text += seg.text;
                    } else {
                        merged.push({ kind: seg.kind, text: seg.text });
                    }
                }
                var out = [];
                for (var j = 0; j < merged.length; j++) {
                    var item = merged[j];
                    var raw = item.text.replace(/\r\n?/g, "\n");
                    if (item.kind === "pre") {
                        raw = raw.replace(/^\n+|\n+$/g, "");
                        if (raw) out.push(raw);
                    } else if (item.kind === "code") {
                        if (raw) out.push(raw);
                    } else {
                        var prose = raw
                            .replace(/[ \t]+/g, " ")
                            .replace(/ *\n */g, "\n")
                            .replace(/\n{3,}/g, "\n\n");
                        if (prose) out.push(prose);
                    }
                }
                return out
                    .join("")
                    .replace(/^\n+|\s+$/g, "")
                    .replace(/^ +/, function (m) {
                        return merged.length > 0 && (merged[0].kind === "pre" || merged[0].kind === "code") ? m : "";
                    });
            }

            function extractFromNode(rootNode) {
                if (!rootNode || isNodeSelfHidden(rootNode)) {
                    return { text: "", truncated: false };
                }
                var children = rootNode.childNodes;
                if (!children || typeof children.length !== "number") {
                    var fallbackRaw = String(rootNode.textContent || "").replace(/\r\n?/g, "\n");
                    var rootTag = tagNameOf(rootNode);
                    if (rootTag === "PRE" || rootTag === "CODE") {
                        return { text: fallbackRaw.replace(/^\n+|\s+$/g, ""), truncated: false };
                    }
                    return {
                        text: fallbackRaw.replace(/[ \t]+/g, " ").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").trim(),
                        truncated: false
                    };
                }

                var segments = [];
                var totalLen = 0;
                var hitLimit = false;
                var rootIsPre = tagNameOf(rootNode) === "PRE";
                var rootIsCode = tagNameOf(rootNode) === "CODE";
                var stack = [{ type: "node", node: rootNode, inPre: rootIsPre, inCode: rootIsCode, isRoot: true }];

                function pushSegment(kind, str) {
                    if (!str) return;
                    segments.push({ kind: kind, text: str });
                    totalLen += str.length;
                }

                while (stack.length > 0) {
                    var item = stack.pop();
                    if (item.type === "sep") {
                        pushSegment(item.kind, item.text);
                        continue;
                    }
                    var node = item.node;
                    if (!node) continue;

                    if (node.nodeType === 3) {
                        var val = node.nodeValue || "";
                        if (val) {
                            if (item.inPre) {
                                pushSegment("pre", val);
                            } else if (item.inCode) {
                                pushSegment("code", val);
                            } else {
                                pushSegment("prose", val.replace(/[\r\n\t]+/g, " "));
                            }
                            if (totalLen > maxChars + 8192) {
                                hitLimit = true;
                                break;
                            }
                        }
                    } else if (node.nodeType === 1) {
                        var tag = tagNameOf(node);
                        if (!item.isRoot && (excludedTags[tag] || isNodeSelfHidden(node))) {
                            continue;
                        }
                        if (tag === "BR") {
                            pushSegment(item.inPre ? "pre" : "prose", "\n");
                            continue;
                        }
                        var nextInPre = item.inPre || tag === "PRE";
                        var nextInCode = item.inCode || tag === "CODE";
                        var isBlock = !item.isRoot && !!blockTags[tag];

                        if (isBlock) {
                            if (item.inPre && tag !== "PRE") {
                                stack.push({ type: "sep", kind: "pre", text: "\n" });
                            } else {
                                stack.push({ type: "sep", kind: "prose", text: "\n\n" });
                            }
                        }

                        var kids = node.childNodes;
                        if (kids && kids.length) {
                            for (var k = kids.length - 1; k >= 0; k--) {
                                stack.push({
                                    type: "node",
                                    node: kids[k],
                                    inPre: nextInPre,
                                    inCode: nextInCode,
                                    isRoot: false
                                });
                            }
                        }

                        if (isBlock && (!item.inPre || tag === "PRE")) {
                            pushSegment("prose", "\n\n");
                        }
                    }
                }

                return { text: normalizeSegments(segments), truncated: hitLimit };
            }

            var rawSelection = String((window.getSelection && window.getSelection()) || "");
            var text = "";
            if (rawSelection.trim()) {
                text = rawSelection
                    .replace(/\r\n?/g, "\n")
                    .replace(/\n{3,}/g, "\n\n")
                    .replace(/^\n+|\s+$/g, "");
            } else {
                var rawArticles = [];
                if (document.querySelectorAll) {
                    var nodeList = document.querySelectorAll("article");
                    for (var a = 0; a < nodeList.length; a++) {
                        rawArticles.push(nodeList[a]);
                    }
                } else if (document.querySelector) {
                    var singleArticle = document.querySelector("article");
                    if (singleArticle) rawArticles.push(singleArticle);
                }

                var visibleArticles = [];
                for (var idx = 0; idx < rawArticles.length; idx++) {
                    var art = rawArticles[idx];
                    if (art && !isHiddenOrExcludedInAncestors(art, null)) {
                        visibleArticles.push(art);
                    }
                }
                var topArticles = [];
                for (var t = 0; t < visibleArticles.length; t++) {
                    if (!hasAncestorInSet(visibleArticles[t], visibleArticles)) {
                        topArticles.push(visibleArticles[t]);
                    }
                }

                var substantiveTexts = [];
                var bestArticleText = "";
                var articleTruncated = false;
                for (var m = 0; m < topArticles.length; m++) {
                    var extracted = extractFromNode(topArticles[m]);
                    if (extracted.truncated) articleTruncated = true;
                    if (extracted.text.length > bestArticleText.length) {
                        bestArticleText = extracted.text;
                    }
                    if (extracted.text.length >= 120) {
                        substantiveTexts.push(extracted.text);
                    }
                }

                var candidateArticleText = substantiveTexts.length > 0
                    ? substantiveTexts.join("\n\n")
                    : bestArticleText;

                var mainEl = null;
                if (document.querySelector) {
                    var m1 = document.querySelector("main");
                    var m2 = !m1 ? document.querySelector("[role='main'], [role=\"main\"]") : null;
                    var pickedMain = m1 || m2;
                    if (pickedMain && !isHiddenOrExcludedInAncestors(pickedMain, null)) {
                        mainEl = pickedMain;
                    }
                }
                var bodyEl = (document.body && !isNodeSelfHidden(document.body))
                    ? document.body
                    : document.documentElement;

                var chosenText = candidateArticleText;
                var chosenTruncated = articleTruncated;

                if (!chosenText || chosenText.length < 120) {
                    var fallbackRoot = mainEl || bodyEl;
                    if (fallbackRoot) {
                        var fb = extractFromNode(fallbackRoot);
                        if (fb.text.length === 0 && fallbackRoot !== bodyEl && bodyEl) {
                            fb = extractFromNode(bodyEl);
                        }
                        if (fb.text.length > chosenText.length) {
                            chosenText = fb.text;
                            chosenTruncated = fb.truncated;
                        }
                    }
                } else if (mainEl) {
                    var mainExtracted = extractFromNode(mainEl);
                    if (mainExtracted.text.length > chosenText.length * 2.5) {
                        chosenText = mainExtracted.text;
                        chosenTruncated = mainExtracted.truncated;
                    }
                }

                text = chosenText;
                wasTruncated = chosenTruncated;
            }

            if (text.length > maxChars) {
                wasTruncated = true;
                text = text.slice(0, maxChars);
            }
            var pageTitle = String(document.title || "").slice(0, 300);
            var pageURL = String(document.URL || (window.location && window.location.href) || "");
            arguments.completionFunction({
                title: pageTitle,
                url: pageURL,
                text: text,
                truncated: wasTruncated
            });
        } catch (e) {
            arguments.completionFunction({
                title: String((document && document.title) || "").slice(0, 300),
                url: String((window.location && window.location.href) || ""),
                text: "",
                truncated: false
            });
        }
    }
};
