/* Render-level smoke test for the WiFi section of the Airoha NPU status view.
 *
 * The view is a LuCI module, so its WiFi part is cut out of status.js and
 * evaluated with minimal stubs for _() and E(). Each case below is a WiFi
 * payload as the RPC backend returns it; the renderer must print a card only
 * when there is something to say, and must never invent a value.
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

function show(label, wf) {
	const v = mod.renderWifi(wf);
	console.log('\n=== ' + label + ' ===');
	if (!v) { console.log('  (WiFi section not rendered at all)'); return; }
	const out = [];
	v.kids.forEach(k => { if (k) dumpNode(k, '  ', out); });
	console.log(out.join('\n'));
}

/* 1 - what the FiberHome HG5585F really returns with no client associated */
show('MT7916 real payload (no clients, both bands up)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 52.0, "temp_crit_c": 110, "bands": [
		{ "band": 1, "freq_mhz": 5180, "channel": 36, "width_mhz": 80, "up": true, "netdev": "phy1-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 10, "noise_dbm": -92 },
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 41, "noise_dbm": -91 }
	]
});

/* 2 - associated clients: traffic / retry / signal rows appear */
show('three clients (traffic, retries, signal)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 61.7, "temp_crit_c": 110, "bands": [
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "MyHome", "count": 3, "tx_packets": 18422, "tx_retries": 512, "tx_failed": 7, "rx_bytes": 2411724, "tx_bytes": 18743296, "signal_dbm": -58, "busy_pct": 47, "noise_dbm": -91 },
		{ "band": 1, "freq_mhz": 5180, "channel": 36, "width_mhz": 80, "up": true, "netdev": "phy1-ap0", "ssid": "MyHome", "count": 2, "tx_packets": 91234, "tx_retries": 88, "tx_failed": 0, "rx_bytes": 88473600, "tx_bytes": 412188672, "signal_dbm": -44, "busy_pct": 12, "noise_dbm": -93 }
	]
});

/* 3 - a disabled radio has no channel: no card, no empty card */
show('5 GHz disabled (only one card expected)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 48.2, "temp_crit_c": 110, "bands": [
		{ "band": 0, "freq_mhz": 2412, "channel": 6, "width_mhz": 40, "up": true, "netdev": "phy0-ap0", "ssid": "ImmortalWrt", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": 8, "noise_dbm": -95 },
		{ "band": 1, "freq_mhz": 0, "channel": 0, "width_mhz": 0, "up": false, "netdev": "phy1-ap0", "ssid": "", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": null, "noise_dbm": null }
	]
});

/* 4 - a board without wireless (ZN504XG-D) */
show('board without WiFi (504)', {
	"wifi_present": false, "npu_offload": false, "chip": "", "temp_c": null, "temp_crit_c": null, "bands": []
});

/* 5 - kernel without survey/hwmon data: rows are omitted, not zeroed */
show('no survey and no temperature', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": null, "temp_crit_c": null, "bands": [
		{ "band": 1, "freq_mhz": 5745, "channel": 149, "width_mhz": 80, "up": true, "netdev": "phy1-ap0", "ssid": "X", "count": 0, "tx_packets": 0, "tx_retries": 0, "tx_failed": 0, "rx_bytes": 0, "tx_bytes": 0, "signal_dbm": null, "busy_pct": null, "noise_dbm": null }
	]
});

/* 6 - two AP interfaces on one band must fold into a single card */
show('multi-SSID on one band (one card, both SSIDs)', {
	"wifi_present": true, "npu_offload": false, "chip": "mt7915e", "temp_c": 55.0, "temp_crit_c": 110, "bands": [
		{ "band": 0, "freq_mhz": 2412, "channel": 1, "width_mhz": 20, "up": true, "netdev": "phy0-ap0", "ssid": "Home, Home-Guest", "count": 4, "tx_packets": 500, "tx_retries": 10, "tx_failed": 0, "rx_bytes": 1024, "tx_bytes": 2048, "signal_dbm": -66, "busy_pct": 22, "noise_dbm": -90 }
	]
});

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
});

console.log('\nfmtBytes: ' + [0, 999, 2048, 1048576, 412188672].map(mod.fmtBytes).join(' | '));
