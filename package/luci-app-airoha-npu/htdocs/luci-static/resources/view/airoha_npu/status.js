'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require view.airoha.ui as aui';

/* ── RPC declarations ── */
var callNpuStatus = rpc.declare({ object: 'luci.airoha_npu', method: 'getStatus' });
var callDashboard = rpc.declare({ object: 'luci.airoha_npu', method: 'getDashboard', params: ['ppe'] });
var callPpeEntries = rpc.declare({ object: 'luci.airoha_npu', method: 'getPpeEntries' });
var callTokenInfo = rpc.declare({ object: 'luci.airoha_npu', method: 'getTokenInfo' });
var callSetGovernor = rpc.declare({ object: 'luci.airoha_npu', method: 'setGovernor', params: ['governor'] });
var callSetMaxFreq = rpc.declare({ object: 'luci.airoha_npu', method: 'setMaxFreq', params: ['freq'] });
// VLAN Offload is an independent switch again (it owns the VLAN passthrough
// pair), so its declares are live here. PPPoE passthrough is owned by AP Mode
// Acceleration on this page - nothing below drives setPppoeOffload, so this
// view keeps no PPPoE declares at all.
var callGetVlanOffload = rpc.declare({ object: 'luci.airoha_npu', method: 'getVlanOffload' });
var callSetVlanOffload = rpc.declare({ object: 'luci.airoha_npu', method: 'setVlanOffload', params: ['enabled'] });
var callGetFlowOffload = rpc.declare({ object: 'luci.airoha_npu', method: 'getFlowOffload' });
var callSetFlowOffload = rpc.declare({ object: 'luci.airoha_npu', method: 'setFlowOffload', params: ['enabled'] });
var callGetApModeOffload = rpc.declare({ object: 'luci.airoha_npu', method: 'getApModeOffload' });
var callSetApModeOffload = rpc.declare({ object: 'luci.airoha_npu', method: 'setApModeOffload', params: ['enabled'] });
var callGetDeviceMode = rpc.declare({ object: 'luci.airoha_npu', method: 'getDeviceMode' });
var callGetTopology = rpc.declare({ object: 'luci.airoha_npu', method: 'getTopology' });
var callGetWifiStats = rpc.declare({ object: 'luci.airoha_npu', method: 'getWifiStats' });
var callFrameEngine = rpc.declare({ object: 'luci.airoha_npu', method: 'getFrameEngine' });
var callSetCpuSettings = rpc.declare({ object: 'luci.airoha_npu', method: 'setCpuSettings', params: ['governor', 'freq'] });

var CPU_MIN_FREQ_KHZ = 500000;
var CPU_MAX_FREQ_KHZ = 1400000;

// Tracks whether the user has changed a CPU control select without saving yet.
// While dirty, the 5s poll must NOT overwrite the selects with live sysfs values.
var cpuSettingsDirty = false;

/* ── Shared state vocabulary ────────────────────────────────────────────── */

function isEnabled(value) {
	return value === true || value === 1 || value === '1';
}

function isBridgeOffloadBlocked(mode) {
	mode = mode || {};
	return isEnabled(mode.bridge_offload_blocked);
}

/* Token-pool occupancy → { text, kind }. */
function tokenHealth(c, s) {
	if (!s) return { text: _('Unknown'), kind: '' };
	var p = c / s * 100;
	return p < 50 ? { text: _('Normal'), kind: 'ok' }
		: p < 80 ? { text: _('Warning'), kind: 'warn' }
			: { text: _('Critical'), kind: 'error' };
}

function getTxQueue(ti, b) {
	var q = Array.isArray(ti.tx_queues) ? ti.tx_queues : [];
	for (var i = 0; i < q.length; i++) if (q[i].band === b) return q[i];
	return null;
}

/* ── Port labels ──────────────────────────────────────────────────────────
 * External port names are pinned per board model ("10G WAN", "2.5G LAN3"…)
 * because they describe the port's design identity, not the momentary PHY
 * result — a label must not change just because a link negotiated down.
 * Boards are matched on the getTopology compatible/model string and ports on
 * their netdev name; anything unmapped (unknown board or netdev) falls back
 * to the topology-derived label. Technical tokens (GDM1, the netdev names)
 * stay untranslated, exactly as the file already treats them. */

/* Human-readable role/mode summary for one topology port. The role tokens
 * (WAN / LAN / PON) are deliberately passed through untranslated like the
 * other technical tokens below: they are standard abbreviations, and every
 * catalog on the device has its own idea of what a bare "LAN" means
 * (base.lmo maps it to a bandwidth word, some vendor catalogs to
 * "LAN 流量"), so translating them only produces wrong labels. */
function portLabel(p) {
	p = p || {};
	var role = String(p.role || '').toLowerCase();
	var mode = String(p.mode || '');
	var netdev = String(p.netdev || '');
	var parts = [];
	if (mode === 'internal' || !netdev) parts.push(_('Internal Switch'));
	else if (role === 'wan') parts.push('WAN');
	else if (role === 'lan') parts.push('LAN');
	else parts.push(_('No netdev'));
	if (mode && mode !== 'internal') parts.push(mode.toUpperCase());
	if (netdev) parts.push(netdev);
	return parts.join(' · ');
}

function portName(p) {
	if (p && p.kind === 'gdm') return 'GDM' + p.reg;
	return String((p && p.key) || '').toUpperCase();
}

/* Link speed (Mbps) → compact tag: 10000 → "10G", 1000 → "1G". */
function speedTag(mbps) {
	mbps = Number(mbps) || 0;
	if (mbps >= 10000) return '10G';
	if (mbps >= 5000) return '5G';
	// 2488 is GPON downstream: at a flat 2500 floor it would read as "1G".
	if (mbps >= 2400) return '2.5G';
	// 2000 is NG-PON2 2G/2G and turbo-EPON - also would have read as "1G".
	if (mbps >= 1900) return '2G';
	if (mbps >= 1000) return '1G';
	if (mbps >= 100) return '100M';
	return '';
}

/* Static per-mode speed fallback (Mbps) for ports whose link is down, so a
 * "1G LAN4" label still reads as 1G before the PHY negotiates. */
function modeFallbackMbps(mode) {
	switch (String(mode || '').toLowerCase()) {
		case 'usxgmii': case 'dxa': return 10000;
		case '2500base-x': return 2500;
		case 'sgmii': case 'internal': return 1000;
		default: return 0;
	}
}

/* Best-known speed tag for a port: negotiated speed wins, else the mode's
 * static capability. */
function portSpeedTag(p) {
	return speedTag(p && p.speed_mbps) || speedTag(modeFallbackMbps(p && p.mode));
}

/* A port that fronts the internal switch CPU (no netdev of its own). */
function isSwitchCpuPort(p) {
	return !(p && p.netdev) || p.role === 'conduit' || String(p.netdev) === 'cpu';
}

/* LAN netdevs behind the internal switch sharing the same GDM data path. */
function switchLanNetdevs(pse, topo) {
	var out = [];
	(Array.isArray(topo && topo.ports) ? topo.ports : []).forEach(function(q) {
		if (q && q.kind === 'gsw' && q.pse === pse && q.netdev) out.push(q.netdev);
	});
	return out;
}

/* Fixed per-board port labels, keyed by netdev. Speeds are the ports' design
 * capability — deliberately not live negotiation, so a label never flips
 * between "10G" and "1G" while a link renegotiates.
 *   XR1710G: 10G WAN / 10G LAN2 / 1G LAN3 / 1G LAN4 (+WiFi via CDM4)
 *   XG2010G: 10G LAN1 / 10G LAN2 / 2.5G LAN3 / 1G LAN4 (uplink is the PON card) */
var BOARD_PORT_NAMES = {
	xr1710: { wan: '10G WAN', lan2: '10G LAN2', lan3: '1G LAN3', lan4: '1G LAN4' },
	xg2010: { lan1: '10G LAN1', lan2: '10G LAN2', lan3: '2.5G LAN3', lan4: '1G LAN4' }
};

/* Pick the fixed label table for this board, or null when the board is not
 * one of the pinned models (unknown boards keep the topology-derived label). */
function boardPortNames(topo) {
	var id = (((topo && topo.compatible) || '') + ' ' + ((topo && topo.model) || '')).toLowerCase();
	var keys = Object.keys(BOARD_PORT_NAMES);
	for (var i = 0; i < keys.length; i++) {
		if (id.indexOf(keys[i]) >= 0) return BOARD_PORT_NAMES[keys[i]];
	}
	return null;
}

