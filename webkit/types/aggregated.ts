/**
 * Unified aggregated data types for CS2 Profile Stats.
 *
 * These types mirror the Lua schema in `providers/aggregated_schema.lua`
 * and represent the merged player profile from all providers.
 */

import { asArray, escapeHtml, formatInteger, formatMetric, formatOneInX, formatPercent } from '../helpers';
import { providerIconImg } from '../icons';

// ── AggValue wrapper ────────────────────────────────────────────────
/**
 * How a single provider contributed to an aggregated value.
 * `weight` is the provider's share of the blend (0–1) for weighted
 * stats, or 0/1 for "primary" picks (ranks, totals). `matches` is how
 * many matches that provider had tracked, which drives the weighting.
 */
export type AggContribution = {
	provider: string;
	value: number;
	weight: number;
	matches?: number;
	is_primary?: boolean;
};

/** A value with attribution to one or more providers. */
export type AggValue<T> = {
	/** The normalized value. */
	value: T;
	/** Provider names that contributed to this value. */
	sources: string[];
	/**
	 * Per-provider breakdown of how each source contributed (value,
	 * weight, matches tracked, primary flag). Optional so profiles
	 * cached before this field existed still render.
	 */
	contributions?: AggContribution[];
};

// ── Aggregated stats ────────────────────────────────────────────────
export type AggregatedStats = {
	kd?: AggValue<number>;
	winrate?: AggValue<number>;
	adr?: AggValue<number>;
	headshot_pct?: AggValue<number>;
	/** Headshots as a share of ALL shots (CSRep metric) — not the same
	 *  denominator as headshot_pct (headshots as a share of kills). */
	head_accuracy?: AggValue<number>;
	hltv_rating?: AggValue<number>;
	kast?: AggValue<number>;
	kills?: AggValue<number>;
	deaths?: AggValue<number>;
	assists?: AggValue<number>;
	total_matches?: AggValue<number>;
	accuracy?: AggValue<number>;
	spray_accuracy?: AggValue<number>;
	preaim?: AggValue<number>;
	aim_offset?: AggValue<number>;
	counter_strafing?: AggValue<number>;
	reaction_time_ms?: AggValue<number>;
	ttd?: AggValue<number>;
	spot_to_damage?: AggValue<number>;
	spot_to_kill?: AggValue<number>;
	first_kills?: AggValue<number>;
	trade_kills?: AggValue<number>;
	enemy_damage?: AggValue<number>;
	bhop_success?: AggValue<number>;
};

// ── Ranks ───────────────────────────────────────────────────────────
export type AggregatedRanks = {
	premier?: AggValue<number>;
	faceit?: AggValue<number>;
	faceit_elo?: AggValue<number>;
	leetify?: AggValue<number>;
};

// ── Utility stats ───────────────────────────────────────────────────
export type AggregatedUtility = {
	grenade_throws?: AggValue<number>;
	flash_assists?: AggValue<number>;
	enemies_flashed_per_flash?: AggValue<number>;
	avg_flash_duration?: AggValue<number>;
	util_dmg_per_match?: AggValue<number>;
	he_dmg_per_throw?: AggValue<number>;
	fire_dmg_per_throw?: AggValue<number>;
	unused_util_on_death?: AggValue<number>;
};

// ── Behavior stats ──────────────────────────────────────────────────
export type AggregatedBehavior = {
	afk_time_per_match?: AggValue<number>;
	teamkills_per_match?: AggValue<number>;
	team_damage_per_match?: AggValue<number>;
	avg_teammates_flashed?: AggValue<number>;
	teammate_flash_duration?: AggValue<number>;
	input_automation?: AggValue<number>;
	vote_kicked?: AggValue<number>;
	team_dmg_kicks?: AggValue<number>;
};

// ── Kill breakdown ──────────────────────────────────────────────────
export type KillBreakdownEntry = {
	percentage?: number;
	count?: number;
	total?: number;
};

export type AggregatedKillBreakdown = {
	wallbangs?: AggValue<KillBreakdownEntry>;
	through_smokes?: AggValue<KillBreakdownEntry>;
	in_air?: AggValue<KillBreakdownEntry>;
	noscope?: AggValue<KillBreakdownEntry>;
	headshots?: AggValue<KillBreakdownEntry>;
};

