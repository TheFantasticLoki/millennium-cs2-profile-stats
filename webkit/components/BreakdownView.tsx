/**
 * CS2 Breakdown — full detailed data exploration panel.
 *
 * Separate element from the overview banner. Contains all provider data
 * with provider attribution, histograms, and deep-dive stats.
 */

import type { AggregatedProfile, AggValue, TrustBreakdownEntry } from '../types/aggregated';
import { PROVIDER_META, aggBreakdownTip, clutchBreakdownTip, entryBreakdownTip } from '../types/aggregated';
import { providerIconImg } from '../icons';
import { asArray, escapeHtml, formatInteger, formatMetric, formatOneInX, formatWinrate, formatPercent, formatMilliseconds, formatMapName } from '../helpers';
import { tip } from '../tooltip';

// ── Helpers ─────────────────────────────────────────────────────────

const trustScoreColor = (score: number) => {
	if (score >= 80) return 'cs2ps-trust-excellent';
	if (score >= 60) return 'cs2ps-trust-good';
	if (score >= 40) return 'cs2ps-trust-moderate';
	if (score >= 20) return 'cs2ps-trust-low';
	return 'cs2ps-trust-danger';
};

const trustScoreLabel = (score: number) => {
	if (score >= 80) return 'Excellent';
	if (score >= 60) return 'Good';
	if (score >= 40) return 'Moderate';
	if (score >= 20) return 'Low';
	return 'Danger';
};

/** Source badges as HTML. Non-array values (stale cache payloads) render no badges. */
const srcBadges = (srcs: string[] | undefined): string =>
	asArray<string>(srcs).map((s) => {
		const meta = PROVIDER_META[s];
		const icon = providerIconImg(s);
		if (icon) return `<span class="cs2ps-bd-src"${tip(escapeHtml(meta?.label ?? s))}>${icon}</span>`;
		if (!meta) return `<span class="cs2ps-bd-src">${escapeHtml(s)}</span>`;
		return `<span class="cs2ps-bd-src" style="--src-color:${meta.color}"${tip(escapeHtml(meta.label))}>${meta.icon}</span>`;
	}).join('');

/** Multi-source indicator. */
const multiSource = (agg: AggValue<unknown> | undefined): string => {
	const sources = asArray<string>(agg?.sources);
	if (!agg || sources.length <= 1) return '';
	return `<span class="cs2ps-bd-multi"${tip(`Data from ${sources.length} providers`)}>×${sources.length}</span>`;
};

// ── Stat row with attribution ───────────────────────────────────────

const bdStat = <T,>(label: string, agg: AggValue<T> | undefined, fmt: (v: T) => string, highlight = false): string => {
	if (!agg) return '';
	const val = fmt(agg.value);
	const badges = srcBadges(agg.sources);
	const multi = multiSource(agg);
	// Numeric stats get a per-provider contribution breakdown on hover.
	const hover =
		typeof agg.value === 'number'
			? tip(aggBreakdownTip(label, agg as AggValue<number>))
			: '';
	return `
		<div class="cs2ps-bd-stat ${highlight ? 'cs2ps-bd-highlight' : ''}"${hover}>
			<span class="cs2ps-bd-stat-label">${escapeHtml(label)}</span>
			<span class="cs2ps-bd-stat-value">${escapeHtml(val)}${multi}</span>
			<span class="cs2ps-bd-stat-src">${badges}</span>
		</div>
	`;
};

// ── Breakdown panel sections ────────────────────────────────────────

