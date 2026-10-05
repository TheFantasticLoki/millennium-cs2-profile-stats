/**
 * CS2 Overview Banner — collapsed sidebar card.
 *
 * Design: compact banner with icon, provider links, skill level, radial trust.
 * Clicking expands into a quake-style dropdown with detailed metrics.
 */

import type { AggregatedProfile, AggValue } from '../types/aggregated';
import { PROVIDER_META, aggBreakdownTip, clutchBreakdownTip, entryBreakdownTip, cstrackerBreakdownRows, csrepBreakdownRows } from '../types/aggregated';
import { faceitLvlImg, providerIconImg, csrepCommendImg } from '../icons';
import { asArray, escapeHtml, formatInteger, formatMetric, formatWinrate, formatPercent } from '../helpers';
import { tip } from '../tooltip';

// ── Helpers ─────────────────────────────────────────────────────────

const resolved = <T,>(agg: AggValue<T> | undefined): T | undefined => agg?.value;

const trustScoreColor = (score: number) => {
	if (score >= 80) return '#10b981';
	if (score >= 60) return '#22c55e';
	if (score >= 40) return '#eab308';
	if (score >= 20) return '#f97316';
	return '#ef4444';
};

const trustScoreLabel = (score: number) => {
	if (score >= 90) return 'Excellent';
	if (score >= 80) return 'Good';
	if (score >= 60) return 'Moderate';
	if (score >= 40) return 'Low';
	return 'Danger';
};

/** Compute a combined trust score from CSTracker + CSRep (0–100). */
const combinedTrust = (profile: AggregatedProfile): number | undefined => {
	const ct = profile.trust?.cstracker_rating;
	const cr = profile.trust?.csrep_score;
	if (ct !== undefined && cr !== undefined) return Math.round((ct + cr) / 2);
	if (ct !== undefined) return ct;
	if (cr !== undefined) return cr;
	return undefined;
};

/** Best premier across all sources. */
const bestPremier = (profile: AggregatedProfile): number | undefined => {
	const v = profile.ranks?.premier;
	if (!v) return undefined;
	const candidates = [v.value];
	const lfPremier = profile.provider_data?.leetify?.ranks?.premier;
	if (lfPremier) candidates.push(lfPremier);
	const ctPremier = profile.provider_data?.cstracker?.premier;
	if (ctPremier) candidates.push(ctPremier);
	return Math.max(...candidates.filter((n) => typeof n === 'number' && n > 0));
};

// ── Provider link buttons ───────────────────────────────────────────

type ProviderLink = { iconHtml: string; url: string; label: string };

const providerLinks = (profile: AggregatedProfile, steamId: string): ProviderLink[] => {
	const links: ProviderLink[] = [];
	const pd = profile.provider_data ?? {};
	if (pd.leetify) links.push({ iconHtml: providerIconImg('leetify'), url: `https://leetify.com/app/profile/${steamId}`, label: 'Leetify' });
	if (pd.faceit?.nickname) links.push({ iconHtml: providerIconImg('faceit'), url: `https://www.faceit.com/en/players/${pd.faceit.nickname}`, label: 'FACEIT' });
	if (pd.cstracker) links.push({ iconHtml: providerIconImg('cstracker'), url: `https://cstracker.gg/players/${steamId}`, label: 'CSTracker' });
	if (pd.csrep) links.push({ iconHtml: providerIconImg('csrep'), url: `https://csrep.gg/player/${steamId}`, label: 'CSRep' });
	if (pd.csstats) links.push({ iconHtml: providerIconImg('csstats'), url: `https://csstats.gg/player/${steamId}`, label: 'CSStats' });
	return links;
};

// ── Radial trust score (SVG) ────────────────────────────────────────

