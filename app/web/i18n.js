/* School Printer - translations (English / Persian) and language switching. Shared by every platform. */
var I = {
en: {
  addDev: 'Add to this device', addTitle: 'Print from any app on this device',
  addLead: 'Add School Printer as a normal printer, then choose it in any app\'s Print dialog - Word, Chrome, Photos, anything.',
  osWin: 'Windows', osMac: 'Mac', osLinux: 'Linux', osPhone: 'Phone / tablet',
  winA: 'Easiest: open printer settings, press "Add device" and pick "School Printer" when it appears.', winOpen: 'Open printer settings',
  winB: 'Or download this file and double-click it:', winDl: 'Download "Add School Printer"',
  winC: 'Or paste this into PowerShell:', macA: 'Open Terminal, paste this, press Enter (your Mac password may be asked):',
  macNote: 'Use this command rather than adding it in System Settings: settings may pick a PostScript driver that this printer cannot use.',
  linA: 'Paste this into a terminal (your password may be asked):',
  phoneA: 'Phones and tablets print from this page: pick a file above and press Print.',
  pinNote: 'This printer has a PIN: when your device asks for a user name and password, type any name and the PIN as the password.',
  copy: 'Copy', copied: 'Copied', close: 'Close',
  title: 'School Printer', adminTitle: 'School Printer Admin', connecting: 'Connecting…', closed: 'Closed', waitingN: '{n} waiting',
  ready: 'Ready', offline: 'Offline', noReach: 'Could not reach the printer computer.', remove: 'Remove', error: 'Error',
  choose: 'Choose files', orDrop: 'or drop them here',
  typesAll: 'PDF, Word, Excel, PowerPoint, text and photos · up to 50 MB',
  typesBasic: 'PDF and photos · up to 50 MB',
  officeSignin: 'Word, Excel and PowerPoint files print only while someone is signed in on the printer computer. PDFs and photos always work.',
  officeNone: 'Word, Excel and PowerPoint files need Microsoft Office or LibreOffice on the printer computer. Save them as PDF instead.',
  uploading: 'Uploading {p}%', converting: 'Converting to PDF…', loadingPrev: 'Preparing preview…', pagesN: '{n} pages', pages1: '1 page',
  convFail: 'Could not convert this file', notAllowed: 'This type of file can\'t be printed',
  copies: 'Copies', pin: 'PIN', print: 'Print', printN: 'Print {n} files',
  sending: 'Sending {f}…', sent: 'Sent {n} file(s) — collect them at the printer.',
  pagesL: 'Pages', all: 'All', custom: 'Custom', pagesPh: 'e.g. 1-3, 5', badRange: 'Check the page numbers (this file has {n} pages)',
  paper: 'Paper size', orient: 'Orientation', auto: 'Auto', portrait: 'Portrait', landscape: 'Landscape',
  colorL: 'Color', colorC: 'Color', colorBW: 'Black & white', monoOnly: 'This printer prints in black & white only',
  sides: 'Two-sided', off: 'Off', longEdge: 'Long edge', shortEdge: 'Short edge',
  margins: 'Margins', mNone: 'None', mNarrow: 'Narrow', mNormal: 'Normal', mWide: 'Wide',
  scale: 'Scale', fit: 'Fit to page', actual: 'Actual size', nup: 'Pages per sheet', more: 'More settings',
  preview: 'Preview', guides: 'Margins', emptyPrev: 'Choose a file to see exactly how it will print.',
  sheetsN: '{n} sheet(s) of paper', sheetOf: 'Sheet {a} of {b}', moreSheets: '+ {n} more sheets', prevFail: 'No preview for this file, but it will still print.',
  eClosed: 'Printing is closed right now.', ePin: 'Wrong PIN.', eBig: 'File is bigger than 50 MB.', eType: 'This type of file can\'t be printed.',
  eNoConv: 'Word, Excel and PowerPoint files print only while someone is signed in on the printer computer.',
  eGone: 'This file expired — please choose it again.', ePinFmt: 'PIN: letters and numbers only, up to 20.',
  eNoPrinter: 'That printer does not exist.', eNoPrinter2: 'Printer not found.', eBadSettings: 'Some print settings were not valid.',
  adminSub: 'Admin · only works on this computer', openPrint: 'Open print page', tellAll: 'Other devices — type this in the address bar',
  orName: 'or {u}', copyAddr: 'Copy address', printing: 'Printing', open: 'Open', openSub: 'Everyone on the network can print',
  closedSub: 'Nobody can print until you open it', now: 'Right now', printer: 'Printer', waiting: 'Waiting', winq: 'Print queue',
  test: 'Print test page', clear: 'Clear stuck jobs', noPin: 'No PIN', save: 'Save',
  pinNote: 'Empty = anyone on this network can print. Letters and numbers only.',
  langCard: 'Language', langNote: 'Default for every device. Each person can still switch with the فا / EN button.',
  officeL: 'Word, Excel & PowerPoint', offOffice: 'Ready — Microsoft Office', offLo: 'Ready — LibreOffice',
  offSignin: 'Waiting for someone to sign in on this computer', offNone: 'Not available — install Microsoft Office or LibreOffice',
  recent: 'Recent prints', time: 'Time', from: 'From', result: 'Result', printed: 'Printed', none: 'Nothing printed yet', macMenu: 'Mac PDF menu',
  tPrinter: 'Printer changed', tPinSaved: 'PIN saved', tPinRemoved: 'PIN removed', tTest: 'Test page sent', tCleared: 'Cleared {n} job(s)',
  tCopied: 'Copied {u}', tNoServer: 'Print server not responding', tLang: 'Default language saved',
  confirmClear: 'Delete all waiting and stuck print jobs?', noNet: 'No network',
  sNormal: 'Normal', sOffline: 'Offline', sNotFound: 'Not found', sError: 'Error'
},
fa: {
  addDev: 'افزودن به این دستگاه', addTitle: 'چاپ از هر برنامه‌ای روی این دستگاه',
  addLead: 'چاپگر مدرسه را مثل یک چاپگر معمولی اضافه کنید، بعد در پنجرهٔ چاپ هر برنامه‌ای انتخابش کنید - Word، Chrome، عکس‌ها و هر چیز دیگر.',
  osWin: 'ویندوز', osMac: 'مک', osLinux: 'لینوکس', osPhone: 'گوشی / تبلت',
  winA: 'ساده‌ترین راه: تنظیمات چاپگر را باز کنید، «Add device» را بزنید و وقتی «School Printer» ظاهر شد انتخابش کنید.', winOpen: 'باز کردن تنظیمات چاپگر',
  winB: 'یا این فایل را دانلود کنید و روی آن دوبار کلیک کنید:', winDl: 'دانلود «Add School Printer»',
  winC: 'یا این را در PowerShell بچسبانید:', macA: 'Terminal را باز کنید، این را بچسبانید و Enter بزنید (ممکن است رمز مک پرسیده شود):',
  macNote: 'از همین دستور استفاده کنید، نه افزودن از System Settings: تنظیمات ممکن است درایور PostScript انتخاب کند که این چاپگر با آن کار نمی‌کند.',
  linA: 'این را در ترمینال بچسبانید (ممکن است رمز عبور پرسیده شود):',
  phoneA: 'گوشی‌ها و تبلت‌ها از همین صفحه چاپ می‌کنند: بالا فایل را انتخاب کنید و چاپ را بزنید.',
  pinNote: 'این چاپگر رمز دارد: وقتی دستگاه نام کاربری و رمز خواست، هر نامی بنویسید و رمز چاپگر را به‌عنوان رمز عبور وارد کنید.',
  copy: 'کپی', copied: 'کپی شد', close: 'بستن',
  title: 'چاپگر مدرسه', adminTitle: 'مدیریت چاپگر مدرسه', connecting: 'در حال اتصال…', closed: 'بسته', waitingN: '{n} در صف',
  ready: 'آماده', offline: 'در دسترس نیست', noReach: 'به رایانهٔ چاپگر دسترسی نیست.', remove: 'حذف', error: 'خطا',
  choose: 'انتخاب فایل', orDrop: 'یا فایل‌ها را اینجا رها کنید',
  typesAll: 'PDF، Word، Excel، PowerPoint، متن و عکس · هر فایل تا ۵۰ مگابایت',
  typesBasic: 'PDF و عکس · هر فایل تا ۵۰ مگابایت',
  officeSignin: 'فایل‌های Word، Excel و PowerPoint فقط وقتی چاپ می‌شوند که کسی وارد رایانهٔ چاپگر شده باشد. PDF و عکس همیشه چاپ می‌شوند.',
  officeNone: 'برای چاپ فایل‌های Word، Excel و PowerPoint باید Microsoft Office یا LibreOffice روی رایانهٔ چاپگر نصب باشد. فعلاً آن‌ها را PDF کنید.',
  uploading: 'در حال ارسال {p}٪', converting: 'در حال تبدیل به PDF…', loadingPrev: 'در حال آماده‌سازی پیش‌نمایش…', pagesN: '{n} صفحه', pages1: '۱ صفحه',
  convFail: 'تبدیل این فایل ممکن نشد', notAllowed: 'این نوع فایل قابل چاپ نیست',
  copies: 'تعداد نسخه', pin: 'رمز', print: 'چاپ', printN: 'چاپ {n} فایل',
  sending: 'در حال ارسال {f}…', sent: '{n} فایل ارسال شد — از کنار چاپگر بردارید.',
  pagesL: 'صفحه‌ها', all: 'همه', custom: 'انتخابی', pagesPh: 'مثلاً 1-3, 5', badRange: 'شمارهٔ صفحه‌ها را بررسی کنید (این فایل {n} صفحه دارد)',
  paper: 'اندازهٔ کاغذ', orient: 'جهت', auto: 'خودکار', portrait: 'عمودی', landscape: 'افقی',
  colorL: 'رنگ', colorC: 'رنگی', colorBW: 'سیاه و سفید', monoOnly: 'این چاپگر فقط سیاه و سفید چاپ می‌کند',
  sides: 'دورو', off: 'خاموش', longEdge: 'لبهٔ بلند', shortEdge: 'لبهٔ کوتاه',
  margins: 'حاشیه', mNone: 'بدون', mNarrow: 'باریک', mNormal: 'معمولی', mWide: 'پهن',
  scale: 'اندازه', fit: 'متناسب با صفحه', actual: 'اندازهٔ واقعی', nup: 'صفحه در هر برگ', more: 'تنظیمات بیشتر',
  preview: 'پیش‌نمایش', guides: 'حاشیه‌ها', emptyPrev: 'یک فایل انتخاب کنید تا دقیقاً ببینید چطور چاپ می‌شود.',
  sheetsN: '{n} برگ کاغذ', sheetOf: 'برگ {a} از {b}', moreSheets: '+ {n} برگ دیگر', prevFail: 'پیش‌نمایش این فایل ممکن نیست، ولی چاپ می‌شود.',
  eClosed: 'چاپ در حال حاضر بسته است.', ePin: 'رمز اشتباه است.', eBig: 'حجم فایل بیشتر از ۵۰ مگابایت است.', eType: 'این نوع فایل قابل چاپ نیست.',
  eNoConv: 'فایل‌های Word، Excel و PowerPoint فقط وقتی چاپ می‌شوند که کسی وارد رایانهٔ چاپگر شده باشد.',
  eGone: 'مهلت این فایل تمام شد — لطفاً دوباره انتخابش کنید.', ePinFmt: 'رمز: فقط حروف و اعداد انگلیسی، حداکثر ۲۰ کاراکتر.',
  eNoPrinter: 'این چاپگر وجود ندارد.', eNoPrinter2: 'چاپگر پیدا نشد.', eBadSettings: 'بعضی از تنظیمات چاپ معتبر نبود.',
  adminSub: 'مدیریت · فقط روی همین رایانه', openPrint: 'صفحهٔ چاپ', tellAll: 'دستگاه‌های دیگر — این نشانی را در نوار آدرس مرورگر بنویسند',
  orName: 'یا {u}', copyAddr: 'کپی نشانی', printing: 'چاپ', open: 'باز', openSub: 'همه در این شبکه می‌توانند چاپ کنند',
  closedSub: 'تا وقتی باز نکنید، کسی نمی‌تواند چاپ کند', now: 'وضعیت فعلی', printer: 'چاپگر', waiting: 'در صف', winq: 'صف چاپ',
  test: 'چاپ صفحهٔ آزمایشی', clear: 'پاک کردن کارهای گیرکرده', noPin: 'بدون رمز', save: 'ذخیره',
  pinNote: 'خالی = همه در این شبکه می‌توانند چاپ کنند. فقط حروف و اعداد انگلیسی.',
  langCard: 'زبان', langNote: 'زبان پیش‌فرض همهٔ دستگاه‌ها. هر کس با دکمهٔ فا / EN می‌تواند عوض کند.',
  officeL: 'Word، Excel و PowerPoint', offOffice: 'آماده — Microsoft Office', offLo: 'آماده — LibreOffice',
  offSignin: 'منتظر ورود کسی به این رایانه', offNone: 'در دسترس نیست — Microsoft Office یا LibreOffice نصب کنید',
  recent: 'چاپ‌های اخیر', time: 'زمان', from: 'فرستنده', result: 'نتیجه', printed: 'چاپ شد', none: 'هنوز چیزی چاپ نشده', macMenu: 'منوی PDF مک',
  tPrinter: 'چاپگر عوض شد', tPinSaved: 'رمز ذخیره شد', tPinRemoved: 'رمز حذف شد', tTest: 'صفحهٔ آزمایشی ارسال شد', tCleared: '{n} کار پاک شد',
  tCopied: '{u} کپی شد', tNoServer: 'سرور چاپ پاسخ نمی‌دهد', tLang: 'زبان پیش‌فرض ذخیره شد',
  confirmClear: 'همهٔ کارهای در صف و گیرکرده پاک شوند؟', noNet: 'بدون شبکه',
  sNormal: 'عادی', sOffline: 'آفلاین', sNotFound: 'پیدا نشد', sError: 'خطا'
}};
var EM = { 'Printing is closed right now.': 'eClosed', 'Wrong PIN.': 'ePin', 'File is bigger than 50 MB.': 'eBig',
  'This type of file can\'t be printed.': 'eType', 'NO_CONVERTER': 'eNoConv', 'GONE': 'eGone',
  'PIN: letters and numbers only, up to 20.': 'ePinFmt', 'That printer does not exist.': 'eNoPrinter', 'Printer not found.': 'eNoPrinter2',
  'Bad settings.': 'eBadSettings', 'Could not reach the printer computer.': 'noReach' };