// ── Clutch performance ──────────────────────────────────────────────
/** One provider's own numbers behind a resolved clutch label. */
export type AggClutchContribution = {
	provider: string;
	wins: number;
	losses: number;
	winrate: number;
	/** Share of the label's combined matches tracked (0–1). */
	weight?: number;
	matches?: number;
	is_primary?: boolean;
};

export type AggregatedClutch = {
	label: string;
	wins: number;
	losses: number;
	winrate: number;
	sources: string[];
	/**
	 * Per-provider numbers behind the resolved values. Optional so
	 * profiles cached before this field existed still render.
	 */
	contributions?: AggClutchContribution[];
};

// ── Entry success (opening duels) ──────────────────────────────────
/** One provider's own numbers behind a resolved entry label. */
export type AggEntryContribution = {
	provider: string;
	success_pct?: number;
	attempts_per_round_pct?: number;
	success_per_round_pct?: number;
	first_kills?: number;
	first_deaths?: number;
	/** Share of the label's combined matches tracked (0–1). */
	weight?: number;
	matches?: number;
	is_primary?: boolean;
};

/** One row of entry-duel performance: Combined, T side, or CT side. */
export type AggregatedEntry = {
	label: string;
	/** Share of entry duels won (first kill vs first death), 0–100. */
	success_pct?: number;
	/** Entry duels attempted per round played, 0–100. */
	attempts_per_round_pct?: number;
	/** Entry duels won per round played, 0–100. */
	success_per_round_pct?: number;
	first_kills?: number;
	first_deaths?: number;
	sources: string[];
	/**
	 * Per-provider numbers behind the resolved values. Optional so
	 * profiles cached before this field existed still render.
	 */
	contributions?: AggEntryContribution[];
};

// ── Multi-kills (rounds with N kills) ───────────────────────────────
export type AggregatedMultiKills = {
	double?: AggValue<number>;
	triple?: AggValue<number>;
	quad?: AggValue<number>;
	penta?: AggValue<number>;
};

// ── Leetify ratings ─────────────────────────────────────────────────
export type AggregatedLeetifyRating = {
	aim?: AggValue<number>;
	positioning?: AggValue<number>;
	utility?: AggValue<number>;
	clutch?: AggValue<number>;
	opening?: AggValue<number>;
};

// ── Trust / reputation ──────────────────────────────────────────────
/** A single reason a trust score deviates from 100. */
export type TrustBreakdownEntry = {
	/** Human-readable factor name (e.g. "Teammates", "Account Flags"). */
	factor?: string;
	/** CSTracker: signed percentage delta. CSRep: component trust % (0-100). */
	delta?: number;
	value?: number;
	/** CSRep only — true when the component holds the score below 100. */
	is_penalty?: boolean;
};

export type AggregatedTrust = {
	cstracker_rating?: number;
	cstracker_breakdown?: TrustBreakdownEntry[];
	/** CSRep overall trust score (0-100). */
	csrep_score?: number;
	csrep_label?: string;
	/** CSRep components normalized to 0-100 (trust %; bonus is +percentage points). */
	csrep_statistical?: number;
	csrep_account_flags?: number;
	csrep_anomalies?: number;
	csrep_account_bonus?: number;
	/** Structured CSRep trust components (statistical, flags, anomalies, bonus). */
	csrep_breakdown?: TrustBreakdownEntry[];
	has_ban: boolean;
	bans: unknown[];
};

// ── Provider-specific extensions ────────────────────────────────────
/** Raw Leetify data kept for deep-dive views. */
export type ProviderLeetifyExt = {
	name?: string;
	steam64_id?: string;
	winrate?: number;
	total_matches?: number;
	ranks?: { premier?: number; faceit?: number; faceit_elo?: number; leetify?: number };
	rating?: { aim?: number; positioning?: number; utility?: number; clutch?: number; opening?: number };
	stats?: { kd?: number; reaction_time_ms?: number; preaim?: number; spray_accuracy?: number; counter_strafing?: number };
	recent_matches?: Array<{ outcome?: string; map_name?: string; finished_at?: string; score?: number[]; data_source?: string }>;
};

/** Raw FACEIT data kept for deep-dive views. */
export type ProviderFaceitExt = {
	nickname?: string;
	country?: string;
	player_id?: string;
	level?: number;
	elo?: number;
	region?: string;
	stats?: { matches?: string; kd?: string; adr?: string; headshots?: string; winrate?: string; recent_results?: string[] };
};

