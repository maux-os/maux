/* maux site: the display and phosphor controls in the monitor's chin.

   Two axes, and they are independent (docs/DEMO-PHOSPHOR.md). The
   DISPLAY is the signal the session was filmed on -- the IIe's own 80
   columns, or the Videx UltraTerm, which has its own character
   generator. The PHOSPHOR is the glass it is shown on. The same
   UltraTerm driving an amber screen is a machine somebody owned, so
   every combination is offered and the two choices are remembered
   separately.

   Each phosphor is a FILM THAT WAS RECORDED, not a filter over one: the
   tint is baked at record time, where it is an exact palette map of a
   two-level picture rather than an approximation of it. So this script
   swaps the source and never restyles the video, and a reader with CSS
   filters unsupported still sees the right colour.

   Optional. Without this script a demo page shows the IIe's film on the
   default phosphor and a plain link to the UltraTerm's. With it, each
   axis gets a control and switching either one swaps the video, its
   poster and its captions and keeps the playback position (as a
   fraction of the film). Both choices go to localStorage, which may
   throw or be empty: every access is wrapped, and the page works
   without it.

   The captions belong to the DISPLAY, not the phosphor: the three films
   of one display are the same frames. So a caption attribute is
   two-part (data-e-vtt-src) and a film attribute is three-part
   (data-e-amber-mp4-src). */