const radialTrust = (score: number, size = 40): string => {
	const color = trustScoreColor(score);
	// Thin ring (2px) hugs the edge so the score text can breathe.
	const radius = (size - 4) / 2;
	const circumference = 2 * Math.PI * radius;
	const progress = (score / 100) * circumference;
	const offset = circumference - progress;

	return `
		<svg class="cs2ps-trust-radial" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
			<circle cx="${size / 2}" cy="${size / 2}" r="${radius}"
				fill="none" stroke="rgba(255,255,255,0.08)" stroke-width="2" />
			<circle cx="${size / 2}" cy="${size / 2}" r="${radius}"
				fill="none" stroke="${color}" stroke-width="2"
				stroke-dasharray="${circumference}" stroke-dashoffset="${offset}"
				stroke-linecap="round" transform="rotate(-90 ${size / 2} ${size / 2})"
				style="transition: stroke-dashoffset 600ms ease" />
			<text x="${size / 2}" y="${size / 2}" text-anchor="middle" dominant-baseline="central"
				fill="${color}" font-size="${Math.round(size * 0.4)}" font-weight="700" font-family="Motiva Sans, Arial, sans-serif">
				${Math.round(score)}
			</text>
		</svg>
	`;
};

// ── Rank displays (Premier badge + FACEIT level badge) ─────────────

/** Hex to rgba() helper. */
const hexToRgba = (hex: string, alpha: number): string => {
	const n = parseInt(hex.slice(1), 16);
	return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
};

/**
 * CS2 Premier tier brackets — official hexes. A tier spans 5,000 rating
 * points; crossing a tier boundary swaps the accent color.
 */
const premierTier = (rating: number): { color: string; name: string; litBars: number } => {
	// In-tier progress: one lit bar per 1,000 points, capped at 4 — the
	// right end always keeps ~one bar-width of empty trailing space.
	// Bars reset at each 5,000.
	const litBars = Math.min(4, Math.floor((rating % 5000) / 1000));
	if (rating >= 30000) return { color: '#FFD700', name: 'Gold', litBars };
	if (rating >= 25000) return { color: '#EB4B4B', name: 'Red', litBars };
	if (rating >= 20000) return { color: '#D32CE6', name: 'Pink', litBars };
	if (rating >= 15000) return { color: '#8847FF', name: 'Purple', litBars };
	if (rating >= 10000) return { color: '#4B69FF', name: 'Dark Blue', litBars };
	if (rating >= 5000) return { color: '#5E98D9', name: 'Blue', litBars };  // blue
	return { color: '#B0C3D9', name: 'Grey', litBars };
};

/**
 * Recreates the CS2 Premier rating badge: a right-leaning parallelogram
 * plate hugging its content, with two thin, full-brightness accent bars
 * on the left and a tight cluster of background bars behind the number.
 *
 * Five slot widths tile the area behind the number; at most four slots
 * ever light up, so the always-empty rightmost slot forms the trailing
 * gap (~one bar thick) and the plate stays short. Each new bar is
 * brighter than the last and is inserted to the LEFT of the lit stack
 * (right beside the accent bars), pushing dimmer bars rightward — every
 * bar keeps its own fixed shade, ramping from just above the plate
 * background (first bar) to just under half the full accent color
 * (fourth bar). Bars reset and the color swaps at every 5,000-point
 * tier boundary.
 */