/** CSTracker extras kept for deep-dive views. */
export type ProviderCstrackerExt = {
	premier?: number;
	faceit_level?: number;
	faceit_elo?: number;
	match_history?: Array<{
		outcome?: string;
		map_name?: string;
		score?: string;
		kills?: number;
		deaths?: number;
		assists?: number;
		kd?: number;
		adr?: number;
		rating?: number;
		kast?: number;
		accuracy?: number;
		preaim?: number;
		ttd?: number;
		when_text?: string;
		match_link?: string;
	}>;
	map_performance?: Array<{
		map_name?: string;
		matches?: number;
		wins?: number;
		losses?: number;
		ties?: number;
		winrate?: number;
	}>;
	teammates?: Array<{
		name?: string;
		steam64_id?: string;
		matches_together?: number;
		wins?: number;
		losses?: number;
		winrate?: number;
		kd?: number;
		rating?: number;
		adr?: number;
	}>;
};

/** CSRep extras kept for deep-dive views. */
export type ProviderCsrepExt = {
	commendations?: { leader?: number; friendly?: number; teaching?: number };
	medals?: unknown;
	crosshairs?: unknown[];
	performance_trend?: unknown;
	ranks?: Record<string, { current?: number; peak?: number; wins?: number; losses?: number; matches?: number }>;
	faceit_id?: string;
	steam_level?: number;
	cs2_hours?: number;
	inventory_value?: number;
};

/** CSStats extras kept for deep-dive views. */
export type ProviderCsstatsExt = {
	recent_matches?: Array<{
		outcome?: string;
		map_name?: string;
		score?: number[];
		finished_at?: number;
		kills?: number;
		deaths?: number;
		assists?: number;
		kd?: number;
		adr?: number;
		rating?: number;
		hs?: number;
		data_source?: string;
	}>;
	damage?: number;
	rounds?: number;
	entry?: {
		success_pct?: number;
		attempts_per_round_pct?: number;
		success_per_round_pct?: number;
		first_kills?: number;
		first_deaths?: number;
		t?: { success_pct?: number; attempts_per_round_pct?: number; first_kills?: number; first_deaths?: number };
		ct?: { success_pct?: number; attempts_per_round_pct?: number; first_kills?: number; first_deaths?: number };
	};
	clutch_1vX?: number;
	multi_kills?: { triple?: number; quad?: number; penta?: number };
	last_match_at?: number;
	extras?: {
		ct_rounds?: number;
		t_rounds?: number;
		kast_rounds?: number;
		comp_wins?: number;
		adr_reported?: number;
		best?: Record<string, number>;
		past10?: Array<Record<string, unknown>>;
		weapons?: Array<{
			name?: string;
			kills?: number;
			headshots?: number;
			hs_pct?: number;
			shots?: number;
			hits?: number;
			accuracy?: number;
			damage?: number;
		}>;
		maps?: Array<{
			map?: string;
			played?: number;
			won?: number;
			winrate?: number;
			kills?: number;
			deaths?: number;
			kd?: number;
			avg_adr?: number;
			avg_rating?: number;
			kast?: number;
			rounds?: number;
		}>;
	};
};

// ── Cross-provider matched match ────────────────────────────────────
export type UnifiedMatch = {
	map_name?: string;
	score?: string;
	outcome?: string;
	finished_at?: string;
	kills?: number;
	deaths?: number;
	assists?: number;
	kd?: number;
	adr?: number;
	rating?: number;
	kast?: number;
	accuracy?: number;
	preaim?: number;
	ttd?: number;
	/** Provider names that contributed data for this match. */
	sources: string[];
};

// ── Aggregated profile (top-level) ──────────────────────────────────
export type AggregatedProfile = {
	steam64_id?: string;
	name?: string;

	stats: AggregatedStats;
	ranks: AggregatedRanks;
	utility: AggregatedUtility;
	behavior: AggregatedBehavior;
	kill_breakdown: AggregatedKillBreakdown;
	multi_kills: AggregatedMultiKills;
	clutch: AggregatedClutch[];
	entry: AggregatedEntry[];
	leetify_rating: AggregatedLeetifyRating;
	trust: AggregatedTrust;

	provider_data: {
		leetify?: ProviderLeetifyExt;
		faceit?: ProviderFaceitExt;
		cstracker?: ProviderCstrackerExt;
		csrep?: ProviderCsrepExt;
		csstats?: ProviderCsstatsExt;
	};

	matches: UnifiedMatch[];

	provider_count: number;
	providers_used: string[];
	aggregated_at?: number;
};

