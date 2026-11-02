/* maux site: the emulator, in the page, in the same case as the films.

   Optional, and deliberately inert until asked. The page is built with
   a .film.emu screen inside figure.hero -- the monitor a demo plays in
   -- holding one link (a.emustart) whose href is the emulator
   configured for maux: the machine, the card size, the slots and the
   disk, all in its query string (site/build.py gen_tryemu). Without
   this script that link is an ordinary link and opens the same
   configured emulator in a new tab. With it, the click builds an
   iframe in the screen and the machine runs there.

   Why the click, rather than a frame in the markup: booting costs the
   release disk plus the emulator's own bundle, and nobody who is
   scrolling past should pay for that.

   The chin is the films' control strip (static/display.js builds the
   same one), with the same two axes and one difference each:

   - DISPLAY is a label, not a control. Apple2TS has no UltraTerm card,
     so this machine has one display and a dead button would be a lie.
   - PHOSPHOR is real. Apple2TS renders green, amber or black-and-white
     itself (its `color` parameter), so the swatch picks the monitor the
     machine comes up on rather than tinting a picture of one -- the
     same rule the films follow, where the colour is recorded and never
     filtered. The choice lives under the films' own localStorage key,
     so a reader who chose amber in /watch/ gets an amber machine here.

   The monitor is chosen BEFORE the machine boots, and once it is
   running the swatches go quiet rather than restarting it. Apple2TS
   can be told at run time (postMessage "updateParameters"), but it
   answers only to a handful of trusted origins -- localhost, file:,
   vscode-webview: -- and a site is none of them, so the only channel
   left would be a reload, and throwing away a reader's session to
   repaint it is not a trade worth making. A reload of the page offers
   the choice again. */
(function () {
  "use strict";
  var PKEY = "maux-phosphor";                 /* the films' own key */
  var PORDER = ["paper", "green", "amber"];
  /* the emulator's name for each monitor (its `color` parameter:
     color, nofringe, green, amber, white, inverse) */
  var A2COLOR = { paper: "white", green: "green", amber: "amber" };

  function recall(k) {
    try { return window.localStorage.getItem(k); } catch (x) { return null; }
  }
  function remember(k, v) {
    try { window.localStorage.setItem(k, v); } catch (x) { /* fine */ }
  }
  function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }

  function wire(box) {
    var start = box.querySelector("a.emustart");
    if (!start) return;
    var href = start.getAttribute("href");
    if (!href) return;
    /* The frame gets the canvas-only build of the same machine
       (data-frame-src, appmode=embed): inside a page, the emulator's own
       panels are a second interface competing with ours for the width,
       and the machine ends up a stamp in the corner. The link out, and
       the fallback here, keep the full interface. */
    var framed = box.getAttribute("data-frame-src") || href;
    var hero = box.parentNode;
    var cur = recall(PKEY);
    if (PORDER.indexOf(cur) < 0) {
      cur = box.getAttribute("data-phosphor") || PORDER[0];
    }
    var frame = null;
    var buttons = {};

    function src() {
      var sep = framed.indexOf("?") >= 0 ? "&" : "?";
      return framed + sep + "color=" + A2COLOR[cur];
    }

    function mark() {
      PORDER.forEach(function (p) {
        var b = buttons[p];
        if (!b) return;
        b.setAttribute("aria-pressed", p === cur ? "true" : "false");
        b.disabled = !!frame;
        b.title = cap(p) + " phosphor" + (frame
          ? " -- the monitor is set before the machine boots; reload"
            + " the page to change it"
          : "");
      });
    }

    function boot() {
      var f = document.createElement("iframe");
      f.className = "emuframe";
      f.setAttribute("src", src());
      f.setAttribute("title", "maux booting in an emulated Apple IIe");
      f.setAttribute("allow", "fullscreen; autoplay; clipboard-write");
      f.setAttribute("allowfullscreen", "");
      box.textContent = "";
      box.className = box.className + " emulive";
      box.appendChild(f);
      frame = f;
      mark();
      if (!hero.querySelector(".emuout")) {
        var out = document.createElement("p");
        out.className = "emuout";
        var a = document.createElement("a");
        a.setAttribute("href", href);
        a.setAttribute("target", "_blank");
        a.setAttribute("rel", "noopener");
        a.appendChild(document.createTextNode(
          "Open the emulator in its own tab"));
        out.appendChild(a);
        hero.appendChild(out);
      }
      /* An emulated IIe only sees the keys its frame receives. */
      f.addEventListener("load", function () {
        try { f.focus(); } catch (x) { /* fine */ }
      });
    }

    function pick(p) {
      if (frame || p === cur) { mark(); return; }
      cur = p;
      remember(PKEY, p);
      mark();
    }

    /* the chin, same strip as a film's (static/display.js) */
    var bar = document.createElement("div");
    bar.className = "monctl";
    var name = box.getAttribute("data-display-name");
    if (name) {
      var lab = document.createElement("span");
      lab.className = "monname";
      lab.appendChild(document.createTextNode(name));
      bar.appendChild(lab);
    }
    var phos = document.createElement("div");
    phos.className = "phos";
    phos.setAttribute("role", "group");
    phos.setAttribute("aria-label", "Phosphor");
    PORDER.forEach(function (p) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "sw sw-" + p;
      b.setAttribute("aria-label", p + " phosphor");
      b.addEventListener("click", function () { pick(p); });
      buttons[p] = b;
      phos.appendChild(b);
    });
    bar.appendChild(phos);
    hero.insertBefore(bar, box.nextSibling);
    mark();

    start.addEventListener("click", function (ev) {
      /* A modified click is the reader asking for a new tab or window;
         leave it to the browser and leave the page alone. */
      if (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey ||
          ev.button !== 0) return;
      ev.preventDefault();
      boot();
    });
  }

  var boxes = document.querySelectorAll("div.emu");
  for (var i = 0; i < boxes.length; i++) wire(boxes[i]);
})();