/* Human-facing name for a topology port: "10G WAN", "10G LAN2", "1G LAN3". */
function humanPortName(p, topo) {
	p = p || {};
	if (p.role === 'pon') return 'PON';
	if (isSwitchCpuPort(p)) {
		var lans = switchLanNetdevs(p.pse, topo);
		if (!lans.length) return _('Internal Switch');
		var fixedLans = boardPortNames(topo);
		return 'LAN · ' + lans.map(function(x) {
			return (fixedLans && fixedLans[String(x).toLowerCase()]) || x;
		}).join(', ');
	}
	var fixed = boardPortNames(topo);
	if (fixed) {
		var nd = String(p.netdev || '').toLowerCase();
		if (fixed[nd]) return fixed[nd];
	}
	var speed = portSpeedTag(p);
	if (String(p.role || '').toLowerCase() === 'wan')
		return (speed ? speed + ' ' : '') + 'WAN';
	return (speed ? speed + ' ' : '') + 'LAN' + String(p.netdev).replace(/^lan/i, '');
}

/* Accent colour for a GDM card: CPU/internal-facing MACs are amber, the
 * externally-facing LAN/WAN MACs are green. */
function portAccent(p) {
	p = p || {};
	if (String(p.mode || '') === 'internal' || !p.netdev) return 'var(--ds-warn)';
	return 'var(--ds-ok)';
}

/* ── Summary tiles ── */
function npuSummaryTiles(st, ti) {
	st = st || {}; ti = ti || {};
	var active = isEnabled(st.npu_loaded);
	var clock = st.npu_clock ? Math.round(st.npu_clock / 1000000) : 0;
	var bound = st.offload_bound || 0;
	var total = st.offload_total || 0;

	// TX token pool — the hardware send tokens the NPU/WDMA draws from. This is
	// the reading the old view never surfaced.
	var tokCount = Number(ti.token_count) || 0;
	var tokSize = Number(ti.token_size) || 0;
	var tokPct = tokSize > 0 ? tokCount / tokSize * 100 : 0;
	var tokAccent = !tokSize ? 'var(--ds-text-muted)'
		: tokPct < 50 ? 'var(--ds-ok)'
			: tokPct < 80 ? 'var(--ds-warn)' : 'var(--ds-error)';

	var temp = (st.cpu_temp && st.cpu_temp !== 'N/A') ? st.cpu_temp : '';

	var tiles = {
		'npu-summary-status': aui.tile({
			id: 'npu-summary-status', title: _('NPU Status'),
			value: active ? _('Activated') : _('Not Activated'),
			accent: active ? 'var(--ai-npu)' : 'var(--ds-text-muted)',
			sub: active ? (st.npu_device || _('NPU device ready')) : _('Driver unavailable')
		}),
		'npu-summary-clock': aui.tile({
			id: 'npu-summary-clock', title: _('NPU Clock / Cores'),
			value: clock ? clock + ' MHz' : 'N/A', accent: 'var(--ds-ok)',
			sub: (st.npu_cores || 0) + ' ' + _('cores')
		}),
		'npu-summary-flows': aui.tile({
			id: 'npu-summary-flows', title: _('Offload Statistics'),
			value: bound + ' / ' + total,
			accent: total > 0 ? 'var(--ai-npu)' : 'var(--ds-text-muted)',
			sub: _('Bound / total PPE flows')
		}),
		// The reserved-memory regions tile was dropped: region count/size means
		// nothing to an operator and the DTS never changes after boot.
		'npu-summary-temp': aui.tile({
			id: 'npu-summary-temp', title: _('CPU Temperature'),
			value: temp ? temp.replace(/[^\d.]/g, '') : '—', unit: temp ? '°C' : '',
			accent: 'var(--ds-ok)',
			sub: (st.cpu_count || 0) + ' ' + _('cores') + ' · ' + (st.soc_compat || '')
		})
	};

	// The TX token pool tile only carries meaning when the driver exposes the
	// probe (mt76's token_info debugfs node). On builds without it the tile
	// would sit at "N/A / Unknown" forever — hide it instead.
	if (tokSize > 0) {
		tiles['npu-summary-token'] = aui.tile({
			id: 'npu-summary-token', title: _('TX Token Pool'),
			value: tokCount + ' / ' + tokSize,
			accent: tokAccent,
			sub: _('used') + ' ' + aui.fmtPct(tokPct, 0)
		});
	}

	return tiles;
}

var SUMMARY_IDS = [
	'npu-summary-status', 'npu-summary-clock', 'npu-summary-flows',
	'npu-summary-token', 'npu-summary-temp'
];

function renderSummary(st, ti) {
	var tiles = npuSummaryTiles(st, ti);
	return E('div', { 'class': 'ai-grid ai-grid--tiles', 'id': 'npu-summary-grid' },
		SUMMARY_IDS.map(function(id) { return tiles[id]; }).filter(Boolean));
}

function updateSummary(st, ti) {
	var grid = document.getElementById('npu-summary-grid');
	if (!grid) return;
	var tiles = npuSummaryTiles(st, ti);
	grid.innerHTML = '';
	SUMMARY_IDS.forEach(function(id) { if (tiles[id]) grid.appendChild(tiles[id]); });
}

/* ── CPU frequency ── */
function freqState(st) {
	st = st || {};
	var hw = st.cpu_hw_freq || 0, min = st.cpu_min_freq || 0, max = st.cpu_max_freq || 0;
	var freq = hw || st.cpu_cur_freq || 0;
	return { freq: freq, min: min, max: max || freq };
}

function renderCpuInfo(st) {
	st = st || {};
	return aui.card({
		name: _('CPU Info'), tag: _('CPU model / temperature'), accent: 'var(--ai-npu)',
		body: [
			aui.row(_('Model'), st.soc_compat || ''),
			aui.row(_('Architecture'), st.cpu_arch || ''),
			aui.row(_('Core Count'), (st.cpu_count || 0)),
			aui.row(_('Temperature'), (st.cpu_temp && st.cpu_temp !== 'N/A') ? st.cpu_temp : 'N/A')
		]
	});
}

function renderFreqCard(st) {
	st = st || {};
	return aui.card({
		name: _('CPU Control'), accent: 'var(--ds-ok)',
		body: E('div', { 'id': 'cpu-control-content' }, [ renderControlSettings(st) ])
	});
}

/* ── Frequency history chart ──
 * One sample per 5 s poll, 120 samples = 10 minutes of active history. Samples
 * survive a page refresh for up to 30 minutes in this tab. A restored run and
 * a new run can have a time gap; the compact chart intentionally keeps sample
 * spacing (rather than wall-clock spacing), matching the original chart. */
var FREQ_HISTORY_KEY = 'airoha_npu.freq_history';
var FREQ_HISTORY_MAX_AGE_MS = 30 * 60 * 1000;
var FREQ_HISTORY_MAX = 120;

function loadFreqHistory() {
	var now = Date.now();
	try {
		var raw = sessionStorage.getItem(FREQ_HISTORY_KEY);
		if (!raw) return [];
		var samples = JSON.parse(raw);
		if (!Array.isArray(samples)) return [];
		return samples.filter(function(sample) {
			return sample && typeof sample === 'object' &&
				typeof sample.t === 'number' && isFinite(sample.t) && sample.t > 0 &&
				typeof sample.v === 'number' && isFinite(sample.v) && sample.v > 0 &&
				sample.t >= now - FREQ_HISTORY_MAX_AGE_MS;
		}).slice(-FREQ_HISTORY_MAX);
	} catch (err) {
		// Storage can be disabled (including privacy modes) or contain stale data.
		return [];
	}
}

function saveFreqHistory() {
	try {
		sessionStorage.setItem(FREQ_HISTORY_KEY, JSON.stringify(freqHistory));
	} catch (err) {
		// A denied or full storage area must never stop the five-second poll.
	}
}

var freqHistory = loadFreqHistory();

function pushFreqSample(khz) {
	khz = Number(khz);
	if (!isFinite(khz) || !(khz > 0)) return;
	freqHistory.push({ t: Date.now(), v: khz });
	if (freqHistory.length > FREQ_HISTORY_MAX) freqHistory.shift();
	saveFreqHistory();
}

/* LuCI's E() uses document.createElement() and cannot create SVG-namespace
 * elements, so build chart nodes with createElementNS. */
var SVG_NS = 'http://www.w3.org/2000/svg';
function svgEl(tag, attrs, children) {
	var el = document.createElementNS(SVG_NS, tag);
	if (attrs) for (var k in attrs) el.setAttribute(k, attrs[k]);
	if (children) for (var i = 0; i < children.length; i++) el.appendChild(children[i]);
	return el;
}