// ── IPC response wrapper ────────────────────────────────────────────
export type AggregatedResponse = {
	status: 'ok' | 'error' | 'loading';
	message?: string;
	data?: AggregatedProfile;
	fetched_at?: number;
};

// ── Provider badge info ─────────────────────────────────────────────
export const PROVIDER_META: Record<string, { label: string; icon: string; color: string }> = {
	leetify: { label: 'Leetify', icon: '📊', color: '#66c0f4' },
	faceit: { label: 'FACEIT', icon: '🔴', color: '#ff5500' },
	cstracker: { label: 'CSTracker', icon: '🎯', color: '#10b981' },
	csrep: { label: 'CSRep', icon: '🛡️', color: '#8b5cf6' },
	csstats: { label: 'CSStats', icon: '📈', color: '#f59e0b' },
};

/**
 * Get the display name for a provider key.
 */
export const providerLabel = (key: string): string => PROVIDER_META[key]?.label ?? key;

/**
 * Get the badge HTML for a list of provider source names.
 * Non-array values (stale cache payloads) degrade to no badges.
 */
export const sourceBadges = (sources: string[] | undefined): string =>
	asArray<string>(sources)
		.map((s) => {
			const meta = PROVIDER_META[s];
			if (!meta) return `<span class="cs2ps-src-badge cs2ps-src-default">${escapeHtml(s)}</span>`;
			return `<span class="cs2ps-src-badge" style="--src-color:${meta.color}">${meta.icon} ${escapeHtml(meta.label)}</span>`;
		})
		.join('');

// ── Aggregation breakdown tooltips ─────────────────────────────────

/** Render a provider name with its inline icon for tooltip rows. */
const providerTipName = (provider: string): string => {
	const meta = PROVIDER_META[provider];
	// providerIconImg already returns full <img> markup — inject the
	// sizing class into the tag instead of re-wrapping it in another
	// <img src="..."> (which would nest quotes and leak `alt="">` text).
	const icon = providerIconImg(provider);
	const iconHtml = icon
		? icon.replace('<img ', '<img class="cs2ps-tip-prov-icon" ')
		: meta
			? `<span class="cs2ps-tip-prov-emoji">${meta.icon}</span>`
			: '';
	return `${iconHtml}<span class="cs2ps-tip-prov-name">${escapeHtml(meta?.label ?? provider)}</span>`;
};

/**
 * Human-readable explanations for each aggregated stat, shown under the
 * stat name in hover tooltips. Keys are the normalized labels produced
 * from every display label used by the banner dropdown and the breakdown
 * panel (lowercased, non-alphanumerics stripped).
 */
