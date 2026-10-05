/**
 * Provider icon assets, inlined at build time from static/assets/<provider>.
 *
 * Rendered as <img> data URIs so each SVG stays an isolated document —
 * no gradient/pattern id collisions when the same icon appears in the
 * banner links, the dropdown source badges, and the breakdown panel.
 */
import { constSysfsExpr } from '@steambrew/webkit';

const imgUri = (svg: string): string => `data:image/svg+xml,${encodeURIComponent(svg)}`;

const leetifySvg = constSysfsExpr('leetify-icon.svg', {
	basePath: '../static/assets/leetify',
	encoding: 'utf8',
}).content;

const cstrackerSvg = constSysfsExpr('icon.svg', {
	basePath: '../static/assets/cstracker',
	encoding: 'utf8',
}).content;

const csrepSvg = constSysfsExpr('icon.svg', {
	basePath: '../static/assets/csrep',
	encoding: 'utf8',
}).content;

/** Steam commendation marks scraped via CSRep — Leader / Friendly / Teacher. */
const csrepCommendSvgs: Record<string, string> = {
	leader: constSysfsExpr('commend-leader.svg', { basePath: '../static/assets/csrep', encoding: 'utf8' })
		// The exported marks ship in Steam's dark gray (#434344); lift them to
		// the plugin's muted text tone so they read on the dark dropdown.
		.content.replace(/#434344/gi, '#90a2af'),
	friendly: constSysfsExpr('commend-friendly.svg', { basePath: '../static/assets/csrep', encoding: 'utf8' })
		.content.replace(/#434344/gi, '#90a2af'),
	teaching: constSysfsExpr('commend-teacher.svg', { basePath: '../static/assets/csrep', encoding: 'utf8' })
		.content.replace(/#434344/gi, '#90a2af'),
};

/** Data-URI src for a CSRep commendation icon (leader/friendly/teaching).
 * Built from the local files in static/assets/csrep at build time —
 * callers must wrap it in an <img> tag (see csrepCommendImg usage). */
export const csrepCommendImg = (key: 'leader' | 'friendly' | 'teaching'): string => {
	const svg = csrepCommendSvgs[key];
	return svg ? imgUri(svg) : '';
};

// CSStats ships a <style> block that only paints the mark in dark color
// schemes — strip it and force the fill white for the dark plugin UI.
const csstatsSvg = constSysfsExpr('icon.svg', {
	basePath: '../static/assets/csstats',
	encoding: 'utf8',
})
	.content.replace(/<style>[\s\S]*?<\/style>/g, '')
	.replace('fill="none"', 'fill="#ffffff"');

/** Official FACEIT assets — the mark plus level medallions lvl1–lvl10. */
const faceitIconSvg = constSysfsExpr('icon.svg', {
	basePath: '../static/assets/faceit',
	encoding: 'utf8',
}).content;

const faceitLvlSvgs: Record<number, string> = {
	1: constSysfsExpr('lvl1.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	2: constSysfsExpr('lvl2.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	3: constSysfsExpr('lvl3.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	4: constSysfsExpr('lvl4.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	5: constSysfsExpr('lvl5.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	6: constSysfsExpr('lvl6.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	7: constSysfsExpr('lvl7.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	8: constSysfsExpr('lvl8.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	9: constSysfsExpr('lvl9.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
	10: constSysfsExpr('lvl10.svg', { basePath: '../static/assets/faceit', encoding: 'utf8' }).content,
};

/** <img> data URI for a FACEIT level medallion (clamped to lvl1–lvl10). */
export const faceitLvlImg = (level: number): string => {
	const svg = faceitLvlSvgs[Math.min(10, Math.max(1, Math.round(level)))];
	return svg ? imgUri(svg) : '';
};

export const PROVIDER_ICON_IMG: Record<string, string> = {
	leetify: imgUri(leetifySvg),
	faceit: imgUri(faceitIconSvg),
	cstracker: imgUri(cstrackerSvg),
	csrep: imgUri(csrepSvg),
	csstats: imgUri(csstatsSvg),
};

/** <img> markup for a provider icon, or an empty string when unknown. */
export const providerIconImg = (key: string): string => {
	const src = PROVIDER_ICON_IMG[key];
	return src ? `<img src="${src}" alt="">` : '';
};
