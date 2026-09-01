/*!
 * pixelex tracker — first-party, cookieless.
 *
 * Optional. Page views are already counted server-side by Pixelex.Plug and the
 * LiveView hook, with nothing for a blocker to block. This adds only what the
 * server cannot see: clicks, SPA navigation, screen size, scroll depth and
 * engagement time.
 *
 *   <script defer src="/px/pixelex.js" data-site="shop"></script>
 *
 * Then any element with data-track is counted when clicked:
 *
 *   <button data-track="book_click" data-track-doctor={@doctor.id}>
 *
 * The name must be in the site's allowlist or the server drops it silently.
 */
(function (window, document) {
  "use strict";

  var script = document.currentScript || (function () {
    var all = document.getElementsByTagName("script");
    return all[all.length - 1];
  })();

  var data = (script && script.dataset) || {};
  var endpoint = data.endpoint || "/px/e";
  var site = data.site || location.hostname;
  var autoPageview = data.autoPageview !== "false";
  var trackEngagement = data.engagement !== "false";

  /* ---------------------------------------------------------------- guards */

  // Every one of these is a source of numbers that look like traffic and are
  // not. Checked once, at load, because none of them changes mid-page.
  function disabled() {
    try {
      if (/^localhost$|^127(\.[0-9]+){0,2}\.[0-9]+$|^\[::1?\]$/.test(location.hostname)) return "localhost";
      if (location.protocol === "file:") return "file";
      if (window._phantom || window.__nightmare || window.Cypress) return "automation";
      if (navigator.webdriver) return "webdriver";
      // Global Privacy Control is a legally binding opt-out under CCPA/CPRA.
      // The server checks the Sec-GPC header too — a blocker may have stripped
      // this script before it ever ran — but honouring it here saves the round
      // trip and is the same answer.
      if (navigator.globalPrivacyControl) return "gpc";
      if (window.localStorage && localStorage.getItem("pixelex_ignore")) return "opted out";
    } catch (_) {
      // Storage can throw in a private window or with site data blocked.
      // Failing open is right: the check is a courtesy, not the consent gate.
    }
    return null;
  }

  var off = disabled();

  /* ---------------------------------------------------------------- sending */

  function send(name, props, url) {
    if (off) return;

    var payload = {
      s: site,
      n: name,
      u: url || location.href,
      r: document.referrer || null,
      t: Date.now()
    };

    if (props && Object.keys(props).length) payload.p = props;

    var body = JSON.stringify(payload);

    // keepalive is load-bearing: most tracked elements are links, so the
    // request has to outlive the navigation the same click starts.
    //
    // fetch over sendBeacon deliberately. The 64KiB keepalive budget is shared
    // across the whole page either way, but sendBeacon cannot set a
    // content-type or be told about a failure, and Umami moved off it for the
    // same reason.
    try {
      if (window.fetch) {
        fetch(endpoint, {
          method: "POST",
          keepalive: true,
          credentials: "omit",
          headers: { "content-type": "application/json" },
          body: body
        }).catch(pixelFallback);
        return;
      }
    } catch (_) {}

    pixelFallback();

    // A GET to a 1x1 GIF. Survives a missing fetch, a CSP that blocks XHR, and
    // an unload race that drops the POST.
    function pixelFallback() {
      try {
        var image = new Image();
        var query =
          "?s=" + encodeURIComponent(payload.s) +
          "&n=" + encodeURIComponent(payload.n) +
          "&u=" + encodeURIComponent(payload.u) +
          "&t=" + payload.t +
          (payload.r ? "&r=" + encodeURIComponent(payload.r) : "");

        image.src = endpoint.replace(/\/e$/, "") + "/px.gif" + query;
      } catch (_) {}
    }
  }

  /* ------------------------------------------------------------ page views */

  var lastPath = null;

  function pageview(url) {
    var path = url ? url.split("#")[0] : location.pathname + location.search;

    // Phoenix fires phx:navigate twice on a live redirect, and a hashchange is
    // not a new page unless the app routes on hashes.
    if (path === lastPath) return;
    lastPath = path;

    send("px.pageview", screenProps(), url);
    resetEngagement();
  }

  function screenProps() {
    var props = {};
    try {
      if (window.innerWidth) props.w = window.innerWidth;
      if (window.screen && screen.width) props.sw = screen.width;
    } catch (_) {}
    return props;
  }

  /* ----------------------------------------------------------- engagement */

  var maxScroll = 0;
  var activeMs = 0;
  var lastTick = Date.now();
  var visible = true;

  function resetEngagement() {
    maxScroll = 0;
    activeMs = 0;
    lastTick = Date.now();
  }

  function tick() {
    var now = Date.now();
    if (visible) activeMs += now - lastTick;
    lastTick = now;
  }

  function scrollDepth() {
    try {
      var height = Math.max(
        document.body.scrollHeight,
        document.documentElement.scrollHeight
      ) - window.innerHeight;

      if (height <= 0) return 100;
      return Math.min(100, Math.round(((window.scrollY || 0) / height) * 100));
    } catch (_) {
      return 0;
    }
  }

  function flushEngagement() {
    if (!trackEngagement || off) return;
    tick();

    var depth = Math.max(maxScroll, scrollDepth());

    // Suppress the noise: only report when the reader got further down the
    // page than before, or actually spent time on it. Plausible found this the
    // difference between a useful signal and a firehose.
    if (depth <= maxScroll && activeMs < 1000) return;

    maxScroll = depth;
    send("px.engagement", { d: depth, ms: activeMs });
    activeMs = 0;
  }

  /* ---------------------------------------------------------------- clicks */

  var clickedAt = new WeakMap ? new WeakMap() : null;

  function onClick(event) {
    var el = event.target && event.target.closest && event.target.closest("[data-track]");
    if (!el) return;

    // Mobile fires a synthetic click after touchend, and people double-tap a
    // button that feels slow. Neither is a second intention.
    if (clickedAt) {
      var now = Date.now();
      if (now - (clickedAt.get(el) || 0) < 800) return;
      clickedAt.set(el, now);
    }

    var props = {};
    for (var key in el.dataset) {
      if (key !== "track" && key.indexOf("track") === 0) {
        // data-track-doctor="123" -> {doctor: "123"}
        props[key.slice(5).toLowerCase()] = el.dataset[key];
      }
    }

    send(el.dataset.track, props);
  }

  /* ------------------------------------------------------------ public api */

  function track(name, props) {
    send(name, props || {});
  }

  // Drain anything queued before this file finished loading. The stub pattern
  // means a page can call pixelex() in its <head> without waiting.
  var queued = (window.pixelex && window.pixelex.q) || [];
  window.pixelex = track;
  window.pixelex.track = track;
  window.pixelex.pageview = pageview;
  window.pixelex.disabled = off;

  /* ------------------------------------------------------------------ wire */

  if (!off) {
    // Capture phase: a handler further down that calls stopPropagation — modal
    // closers do — would otherwise silently stop the count.
    document.addEventListener("click", onClick, true);

    // Phoenix LiveView: live_patch and live_navigate never touch the server's
    // request path, so this is the only client-side signal for them.
    window.addEventListener("phx:navigate", function (e) {
      pageview(e.detail && e.detail.href);
    });

    // Ordinary SPA routers.
    var pushState = history.pushState;
    if (pushState) {
      history.pushState = function () {
        pushState.apply(this, arguments);
        pageview();
      };
      window.addEventListener("popstate", function () { pageview(); });
    }

    window.addEventListener("hashchange", function () { pageview(); });

    if (trackEngagement) {
      document.addEventListener("visibilitychange", function () {
        visible = document.visibilityState === "visible";
        tick();
        // hidden, not unload: an unload handler disqualifies the page from the
        // back-forward cache and does not fire reliably on mobile at all.
        if (!visible) flushEngagement();
      });

      window.addEventListener("pagehide", flushEngagement);

      window.addEventListener("scroll", function () {
        var depth = scrollDepth();
        if (depth > maxScroll) maxScroll = depth;
      }, { passive: true });
    }

    if (autoPageview) pageview();

    for (var i = 0; i < queued.length; i++) {
      try { track.apply(null, queued[i]); } catch (_) {}
    }
  }
})(window, document);