const STAT_DESCRIPTIONS: Record<string, string> = {
	kd: 'Kills per death — above 1.0 means more kills than deaths.',
	winrate: 'Share of tracked matches that ended in a win.',
	adr: 'Average damage dealt per round.',
	hs: 'Percentage of kills landed as headshots.',
	headshot: 'Percentage of kills landed as headshots.',
	headaccuracy: 'Percentage of ALL shots that landed on the head (CSRep metric) — a different denominator from HS%, which counts headshots out of kills.',
	headacc: 'Percentage of ALL shots that landed on the head (CSRep metric) — a different denominator from HS%, which counts headshots out of kills.',
	hltv: 'HLTV 2.0 rating — composite performance score, ~1.00 is average.',
	hltvrating: 'HLTV 2.0 rating — composite performance score, ~1.00 is average.',
	kast: 'Rounds with a kill, assist, survival, or trade — round impact.',
	games: 'Total matches the contributing providers have tracked.',
	totalmatches: 'Total matches the contributing providers have tracked.',
	kills: 'Total kills across tracked matches.',
	deaths: 'Total deaths across tracked matches.',
	assists: 'Total assists across tracked matches.',
	aim: 'Leetify aim rating (0–100) — crosshair placement and recoil control.',
	position: 'Leetify positioning rating (0–100) — positioning discipline.',
	positioning: 'Leetify positioning rating (0–100) — positioning discipline.',
	utility: 'Leetify utility rating (0–100) — grenade usage effectiveness.',
	clutch: 'Leetify clutch rating (−10 to +10) — performance in 1vX situations.',
	opening: 'Leetify opening rating (−10 to +10) — performance in opening duels.',
	premier: 'CS2 Premier rating points — in-game competitive rank.',
	faceitlevel: 'FACEIT competition level (1–10).',
	faceitelo: 'FACEIT Elo — rating points in FACEIT\'s ladder.',
	leetify: 'Leetify skill rating (−10 to +10).',
	preaim: 'Average angle between crosshair and enemy at first contact (degrees).',
	aimoffset: 'Average crosshair offset from ideal placement (degrees).',
	sprayaccuracy: 'Percentage of spray bullets that hit their target.',
	counterstrafing: 'Percentage of counter-strafes timed correctly.',
	reactiontime: 'Median time from target appearing to firing (milliseconds).',
	ttd: 'Median time from spotting an enemy to dealing damage (milliseconds).',
	spotdamage: 'Median time from spotting an enemy to dealing damage (milliseconds).',
	spotkill: 'Median time from spotting an enemy to securing the kill (milliseconds).',
	firstkills: 'Total opening kills — the first kill of a round.',
	tradekills: 'Total trade kills — kills that avenge a dead teammate.',
	accuracy: 'Percentage of shots that hit their target.',
	doublekills: 'Rounds with two kills (double kill).',
	triplekills: 'Rounds with three kills (triple kill).',
	quadkills: 'Rounds with four kills (quad kill).',
	pentakills: 'Rounds with five kills — aces, the entire enemy team.',
	entrysuccess: 'Share of entry duels (first kill vs first death) that were won.',
	entryattemptsperround: 'Entry duels attempted per round played.',
	entrysuccessperround: 'Entry duels won per round played.',
	firstdeaths: 'Deaths where the enemy secured the first kill of the round.',
};

/** Normalize a display label to a STAT_DESCRIPTIONS key. */
const statDescriptionKey = (label: string): string =>
	label.toLowerCase().replace(/[^a-z0-9]/g, '');

/** Look up the explanation for a stat label, if one is known. */
const statDescription = (label: string): string | undefined =>
	STAT_DESCRIPTIONS[statDescriptionKey(label)];

/**
 * Build the hover tooltip for an aggregated numeric value, showing each
 * provider's own value, its weight in the blend, and how many matches it
 * had tracked. Falls back to a plain source list for profiles cached
 * before per-provider contributions existed.
 */
export const aggBreakdownTip = (
	label: string,
	agg: AggValue<number> | undefined,
	options?: { digits?: number; suffix?: string },
): string => {
	if (!agg) return escapeHtml(label);
	const digits = options?.digits ?? 2;
	const suffix = options?.suffix ?? '';
	const fmt = (v: number) => `${v.toFixed(digits)}${suffix}`;

	const contributions: AggContribution[] =
		Array.isArray(agg.contributions) && agg.contributions.length > 0
			? agg.contributions
			: asArray<string>(agg.sources).map((s) => ({ provider: s, value: agg.value, weight: 1, is_primary: true }));

	// A weighted blend has fractional weights; a primary pick is 0/1.
	const weighted = contributions.some((c) => c.weight > 0 && c.weight < 1);
	const method = weighted ? 'Weighted by matches tracked' : 'Provider with most matches tracked';

	const rows = [...contributions]
		.sort((a, b) => (b.weight ?? 0) - (a.weight ?? 0))
		.map((c) => {
			const weightPct = Math.round((c.weight ?? 0) * 100);
			const weightTag =
				weighted && weightPct > 0
					? ` <span class="cs2ps-tip-weight">${weightPct}%</span>`
					: '';
			const matchesTag =
				c.matches !== undefined && c.matches > 0
					? ` <span class="cs2ps-tip-sub">${formatMetric(c.matches, 0)} matches</span>`
					: '';
			const primaryTag = c.is_primary && !weighted ? ' <span class="cs2ps-tip-primary">★</span>' : '';
			return (
				`<div class="cs2ps-tip-row">` +
				`<span class="cs2ps-tip-key cs2ps-tip-prov">${providerTipName(c.provider)}${primaryTag}</span>` +
				`<span class="cs2ps-tip-val">${escapeHtml(fmt(c.value))}${weightTag}${matchesTag}</span>` +
				`</div>`
			);
		})
		.join('');

	const desc = statDescription(label);
	return (
		`<div class="cs2ps-tip-head">${escapeHtml(label)}</div>` +
		(desc ? `<div class="cs2ps-tip-desc">${escapeHtml(desc)}</div>` : '') +
		`<div class="cs2ps-tip-method">${escapeHtml(method)}</div>` +
		rows
	);
};

