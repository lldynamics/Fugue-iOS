// Safari invokes this packaged script only when the user selects Fugue (夜奔) in Share.
var ExtensionPreprocessingJS = {
    run: function (arguments) {
        try {
            var selection = String((window.getSelection && window.getSelection()) || "").trim();
            var root = (document.querySelector && (document.querySelector("article") || document.querySelector("main"))) || document.body || document.documentElement;
            var text = selection;
            var maxChars = 60000;
            var wasTruncated = false;

            if (!text && root) {
                var excludedTags = {
                    SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, NAV: 1, HEADER: 1,
                    FOOTER: 1, FORM: 1, SVG: 1, TEMPLATE: 1, ASIDE: 1
                };
                var blockTags = {
                    P: 1, DIV: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1,
                    LI: 1, BR: 1, TR: 1, BLOCKQUOTE: 1, SECTION: 1, ARTICLE: 1, PRE: 1
                };
                var chunks = [];
                var totalLen = 0;

                function isExcluded(el) {
                    var cur = el;
                    while (cur && cur !== root) {
                        if (excludedTags[cur.tagName] || cur.hidden || (cur.getAttribute && cur.getAttribute("aria-hidden") === "true")) {
                            return true;
                        }
                        cur = cur.parentElement;
                    }
                    return false;
                }

                if (document.createTreeWalker && window.NodeFilter) {
                    var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, null);
                    var node = walker.currentNode;
                    while (node) {
                        if (node.nodeType === 1) {
                            if (excludedTags[node.tagName] || node.hidden || (node.getAttribute && node.getAttribute("aria-hidden") === "true")) {
                                node = walker.nextSibling() || (function () {
                                    var p = walker.parentNode();
                                    while (p && p !== root) {
                                        var s = walker.nextSibling();
                                        if (s) return s;
                                        p = walker.parentNode();
                                    }
                                    return null;
                                })();
                                continue;
                            }
                            if (blockTags[node.tagName]) {
                                chunks.push("\n\n");
                                totalLen += 2;
                            }
                        } else if (node.nodeType === 3 && !isExcluded(node.parentElement)) {
                            var val = node.nodeValue || "";
                            if (val) {
                                chunks.push(val);
                                totalLen += val.length;
                                if (totalLen > maxChars + 8192) {
                                    wasTruncated = true;
                                    break;
                                }
                            }
                        }
                        node = walker.nextNode();
                    }
                    text = chunks.join("");
                } else {
                    text = String(root.textContent || "");
                }
            }

            text = text.replace(/[ \t\r]+/g, " ").replace(/\n\s*\n/g, "\n\n").trim();
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