function renderFreqChart(min, max, containerW) {
	var lo = (min > 0) ? min : CPU_MIN_FREQ_KHZ;
	var hi = (max > lo) ? max : CPU_MAX_FREQ_KHZ;
	var n = freqHistory.length;
	if (!n) return E('div', { 'class': 'ai-empty' }, _('No data'));

	var W = Math.round(containerW > 0 ? containerW : 600);
	var H = 240, padX = 6, padT = 14, padB = 6;
	var innerW = W - padX * 2, innerH = H - padT - padB;
	var span = hi - lo;
	function yOf(f) {
		var c = Math.min(Math.max(f, lo), hi);
		return padT + innerH - (c - lo) / span * innerH;
	}
	var pts = [], xs = [], ys = [];
	for (var i = 0; i < n; i++) {
		var x = padX + (FREQ_HISTORY_MAX - n + i) / (FREQ_HISTORY_MAX - 1) * innerW;
		var y = yOf(freqHistory[i].v);
		xs.push(x); ys.push(y);
		pts.push(x.toFixed(1) + ',' + y.toFixed(1));
	}
	if (n === 1) { xs.unshift(padX); ys.unshift(ys[0]); pts.unshift(padX + ',' + ys[0].toFixed(1)); }
	/* Close the area fill at the first/last data x, not the chart edges,
	 * otherwise the polygon diagonal streaks across empty space. */
	var area = pts.slice();
	area.push(xs[xs.length - 1].toFixed(1) + ',' + (padT + innerH));
	area.unshift(xs[0].toFixed(1) + ',' + (padT + innerH));

	var gridStyle = 'stroke:var(--ds-border);stroke-width:1;stroke-dasharray:3 3';
	var lblStyle = 'fill:var(--ds-text-muted);font-size:9px;font-family:var(--ds-mono)';
	var last = pts[pts.length - 1].split(',');
	return svgEl('svg', {
		'viewBox': '0 0 ' + W + ' ' + H,
		'width': '100%', 'height': H,
		'style': 'display:block',
		'role': 'img', 'aria-label': _('Frequency History')
	}, [
		svgEl('line', { 'x1': padX, 'y1': padT, 'x2': W - padX, 'y2': padT, 'style': gridStyle }),
		svgEl('line', { 'x1': padX, 'y1': padT + innerH, 'x2': W - padX, 'y2': padT + innerH, 'style': gridStyle }),
		svgEl('text', { 'x': padX + 2, 'y': padT - 4, 'style': lblStyle }, [ document.createTextNode(aui.fmtFreq(hi)) ]),
		svgEl('text', { 'x': padX + 2, 'y': padT + innerH - 4, 'style': lblStyle }, [ document.createTextNode(aui.fmtFreq(lo)) ]),
		svgEl('polygon', { 'points': area.join(' '), 'style': 'fill:var(--ds-ok);opacity:.12;stroke:none' }),
		svgEl('polyline', {
			'points': pts.join(' '),
			'style': 'fill:none;stroke:var(--ds-ok);stroke-width:2;stroke-linejoin:round;stroke-linecap:round'
		}),
		svgEl('circle', { 'cx': last[0], 'cy': last[1], 'r': '3', 'style': 'fill:var(--ds-ok)' })
	]);
}

/* ── CPU control settings (governor / max freq + save) ── */
function governorLabel(governor) {
	var labels = {
		conservative: _('conservative'), ondemand: _('ondemand'), performance: _('performance'),
		powersave: _('powersave'), schedutil: 'schedutil', userspace: _('userspace')
	};
	return labels[governor] || governor;
}

function splitList(s) {
	return String(s == null ? '' : s).trim().split(/\s+/).filter(Boolean);
}

/* Map the backend cpufreq reason code to its translatable string. */
function cpuReasonText(reason) {
	if (reason === 'no_governors') return _('No CPU governors reported by the kernel');
	if (reason === 'no_frequencies') return _('No selectable CPU frequencies reported by the kernel');
	return _('CPU frequency scaling is not available on this board');
}

/* Returns '' while cpufreq is usable, otherwise the reason text to show. A
 * missing availability key fails open (a backend that predates the key must
 * keep working); the key is only treated as "unavailable" when the kernel also
 * reported nothing to choose from. */
function cpufreqReason(st) {
	st = st || {};
	var avail = st.cpu_cpufreq_available;
	if (avail !== undefined && avail !== null)
		return isEnabled(avail) ? '' : cpuReasonText(st.cpu_cpufreq_reason);
	if (splitList(st.cpu_avail_governors).length || splitList(st.cpu_avail_freqs).length)
		return '';
	return cpuReasonText(st.cpu_cpufreq_reason);
}

/* Build a CPU control <select>. It is ALWAYS a real select element (never a
 * bare text node) so the poll path and the Save handler can always find it.
 * When the available list is empty the live value is seeded so the control
 * still displays the current setting; when nothing is known at all it becomes
 * a disabled placeholder carrying the backend reason as its only option. */
function cpuSelect(id, values, current, placeholder, labelFn) {
	var attrs = {
		'id': id, 'class': 'cbi-input-select',
		'change': function() { cpuSettingsDirty = true; updateCpuSettingsHint(); }
	};
	var opts;
	if (values && values.length) {
		opts = values.map(function(v) {
			return E('option', { 'value': v, 'selected': String(v) === String(current) ? '' : null }, labelFn(v));
		});
	} else if (current !== undefined && current !== null && String(current) !== '') {
		opts = [ E('option', { 'value': String(current), 'selected': '' }, labelFn(current)) ];
	} else {
		opts = [ E('option', { 'value': '', 'selected': '' }, placeholder || 'N/A') ];
	}
	if (!(values && values.length)) attrs.disabled = '';
	return E('select', attrs, opts);
}

function renderGovSelect(avail, active, reason) {
	return cpuSelect('cpu-governor-select', splitList(avail), active || '', reason, governorLabel);
}

function renderMaxFreqSelect(avail, cur, reason) {
	var freqs = splitList(avail).map(function(f) { return parseInt(f, 10); })
		.filter(function(f) { return isFinite(f) && f >= CPU_MIN_FREQ_KHZ && f <= CPU_MAX_FREQ_KHZ; })
		.filter(function(f, i, values) { return values.indexOf(f) === i; });
	var activeNum = parseInt(cur, 10);
	// The select must mirror the live kernel value: when scaling_max_freq is
	// missing from the advertised list (quirky OPP table), inject it as an
	// option instead of silently clamping the display to a different value.
	if (isFinite(activeNum) && activeNum >= CPU_MIN_FREQ_KHZ && activeNum <= CPU_MAX_FREQ_KHZ && freqs.indexOf(activeNum) < 0)
		freqs.push(activeNum);
	freqs.sort(function(a, b) { return a - b; });
	var active = isFinite(activeNum) && activeNum > 0 ? String(activeNum)
		: (freqs.length ? String(freqs[freqs.length - 1]) : '');
	return cpuSelect('cpu-maxfreq-select', freqs.map(String), active, reason, function(f) {
		return Math.round(parseInt(f, 10) / 1000) + ' MHz';
	});
}

function updateCpuSettingsHint() {
	var hint = document.getElementById('cpu-settings-hint');
	if (!hint) return;
	if (cpuSettingsDirty) { hint.textContent = _('Unsaved changes'); hint.style.color = 'var(--ds-warn)'; }
	else { hint.textContent = ''; hint.style.color = ''; }
}

function renderControlSettings(st) {
	// Container rebuilt from live status → selections reflect what is currently applied.
	st = st || {};
	cpuSettingsDirty = false;

	var reason = cpufreqReason(st);

	var saveBtn = E('button', {
		'id': 'cpu-settings-save',
		'class': 'ai-btn ai-btn--primary',
		'title': reason || null,
		'click': function(ev) {
			var btn = ev.target;
			var gs = document.getElementById('cpu-governor-select');
			var fs = document.getElementById('cpu-maxfreq-select');
			if (!gs || !fs || gs.disabled || fs.disabled) {
				ui.addNotification(null, E('p', {}, reason || _('No CPU frequency controls are available on this board')), 'warning');
				return;
			}
			btn.disabled = true;
			callSetCpuSettings(gs.value, parseInt(fs.value)).then(function(r) {
				btn.disabled = false;
				if (r && r.error) {
					ui.addNotification(null, E('p', {}, _('Error: ') + r.error), 'error');
				} else {
					cpuSettingsDirty = false;
					updateCpuSettingsHint();
					ui.addNotification(null, E('p', {}, _('CPU settings saved — they will persist after a reboot')), 'info');
				}
			}).catch(function() { btn.disabled = false; });
		}
	}, _('Save'));
	// The Save button is always rendered; it is only disabled while there is
	// nothing selectable, and its title explains why.
	if (reason) saveBtn.disabled = true;

	var hint = E('span', { 'id': 'cpu-settings-hint', 'class': 'ai-muted' }, '');
	var note = E('div', {
		'id': 'cpu-cpufreq-note', 'class': 'ai-hint',
		'style': 'flex-basis:100%;margin:0'
	}, reason || '');

	return E('div', { 'class': 'ai-form' }, [
		E('div', { 'class': 'ai-field' }, [
			E('label', { 'class': 'ai-field-label', 'for': 'cpu-governor-select' }, _('Governor')),
			renderGovSelect(st.cpu_avail_governors, st.cpu_governor, reason)
		]),
		E('div', { 'class': 'ai-field' }, [
			E('label', { 'class': 'ai-field-label', 'for': 'cpu-maxfreq-select' }, _('Max Freq')),
			renderMaxFreqSelect(st.cpu_avail_freqs, st.cpu_max_freq, reason)
		]),
		saveBtn,
		hint,
		note
	]);
}

