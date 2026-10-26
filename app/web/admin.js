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
      var fm = m[2].match(/-from([0-9a-f._]+)(?:-via([A-Za-z0-9_]+))?-c/i) || [], f = fm[1] || (m[2] == 'print-loop' ? '-' : L('macMenu'));
      if (fm[2]) f += ' · ' + L('viaSt', { s: fm[2].replace(/_/g, ' ') });
      var sent = /^sent:/.test(m[4]), loop = /^loop:/.test(m[4]), ok = m[4] == '0' || /^0 /.test(m[4]) || sent;
      var tag = sent ? L('sentTo', { s: m[4].slice(5) }) : loop ? L('loopTag') : ok ? L('printed') : L('error');
      return '<tr><td class="ltr">' + esc(m[1].replace('T', ' ')) + '</td><td class="ltr">' + esc(f) + '</td><td>' + esc(m[3] || 1) + '</td><td><span class="tag ' + (ok ? 'ok' : 'err') + '" title="' + esc(loop ? L('loopHelp') : m[4]) + '">' + esc(tag) + '</span></td></tr>';
    }).join('') || '<tr><td colspan="4" class="mute">' + L('none') + '</td></tr>';
    paintNet(s.net);
  }

  /* ---------------- printing network ---------------- */
  var joining = 0, stnEdited = false, changing = false;
  function pct(a, b) { return b ? Math.round(a / b * 100) : 0; }
  function mb(n) { return n >= 1024 ? (n / 1024).toFixed(1) + ' GB' : n + ' MB'; }
  function meter(p, txt) { var c = p >= 85 ? 'err' : p >= 60 ? 'warn' : 'ok'; return '<div class="meter ' + c + '"><i style="width:' + Math.max(3, Math.min(100, p)) + '%"></i></div><span class="mute">' + esc(txt) + '</span>'; }
  var CONV = { office: 'convOffice', lo: 'convLo', signin: 'convSignin', none: 'convNone', peer: 'convNone' };
  var TOKRX = /^[A-HJKMNP-Z2-9]{12}$/;
  function tokVal() { return $('jtok').value.toUpperCase().replace(/[^A-Z0-9]/g, ''); }
  function jCheck() {
    var v = tokVal(), n = v.length, ok = TOKRX.test(v);
    $('jcount').textContent = L('tokCount', { n: n }); $('jcount').className = 'sm counter ' + (ok ? 'ok' : n ? 'warn' : 'mute');
    var miss = !n ? L('tokMissEmpty') : n !== 12 ? L('tokMissLen', { k: Math.abs(12 - n) }) : !ok ? L('tokMissChars') : '';
    $('jmiss').textContent = miss; $('njoin').disabled = !!miss || !!joining; return ok ? v : null;
  }
  function fmtTok(t) { return t.slice(0, 4) + '-' + t.slice(4, 8) + '-' + t.slice(8); }
  function stnCheck() {
    var n = Array.from($('stn').value.trim()).length;
    $('stncount').textContent = L('stCount', { n: n }); $('stncount').className = 'sm counter ' + (n ? 'ok' : 'err');
    $('stnsave').disabled = !n; if (!n) $('stncount').textContent += ' — ' + L('stMissEmpty'); return !!n;
  }
  function paintNet(n) {
    if (!n) return;
    $('netnosha').hidden = n.ok; $('netmode').hidden = !n.ok; $('netok').hidden = !n.ok; $('nocrypto').hidden = n.crypto !== false;
    var al = n.alerts || []; $('alerts').hidden = !al.length;
    $('alerts').innerHTML = al.map(function (a) { return '<div class="alert"><span>' + esc(L('idChanged', { s: a.station })) + '</span><button class="btn" type="button" data-trust="' + esc(a.id) + '">' + esc(L('trustAgain')) + '</button></div>'; }).join('');
    [].forEach.call($('alerts').querySelectorAll('[data-trust]'), function (b) { b.onclick = function () {
      if (confirm(L('confirmTrust'))) api('net', { do: 'trust', id: b.getAttribute('data-trust') }).then(function (r) { res(r, 'tSaved'); }); }; });
    [].forEach.call(document.querySelectorAll('.netopts .opt'), function (b) { b.setAttribute('aria-checked', String(b.getAttribute('data-net') === n.mode)); });
    $('tokbox').hidden = n.mode !== 'private';
    if (n.token) { $('tokv').hidden = false; $('tokv').textContent = fmtTok(n.token); $('tokleft').textContent = L('tokLeft', { m: Math.max(1, Math.ceil(n.tokenLeft / 60)) }); $('ntoken').textContent = L('tokNew'); }
    else { $('tokv').hidden = true; $('tokleft').textContent = ''; $('ntoken').textContent = L('tokShow'); }
    var on = (n.stations || []).filter(function (x) { return x.online; }).length, all = (n.stations || []).length;
    $('netdot').className = 'dot ' + (!n.joined ? '' : on > 1 ? 'ok' : 'warn');
    $('netstate').textContent = !n.joined ? L('netAlone') : on > 1 ? L('netOn', { n: on }) : L('netSearching');
    if (joining && Date.now() - joining > 25000) { joining = 0; $('nprog').hidden = true; jCheck(); }
    if (true) {
      $('netsum').textContent = !n.joined ? L('netSumOff') : on > 1 ? L(n.mode === 'private' ? 'netSumPriv' : 'netSum', { n: on }) : L('netSumAlone');
      var off = all - on, sub = [];
      if (off) sub.push(L('netOff', { n: off }));
      if (n.others) sub.push(L('netOthers', { n: n.others }));
      sub.push(n.lastScan >= 0 ? L('netScanned', { s: n.lastScan }) : L('netScanning'));
      $('netsub').textContent = sub.join(' · ');
      if (!stnEdited && document.activeElement !== $('stn')) { $('stn').value = n.station; stnCheck(); }
      if (!domEdited && document.activeElement !== $('dom')) { $('dom').value = n.domain || ''; domCheck(); }
      $('tgdns').setAttribute('aria-checked', n.dns && !!n.domain); $('tgdns').disabled = !n.domain;
      $('dnsstate').textContent = !n.domain ? L('dnsNoDom') : !n.dns ? L('dnsOff') : n.dnsState === 'on' ? L('dnsOn') : n.dnsState === 'busy' ? L('dnsBusy') : L('dnsStarting');
      var ips = n.stations.filter(function (x) { return x.online; }).map(function (x) { return x.url.replace(/^https?:\/\/|:\d+$/g, ''); }), mainSt = n.stations.filter(function (x) { return x.id === n.main; })[0];
      $('domhelp').textContent = n.domain ? L('domHelp', { d: n.domain, ips: ips.join(', '), m: mainSt ? mainSt.url.replace(/^https?:\/\/|:\d+$/g, '') : '' }) : '';
      $('tgshare').setAttribute('aria-checked', n.share); $('tgaccept').setAttribute('aria-checked', n.accept); $('tgconv').setAttribute('aria-checked', n.conv);
      $('stbody').innerHTML = n.stations.map(function (x) {
        var stc = !x.online ? ['err', x.err == 'PASSWORD' ? L('stPw') : L('stOffline')] : !x.ready ? ['warn', x.pstatus == 'Normal' ? L('closed') : (SM[x.pstatus] ? L(SM[x.pstatus]) : x.pstatus || L('sNotFound'))] : ['ok', L('stReady')];
        var cpu = x.online ? meter(x.cpu, x.cpu + '% · ' + L('cores', { n: x.cores })) : '<span class="mute">—</span>';
        var mem = x.online && x.memTotal ? meter(100 - pct(x.memFree, x.memTotal), L('memFree', { m: mb(x.memFree) })) : '<span class="mute">—</span>';
        var conv = !x.online ? '—' : L(CONV[x.conv] || 'convNone') + (x.convBusy ? ' · ' + L('convBusy', { n: x.convBusy }) : '');
        return '<tr class="' + (x.here ? 'here' : '') + '"><td><b>' + esc(x.station) + '</b>' + (x.here ? ' <span class="tag ok">' + L('thisPc') + '</span>' : '') +
          '<div class="mute sm ltr">' + esc(x.url.replace(/^https?:\/\//, '')) + (x.color ? ' · ' + L('colorC') : '') + (x.duplex ? ' · ' + L('sides') : '') + '</div></td>' +
          '<td class="ltr">' + esc(x.printer || '—') + '</td><td><span class="tag ' + stc[0] + '">' + esc(stc[1]) + '</span></td>' +
          '<td>' + (x.online ? L('qPages', { n: x.queue }) : '—') + '</td><td>' + cpu + '</td><td>' + mem + '</td><td class="sm">' + esc(conv) + '</td></tr>';
      }).join('');
    }
  }
  [].forEach.call(document.querySelectorAll('.netopts .opt'), function (b) {
    b.onclick = function () {
      var to = b.getAttribute('data-net'), cur = st.net && st.net.mode; if (to === cur) return;
      var q = to === 'private' ? 'confirmCreate' : cur === 'private' ? 'confirmLeavePriv' : to === 'alone' ? 'confirmAlone' : '';
      if (q && !confirm(L(q))) return;
      api('net', { do: to }).then(function (r) { res(r, to === 'private' ? 'tCreated' : to === 'alone' ? 'tAlone' : 'tPublic'); });
    };
  });
  $('ntoken').onclick = function () { api('net', { do: 'token' }).then(function (r) { if (r.error) toast(E(r.error), 'err'); load(); }); };
  $('jtok').oninput = jCheck; $('jtok').onkeydown = function (e) { if (e.key === 'Enter') $('njoin').click(); };
  $('njoin').onclick = function () {
    var v = jCheck(); if (!v) return;
    joining = Date.now(); $('njoin').disabled = true; $('nprog').hidden = false; $('nprogt').textContent = L('joinLooking');
    api('net', { do: 'join', token: v }).then(function (r) {
      joining = 0; $('nprog').hidden = true;
      if (r.error) { jCheck(); toast(E(r.error), 'err'); return; }
      $('jtok').value = ''; jCheck(); toast(L('tJoinedPriv'), 'ok'); load();
    }).catch(function () { joining = 0; $('nprog').hidden = true; jCheck(); toast(L('tNoServer'), 'err'); });
  };
  $('nscan').onclick = function () { api('scan', {}).then(function () { toast(L('tScan'), 'ok'); }); };
  $('stn').oninput = function () { stnEdited = true; stnCheck(); };
  $('stnsave').onclick = function () { if (stnCheck()) api('set', { station: $('stn').value.trim() }).then(function (r) { stnEdited = false; res(r, 'tStation'); }); };
  [['tgshare', 'share'], ['tgaccept', 'accept'], ['tgconv', 'conv']].forEach(function (t) {
    $(t[0]).onclick = function () { var o = {}; o[t[1]] = this.getAttribute('aria-checked') != 'true'; api('set', o).then(function (r) { res(r, 'tSaved'); }); };
  });
  var domEdited = false, DOMRX = /^(?=.{3,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$/;
  function domCheck() {
    var v = $('dom').value.trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, ''), ok = !v || DOMRX.test(v);
    $('domhint').textContent = !v ? L('domEmpty') : ok ? (/\.(com|net|org|ir|io)$/.test(v) ? L('domReal') : L('domOk')) : L('domBad');
    $('domhint').className = 'sm counter ' + (!v ? 'mute' : !ok ? 'err' : /\.(com|net|org|ir|io)$/.test(v) ? 'warn' : 'ok');
    $('domsave').disabled = !ok; return ok ? v : null;
  }
  $('dom').oninput = function () { domEdited = true; domCheck(); };
  $('domsave').onclick = function () { var v = domCheck(); if (v !== null) api('set', { domain: v }).then(function (r) { domEdited = false; res(r, 'tSaved'); }); };
  $('tgdns').onclick = function () { api('set', { dns: this.getAttribute('aria-checked') != 'true' }).then(function (r) { res(r, 'tSaved'); }); };
  jCheck();
  window.onLang = function () { if (st.urls) paint(st); jCheck(); };
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