const premierBadge = (rating: number): string => {
	const { color, name, litBars } = premierTier(rating);
	const label = escapeHtml(formatInteger(rating));
	const border = hexToRgba(color, 0.6);

	// ── Plate geometry (viewBox 0 0 144 52) ──
	// Right-leaning parallelogram: the top edge sits +12px in x relative
	// to the bottom edge, matching the in-game badge's italic lean. The
	// plate hugs the accent bars + bar cluster + trailing empty slot, so
	// the badge length scales with its content instead of staying wide.
	const SLANT = 12;
	const TOP_Y = 2;
	const BOT_Y = 50;
	const PLATE = `M 16 ${TOP_Y} H 140 L ${140 - SLANT} ${BOT_Y} H ${16 - SLANT} Z`;

	// Slanted vertical strip: `tx` = top-left x, `w` = width, y 7..45.
	// Strips lean with the plate edges (≈9.5px x-shift over their height).
	const STRIP_TOP = 7;
	const STRIP_BOT = 45;
	const STRIP_DX = (SLANT * (STRIP_BOT - STRIP_TOP)) / (BOT_Y - TOP_Y);
	const strip = (tx: number, w: number): string =>
		`M ${tx} ${STRIP_TOP} L ${tx + w} ${STRIP_TOP} L ${tx + w - STRIP_DX} ${STRIP_BOT} L ${tx - STRIP_DX} ${STRIP_BOT} Z`;

	// Constant: two thin accent bars on the left, full tier color.
	const accents =
		`<path d="${strip(22, 4)}" fill="${color}"/>` +
		`<path d="${strip(30.5, 4)}" fill="${color}"/>`;

	// Background: 5 tightly clustered slots tiling the area behind the
	// number (4 lit max); the always-empty rightmost slot is the trailing
	// gap (~one bar thick). Each new (brighter) bar is inserted at the
	// left of the lit stack and pushes dimmer bars right.
	// Shade ladder: dimmest → brightest.
	const RAMP = [0.10, 0.20, 0.33, 0.48];
	const SLOT_X0 = 40;
	const SLOT_PITCH = 20;
	const SLOT_W = 17;

	let bars = '';
	for (let k = 0; k < litBars; k++) {
		bars += `<path d="${strip(SLOT_X0 + k * SLOT_PITCH, SLOT_W)}" fill="${hexToRgba(color, RAMP[litBars - k - 1])}"/>`;
	}

	const tipHtml =
		`<div class="cs2ps-tip-head">Premier Rating</div>` +
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Rating</span><span class="cs2ps-tip-val" style="color:${color}">${label}</span></div>` +
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Tier</span><span class="cs2ps-tip-val" style="color:${color}">${name}</span></div>`;

	return `
		<span class="cs2ps-banner-rank"${tip(tipHtml)}>
			<svg class="cs2ps-pb-svg" viewBox="0 0 144 52" xmlns="http://www.w3.org/2000/svg">
				<path d="${PLATE}" fill="#11141a" stroke="${border}" stroke-width="1.5" stroke-linejoin="round"/>
				<path d="${PLATE}" fill="${hexToRgba(color, 0.07)}"/>
				${bars}
				${accents}
				<text x="38" y="26" text-anchor="start" dominant-baseline="central" fill="#ffffff" stroke="#0d1117" stroke-width="3" paint-order="stroke" font-size="22" font-weight="900" font-family="Stratum2, Arial Black, sans-serif">${label}</text>
			</svg>
		</span>
	`;
};

/** Official FACEIT level medallion (lvl1–10 assets); ELO revealed on hover. */
const faceitBadge = (level: number, elo: number | undefined): string => {
	const src = faceitLvlImg(level);
	if (!src) return '';
	const levelLabel = escapeHtml(String(level));
	const tipHtml =
		`<div class="cs2ps-tip-head">FACEIT</div>` +
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Level</span><span class="cs2ps-tip-val" style="color:#ff5500">${levelLabel}</span></div>` +
		(elo !== undefined
			? `<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">ELO</span><span class="cs2ps-tip-val" style="color:#ff5500">${escapeHtml(formatInteger(elo))}</span></div>`
			: '');
	return `
		<span class="cs2ps-banner-rank"${tip(tipHtml)}>
			<img class="cs2ps-faceit-lvl" src="${src}" alt="FACEIT Level ${levelLabel}">
		</span>
	`;
};

