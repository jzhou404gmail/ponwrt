'use strict';
'require baseclass';

/* ---------------------------------------------------------------------------
 * Shared design tokens for the mesh-conf views.
 *
 * The canonical values live in docs/design-luci-vlan-ui.md and are mirrored in
 * the Switch view's stylesheet (view/network/switch-vlan.css, see
 * patches/feeds/luci/.../102-align-switch-vlan-design-tokens.patch) so that
 * pages editing the same model read as one product.
 *
 * `tokens` is the body of the `.meshconf-page{ ... }` rule: the surfaces, text
 * and borders map onto the LuCI theme variables instead of being hardcoded, so
 * a theme that really exposes them keeps ownership of its light/dark palette
 * - and the fixed palette the page used to carry (plus a body-background
 * luminance probe) no longer makes it ignore the theme.
 *
 * The catch is that only some themes expose them. The reference boards run
 * Argon, whose cascade.css defines NONE of `--background-color-high` /
 * `--background-color-medium` / `--border-color-low` / `--border-color-medium` /
 * `--text-color-high` / `--text-color-low` / `--primary-color-high` (its :root
 * carries the Bootstrap 4 palette instead: --primary, --dark-primary, --white,
 * --background-color, --gray-dark, --light, ...), so on Argon every lookup
 * misses and the hardcoded fallbacks below are what actually apply. That is
 * why the dark block has to restate the surfaces, text and border as well:
 * without it a dark page renders white panels with near-black text.
 *
 * `dark` is the dark re-tuning. Its selector is `:root .meshconf-page`, not
 * `:root`: the values are declared on the page root by the `.meshconf-page`
 * block above, and a custom property set on an element always beats the one it
 * would inherit from an ancestor - so a bare `:root{...}` block is dead code
 * here, whatever its position in the stylesheet. The extra specificity of the
 * descendant selector is what lets this re-tuning win.
 *
 * Concrete dark values are Argon's own dark palette, so the page reads as part
 * of the theme: page canvas #1e1e1e (dark.css `body`), elevated surface #252526
 * (what dark.css gives `table th` and the zebra rows), body text #cccccc,
 * secondary text #adb5bd, border #454545. Measured with the WCAG
 * relative-luminance formula against #252526: text 9.5:1, muted text 7.2:1;
 * the border measures 1.74:1 on the canvas, which is enough for a hairline.
 * The accents get a higher tint alpha there, since a .08 wash is invisible on
 * a dark surface. `--ds-primary` is re-tuned too - in these two views it is
 * only ever an outline/border/text colour (focus ring, hover, checkbox accent),
 * never a filled background under white text, so a lighter blue is safe.
 *
 * `dark` is deliberately NOT gated on :root[data-darkmode="true"] - only some
 * themes set that attribute (Argon never does), so the views decide at runtime
 * with isDarkMode() and append this string only when it applies.
 *
 * Sizes are em-based, never px: the LuCI theme sets the base font size, and
 * only a relative scale keeps the page in step with it.
 *
 * Both meshconf.js and steering.js consume this module; keeping the values in
 * one place is what stops the two views from drifting apart.
 * ------------------------------------------------------------------------- */
return baseclass.extend({
	tokens: '--ds-surface:var(--background-color-high,#fff);--ds-surface-sunken:var(--background-color-medium,#f6f8fa);--ds-border:var(--border-color-low,#d8dee4);--ds-text:var(--text-color-high,#1f2328);--ds-text-muted:var(--text-color-low,#5c6773);--ds-primary:var(--primary-color-high,#0969da);--ds-ok:#1a7f37;--ds-ok-tint:rgba(26,127,55,.08);--ds-ok-line:rgba(26,127,55,.35);--ds-warn:#bc4c00;--ds-warn-tint:rgba(188,76,0,.08);--ds-warn-line:rgba(188,76,0,.35);--ds-error:#cf222e;--ds-error-tint:rgba(207,34,46,.08);--ds-error-line:rgba(207,34,46,.40);--ds-info:#0969da;--ds-info-tint:rgba(9,105,218,.08);--ds-info-line:rgba(9,105,218,.35);--ds-focus-ring:rgba(9,105,218,.32);--ds-r-sm:4px;--ds-r-md:6px;--ds-r-lg:8px;--ds-r-pill:999px;--ds-sp-1:.25em;--ds-sp-2:.5em;--ds-sp-3:.75em;--ds-sp-4:1em;--ds-sp-5:1.5em;--ds-fs-xs:.8em;--ds-fs-sm:.88em;--ds-fs-base:1em;--ds-fs-lg:1.1em;--ds-fs-2xl:1.6em;--ds-shadow-1:0 1px 2px rgba(16,24,40,.04)',

	dark: ':root .meshconf-page{--ds-surface:var(--background-color-high,#252526);--ds-surface-sunken:var(--background-color-medium,#1e1e1e);--ds-border:var(--border-color-low,#454545);--ds-text:var(--text-color-high,#cccccc);--ds-text-muted:var(--text-color-low,#adb5bd);--ds-primary:var(--primary-color-high,#4d9cf6);--ds-ok:#4ac26b;--ds-ok-tint:rgba(74,194,107,.18);--ds-ok-line:rgba(74,194,107,.45);--ds-warn:#e3934a;--ds-warn-tint:rgba(227,147,74,.18);--ds-warn-line:rgba(227,147,74,.45);--ds-error:#f47067;--ds-error-tint:rgba(244,112,103,.18);--ds-error-line:rgba(244,112,103,.5);--ds-info:#4d9cf6;--ds-info-tint:rgba(77,156,246,.18);--ds-info-line:rgba(77,156,246,.45);--ds-focus-ring:rgba(77,156,246,.45);--ds-shadow-1:none}'
});