/* ── Offload switches ── */
function offloadState(enabled, blocked) {
	enabled = isEnabled(enabled);
	blocked = isEnabled(blocked);
	if (blocked) return { kind: 'warn', text: _('Router mode restricted') };
	return enabled ? { kind: 'ok', text: _('Enabled') } : { kind: '', text: _('Disabled') };
}

function renderOffloadSwitch(cfg) {
	return aui.switchRow({
		rowId: cfg.rowId,
		inputId: cfg.inputId,
		badgeId: cfg.badgeId,
		name: cfg.name,
		note: cfg.note,
		on: isEnabled(cfg.enabled),
		blocked: isEnabled(cfg.blocked),
		onLabel: _('Enabled'),
		offLabel: _('Disabled'),
		blockedLabel: _('Router mode restricted'),
		title: isEnabled(cfg.blocked)
			? (isEnabled(cfg.enabled) ? _('Suggested off in router mode') : _('Use hardware flow offload in router mode'))
			: (isEnabled(cfg.enabled) ? _('Click to disable') : _('Click to enable')),
		onChange: function(input) {
			var val = input.checked ? 1 : 0;
			var blocked = input.getAttribute('data-blocked') === '1';
			if (blocked && val === 1) {
				input.checked = false;
				ui.addNotification(null, E('p', {}, _('Use hardware flow offload in router mode')), 'warning');
				return;
			}
			input.disabled = true;
			cfg.callFn(val).then(function(r) {
				input.disabled = false;
				if (r && r.error) {
					input.checked = !val;
					ui.addNotification(null, E('p', {}, _('Error: ') + r.error), 'error');
				} else {
					updateOffloadControl(cfg.inputId, cfg.badgeId, cfg.rowId, val, blocked);
				}
			}).catch(function() {
				input.checked = !val;
				input.disabled = false;
			});
		}
	});
}

function renderOffloadControls(topo, vo, flo, apo, blocked) {
	var id = String(topo && topo.compatible || '');
	if (!id) return null;
	var bridge = !/^gemtek,xg2010g(?:-|$)/.test(id) &&
		vo.supported !== false && apo.supported !== false;
	var controls = [
		renderOffloadSwitch({ rowId: 'flow-offload-row', inputId: 'flow-offload-select', badgeId: 'flow-offload-badge',
			name: _('Flow Offload'), enabled: flo.enabled, blocked: false, callFn: callSetFlowOffload })
	];
	if (bridge) {
		controls.unshift(renderOffloadSwitch({ rowId: 'vlan-offload-row', inputId: 'vlan-offload-select', badgeId: 'vlan-offload-badge',
			name: _('VLAN Offload'), enabled: vo.enabled, blocked: blocked, callFn: callSetVlanOffload }));
		controls.push(renderOffloadSwitch({ rowId: 'apmode-offload-row', inputId: 'apmode-offload-select', badgeId: 'apmode-offload-badge',
			name: _('AP Mode Acceleration'), enabled: apo.enabled, blocked: blocked, callFn: callSetApModeOffload }));
	}
	return E('div', { 'class': 'ai-offload-controls ai-grid' + (bridge ? ' ai-grid--3' : '') }, controls);
}

function updateOffloadControl(inputId, badgeId, rowId, enabled, blocked) {
	enabled = isEnabled(enabled);
	blocked = isEnabled(blocked);
	var input = document.getElementById(inputId);
	if (input) {
		input.setAttribute('data-blocked', blocked ? '1' : '0');
		if (!input.matches(':focus')) input.checked = enabled;
		input.disabled = blocked && !enabled;
	}
	var row = document.getElementById(rowId);
	if (row) {
		row.setAttribute('data-on', enabled ? 'true' : 'false');
		row.setAttribute('data-blocked', blocked ? 'true' : 'false');
	}
	var b = document.getElementById(badgeId);
	if (b) {
		var state = offloadState(enabled, blocked);
		b.className = 'ai-pill' + (state.kind ? ' ai-pill--' + state.kind : '');
		// Keep the leading dot; only the label text is swapped.
		b.textContent = '';
		b.appendChild(E('span', { 'class': 'dot' }));
		b.appendChild(document.createTextNode(state.text));
	}
}

function renderEthernetPorts(topo) {
	topo = topo || {};
	var ports = (Array.isArray(topo.ports) ? topo.ports : []).filter(function(p) {
		return p && p.netdev && !isSwitchCpuPort(p);
	}).sort(function(a, b) {
		var aUp = a.role === 'wan' || a.role === 'pon';
		var bUp = b.role === 'wan' || b.role === 'pon';
		return aUp !== bUp ? (aUp ? -1 : 1) : a.netdev.localeCompare(b.netdev, undefined, { numeric: true });
	});
	function count(value) {
		return typeof value === 'number' && isFinite(value) ? value.toLocaleString() : 'N/A';
	}
	/* A PON netdev reports carrier=1 as soon as the interface exists, which
	 * says nothing about whether the ONU ever reached the OLT - a stuck ONU
	 * therefore still showed "Link up". For the PON port derive the state from
	 * the registration data instead: no light (LOS), and any ONU state other
	 * than O5, mean the link is not actually carrying service. "LOS" and the
	 * O1-O7 codes are industry notation, so they need no translation and no
	 * new catalogue entry - which matters because a hand-deployed build never
	 * carries a rebuilt .lmo. */
	function ponLink(p) {
		var pon = topo.pon;
		if (!pon || pon.present !== 1 || !p) return null;
		if (p.role !== 'pon' && p.netdev !== pon.netdev) return null;
		if (pon.los === 1) return { text: _('Link down') + ' (LOS)', ok: false };
		var os = String(pon.onu_state || '').toUpperCase();
		if (os === 'O5') return { text: _('Link up') + ' (O5)', ok: true };
		if (/^O[1-7]$/.test(os)) return { text: _('Link down') + ' (' + os + ')', ok: false };
		return { text: _('Unknown'), ok: false };
	}
	function bytes(value) {
		return typeof value === 'number' && isFinite(value) ? '%1024.2mB'.format(value) : 'N/A';
	}
	/* Same 3px accent stripe the cards, tiles and switch rows carry, so the
	 * port table reads as one of the page's single elements instead of a bare
	 * grid. Ports are NPU-side hardware (GDM/GSW, the frame engine's own
	 * counters), so they take --ai-npu rather than the CPU/load accents. */
	var table = aui.table({
		accent: 'var(--ai-npu)',
		cols: [
			{ t: _('Port') }, { t: _('Path') }, { t: _('Link') }, { t: _('Speed / Duplex') },
			{ t: _('RX / TX bytes'), num: true }, { t: _('RX / TX packets'), num: true },
			{ t: _('RX / TX errors'), num: true }, { t: _('RX / TX dropped'), num: true }
		],
		rows: ports.map(function(p) {
			var state = p.present === false ? _('Unavailable') :
				p.carrier === 1 ? _('Link up') : p.carrier === 0 ? _('Link down') : _('Unknown');
			var up = p.carrier === 1;
			var plink = ponLink(p);
			if (plink) { state = plink.text; up = plink.ok; }
			// PON is asymmetric, so the backend reports its upstream rate
			// alongside the downstream one; every other port leaves it null.
			var speed = 'N/A';
			if (p.carrier === 1 && p.speed_mbps > 0 && p.speed_up_mbps > 0)
				speed = speedTag(p.speed_mbps) + '\u2193 / ' + speedTag(p.speed_up_mbps) + '\u2191';
			else if (p.carrier === 1 && p.speed_mbps > 0)
				speed = p.speed_mbps + ' Mbps';
			var path = (p.kind === 'gsw' ? 'GSW' : 'GDM') + p.reg;
			if (p.nbq !== null && p.nbq !== undefined) path += ' / NBQ' + p.nbq;
			return [
				humanPortName(p, topo) + ' (' + p.netdev + ')',
				path, aui.pill(state, up ? 'ok' : ''),
				speed + (p.carrier === 1 && p.duplex ? ' / ' + p.duplex : ''),
				bytes(p.rx_bytes) + ' / ' + bytes(p.tx_bytes),
				count(p.rx_packets) + ' / ' + count(p.tx_packets),
				count(p.rx_errors) + ' / ' + count(p.tx_errors),
				count(p.rx_dropped) + ' / ' + count(p.tx_dropped)
			];
		}),
		emptyText: _('Port data unavailable')
	});
	table.classList.add('ai-port-table');
	return table;
}