/** Bottom row of the banner info stack: trust ring, FACEIT, Premier. */
const ranksDisplay = (profile: AggregatedProfile): string => {
	const parts: string[] = [];

	const trust = combinedTrust(profile);
	if (trust !== undefined) {
		const ct = profile.trust.cstracker_rating;
		const cr = profile.trust.csrep_score;
		const rows = [`<div class="cs2ps-tip-head">Trust: ${trustScoreLabel(trust)} (${formatMetric(trust, 5)})</div>`];
		if (ct !== undefined) rows.push(`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">CSTracker</span><span class="cs2ps-tip-val" style="color:${trustScoreColor(ct)}">${formatMetric(ct, 5)}</span></div>`);
		if (cr !== undefined) rows.push(`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">CSRep</span><span class="cs2ps-tip-val" style="color:${trustScoreColor(cr)}">${formatMetric(cr, 5)}</span></div>`);
		// Surface the scraped reasons when either score is below 100.
		const ctReasons = cstrackerBreakdownRows(asArray(profile.trust?.cstracker_breakdown));
		if (ct !== undefined && ct < 100 && ctReasons) {
			rows.push(
				`<div class="cs2ps-tip-sub-head">CSTracker — why below 100</div>`,
				`<div class="cs2ps-tip-desc">Behavioral factors applied as ± adjustments to the base score.</div>`,
				ctReasons,
			);
		}
		const crReasons = csrepBreakdownRows(asArray(profile.trust?.csrep_breakdown));
		if (cr !== undefined && cr < 100 && crReasons) {
			rows.push(
				`<div class="cs2ps-tip-sub-head">CSRep — why below 100</div>`,
				`<div class="cs2ps-tip-desc">Statistical trust is the base; flags and anomalies lower it, bonus raises it.</div>`,
				crReasons,
			);
		}
		parts.push(`<span class="cs2ps-banner-trust"${tip(rows.join(''))}>${radialTrust(trust, 22)}</span>`);
	}

	const faceitLevel = resolved(profile.ranks.faceit);
	if (faceitLevel !== undefined) {
		parts.push(faceitBadge(faceitLevel, resolved(profile.ranks.faceit_elo)));
	}

	const premier = bestPremier(profile);
	if (premier !== undefined) {
		parts.push(premierBadge(premier));
	}

	if (!parts.length) return '';
	return `<div class="cs2ps-banner-ranks">${parts.join('')}</div>`;
};

// ── Banner (collapsed) ──────────────────────────────────────────────

/** One provider's slot in the segmented loading bar. */
export type LoadSegment = {
	label: string;
	color: string;
	state: 'active' | 'done' | 'error';
	detail: string;
};

/**
 * Segmented loading bar pinned to the bottom of the banner. One segment
 * per data provider. The backend fetches all providers concurrently in a
 * single parallel pump, so every in-flight segment animates at the same
 * time and fills in the moment its own response arrives — segments
 * complete out of layout order as a matter of course (fast APIs first,
 * FlareSolverr-backed scrapers last). Hovering a segment shows the
 * provider name and its current state.
 */
export const renderLoadingSegments = (segments: LoadSegment[]): string => {
	if (!segments.length) return '';
	const items = segments
		.map(
			(segment) =>
				`<div class="cs2ps-loadseg cs2ps-loadseg-${segment.state}" style="--seg-color:${escapeHtml(segment.color)}"${tip(
					`<div class="cs2ps-tip-head">${escapeHtml(segment.label)}</div><div class="cs2ps-tip-desc">${escapeHtml(segment.detail)}</div>`,
				)}><span class="cs2ps-loadseg-fill"></span></div>`,
		)
		.join('');
	return `<div class="cs2ps-loadbar" aria-hidden="true">${items}</div>`;
};