export const renderBreakdown = (profile: AggregatedProfile): string => {
	const sections: string[] = [];
	const p = profile ?? ({} as AggregatedProfile);

	// Each section renders in isolation: one provider feeding a malformed
	// field (scrape drift, odd cache payload) degrades that single section
	// to a notice instead of throwing and wiping the whole Breakdown panel.
	const safe = (label: string, render: () => string): void => {
		try {
			const html = render();
			if (html) sections.push(html);
		} catch (error) {
			console.error(`[CS2 Profile Stats] Breakdown section "${label}" failed:`, error);
			sections.push(
				`<div class="cs2ps-bd-section"><div class="cs2ps-bd-section-title">${escapeHtml(label)}</div>` +
				`<p class="cs2ps-detail-note">This section failed to render for this profile.</p></div>`,
			);
		}
	};

	// ── Provider overview ──
	safe('Data Sources', () => renderProviderOverview(p));

	// ── Core Performance ──
	safe('Core Performance', () => renderCoreStats(p));

	// ── Trust & Reputation ──
	safe('Trust & Reputation', () => renderTrustSection(p));

	// ── Leetify Ratings ──
	safe('Leetify Ratings', () => renderLeetifyRatings(p));

	// ── Ranks ──
	safe('Ranks', () => renderRanks(p));

	// ── Aim & Reactions ──
	safe('Aim & Reactions', () => renderAimSection(p));

	// ── Clutch Performance ──
	safe('Clutch Performance', () => renderClutchSection(p));

	// ── Entry Success ──
	safe('Entry Success', () => renderEntrySection(p));

	// ── Multi-Kills ──
	safe('Multi-Kills', () => renderMultiKillsSection(p));

	// ── Kill Breakdown ──
	safe('Kill Breakdown', () => renderKillBreakdown(p));

	// ── Utility ──
	safe('Utility', () => renderUtilitySection(p));

	// ── Behavior ──
	safe('Behavior', () => renderBehaviorSection(p));

	// ── Match History ──
	safe('Match History', () => renderMatchHistory(p));

	return `<div class="cs2ps-bd-root">${sections.join('')}</div>`;
};

// ── Section: Provider overview ──────────────────────────────────────

const renderProviderOverview = (profile: AggregatedProfile): string => {
	const badges = asArray<string>(profile.providers_used).map((name) => {
		const meta = PROVIDER_META[name];
		const icon = providerIconImg(name);
		if (icon) return `<span class="cs2ps-bd-prov-badge" style="--prov-color:${meta?.color ?? '#8ea6b7'}">${icon} ${escapeHtml(meta?.label ?? name)}</span>`;
		if (!meta) return `<span class="cs2ps-bd-prov-badge cs2ps-bd-prov-unknown">${escapeHtml(name)}</span>`;
		return `<span class="cs2ps-bd-prov-badge" style="--prov-color:${meta.color}">${meta.icon} ${escapeHtml(meta.label)}</span>`;
	}).join('');

	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Data Sources</div>
			<div class="cs2ps-bd-prov-list">${badges}<span class="cs2ps-bd-prov-count">${profile.provider_count} active</span></div>
		</div>
	`;
};

// ── Section: Core stats ─────────────────────────────────────────────

const renderCoreStats = (profile: AggregatedProfile): string => {
	const s = profile.stats ?? {};
	const items = [
		bdStat('K/D', s.kd, (v) => formatMetric(v, 2), true),
		bdStat('Win Rate', s.winrate, (v) => formatWinrate(v), true),
		bdStat('ADR', s.adr, (v) => formatMetric(v, 1)),
		bdStat('Headshot %', s.headshot_pct, (v) => formatPercent(v)),
		bdStat('HLTV Rating', s.hltv_rating, (v) => formatMetric(v, 2)),
		bdStat('KAST', s.kast, (v) => formatPercent(v)),
		bdStat('Total Matches', s.total_matches, (v) => formatInteger(v)),
		bdStat('Kills', s.kills, (v) => formatInteger(v)),
		bdStat('Deaths', s.deaths, (v) => formatInteger(v)),
		bdStat('Assists', s.assists, (v) => formatInteger(v)),
	].filter(Boolean).join('');

	if (!items) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Core Performance</div>
			<div class="cs2ps-bd-grid">${items}</div>
		</div>
	`;
};

// ── Section: Trust ──────────────────────────────────────────────────

