/* Render-level smoke test for the WiFi part of the Airoha NPU status view.
 *
 * The view is a LuCI module, so its WiFi part is cut out of status.js and
 * evaluated with minimal stubs for _() and E(). Each case below is a WiFi
 * payload as the RPC backend returns it; the renderer must print a card only
 * when there is something to say, and must never invent a value.
 *
 * Since the WiFi content moved into the CDM4 (P7 WiFi DMA) card of the Frame
 * Engine diagram, the entry point is that card: renderWifi(wf, ports, devmemOk)
 * returns it, or null on a board whose backend found no wireless.
 *
 * Run from the package directory:
 *   node ../../docs/luci-app-airoha-npu-port/tests/smoke_wifi.js
 */
'use strict';
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '../../../package/luci-app-airoha-npu');
const src = fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/airoha_npu/status.js'), 'utf8');
const cut = src.slice(src.indexOf('/* \u2500\u2500 WiFi \u2500\u2500'), src.indexOf('/* \u2500\u2500 Frame Engine'));

function _(s) {
	return { format: function() { let a = arguments, i = 0; return s.replace(/%s/g, () => a[i++]); }, toString() { return s; } };
}
function E(tag, attrs, children) {
	if (children === undefined) { children = attrs; attrs = {}; }
	const kids = [];
	(function push(c) {
		(Array.isArray(c) ? c : [c]).forEach(x => {
			if (x === null || x === undefined || x === false) return;
			if (Array.isArray(x)) push(x); else kids.push(x);
		});
	})(children);
	/* Real _() resolves to a translated string; here it is an object that
	 * carries the msgid, so unwrap it the same way E() would. */
	const text = kids.map(k => typeof k === 'object' ? (k.text !== undefined ? k.text : String(k)) : String(k)).join('');
	return { tag, attrs: attrs || {}, kids, text };
}

const mod = new Function('_', 'E', 'bandNames', 'bandColors',
	'\n return (function(){' + cut + '\nreturn { renderWifi, renderBandCard, fmtBytes };})();')(_, E);

const pad = (s, n) => String(s).padEnd(n);