export const renderOverviewBanner = (profile: AggregatedProfile, steamId: string, expanded: boolean, loadSegments: LoadSegment[] = []): string => {
	const links = providerLinks(profile, steamId);
	const linkCount = links.length;

	// Provider link buttons — split into evenly balanced rows (max 2) so
	// the top and bottom rows never differ by more than one button.
	const capped = links.slice(0, 6);
	const perRow = Math.max(1, capped.length <= 3 ? capped.length : Math.ceil(capped.length / 2));
	const linkRows: string[] = [];
	for (let i = 0; i < capped.length; i += perRow) {
		const row = capped.slice(i, i + perRow).map((l) =>
			`<a class="cs2ps-banner-link" href="${escapeHtml(l.url)}" target="_blank" rel="noopener"${tip(escapeHtml(l.label))}>${l.iconHtml}</a>`
		).join('');
		linkRows.push(`<div class="cs2ps-banner-link-row">${row}</div>`);
	}
	const linkButtons = linkRows.join('');

	return `
		<div class="cs2ps-banner ${expanded ? 'cs2ps-banner-expanded' : ''}" data-cs2ps-banner>
			<div class="cs2ps-banner-row">
				<div class="cs2ps-banner-gameicon"${tip('Counter-Strike 2')}></div>
				<div class="cs2ps-banner-info">
					<span class="cs2ps-banner-title">CS2 Overview</span>
					${ranksDisplay(profile)}
				</div>
				${linkCount > 0 ? `<div class="cs2ps-banner-links">${linkButtons}</div>` : ''}
				<div class="cs2ps-banner-collapse">
					<span class="cs2ps-banner-chevron ${expanded ? 'cs2ps-banner-chevron-open' : ''}">⌃</span>
				</div>
			</div>
			<div class="cs2ps-banner-dropdown ${expanded ? 'cs2ps-banner-dropdown-open' : ''}">
				${renderBannerDropdown(profile)}
			</div>
			${loadSegments.length ? renderLoadingSegments(loadSegments) : ''}
		</div>
	`;
};

// ── Quake-style dropdown content ────────────────────────────────────