const renderTrustSection = (profile: AggregatedProfile): string => {
	const t = profile.trust ?? ({} as AggregatedProfile['trust']);
	const items: string[] = [];

	if (t.cstracker_rating !== undefined) {
		const cls = trustScoreColor(t.cstracker_rating);
		items.push(`
			<div class="cs2ps-bd-trust-item ${cls}">
				<span class="cs2ps-bd-trust-name">🎯 CSTracker</span>
				<span class="cs2ps-bd-trust-score">${formatInteger(t.cstracker_rating)}/100</span>
				<span class="cs2ps-bd-trust-label">${trustScoreLabel(t.cstracker_rating)}</span>
			</div>
		`);
		const ctBreakdown = asArray<TrustBreakdownEntry>(t.cstracker_breakdown);
		if (ctBreakdown.length > 0) {
			const factors = ctBreakdown.map((b) => `
				<span class="cs2ps-bd-trust-factor">
					${escapeHtml(b.factor || '')} <span class="${(b.delta || 0) >= 0 ? 'cs2ps-positive' : 'cs2ps-negative'}">${(b.delta || 0) >= 0 ? '+' : ''}${formatMetric(b.delta, 1)}%</span>
				</span>
			`).join('');
			items.push(`<div class="cs2ps-bd-trust-factors">${factors}</div>`);
		}
	}

	if (t.csrep_score !== undefined) {
		const cls = trustScoreColor(t.csrep_score);
		items.push(`
			<div class="cs2ps-bd-trust-item ${cls}">
				<span class="cs2ps-bd-trust-name">🛡️ CSRep</span>
				<span class="cs2ps-bd-trust-score">${formatInteger(t.csrep_score)}/100</span>
				<span class="cs2ps-bd-trust-label">${t.csrep_label || trustScoreLabel(t.csrep_score)}</span>
			</div>
		`);
		// Prefer the structured breakdown (factor → value, penalty flags);
		// fall back to the flat component fields for older cached profiles.
		// CSRep components are trust percentages on a 0-100 scale (bonus is
		// +percentage points) — normalized in backend csrep.lua.
		const crBreakdown = asArray<TrustBreakdownEntry>(t.csrep_breakdown);
		if (crBreakdown.length > 0) {
			const factors = crBreakdown.map((b) => {
				const value = b.value ?? b.delta ?? 0;
				const isPenalty = b.is_penalty === true;
				const isBonus = /bonus/i.test(b.factor || '');
				const cls2 = isBonus ? 'cs2ps-positive' : isPenalty ? 'cs2ps-negative' : '';
				const sign = isBonus && value > 0 ? '+' : '';
				return `
					<span class="cs2ps-bd-trust-factor">
						${escapeHtml(b.factor || '')} <span class="${cls2}">${sign}${formatMetric(value, 1)}%</span>
					</span>
				`;
			}).join('');
			items.push(`<div class="cs2ps-bd-trust-factors">${factors}</div>`);
		} else {
			const crDetails = [
				t.csrep_statistical !== undefined ? `Statistical: ${formatMetric(t.csrep_statistical, 1)}%` : '',
				t.csrep_account_flags !== undefined ? `Flags: ${formatMetric(t.csrep_account_flags, 1)}%` : '',
				t.csrep_anomalies !== undefined ? `Anomalies: ${formatMetric(t.csrep_anomalies, 1)}%` : '',
				t.csrep_account_bonus !== undefined ? `Bonus: +${formatMetric(t.csrep_account_bonus, 2)}%` : '',
			].filter(Boolean).join(' · ');
			if (crDetails) items.push(`<div class="cs2ps-bd-trust-detail">${escapeHtml(crDetails)}</div>`);
		}
	}

	if (t.has_ban) {
		items.push(`<div class="cs2ps-bd-trust-ban">⚠️ This player has a ban on record</div>`);
	}

	if (!items.length) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Trust & Reputation</div>
			<div class="cs2ps-bd-trust">${items.join('')}</div>
		</div>
	`;
};

// ── Section: Leetify ratings ────────────────────────────────────────

const renderLeetifyRatings = (profile: AggregatedProfile): string => {
	const lr = profile.leetify_rating ?? {};
	const items = [
		bdStat('Aim', lr.aim, (v) => formatMetric(v, 1)),
		bdStat('Positioning', lr.positioning, (v) => formatMetric(v, 1)),
		bdStat('Utility', lr.utility, (v) => formatMetric(v, 1)),
		bdStat('Clutch', lr.clutch, (v) => `${v > 0 ? '+' : ''}${formatMetric(v, 2)}`),
		bdStat('Opening', lr.opening, (v) => `${v > 0 ? '+' : ''}${formatMetric(v, 2)}`),
	].filter(Boolean).join('');

	if (!items) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Leetify Ratings</div>
			<div class="cs2ps-bd-grid">${items}</div>
		</div>
	`;
};

