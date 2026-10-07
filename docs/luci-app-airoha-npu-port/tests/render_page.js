/* Whole-page render test for the Airoha NPU status view.
 *
 * The view source is evaluated with the smallest possible LuCI stubs and then
 * render() is called with a real captured payload, so this shows exactly what
 * the browser would build - including whether the GDM1/GDM2/GDM4 cards make it
 * into the DOM. Payloads live in tests/fixtures/<device>.json and are captured
 * from the running devices with `ubus call luci.airoha_npu <method>`.
 *
 * Usage:
 *   node render_page.js                 # every fixture
 *   node render_page.js 5855f           # one fixture
 */
'use strict';
const fs = require('fs');
const path = require('path');

const pkg = path.resolve(__dirname, '../../../package/luci-app-airoha-npu');
const src = fs.readFileSync(path.join(pkg, 'htdocs/luci-static/resources/view/airoha_npu/status.js'), 'utf8');

/* ── minimal LuCI stubs ── */
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
	/* Real _() resolves to a translated string; here it is an object carrying
	 * the msgid, so unwrap it the way E() would. */
	const text = kids.map(k => (k && typeof k === 'object') ? (k.text !== undefined ? k.text : String(k)) : String(k)).join('');
	return { tag, attrs: attrs || {}, kids, text };
}
function makeEl(id) {
	const el = {
		id, style: {}, textContent: '', className: '', children: [], rows: [],
		appendChild(n) { this.children.push(n); if (n && n.tag === 'tr') this.rows.push(n); },
		deleteRow(i) { this.rows.splice(i, 1); },
		matches() { return false; }, classList: { add() {} },
		get firstChild() { return this.children[0] || null; }
	};
	Object.defineProperty(el, 'innerHTML', {
		get() { return ''; },
		set(v) { if (v === '') { this.children.length = 0; this.rows.length = 0; } }
	});
	return el;
}
const elements = {};
const documentStub = {
	getElementById: id => (elements[id] = elements[id] || makeEl(id)),
	querySelector: () => null, querySelectorAll: () => [],
	createElement: () => makeEl(), head: makeEl(), body: makeEl()
};
const windowStub = { getComputedStyle: () => ({ backgroundColor: 'rgb(255,255,255)' }), console };
let fixture = {};
const rpcStub = { declare: o => (() => Promise.resolve(fixture[o.method] || {})) };
const pollStub = { fn: null, add(fn) { this.fn = fn; } };
const uiStub = { addNotification() {} };
const LStub = { bind: (f, c) => f.bind(c), resolve: v => Promise.resolve(v) };
const viewStub = { extend: o => o };

/* The file ends with `return view.extend({...})`, so a function body works. */
const factory = new Function('require', '_', 'E', 'rpc', 'poll', 'ui', 'view', 'L', 'document', 'window', 'confirm',
	src + '\n; return view;');
const view = factory(() => ({}), _, E, rpcStub, pollStub, uiStub, viewStub, LStub, documentStub, windowStub, () => true);

/* ── helpers ── */
function countCards(node, re) {
	let n = 0;
	(function walk(x) {
		if (!x) return;
		if (Array.isArray(x)) return x.forEach(walk);
		if (typeof x !== 'object') return;
		if (String((x.attrs || {}).class || '').includes('soc-card') && (!re || re.test(x.text))) n++;
		if (x.children) x.children.forEach(walk);
		if (x.kids) x.kids.forEach(walk);
	})(node);
	return n;
}
function outline(node, ind, out) {
	if (node == null) return;
	if (Array.isArray(node)) return node.forEach(k => outline(k, ind, out));
	if (typeof node !== 'object') return;
	const cls = String((node.attrs || {}).class || '');
	if (node.tag === 'h2' || node.tag === 'h3' || node.tag === 'h4') { out.push(ind + '## ' + node.text); return; }
	if (cls.includes('soc-card')) { out.push(ind + '[card] ' + node.text.slice(0, 64)); return; }
	if (cls.includes('soc-pse-cell')) { out.push(ind + '[pse] ' + node.text.slice(0, 24)); return; }
	if (cls.includes('soc-warn')) { out.push(ind + '!! warn: ' + node.text.slice(0, 60)); return; }
	if (node.children && node.children.length) return node.children.forEach(k => outline(k, ind, out));
	if (node.kids && node.kids.length) return node.kids.forEach(k => outline(k, ind + '  ', out));
	if (node.text) out.push(ind + node.text.slice(0, 70));
}

/* ── run ── */
const dir = path.join(__dirname, 'fixtures');
const only = process.argv[2];
const files = fs.readdirSync(dir).filter(f => f.endsWith('.json') && (!only || f.includes(only)));
let failures = 0;