/* Detailed MT7996 per-band health. The backend's has_wifi flag is
 * authoritative, so radio-less XG2010G systems do not render an empty
 * section.
 *
 * One card per radio band, laid out exactly like the NPU & Offload Engine
 * block above: the left border carries the band's own accent
 * (--ai-band-24 / -5 / -6, the same tokens the band gauges use) so the three
 * bands stay distinguishable at a glance instead of being three anonymous
 * table rows. Every value the old per-band table showed is still here - the
 * path moved into the card's right-hand tag, the airtime column became the
 * bar, and the rest are rows. */
function renderWifiDetails(wifi, ppe, ti, st) {
	wifi = wifi || {};
	if (!aui.hasWifiRadio(wifi)) return null;
	var bands = Array.isArray(wifi.bands) ? wifi.bands : [];
	var bandBnd = ppe && ppe.bnd && Array.isArray(ppe.bnd.band_bnd) ? ppe.bnd.band_bnd : [];
	var bandUnb = ppe && ppe.unb && Array.isArray(ppe.unb.band_unb) ? ppe.unb.band_unb : [];
	var cards = bands.map(function(bd) {
		var info = aui.BANDS[bd.band];
		var accent = info ? 'var(' + info.varName + ')' : 'var(--ds-border-strong)';
		var name = info ? info.full : _('Frequency band') + ' ' + bd.band;
		var txPackets = Number(bd.tx_packets) || 0;
		var txRetries = Number(bd.tx_retries) || 0;
		var retry = txPackets + txRetries > 0 ? txRetries / (txPackets + txRetries) * 100 : (Number(bd.retry_pct) || 0);
		var retryColor = retry > 20 ? 'var(--ds-error)' : retry > 5 ? 'var(--ds-warn)' : 'var(--ds-ok)';
		var health = (bd.stations || 0) === 0 ? { text: _('No clients'), kind: '' } :
			retry > 50 ? { text: _('Poor'), kind: 'error' } :
				retry > 20 ? { text: _('Fair'), kind: 'warn' } : { text: _('Good'), kind: 'ok' };
		var txQueue = getTxQueue(ti, bd.band);
		var queueType = txQueue && txQueue.type ? String(txQueue.type).toUpperCase() :
			(isEnabled(st && st.npu_loaded) ? 'NPU' : 'DMA');
		var signal = (bd.stations || 0) > 0 ? (bd.avg_signal || 0) + ' / ' + (bd.min_signal || 0) : 'N/A';
		var airtime = Number(bd.airtime_efficiency) || 0;
		return aui.card({
			name: name,
			tag: 'P7 / ' + queueType,
			accent: accent,
			body: [
				aui.bar({
					pct: airtime,
					accent: accent,
					title: _('Airtime'),
					right: airtime + '%'
				}),
				aui.row(_('Status'), aui.pill(health.text, health.kind)),
				aui.row(_('Clients'), String(bd.stations || 0)),
				aui.row(_('Retry'), E('span', { 'style': 'color:' + retryColor }, retry.toFixed(1) + '%')),
				aui.row(_('PHY / Expected'), aui.fmtMbps(bd.avg_phy_rate) + ' / ' + aui.fmtMbps(bd.avg_exp_throughput)),
				aui.row(_('Failed'), String(bd.tx_failed || 0)),
				aui.row(_('Signal'), signal),
				aui.row(_('TX'), aui.fmtMbps(bd.tx_mbps) + ' Mbps'),
				aui.row('BND / UNB', (bandBnd[bd.band] || 0) + ' / ' + (bandUnb[bd.band] || 0))
			]
		});
	});
	var body = cards.length
		? E('div', {}, [
			E('div', { 'class': 'ai-subhead', 'style': 'margin-top:0' }, _('Frequency band')),
			E('div', { 'class': 'ai-grid ai-grid--3' }, cards)
		])
		: aui.empty(_('No entries'));
	return aui.section({
		title: _('WiFi Band Details'),
		hint: _('Per-band airtime efficiency, negotiated and expected rates, failure counts and BND/UNB ownership.'),
		body: body
	});
}

/* ── Frame Engine (GDM ports + CDM engines) ──────────────────────────────
 * The GDM data MACs and the CDM DMA engines have no debugfs node, so the
 * backend reads their counters straight from the frame-engine registers.
 * Those addresses belong to the SoC, not the board, so the same
 * GDM1/GDM2/GDM4 and CDM1/CDM2 set decodes on both boards this app ships to:
 * the XR1710G (WiFi router: switch CPU port, USXGMII WAN, USXGMII LAN2) and
 * the Nokia XG-040G-MD (PON ONU: switch CPU port, PON uplink, lan1). Only the
 * port *names* differ, and those come from the device-tree topology, exactly
 * like the Ethernet-ports table, so each card labels itself per board.
 *
 * The counters are free-running 32-bit registers: they wrap and reset only on
 * reboot, so they are shown as plain totals, never as rates. */

/* First topology entry behind a GDM register index, or null. Used both to keep
 * the GDM cards limited to the ports this board exposes and to give each card
 * the same board-aware name the port table uses. */
function gdmPort(topo, reg) {
	var ports = (topo && Array.isArray(topo.ports)) ? topo.ports : [];
	for (var i = 0; i < ports.length; i++) {
		var p = ports[i];
		if (p && p.kind === 'gdm' && Number(p.reg) === Number(reg)) return p;
	}
	return null;
}

/* Share of a CDM's RX frames the PPE forwarded without the CPU ever seeing
 * them. A HIGH share is the good case here - it is work the CPU never did -
 * which is the opposite of every load gauge elsewhere on the page. A low share
 * is deliberately NOT an error: the engine also carries control/host traffic
 * the PPE is never meant to touch, so it stays neutral rather than red. */
function cdmOffloadAccent(pct, total) {
	if (total <= 0) return 'var(--ds-border-strong)';
	if (pct >= 80) return 'var(--ds-ok)';
	if (pct >= 50) return 'var(--ds-warn)';
	return 'var(--ai-npu)';
}

function renderGdmCard(g, topo) {
	g = g || {};
	var tx = Number(g.tx) || 0, rx = Number(g.rx) || 0;
	var txDrop = Number(g.tx_drop) || 0, rxDrop = Number(g.rx_drop) || 0;
	var port = gdmPort(topo, g.reg);
	var body = [
		aui.row(_('TX packets'), aui.fmtK(tx)),
		aui.row(_('RX packets'), aui.fmtK(rx))
	];
	if (txDrop > 0) body.push(aui.row(_('TX dropped'), aui.fmtK(txDrop), 'ai-err'));
	if (rxDrop > 0) body.push(aui.row(_('RX dropped'), aui.fmtK(rxDrop), 'ai-err'));
	return aui.card({
		name: 'GDM' + g.reg,
		tag: port ? humanPortName(port, topo) : _('No port'),
		accent: (tx > 0 || rx > 0) ? 'var(--ai-npu)' : 'var(--ds-border-strong)',
		body: body
	});
}

