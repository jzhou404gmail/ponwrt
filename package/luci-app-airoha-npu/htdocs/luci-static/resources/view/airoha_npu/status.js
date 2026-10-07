'use strict';
'require view';
'require poll';
'require rpc';
'require ui';

var callNpuStatus = rpc.declare({ object: 'luci.airoha_npu', method: 'getStatus' });
var callPpeEntries = rpc.declare({ object: 'luci.airoha_npu', method: 'getPpeEntries' });
var callWifiInfo = rpc.declare({ object: 'luci.airoha_npu', method: 'getWifiInfo' });
var callFrameEngine = rpc.declare({ object: 'luci.airoha_npu', method: 'getFrameEngine' });
var callSetGovernor = rpc.declare({ object: 'luci.airoha_npu', method: 'setGovernor', params: ['governor'] });
var callSetMaxFreq = rpc.declare({ object: 'luci.airoha_npu', method: 'setMaxFreq', params: ['freq'] });
var callSetOverclock = rpc.declare({ object: 'luci.airoha_npu', method: 'setOverclock', params: ['freq_mhz'] });

/* ── Theme-adaptive CSS ── */
var themeCSS = '\
.soc-card{background:var(--soc-card-bg);border:1px solid var(--soc-border);border-radius:8px;padding:14px;transition:border-color .3s}\
.soc-card-accent{border-left-width:3px;border-left-style:solid}\
.soc-muted{color:var(--soc-muted)}\
.soc-text{color:var(--soc-text)}\
.soc-label{font-size:11px;color:var(--soc-muted)}\
.soc-bar-track{background:var(--soc-bar-track);border-radius:4px;overflow:hidden}\
.soc-pse-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:6px}\
.soc-pse-cell{background:var(--soc-card-bg);border:1px solid var(--soc-border);border-radius:5px;padding:6px 8px;font-size:12px}\
.soc-warn{background:rgba(255,193,7,.14);border:1px solid #f9a825;border-radius:6px;padding:8px 10px;font-size:12px;color:var(--soc-text)}\
.soc-gdm-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:10px}\
.soc-cdm-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-bottom:10px}\
';

function isDarkMode() {
	// Sample multiple elements to get a reliable reading
	var els = [document.body, document.querySelector('.main-content'), document.querySelector('#maincontent'), document.querySelector('.cbi-map')];
	for (var i = 0; i < els.length; i++) {
		if (!els[i]) continue;
		var bg = window.getComputedStyle(els[i]).backgroundColor;
		var m = bg.match(/\d+/g);
		if (m && m.length >= 3) {
			var a = m.length >= 4 ? parseFloat(m[3]) : 1;
			if (a < 0.1) continue; // transparent, skip
			var lum = (parseInt(m[0]) * 299 + parseInt(m[1]) * 587 + parseInt(m[2]) * 114) / 1000;
			return lum < 128;
		}
	}
	// Fallback: check if any known dark theme stylesheet is loaded
	var sheets = document.querySelectorAll('link[href*="dark"], link[href*="glass"]');
	return sheets.length > 0;
}

var _lastDarkMode = null;

function injectCSS() {
	var el = document.getElementById('soc-theme-css');
	if (!el) { el = document.createElement('style'); el.id = 'soc-theme-css'; document.head.appendChild(el); }

	var dark = isDarkMode();
	if (dark === _lastDarkMode) return;
	_lastDarkMode = dark;

	var vars = dark
		? ':root{--soc-card-bg:#1e1e1e;--soc-border:#333;--soc-muted:#999;--soc-text:#e0e0e0;--soc-bar-track:#333}'
		: ':root{--soc-card-bg:#fff;--soc-border:#d0d0d0;--soc-muted:#666;--soc-text:#222;--soc-bar-track:#e0e0e0}';
	el.textContent = themeCSS + vars;
}

/* ── Helpers ── */
/* PSE port map. P2 (GDM2) carries the XPON GEM data plane on PonWrt and is
 * the WAN; P9 (GDM4) is the board's copper PHY (2.5G EN8811 on the Nokia /
 * ZNXT boards, 10G RTL8261N on the Gemtek XG2010G), a LAN port here. */
