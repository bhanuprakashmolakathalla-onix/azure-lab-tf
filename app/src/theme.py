"""Two skins, one system.

The storefront and the console are the same platform seen from opposite sides,
and they should not look like the same page. A shop is light, roomy and
typographic because it is trying to sell you something. An operations console is
dark and dense because someone stares at it for an hour looking for the row that
is wrong.

Both commit to a single appearance rather than following the operating system.
A brand picks its ground; an ops tool picks the one that does not glare at 8am.
Neither is a page whose colours should change under the reader.
"""

SHOP_CSS = """<style>
:root {
  color-scheme: light;
  --paper:#fbf9f5; --surface:#ffffff; --sunk:#f3efe7;
  --ink:#1b1916; --ink-soft:#57514a; --muted:#8c8477;
  --rule:#e3ded3; --rule-soft:#eee9e0;
  --accent:#7c2f2b; --accent-ink:#ffffff; --accent-soft:#f4e9e6;
  --sale:#9d2f2b; --good:#2f6b46; --warn:#8c6410;
  --display:"Georgia","Iowan Old Style","Times New Roman",serif;
  --ui:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
  --shadow:0 1px 2px rgba(28,25,22,.05), 0 8px 24px rgba(28,25,22,.06);
}
* { box-sizing:border-box; }
html { scroll-behavior:smooth; }
body { margin:0; background:var(--paper); color:var(--ink);
       font:15px/1.6 var(--ui); -webkit-font-smoothing:antialiased; }
a { color:inherit; text-decoration:none; }
img,svg { max-width:100%; }
.wrap { max-width:1240px; margin:0 auto; padding:0 28px; }

/* --- masthead ---------------------------------------------------------- */
.top { background:var(--ink); color:#efe9df; font-size:.72rem; letter-spacing:.14em;
       text-transform:uppercase; text-align:center; padding:.55rem 1rem; }
header.site { position:sticky; top:0; z-index:40; background:rgba(251,249,245,.94);
              backdrop-filter:blur(10px); border-bottom:1px solid var(--rule); }
.bar { display:flex; align-items:center; gap:2rem; height:72px; }
.wordmark { font-family:var(--ui); font-weight:700; font-size:1.15rem;
            letter-spacing:.34em; text-transform:uppercase; }
nav.main { display:flex; gap:1.6rem; flex:1; font-size:.82rem; letter-spacing:.1em;
           text-transform:uppercase; color:var(--ink-soft); }
nav.main a { padding:.4rem 0; border-bottom:2px solid transparent; }
nav.main a:hover { color:var(--ink); }
nav.main a.on { color:var(--ink); border-bottom-color:var(--accent); }
.tools { display:flex; align-items:center; gap:1.1rem; font-size:.82rem;
         letter-spacing:.08em; text-transform:uppercase; }
.bag-link { display:inline-flex; align-items:center; gap:.45rem; }
.bag-count { display:inline-grid; place-items:center; min-width:20px; height:20px;
             padding:0 6px; border-radius:999px; background:var(--accent);
             color:var(--accent-ink); font-size:.68rem; letter-spacing:0; font-weight:700; }

/* --- hero -------------------------------------------------------------- */
.hero { background:var(--sunk); border-bottom:1px solid var(--rule); }
.hero .wrap { display:grid; grid-template-columns:1.05fr .95fr; gap:3rem;
              align-items:center; padding-top:3.5rem; padding-bottom:3.5rem; }
.hero h1 { font-family:var(--display); font-size:clamp(2.2rem,4.4vw,3.5rem);
           line-height:1.08; margin:.6rem 0 1rem; font-weight:400; letter-spacing:-.01em; }
.hero p { color:var(--ink-soft); max-width:44ch; margin:0 0 1.8rem; font-size:1.02rem; }
.eyebrow { font-size:.72rem; letter-spacing:.22em; text-transform:uppercase; color:var(--accent); }
.hero-art { display:grid; grid-template-columns:repeat(3,1fr); gap:.75rem; }
.hero-art .shot { border-radius:4px; box-shadow:var(--shadow); }
.hero-art > *:nth-child(2) { transform:translateY(-22px); }

/* --- buttons ----------------------------------------------------------- */
.btn { display:inline-flex; align-items:center; justify-content:center; gap:.5rem;
       padding:.85rem 1.9rem; border:1px solid var(--ink); background:var(--ink);
       color:#fff; font:inherit; font-size:.8rem; letter-spacing:.14em;
       text-transform:uppercase; cursor:pointer; border-radius:2px;
       transition:background .15s, color .15s, border-color .15s; }
.btn:hover { background:var(--accent); border-color:var(--accent); }
.btn:disabled { background:var(--rule); border-color:var(--rule); color:var(--muted); cursor:not-allowed; }
.btn.ghost { background:transparent; color:var(--ink); }
.btn.ghost:hover { background:var(--ink); color:#fff; }
.btn.small { padding:.55rem 1.1rem; font-size:.72rem; }
.btn.block { width:100%; }

/* --- sections ---------------------------------------------------------- */
section.band { padding:4rem 0; }
section.band.tight { padding:2.5rem 0; }
.section-head { display:flex; align-items:flex-end; justify-content:space-between;
                gap:1rem; margin-bottom:1.8rem; }
.section-head h2 { font-family:var(--display); font-weight:400; font-size:1.75rem;
                   margin:.3rem 0 0; letter-spacing:-.01em; }
.section-head a { font-size:.76rem; letter-spacing:.14em; text-transform:uppercase;
                  color:var(--ink-soft); border-bottom:1px solid var(--rule); padding-bottom:2px; }
.section-head a:hover { color:var(--accent); border-color:var(--accent); }

/* --- product grid ------------------------------------------------------ */
.grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(238px,1fr)); gap:2rem 1.5rem; }
.card { position:relative; display:block; }
.card .frame { position:relative; aspect-ratio:3/4; overflow:hidden; border-radius:3px;
               background:var(--sunk); }
.card .frame .shot { width:100%; height:100%; display:block;
                     transition:transform .5s cubic-bezier(.2,.6,.2,1); }
.card:hover .frame .shot { transform:scale(1.045); }
.card .meta { padding:.85rem .1rem 0; }
.card .name { font-family:var(--display); font-size:1.02rem; line-height:1.3; }
.card .sub { color:var(--muted); font-size:.79rem; margin-top:.15rem; }
.card .price { margin-top:.45rem; display:flex; align-items:baseline; gap:.55rem; font-size:.92rem; }
.was { color:var(--muted); text-decoration:line-through; font-size:.82rem; }
.off { color:var(--sale); font-size:.78rem; font-weight:600; }
.flags { position:absolute; top:.7rem; left:.7rem; display:flex; flex-direction:column;
         gap:.35rem; align-items:flex-start; }
.flag { background:var(--surface); border:1px solid var(--rule); color:var(--ink);
        font-size:.64rem; letter-spacing:.14em; text-transform:uppercase;
        padding:.3rem .55rem; border-radius:2px; }
.flag.sale { background:var(--sale); border-color:var(--sale); color:#fff; }
.flag.new { background:var(--ink); border-color:var(--ink); color:#fff; }
.flag.gone { background:rgba(255,255,255,.92); color:var(--muted); }
.card .swatches { display:flex; gap:.3rem; margin-top:.5rem; }
.chip { width:16px; height:16px; }

/* --- listing ----------------------------------------------------------- */
.page-head { border-bottom:1px solid var(--rule); padding:2.6rem 0 1.6rem; }
.page-head h1 { font-family:var(--display); font-weight:400; font-size:2.3rem; margin:.4rem 0 .3rem; }
.page-head p { color:var(--ink-soft); margin:0; }
.crumbs { font-size:.74rem; letter-spacing:.12em; text-transform:uppercase; color:var(--muted); }
.crumbs a:hover { color:var(--accent); }
.filters { display:flex; flex-wrap:wrap; gap:.5rem 1.6rem; align-items:center;
           padding:1.1rem 0; border-bottom:1px solid var(--rule-soft); margin-bottom:2rem; }
.filter-group { display:flex; align-items:center; gap:.45rem; flex-wrap:wrap; }
.filter-group .label { font-size:.7rem; letter-spacing:.16em; text-transform:uppercase;
                       color:var(--muted); margin-right:.2rem; }
.pill { border:1px solid var(--rule); border-radius:999px; padding:.32rem .78rem;
        font-size:.78rem; color:var(--ink-soft); background:var(--surface); }
.pill:hover { border-color:var(--ink); color:var(--ink); }
.pill.on { background:var(--ink); border-color:var(--ink); color:#fff; }
.pill.swatch-pill { display:inline-flex; align-items:center; gap:.4rem; padding-left:.4rem; }
.count { margin-left:auto; font-size:.8rem; color:var(--muted); }

/* --- product detail ---------------------------------------------------- */
.pdp { display:grid; grid-template-columns:1.08fr .92fr; gap:3.5rem; padding:2.5rem 0 4rem; }
.gallery .main { aspect-ratio:3/4; background:var(--sunk); border-radius:3px; overflow:hidden; }
.gallery .main .shot { width:100%; height:100%; }
.thumbs { display:flex; gap:.6rem; margin-top:.7rem; }
.thumbs a { width:72px; aspect-ratio:3/4; border:1px solid var(--rule); border-radius:2px;
            overflow:hidden; display:block; }
.thumbs a.on { border-color:var(--ink); }
.pdp .info { padding-top:.5rem; }
.pdp h1 { font-family:var(--display); font-weight:400; font-size:2rem; line-height:1.2;
          margin:.5rem 0 .3rem; }
.pdp .colourline { color:var(--ink-soft); font-size:.9rem; }
.priceline { display:flex; align-items:baseline; gap:.7rem; margin:1.3rem 0 .3rem; }
.priceline .now { font-size:1.5rem; }
.tax { color:var(--muted); font-size:.78rem; }
/* Sizes are radio inputs wearing a button. The input is reachable by keyboard
   and readable by a screen reader; the label is what you see. Nothing here
   needs JavaScript to select a size. */
.sizes { display:flex; flex-wrap:wrap; gap:.5rem; margin:.7rem 0 .3rem; }
.size-opt { position:absolute; width:1px; height:1px; opacity:0; pointer-events:none; }
.size-btn { display:inline-block; min-width:56px; padding:.7rem .4rem; text-align:center;
            border:1px solid var(--rule); background:var(--surface); font:inherit;
            font-size:.85rem; cursor:pointer; border-radius:2px; user-select:none; }
.size-btn:hover { border-color:var(--ink); }
.size-opt:focus-visible + .size-btn { outline:2px solid var(--accent); outline-offset:2px; }
.size-opt:checked + .size-btn { background:var(--ink); border-color:var(--ink); color:#fff; }
.size-opt:disabled + .size-btn { color:var(--muted); background:var(--sunk); cursor:not-allowed;
                                 text-decoration:line-through; }
.stocknote { font-size:.8rem; margin:.6rem 0 1.2rem; min-height:1.2em; }
.stocknote.low { color:var(--sale); }
.stocknote.ok { color:var(--good); }
.row-actions { display:flex; gap:.7rem; align-items:stretch; }
.qty { display:inline-flex; align-items:center; border:1px solid var(--rule); border-radius:2px; }
.qty button { width:38px; border:0; background:transparent; font:inherit; font-size:1.1rem;
              cursor:pointer; color:var(--ink-soft); }
.qty input { width:38px; border:0; text-align:center; font:inherit; background:transparent;
             -moz-appearance:textfield; }
.qty input::-webkit-outer-spin-button, .qty input::-webkit-inner-spin-button
             { -webkit-appearance:none; margin:0; }
details.acc { border-top:1px solid var(--rule); }
details.acc summary { padding:1rem 0; cursor:pointer; font-size:.78rem; letter-spacing:.14em;
                      text-transform:uppercase; list-style:none; display:flex;
                      justify-content:space-between; align-items:center; }
details.acc summary::-webkit-details-marker { display:none; }
details.acc summary::after { content:"+"; color:var(--muted); font-size:1rem; }
details.acc[open] summary::after { content:"–"; }
details.acc .body { padding-bottom:1.2rem; color:var(--ink-soft); font-size:.9rem; }
.fitnote { background:var(--accent-soft); border-left:2px solid var(--accent);
           padding:.85rem 1rem; font-size:.86rem; color:var(--ink-soft); margin:1.4rem 0; }
.fitnote b { color:var(--ink); }
.specs { list-style:none; padding:0; margin:0; font-size:.86rem; color:var(--ink-soft); }
.specs li { display:flex; justify-content:space-between; padding:.4rem 0;
            border-bottom:1px solid var(--rule-soft); }
.specs li span:last-child { color:var(--ink); }

/* --- bag & checkout ---------------------------------------------------- */
.two-col { display:grid; grid-template-columns:1.5fr .85fr; gap:3rem; align-items:start;
           padding:2rem 0 4rem; }
.bag-line { display:grid; grid-template-columns:96px 1fr auto; gap:1.2rem;
            padding:1.4rem 0; border-bottom:1px solid var(--rule-soft); align-items:start; }
.bag-line .frame { aspect-ratio:3/4; background:var(--sunk); border-radius:2px; overflow:hidden; }
.bag-line .name { font-family:var(--display); font-size:1.05rem; }
.bag-line .sub { color:var(--muted); font-size:.82rem; margin-top:.2rem; }
.bag-line .line-actions { display:flex; align-items:center; gap:.9rem; margin-top:.7rem; }
.linkish { background:none; border:0; padding:0; font:inherit; font-size:.78rem;
           color:var(--muted); text-decoration:underline; cursor:pointer; }
.linkish:hover { color:var(--sale); }
.summary { background:var(--surface); border:1px solid var(--rule); border-radius:3px;
           padding:1.6rem; position:sticky; top:96px; }
.summary h2 { font-family:var(--display); font-weight:400; font-size:1.25rem; margin:0 0 1.1rem; }
.sum-row { display:flex; justify-content:space-between; padding:.42rem 0; font-size:.92rem;
           color:var(--ink-soft); }
.sum-row.total { border-top:1px solid var(--rule); margin-top:.7rem; padding-top:.9rem;
                 font-size:1.12rem; color:var(--ink); font-weight:600; }
.sum-row .save { color:var(--good); }
.progress { height:4px; background:var(--sunk); border-radius:999px; overflow:hidden; margin:.5rem 0 1rem; }
.progress i { display:block; height:100%; background:var(--good); }
.field { margin-bottom:1.1rem; }
.field label { display:block; font-size:.72rem; letter-spacing:.14em; text-transform:uppercase;
               color:var(--muted); margin-bottom:.4rem; }
.field input, .field textarea, .field select {
  width:100%; padding:.75rem .85rem; border:1px solid var(--rule); border-radius:2px;
  font:inherit; background:var(--surface); color:var(--ink); }
.field input:focus, .field textarea:focus { outline:2px solid var(--accent); outline-offset:-1px; }
.field-row { display:grid; grid-template-columns:1fr 1fr; gap:1.1rem; }
.notice { border:1px solid var(--rule); border-left:3px solid var(--warn); background:var(--surface);
          padding:.9rem 1.1rem; font-size:.86rem; color:var(--ink-soft); margin-bottom:1.5rem; }
.notice.bad { border-left-color:var(--sale); }
.notice.good { border-left-color:var(--good); }

/* --- order ------------------------------------------------------------- */
.confirm { text-align:center; padding:4rem 0 1rem; }
.confirm .tick { width:56px; height:56px; border-radius:50%; background:var(--good);
                 color:#fff; display:grid; place-items:center; margin:0 auto 1.3rem;
                 font-size:1.6rem; }
.confirm h1 { font-family:var(--display); font-weight:400; font-size:2.1rem; margin:0 0 .5rem; }
.confirm .oid { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:1.05rem;
                letter-spacing:.06em; background:var(--sunk); padding:.35rem .7rem; border-radius:2px; }
.track { display:flex; justify-content:space-between; margin:2.5rem 0; position:relative; }
.track::before { content:""; position:absolute; left:8%; right:8%; top:11px; height:2px;
                 background:var(--rule); }
.track .step { position:relative; text-align:center; flex:1; font-size:.74rem;
               letter-spacing:.1em; text-transform:uppercase; color:var(--muted); }
.track .step i { display:block; width:24px; height:24px; border-radius:50%; margin:0 auto .6rem;
                 background:var(--paper); border:2px solid var(--rule); position:relative; z-index:1; }
.track .step.done { color:var(--ink); }
.track .step.done i { background:var(--ink); border-color:var(--ink); }
.track .step.cancelled i { background:var(--sale); border-color:var(--sale); }
table.lines { width:100%; border-collapse:collapse; font-size:.9rem; }
table.lines th { text-align:left; font-size:.7rem; letter-spacing:.14em; text-transform:uppercase;
                 color:var(--muted); font-weight:600; padding:.6rem .5rem;
                 border-bottom:1px solid var(--rule); }
table.lines td { padding:.75rem .5rem; border-bottom:1px solid var(--rule-soft); }
table.lines td.num, table.lines th.num { text-align:right; font-variant-numeric:tabular-nums; }

/* --- footer ------------------------------------------------------------ */
footer.site { background:var(--ink); color:#cdc5b8; margin-top:4rem; padding:3.5rem 0 2rem; }
footer.site .cols { display:grid; grid-template-columns:1.5fr repeat(3,1fr); gap:2.5rem; }
footer.site h3 { font-size:.72rem; letter-spacing:.18em; text-transform:uppercase;
                 color:#fff; margin:0 0 1rem; font-weight:600; }
footer.site ul { list-style:none; padding:0; margin:0; font-size:.86rem; line-height:2; }
footer.site a:hover { color:#fff; }
footer.site .wordmark { color:#fff; }
footer.site .fine { border-top:1px solid rgba(255,255,255,.12); margin-top:2.5rem;
                    padding-top:1.5rem; font-size:.76rem; color:#8f8779;
                    display:flex; justify-content:space-between; gap:1rem; flex-wrap:wrap; }
code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.85em;
       background:rgba(255,255,255,.08); padding:.1em .4em; border-radius:2px; }

.empty-state { text-align:center; padding:5rem 0; color:var(--muted); }
.empty-state h2 { font-family:var(--display); font-weight:400; color:var(--ink);
                  font-size:1.6rem; margin:0 0 .6rem; }

/* --- toast ------------------------------------------------------------- */
#toast { position:fixed; right:24px; bottom:24px; z-index:60; background:var(--ink);
         color:#fff; padding:.9rem 1.2rem; border-radius:3px; font-size:.88rem;
         box-shadow:var(--shadow); opacity:0; transform:translateY(8px);
         transition:opacity .2s, transform .2s; pointer-events:none; }
#toast.show { opacity:1; transform:none; }

@media (max-width:900px) {
  .hero .wrap { grid-template-columns:1fr; }
  .hero-art > *:nth-child(2) { transform:none; }
  .pdp, .two-col { grid-template-columns:1fr; gap:2rem; }
  nav.main { display:none; }
  footer.site .cols { grid-template-columns:1fr 1fr; }
  .summary { position:static; }
}
@media (max-width:520px) {
  .wrap { padding:0 18px; }
  .grid { grid-template-columns:repeat(auto-fill,minmax(160px,1fr)); gap:1.5rem 1rem; }
  .field-row { grid-template-columns:1fr; }
}
</style>"""


