/* School Printer - admin page (only answers on the printer computer itself). */
(function () {
  var $ = function (i) { return document.getElementById(i); }, st = {}, pinEdited = false, tt;
  function toast(t, c) { var e = $('toast'); e.textContent = t; e.className = 'glass show ' + (c || ''); clearTimeout(tt); tt = setTimeout(function () { e.className = 'glass ' + (c || ''); }, 2600); }
  function api(p, b) { return fetch('/admin/' + p, { method: b ? 'POST' : 'GET', headers: { 'X-Admin': '1' }, body: b ? JSON.stringify(b) : undefined }).then(function (r) { return r.json(); }); }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  var OFF = { office: ['offOffice', 'ok'], lo: ['offLo', 'ok'], signin: ['offSignin', 'warn'], none: ['offNone', 'err'] };
  function paint(s) {
    $('urls').innerHTML = (s.urls.length ? s.urls : [L('noNet')]).map(esc).join('<br>'); $('name').textContent = L('orName', { u: s.name });
    $('sw').setAttribute('aria-checked', s.open); $('ot').textContent = s.open ? L('open') : L('closed'); $('ot').className = s.open ? 'ok' : 'err';
    $('os').textContent = s.open ? L('openSub') : L('closedSub'); if (document.activeElement !== $('lsel')) $('lsel').value = s.lang;
    $('ps').textContent = SM[s.pstatus] ? L(SM[s.pstatus]) : s.pstatus; $('ps').className = s.pstatus == 'Normal' ? 'ok' : 'err';
    $('wt').textContent = s.waiting; $('jb').textContent = s.jobs;
    var o = OFF[s.office] || OFF.none; $('otxt').textContent = L(o[0]); $('odot').className = 'dot ' + o[1];
    if (document.activeElement !== $('psel')) $('psel').innerHTML = s.printers.map(function (p) { return '<option' + (p == s.printer ? ' selected' : '') + '>' + esc(p) + '</option>'; }).join('');
    if (!pinEdited) $('pin').value = s.pin;
    $('log').innerHTML = s.log.map(function (l) {
      var m = l.match(/^(\S+)\s+(\S+)\s+(?:copies=(\d+)\s+)?exit=(.*)$/); if (!m) return '';
      var f = (m[2].match(/-from([0-9a-f._]+)-c/i) || [])[1] || L('macMenu'), ok = m[4] == '0';
      return '<tr><td class="ltr">' + esc(m[1].replace('T', ' ')) + '</td><td class="ltr">' + esc(f) + '</td><td>' + esc(m[3] || 1) + '</td><td><span class="tag ' + (ok ? 'ok' : 'err') + '" title="' + esc(m[4]) + '">' + (ok ? L('printed') : L('error')) + '</span></td></tr>';
    }).join('') || '<tr><td colspan="4" class="mute">' + L('none') + '</td></tr>';
  }
  window.onLang = function () { if (st.urls) paint(st); };
  function load() { api('info').then(function (s) { st = s; serverLang(s.lang); paint(s); }).catch(function () { toast(L('tNoServer'), 'err'); }); }
  function res(r, okKey) { toast(r.error ? E(r.error) : L(okKey), r.error ? 'err' : 'ok'); load(); }
  $('sw').onclick = function () { api('set', { open: !st.open }).then(load); };
  $('psel').onchange = function () { api('set', { printer: this.value }).then(function (r) { res(r, 'tPrinter'); }); };
  $('lsel').onchange = function () { api('set', { lang: this.value }).then(function (r) { res(r, 'tLang'); }); };
  $('pin').oninput = function () { pinEdited = true; };
  $('savepin').onclick = function () { api('set', { pin: $('pin').value }).then(function (r) { pinEdited = false; res(r, $('pin').value ? 'tPinSaved' : 'tPinRemoved'); }); };
  $('test').onclick = function () { api('testpage', {}).then(function (r) { res(r, 'tTest'); }); };
  $('clear').onclick = function () { if (confirm(L('confirmClear'))) api('clear', {}).then(function (r) { toast(L('tCleared', { n: r.removed }), 'ok'); load(); }); };
  $('copy').onclick = function () { var u = (st.urls || [])[0] || ''; if (navigator.clipboard) navigator.clipboard.writeText(u).then(function () { toast(L('tCopied', { u: u }), 'ok'); }); };
  load(); setInterval(load, 4000);
})();