function renderCdmCard(c) {
	c = c || {};
	var cpu = Number(c.rx_cpu) || 0, hwf = Number(c.rx_hwf) || 0;
	var total = cpu + hwf;
	var pct = total > 0 ? hwf / total * 100 : 0;
	var body = [
		aui.bar({
			pct: pct,
			accent: cdmOffloadAccent(pct, total),
			title: _('Offload share'),
			right: total > 0 ? aui.fmtPct(pct, 1) : '—'
		}),
		aui.row(_('CPU path'), aui.fmtK(cpu)),
		aui.row(_('HW forwarded'), aui.fmtK(hwf)),
		// Register +0x00 of this CDM, presented as a total in its own right.
		// It is NOT the sum of the CPU/HW delivery split above - on both test
		// boards it runs on a separate frame stream and can sit far below
		// rx_cpu - so the three lines must never be added up.
		// The JSON key stays `tx`: the backend is deployed by hand to two
		// devices, so renaming the field would break a device that is still
		// running the old backend with a new frontend.
		aui.row(_('Total received'), aui.fmtK(c.tx))
	];
	if ((Number(c.rx_cpu_drop) || 0) > 0) body.push(aui.row(_('CPU dropped'), aui.fmtK(c.rx_cpu_drop), 'ai-err'));
	if ((Number(c.rx_hwf_drop) || 0) > 0) body.push(aui.row(_('HW dropped'), aui.fmtK(c.rx_hwf_drop), 'ai-err'));
	return aui.card({
		name: 'CDM' + c.reg,
		tag: 'CPU DMA',
		accent: 'var(--ai-npu)',
		body: body
	});
}

/*
 * 峰值保持：PSE 共享缓冲是瞬时快照，而池子有 12064 个缓冲 —— 5 秒一次的轮询
 * 几乎总落在 0，1 位小数的百分比因此永远显示 0.0%，看不出任何突发。
 * 记住本次页面打开以来的最大占用，就能把"刚才有没有压满过"表达出来；
 * 峰值也一直是 0，则说明这段时间确实没有突发。页面重新加载时归零。
 */
var psePeakUsed = 0;

function renderPseBufferCard(pse) {
	pse = pse || {};
	var used = Number(pse.used) || 0, free = Number(pse.free) || 0;
	var total = used + free;
	var pct = total > 0 ? used / total * 100 : 0;
	if (used > psePeakUsed)
		psePeakUsed = used;
	var peakPct = total > 0 ? psePeakUsed / total * 100 : 0;
	var accent = total <= 0 ? 'var(--ds-border-strong)'
		: pct >= 80 ? 'var(--ds-error)' : pct >= 50 ? 'var(--ds-warn)' : 'var(--ds-ok)';
	return aui.card({
		name: _('PSE shared buffer'),
		tag: total > 0 ? aui.fmtPct(pct, 1) : '—',
		accent: accent,
		body: aui.bar({
			pct: pct,
			accent: accent,
			title: _('HW Buffer'),
			right: aui.fmtK(used) + ' / ' + aui.fmtK(total) +
				' · ' + _('peak') + ' ' + aui.fmtPct(peakPct, 1)
		})
	});
}

/* Map the backend's unavailability reason to a translatable sentence. */
function frameEngineReason(fe) {
	if (fe && fe.reason === 'devmem_unavailable')
		return _('Frame Engine counters need the devmem applet (CONFIG_BUSYBOX_CONFIG_DEVMEM) and /dev/mem; neither is available on this build.');
	return _('Frame Engine counters are unavailable on this build.');
}

/* The whole frame-engine block, rendered inside the NPU & Offload Engine
 * section. GDM cards are restricted to the ports this board exposes; the CDM
 * cards and the PSE buffer are board-independent. */
function renderFrameEngine(fe, topo) {
	fe = fe || {};
	var head = E('div', { 'class': 'ai-subhead', 'style': 'margin-top:0' }, _('Frame Engine'));
	var hint = E('p', { 'class': 'ai-hint' },
		_('Register-level counters for the GDM data MACs and CDM DMA engines, read from the frame-engine block.'));
	if (fe.available === false) {
		return E('div', { 'style': 'margin-top:var(--ds-sp-4)' }, [
			head, hint, aui.empty(frameEngineReason(fe))
		]);
	}
	// Keep only the GDM ports this board actually exposes. When the topology
	// is not known yet (first paint) the filter fails open rather than hiding
	// every card until the first poll lands.
	var knownPorts = !!(topo && Array.isArray(topo.ports) && topo.ports.length);
	var gdm = (Array.isArray(fe.gdm) ? fe.gdm : []).filter(function(g) {
		return g && (!knownPorts || gdmPort(topo, g.reg));
	});
	var cdm = Array.isArray(fe.cdm) ? fe.cdm : [];
	var blocks = [ head, hint, renderPseBufferCard(fe.pse) ];
	if (gdm.length) {
		blocks.push(E('div', { 'class': 'ai-subhead' }, _('GDM Ports')));
		blocks.push(E('div', { 'class': 'ai-grid ai-grid--3' }, gdm.map(function(g) {
			return renderGdmCard(g, topo);
		})));
	}
	if (cdm.length) {
		blocks.push(E('div', { 'class': 'ai-subhead' }, _('CDM Engines')));
		blocks.push(E('div', { 'class': 'ai-grid ai-grid--3' }, cdm.map(renderCdmCard)));
	}
	return E('div', { 'style': 'margin-top:var(--ds-sp-4)' }, blocks);
}

/* ── NPU and PPE engine status ── */
function renderEngineStatus(st, ppe) {
	st = st || {}; ppe = ppe || {};
	var npuActive = isEnabled(st.npu_loaded);
	var npuCard = aui.card({
		name: 'NPU', tag: npuActive ? 'ACTIVE' : 'OFF',
		accent: npuActive ? 'var(--ai-npu)' : 'var(--ds-border-strong)',
		body: [
			aui.row(_('Firmware / Clock / Cores'), (st.npu_version || 'Unknown') + ' · ' + (st.npu_clock ? Math.round(st.npu_clock / 1000000) + ' MHz' : 'N/A')),
			aui.row('RISC-V', (st.npu_cores || 0) + ' ' + _('cores') + ' · PCIe RAM')
		]
	});

	var unbCount = (Array.isArray(ppe.entries) ? ppe.entries : []).filter(function(e) {
		return e && e.state && e.state !== 'BND';
	}).length;
	var ppeCard = aui.card({
		name: 'PPE Engines', tag: 'P4 + P8', accent: 'var(--ai-npu)',
		body: [
			aui.row(_('Bound'), String(st.offload_bound || 0)),
			aui.row(_('Total'), String(st.offload_total || 0)),
			aui.row(_('Unbound'), String(unbCount))
		]
	});

	return E('div', { 'class': 'ai-grid ai-grid--2', 'style': 'margin-top:var(--ds-sp-2)' }, [ ppeCard, npuCard ]);
}

/* ── PPE flow table ── */
var PPE_SHOWN_MAX = 50;
var ppeStateFilter = '', ppeTypeFilter = '', ppePage = 0;
var ppeCurrentEntries = [], ppeCurrentMeta = {};

function filteredPpeEntries(entries) {
	return (entries || []).filter(function(e) {
		return e && (!ppeStateFilter || e.state === ppeStateFilter) &&
			(!ppeTypeFilter || String(e.type).split(' ')[0] === ppeTypeFilter);
	});
}

/* Header badge: how many entries the backend returned, the v4/v6 split, how
 * many are actually rendered, and how many were dropped by the client cap. */
function ppeCountText(entries) {
	entries = entries || [];
	if (ppeCurrentMeta.available === false) return _('PPE table unavailable');
	var total = ppeCurrentMeta.total === undefined ? entries.length : ppeCurrentMeta.total;
	var s = total + ' ' + _('flows') + ' · BND ' +
		(ppeCurrentMeta.bound || 0) + ' / UNB ' + (ppeCurrentMeta.unbound || 0) +
		' · IPv4 ' + (ppeCurrentMeta.ipv4 || 0) + ' / IPv6 ' + (ppeCurrentMeta.ipv6 || 0) +
		' / L2B ' + (ppeCurrentMeta.l2b || 0);
	if (ppeCurrentMeta.truncated) s += ' · ' + _('showing') + ' ' + entries.length + ' / ' + total;
	return s;
}

function ppeRows(entries) {
	entries = filteredPpeEntries(entries);
	if (!entries || !entries.length)
		return [ E('tr', {}, [ E('td', { 'colspan': '9' }, aui.empty(ppeCurrentMeta.available === false ? _('PPE table unavailable') : _('No matching flows'))) ]) ];
	return entries.slice(ppePage * PPE_SHOWN_MAX, (ppePage + 1) * PPE_SHOWN_MAX).map(function(e) {
		var eth = e.eth || '';
		if (eth === '00:00:00:00:00:00->00:00:00:00:00:00') eth = '-';
		var state = e.state === 'BND' ? aui.badge(e.state, 'bnd') : aui.badge(e.state, 'unb');
		return E('tr', {}, [
			E('td', { 'class': 'ai-num', 'data-label': _('Index') }, e.index),
			E('td', { 'data-label': _('State') }, state),
			E('td', { 'data-label': _('Type') }, e.type + (e.proto ? ' ' + e.proto : '')),
			E('td', { 'data-label': 'VLAN' }, e.vlan || '-'),
			E('td', { 'data-label': _('Original Flow'), 'style': 'color:var(--ai-npu)' }, e.orig || '-'),
			E('td', { 'data-label': _('New Flow') }, e.new_flow || '-'),
			E('td', { 'data-label': _('Ethernet') }, eth),
			E('td', { 'data-label': _('Packets'), 'class': 'ai-num' }, e.packets === null || e.packets === undefined ? 'N/A' : String(e.packets)),
			E('td', { 'data-label': _('Bytes'), 'class': 'ai-num' }, e.bytes === null || e.bytes === undefined ? 'N/A' : String(e.bytes))
		]);
	});
}