var psePortMap = [
	{ name: 'CDM1', label: 'CPU DMA 1 (LAN)', color: '#607d8b' },
	{ name: 'GDM1', label: 'LAN Switch', color: '#ff9800' },
	{ name: 'GDM2', label: 'PON (WAN)', color: '#00bcd4' },
	{ name: 'GDM3', label: 'GDM3', color: '#607d8b' },
	{ name: 'PPE1', label: 'PPE Eng 1', color: '#2196f3' },
	{ name: 'CDM2', label: 'CPU DMA 2', color: '#607d8b' },
	{ name: 'CDM3', label: 'CDM3', color: '#607d8b' },
	{ name: 'CDM4', label: 'CDM4 (WDMA)', color: '#9e9e9e' },
	{ name: 'PPE2', label: 'PPE Eng 2', color: '#2196f3' },
	{ name: 'GDM4', label: 'Copper PHY', color: '#4caf50' },
	{ name: 'CDM5', label: 'CDM5', color: '#607d8b' }
];

function fmtFreq(khz) { return (!khz || khz === 0) ? 'N/A' : (khz / 1000).toFixed(0) + ' MHz'; }
function fmtK(n) {
	if (!n || n === 0) return '0';
	if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
	if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K';
	return n.toString();
}

function calcTotalMem(regions) {
	var t = 0;
	(regions || []).forEach(function(r) {
		var m = (r.size || '').match(/(\d+)\s*(KiB|MiB|GiB)/i);
		if (m) { var s = parseInt(m[1]); var u = m[2][0].toUpperCase(); t += u === 'G' ? s*1048576 : u === 'M' ? s*1024 : s; }
	});
	return t >= 1024 ? (t/1024).toFixed(0)+' MiB' : t+' KiB';
}

function fmtMemKb(kb) {
	if (!kb) return 'N/A';
	if (kb >= 1048576) return (kb/1048576).toFixed(2)+' GiB';
	return (kb/1024).toFixed(0)+' MiB';
}

/* ── WiFi ──
 * Written for the MT7916D of the FiberHome HG5585F, which exposes two phys
 * (phy0-ap0 / phy1-ap0), but the band of every interface is resolved by the
 * RPC backend from its runtime centre frequency, so any layout works.
 *
 * Only the MT7996/MT7992 boards offload WiFi traffic to the NPU; the MT7916
 * has no such path, and the header says so instead of showing a badge that
 * would mean nothing here.
 *
 * Every row is drawn only when the backend could really read that value, so
 * an idle band shows its channel and nothing else instead of a wall of
 * zeros. Values shared by all bands (the chip temperature) are shown once in
 * the section header rather than repeated on every card.
 */
var bandNames = ['2.4 GHz', '5 GHz', '6 GHz'];

function bandLabel(b) { return bandNames[b] || _('Band %d').format(b); }

function fmtBytes(n) {
	if (!n) return '0';
	if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GiB';
	if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MiB';
	if (n >= 1024) return (n / 1024).toFixed(0) + ' KiB';
	return n + ' B';
}

/* Bigger is worse (channel load, retry rate, temperature). */
function highColor(v, warn, bad) {
	return v >= bad ? '#f44336' : v >= warn ? '#ff9800' : '#4caf50';
}

/* Signal strength: higher is better. */
function signalColor(dbm) {
	return dbm >= -60 ? '#4caf50' : dbm >= -70 ? '#ff9800' : '#f44336';
}

var bandColors = ['#ff9800', '#2196f3', '#9c27b0'];

/* One card per band, deliberately in the same visual language as the GDM
 * cards: coloured left border, title with a badge for the interface, then a
 * two-column label/value grid. */