// ── Section: Ranks ──────────────────────────────────────────────────

const renderRanks = (profile: AggregatedProfile): string => {
	const ranks = profile.ranks ?? {};
	const items = [
		bdStat('Premier', ranks.premier, (v) => formatInteger(v)),
		bdStat('FACEIT Level', ranks.faceit, (v) => formatInteger(v)),
		bdStat('FACEIT ELO', ranks.faceit_elo, (v) => formatInteger(v)),
		bdStat('Leetify', ranks.leetify, (v) => `${v > 0 ? '+' : ''}${formatMetric(v, 2)}`),
	].filter(Boolean).join('');

	if (!items) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Ranks</div>
			<div class="cs2ps-bd-grid">${items}</div>
		</div>
	`;
};

// ── Section: Aim & reactions ────────────────────────────────────────

const renderAimSection = (profile: AggregatedProfile): string => {
	const s = profile.stats ?? {};
	const items = [
		bdStat('Preaim', s.preaim, (v) => `${formatMetric(v, 1)}°`),
		bdStat('Aim Offset', s.aim_offset, (v) => `${formatMetric(v, 1)}°`),
		bdStat('Spray Accuracy', s.spray_accuracy, (v) => formatPercent(v)),
		bdStat('Counter-strafing', s.counter_strafing, (v) => formatPercent(v)),
		bdStat('Reaction Time', s.reaction_time_ms, (v) => formatMilliseconds(v)),
		bdStat('Head Accuracy', s.head_accuracy, (v) => formatPercent(v)),
		bdStat('TTD', s.ttd, (v) => `${formatInteger(v)} ms`),
		bdStat('Spot→Damage', s.spot_to_damage, (v) => `${formatInteger(v)} ms`),
		bdStat('Spot→Kill', s.spot_to_kill, (v) => `${formatInteger(v)} ms`),
		bdStat('First Kills', s.first_kills, (v) => formatInteger(v)),
		bdStat('Trade Kills', s.trade_kills, (v) => formatInteger(v)),
		bdStat('Accuracy', s.accuracy, (v) => formatPercent(v)),
	].filter(Boolean).join('');

	if (!items) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Aim & Reactions</div>
			<div class="cs2ps-bd-grid">${items}</div>
		</div>
	`;
};

// ── Bar-row sections (clutch & entry share the clutch layout) ───────

/**
 * Horizontal stat bar row in the clutch layout: label, bar, record,
 * percentage, 1-in-X odds, and source badges. Used by both the clutch
 * and entry sections so they display identically.
 */
const statBarRow = (opts: {
	label: string;
	pct: number;
	record: string;
	oneInX: string;
	sources: string[];
	hover: string;
}): string => {
	const height = Math.min(100, Math.max(5, opts.pct));
	const color = opts.pct >= 50 ? '#22c55e' : opts.pct >= 30 ? '#eab308' : '#ef4444';
	return `
		<div class="cs2ps-bd-clutch-row"${tip(opts.hover)}>
			<span class="cs2ps-bd-clutch-label">${escapeHtml(opts.label)}</span>
			<div class="cs2ps-bd-clutch-bar-wrap">
				<div class="cs2ps-bd-clutch-bar" style="width:${height}%;background:${color}"></div>
			</div>
			<span class="cs2ps-bd-clutch-val">${escapeHtml(opts.record)}</span>
			<span class="cs2ps-bd-clutch-pct">${formatPercent(opts.pct)}</span>
			<span class="cs2ps-bd-clutch-one">${escapeHtml(opts.oneInX)}</span>
			<span class="cs2ps-bd-clutch-src">${srcBadges(opts.sources)}</span>
		</div>
	`;
};