var SM = { 'Normal': 'sNormal', 'Offline': 'sOffline', 'Not found': 'sNotFound', 'Error': 'sError' };
var lang = 'en', langChosen = false;
function L(k, o) { var s = (I[lang] && I[lang][k]) || I.en[k] || k; if (o) for (var x in o) s = s.split('{' + x + '}').join(o[x]); return s; }
function E(m) { return EM[m] ? L(EM[m]) : m; }
function applyLang(l) {
  lang = I[l] ? l : 'en'; var h = document.documentElement; h.lang = lang; h.dir = lang == 'fa' ? 'rtl' : 'ltr';
  [].forEach.call(document.querySelectorAll('[data-t]'), function (e) { e.textContent = L(e.getAttribute('data-t')); });
  [].forEach.call(document.querySelectorAll('[data-tp]'), function (e) { e.placeholder = L(e.getAttribute('data-tp')); });
  document.title = L(document.body.getAttribute('data-title'));
  var b = document.getElementById('lang'); if (b) b.textContent = lang == 'fa' ? 'EN' : 'فا';
  if (window.onLang) window.onLang();
}
(function () { var s = null; try { s = localStorage.getItem('sp-lang'); } catch (e) {} langChosen = !!s; applyLang(s || 'fa'); })();
function serverLang(l) { if (!langChosen && l && l !== lang) applyLang(l); }
document.getElementById('lang').onclick = function () {
  var n = lang == 'fa' ? 'en' : 'fa'; langChosen = true; try { localStorage.setItem('sp-lang', n); } catch (e) {} applyLang(n);
};