function renderBandCard(b) {
	var color = bandColors[b.band] || '#607d8b';
	var rows = [];

	function row(label, value, valueColor) {
		rows.push(E('span', { 'class': 'soc-muted' }, label));
		rows.push(E('span', { 'class': 'soc-text', 'style': 'text-align:right' + (valueColor ? ';color:' + valueColor : '') }, value));
	}

	if (b.ssid) row(_('SSID'), b.ssid);
	if (b.channel) row(_('Channel'), b.channel + ' @ ' + (b.width_mhz || '?') + ' MHz');
	row(_('Clients'), String(b.count || 0));

	if (b.count && b.signal_dbm != null) {
		// The weakest associated client is the one that limits the band.
		row(_('Signal (weakest)'), b.signal_dbm + ' dBm', signalColor(b.signal_dbm));
	}
	if (b.busy_pct != null) {
		// Airtime the channel was busy, measured over the last poll interval.
		row(_('Channel usage'), b.busy_pct + ' %', highColor(b.busy_pct, 30, 60));
	}
	if (b.noise_dbm != null)
		row(_('Noise'), b.noise_dbm + ' dBm');

	// Traffic counters come from the station table, so they only exist once a
	// client is associated - an idle band shows none of this.
	if (b.count) {
		row(_('Traffic'), E('span', { 'title': _('Downlink to the clients / uplink from the clients') },
			'\u2193 ' + fmtBytes(b.tx_bytes) + '  \u2191 ' + fmtBytes(b.rx_bytes)));
		if (b.tx_packets)
			row(_('Retry rate'), (b.tx_retries / b.tx_packets * 100).toFixed(1) + ' %',
				highColor(b.tx_retries / b.tx_packets * 100, 10, 25));
		if (b.tx_failed)
			row(_('TX failed'), String(b.tx_failed));
	}

	return E('div', { 'class': 'soc-card soc-card-accent', 'style': 'border-left-color:' + color + (b.up ? ';border-color:' + color : '') }, [
		E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;margin-bottom:6px' }, [
			E('span', { 'style': 'font-weight:bold;color:' + color + ';font-size:14px' }, bandLabel(b.band)),
			E('span', { 'style': 'background:#666;color:#fff;padding:1px 7px;border-radius:3px;font-size:10px;font-weight:600' }, b.netdev || '')
		]),
		E('div', { 'style': 'display:grid;grid-template-columns:auto 1fr;gap:2px 10px;font-size:12px' }, rows)
	]);
}

function renderWifi(wf) {
	if (!wf || !wf.wifi_present) return null;

	// A radio that is configured out has no channel and nothing to report it
	// with, so it gets no card at all.
	var bands = (Array.isArray(wf.bands) ? wf.bands : []).filter(function(b) {
		return b && (b.channel > 0 || b.count > 0);
	}).sort(function(a, b) { return a.band - b.band; });
	if (!bands.length) return null;

	var sub = [];
	if (wf.chip) sub.push(wf.chip);
	sub.push(wf.npu_offload
		? _('NPU offload active · WiFi → NPU → WDMA → PPE')
		: _('No NPU offload path · WiFi → PCIe → GDM3 (P3) → PPE'));

	// The chip temperature sensor is shared by both phys (one MT7916 die), so
	// it belongs to the section, not to a single band.
	var temp = null;
	if (wf.temp_c != null) {
		temp = E('span', {
			'style': 'background:' + highColor(wf.temp_c, 75, 90) + ';color:#fff;padding:1px 7px;border-radius:3px;font-size:10px;font-weight:600',
			'title': wf.temp_crit_c != null
				? _('WiFi chip temperature (limit %s °C)').format(wf.temp_crit_c)
				: _('WiFi chip temperature')
		}, Number(wf.temp_c).toFixed(0) + ' °C');
	}

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', { 'style': 'display:flex;justify-content:space-between;align-items:center' }, [
			E('span', {}, _('WiFi')),
			temp
		]),
		E('div', { 'class': 'soc-muted', 'style': 'font-size:12px;margin-bottom:8px' }, sub.join(' · ')),
		E('div', { 'class': 'soc-gdm-grid' }, bands.map(renderBandCard))
	]);
}