/**
 * Full hover tooltip for a clutch label: resolved winrate/record plus a
 * per-provider contribution breakdown mirroring aggBreakdownTip. Falls
 * back to a plain source list for profiles cached before contributions
 * existed.
 */
export const clutchBreakdownTip = (c: AggregatedClutch): string => {
	const color = c.winrate >= 50 ? '#22c55e' : c.winrate >= 30 ? '#eab308' : '#ef4444';
	const contributions: AggClutchContribution[] =
		Array.isArray(c.contributions) && c.contributions.length > 0
			? c.contributions
			: asArray<string>(c.sources).map((s) => ({ provider: s, wins: c.wins, losses: c.losses, winrate: c.winrate, weight: 1, is_primary: true }));

	const weighted = contributions.some((x) => (x.weight ?? 0) > 0 && (x.weight ?? 0) < 1);
	const method = weighted ? 'Weighted by matches tracked' : 'Provider with most matches tracked';

	const rows = [...contributions]
		.sort((a, b) => (b.weight ?? 0) - (a.weight ?? 0))
		.map((x) => {
			const weightPct = Math.round((x.weight ?? 0) * 100);
			const weightTag = weighted && weightPct > 0 ? ` <span class="cs2ps-tip-weight">${weightPct}%</span>` : '';
			const matchesTag =
				x.matches !== undefined && x.matches > 0
					? ` <span class="cs2ps-tip-sub">${formatMetric(x.matches, 0)} matches</span>`
					: '';
			const primaryTag = x.is_primary && !weighted ? ' <span class="cs2ps-tip-primary">★</span>' : '';
			const xColor = x.winrate >= 50 ? '#22c55e' : x.winrate >= 30 ? '#eab308' : '#ef4444';
			return (
				`<div class="cs2ps-tip-row">` +
				`<span class="cs2ps-tip-key cs2ps-tip-prov">${providerTipName(x.provider)}${primaryTag}</span>` +
				`<span class="cs2ps-tip-val" style="color:${xColor}">${formatPercent(x.winrate)} · ${formatInteger(x.wins)}W/${formatInteger(x.losses)}L${weightTag}${matchesTag}</span>` +
				`</div>`
			);
		})
		.join('');

	return (
		`<div class="cs2ps-tip-head">Clutch ${escapeHtml(c.label)}</div>` +
		`<div class="cs2ps-tip-desc">Rounds where this player was the last one alive against ${escapeHtml(c.label.replace('1v', ''))} opponent(s).</div>` +
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Winrate</span><span class="cs2ps-tip-val" style="color:${color}">${formatPercent(c.winrate)}</span></div>` +
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Record</span><span class="cs2ps-tip-val">${formatInteger(c.wins)}W / ${formatInteger(c.losses)}L</span></div>` +
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">1 in X</span><span class="cs2ps-tip-val">${escapeHtml(formatOneInX(c.wins, c.losses))}</span></div>` +
		`<div class="cs2ps-tip-method">${escapeHtml(method)}</div>` +
		rows
	);
};

/**
 * Full hover tooltip for an entry label, mirroring clutchBreakdownTip:
 * resolved success rate, record, 1-in-X odds, per-round figures, and a
 * per-provider contribution breakdown. Falls back to a plain source list
 * for profiles cached before contributions existed.
 */