// ── Section: Clutch ─────────────────────────────────────────────────

const renderClutchSection = (profile: AggregatedProfile): string => {
	const clutch = asArray<AggregatedProfile['clutch'][number]>(profile.clutch);
	if (clutch.length === 0) return '';

	const bars = clutch
		.map((c) =>
			statBarRow({
				label: c.label,
				pct: c.winrate,
				record: `${formatInteger(c.wins)}W / ${formatInteger(c.losses)}L`,
				oneInX: formatOneInX(c.wins, c.losses),
				sources: c.sources,
				hover: clutchBreakdownTip(c),
			}),
		)
		.join('');

	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Clutch Performance</div>
			<div class="cs2ps-bd-clutch">${bars}</div>
		</div>
	`;
};

// ── Section: Entry ──────────────────────────────────────────────────

const renderEntrySection = (profile: AggregatedProfile): string => {
	const rows = asArray<AggregatedProfile['entry'][number]>(profile.entry);
	if (rows.length === 0) return '';

	const bars = rows
		.map((r) => {
			const fk = r.first_kills;
			const fd = r.first_deaths;
			return statBarRow({
				label: r.label,
				pct: r.success_pct ?? 0,
				record: fk !== undefined && fd !== undefined ? `${formatInteger(fk)} FK / ${formatInteger(fd)} FD` : '',
				oneInX: formatOneInX(fk, fd),
				sources: r.sources,
				hover: entryBreakdownTip(r),
			});
		})
		.join('');

	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Entry Success</div>
			<div class="cs2ps-bd-clutch">${bars}</div>
		</div>
	`;
};

// ── Section: Multi-kills ───────────────────────────────────────────

const renderMultiKillsSection = (profile: AggregatedProfile): string => {
	const mk = profile.multi_kills ?? {};
	const items = [
		bdStat('Double Kill', mk.double, (v) => formatInteger(v)),
		bdStat('Triple Kill', mk.triple, (v) => formatInteger(v)),
		bdStat('Quad Kill', mk.quad, (v) => formatInteger(v)),
		bdStat('Penta Kill', mk.penta, (v) => formatInteger(v)),
	].filter(Boolean).join('');

	if (!items) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Multi-Kills</div>
			<div class="cs2ps-bd-grid">${items}</div>
		</div>
	`;
};

// ── Section: Kill breakdown ─────────────────────────────────────────

const renderKillBreakdown = (profile: AggregatedProfile): string => {
	const kb = profile.kill_breakdown ?? {};
	const items: string[] = [];

	for (const [key, entry] of Object.entries(kb)) {
		if (entry && entry.value) {
			const e = entry.value as { percentage?: number; count?: number; total?: number };
			const label = key.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
			const pct = e.percentage !== undefined ? formatPercent(e.percentage) : '';
			const count = e.count !== undefined ? `${formatInteger(e.count)}/${formatInteger(e.total)}` : '';
			items.push(`
				<div class="cs2ps-bd-kb-item">
					<span class="cs2ps-bd-kb-label">${escapeHtml(label)}</span>
					<span class="cs2ps-bd-kb-val">${escapeHtml(pct)}</span>
					<span class="cs2ps-bd-kb-count">${escapeHtml(count)}</span>
					<span class="cs2ps-bd-kb-src">${srcBadges(entry.sources)}</span>
				</div>
			`);
		}
	}

	if (!items.length) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Kill Breakdown</div>
			<div class="cs2ps-bd-kb">${items.join('')}</div>
		</div>
	`;
};

// ── Section: Utility ────────────────────────────────────────────────