/* ── Frame Engine Diagram (GDM / PPE / NPU) ── */
function renderFeDiagram(fe, st, wf) {
	if (!fe) return E('div', { 'class': 'soc-muted' }, 'Frame Engine data not available');
	st = st || {};
	wf = wf || {};

	// GDM/NPU/PPE cards come from netdev/sysfs data and work even without
	// /dev/mem; only the PSE register reads need it. When /dev/mem is
	// missing we render a compact banner and grey out the PSE parts instead
	// of failing the whole diagram.
	var devmemOk = (fe.devmem_ok !== 0 && !fe.error);
	var warnBanner = null;
	if (fe.error) {
		warnBanner = E('div', { 'class': 'soc-warn', 'style': 'margin-bottom:10px' }, [
			E('span', { 'style': 'font-weight:bold' }, '⚠ PSE register reads unavailable: '),
			E('span', {}, fe.error)
		]);
	}

	var ports = Array.isArray(fe.pse_ports) ? fe.pse_ports : [];

	// Helper: GDM card. The netdev behind each GDM is resolved by the RPC
	// backend from the running device tree, so the same view works whether
	// the copper PHY is called wan, lan1 or lan5 on this board, and whether
	// it is a 2.5G or a 10G port.
	function gdmCard(key, name, label, color, pse) {
		var d = fe[key] || {};
		var present = !!d.netdev;
		var active = present && (d.tx > 0 || d.rx > 0);
		var head = E('div', { 'style': 'display:flex;justify-content:space-between;align-items:baseline;margin-bottom:2px' }, [
			E('span', { 'style': 'font-weight:bold;color:'+color+';font-size:14px' }, name),
			E('span', { 'class': 'soc-label' }, pse)
		]);
		var subtext = label;
		if (present) subtext += ' · ' + d.netdev + (d.speed ? ' · ' + d.speed : '');
		var sub = E('div', { 'class': 'soc-label', 'style': 'margin-bottom:6px' }, subtext);

		// A GDM without a netdev has nothing to report; showing a greyed-out
		// placeholder would be an empty box, so it is simply not rendered.
		if (!present)
			return null;

		var rows = [
			E('span', { 'class': 'soc-muted' }, 'TX'), E('span', { 'class': 'soc-text', 'style': 'text-align:right' }, fmtK(d.tx)),
			E('span', { 'class': 'soc-muted' }, 'RX'), E('span', { 'class': 'soc-text', 'style': 'text-align:right' }, fmtK(d.rx)),
			E('span', { 'class': 'soc-muted' }, _('Link')),
			E('span', { 'style': 'text-align:right;color:'+(d.link?'#4caf50':'#f44336') }, d.link ? _('up') : _('down'))
		];
		if (d.tx_drop > 0)
			rows.push(E('span', { 'style': 'color:#f44336' }, 'TX Drop'),
			          E('span', { 'style': 'color:#f44336;text-align:right' }, fmtK(d.tx_drop)));
		if (d.rx_drop > 0)
			rows.push(E('span', { 'style': 'color:#f44336' }, 'RX Drop'),
			          E('span', { 'style': 'color:#f44336;text-align:right' }, fmtK(d.rx_drop)));

		return E('div', { 'class': 'soc-card soc-card-accent', 'style': 'border-left-color:'+color + (active?';border-color:'+color:'') }, [
			head, sub,
			E('div', { 'style': 'display:grid;grid-template-columns:auto 1fr;gap:2px 10px;font-size:12px' }, rows)
		]);
	}

	// NPU status, firmware, clock and core count are all reported by the
	// "NPU & Offload Engine" table above, so the diagram deliberately does not
	// repeat them in a card of its own.

	// PPE engines with flow count
	var ppeCard = E('div', { 'class': 'soc-card', 'style': 'border-color:#2196f3' }, [
		E('div', { 'style': 'display:flex;justify-content:space-between;align-items:center;margin-bottom:4px' }, [
			E('span', { 'style': 'font-weight:bold;color:#2196f3;font-size:14px' }, 'PPE Engines'),
			E('span', { 'class': 'soc-label' }, 'P4 + P8')
		]),
		E('div', { 'style': 'display:flex;gap:16px;font-size:12px' }, [
			E('span', {}, [
				E('span', { 'class': 'soc-muted' }, 'Bound '),
				E('span', { 'class': 'soc-text', 'style': 'font-weight:bold', 'id': 'fe-ppe-bound' }, (st.offload_bound||0).toString())
			]),
			E('span', {}, [
				E('span', { 'class': 'soc-muted' }, 'Total '),
				E('span', { 'class': 'soc-text', 'id': 'fe-ppe-total' }, (st.offload_total||0).toString())
			])
		])
	]);

	// PSE shared buffer
	var pseT = fe.pse_total || 0;
	var pseR = fe.pse_reserved || 0;
	var pseF = fe.pse_free || 0;
	// Guard against NaN (e.g. stale cached JS with mismatched RPC fields)
	var pseP = (pseT > 0 && isFinite(pseR/pseT)) ? ((pseR/pseT)*100).toFixed(1) : '0';
	var pseCol = parseFloat(pseP)>80?'#f44336':parseFloat(pseP)>50?'#ff9800':'#4caf50';

	// PSE port cells (full hardware port map, P0..P10; P7=CDM4/WDMA hidden -
	// it is the WiFi DMA path and this board has no such WiFi device)
	var portCells = ports.filter(function(p) { return p.port !== 7; }).map(function(p) {
		var info = psePortMap[p.port] || { name:'P'+p.port, label:'?', color:'#666' };
		// P3 is GDM3, the PCIe MAC: on boards with WiFi that is the wireless
		// data path, so label it accordingly instead of a bare "GDM3".
		if (p.port === 3 && wf.wifi_present)
			info = { name: 'GDM3', label: _('PCIe (WiFi)'), color: '#9c27b0' };
		// Drops are not repeated here: the only ports that have a drop counter
		// are P1/P2/P9 (the three GDM netdevs) and those already report
		// "RX Drop" on their own card above.
		return E('div', { 'class': 'soc-pse-cell' }, [
			E('div', { 'style': 'font-weight:600;color:'+info.color+';font-size:11px' }, 'P'+p.port+' '+info.name),
			E('div', { 'class': 'soc-label', 'style': 'font-size:9px;margin-top:1px' }, info.label),
			E('div', { 'style': 'display:flex;gap:8px;font-size:11px;margin-top:2px' }, [
				E('span', { 'class': 'soc-muted' }, 'IQ '+p.iq),
				E('span', { 'class': 'soc-muted' }, 'OQ '+p.oq)
			])
		]);
	});

	// A GDM that resolved no netdev gets no card (an empty box helps nobody),
	// but when not one of the three resolved, that is a fault worth naming:
	// silently rendering nothing is indistinguishable from a broken view.
	function gdmCards() {
		var cards = [
			gdmCard('gdm1', 'GDM1', _('LAN Switch (lan2-lan4)'), '#ff9800', 'P1'),
			gdmCard('gdm2', 'GDM2', _('PON (WAN uplink)'), '#00bcd4', 'P2'),
			gdmCard('gdm4', 'GDM4', _('Copper PHY (LAN)'), '#4caf50', 'P9')
		].filter(Boolean);

		if (!cards.length)
			cards.push(E('div', { 'class': 'soc-warn' },
				_('No GDM port resolved a netdev (the RPC returned none for gdm1/gdm2/gdm4)')));

		return cards;
	}

	return E('div', { 'id': 'fe-diagram' }, [
		devmemOk ? null : warnBanner,
		// PSE buffer bar
		E('div', { 'class': 'soc-card', 'style': 'margin-bottom:10px' }, [
			E('div', { 'style': 'display:flex;justify-content:space-between;margin-bottom:4px' }, [
				E('span', { 'class': 'soc-text', 'style': 'font-weight:bold;font-size:13px' }, 'PSE Shared Buffer'),
				devmemOk
					? E('span', { 'class': 'soc-muted', 'style': 'font-size:12px' }, pseR+' reserved / '+pseF+' free · '+pseT+' pages ('+pseP+'%)')
					: E('span', { 'class': 'soc-muted', 'style': 'font-size:12px' }, 'unavailable (no /dev/mem)')
			]),
			devmemOk
				? E('div', { 'class': 'soc-bar-track', 'style': 'height:8px' }, [
					E('div', { 'style': 'background:'+pseCol+';height:100%;width:'+pseP+'%;border-radius:4px;transition:width .5s' })
				])
				: null,
			E('div', { 'class': 'soc-label', 'style': 'margin-top:4px' }, devmemOk
				? 'Pages reserved for per-port queues (ALLRSV) vs total PSE pages (FQ_LIMIT)'
				: 'Requires /dev/mem - enable CONFIG_KERNEL_DEVMEM=y and rebuild')
		]),
		// Row 1: GDM ports that actually have a netdev. On PonWrt the PON data
		// path (GDM2) is the WAN and the 2.5G PHY (GDM4) is a LAN port.
		E('div', { 'class': 'soc-gdm-grid' }, gdmCards()),
		// Row 2: PPE flow summary
		E('div', { 'style': 'margin-bottom:10px' }, [ ppeCard ]),
		// PSE port grid
		E('div', { 'class': 'soc-text', 'style': 'font-size:12px;font-weight:600;margin-bottom:6px' }, 'PSE Port Queue Status'),
		devmemOk
			? E('div', { 'class': 'soc-pse-grid' }, portCells)
			: E('div', { 'class': 'soc-muted', 'style': 'font-size:12px' }, 'Register reads unavailable - enable CONFIG_KERNEL_DEVMEM=y and rebuild')
	]);
}

