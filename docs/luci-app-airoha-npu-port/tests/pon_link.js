/* Unit test for the PON port link-state decision (ponLink in status.js).
 *
 * The whole-page test needs the LuCI module loader; this one pulls the real
 * ponLink function out of the view source and drives it with the payloads the
 * backend can produce, so both GPON and EPON lines are covered:
 *
 *   GPON/XGS-PON  onu_state = "O1".."O7"      (O5 = registered)
 *   EPON          onu_state = ""              (driver says "not-applicable")
 *                 mpcp_state = 0..5           (4 = registered LLID)
 *
 * Usage:
 *   node pon_link.js
 */
'use strict';
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(
	path.resolve(__dirname, '../../../package/luci-app-airoha-npu/htdocs/luci-static/resources/view/airoha_npu/status.js'),
	'utf8');

/* Extract `function ponLink(p) { ... }` by brace matching, so the test always
 * exercises the shipped code rather than a copy that can drift. */
function extract(name, text) {
	const start = text.indexOf('function ' + name + '(');
	if (start < 0) throw new Error('function ' + name + ' not found');
	let depth = 0, i = text.indexOf('{', start);
	for (; i < text.length; i++) {
		if (text[i] === '{') depth++;
		else if (text[i] === '}' && --depth === 0) return text.slice(start, i + 1);
	}
	throw new Error('unbalanced braces in ' + name);
}

/* ponLink returns translated msgids; unwrap them to their English text. */
function _(s) { return s; }

/* ponLink closes over `topo`; rebuild it per case with that scope. */
function link(pon, port) {
	const fn = new Function('_', 'topo', extract('ponLink', src) + '\nreturn ponLink;')(_, { pon: pon });
	return fn(port);
}

const PON_PORT = { role: 'pon', netdev: 'pon0' };
const GPON = { present: 1, los: 0, onu_state: 'O5', netdev: 'pon0', mpcp_state: null };
const EPON = { present: 1, los: 0, onu_state: '', netdev: 'pon0', mpcp_state: 4 };

let failures = 0;
function check(what, got, want) {
	const ok = got === want;
	console.log((ok ? '  ✅ ' : '  !! ') + what + (ok ? '' : '  → got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)));
	if (!ok) failures++;
}

console.log('GPON / XGS-PON (O-codes)');
check('O5 = link up', link(GPON, PON_PORT).text, 'Link up (O5)');
check('O5 is healthy', link(GPON, PON_PORT).ok, true);
check('O2 = link down', link(Object.assign({}, GPON, { onu_state: 'O2' }), PON_PORT).text, 'Link down (O2)');
check('LOS wins over O5', link(Object.assign({}, GPON, { los: 1 }), PON_PORT).text, 'Link down (LOS)');

console.log('EPON (802.3ah MPCP state)');
check('state 4 = link up', link(EPON, PON_PORT).text, 'Link up (REGISTERED)');
check('state 4 is healthy', link(EPON, PON_PORT).ok, true);
check('state 3 = link down', link(Object.assign({}, EPON, { mpcp_state: 3 }), PON_PORT).text, 'Link down (REGISTER_PENDING)');
check('state 5 = link down (DENIED)', link(Object.assign({}, EPON, { mpcp_state: 5 }), PON_PORT).text, 'Link down (DENIED)');
check('state 0 = link down (WAIT)', link(Object.assign({}, EPON, { mpcp_state: 0 }), PON_PORT).text, 'Link down (WAIT)');
check('LOS wins over MPCP', link(Object.assign({}, EPON, { los: 1 }), PON_PORT).text, 'Link down (LOS)');
check('string state (defensive)', link(Object.assign({}, EPON, { mpcp_state: '4' }), PON_PORT).text, 'Link up (REGISTERED)');

console.log('Fallbacks / scope');
check('EPON without mpcp_state (old backend) stays unknown', link(Object.assign({}, EPON, { mpcp_state: null }), PON_PORT).text, 'Unknown');
check('EPON with missing key stays unknown', link({ present: 1, los: 0, onu_state: '', netdev: 'pon0' }, PON_PORT).text, 'Unknown');
check('no PON data', link(null, PON_PORT), null);
check('other port is not PON', link(EPON, { role: 'lan', netdev: 'lan1' }), null);

/* The Chinese UI must read 已注册, not the raw protocol token. */
const po = fs.readFileSync(
	path.resolve(__dirname, '../../../package/luci-app-airoha-npu/po/zh_Hans/luci-app-airoha-npu.po'), 'utf8');
check('zh_Hans translates REGISTERED', /msgid "REGISTERED"\nmsgstr "已注册"/.test(po), true);

console.log('\n' + (failures ? '❌ failures: ' + failures : '✅ all passed'));
process.exit(failures ? 1 : 0);