SHOP_JS = """<script>
(function () {
  // ENHANCEMENT ONLY. Selecting a size already works - it is a radio input
  // inside the form. All this does is say how many are left, which is a nicer
  // thing to know before you commit than after.
  var note = document.getElementById('stocknote');
  if (note) {
    document.querySelectorAll('.size-opt').forEach(function (input) {
      input.addEventListener('change', function () {
        var label = document.querySelector('label[for="' + input.id + '"]');
        if (!label) return;
        var left = parseInt(label.dataset.left || '0', 10);
        note.className = 'stocknote ' + (left <= 4 ? 'low' : 'ok');
        note.textContent = left <= 4
          ? 'Only ' + left + ' left in size ' + label.dataset.size
          : left + ' available in size ' + label.dataset.size;
      });
    });
  }

  document.querySelectorAll('.qty').forEach(function (q) {
    var input = q.querySelector('input');
    q.querySelectorAll('button[data-step]').forEach(function (b) {
      b.addEventListener('click', function (e) {
        e.preventDefault();
        var next = (parseInt(input.value, 10) || 1) + parseInt(b.dataset.step, 10);
        input.value = Math.max(1, Math.min(10, next));
        if (q.dataset.autosubmit) q.closest('form').submit();
      });
    });
  });

  var toast = document.getElementById('toast');
  if (toast && toast.dataset.message) {
    toast.textContent = toast.dataset.message;
    toast.classList.add('show');
    setTimeout(function () { toast.classList.remove('show'); }, 3200);
  }
})();
</script>"""