/* ── CPU Frequency ── */
function freqBarState(hw, min, max, pll, gov) {
	var oc = gov==='performance' && pll>0 && (pll*1000)>max;
	return { freq: oc ? pll*1000 : Math.min(hw,max), max: oc ? pll*1000 : max, oc: oc };
}

function renderFreqBar(hw, min, max, pll, gov) {
	if (!max) return E('span',{},'N/A');
	var s = freqBarState(hw,min,max,pll,gov);
	var pct = Math.round(((s.freq-min)/(s.max-min))*100);
	pct = Math.max(0,Math.min(100,pct));
	var bg = s.oc ? 'linear-gradient(90deg,#e65100,#ff9800)' : 'linear-gradient(90deg,#2e7d32,#66bb6a)';
	var label = s.oc ? (pll+' MHz (OC)') : fmtFreq(s.freq);

	return E('div', { 'id':'cpu-freq-bar-wrap', 'style':'display:flex;align-items:center;gap:10px' }, [
		E('span', { 'class':'soc-muted', 'style':'font-size:90%' }, fmtFreq(min)),
		E('div', { 'style':'flex:1;border-radius:4px;height:22px;position:relative;min-width:180px;max-width:350px;overflow:hidden', 'class':'soc-bar-track' }, [
			E('div', { 'id':'cpu-freq-fill', 'style':'background:'+bg+';height:100%;border-radius:4px;width:'+pct+'%;transition:width .5s' }),
			E('span', { 'id':'cpu-freq-text', 'style':'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-weight:bold;font-size:13px;color:#fff;text-shadow:0 1px 2px rgba(0,0,0,.6)' }, label)
		]),
		E('span', { 'id':'cpu-freq-max-label', 'class':'soc-muted', 'style':'font-size:90%' }, fmtFreq(s.max))
	]);
}

