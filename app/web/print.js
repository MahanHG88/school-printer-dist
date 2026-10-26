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
    var office = s.office === 'office' || s.office === 'lo' || s.office === 'peer';    // peer: another station converts
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
    colorBtn.disabled = !c.color; $('monoHint').hidden = !!c.color; if (!c.color) S.color = 'gray';    // c.color: any connected printer
    $('duplexRow').hidden = !c.duplex; if (!c.duplex) S.duplex = 'off';
    syncSeg(); schedule();
  }
  function status() {
    fetch('/status').then(function (r) { return r.json(); }).then(function (s) {
      st0 = s; serverLang(s.lang); $('pname').textContent = s.printer || ''; $('pinbox').hidden = !s.pin;
      if (s.caps) applyCaps(s.caps); paint(); renderList();
      fails = 0; if (s.station) try { localStorage.setItem('sp-here', location.origin); } catch (e) {}
    }).catch(function () { st0 = null; $('dot').className = 'dot err'; $('qt').textContent = L('offline'); if (++fails >= 2) failover(); });
  }
  /* this station stopped answering (switched off, unplugged): go to another one - it sends people on to the new main station */
  var fails = 0, others = [], hopping = false;
  function rememberStations() { fetch('/stations').then(function (r) { return r.json(); }).then(function (j) {
    others = (j.list || []).filter(function (x) { return x.url && x.online && x.url !== location.origin; }).map(function (x) { return x.url; });
    try { localStorage.setItem('sp-others', JSON.stringify(others)); } catch (e) {} }).catch(function () {}); }
  function failover() {
    if (hopping || busy || scBusy) return; var list = others.slice();
    try { list = list.concat(JSON.parse(localStorage.getItem('sp-others') || '[]')); } catch (e) {}
    list = list.filter(function (u, i) { return u && u !== location.origin && list.indexOf(u) === i; }); if (!list.length) return;
    hopping = true; $('qt').textContent = L('hopping');
    (function next(i) {
      if (i >= list.length) { hopping = false; return; }
      var ctl = window.AbortController ? new AbortController() : null, t = setTimeout(function () { if (ctl) ctl.abort(); }, 2500);
      fetch(list[i] + '/status', { mode: 'no-cors', cache: 'no-store', signal: ctl ? ctl.signal : undefined })
        .then(function () { clearTimeout(t); location.href = list[i] + '/?moved=1'; })
        .catch(function () { clearTimeout(t); next(i + 1); });
    })(0);
  }
  rememberStations(); setInterval(rememberStations, 30000);

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
  function sheetsOf(f, cfg) { var Lo = layout(f.pages); if (Lo.error) return 1; return (cfg.duplex !== 'off' ? Math.ceil(Lo.sheets.length / 2) : Lo.sheets.length) * (cfg.copies || 1); }
  var pm = { mode: 'auto', todo: [], list: [], pick: '' };
  try { pm.mode = localStorage.getItem('sp-mode') || 'auto'; pm.pick = localStorage.getItem('sp-station') || ''; } catch (e) {}
  $('go').onclick = function () {
    var todo = files.filter(function (f) { return f.state === 'ready'; });
    for (var t = 0; t < todo.length; t++) { var Lo = layout(todo[t].pages); if (Lo.error) { sel = files.indexOf(todo[t]); renderList(); schedule(); say(todo[t].name + ': ' + Lo.error, 'err'); return; } }
    if (!todo.length) return;
    say(''); pm.todo = todo; $('pmchoose').hidden = false; $('pmrun').hidden = true; $('pm').hidden = false;
    var cfg = settingsFor(), sh = 0; todo.forEach(function (f) { sh += sheetsOf(f, cfg); });
    $('pmsum').textContent = (todo.length === 1 ? L('pmSum1', { s: sh }) : L('pmSumN', { n: todo.length, s: sh })) + ' · ' + (cfg.color === 'color' ? L('colorC') : L('colorBW')) + ' · ' + cfg.paper;
    renderPm(); loadStations();
  };
  function loadStations() { fetch('/stations').then(function (r) { return r.json(); }).then(function (j) { pm.list = j.list || []; pm.auto = j.auto; renderPm(); }).catch(function () { pm.list = []; renderPm(); }); }
  function fits(x, cfg) { return (cfg.color !== 'color' || x.color) && (cfg.duplex === 'off' || x.duplex); }
  function stLabel(x, cfg) {
    var st = !x.online ? L('pmOff') : !x.ready ? L('pmBusy') : x.queue ? L('pmQn', { n: x.queue }) : L('pmQ0');
    return x.station + (x.here ? ' (' + L('pmHere') + ')' : '') + ' — ' + (x.printer || '?') + ' · ' + st + (cfg.color === 'color' && !x.color ? ' · ' + L('pmBW') : '');
  }
  function bestAuto(cfg) {
    var ready = pm.list.filter(function (x) { return x.ready && (x.here || pm.auto); }); if (!ready.length) return null;
    var fit = ready.filter(function (x) { return fits(x, cfg); }); if (!fit.length) fit = ready;
    return fit.reduce(function (b, x) { return x.queue < b.queue ? x : b; }, fit[0]);
  }
  function renderPm() {
    var cfg = settingsFor(), multi = pm.list.length > 1;
    if (!multi) pm.mode = 'auto';
    [].forEach.call(document.querySelectorAll('.opt'), function (b) { b.setAttribute('aria-checked', String(b.getAttribute('data-mode') === pm.mode)); b.disabled = !multi && b.getAttribute('data-mode') === 'pick'; });
    $('pmone').hidden = multi || !pm.list.length; $('pmpick').hidden = pm.mode !== 'pick';
    var b = bestAuto(cfg); $('pmnow').textContent = b && multi ? L('pmNow', { s: b.station + ' · ' + (b.queue ? L('pmQn', { n: b.queue }) : L('pmQ0')) }) : '';
    if (document.activeElement !== $('pmsel')) {
      var ok = pm.list.filter(function (x) { return x.ready; });
      if (!ok.some(function (x) { return x.id === pm.pick; })) { var f = ok.filter(function (x) { return fits(x, cfg); })[0] || ok[0]; pm.pick = f ? f.id : ''; }
      $('pmsel').innerHTML = pm.list.map(function (x) { return '<option value="' + esc(x.id) + '"' + (x.ready ? '' : ' disabled') + (x.id === pm.pick ? ' selected' : '') + '>' + esc(stLabel(x, cfg)) + '</option>'; }).join('');
    }
    var cur = pm.list.filter(function (x) { return x.id === pm.pick; })[0];
    $('pmhint').textContent = cur && cfg.color === 'color' && !cur.color ? L('pmBW') : '';
    var miss = pm.mode === 'pick' && !cur ? L('pmChoose') : '';
    $('pmmiss').textContent = miss; $('pmgo').disabled = !!miss;
  }
  [].forEach.call(document.querySelectorAll('.opt'), function (b) { b.onclick = function () { pm.mode = b.getAttribute('data-mode'); try { localStorage.setItem('sp-mode', pm.mode); } catch (e) {} renderPm(); if (pm.mode === 'pick') $('pmsel').focus(); }; });
  $('pmsel').onchange = function () { pm.pick = this.value; try { localStorage.setItem('sp-station', pm.pick); } catch (e) {} renderPm(); };
  function closePm() { if (!busy) $('pm').hidden = true; }
  $('pmclose').onclick = closePm; $('pm').onclick = function (e) { if (e.target === this) closePm(); };
  $('pmok').onclick = function () { $('pm').hidden = true; };

  function stage(c) { $('pmstage').className = 'stage' + (c ? ' ' + c : ''); }
  function finish(ok, title, detail) {
    busy = false; stage(ok ? 'done' : 'fail'); $('pmstate').textContent = title; $('pmdetail').innerHTML = detail || ''; $('pmok').hidden = false; $('pmok').focus();
    renderList(); schedule(); status();
  }
  $('pmgo').onclick = function () {
    var todo = pm.todo.slice(), cfg = settingsFor(), p = pin(), target = pm.mode === 'pick' ? pm.pick : 'auto', sent = [];
    busy = true; renderList(); $('pmchoose').hidden = true; $('pmrun').hidden = false; $('pmok').hidden = true; stage('');
    $('pmstate').textContent = L('pmSending'); $('pmdetail').textContent = ''; $('pmlist').innerHTML = '';
    (function next() {
      if (!todo.length) return follow(sent);
      var f = todo.shift(), body = JSON.parse(JSON.stringify(cfg));
      body.id = f.id; body.land = layout(f.pages).land; body.sheets = sheetsOf(f, cfg); body.target = target;
      fetch('/print', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Pin': p }, body: JSON.stringify(body) })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (r) {
          if (!r.ok) { if (!sent.length) { loadStations(); } return finish(false, L('pmFailH'), esc(f.name + ': ' + E(r.j.error))); }
          sent.push({ f: f, jid: r.j.jid, station: r.j.station || '', first: r.j.station || '', state: r.j.jid ? 'sending' : 'done', ahead: 0 });
          var i = files.indexOf(f); if (i >= 0) { files.splice(i, 1); if (sel >= files.length) sel = files.length - 1; }
          next();
        }).catch(function () { finish(false, L('pmFailH'), esc(L('noReach'))); });
    })();
  };
  var WHY = { STATION_LOST: 'pmMovedLost', PRINTER_ERROR: 'pmMovedJam', NOT_TAKEN: 'pmMoved' };
  var FAILS = { STATION_LOST: 'pmFailLost', PRINTER_ERROR: 'pmFailJam', NOT_TAKEN: 'pmFailNone', FAILED: 'pmFailNone' };
  function follow(sent) {
    var t0 = Date.now();
    function list() {
      $('pmlist').innerHTML = sent.length < 2 ? '' : sent.map(function (x) {
        return '<li><b>' + esc(x.f.name) + '</b><span>' + esc(x.station) + '</span></li>'; }).join('');
    }
    (function tick() {
      var open = sent.filter(function (x) { return x.jid && x.state !== 'printing' && x.state !== 'done' && x.state !== 'failed' && x.state !== 'gone'; });
      var bad = sent.filter(function (x) { return x.state === 'failed'; });
      list();
      if (bad.length) return finish(false, L('pmFailH'), esc(bad[0].f.name + ': ' + (FAILS[bad[0].err] ? L(FAILS[bad[0].err]) : bad[0].err || L('error'))));
      if (!open.length) {
        var names = sent.map(function (x) { return x.station; }).filter(function (v, i, a) { return v && a.indexOf(v) === i; });
        var d = names.length === 1 ? L('pmPickup', { s: '<b class="pickup">' + esc(names[0]) + '</b>' }) : names.length ? L('pmPickupN') : '';
        var moved = sent.filter(function (x) { return x.moved; })[0];
        if (moved) d += '<br><span class="sm">' + esc(L(WHY[moved.why] || 'pmMoved', { a: moved.first, b: moved.station })) + '</span>';
        var ahead = Math.max.apply(null, sent.map(function (x) { return x.ahead || 0; })); if (ahead) d += '<br><span class="sm">' + esc(L('pmAhead', { n: ahead })) + '</span>';
        return finish(true, L('pmDoneH'), d);
      }
      var w = open[0]; $('pmstate').textContent = w.state === 'queued' ? L('pmWaiting', { s: w.station }) : L('pmSending');
      $('pmdetail').textContent = w.ahead ? L('pmAhead', { n: w.ahead }) : '';
      if (Date.now() - t0 > 600000) return finish(true, L('pmDoneH'), esc(L('pmWaiting', { s: w.station })));
      Promise.all(open.map(function (x) {
        return fetch('/job/' + x.jid).then(function (r) { return r.json(); }).then(function (j) {
          x.state = j.state; x.ahead = j.ahead || 0; x.err = j.err || ''; if (j.station) x.station = j.station; x.moved = j.moved; x.why = j.why || '';
        }).catch(function () {});
      })).then(function () { setTimeout(tick, 1100); });
    })();
  }
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closePm(); });


  /* ---------------- scan ---------------- */
  var SC = { list: [], dev: '', dpi: 300, mode: 'color', src: 'flatbed', fmt: 'pdf' };
  try { var sv = JSON.parse(localStorage.getItem('sp-scan') || '{}'); for (var k in sv) if (k in SC && k !== 'list') SC[k] = sv[k]; } catch (e) {}
  function scSave() { var o = {}; ['dev', 'dpi', 'mode', 'src', 'fmt'].forEach(function (k) { o[k] = SC[k]; }); try { localStorage.setItem('sp-scan', JSON.stringify(o)); } catch (e) {} }
  function scKey(x) { return x.station + '|' + x.id; }
  function scCur() { return SC.list.filter(function (x) { return scKey(x) === SC.dev; })[0]; }
  function scSeg(id, val, allowed) {
    [].forEach.call($(id).querySelectorAll('button'), function (b) { var v = b.getAttribute('data-v'); b.disabled = allowed && allowed.indexOf(v) < 0; b.setAttribute('aria-pressed', String(v === val)); });
  }
  function scRender() {
    var d = scCur(); if (!d && SC.list.length) { d = SC.list[0]; SC.dev = scKey(d); }
    if (document.activeElement !== $('smdev')) $('smdev').innerHTML = SC.list.map(function (x) {
      return '<option value="' + esc(scKey(x)) + '"' + (scKey(x) === SC.dev ? ' selected' : '') + '>' + esc(x.stationName + ' — ' + x.name) + '</option>'; }).join('') || '<option value="">' + esc(L('scanNone')) + '</option>';
    var dpis = d ? d.dpis.map(Number) : [];
    if (d && dpis.indexOf(+SC.dpi) < 0) SC.dpi = dpis.indexOf(300) >= 0 ? 300 : dpis[Math.floor(dpis.length / 2)];
    $('smdpi').innerHTML = dpis.map(function (n) { return '<option value="' + n + '"' + (n === +SC.dpi ? ' selected' : '') + '>' + n + ' dpi' + (n <= 150 ? ' · ' + L('scanFast') : n >= 600 ? ' · ' + L('scanFine') : '') + '</option>'; }).join('');
    if (d && d.modes.indexOf(SC.mode) < 0) SC.mode = d.modes[0];
    var srcs = d ? d.sources : ['flatbed']; if (srcs.indexOf(SC.src) < 0) SC.src = srcs[0];
    $('smsrcrow').hidden = srcs.length < 2;
    if (SC.src === 'feeder') SC.fmt = 'pdf';
    scSeg('smmode', SC.mode, d && d.modes); scSeg('smsrc', SC.src, srcs); scSeg('smfmt', SC.fmt, SC.src === 'feeder' ? ['pdf'] : null);
    $('smhint').textContent = SC.src === 'feeder' ? L('scanFeedHint') : SC.fmt !== 'pdf' ? L('scanImgHint') : '';
    var miss = !d ? L('scanMissDev') : ''; $('smmiss').textContent = miss; $('smgo').disabled = !!miss;
  }
  function scLoad() { return fetch('/scanners').then(function (r) { return r.json(); }).then(function (j) { SC.list = j.list || []; $('scanbtn').hidden = !SC.list.length; if (!$('sm').hidden) scRender(); }).catch(function () {}); }
  $('scanbtn').onclick = function () { $('smform').hidden = false; $('smrun').hidden = true; $('sm').hidden = false; scRender(); scLoad(); };
  $('smdev').onchange = function () { SC.dev = this.value; scSave(); scRender(); };
  $('smdpi').onchange = function () { SC.dpi = +this.value; scSave(); };
  [['smmode', 'mode'], ['smsrc', 'src'], ['smfmt', 'fmt']].forEach(function (g) {
    $(g[0]).addEventListener('click', function (e) { var b = e.target.closest('button'); if (!b || b.disabled) return; SC[g[1]] = b.getAttribute('data-v'); scSave(); scRender(); });
  });
  var scBusy = false;
  function scClose() { if (!scBusy) $('sm').hidden = true; }
  $('smclose').onclick = scClose; $('sm').onclick = function (e) { if (e.target === this) scClose(); }; $('smok').onclick = scClose;
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') scClose(); });
  $('smagain').onclick = function () { $('smform').hidden = false; $('smrun').hidden = true; scRender(); };
  function scStage(c) { $('smstage').className = 'stage scanstage' + (c ? ' ' + c : ''); }
  var SCERR = { NO_SCANNER: 'scanENo', STATION_OFFLINE: 'eStationOff', STATION_LOST: 'scanELost', FEEDER_EMPTY: 'scanEFeed', SCAN_FAILED: 'scanEFail', BUSY: 'scanEFail' };
  $('smgo').onclick = function () {
    var d = scCur(); if (!d) return;
    scBusy = true; $('smform').hidden = true; $('smrun').hidden = false; scStage(''); $('smdl').hidden = $('smagain').hidden = $('smok').hidden = true;
    $('smstate').textContent = L('scanSending'); $('smdetail').textContent = L('scanAt', { s: d.stationName, d: d.name });
    function fin(ok, t, det) { scBusy = false; scStage(ok ? 'done' : 'fail'); $('smstate').textContent = t; $('smdetail').innerHTML = det || ''; $('smagain').hidden = false; $('smok').hidden = !ok ? false : true; }
    fetch('/scan', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Pin': pin() },
      body: JSON.stringify({ station: d.station, device: d.id, dpi: +SC.dpi, mode: SC.mode, source: SC.src, format: SC.fmt }) })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (r) {
        if (!r.ok || !r.j.sid) return fin(false, L('scanFailH'), esc(E(r.j.error) || L('scanEFail')));
        var sid = r.j.sid, t0 = Date.now();
        (function tick() {
          fetch('/scan/' + sid).then(function (x) { return x.json(); }).then(function (j) {
            if (j.state === 'ready') {
              var url = '/scan/' + sid + '/file'; $('smdl').href = url; $('smdl').hidden = false;
              fin(true, L('scanDoneH'), esc(L('scanDoneD', { p: j.pages || 1, k: kb(j.size || 0) })));
              var a = document.createElement('a'); a.href = url; a.download = ''; document.body.appendChild(a); a.click(); a.remove();
              return;
            }
            if (j.state === 'failed' || j.state === 'gone') return fin(false, L('scanFailH'), esc(L(SCERR[j.err] || 'scanEFail')));
            $('smstate').textContent = j.state === 'scanning' ? L('scanNow') : L('scanWait');
            if (Date.now() - t0 > 900000) return fin(false, L('scanFailH'), esc(L('scanEFail')));
            setTimeout(tick, 1000);
          }).catch(function () { setTimeout(tick, 2000); });
        })();
      }).catch(function () { fin(false, L('scanFailH'), esc(L('noReach'))); });
  };
  scLoad(); setInterval(scLoad, 15000);

  /* ---------------- "Add to this device" ---------------- */
  var hostp = location.host, ua = navigator.userAgent;
  $('cmdwin').textContent = 'Add-Printer -IppURL "http://' + hostp + '/ipp/print"';
  $('cmdmac').textContent = 'curl -fsSL http://' + hostp + '/add.sh | bash';
  $('cmdlin').textContent = 'curl -fsSL http://' + hostp + '/add.sh | bash';
  function osPick(o) {
    [].forEach.call(document.querySelectorAll('#ostabs button'), function (b) { b.setAttribute('aria-pressed', String(b.getAttribute('data-os') === o)); });
    [].forEach.call(document.querySelectorAll('.ospane'), function (p) { p.hidden = p.getAttribute('data-os') !== o; });
  }
  var guess = /iPhone|iPad|Android/.test(ua) ? 'phone' : /Windows/.test(ua) ? 'win' : /Macintosh/.test(ua) ? (navigator.maxTouchPoints > 1 ? 'phone' : 'mac') : /Linux|CrOS/.test(ua) ? 'linux' : 'win';
  osPick(guess);
  $('ostabs').onclick = function (e) { var b = e.target.closest('button'); if (b) osPick(b.getAttribute('data-os')); };
  $('addbtn').onclick = function () { $('addpin').hidden = !(st0 && st0.pin); $('addmodal').hidden = false; };
  $('addclose').onclick = function () { $('addmodal').hidden = true; };
  $('addmodal').onclick = function (e) { if (e.target === this) this.hidden = true; };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') $('addmodal').hidden = true; });
  [].forEach.call(document.querySelectorAll('[data-copy]'), function (b) {
    b.onclick = function () {
      var t = $(b.getAttribute('data-copy')).textContent;
      function done() { b.textContent = L('copied'); setTimeout(function () { b.textContent = L('copy'); }, 1500); }
      if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(t).then(done, fallback); else fallback();
      function fallback() { var a = document.createElement('textarea'); a.value = t; document.body.appendChild(a); a.select(); try { document.execCommand('copy'); done(); } catch (e) {} a.remove(); }
    };
  });
  status(); setInterval(status, 5000);
})();