CONSOLE_CSS = """<style>
:root {
  color-scheme: dark;
  --page:#0e0e0d; --surface-1:#191918; --surface-2:#222220; --surface-3:#2b2b28;
  --text-primary:#ffffff; --text-secondary:#c3c2b7; --muted:#8b8981;
  --grid:#2c2c2a; --hairline:rgba(255,255,255,.10);
  --series-1:#3987e5; --series-2:#d95926;
  --good:#25a15c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b; --dead:#8f6fd0;
  --ui:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
}
* { box-sizing:border-box; }
body { margin:0; background:var(--page); color:var(--text-primary);
       font:14px/1.55 var(--ui); -webkit-font-smoothing:antialiased; }
a { color:inherit; text-decoration:none; }
.shell { display:grid; grid-template-columns:220px 1fr; min-height:100vh; }

aside { background:var(--surface-1); border-right:1px solid var(--hairline);
        padding:1.6rem 0; position:sticky; top:0; height:100vh; overflow-y:auto; }
aside .brand { padding:0 1.4rem 1.6rem; border-bottom:1px solid var(--hairline); }
aside .brand b { display:block; font-size:1rem; letter-spacing:.28em; }
aside .brand span { display:block; font-size:.64rem; letter-spacing:.24em; color:var(--muted);
                    text-transform:uppercase; margin-top:.35rem; }
aside nav { padding:1rem .7rem; display:flex; flex-direction:column; gap:.15rem; }
aside nav a { padding:.6rem .75rem; border-radius:5px; color:var(--text-secondary); font-size:.88rem; }
aside nav a:hover { background:var(--surface-2); color:var(--text-primary); }
aside nav a.on { background:var(--surface-3); color:var(--text-primary); font-weight:600; }
aside .foot { margin-top:auto; padding:1.2rem 1.4rem 0; font-size:.7rem; color:var(--muted); line-height:1.7; }

main { padding:2rem 2.2rem 4rem; max-width:1400px; }
.head { display:flex; align-items:flex-end; justify-content:space-between; gap:1rem;
        padding-bottom:1.2rem; border-bottom:1px solid var(--hairline); margin-bottom:1.8rem;
        flex-wrap:wrap; }
.head h1 { font-size:1.35rem; font-weight:600; margin:0; letter-spacing:-.01em; }
.head p { margin:.3rem 0 0; color:var(--muted); font-size:.84rem; }
.ranges { display:flex; gap:.25rem; }
.ranges a { color:var(--text-secondary); padding:.3rem .75rem; border-radius:999px;
            font-size:.8rem; border:1px solid transparent; }
.ranges a:hover { background:var(--surface-2); }
.ranges a.on { background:var(--surface-2); border-color:var(--hairline); color:var(--text-primary); }

.tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:1px;
         background:var(--hairline); border:1px solid var(--hairline); border-radius:8px;
         overflow:hidden; margin-bottom:1.4rem; }
.tile { background:var(--surface-1); padding:1.1rem 1.2rem .95rem; }
.tile-label { font-size:.68rem; letter-spacing:.13em; text-transform:uppercase; color:var(--muted); }
.tile-value { font-size:1.85rem; font-weight:600; margin:.3rem 0 .1rem; letter-spacing:-.02em; }
.tile-sub { font-size:.76rem; color:var(--text-secondary); }
.spark { display:block; margin-top:.5rem; opacity:.85; }

.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(430px,1fr)); gap:1rem; }
.card { background:var(--surface-1); border:1px solid var(--hairline); border-radius:8px;
        padding:1.2rem 1.3rem 1rem; }
.card.wide { grid-column:1/-1; }
.card header { margin-bottom:1rem; }
.card h2 { font-size:.92rem; font-weight:600; margin:0; }
.card header p { margin:.25rem 0 0; font-size:.78rem; color:var(--muted); }

.chart { width:100%; height:auto; display:block; overflow:visible; }
line.grid { stroke:var(--grid); stroke-width:1; }
text.tick { fill:var(--muted); font-size:10px; font-variant-numeric:tabular-nums; }
text.endlabel { fill:var(--text-primary); font-size:11px; font-weight:600; }
text.barlabel { fill:var(--text-secondary); font-size:11px; }
text.barvalue { fill:var(--text-primary); font-size:11px; font-variant-numeric:tabular-nums; }
.hit { fill:transparent; cursor:crosshair; }
.barrow:hover .bar, .bar:hover { filter:brightness(1.15); }
.legend { display:flex; gap:1.1rem; margin-bottom:.5rem; font-size:.78rem; color:var(--text-secondary); }
.legend i { display:inline-block; width:9px; height:9px; border-radius:2px; margin-right:.4rem; }

details { margin-top:.8rem; border-top:1px solid var(--hairline); padding-top:.6rem; }
summary { cursor:pointer; font-size:.76rem; color:var(--muted); list-style:none; }
summary::-webkit-details-marker { display:none; }
summary::before { content:"\\25B8  "; }
details[open] summary::before { content:"\\25BE  "; }

.scroll { overflow-x:auto; }
table.data { border-collapse:collapse; width:100%; font-size:.84rem; }
table.data th { text-align:left; font-weight:600; color:var(--muted); font-size:.7rem;
                text-transform:uppercase; letter-spacing:.08em; padding:.5rem .65rem;
                border-bottom:1px solid var(--hairline); white-space:nowrap; }
table.data td { padding:.55rem .65rem; border-bottom:1px solid var(--grid); color:var(--text-secondary); }
table.data tr:hover td { background:var(--surface-2); }
table.data td.num, table.data th.num { text-align:right; font-variant-numeric:tabular-nums; }
table.data td.name { color:var(--text-primary); }
table.data td.dim { color:var(--muted); }
table.data a { color:var(--series-1); }
table.data a:hover { text-decoration:underline; }

.tag { display:inline-flex; align-items:center; gap:.35rem; padding:.18rem .55rem;
       border-radius:999px; font-size:.72rem; border:1px solid var(--hairline);
       background:var(--surface-2); white-space:nowrap; }
.tag i { width:7px; height:7px; border-radius:50%; }
.filters { display:flex; gap:.4rem; flex-wrap:wrap; margin-bottom:1.2rem; }
.filters a { padding:.35rem .8rem; border-radius:999px; border:1px solid var(--hairline);
             font-size:.79rem; color:var(--text-secondary); background:var(--surface-1); }
.filters a:hover { background:var(--surface-2); color:var(--text-primary); }
.filters a.on { background:var(--surface-3); color:var(--text-primary); border-color:var(--muted); }

form.inline { display:inline-flex; gap:.5rem; align-items:center; flex-wrap:wrap; }
.act { display:inline-block; background:var(--surface-3); border:1px solid var(--hairline);
       color:var(--text-primary); padding:.5rem 1rem; border-radius:5px; font:inherit;
       font-size:.82rem; cursor:pointer; text-decoration:none; }
.act:hover { background:var(--surface-2); border-color:var(--muted); }
.act.primary { background:var(--series-1); border-color:var(--series-1); color:#fff; }
.act.primary:hover { filter:brightness(1.1); }
.act.danger { color:#ffb4b4; }
.act.danger:hover { border-color:var(--critical); }
input.text, select.text { background:var(--surface-2); border:1px solid var(--hairline);
             color:var(--text-primary); padding:.5rem .7rem; border-radius:5px; font:inherit;
             font-size:.84rem; }

.kv { display:grid; grid-template-columns:auto 1fr; gap:.45rem 1.2rem; font-size:.86rem; }
.kv dt { color:var(--muted); }
.kv dd { margin:0; color:var(--text-primary); }
.empty { color:var(--muted); font-size:.85rem; padding:2rem 0; text-align:center; }
code { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.85em;
       background:var(--surface-2); padding:.1em .4em; border-radius:3px; color:var(--text-secondary); }
#tip { position:fixed; pointer-events:none; opacity:0; transition:opacity .1s;
       background:var(--surface-3); border:1px solid var(--hairline); border-radius:6px;
       padding:.4rem .6rem; font-size:.78rem; z-index:50; white-space:nowrap;
       box-shadow:0 6px 20px rgba(0,0,0,.5); }
#tip b { display:block; color:var(--text-primary); font-variant-numeric:tabular-nums; }
#tip span { color:var(--muted); }

@media (max-width:900px) {
  .shell { grid-template-columns:1fr; }
  aside { position:static; height:auto; }
  aside nav { flex-direction:row; flex-wrap:wrap; }
  .cards { grid-template-columns:1fr; }
  main { padding:1.5rem 1.2rem 3rem; }
}
</style>"""


CONSOLE_JS = """<script>
(function () {
  var tip = document.getElementById('tip');
  if (!tip) return;
  document.addEventListener('mouseover', function (e) {
    var t = e.target.closest('[data-label]');
    if (!t) return;
    tip.innerHTML = '<span>' + t.dataset.label + '</span><b>' + t.dataset.value + '</b>';
    tip.style.opacity = 1;
  });
  document.addEventListener('mousemove', function (e) {
    if (tip.style.opacity !== '1') return;
    var x = e.clientX + 14, y = e.clientY + 14;
    if (x + tip.offsetWidth > innerWidth - 8) x = e.clientX - tip.offsetWidth - 14;
    tip.style.left = x + 'px'; tip.style.top = y + 'px';
  });
  document.addEventListener('mouseout', function (e) {
    if (e.target.closest('[data-label]')) tip.style.opacity = 0;
  });
})();
</script>"""