function updateFreqBar(hw, min, max, pll, gov) {
	var s = freqBarState(hw,min,max,pll,gov);
	var el = document.getElementById('cpu-freq-text'), fl = document.getElementById('cpu-freq-fill'), ml = document.getElementById('cpu-freq-max-label');
	if (el) el.textContent = s.oc ? (pll+' MHz (OC)') : fmtFreq(s.freq);
	if (fl && s.max>0) { var pct=Math.max(0,Math.min(100,Math.round(((s.freq-min)/(s.max-min))*100))); fl.style.width=pct+'%'; fl.style.background=s.oc?'linear-gradient(90deg,#e65100,#ff9800)':'linear-gradient(90deg,#2e7d32,#66bb6a)'; }
	if (ml) ml.textContent = fmtFreq(s.max);
}

function renderGovSelect(avail, active) {
	var gs = (avail||'').trim().split(/\s+/).filter(Boolean);
	if (!gs.length) return E('span',{},'N/A');
	return E('select', { 'id':'cpu-governor-select','class':'cbi-input-select','style':'min-width:140px','change':function(ev){
		var g=ev.target.value; ev.target.disabled=true;
		callSetGovernor(g).then(function(r){ev.target.disabled=false;if(r&&r.error) ui.addNotification(null,E('p',{},_('Error: ')+r.error),'error');}).catch(function(){ev.target.disabled=false;});
	}}, gs.map(function(g){return E('option',{'value':g,'selected':g===active?'':null},g);}));
}

function renderMaxFreqSelect(avail, cur) {
	var fs = (avail||'').trim().split(/\s+/).filter(Boolean);
	if (!fs.length) return E('span',{},'N/A');
	return E('select', { 'id':'cpu-maxfreq-select','class':'cbi-input-select','style':'min-width:140px','change':function(ev){
		var f=ev.target.value; ev.target.disabled=true;
		callSetMaxFreq(parseInt(f)).then(function(r){ev.target.disabled=false;if(r&&r.error) ui.addNotification(null,E('p',{},_('Error: ')+r.error),'error');}).catch(function(){ev.target.disabled=false;});
	}}, fs.map(function(f){return E('option',{'value':f,'selected':parseInt(f)===parseInt(cur)?'':null},(parseInt(f)/1000).toFixed(0)+' MHz');}));
}

function renderOcControls() {
	var inp = E('input',{'id':'oc-freq-input','type':'number','min':'500','max':'1600','step':'50','value':'1400','class':'cbi-input-text','style':'width:100px'});
	var btn = E('button',{'class':'cbi-button cbi-button-action','style':'margin-left:8px','click':function(){
		var f=parseInt(document.getElementById('oc-freq-input').value);
		if(isNaN(f)||f<500||f>1600){ui.addNotification(null,E('p',{},_('Must be 500-1600 MHz')),'error');return;}
		if(f>1400&&!confirm(_('Frequencies above 1400 MHz may be unstable. Continue?'))) return;
		btn.disabled=true;btn.textContent=_('Applying...');
		callSetOverclock(f).then(function(r){btn.disabled=false;btn.textContent=_('Apply');
			if(r&&r.error) ui.addNotification(null,E('p',{},_('Failed: ')+r.error),'error');
			else if(r&&r.result==='ok') ui.addNotification(null,E('p',{},_('CPU set to ')+r.actual_mhz+' MHz'),'info');
		}).catch(function(e){btn.disabled=false;btn.textContent=_('Apply');});
	}},_('Apply'));
	return E('div',{'style':'display:flex;align-items:center;gap:8px;flex-wrap:wrap'},[
		inp, E('span',{'class':'soc-muted'},'MHz'), btn,
		E('span',{'class':'soc-muted','style':'font-size:85%;margin-left:8px'},_('Direct PLL. Stock max 1200 MHz. Stable up to 1500 MHz.'))
	]);
}

