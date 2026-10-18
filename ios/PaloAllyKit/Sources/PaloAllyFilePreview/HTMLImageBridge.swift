import Foundation
import WebKit

/// Lets a sandboxed HTML library page show the pictures published beside it.
///
/// The page lives on a fake origin with all network blocked, so `<img
/// src="img/a.jpg">` can't load by itself. A small user script, run in its own
/// content world (the page's scripts can neither see nor call it), finds
/// `<img>` elements with a file-relative `src`, takes the `src` off, and asks
/// native for each one as it nears the viewport. Native resolves it against
/// the page's own folder (no `..`, no absolute paths, no URLs), reads it from
/// the item, and answers with a `data:` URI, or a miss, which shows a quiet
/// stub. http(s) images are left alone: they stay blocked.
///
/// Skipped on purpose: CSS `url()` (stylesheets and inline styles) and
/// `srcset`.
@MainActor
public final class HTMLImageBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "paloImages"
    static let world = WKContentWorld.world(name: "paloally.images")

    private let filler = PreviewImageFiller()
    private weak var webView: WKWebView?

    public override init() {
        super.init()
        filler.deliver = { [weak self] src, uri in
            guard let webView = self?.webView else { return }
            let call = uri == nil ? "window.paloImageFail(src)" : "window.paloImageSet(src, uri)"
            var args: [String: Any] = ["src": src]
            if let uri { args["uri"] = uri }
            webView.callAsyncJavaScript(call, arguments: args, in: nil, in: Self.world, completionHandler: nil)
        }
    }

    /// Install the script and the message channel on a configuration, before
    /// its web view is made.
    public func install(in config: WKWebViewConfiguration) {
        let script = WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                  forMainFrameOnly: true, in: Self.world)
        config.userContentController.addUserScript(script)
        config.userContentController.add(WeakHandler(self), contentWorld: Self.world, name: Self.handlerName)
    }

    public func attach(_ webView: WKWebView) { self.webView = webView }

    /// A new document is loading from this item. `source.directory` is the
    /// page's own folder inside it.
    public func reset(source: FilePreviewWebView.ImageSource?) {
        filler.source = source
        filler.reset()
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let srcs = body["srcs"] as? [String] else { return }
        // Bounded: a hostile page can't queue an unbounded list.
        let batch = Array(srcs.prefix(64))
        filler.enqueue(batch)
    }

    /// `WKUserContentController` retains its handlers; this keeps the bridge
    /// (and through it the web view) from being retained by its own config.
    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: HTMLImageBridge?
        init(_ target: HTMLImageBridge) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(c, didReceive: message)
        }
    }

    static let script = #"""
    (function () {
      "use strict";
      if (window.__paloImagesInstalled) { return; }
      window.__paloImagesInstalled = true;
      var ATTR = "data-palo-src";
      var requested = Object.create(null);
      var observer = null;

      function isRelative(s) {
        s = (s || "").trim();
        if (!s || s.charAt(0) === "/" || s.charAt(0) === "#") { return false; }
        var head = s.split(/[\/?#]/)[0];
        return head.indexOf(":") < 0;
      }

      function post(srcs) {
        if (!srcs.length) { return; }
        var mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.paloImages;
        if (mh) { mh.postMessage({ srcs: srcs }); }
      }

      function claim(els) {
        var out = [];
        els.forEach(function (el) {
          var s = el.getAttribute(ATTR);
          if (!s || requested[s]) { return; }
          requested[s] = true;
          out.push(s);
        });
        return out;
      }

      function ask(el) {
        if (!("IntersectionObserver" in window)) { post(claim([el])); return; }
        if (!observer) {
          observer = new IntersectionObserver(function (entries) {
            var hit = [];
            entries.forEach(function (e) {
              if (!e.isIntersecting) { return; }
              observer.unobserve(e.target);
              hit.push(e.target);
            });
            post(claim(hit));
          }, { rootMargin: "800px" });
        }
        observer.observe(el);
      }

      function take(img) {
        if (img.hasAttribute(ATTR)) { return; }
        var s = img.getAttribute("src");
        if (s === null || !isRelative(s)) { return; }
        img.setAttribute(ATTR, s.trim());
        img.removeAttribute("src");
        img.removeAttribute("srcset");
        ask(img);
      }

      function scan(root) {
        if (root.nodeType !== 1) { return; }
        if (root.tagName === "IMG") { take(root); }
        var list = root.querySelectorAll ? root.querySelectorAll("img") : [];
        for (var i = 0; i < list.length; i++) { take(list[i]); }
      }

      function each(src, fn) {
        document.querySelectorAll("img[" + ATTR + "]").forEach(function (el) {
          if (el.getAttribute(ATTR) === src) { fn(el); }
        });
      }

      window.paloImageSet = function (src, uri) {
        each(src, function (el) { el.src = uri; });
      };

      // A miss is a small quiet label in the picture's place, never a blank box.
      window.paloImageFail = function (src) {
        each(src, function (el) {
          var span = document.createElement("span");
          span.setAttribute("data-palo-stub", "1");
          span.textContent = "\u{1F5BC} " + (el.getAttribute("alt") || src);
          span.style.cssText = "display:inline-block;padding:4px 8px;border-radius:6px;" +
            "background:rgba(128,128,128,.14);color:rgba(128,128,128,.9);" +
            "font:12px -apple-system,sans-serif;max-width:100%;box-sizing:border-box;";
          el.replaceWith(span);
        });
      };

      scan(document.documentElement);
      new MutationObserver(function (muts) {
        muts.forEach(function (m) {
          if (m.type === "attributes") { if (m.target.tagName === "IMG") { take(m.target); } return; }
          m.addedNodes.forEach(scan);
        });
      }).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["src"] });
    })();
    """#
}