const renderBannerDropdown = (profile: AggregatedProfile): string => {
	const sections: string[] = [];

	// ── Trust summary ──
	// Each provider's score is shown with the scraped reasons it is below
	// 100 (CSTracker factor deltas, CSRep trust components), inline and
	// on hover.
	const trust = profile.trust ?? ({} as AggregatedProfile['trust']);
	const trustItems: string[] = [];
	if (trust.cstracker_rating !== undefined) {
		const color = trustScoreColor(trust.cstracker_rating);
		const reasons = cstrackerBreakdownRows(asArray(trust.cstracker_breakdown));
		const showReasons = trust.cstracker_rating < 100 && !!reasons;
		const hover = showReasons
			? `<div class="cs2ps-tip-head">CSTracker Trust ${formatMetric(trust.cstracker_rating, 5)}/100 — why below 100</div><div class="cs2ps-tip-desc">Behavioral factors applied as ± adjustments to the base score.</div>${reasons}`
			: `<div class="cs2ps-tip-head">CSTracker Trust</div><div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Rating</span><span class="cs2ps-tip-val" style="color:${color}">${formatMetric(trust.cstracker_rating, 5)}/100</span></div>`;
		trustItems.push(`
			<div class="cs2ps-drop-trust-item"${tip(hover)}>
				<span class="cs2ps-drop-trust-dot" style="background:${color}"></span>
				<span class="cs2ps-drop-trust-label">CSTracker</span>
				<span class="cs2ps-drop-trust-val" style="color:${color}">${formatInteger(trust.cstracker_rating)}</span>
			</div>
		`);
		if (showReasons) trustItems.push(`<div class="cs2ps-drop-trust-reasons">${reasons}</div>`);
	}
	if (trust.csrep_score !== undefined) {
		const color = trustScoreColor(trust.csrep_score);
		const reasons = csrepBreakdownRows(asArray(trust.csrep_breakdown));
		const showReasons = trust.csrep_score < 100 && !!reasons;
		const hover = showReasons
			? `<div class="cs2ps-tip-head">CSRep Trust ${formatMetric(trust.csrep_score, 5)}/100 — why below 100</div><div class="cs2ps-tip-desc">Statistical trust is the base; flags and anomalies lower it, bonus raises it.</div>${reasons}`
			: `<div class="cs2ps-tip-head">CSRep Trust</div><div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Score</span><span class="cs2ps-tip-val" style="color:${color}">${formatMetric(trust.csrep_score, 5)}/100</span></div>`;
		trustItems.push(`
			<div class="cs2ps-drop-trust-item"${tip(hover)}>
				<span class="cs2ps-drop-trust-dot" style="background:${color}"></span>
				<span class="cs2ps-drop-trust-label">CSRep</span>
				<span class="cs2ps-drop-trust-val" style="color:${color}">${formatInteger(trust.csrep_score)}</span>
			</div>
		`);
		if (showReasons) trustItems.push(`<div class="cs2ps-drop-trust-reasons">${reasons}</div>`);
	}
	if (trustItems.length) {
		sections.push(`<div class="cs2ps-drop-section"><div class="cs2ps-drop-heading">Trust</div><div class="cs2ps-drop-trust-grid">${trustItems.join('')}</div></div>`);
	}

	// ── Commendations (CSRep) ──
	// Compact one-line row: icon + count per commendation, each item with
	// its own hover tooltip. Sits between Trust and Performance.
	const comms = profile.provider_data?.csrep?.commendations;
	if (comms) {
		const items: Array<{ key: 'leader' | 'friendly' | 'teaching'; label: string; value: number }> = [];
		if (typeof comms.leader === 'number') items.push({ key: 'leader', label: 'Leader', value: comms.leader });
		if (typeof comms.friendly === 'number') items.push({ key: 'friendly', label: 'Friendly', value: comms.friendly });
		if (typeof comms.teaching === 'number') items.push({ key: 'teaching', label: 'Teaching', value: comms.teaching });
		if (items.length) {
			const cells = items.map((c) => {
					const iconUri = csrepCommendImg(c.key);
					const icon = iconUri ? `<img src="${iconUri}" alt="">` : '';
				const hover =
					`<div class="cs2ps-tip-head">${escapeHtml(c.label)}</div>` +
					`<div class="cs2ps-tip-desc">Steam commendation awarded by other players (sourced via CSRep).</div>` +
					`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Commendations</span><span class="cs2ps-tip-val">${formatInteger(c.value)}</span></div>`;
				return `
					<div class="cs2ps-drop-commend"${tip(hover)}>
						${icon}
						<span class="cs2ps-drop-commend-count">${formatInteger(c.value)}</span>
					</div>
				`;
			}).join('');
			sections.push(`<div class="cs2ps-drop-section"><div class="cs2ps-drop-commend-row">${cells}</div></div>`);
		}
	}

	// ── Core stats grid ──
	// Each cell carries a hover tooltip with the per-provider breakdown:
	// each source's own value, its weight in the blend, and matches tracked.
	const stats = profile.stats ?? {};
	const coreItems: string[] = [];
	if (stats.kd) coreItems.push(dropStat('K/D', stats.kd, (v) => formatMetric(v, 2), { digits: 2 }));
	if (stats.winrate) coreItems.push(dropStat('Win Rate', stats.winrate, (v) => formatWinrate(v), { digits: 1, suffix: '%' }));
	if (stats.adr) coreItems.push(dropStat('ADR', stats.adr, (v) => formatMetric(v, 0), { digits: 1 }));
	if (stats.headshot_pct) coreItems.push(dropStat('HS%', stats.headshot_pct, (v) => formatPercent(v), { digits: 1, suffix: '%' }));
	if (stats.head_accuracy) coreItems.push(dropStat('Head Acc', stats.head_accuracy, (v) => formatPercent(v), { digits: 1, suffix: '%' }));
	if (stats.hltv_rating) coreItems.push(dropStat('HLTV', stats.hltv_rating, (v) => formatMetric(v, 2), { digits: 2 }));
	if (stats.kast) coreItems.push(dropStat('KAST', stats.kast, (v) => formatPercent(v), { digits: 1, suffix: '%' }));
	if (stats.total_matches) coreItems.push(dropStat('Games', stats.total_matches, (v) => formatInteger(v), { digits: 0 }));
	if (coreItems.length) {
		sections.push(`<div class="cs2ps-drop-section"><div class="cs2ps-drop-heading">Performance</div><div class="cs2ps-drop-grid">${coreItems.join('')}</div></div>`);
	}

	// ── Leetify ratings ──
	const lr = profile.leetify_rating ?? {};
	const lrItems: string[] = [];
	if (lr.aim) lrItems.push(dropStat('Aim', lr.aim, (v) => formatMetric(v, 1), { digits: 1 }));
	if (lr.positioning) lrItems.push(dropStat('Position', lr.positioning, (v) => formatMetric(v, 1), { digits: 1 }));
	if (lr.utility) lrItems.push(dropStat('Utility', lr.utility, (v) => formatMetric(v, 1), { digits: 1 }));
	if (lr.clutch) lrItems.push(dropStat('Clutch', lr.clutch, (v) => `${v > 0 ? '+' : ''}${formatMetric(v, 2)}`, { digits: 2 }));
	if (lr.opening) lrItems.push(dropStat('Opening', lr.opening, (v) => `${v > 0 ? '+' : ''}${formatMetric(v, 2)}`, { digits: 2 }));
	if (lrItems.length) {
		sections.push(`<div class="cs2ps-drop-section"><div class="cs2ps-drop-heading">Leetify Ratings</div><div class="cs2ps-drop-grid">${lrItems.join('')}</div></div>`);
	}

	// ── CSTracker deep stats (histograms when available) ──
	const ct = profile.provider_data?.cstracker;
	if (ct?.match_history && ct.match_history.length > 0) {
		const recentKd = asArray<NonNullable<typeof ct.match_history>[number]>(ct.match_history)
			.slice(0, 10)
			.filter((m) => m.kd !== undefined);
		if (recentKd.length > 0) {
			const kdBars = recentKd.map((m) => {
				const val = m.kd ?? 0;
				const height = Math.min(100, Math.max(5, (val / 3) * 100));
				const color = val >= 1.0 ? '#22c55e' : val >= 0.8 ? '#eab308' : '#ef4444';
				return `<div class="cs2ps-drop-bar" style="height:${height}%;background:${color}"${tip(`K/D ${formatMetric(val, 2)}`)}></div>`;
			}).join('');
			sections.push(`<div class="cs2ps-drop-section"><div class="cs2ps-drop-heading">Recent K/D Trend</div><div class="cs2ps-drop-histogram">${kdBars}</div></div>`);
		}
	}

	// ── Clutch ──
	// Each bar carries the same quality of hover tooltip as the other
	// aggregated stats: winrate, W/L record, and per-provider contributions.
	if (profile.clutch.length > 0) {
		const clutchBars = asArray<AggregatedProfile['clutch'][number]>(profile.clutch).map((c) => {
			const height = Math.min(100, Math.max(5, c.winrate));
			const color = c.winrate >= 50 ? '#22c55e' : c.winrate >= 30 ? '#eab308' : '#ef4444';
			const hover = clutchBreakdownTip(c);
			return `
				<div class="cs2ps-drop-clutch-item"${tip(hover)}>
					<div class="cs2ps-drop-clutch-bar-wrap">
						<div class="cs2ps-drop-clutch-bar" style="height:${height}%;background:${color}"></div>
					</div>
					<span class="cs2ps-drop-clutch-label">${escapeHtml(c.label)}</span>
					<span class="cs2ps-drop-clutch-val">${formatPercent(c.winrate)}</span>
				</div>
			`;
		}).join('');
		sections.push(`<div class="cs2ps-drop-section"><div class="cs2ps-drop-heading">Clutch Win Rates</div><div class="cs2ps-drop-clutch">${clutchBars}</div></div>`);
	}

	// ── Entry success ──
	// Same vertical-bar layout as clutch, with per-provider contributions
	// on hover. Bar height is the entry-duel success rate.
	const entryRows = asArray<AggregatedProfile['entry'][number]>(profile.entry);
	if (entryRows.length > 0) {
		const entryBars = entryRows.map((r) => {
			const pct = r.success_pct ?? 0;
			const height = Math.min(100, Math.max(5, pct));
			const color = pct >= 50 ? '#22c55e' : pct >= 30 ? '#eab308' : '#ef4444';
			return `
				<div class="cs2ps-drop-clutch-item"${tip(entryBreakdownTip(r))}>
					<div class="cs2ps-drop-clutch-bar-wrap">
						<div class="cs2ps-drop-clutch-bar" style="height:${height}%;background:${color}"></div>
					</div>
					<span class="cs2ps-drop-clutch-label">${escapeHtml(r.label)}</span>
					<span class="cs2ps-drop-clutch-val">${formatPercent(pct)}</span>
				</div>
			`;
		}).join('');
		sections.push(`<div class="cs2ps-drop-section"><div class="cs2ps-drop-heading">Entry Success</div><div class="cs2ps-drop-clutch">${entryBars}</div></div>`);
	}

	// ── Multi-kills ──
	// Aggregated counts (double/triple/quad/penta rounds) with per-provider
	// hover breakdowns, same treatment as the other aggregated stats.
	const mk = profile.multi_kills ?? {};
	const mkItems: string[] = [];
	if (mk.double) mkItems.push(dropStat('Double Kill', mk.double, (v) => formatInteger(v), { digits: 0 }));
	if (mk.triple) mkItems.push(dropStat('Triple Kill', mk.triple, (v) => formatInteger(v), { digits: 0 }));
	if (mk.quad) mkItems.push(dropStat('Quad Kill', mk.quad, (v) => formatInteger(v), { digits: 0 }));
	if (mk.penta) mkItems.push(dropStat('Penta Kill', mk.penta, (v) => formatInteger(v), { digits: 0 }));
	if (mkItems.length) {
		sections.push(`<div class="cs2ps-drop-section"><div class="cs2ps-drop-heading">Multi-Kills</div><div class="cs2ps-drop-grid">${mkItems.join('')}</div></div>`);
	}

	if (!sections.length) {
		return '<div class="cs2ps-drop-empty">Limited data available from aggregated sources.</div>';
	}

	return sections.join('');
};

/** Single stat in the dropdown grid, with a per-provider hover breakdown. */
const dropStat = (
	label: string,
	agg: AggValue<number> | undefined,
	fmt: (v: number) => string,
	opts?: { digits?: number; suffix?: string },
): string => {
	if (!agg || typeof agg.value !== 'number' || !Number.isFinite(agg.value)) return '';
	const badges = asArray<string>(agg.sources).map((s) => {
		const meta = PROVIDER_META[s];
		const icon = providerIconImg(s);
		if (icon) return `<span class="cs2ps-drop-src"${tip(escapeHtml(meta?.label ?? s))}>${icon}</span>`;
		return meta ? `<span class="cs2ps-drop-src" style="color:${meta.color}">${meta.icon}</span>` : '';
	}).join('');
	const hover = aggBreakdownTip(label, agg, opts);
	return `
		<div class="cs2ps-drop-stat"${tip(hover)}>
			<span class="cs2ps-drop-stat-label">${escapeHtml(label)}</span>
			<span class="cs2ps-drop-stat-value">${escapeHtml(fmt(agg.value))}</span>
			${badges ? `<span class="cs2ps-drop-stat-src">${badges}</span>` : ''}
		</div>
	`;
};