/* ── Section refresh helper ──
 * Sections are rebuilt before their old content is dropped, and a failure in
 * one section never stops the others. Clearing first would mean that a single
 * rendering error leaves the user with a permanently empty box - which is
 * exactly how the GDM cards can "disappear" while the rest of the page keeps
 * working. */
function updateSection(id, build) {
	var box = document.getElementById(id);
	if (!box) return;
	var node;
	try {
		node = build();
	} catch (e) {
		/* Report it and keep the previous content; the next poll retries. */
		if (window.console && window.console.error)
			window.console.error('airoha-npu: rendering #' + id + ' failed', e);
		return;
	}
	if (!node) { box.innerHTML = ''; return; }
	box.innerHTML = '';
	box.appendChild(node);
}

/* ── PPE Table ── */
function renderPpeEmptyRow() {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td', 'colspan': 6 }, E('span', { 'class': 'soc-muted' }, _('No offloaded flows')))
	]);
}

function renderPpeRows(entries) {
	return entries.slice(0,100).map(function(e) {
		var eth = e.eth||''; if(eth==='00:00:00:00:00:00->00:00:00:00:00:00') eth='-';
		return E('tr',{'class':'tr'},[
			E('td',{'class':'td'},e.index), E('td',{'class':'td'},E('span',{'class':e.state==='BND'?'label-success':''},e.state)),
			E('td',{'class':'td'},e.type), E('td',{'class':'td'},e.orig||'-'), E('td',{'class':'td'},e.new_flow||'-'), E('td',{'class':'td'},eth)
		]);
	});
}

