/* School Printer - print page: upload, convert, preview, settings, print.
   The sheet layout here is the SAME maths the printer computer uses (watch.ps1 / schoolprinter.pl),
   so the preview shows what comes out of the printer. Units: millimetres. */
(function () {
  'use strict';
  var $ = function (i) { return document.getElementById(i); };
  var MARG = { none: 0, narrow: 6.35, normal: 12.7, wide: 25.4 };
  var KEYS = ['paper', 'orientation', 'color', 'duplex', 'margins', 'scale', 'nup'];
  var S = { copies: 1, pmode: 'all', range: '', paper: '', orientation: 'auto', color: 'color', duplex: 'off', margins: 'none', scale: 'fit', nup: '1' };
  try { var saved = JSON.parse(localStorage.getItem('sp-set') || '{}'); KEYS.forEach(function (k) { if (saved[k]) S[k] = saved[k]; }); } catch (e) {}
  try { $('pin').value = localStorage.getItem('sp-pin') || ''; } catch (e) {}
  if (window.pdfjsLib) pdfjsLib.GlobalWorkerOptions.workerSrc = '/assets/pdf.worker.min.js';

  var st0 = null, caps = null, files = [], sel = -1, busy = false, queue = [], uploading = false, renderTimer = null;
  var FCOL = { pdf: '#e5484d', doc: '#2b6cd8', docx: '#2b6cd8', rtf: '#2b6cd8', odt: '#2b6cd8', txt: '#6b7280', xls: '#1a7f37', xlsx: '#1a7f37', csv: '#1a7f37', ods: '#1a7f37', ppt: '#d9480f', pptx: '#d9480f', odp: '#d9480f' };

  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function ext(n) { var m = /\.([a-z0-9]+)$/i.exec(n || ''); return m ? m[1].toLowerCase() : ''; }
  function kb(n) { return n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB'; }
  function say(t, c) { $('msg').textContent = t || ''; $('msg').className = c || ''; }
  function save() { var o = {}; KEYS.forEach(function (k) { o[k] = S[k]; }); try { localStorage.setItem('sp-set', JSON.stringify(o)); } catch (e) {} }

  /* ---------------- status + capabilities ---------------- */
  function paint() {
    var s = st0; if (!s) return;
    $('dot').className = 'dot ' + (!s.open ? 'err' : s.waiting ? 'warn' : 'ok');
    $('qt').textContent = !s.open ? L('closed') : s.waiting ? L('waitingN', { n: s.waiting }) : L('ready');
    var office = s.office === 'office' || s.office === 'lo';
    $('typesTxt').textContent = office ? L('typesAll') : L('typesBasic');
    $('officeNote').hidden = office;
    $('officeNote').textContent = s.office === 'signin' ? L('officeSignin') : L('officeNone');
    $('f').accept = (s.types || []).map(function (t) { return '.' + t; }).join(',');
  }
  var ORDER = ['a4', 'letter', 'a5', 'legal', 'a3', 'a6', 'b5', 'executive', 'tabloid'];
  function rank(n) { var l = n.toLowerCase(); for (var i = 0; i < ORDER.length; i++) if (l.indexOf(ORDER[i]) === 0) return i; return 99; }
  function applyCaps(c) {
    var key = JSON.stringify(c); if (caps && JSON.stringify(caps) === key) return;
    caps = c;
    var ps = (c.papers || []).slice().sort(function (a, b) { return rank(a.n) - rank(b.n) || a.n.localeCompare(b.n); });
    if (!ps.some(function (p) { return p.n === S.paper; })) S.paper = c.def || (ps[0] && ps[0].n) || '';
    $('paper').innerHTML = ps.map(function (p) {
      return '<option value="' + esc(p.n) + '"' + (p.n === S.paper ? ' selected' : '') + '>' + esc(p.n) + ' · ' + Math.round(p.w) + '×' + Math.round(p.h) + ' mm</option>';
    }).join('');
    var colorBtn = document.querySelector('[data-k=color] [data-v=color]');
    colorBtn.disabled = !c.color; $('monoHint').hidden = !!c.color; if (!c.color) S.color = 'gray';
    $('duplexRow').hidden = !c.duplex; if (!c.duplex) S.duplex = 'off';
    syncSeg(); schedule();
  }
  function status() {
    fetch('/status').then(function (r) { return r.json(); }).then(function (s) {
      st0 = s; serverLang(s.lang); $('pname').textContent = s.printer || ''; $('pinbox').hidden = !s.pin;
      if (s.caps) applyCaps(s.caps); paint(); renderList();
    }).catch(function () { st0 = null; $('dot').className = 'dot err'; $('qt').textContent = L('offline'); });
  }

  /* ---------------- settings controls ---------------- */
  function syncSeg() {
    [].forEach.call(document.querySelectorAll('.seg'), function (g) {
      var k = g.getAttribute('data-k');
      [].forEach.call(g.querySelectorAll('button'), function (b) { b.setAttribute('aria-pressed', String(b.getAttribute('data-v') === String(S[k]))); });
    });
    $('rangeRow').hidden = S.pmode !== 'custom';
  }
  [].forEach.call(document.querySelectorAll('.seg'), function (g) {
    g.addEventListener('click', function (e) {
      var b = e.target.closest('button'); if (!b || b.disabled) return;
      S[g.getAttribute('data-k')] = b.getAttribute('data-v'); save(); syncSeg(); schedule();
      if (g.getAttribute('data-k') === 'pmode' && S.pmode === 'custom') $('range').focus();
    });
  });
  $('paper').onchange = function () { S.paper = this.value; save(); schedule(); };
  $('range').oninput = function () { S.range = this.value; schedule(); };
  function cp(d) { var v = Math.min(20, Math.max(1, (+$('c').value || 1) + d)); $('c').value = v; S.copies = v; schedule(); }
  $('minus').onclick = function () { cp(-1); }; $('plus').onclick = function () { cp(1); }; $('c').onchange = function () { cp(0); };
  $('guides').onchange = function () { $('sheets').classList.toggle('noguides', !this.checked); };
  syncSeg();

  /* ---------------- files ---------------- */
  function renderList() {
    $('list').innerHTML = files.map(function (f, i) {
      var e = ext(f.name), sub, icon = '<span class="ficon" style="background:' + (FCOL[e] || '#8b5cf6') + '">' + esc(e.toUpperCase().slice(0, 4)) + '</span>';
      if (f.state === 'uploading') sub = L('uploading', { p: f.pct || 0 });
      else if (f.state === 'converting') sub = L('converting');
      else if (f.state === 'loading') sub = L('loadingPrev');
      else if (f.state === 'ready') sub = (f.pages ? (f.pages.length === 1 ? L('pages1') : L('pagesN', { n: f.pages.length })) : '') + ' · ' + kb(f.size);
      else sub = f.err || L('error');
      var spin = (f.state === 'uploading' || f.state === 'converting' || f.state === 'loading') ? '<span class="spin"></span>' : '';
      var prog = f.state === 'uploading' ? '<span class="prog" style="width:' + (f.pct || 0) + '%"></span>' : '';
      return '<li data-i="' + i + '" class="' + (i === sel ? 'sel ' : '') + (f.state === 'error' ? 'bad' : '') + '">' + icon +
        '<span class="nm"><b>' + esc(f.name) + '</b><em>' + esc(sub) + '</em></span>' + spin +
        '<button class="x" data-x="' + i + '" aria-label="' + esc(L('remove')) + '">&times;</button>' + prog + '</li>';
    }).join('');
    var ready = files.filter(function (f) { return f.state === 'ready'; }).length;
    $('go').disabled = busy || !ready || !st0 || !st0.open || files.some(function (f) { return f.state !== 'ready' && f.state !== 'error'; });
    $('go').textContent = ready > 1 ? L('printN', { n: ready }) : L('print');
  }
  $('list').onclick = function (e) {
    var x = e.target.getAttribute('data-x');
    if (x !== null) { var f = files.splice(+x, 1)[0]; if (f && f.urls) for (var k in f.urls) URL.revokeObjectURL(f.urls[k]);
      if (sel >= files.length) sel = files.length - 1; if (+x < sel) sel--; renderList(); schedule(); return; }
    var li = e.target.closest('li'); if (li) { sel = +li.getAttribute('data-i'); renderList(); schedule(); }
  };
  function add(list) {
    var types = (st0 && st0.types) || ['pdf', 'jpg', 'jpeg', 'png'];
    for (var i = 0; i < list.length; i++) {
      var f = list[i], e = ext(f.name);
      var entry = { file: f, name: f.name, size: f.size, state: 'uploading', pct: 0, urls: {} };
      if (types.indexOf(e) < 0) { entry.state = 'error'; entry.err = L('notAllowed'); }
      else if (f.size > 50 * 1048576) { entry.state = 'error'; entry.err = L('eBig'); }
      else queue.push(entry);
      files.push(entry); if (sel < 0 && entry.state !== 'error') sel = files.length - 1;
    }
    renderList(); pump(); say('');
  }
  $('f').onchange = function () { add(this.files); this.value = ''; };
  ['dragenter', 'dragover'].forEach(function (t) { $('drop').addEventListener(t, function (e) { e.preventDefault(); $('drop').classList.add('over'); }); });
  ['dragleave', 'drop'].forEach(function (t) { $('drop').addEventListener(t, function (e) { e.preventDefault(); $('drop').classList.remove('over'); }); });
  $('drop').addEventListener('drop', function (e) { add(e.dataTransfer.files); });

  function pin() { var p = $('pin').value; try { localStorage.setItem('sp-pin', p); } catch (e) {} return p; }
  function fail(f, m) { f.state = 'error'; f.err = m; renderList(); schedule(); }
  function pump() {
    if (uploading || !queue.length) return;
    var f = queue.shift(); if (files.indexOf(f) < 0) return pump();
    uploading = true;
    var x = new XMLHttpRequest(); x.open('POST', '/upload');
    x.setRequestHeader('X-Pin', pin()); x.setRequestHeader('X-Filename', encodeURIComponent(f.name));
    x.upload.onprogress = function (e) { if (e.lengthComputable) { f.pct = Math.round(e.loaded / e.total * 100); renderList(); } };
    x.onload = function () {
      uploading = false; var j = {}; try { j = JSON.parse(x.responseText); } catch (e) {}
      if (x.status !== 200) fail(f, E(j.error) || L('error') + ' ' + x.status);
      else { f.id = j.id; f.kind = j.kind; if (j.state === 'converting') { f.state = 'converting'; renderList(); poll(f); } else loadDoc(f); }
      pump();
    };
    x.onerror = function () { uploading = false; fail(f, L('noReach')); pump(); };
    x.send(f.file);
  }
  function poll(f) {
    if (files.indexOf(f) < 0) return;
    fetch('/info/' + f.id).then(function (r) { return r.json(); }).then(function (j) {
      if (j.state === 'ready') { f.kind = j.kind; loadDoc(f); }
      else if (j.state === 'failed') fail(f, L('convFail'));
      else if (j.state === 'gone') fail(f, L('eGone'));
      else setTimeout(function () { poll(f); }, 900);
    }).catch(function () { setTimeout(function () { poll(f); }, 2000); });
  }
  function loadDoc(f) {
    f.state = 'loading'; renderList();
    var url = '/file/' + f.id;
    if (f.kind === 'image') {
      var img = new Image();
      img.onload = function () { f.pages = [{ w: img.naturalWidth * 25.4 / 96, h: img.naturalHeight * 25.4 / 96 }]; f.urls[0] = url; f.state = 'ready'; renderList(); schedule(); };
      img.onerror = function () { f.pages = [{ w: 210, h: 297 }]; f.noPrev = true; f.state = 'ready'; renderList(); schedule(); };
      img.src = url; return;
    }
    if (!window.pdfjsLib) { f.pages = [{ w: 210, h: 297 }]; f.noPrev = true; f.state = 'ready'; renderList(); schedule(); return; }
    pdfjsLib.getDocument({ url: url, isEvalSupported: false }).promise.then(function (doc) {
      f.pdf = doc; var ps = [], n = doc.numPages, done = 0;
      for (var i = 1; i <= n; i++) (function (i) {
        doc.getPage(i).then(function (p) { var v = p.getViewport({ scale: 1 }); ps[i - 1] = { w: v.width * 25.4 / 72, h: v.height * 25.4 / 72 };
          if (++done === n) { f.pages = ps; f.state = 'ready'; renderList(); schedule(); } });
      })(i);
    }).catch(function () { f.pages = [{ w: 210, h: 297 }]; f.noPrev = true; f.state = 'ready'; renderList(); schedule(); });
  }
  function pageUrl(f, i, cb) {
    if (f.urls[i]) return cb(f.urls[i]);
    if (!f.pdf) return cb(null);
    f.pdf.getPage(i + 1).then(function (p) {
      var v1 = p.getViewport({ scale: 1 }), sc = Math.min(3, 900 / v1.width), v = p.getViewport({ scale: sc });
      var c = document.createElement('canvas'); c.width = Math.round(v.width); c.height = Math.round(v.height);
      var ctx = c.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height);
      p.render({ canvasContext: ctx, viewport: v }).promise.then(function () {
        c.toBlob(function (b) { f.urls[i] = URL.createObjectURL(b); cb(f.urls[i]); }, 'image/jpeg', 0.85);
      });
    }).catch(function () { cb(null); });
  }

  /* ---------------- layout (shared maths) ---------------- */
  function parseRange(txt, n) {
    if (!txt || !txt.trim()) return null;
    if (!/^\s*\d+(\s*-\s*\d+)?(\s*,\s*\d+(\s*-\s*\d+)?)*\s*,?\s*$/.test(txt)) return false;
    var out = [];
    txt.split(',').forEach(function (part) {
      if (!part.trim()) return; var m = part.split('-'), a = +m[0], b = m.length > 1 ? +m[1] : a;
      if (a > b) { var t = a; a = b; b = t; }
      for (var k = Math.max(1, a); k <= Math.min(n, b); k++) if (out.indexOf(k - 1) < 0) out.push(k - 1);
    });
    out.sort(function (a, b) { return a - b; });
    return out.length ? out : false;
  }
  function layout(pages) {
    var sel = null;
    if (S.pmode === 'custom') { sel = parseRange(S.range, pages.length); if (sel === false) return { error: L('badRange', { n: pages.length }) }; }
    if (!sel) { sel = []; for (var i = 0; i < pages.length; i++) sel.push(i); }
    var paper = (caps && caps.papers || []).filter(function (p) { return p.n === S.paper; })[0] || { w: 210, h: 297 };
    var pw = Math.min(paper.w, paper.h), ph = Math.max(paper.w, paper.h), nup = +S.nup;
    var first = pages[sel[0]], pageLand = first.w > first.h, land;
    if (S.orientation === 'portrait') land = false; else if (S.orientation === 'landscape') land = true; else land = nup === 2 ? !pageLand : pageLand;
    var W = land ? ph : pw, H = land ? pw : ph, m = Math.max(MARG[S.margins] || 0, (caps && caps.hm) || 0);
    var cols = 1, rows = 1; if (nup === 4) { cols = 2; rows = 2; } else if (nup === 2) { if (land) cols = 2; else rows = 2; }
    var cw = (W - 2 * m) / cols, ch = (H - 2 * m) / rows, sheets = [];
    for (var s = 0; s < sel.length; s += nup) sheets.push(sel.slice(s, s + nup));
    return { W: W, H: H, m: m, cols: cols, rows: rows, cw: cw, ch: ch, sheets: sheets, sel: sel, land: land };
  }
  function place(Lo, k, size) {
    var c = k % Lo.cols, r = Math.floor(k / Lo.cols), x0 = Lo.m + c * Lo.cw, y0 = Lo.m + r * Lo.ch;
    var f = S.scale === 'fit' ? Math.min(Lo.cw / size.w, Lo.ch / size.h) : 1, w = size.w * f, h = size.h * f;
    return { cx: x0, cy: y0, x: x0 + (Lo.cw - w) / 2, y: y0 + (Lo.ch - h) / 2, w: w, h: h };
  }

  /* ---------------- preview ---------------- */
  var io = 'IntersectionObserver' in window ? new IntersectionObserver(function (es) {
    es.forEach(function (e) { if (e.isIntersecting) { io.unobserve(e.target); loadImg(e.target); } });
  }, { root: $('sheets'), rootMargin: '400px' }) : null;
  function loadImg(img) {
    var f = files[+img.getAttribute('data-f')], i = +img.getAttribute('data-p'); if (!f) return;
    pageUrl(f, i, function (u) { if (u) { img.src = u; img.classList.remove('loading'); } });
  }
  function schedule() { clearTimeout(renderTimer); renderTimer = setTimeout(render, 60); }
  function render() {
    var box = $('sheets'), f = files[sel];
    if (!f || f.state !== 'ready' || !f.pages) {
      $('sheetsTxt').textContent = '';
      box.innerHTML = '<div class="empty">' + esc(f && f.state === 'error' ? f.err : f ? L(f.state === 'converting' ? 'converting' : 'loadingPrev') : L('emptyPrev')) + '</div>';
      return;
    }
    var Lo = layout(f.pages);
    if (Lo.error) { $('sheetsTxt').textContent = ''; box.innerHTML = '<div class="empty err">' + esc(Lo.error) + '</div>'; return; }
    var copies = +S.copies || 1, paperCount = (S.duplex !== 'off' ? Math.ceil(Lo.sheets.length / 2) : Lo.sheets.length) * copies;
    $('sheetsTxt').textContent = '· ' + L('sheetsN', { n: paperCount });
    var avail = Math.max(160, box.clientWidth - 44), dispW = Math.min(Lo.W > Lo.H ? 520 : 380, avail), k = dispW / Lo.W, dispH = Lo.H * k;
    var MAX = 40, html = '', gray = S.color === 'gray' ? ' gray' : '';
    for (var s = 0; s < Math.min(Lo.sheets.length, MAX); s++) {
      html += '<div class="sheetwrap"><div class="sheet' + gray + '" style="width:' + dispW.toFixed(1) + 'px;height:' + dispH.toFixed(1) + 'px">';
      html += '<div class="guide" style="left:' + (Lo.m * k) + 'px;top:' + (Lo.m * k) + 'px;right:' + (Lo.m * k) + 'px;bottom:' + (Lo.m * k) + 'px"></div>';
      Lo.sheets[s].forEach(function (pi, j) {
        var p = place(Lo, j, f.pages[pi]);
        html += '<div class="cell" style="left:' + (p.cx * k) + 'px;top:' + (p.cy * k) + 'px;width:' + (Lo.cw * k) + 'px;height:' + (Lo.ch * k) + 'px">' +
          '<img class="pg loading" alt="" data-f="' + sel + '" data-p="' + pi + '" style="left:' + ((p.x - p.cx) * k) + 'px;top:' + ((p.y - p.cy) * k) + 'px;width:' + (p.w * k) + 'px;height:' + (p.h * k) + 'px"></div>';
      });
      html += '</div><span class="cap">' + esc(L('sheetOf', { a: s + 1, b: Lo.sheets.length })) + '</span></div>';
    }
    if (Lo.sheets.length > MAX) html += '<div class="more">' + esc(L('moreSheets', { n: Lo.sheets.length - MAX })) + '</div>';
    if (f.noPrev) html = '<div class="empty">' + esc(L('prevFail')) + '</div>' + html;
    box.innerHTML = html;
    [].forEach.call(box.querySelectorAll('img.pg'), function (img) { if (io) io.observe(img); else loadImg(img); });
  }
  window.addEventListener('resize', schedule);
  window.onLang = function () { renderList(); paint(); syncSeg(); schedule(); };

  /* ---------------- print ---------------- */
  function settingsFor() {
    return { copies: +$('c').value || 1, pages: S.pmode === 'custom' ? S.range.trim() : '', paper: S.paper, orientation: S.orientation,
      color: S.color, duplex: S.duplex, margins: S.margins, scale: S.scale, nup: +S.nup };
  }
  $('go').onclick = function () {
    var todo = files.filter(function (f) { return f.state === 'ready'; });
    for (var t = 0; t < todo.length; t++) { var Lo = layout(todo[t].pages); if (Lo.error) { sel = files.indexOf(todo[t]); renderList(); schedule(); say(todo[t].name + ': ' + Lo.error, 'err'); return; } }
    busy = true; renderList(); $('bar').hidden = false; $('bi').style.width = '0';
    var p = pin(), done = 0, cfg = settingsFor();
    (function next() {
      if (!todo.length) { busy = false; $('bar').hidden = true; renderList(); schedule(); say(L('sent', { n: done }), 'ok'); status(); return; }
      var f = todo.shift(); say(L('sending', { f: f.name }));
      var body = JSON.parse(JSON.stringify(cfg)); body.id = f.id; body.land = layout(f.pages).land;   // what 'Auto' resolved to (used by the Mac/Linux version)
      fetch('/print', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Pin': p }, body: JSON.stringify(body) })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (r) {
          if (!r.ok) { busy = false; $('bar').hidden = true; renderList(); say(f.name + ': ' + E(r.j.error), 'err'); return; }
          done++; $('bi').style.width = (done / (done + todo.length) * 100) + '%';
          var i = files.indexOf(f); if (i >= 0) { files.splice(i, 1); if (sel >= files.length) sel = files.length - 1; }
          next();
        }).catch(function () { busy = false; $('bar').hidden = true; renderList(); say(L('noReach'), 'err'); });
    })();
  };

  status(); setInterval(status, 5000);
})();