function renderPpeTable(entries) {
	function selectFilter(label, values, change) {
		return E('select', { 'aria-label': label, 'change': function(event) {
			change(event.target.value);
			ppePage = 0;
			updatePpeTable(ppeCurrentEntries);
		} }, [E('option', { value: '' }, label)].concat(values.map(function(value) {
			return E('option', { value: value }, value);
		})));
	}
	var tools = E('div', { 'style': 'display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px' }, [
		selectFilter(_('All states'), ['BND', 'UNB', 'FIN'], function(value) { ppeStateFilter = value; }),
		selectFilter(_('All types'), ['IPv4', 'IPv6', 'L2B', 'DS-LITE', '6RD'], function(value) { ppeTypeFilter = value; }),
		E('button', { 'type': 'button', 'class': 'cbi-button', 'id': 'ppe-prev', 'title': _('Previous page'),
			'aria-label': _('Previous page'), 'style': 'width:32px;height:32px', 'click': function() {
				ppePage = Math.max(0, ppePage - 1); updatePpeTable(ppeCurrentEntries);
			} }, '\u2039'),
		E('span', { 'id': 'ppe-page', 'style': 'min-width:6em;text-align:center;font-variant-numeric:tabular-nums' }, '1 / 1'),
		E('button', { 'type': 'button', 'class': 'cbi-button', 'id': 'ppe-next', 'title': _('Next page'),
			'aria-label': _('Next page'), 'style': 'width:32px;height:32px', 'click': function() {
				ppePage++; updatePpeTable(ppeCurrentEntries);
			} }, '\u203a')
	]);
	// Accent stripe like every other single element on the page; PPE is the
	// NPU's own flow table, so it takes the same --ai-npu as the port table.
	return E('div', {}, [tools, E('div', {
		'class': 'ai-table-wrap ai-table-wrap--accent',
		'style': '--ai-accent:var(--ai-npu)'
	}, [
		E('table', { 'class': 'ai-table ai-table--mono ai-table--stack', 'id': 'ppe-entries-table' }, [
			E('thead', {}, [
				E('tr', {}, [
					E('th', { 'scope': 'col' }, _('Index')), E('th', { 'scope': 'col' }, _('State')),
					E('th', { 'scope': 'col' }, _('Type')), E('th', { 'scope': 'col' }, 'VLAN'),
					E('th', { 'scope': 'col' }, _('Original Flow')), E('th', { 'scope': 'col' }, _('New Flow')),
					E('th', { 'scope': 'col' }, _('Ethernet')), E('th', { 'scope': 'col' }, _('Packets')),
					E('th', { 'scope': 'col' }, _('Bytes'))
				])
			]),
			E('tbody', {}, ppeRows(entries))
		])
	])]);
}

function updatePpeTable(entries, metadata) {
	ppeCurrentEntries = entries || [];
	if (metadata) ppeCurrentMeta = metadata;
	var filtered = filteredPpeEntries(ppeCurrentEntries);
	var pages = Math.max(1, Math.ceil(filtered.length / PPE_SHOWN_MAX));
	ppePage = Math.max(0, Math.min(ppePage, pages - 1));
	var tbody = document.querySelector('#ppe-entries-table tbody');
	if (!tbody) return;
	tbody.innerHTML = '';
	ppeRows(entries).forEach(function(row) { tbody.appendChild(row); });
	var badge = document.getElementById('ppe-count');
	if (badge) badge.textContent = ppeCountText(entries);
	var page = document.getElementById('ppe-page');
	if (page) page.textContent = (ppePage + 1) + ' / ' + pages;
	var previous = document.getElementById('ppe-prev'), next = document.getElementById('ppe-next');
	if (previous) previous.disabled = ppePage === 0;
	if (next) next.disabled = ppePage + 1 >= pages;
}