function dumpCard(n, ind, out) {
	const titleKids = n.kids[0].kids;
	out.push(ind + '\u250c\u2500 ' + (titleKids[0] ? titleKids[0].text : '') + (titleKids[1] ? '   [' + titleKids[1].text + ']' : ''));
	const grid = n.kids.find(k => k && k.tag === 'div' && String((k.attrs || {}).style || '').includes('grid'));
	if (grid) for (let i = 0; i < grid.kids.length; i += 2) {
		const lab = grid.kids[i], val = grid.kids[i + 1];
		const m = String(val && val.attrs ? val.attrs.style || '' : '').match(/color:(#[0-9a-fA-F]+)/);
		out.push(ind + '\u2502   ' + pad(lab.text, 18) + ' = ' + (val ? val.text : '') + (m ? '   <' + m[1] + '>' : ''));
	}
	out.push(ind + '\u2514\u2500');
}

function dumpNode(n, ind, out) {
	const cls = String((n.attrs || {}).class || '');
	if (cls.includes('soc-card')) return dumpCard(n, ind, out);
	if (n.tag === 'h3') { out.push(ind + '\u3010\u6807\u9898\u3011 ' + n.kids.map(k => k ? k.text : '').filter(Boolean).join('   | badge: ')); return; }
	if (cls.includes('cbi-section') || cls.includes('soc-gdm-grid')) {
		n.kids.forEach(k => { if (k) dumpNode(k, ind, out); });
		return;
	}
	out.push(ind + n.text);
}

/* The CDM4 card: header row (name + badge + chip temperature), the path line,
 * the optional P7 IQ/OQ line and the band grid inside. */
function show(label, wf, ports, devmemOk) {
	const v = mod.renderWifi(wf, ports, devmemOk);
	console.log('\n=== ' + label + ' ===');
	if (!v) { console.log('  (no CDM4 card: this board has no wireless)'); return null; }

	const out = [];
	out.push('  \u250c\u2500 ' + v.kids[0].text.replace(/\s+/g, ' ').trim());
	out.push('  \u2502  ' + v.kids[1].text);
	v.kids.slice(2).forEach(k => {
		if (!k) return;
		if (String((k.attrs || {}).class || '').includes('soc-cdm4-band-grid')) {
			const bands = k.kids.filter(Boolean);
			out.push('  \u2502  \u9891\u6bb5\u5361 ' + bands.length + ' \u5f20');
			bands.forEach(b => dumpCard(b, '  \u2502    ', out));
		} else {
			out.push('  \u2502  ' + k.text);
		}
	});
	out.push('  \u2514\u2500');
	console.log(out.join('\n'));
	return v;
}

/* Assertion helper: the smoke run must fail loudly, not just print. */
let failures = 0;
function check(ok, what) {
	console.log('  -> ' + (ok ? '\u2705 ' : '!! ') + what);
	if (!ok) failures++;
}
function bandsIn(card) {
	const grid = card.kids.filter(k => k && String((k.attrs || {}).class || '').includes('soc-cdm4-band-grid'))[0];
	return grid ? grid.kids.filter(Boolean) : [];
}

/* 1 - what the FiberHome HG5585F really returns with no client associated */
const c1 = show('MT7916 real payload (no clients, both bands up)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 52.0, "temp_crit_c": 110, "bands": [
		{ "band": 1, "freq_mhz": 5180, "channel": 36, "width_mhz": 80, "up": true, "netdev": "phy1-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 10, "noise_dbm": -92 },
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 41, "noise_dbm": -91 }
	]
}, [{ "port": 7, "queues": 10, "iq": 2, "oq": 0, "drops": 0 }], true);
check(c1 && bandsIn(c1).length === 2, '两个频段两张卡');
check(c1 && /2\.4 GHz/.test(c1.text) && /5 GHz/.test(c1.text), '卡内同时有 2.4G 与 5G');
check(c1 && /IQ 2/.test(c1.text) && /OQ 0/.test(c1.text), '有 /dev/mem 时显示 P7 的 IQ/OQ');

/* 1b - the same payload without the P7 queue data: the line is left out, not
 * printed as a pair of zeros. */
const c1b = show('same payload, no /dev/mem (no IQ/OQ line)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 52.0, "temp_crit_c": 110, "bands": [
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 41, "noise_dbm": -91 }
	]
}, [{ "port": 7, "queues": 10, "iq": 0, "oq": 0, "drops": 0 }], false);
check(c1b && !/IQ /.test(c1b.text), '无 /dev/mem 时整行不画（不报假的 0）');

/* 1c - a 6 GHz radio (band index 2) has no card on this page. */
const c1c = show('6 GHz radio present (must not be drawn)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 52.0, "temp_crit_c": 110, "bands": [
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 41, "noise_dbm": -91 },
		{ "band": 2, "freq_mhz": 6115, "channel": 33, "width_mhz": 160, "up": true, "netdev": "phy2-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 4, "noise_dbm": -95 }
	]
}, null, false);
check(c1c && bandsIn(c1c).length === 1, 'band 2 不生成卡片');
check(c1c && !/6 GHz/.test(c1c.text), '整张卡里没有 6 GHz 字样');

/* 2 - associated clients: traffic / retry / signal rows appear */
show('three clients (traffic, retries, signal)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 61.7, "temp_crit_c": 110, "bands": [
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "MyHome", "count": 3, "tx_packets": 18422, "tx_retries": 512, "tx_failed": 7, "rx_bytes": 2411724, "tx_bytes": 18743296, "signal_dbm": -58, "busy_pct": 47, "noise_dbm": -91 },
		{ "band": 1, "freq_mhz": 5180, "channel": 36, "width_mhz": 80, "up": true, "netdev": "phy1-ap0", "ssid": "MyHome", "count": 2, "tx_packets": 91234, "tx_retries": 88, "tx_failed": 0, "rx_bytes": 88473600, "tx_bytes": 412188672, "signal_dbm": -44, "busy_pct": 12, "noise_dbm": -93 }
	]
});