const renderUtilitySection = (profile: AggregatedProfile): string => {
	const u = profile.utility ?? {};
	const items = [
		bdStat('Grenade Throws', u.grenade_throws, (v) => formatInteger(v)),
		bdStat('Flash Assists', u.flash_assists, (v) => formatInteger(v)),
		bdStat('Enemies Flashed/Flash', u.enemies_flashed_per_flash, (v) => formatMetric(v, 2)),
		bdStat('Avg Flash Duration', u.avg_flash_duration, (v) => `${formatMetric(v, 2)}s`),
		bdStat('Util Dmg/Match', u.util_dmg_per_match, (v) => formatMetric(v, 1)),
		bdStat('HE Dmg/Throw', u.he_dmg_per_throw, (v) => formatMetric(v, 1)),
		bdStat('Fire Dmg/Throw', u.fire_dmg_per_throw, (v) => formatMetric(v, 1)),
	].filter(Boolean).join('');

	if (!items) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Utility</div>
			<div class="cs2ps-bd-grid">${items}</div>
		</div>
	`;
};

// ── Section: Behavior ───────────────────────────────────────────────

const renderBehaviorSection = (profile: AggregatedProfile): string => {
	const b = profile.behavior ?? {};
	const items = [
		bdStat('AFK Time/Match', b.afk_time_per_match, (v) => `${formatInteger(v)}s`),
		bdStat('Teamkills/Match', b.teamkills_per_match, (v) => formatMetric(v, 2)),
		bdStat('Team Damage/Match', b.team_damage_per_match, (v) => formatMetric(v, 1)),
		bdStat('Avg Teammates Flashed', b.avg_teammates_flashed, (v) => formatMetric(v, 2)),
		bdStat('Input Automation', b.input_automation, (v) => formatPercent(v)),
		bdStat('Vote Kicked', b.vote_kicked, (v) => formatPercent(v)),
	].filter(Boolean).join('');

	if (!items) return '';
	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Behavior</div>
			<div class="cs2ps-bd-grid">${items}</div>
		</div>
	`;
};

// ── Section: Match history ──────────────────────────────────────────

const renderMatchHistory = (profile: AggregatedProfile): string => {
	const matches = asArray<AggregatedProfile['matches'][number]>(profile.matches);
	if (matches.length === 0) return '';

	const rows = matches.slice(0, 15).map((m) => {
		const outcome = m.outcome?.toLowerCase();
		const cls = outcome === 'win' ? 'cs2ps-bd-match-win' : outcome === 'loss' ? 'cs2ps-bd-match-loss' : 'cs2ps-bd-match-unknown';
		const result = outcome === 'win' ? 'W' : outcome === 'loss' ? 'L' : '•';
		const kd = m.kills !== undefined && m.deaths !== undefined ? `${formatInteger(m.kills)}/${formatInteger(m.deaths)}` : '';

		return `
			<div class="cs2ps-bd-match">
				<span class="cs2ps-bd-match-result ${cls}">${result}</span>
				<span class="cs2ps-bd-match-map">${escapeHtml(formatMapName(m.map_name))}</span>
				<span class="cs2ps-bd-match-score">${escapeHtml(m.score || '—')}</span>
				${kd ? `<span class="cs2ps-bd-match-kd">${escapeHtml(kd)}</span>` : ''}
				${m.adr !== undefined ? `<span class="cs2ps-bd-match-adr">ADR ${formatMetric(m.adr, 0)}</span>` : ''}
				${m.rating !== undefined ? `<span class="cs2ps-bd-match-rating">R ${formatMetric(m.rating, 2)}</span>` : ''}
				<span class="cs2ps-bd-match-src">${srcBadges(m.sources)}</span>
			</div>
		`;
	}).join('');

	return `
		<div class="cs2ps-bd-section">
			<div class="cs2ps-bd-section-title">Match History <span class="cs2ps-bd-section-count">${matches.length} matched</span></div>
			<div class="cs2ps-bd-matches">${rows}</div>
		</div>
	`;
};