/* ── Main View ── */
return view.extend({
	load: function() {
		return Promise.all([ callNpuStatus(), callPpeEntries(), callFrameEngine() ]);
	},

	render: function(data) {
		injectCSS();
		var st = data[0]||{}, ppe = data[1]||{}, wf = data[2]||{}, fe = data[3]||{};
		var entries = Array.isArray(ppe.entries) ? ppe.entries : [];
		var memR = Array.isArray(st.memory_regions) ? st.memory_regions : [];
		var memRam = st.mem_ram_kb || 0;
		var memPct = (memRam > 0 && st.mem_total_kb > 0) ? ((st.mem_total_kb/memRam)*100).toFixed(1)+'%' : '';

		var view = E('div',{'class':'cbi-map'},[
			E('h2',{},_('Airoha SoC Status')),

			// CPU Frequency
			E('div',{'class':'cbi-section'},[
				E('h3',{},_('CPU Frequency')),
				E('table',{'class':'table'},[
					E('tr',{'class':'tr'},[ E('td',{'class':'td','width':'33%'},E('strong',{},_('Current Frequency'))), E('td',{'class':'td'}, renderFreqBar(st.cpu_hw_freq,st.cpu_min_freq,st.cpu_max_freq,st.pll_freq_mhz,st.cpu_governor)) ]),
					E('tr',{'class':'tr'},[ E('td',{'class':'td'},E('strong',{},_('Governor'))), E('td',{'class':'td'}, renderGovSelect(st.cpu_avail_governors,st.cpu_governor)) ]),
					E('tr',{'class':'tr'},[ E('td',{'class':'td'},E('strong',{},_('Max Frequency'))), E('td',{'class':'td'}, renderMaxFreqSelect(st.cpu_avail_freqs,st.cpu_max_freq)) ]),
					E('tr',{'class':'tr'},[ E('td',{'class':'td'},E('strong',{},_('Overclock'))), E('td',{'class':'td'}, renderOcControls()) ]),
					E('tr',{'class':'tr'},[ E('td',{'class':'td'},E('strong',{},_('CPU Cores'))), E('td',{'class':'td'},(st.cpu_count||0).toString()) ])
				])
			]),

			// NPU & Frame Engine (unified)
			E('div',{'class':'cbi-section'},[
				E('h3',{},_('NPU & Offload Engine')),
				E('table',{'class':'table'},[
					E('tr',{'class':'tr'},[ E('td',{'class':'td','width':'33%'},E('strong',{},_('NPU Status'))),
						E('td',{'class':'td','id':'npu-status'}, st.npu_loaded ?
							E('span',{'class':'label-success'},_('Active')+(st.npu_device?' ('+st.npu_device+')':'')) :
							E('span',{'class':'label-danger'},_('Not Active'))) ]),
					E('tr',{'class':'tr'},[ E('td',{'class':'td'},E('strong',{},_('Firmware / Clock / Cores'))),
						E('td',{'class':'td','id':'npu-info'}, (st.npu_version||'N/A')+' | '+(st.npu_clock?(st.npu_clock/1e6).toFixed(0)+' MHz':'N/A')+' | '+(st.npu_cores||0)+' cores') ]),
					E('tr',{'class':'tr'},[ E('td',{'class':'td'},E('strong',{},_('Reserved Memory'))),
						E('td',{'class':'td','id':'npu-memory'},
							calcTotalMem(memR)+' ('+memR.length+' regions)' +
							(memRam ? ' of '+fmtMemKb(memRam)+' RAM'+(memPct?' ('+memPct+')':'') : '')) ])
				]),

				// Frame Engine diagram
				E('div',{'style':'margin-top:12px'},[ E('h4',{'class':'soc-text','style':'font-size:14px;margin-bottom:8px'},_('Frame Engine'))]),
				E('div',{'id':'fe-container'}, renderFeDiagram(fe, st, wf))
			]),

			// WiFi (only rendered on boards that actually have wireless)
			E('div',{'id':'wifi-container'}, [ renderWifi(wf) ].filter(Boolean)),

			// PPE Flow Table
			E('div',{'class':'cbi-section'},[
				E('h3',{},_('PPE Flow Offload Entries')),
				E('table',{'class':'table','id':'ppe-entries-table'},[
					E('tr',{'class':'tr cbi-section-table-titles'},[
						E('th',{'class':'th'},_('Index')), E('th',{'class':'th'},_('State')), E('th',{'class':'th'},_('Type')),
						E('th',{'class':'th'},_('Original Flow')), E('th',{'class':'th'},_('New Flow')), E('th',{'class':'th'},_('Ethernet'))
					])
				].concat(entries.length ? renderPpeRows(entries) : [ renderPpeEmptyRow() ]))
			])
		]);

		poll.add(L.bind(function() {
			return Promise.all([ callNpuStatus(), callPpeEntries(), callWifiInfo(), callFrameEngine() ]).then(L.bind(function(d) {
				injectCSS();
				var st=d[0]||{}, ppe=d[1]||{}, wf=d[2]||{}, fe=d[3]||{};
				var entries = Array.isArray(ppe.entries)?ppe.entries:[];

				updateFreqBar(st.cpu_hw_freq,st.cpu_min_freq,st.cpu_max_freq,st.pll_freq_mhz,st.cpu_governor);
				var gs=document.getElementById('cpu-governor-select'); if(gs&&!gs.matches(':focus')) gs.value=st.cpu_governor||'';
				var fs=document.getElementById('cpu-maxfreq-select'); if(fs&&!fs.matches(':focus')) fs.value=(st.cpu_max_freq||0).toString();

				var se=document.getElementById('npu-status');
				if(se){se.innerHTML='';var sp=document.createElement('span');sp.className=st.npu_loaded?'label-success':'label-danger';sp.textContent=st.npu_loaded?(_('Active')+(st.npu_device?' ('+st.npu_device+')':'')):_('Not Active');se.appendChild(sp);}

				var ni=document.getElementById('npu-info');
				if(ni){ni.textContent=(st.npu_version||'N/A')+' | '+(st.npu_clock?(st.npu_clock/1e6).toFixed(0)+' MHz':'N/A')+' | '+(st.npu_cores||0)+' cores';}

				// Each section is refreshed independently: one failing section
				// keeps its previous content and the others still update.
				updateSection('fe-container', function(){ return renderFeDiagram(fe, st, wf); });

				// A null here means "this board has no wireless to report", so
				// the container is emptied; it is never emptied on an error.
				updateSection('wifi-container', function(){ return renderWifi(wf); });

				var tb=document.getElementById('ppe-entries-table');
				if(tb){
					var newRows=(entries.length ? renderPpeRows(entries) : [renderPpeEmptyRow()]);
					while(tb.rows.length>1)tb.deleteRow(1);
					newRows.forEach(function(r){tb.appendChild(r);});
				}
			},this));
		},this), 5);

		return view;
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