(function () {
  "use strict";
  var DKEY = "maux-display";
  var PKEY = "maux-phosphor";
  var DNAMES = { e: "IIe 80-col", ut: "UltraTerm" };
  var DTITLES = { e: "Apple IIe 80-column display", ut: "Videx UltraTerm" };
  var DORDER = ["e", "ut"];
  var PORDER = ["paper", "green", "amber"];

  function recall(k) {
    try { return window.localStorage.getItem(k); } catch (x) { return null; }
  }
  function remember(k, v) {
    try { window.localStorage.setItem(k, v); } catch (x) { /* fine */ }
  }
  function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

  function wire(video) {
    // What this film actually has. A phosphor is offered only when every
    // offered display carries it, so no button can be dead on one of
    // them; the builder applies the same rule when it writes the
    // attributes, and this is the same test against what arrived.
    function film(d, p, k) {
      return video.getAttribute("data-" + d + "-" + p + "-" + k);
    }
    function has(d, p) {
      return !!(film(d, p, "mp4-src") || film(d, p, "webm-src"));
    }
    var displays = DORDER.filter(function (d) {
      return PORDER.some(function (p) { return has(d, p); });
    });
    var monitors = PORDER.filter(function (p) {
      return displays.length > 0 && displays.every(function (d) {
        return has(d, p);
      });
    });
    if (displays.length < 1 || monitors.length < 1) { return; }

    var cur = {
      d: video.getAttribute("data-display") || displays[0],
      p: video.getAttribute("data-phosphor") || monitors[0]
    };
    if (displays.indexOf(cur.d) < 0) { cur.d = displays[0]; }
    if (monitors.indexOf(cur.p) < 0) { cur.p = monitors[0]; }

    var holder = (video.closest ? video.closest(".film") : null) || video;
    var bar = document.createElement("div");
    bar.className = "monctl";
    var groups = [];

    function group(label, cls) {
      var box = document.createElement("div");
      box.className = cls;
      box.setAttribute("role", "group");
      box.setAttribute("aria-label", label);
      return box;
    }

    // the display: a segmented control, because the two names are words
    function addSeg(label, order, axis) {
      if (order.length < 2) { return; }
      var box = group(label, "seg"), buttons = {};
      order.forEach(function (v) {
        var b = document.createElement("button");
        b.type = "button";
        b.textContent = DNAMES[v];
        b.title = DTITLES[v];
        b.addEventListener("click", function () { pick(axis, v, true); });
        buttons[v] = b;
        box.appendChild(b);
      });
      bar.appendChild(box);
      groups.push({ buttons: buttons, axis: axis });
    }

    // the phosphor: swatches, because the choice IS the colour. Each
    // swatch is painted by CSS in the colour of the film it selects.
    function addSwatches(label, order, axis) {
      if (order.length < 2) { return; }
      var box = group(label, "phos"), buttons = {};
      order.forEach(function (v) {
        var b = document.createElement("button");
        b.type = "button";
        b.className = "sw sw-" + v;
        b.setAttribute("aria-label", v + " phosphor");
        b.title = cap(v) + " phosphor";
        b.addEventListener("click", function () { pick(axis, v, true); });
        buttons[v] = b;
        box.appendChild(b);
      });
      bar.appendChild(box);
      groups.push({ buttons: buttons, axis: axis });
    }

    addSeg("Display", displays, "d");
    addSwatches("Phosphor", monitors, "p");
    if (!groups.length) { return; }
    holder.parentNode.insertBefore(bar, holder.nextSibling);
    var alt = holder.parentNode.querySelector("[data-display-alt]");
    if (alt) { alt.hidden = true; }

    function mark() {
      groups.forEach(function (g) {
        Object.keys(g.buttons).forEach(function (v) {
          g.buttons[v].setAttribute(
            "aria-pressed", v === cur[g.axis] ? "true" : "false");
        });
      });
    }

    function show(initial) {
      var d = cur.d, p = cur.p;
      var at = video.currentTime || 0;
      var len = video.duration;       // the film being left
      // The films differ by a few frames (the card repaints faster), so
      // the position is carried over PROPORTIONALLY: the same fraction
      // of the new film, not the same second. Across a phosphor change
      // the frame count is identical, so this is exact there.
      var frac = (len && isFinite(len) && len > 0) ? at / len : 0;
      var playing = initial ? video.autoplay
                            : (!video.paused && !video.ended);
      var kids = video.querySelectorAll("source, track");
      for (var i = 0; i < kids.length; i++) { video.removeChild(kids[i]); }
      var webm = film(d, p, "webm-src");
      if (webm) {
        var w = document.createElement("source");
        w.src = webm; w.type = "video/webm";
        video.appendChild(w);
      }
      var mp4 = film(d, p, "mp4-src");
      if (mp4) {
        var m = document.createElement("source");
        m.src = mp4; m.type = "video/mp4";
        video.appendChild(m);
      }
      var vtt = video.getAttribute("data-" + d + "-vtt-src");
      if (vtt) {
        var t = document.createElement("track");
        t.kind = "captions"; t.src = vtt; t.srclang = "en";
        t.label = "English";
        video.appendChild(t);
      }
      var poster = film(d, p, "poster");
      if (poster) { video.setAttribute("poster", poster); }
      video.setAttribute("data-display", d);
      video.setAttribute("data-phosphor", p);
      var resume = function () {
        video.removeEventListener("loadedmetadata", resume);
        try {
          if (frac && video.duration) {
            video.currentTime = frac * video.duration;
          }
        } catch (x) { /* a position the new file lacks */ }
        if (playing) {
          var pr = video.play();
          if (pr && pr.catch) { pr.catch(function () { /* refused */ }); }
        } else {
          video.pause();
        }
      };
      video.addEventListener("loadedmetadata", resume);
      video.load();
      mark();
    }

    function pick(axis, v, save) {
      if (cur[axis] === v) { mark(); return; }
      cur[axis] = v;
      show(false);
      if (save) { remember(axis === "d" ? DKEY : PKEY, v); }
    }

    mark();
    var wd = recall(DKEY), wp = recall(PKEY);
    var move = (wd && wd !== cur.d && displays.indexOf(wd) >= 0) ||
               (wp && wp !== cur.p && monitors.indexOf(wp) >= 0);
    if (move) {
      if (wd && displays.indexOf(wd) >= 0) { cur.d = wd; }
      if (wp && monitors.indexOf(wp) >= 0) { cur.p = wp; }
      show(true);
    }
  }

  var vids = document.querySelectorAll("video[data-display]");
  for (var i = 0; i < vids.length; i++) { wire(vids[i]); }
})();
