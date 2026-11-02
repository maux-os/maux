/* maux site: the demo captions, drawn by the page.
   Optional. Without this script the browser's own caption renderer shows
   the WebVTT track, centred (every cue carries line:40% position:50%
   align:center size:80%). With it, the track is switched to "hidden" and
   the active cue is drawn in the overlay inside the .film wrapper: a plate
   at 40% of the picture's height, with a dim layer over the picture while
   it shows. It follows the video across seeking, looping and the display
   selector's track swap (static/display.js), because it reads whatever
   text tracks the video has at the moment a cue changes.

   Captions on/off: the browser's own captions menu is honoured ("showing"
   or "hidden" is on; "disabled" is off and clears the plate at once), and
   a small Captions button (its own labelled group above the film) does the same and is
   remembered. When the menu sets a track to "showing", the browser's own
   rendering is suppressed (style.css, .film-ov) so a cue is never drawn
   twice. */
(function () {
  "use strict";
  var KEY = "maux-captions";

  function recall() {
    try { return window.localStorage.getItem(KEY); } catch (x) { return null; }
  }
  function remember(v) {
    try { window.localStorage.setItem(KEY, v); } catch (x) { /* fine */ }
  }

  function wire(film) {
    var video = film.querySelector("video");
    var plate = film.querySelector(".film-plate");
    if (!video || !plate || !video.textTracks) { return; }
    var shown = null;          // the cue text on screen, or null
    var native = false;        // fullscreen: the native renderer takes over
    var on = recall() !== "off";
    var button = null;

    function setClass() {
      if (native) { film.classList.remove("film-ov"); }
      else { film.classList.add("film-ov"); }
    }

    function activeCue() {
      var tt = video.textTracks;
      for (var i = 0; i < tt.length; i++) {
        var t = tt[i];
        if (t.kind !== "captions" && t.kind !== "subtitles") { continue; }
        if (t.mode === "disabled") { continue; }
        var a = t.activeCues;
        if (a && a.length) { return a[0]; }
      }
      return null;
    }

    function fill(cue) {
      while (plate.firstChild) { plate.removeChild(plate.firstChild); }
      if (cue.getCueAsHTML) {
        plate.appendChild(cue.getCueAsHTML());
      } else {
        plate.textContent = cue.text;
      }
    }

    function show(cue) {
      plate.classList.remove("is-out");
      plate.classList.remove("is-in");
      void plate.offsetWidth;            // restart the animation
      fill(cue);
      plate.classList.add("is-in");
      film.classList.add("is-narrating");
    }

    function hide(now) {
      if (shown === null) { return; }
      plate.classList.remove("is-in");
      if (now) {
        plate.classList.remove("is-out");
      } else {
        plate.classList.add("is-out");
      }
      film.classList.remove("is-narrating");
    }

    function refresh() {
      var cue = (native || !on) ? null : activeCue();
      var text = cue ? cue.text : null;
      if (text === shown) { return; }
      if (cue) { show(cue); } else { hide(!on); }
      shown = text;
    }

    function modeFor() {
      if (!on) { return "disabled"; }
      return native ? "showing" : "hidden";
    }

    function hook(track) {
      if (track.__mauxCaps) { return; }
      track.__mauxCaps = true;
      track.mode = modeFor();
      track.addEventListener("cuechange", refresh);
    }

    function paint() {
      if (button) { button.setAttribute("aria-pressed", on ? "true" : "false"); }
    }

    function apply() {
      for (var i = 0; i < video.textTracks.length; i++) {
        if (video.textTracks[i].__mauxCaps) {
          video.textTracks[i].mode = modeFor();
        }
      }
      paint();
      refresh();
    }

    function hookAll() {
      for (var i = 0; i < video.textTracks.length; i++) {
        hook(video.textTracks[i]);
      }
      refresh();
    }

    // The browser's captions menu: any hooked track not "disabled" is on.
    function menuChanged() {
      var seen = false, any = false;
      for (var i = 0; i < video.textTracks.length; i++) {
        var t = video.textTracks[i];
        if (!t.__mauxCaps) { continue; }
        seen = true;
        if (t.mode !== "disabled") { any = true; }
      }
      if (!seen || any === on) { refresh(); return; }
      on = any;
      remember(on ? "on" : "off");
      paint();
      refresh();
    }

    function setNative(v) {
      native = v;
      setClass();
      apply();
    }

    // The toggle, in its own labelled group above the film (after the
    // display picker's group, when there is one).
    var bar = document.createElement("div");
    bar.className = "display-pick";
    bar.setAttribute("role", "group");
    bar.setAttribute("aria-label", "Captions");
    film.parentNode.insertBefore(bar, film);
    button = document.createElement("button");
    button.type = "button";
    button.textContent = "Captions";
    button.title = "Show or hide the captions";
    button.addEventListener("click", function () {
      on = !on;
      remember(on ? "on" : "off");
      apply();
    });
    bar.appendChild(button);

    video.textTracks.addEventListener("addtrack", hookAll);
    video.textTracks.addEventListener("removetrack", refresh);
    video.textTracks.addEventListener("change", menuChanged);
    ["seeked", "timeupdate", "emptied", "loadedmetadata", "ended"]
      .forEach(function (ev) { video.addEventListener(ev, refresh); });
    // A <video> in fullscreen shows only itself, not the overlay: hand the
    // captions back to the browser there.
    document.addEventListener("fullscreenchange", function () {
      setNative(document.fullscreenElement === video);
    });
    video.addEventListener("webkitbeginfullscreen", function () { setNative(true); });
    video.addEventListener("webkitendfullscreen", function () { setNative(false); });
    setClass();
    paint();
    hookAll();
  }

  var films = document.querySelectorAll(".film");
  for (var i = 0; i < films.length; i++) { wire(films[i]); }
})();