function countCards(node, re) {
	let n = 0;
	(function walk(x) {
		if (!x) return;
		if (Array.isArray(x)) return x.forEach(walk);
		if (typeof x !== 'object') return;
		if (String((x.attrs || {}).class || '').includes('soc-card') && (!re || re.test(x.text))) n++;
		if (x.children) x.children.forEach(walk);
		if (x.kids) x.kids.forEach(walk);
	})(node);
	return n;
}
function countClass(node, cls) {
	let n = 0;
	(function walk(x) {
		if (!x) return;
		if (Array.isArray(x)) return x.forEach(walk);
		if (typeof x !== 'object') return;
		if (String((x.attrs || {}).class || '').includes(cls)) n++;
		if (x.children) x.children.forEach(walk);
		if (x.kids) x.kids.forEach(walk);
	})(node);
	return n;
}
function outline(node, ind, out) {
	if (node == null) return;
	if (Array.isArray(node)) return node.forEach(k => outline(k, ind, out));
	if (typeof node !== 'object') return;
	const cls = String((node.attrs || {}).class || '');
	if (node.tag === 'h2' || node.tag === 'h3' || node.tag === 'h4') { out.push(ind + '## ' + node.text); return; }
	if (cls.includes('soc-card')) { out.push(ind + '[card] ' + node.text.slice(0, 64)); return; }
	if (cls.includes('soc-pse-cell')) { out.push(ind + '[pse] ' + node.text.slice(0, 24)); return; }
	if (cls.includes('soc-warn')) { out.push(ind + '!! warn: ' + node.text.slice(0, 70)); return; }
	if (node.children && node.children.length) return node.children.forEach(k => outline(k, ind, out));
	if (node.kids && node.kids.length) return node.kids.forEach(k => outline(k, ind + '  ', out));
	if (node.text) out.push(ind + node.text.slice(0, 70));
}
const pseCells = tree => countClass(tree, 'soc-pse-cell');

(async function main() {
	for (const f of files) {
		const fixtureBase = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
		Object.keys(elements).forEach(k => delete elements[k]);

		console.log('\n############ ' + f + '  (' + (fixtureBase.host || '?') + ') ############');
		fixture = fixtureBase;

		let tree;
		try {
			tree = view.render([fixture.getStatus, fixture.getPpeEntries, fixture.getWifiInfo, fixture.getFrameEngine]);
		} catch (e) {
			console.log('  !! render() THREW: ' + e.message);
			console.log(e.stack.split('\n').slice(1, 4).join('\n'));
			failures++; continue;
		}
		const out = [];
		outline(tree, '  ', out);
		console.log(out.join('\n'));

		const gdm = countCards(tree, /GDM[124]/);
		console.log('  -> 首次渲染: GDM 卡 ' + gdm + ' 张, PSE 端口格 ' + pseCells(tree) + ' 个');
		if (gdm !== 3) { console.log('  !! 期望 3 张 GDM 卡（GDM1/GDM2/GDM4）'); failures++; }

		if (!pollStub.fn) { console.log('  !! 视图没有注册 poll 回调'); failures++; continue; }
		await pollStub.fn();
		const feAfter = countCards(elements['fe-container'].children, /GDM[124]/);
		const wc = elements['wifi-container'];
		const tb = elements['ppe-entries-table'];
		console.log('  -> 轮询刷新后: #fe-container GDM 卡 ' + feAfter + ' 张, #wifi-container 子节点 '
			+ (wc ? wc.children.length : 'n/a') + ', PPE 表行 ' + (tb ? tb.rows.length : 'n/a'));
		if (feAfter !== 3) { console.log('  !! 轮询刷新后 GDM 卡丢失'); failures++; }

		/* 降级：RPC 返回空载荷时，必须给出可见原因而不是静默空白 */
		fixture = Object.assign({}, fixtureBase, { getFrameEngine: {} });
		await pollStub.fn();
		const feEmpty = elements['fe-container'].children;
		const warn = countClass(feEmpty, 'soc-warn');
		console.log('  -> 降级（getFrameEngine 返回 {}）: GDM 卡 ' + countCards(feEmpty, /GDM[124]/)
			+ ' 张, 提示条 ' + warn + ' 个' + (warn === 1 ? '  ✅ 说明了原因' : '  !! 静默空白'));
		if (warn !== 1) failures++;
	}
	console.log('\n' + (failures ? '❌ 失败项: ' + failures : '✅ 全部通过'));
	process.exit(failures ? 1 : 0);
})();
