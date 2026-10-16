// Cornetta · sito. Script unico, servito come file (CSP: script-src 'self').
(function () {
  "use strict";
  var it = document.documentElement.lang !== "en";
  var t = it
    ? { mac: "Scarica per Mac", win: "Scarica per Windows", phone: "Cornetta funziona sul computer: apri questa pagina dal Mac o dal PC.", winSoon: "La versione per Windows è in arrivo.", copy: "Copia il link", copied: "Link copiato", mb: "MB", version: "Versione", winReq: "Windows 10 e 11" }
    : { mac: "Download for Mac", win: "Download for Windows", phone: "Cornetta runs on your computer: open this page on your Mac or PC.", winSoon: "The Windows version is coming soon.", copy: "Copy link", copied: "Link copied", mb: "MB", version: "Version", winReq: "Windows 10 and 11" };

  var ua = navigator.userAgent;
  var isPhone = /iPhone|iPad|iPod|Android/i.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  var isWindows = /Windows/i.test(ua);

  function size(bytes) {
    return (bytes / 1048576).toLocaleString(it ? "it-IT" : "en-US", { maximumFractionDigits: 1 }) + " " + t.mb;
  }

  // Versione, peso e checksum veri, dal file che pubblica lo script di rilascio.
  fetch("/downloads/latest.json", { cache: "no-store" })
    .then(function (r) { return r.ok ? r.json() : Promise.reject(r.status); })
    .then(function (latest) {
      document.querySelectorAll("[data-meta]").forEach(function (el) {
        var platform = el.getAttribute("data-meta");
        var info = latest[platform];
        if (!info) return;
        el.textContent = t.version + " " + info.version + " · " + size(info.size) + " · " + el.getAttribute("data-requirements");
      });
      document.querySelectorAll("[data-sha]").forEach(function (el) {
        var info = latest[el.getAttribute("data-sha")];
        if (info && info.sha256) el.textContent = info.sha256;
      });
      // L'HTML propone già Windows in beta, così lo leggono anche motori di ricerca e assistenti senza JavaScript.
      // Se latest.json perde la voce windows, la pagina torna a «in sviluppo».
      if (latest.windows) {
        if (isWindows) {
          document.querySelectorAll("[data-download-primary]").forEach(function (a) {
            a.href = "/download/windows";
            a.querySelector("span").textContent = t.win;
          });
          // Su un PC il pulsante principale è già Windows: la riga «Hai un PC?» lascia il posto a «Hai un Mac?».
          document.querySelectorAll(".meta-alt[data-windows]").forEach(function (el) { el.hidden = true; });
          document.querySelectorAll("[data-windows-mac]").forEach(function (el) { el.hidden = false; });
          document.querySelectorAll("[data-meta=mac]").forEach(function (el) {
            var info = latest.windows;
            el.textContent = t.version + " " + info.version + " beta · " + size(info.size) + " · " + t.winReq;
          });
        }
      } else {
        document.querySelectorAll("[data-windows]").forEach(function (el) { el.hidden = true; });
        document.querySelectorAll("[data-windows-soon]").forEach(function (el) { el.hidden = false; });
        var note = document.getElementById("os-note");
        if (note && isWindows) { note.textContent = t.winSoon; note.hidden = false; }
      }
    })
    .catch(function () {});

  if (isPhone) {
    var note = document.getElementById("os-note");
    if (note) {
      note.textContent = t.phone + " ";
      var button = document.createElement("button");
      button.type = "button";
      button.className = "btn btn-secondary";
      button.textContent = t.copy;
      button.addEventListener("click", function () {
        navigator.clipboard.writeText(location.href).then(function () { button.textContent = t.copied; });
      });
      note.appendChild(button);
      note.hidden = false;
    }
  }

  var nav = document.querySelector(".nav");
  if (nav) {
    var onScroll = function () { nav.classList.toggle("scrolled", window.scrollY > 8); };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
  }
})();