/* ── Main view ── */
return view.extend({
	load: function() {
		// Progressive rendering: don't block on RPC calls, let the page render
		// immediately. Stylesheet goes in here (not in render) so it is already
		// applied when the view node is inserted — no width flash, matching the
		// fancontrol views' approach.
		aui.ensureCss();
		return Promise.resolve([]);
	},

	render: function(data) {
		data = data || [];
		aui.ensureCss();
		// The main live path uses named getDashboard fields and bypasses this
		// array. These defaults retain the legacy Promise.all slot order used by
		// the old-backend fallback below. load() currently returns an empty array,
		// but if it ever starts returning legacy data this index map must still
		// match that fallback: status, PPE, token, flow, AP mode, device mode,
		// topology, VLAN, WiFi and frame engine.
		var st = data[0] || {}, ppe = data[1] || {}, ti = data[2] || {};
		var flo = data[3] || { enabled: 0 };
		var apo = data[4] || { enabled: 0 };
		var dm = data[5] || {};
		var topo = data[6] || {};
		var vo = data[7] || { enabled: 0 };
		var fe = data[9] || {};
		var bridgeBlocked = isBridgeOffloadBlocked(dm);
		var entries = Array.isArray(ppe.entries) ? ppe.entries : [];
		var latestPpeEntries = entries;
		var ppeRequestSequence = 0;
		var latestPpeRequest = 0;
		var updatedEl = null;
		// Last cpufreq reason, so the poll can rebuild the control container when
		// the board's cpufreq availability changes. Null forces one rebuild once
		// the live status lands (the controls always exist, so their presence can
		// no longer signal "not rendered yet").
		var prevCpuReason = null;

		function markUpdated() {
			if (updatedEl)
				updatedEl.textContent = _('Updated %s').format(new Date().toLocaleTimeString());
		}

		// The page auto-polls every 5 s; the only "refresh" affordance is the
		// system-level updated-time stamp on the right. Manual Refresh /
		// Pause-Resume buttons were removed — they conflicted with it.
		updatedEl = E('span', { 'class': 'ai-updated' }, '');

		// Width policy: the root carries no width rules of its own (fancontrol
		// style) — the layout inherits the theme's content width, so the
		// late-injected stylesheet never changes geometry (no width flash).
		var view = E('div', { 'class': 'cbi-map airoha-page' }, [
			E('header', { 'class': 'ai-pagehead' }, [
				E('h2', {}, _('Airoha SoC Status')),
		]),

			aui.section({
				title: _('Ethernet Ports'),
				body: E('div', { 'id': 'ethernet-ports' }, renderEthernetPorts(topo))
			}),

		// CPU Frequency
				aui.section({
					title: _('CPU Frequency'),
					body: E('div', {}, [
						E('div', { 'class': 'ai-grid ai-grid--2' }, [
							E('div', { 'id': 'cpu-info-content' }, [ renderCpuInfo(st) ]),
							E('div', { 'id': 'cpu-freq-card' }, [ renderFreqCard(st) ])
						]),
						E('div', { 'class': 'ai-grid', 'style': 'margin-top:var(--ds-sp-2)' }, [
							aui.card({
								name: _('Frequency History'), accent: 'var(--ai-npu)',
								body: E('div', { 'id': 'cpu-history-content' }, [ renderFreqChart(st.cpu_min_freq, st.cpu_max_freq) ])
							})
						])
					])
				}),

			// NPU and hardware offload controls/status.
			aui.section({
				title: _('NPU & Offload Engine'),
				hint: _('Switches here apply the hardware offload settings for this device.'),
				body: E('div', {}, [
					renderSummary(st, ti),
					E('div', { 'id': 'offload-controls', 'style': 'margin-top:var(--ds-sp-3)' },
						renderOffloadControls(topo, vo, flo, apo, bridgeBlocked)),
					E('div', { 'id': 'engine-status' }, renderEngineStatus(st, ppe)),
					E('div', { 'id': 'frame-engine' }, renderFrameEngine(fe, topo))
				])
			}),

			E('div', { 'id': 'wifi-detail' }),

			// PPE Flow Table
			aui.section({
				title: _('PPE Flow Offload Entries'),
				count: ppeCountText(entries), countId: 'ppe-count',
				body: renderPpeTable(entries)
			})
		]);

		// Data fetch + DOM update functions — called immediately and via poll.
		// Individual calls are retained only for compatibility with older backends.
		function _safeCall(promise, fallback) {
			return promise.catch(function() { return fallback; });
		}

		function applyData(st, ppe, ti, flo, apo, dm, topo, vo, wifi, fe, requestSequence, deferPpe) {
			aui.ensureCss();
			st = st || {};
			ppe = ppe || {};
			ti = ti || {};
			flo = flo || { enabled: 0 };
			apo = apo || { enabled: 0 };
			dm = dm || {};
			topo = topo || {};
			vo = vo || { enabled: 0 };
			wifi = wifi || { available: false, bands: [] };
			fe = fe || { available: false };
			if (typeof wifi.has_wifi !== 'boolean' && typeof ti.has_wifi === 'boolean')
				wifi.has_wifi = ti.has_wifi;
			var bridgeBlocked = isBridgeOffloadBlocked(dm);
			// deferred:true means "this round did not ask for PPE" (the flow
			// table is fetched on a slower cadence - see fetchDashboardData).
			// Leave both the table and latestPpeEntries alone: overwriting them
			// would flash an empty flow table every 5 s and defeat the point of
			// keeping the last real snapshot.
			if (deferPpe !== true && requestSequence > latestPpeRequest) {
				latestPpeRequest = requestSequence;
				latestPpeEntries = Array.isArray(ppe.entries) ? ppe.entries : [];
				updatePpeTable(latestPpeEntries, ppe);
			}
			updateSummary(st, ti);

			// CPU info — always re-render (just text rows, no user interaction)
			var ci = document.getElementById('cpu-info-content');
			if (ci) { ci.innerHTML = ''; ci.appendChild(renderCpuInfo(st)); }

			// History chart — append one sample per poll and re-render.
			pushFreqSample(freqState(st).freq);
			var hc = document.getElementById('cpu-history-content');
			if (hc) { hc.innerHTML = ''; hc.appendChild(renderFreqChart(st.cpu_min_freq, st.cpu_max_freq, hc.clientWidth)); }

			// Control settings — the selects now always exist, so their presence can
			// no longer signal "not rendered yet". Rebuild the container whenever the
			// board's cpufreq availability/reason changes (cpufreq appearing or
			// disappearing between polls); otherwise update the live values in place,
			// unless the user has unsaved changes.
			var cpuReason = cpufreqReason(st);
			var gs = document.getElementById('cpu-governor-select');
			if (!gs || cpuReason !== prevCpuReason) {
				var cc = document.getElementById('cpu-control-content');
				if (cc) { cc.innerHTML = ''; cc.appendChild(renderControlSettings(st)); }
				prevCpuReason = cpuReason;
			} else if (!cpuSettingsDirty) {
				if (!gs.matches(':focus')) gs.value = st.cpu_governor || '';
				var fsSel = document.getElementById('cpu-maxfreq-select');
				if (fsSel && !fsSel.matches(':focus')) {
					var target = (st.cpu_max_freq || 0).toString();
					var hasOpt = Array.from(fsSel.options).some(function(o) { return o.value === target; });
					if (hasOpt) {
						fsSel.value = target;
					} else {
						// Option list is stale (live value not selectable) — rebuild
						// so renderMaxFreqSelect can inject the current kernel value.
						var cc = document.getElementById('cpu-control-content');
						if (cc) { cc.innerHTML = ''; cc.appendChild(renderControlSettings(st)); }
					}
				}
			}

			updateOffloadControl('vlan-offload-select', 'vlan-offload-badge', 'vlan-offload-row', vo.enabled, bridgeBlocked);
			updateOffloadControl('flow-offload-select', 'flow-offload-badge', 'flow-offload-row', flo.enabled, false);
			updateOffloadControl('apmode-offload-select', 'apmode-offload-badge', 'apmode-offload-row', apo.enabled, bridgeBlocked);

			var controls = document.getElementById('offload-controls');
			var controlBoard = String(topo.compatible || '') + ':' + (vo.supported !== false && apo.supported !== false);
			if (controls && topo.compatible && controls.getAttribute('data-board') !== controlBoard) {
				controls.replaceChildren(renderOffloadControls(topo, vo, flo, apo, bridgeBlocked));
				controls.setAttribute('data-board', controlBoard);
			}

			var engineEl = document.getElementById('engine-status');
			if (engineEl) engineEl.replaceChildren(renderEngineStatus(st, ppe));
			var feEl = document.getElementById('frame-engine');
			if (feEl) feEl.replaceChildren(renderFrameEngine(fe, topo));
			var epEl = document.getElementById('ethernet-ports');
			if (epEl) { epEl.innerHTML = ''; epEl.appendChild(renderEthernetPorts(topo)); }
			var wifiEl = document.getElementById('wifi-detail');
			if (wifiEl) {
				wifiEl.replaceChildren();
				var wifiDetails = renderWifiDetails(wifi, ppe, ti, st);
				if (wifiDetails) wifiEl.appendChild(wifiDetails);
			}

			markUpdated();
		}

		function fetchLegacyData() {
			return Promise.all([
				_safeCall(callNpuStatus(), {}),
				_safeCall(callPpeEntries(), { available: false, entries: [] }),
				_safeCall(callTokenInfo(), {}),
				_safeCall(callGetFlowOffload(), { enabled: 0 }),
				_safeCall(callGetApModeOffload(), { enabled: 0 }),
				_safeCall(callGetDeviceMode(), { bridge_offload_blocked: false }),
				_safeCall(callGetTopology(), {}),
				_safeCall(callGetVlanOffload(), { enabled: 0 }),
				_safeCall(callGetWifiStats(), { available: false, bands: [] }),
				_safeCall(callFrameEngine(), { available: false, reason: 'request_failed' })
			]).then(function(d) {
				return {
					st: d[0] || {}, ppe: d[1] || {}, ti: d[2] || {},
					flo: d[3] || {}, apo: d[4] || {}, dm: d[5] || {},
					topo: d[6] || {}, vo: d[7] || {}, wifi: d[8] || {}, fe: d[9] || {}
				};
			});
		}

		// PPE is by far the most expensive probe on the board (a 1024-entry
		// debugfs snapshot + awk, ~2 s on the PON ONU), so `ppe:0` tells the
		// backend to skip it entirely. The reply then carries deferred:true,
		// which applyData uses to keep the previous flow table on screen.
		function fetchDashboardData(includePpe) {
			var deferred = { available: false, entries: [], total: 0, deferred: true };
			return callDashboard(includePpe ? 1 : 0).then(function(dashboard) {
				// No getDashboard: an older backend. It always returns the whole
				// page - including PPE - in one go, so the caller's PPE cadence
				// cannot be honoured; fall back to the 10 individual calls and
				// let them behave exactly as they did before.
				if (!dashboard) return fetchLegacyData();
				var ppe = dashboard.ppe || {};
				return {
					st: dashboard.status || {},
					ppe: includePpe ? ppe : deferred,
					ti: dashboard.token || {},
					flo: dashboard.flow_offload || {},
					apo: dashboard.apmode_offload || {},
					dm: dashboard.device_mode || {},
					topo: dashboard.topology || {},
					vo: dashboard.vlan_offload || {},
					wifi: dashboard.wifi || {},
					fe: dashboard.frame_engine || {},
					deferPpe: !includePpe
				};
			}, function() {
				return fetchLegacyData();
			});
		}

		function runFetch(includePpe) {
			var requestSequence = ++ppeRequestSequence;
			return fetchDashboardData(includePpe).then(function(data) {
				applyData(data.st, data.ppe, data.ti, data.flo, data.apo, data.dm,
					data.topo, data.vo, data.wifi, data.fe, requestSequence, data.deferPpe);
			}).catch(function(err) {
				console.error('[airoha_npu] fetchData error:', err);
			});
		}

		// Poll cadence: the flow table does not need 5 s resolution, and it is
		// the single most expensive probe on the board. Every 4th cycle (i.e.
		// about every 20 s) asks for PPE; the three cycles in between skip it,
		// which is what makes the periodic poll cheap.
		var PPE_POLL_EVERY = 4;
		var pollCount = 0;

		function pollFetch() {
			pollCount++;
			return runFetch(pollCount % PPE_POLL_EVERY === 1);
		}

		// First paint is deliberately two requests, in order: the fast half
		// (ports, CPU, NPU, frame engine - well under a second) renders as soon
		// as it lands, then the flow table is fetched separately. Firing both at
		// once would just put the expensive call back on the critical path.
		runFetch(false).then(function() {
			return runFetch(true);
		});
		// Poll for periodic updates
		poll.add(pollFetch, 5);

		return view;
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