export const entryBreakdownTip = (r: AggregatedEntry): string => {
	const pct = r.success_pct ?? 0;
	const color = pct >= 50 ? '#22c55e' : pct >= 30 ? '#eab308' : '#ef4444';
	const contributions: AggEntryContribution[] =
		Array.isArray(r.contributions) && r.contributions.length > 0
			? r.contributions
			: asArray<string>(r.sources).map((s) => ({ provider: s, success_pct: r.success_pct, weight: 1, is_primary: true }));

	const weighted = contributions.some((x) => (x.weight ?? 0) > 0 && (x.weight ?? 0) < 1);
	const method = weighted ? 'Weighted by matches tracked' : 'Provider with most matches tracked';

	const rows = [...contributions]
		.sort((a, b) => (b.weight ?? 0) - (a.weight ?? 0))
		.map((x) => {
			const weightPct = Math.round((x.weight ?? 0) * 100);
			const weightTag = weighted && weightPct > 0 ? ` <span class="cs2ps-tip-weight">${weightPct}%</span>` : '';
			const matchesTag =
				x.matches !== undefined && x.matches > 0
					? ` <span class="cs2ps-tip-sub">${formatMetric(x.matches, 0)} matches</span>`
					: '';
			const primaryTag = x.is_primary && !weighted ? ' <span class="cs2ps-tip-primary">★</span>' : '';
			const sp = x.success_pct ?? 0;
			const xColor = sp >= 50 ? '#22c55e' : sp >= 30 ? '#eab308' : '#ef4444';
			return (
				`<div class="cs2ps-tip-row">` +
				`<span class="cs2ps-tip-key cs2ps-tip-prov">${providerTipName(x.provider)}${primaryTag}</span>` +
				`<span class="cs2ps-tip-val" style="color:${xColor}">${formatPercent(sp)}${weightTag}${matchesTag}</span>` +
				`</div>`
			);
		})
		.join('');

	const detailRows = [
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Success</span><span class="cs2ps-tip-val" style="color:${color}">${formatPercent(pct)}</span></div>`,
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Record</span><span class="cs2ps-tip-val">${r.first_kills !== undefined && r.first_deaths !== undefined ? `${formatInteger(r.first_kills)} FK / ${formatInteger(r.first_deaths)} FD` : '—'}</span></div>`,
		`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">1 in X</span><span class="cs2ps-tip-val">${escapeHtml(formatOneInX(r.first_kills, r.first_deaths))}</span></div>`,
	];
	if (r.attempts_per_round_pct !== undefined) {
		detailRows.push(`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Attempts / Round</span><span class="cs2ps-tip-val">${formatPercent(r.attempts_per_round_pct)}</span></div>`);
	}
	if (r.success_per_round_pct !== undefined) {
		detailRows.push(`<div class="cs2ps-tip-row"><span class="cs2ps-tip-key">Success / Round</span><span class="cs2ps-tip-val">${formatPercent(r.success_per_round_pct)}</span></div>`);
	}

	return (
		`<div class="cs2ps-tip-head">Entry ${escapeHtml(r.label)}</div>` +
		`<div class="cs2ps-tip-desc">Share of entry duels (first kill vs first death) that were won.</div>` +
		detailRows.join('') +
		`<div class="cs2ps-tip-method">${escapeHtml(method)}</div>` +
		rows
	);
};

/** CSTracker trust reasons as tooltip/dropdown rows (signed % deltas). */
export const cstrackerBreakdownRows = (entries: TrustBreakdownEntry[] | undefined): string => {
	const list = asArray<TrustBreakdownEntry>(entries);
	if (!list.length) return '';
	return list
		.map((b) => {
			const delta = b.delta ?? 0;
			const color = delta >= 0 ? '#10b981' : '#ef4444';
			const sign = delta > 0 ? '+' : '';
			return (
				`<div class="cs2ps-tip-row">` +
				`<span class="cs2ps-tip-key">${escapeHtml(b.factor ?? '')}</span>` +
				`<span class="cs2ps-tip-val" style="color:${color}">${sign}${formatMetric(delta, 1)}%</span>` +
				`</div>`
			);
		})
		.join('');
};

/**
 * CSRep trust reasons as tooltip/dropdown rows. Components are trust
 * percentages on a 0-100 scale (100 = full trust); the account bonus is a
 * positive adjustment in percentage points.
 */
export const csrepBreakdownRows = (entries: TrustBreakdownEntry[] | undefined): string => {
	const list = asArray<TrustBreakdownEntry>(entries);
	if (!list.length) return '';
	return list
		.map((b) => {
			const value = b.value ?? b.delta ?? 0;
			const isBonus = /bonus/i.test(b.factor ?? '');
			const isPenalty = b.is_penalty === true;
			const color = isBonus ? '#10b981' : isPenalty ? '#ef4444' : '#d6d7d8';
			const sign = isBonus && value > 0 ? '+' : '';
			return (
				`<div class="cs2ps-tip-row">` +
				`<span class="cs2ps-tip-key">${escapeHtml(b.factor ?? '')}</span>` +
				`<span class="cs2ps-tip-val" style="color:${color}">${sign}${formatMetric(value, 1)}%</span>` +
				`</div>`
			);
		})
		.join('');
};