/* 3 - a disabled radio has no channel: no card, no empty card */
const c3 = show('5 GHz disabled (only one card expected)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 48.2, "temp_crit_c": 110, "bands": [
		{ "band": 0, "freq_mhz": 2412, "channel": 6, "width_mhz": 40, "up": true, "netdev": "phy0-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 8, "noise_dbm": -95 },
		{ "band": 1, "freq_mhz": 0, "channel": 0, "width_mhz": 0, "up": false, "netdev": "phy1-ap0", "ssid": "", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": null, "noise_dbm": null }
	]
}, null, false);
check(c3 && bandsIn(c3).length === 1, '关掉的射频不画卡');

/* 4 - a board without wireless (ZN504XG-D): no CDM4 card at all, so the
 * Frame Engine diagram shows CDM1/CDM2 only. */
const c4 = show('board without WiFi (504)', {
	"wifi_present": false, "npu_offload": false, "chip": "", "temp_c": null, "temp_crit_c": null, "bands": []
}, null, true);
check(c4 === null, '无无线机型整张 CDM4 卡不渲染');

/* 5 - kernel without survey/hwmon data: rows are omitted, not zeroed */
show('no survey and no temperature', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": null, "temp_crit_c": null, "bands": [
		{ "band": 1, "freq_mhz": 5745, "channel": 149, "width_mhz": 80, "up": true, "netdev": "phy1-ap0", "ssid": "X", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": null, "noise_dbm": null }
	]
}, null, true);

/* 6 - two AP interfaces on one band must fold into a single card */
show('multi-SSID on one band (one card, both SSIDs)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 55.0, "temp_crit_c": 110, "bands": [
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "Home, Home-Guest", "count": 4, "tx_packets": 500, "tx_retries": 10, "tx_failed": 0, "rx_bytes": 1024, "tx_bytes": 2048, "signal_dbm": -66, "busy_pct": 22, "noise_dbm": -90 }
	]
}, null, true);

/* 7 - live capture: a phone associated to the 5 GHz radio of the HG5585F.
 * The raw iw output for this client was:
 *   rx bytes: 82702   tx bytes: 22616   tx packets: 229
 *   tx retries: 2     tx failed: 2      signal: -33 [-52, -33, -51] dBm
 * so this payload also documents what the station parser must produce. */
show('live capture: one phone on 5 GHz', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 56, "temp_crit_c": 110, "bands": [
		{ "band": 1, "freq_mhz": 5180, "channel": 36, "width_mhz": 80, "up": true, "netdev": "phy1-ap0", "ssid": "ImmortalWrt", "count": 1, "tx_packets": 229, "tx_retries": 2, "tx_failed": 2, "rx_bytes": 82702, "tx_bytes": 22616, "signal_dbm": -33, "busy_pct": 10, "noise_dbm": -91 },
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 41, "noise_dbm": -92 }
	]
}, null, true);

/* 8 - every radio disabled: the card still exists (the board has wireless
 * hardware) and says so instead of rendering an empty grid. */
const c8 = show('all radios disabled', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 50, "temp_crit_c": 110, "bands": []
}, null, true);
check(c8 !== null && bandsIn(c8).length === 0, '有无线但无射频 up：卡片保留，不画空频段卡');

console.log('\nfmtBytes: ' + [0, 999, 2048, 1048576, 412188672].map(mod.fmtBytes).join(' | '));
console.log(failures ? '\n\u274c \u5931\u8d25\u9879: ' + failures : '\n\u2705 \u5168\u90e8\u901a\u8fc7');
process.exit(failures ? 1 : 0);
