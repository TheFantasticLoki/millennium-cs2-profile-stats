import { callable, constSysfsExpr, Millennium } from '@steambrew/webkit';
import type { AggregatedProfile, AggregatedResponse, AggContribution, AggValue, UnifiedMatch } from './types/aggregated';
import { renderLoadingSegments, renderOverviewBanner, type LoadSegment } from './components/OverviewBanner';
import { renderBreakdown } from './components/BreakdownView';
import { installTooltips, tip } from './tooltip';
import {
	asArray,
	escapeHtml,
	finiteNumber,
	formatInteger,
	formatMetric,
	formatWinrate,
	formatPercent,
	formatUsd,
	hasValue,
	formatSignedMetric,
	formatMapName,
	formatMatchDate,
	formatDataSource,
	formatScore,
} from './helpers';

const styles = constSysfsExpr('cs2-profile-stats.css', {
	basePath: '../static',
	encoding: 'utf8',
}).content;

const leetifyBadge = `data:image/png;base64,${
	constSysfsExpr('leetify-badge-white-small.png', {
		basePath: '../static/assets/leetify',
		encoding: 'base64',
	}).content
}`;

type ProviderStatus = 'loading' | 'ok' | 'not_found' | 'private' | 'unauthorized' | 'rate_limited' | 'cloudflare_required' | 'error';

type ProviderResponse<T> = {
	status: ProviderStatus;
	message?: string;
	url?: string;
	data?: T;
	fetched_at?: number;
	/** Set once the soft threshold passes — the response is still awaited;
	 *  this only flags that the provider is slow (the backend Lua VM
	 *  fetches providers serially, so later ones routinely exceed it). */
	slow?: boolean;
};

type LeetifyProfile = {
	name?: string;
	steam64_id: string;
	profile_id?: string;
	privacy_mode?: string;
	winrate?: number;
	total_matches?: number;
	first_match_date?: string;
	ranks: {
		premier?: number;
		faceit?: number;
		faceit_elo?: number;
		leetify?: number;
	};
	rating: {
		aim?: number;
		positioning?: number;
		utility?: number;
		clutch?: number;
		opening?: number;
	};
	stats: {
		kd?: number;
		kd_matches?: number;
		reaction_time_ms?: number;
		damage_time_min_ms?: number;
		damage_time_max_ms?: number;
		damage_time_source_url?: string;
		preaim?: number;
		spray_accuracy?: number;
		counter_strafing?: number;
	};
	recent_matches: Array<{
		outcome?: string;
		map_name?: string;
		finished_at?: string;
		score?: number[];
		data_source?: string;
	}>;
};

type FaceitProfile = {
	nickname?: string;
	country?: string;
	player_id?: string;
	level?: number;
	elo?: number;
	region?: string;
	stats: {
		matches?: string;
		kd?: string;
		adr?: string;
		headshots?: string;
		winrate?: string;
		recent_results: string[];
	};
};

type SteamProfile = {
	status: ProviderStatus;
	message?: string;
	steamId: string;
	memberSince?: string;
	hours?: string;
	recentHours?: string;
};

type InventoryState = {
	status: 'idle' | 'loading' | 'ok' | 'private' | 'too_large' | 'error';
	valueUsd?: number;
	totalItems?: number;
	marketableItems?: number;
	pricedItems?: number;
	message?: string;
};

type Preferences = {
	show_steam_details: boolean;
	expand_details: boolean;
};

type DetailTab = 'overview' | 'matches' | 'faceit' | 'steam' | 'trust' | 'providers' | 'breakdown';

// ── New provider types ────────────────────────────────────────────────

type CstrackerKillBreakdown = {
	percentage?: number;
	count?: number;
	total?: number;
};

type CstrackerClutch = {
	label?: string;
	wins?: number;
	losses?: number;
	winrate?: number;
};

type CstrackerMapPerformance = {
	map_name?: string;
	matches?: number;
	wins?: number;
	losses?: number;
	ties?: number;
	winrate?: number;
	kd?: string;
	adr?: string;
	rating?: string;
	ttd?: string;
	kast?: string;
	preaim?: string;
};

type CstrackerMatchHistory = {
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
	data_source?: string;
};

type CstrackerTeammate = {
	name?: string;
	steam64_id?: string;
	matches_together?: number;
	wins?: number;
	losses?: number;
	winrate?: number;
	kd?: number;
	rating?: number;
	adr?: number;
	last_match_map?: string;
	last_match_score?: string;
	last_match_ago?: string;
};

type CstrackerProfile = {
	name?: string;
	steam64_id: string;
	profile_url?: string;

	// Trust & ban
	trust_rating?: number;
	trust_breakdown?: Array<{ factor?: string; delta?: number }>;
	has_ban?: boolean;

	// Core stats (from stat cards)
	kd?: number;
	adr?: number;
	hltv_rating?: number;
	kast?: number;
	accuracy?: number;
	ttd?: number;
	preaim?: number;
	aim_offset?: number;
	winrate?: number;
	total_matches?: number;

	// Detailed totals
	kills?: number;
	deaths?: number;
	assists?: number;
	hs_kills?: number;
	hs_pct?: number;
	first_kills?: number;
	trade_kills?: number;
	enemy_damage?: number;
	bhop_success?: number;

	// Aim & reactions (detailed)
	spray_accuracy?: number;
	spot_to_damage?: number;
	spot_to_kill?: number;
	counter_strafing?: number;

	// Utility (detailed)
	grenade_throws?: number;
	flash_assists?: number;
	enemies_flashed_per_flash?: number;
	avg_flash_duration?: number;
	util_dmg_per_match?: number;
	he_dmg_per_throw?: number;
	fire_dmg_per_throw?: number;
	unused_util_on_death?: number;

	// Behavior (detailed)
	afk_time_per_match?: number;
	teamkills_per_match?: number;
	team_damage_per_match?: number;
	avg_teammates_flashed?: number;
	teammate_flash_duration?: number;
	input_automation?: number;
	vote_kicked?: number;
	team_dmg_kicks?: number;

	// Kill breakdown
	kill_breakdown?: Record<string, CstrackerKillBreakdown>;

	// Clutch performance
	clutch?: CstrackerClutch[];

	// Map performance
	map_performance?: CstrackerMapPerformance[];

	// Match history
	match_history?: CstrackerMatchHistory[];
	recent_matches?: CstrackerMatchHistory[];

	// Teammates
	teammates?: CstrackerTeammate[];

	// Rank / FACEIT
	premier?: number;
	faceit_level?: number;
	faceit_elo?: number;

	// Legacy compatibility
	hs?: number;
};

type CsrepProfile = {
	steam64_id: string;
	name?: string;
	/** Overall trust score on a 0-100 scale. */
	trust_score?: number;
	trust_label?: string;
	/** Trust components normalized to 0-100 in backend csrep.lua (API sends 0-1). */
	statistical_trust?: number;
	account_flags?: number;
	anomalies?: number;
	/** Bonus adjustment in percentage points (e.g. 1.11 = +1.11%). */
	account_bonus?: number;
	has_ban?: boolean;
	premier?: number;
	faceit_id?: string;
	commendations?: { leader?: number; friendly?: number; teaching?: number };
	profile_url?: string;
	performance?: {
		kd_ratio?: number;
		win_rate?: number;
		kills?: number;
		deaths?: number;
		assists?: number;
		matches_played?: number;
		/** Nested clutch counters (backend csrep.lua builds this table). */
		clutches?: {
			total?: number; won?: number; lost?: number;
			v1?: number; v1_won?: number;
			v2?: number; v2_won?: number;
			v3?: number; v3_won?: number;
			v4?: number; v4_won?: number;
			v5?: number; v5_won?: number;
		};
		multi_kills?: { double?: number; triple?: number; quad?: number; penta?: number };
	};
	stats?: {
		hltv_rating_2?: number;
		adr?: number;
		accuracy_head?: number;
		kast?: number;
	};
};

type CsstatsProfile = {
	name?: string;
	steam64_id: string;
	kd?: number;
	winrate?: number;
	adr?: number;
	hs?: number;
	hltv_rating?: number;
	kast?: number;
	kills?: number;
	deaths?: number;
	assists?: number;
	headshots?: number;
	total_matches?: number;
	wins?: number;
	losses?: number;
	ties?: number;
	damage?: number;
	rounds?: number;
	clutch?: Array<{ label?: string; wins?: number; losses?: number; winrate?: number }>;
	clutch_1vX?: number;
	clutch_1v1?: number;
	clutch_1v2?: number;
	clutch_1v3?: number;
	entry?: {
		success_pct?: number;
		attempts_per_round_pct?: number;
		success_per_round_pct?: number;
		first_kills?: number;
		first_deaths?: number;
		t?: { success_pct?: number; attempts_per_round_pct?: number; first_kills?: number; first_deaths?: number };
		ct?: { success_pct?: number; attempts_per_round_pct?: number; first_kills?: number; first_deaths?: number };
	};
	first_kills?: number;
	multi_kills?: { triple?: number; quad?: number; penta?: number };
	premier?: number;
	last_match_at?: number;
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
	extras?: Record<string, unknown>;
	profile_url?: string;
};

type Cs2trackerProfile = {
	steam64_id: string;
	suspicion_score?: number;
	trust_level?: string;
	is_legit?: boolean;
	is_suspect?: boolean;
	has_ban?: boolean;
	overwatch_status?: string;
	premier?: number;
	profile_url?: string;
};

type TrackerProfile = {
	name?: string;
	steam64_id: string;
	kd?: number;
	winrate?: number;
	adr?: number;
	hs?: number;
	kills?: number;
	total_matches?: number;
	profile_url?: string;
};

// ── End new provider types ────────────────────────────────────────────

type ViewState = {
	leetify: ProviderResponse<LeetifyProfile>;
	faceit: ProviderResponse<FaceitProfile>;
	cstracker: ProviderResponse<CstrackerProfile>;
	csrep: ProviderResponse<CsrepProfile>;
	csstats: ProviderResponse<CsstatsProfile>;
	cs2tracker: ProviderResponse<Cs2trackerProfile>;
	tracker: ProviderResponse<TrackerProfile>;
	steam: SteamProfile;
	inventory: InventoryState;
	preferences: Preferences;
	expanded: boolean;
	activeTab: DetailTab;
	aggregated: AggregatedResponse;
	bannerExpanded: boolean;
	/** Providers participating in this load (registered + enabled on the
	 *  backend), in canonical fetch order. Drives the loading segments. */
	loadProviders: LoadProviderDef[];
};

// Return type is `unknown`: Millennium IPC may deliver an already-parsed
// object or a raw JSON string depending on the transport. parseJson handles both.
const getLeetifyProfile = callable<[{ steamId: string }], unknown>('get_leetify_profile');
const getFaceitProfile = callable<[{ steamId: string }], unknown>('get_faceit_profile');
const getPreferences = callable<[], unknown>('get_preferences');
const getCstrackerProfile = callable<[{ steamId: string }], unknown>('get_cstracker_profile');
const getCsrepProfile = callable<[{ steamId: string }], unknown>('get_csrep_profile');
const getCsstatsProfile = callable<[{ steamId: string }], unknown>('get_csstats_profile');
const getCs2trackerProfile = callable<[{ steamId: string }], unknown>('get_cs2tracker_profile');
const getTrackerProfile = callable<[{ steamId: string }], unknown>('get_tracker_profile');
const getProviderConfigs = callable<[], unknown>('get_provider_configs');

// ── Provider pipeline ───────────────────────────────────────────────

type ProviderKey = 'leetify' | 'faceit' | 'cstracker' | 'csrep' | 'csstats' | 'cs2tracker' | 'tracker';

/**
 * Stable display order for provider segments and fetch fan-out. The
 * backend fetches every provider concurrently in one parallel pump, so
 * responses arrive as each provider completes — typically fast APIs first
 * and FlareSolverr-backed scrapers later — rather than strictly in this
 * order. The loading bar renders one segment per provider and fills each
 * the moment its own response lands.
 */
const PROVIDER_ORDER: ProviderKey[] = ['leetify', 'faceit', 'csrep', 'cstracker', 'csstats', 'cs2tracker', 'tracker'];

/** Fallback set used when the backend provider config can't be read. */
const CORE_PROVIDERS: ProviderKey[] = ['leetify', 'faceit', 'csrep', 'cstracker', 'csstats'];

type LoadProviderDef = { name: ProviderKey; label: string; color: string };

const PROVIDER_DEFS: Record<ProviderKey, LoadProviderDef> = {
	leetify: { name: 'leetify', label: 'Leetify', color: '#66c0f4' },
	faceit: { name: 'faceit', label: 'FACEIT', color: '#ff5500' },
	csrep: { name: 'csrep', label: 'CSRep', color: '#8b5cf6' },
	cstracker: { name: 'cstracker', label: 'CSTracker', color: '#10b981' },
	csstats: { name: 'csstats', label: 'CSStats', color: '#f59e0b' },
	cs2tracker: { name: 'cs2tracker', label: 'CS2Tracker', color: '#94a3b8' },
	tracker: { name: 'tracker', label: 'Tracker.GG', color: '#64748b' },
};

const PROVIDER_REQUESTS: Record<
	ProviderKey,
	{ callable: typeof getLeetifyProfile; parse: (raw: unknown) => ProviderResponse<unknown> }
> = {
	leetify: { callable: getLeetifyProfile, parse: (raw) => parseJson<ProviderResponse<LeetifyProfile>>(raw) },
	faceit: { callable: getFaceitProfile, parse: (raw) => parseJson<ProviderResponse<FaceitProfile>>(raw) },
	csrep: { callable: getCsrepProfile, parse: (raw) => parseJson<ProviderResponse<CsrepProfile>>(raw) },
	cstracker: { callable: getCstrackerProfile, parse: (raw) => parseJson<ProviderResponse<CstrackerProfile>>(raw) },
	csstats: { callable: getCsstatsProfile, parse: (raw) => parseJson<ProviderResponse<CsstatsProfile>>(raw) },
	cs2tracker: { callable: getCs2trackerProfile, parse: (raw) => parseJson<ProviderResponse<Cs2trackerProfile>>(raw) },
	tracker: { callable: getTrackerProfile, parse: (raw) => parseJson<ProviderResponse<TrackerProfile>>(raw) },
};

/** Soft threshold: flag the provider as slow but keep awaiting its response. */
const PROVIDER_SLOW_MS = 15_000;
/** Hard cap: give up only on requests that never settle at all. */
const PROVIDER_HARD_MS = 120_000;
const STEAM_TIMEOUT_MS = 8_000;

const isProfilePage = () =>
	window.location.hostname === 'steamcommunity.com' && /^\/(id|profiles)\/[^/]+\/?$/i.test(window.location.pathname);

const profileBaseUrl = () => {
	const url = new URL(window.location.href);
	url.search = '';
	url.hash = '';
	return url.href.replace(/\/$/, '');
};

function parseJson<T>(raw: unknown): T {
	if (typeof raw === 'string') {
		return JSON.parse(raw) as T;
	}
	if (raw !== null && typeof raw === 'object') {
		// IPC layer may deliver an already-parsed object — not an error.
		return raw as T;
	}
	throw new Error(`Invalid provider response: expected JSON string or object, got ${typeof raw}.`);
}

const withTimeout = <T,>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> =>
	new Promise((resolve, reject) => {
		const timeoutId = window.setTimeout(() => reject(new Error(message)), timeoutMs);
		promise.then(
			(value) => {
				window.clearTimeout(timeoutId);
				resolve(value);
			},
			(error) => {
				window.clearTimeout(timeoutId);
				reject(error);
			},
		);
	});

/**
 * Run a provider IPC request without ever abandoning a late response.
 *
 * The backend fetches all providers concurrently (one parallel pump), so
 * responses land as each provider finishes — typically within a few
 * seconds, with FlareSolverr-backed scrapers taking longest. The soft
 * timeout only flags an individual provider as slow; its response is
 * still applied whenever it arrives. The hard cap exists solely for
 * requests that never settle at all.
 */
const requestProvider = <T,>(
	request: Promise<unknown>,
	parse: (raw: unknown) => ProviderResponse<T>,
	label: string,
	onSettle: (response: ProviderResponse<T>) => void,
): void => {
	let settled = false;
	const slowTimer = window.setTimeout(() => {
		if (settled) return;
		onSettle({ status: 'loading', slow: true });
	}, PROVIDER_SLOW_MS);
	const hardTimer = window.setTimeout(() => {
		if (settled) return;
		settled = true;
		window.clearTimeout(slowTimer);
		console.warn(`[CS2 Profile Stats] ${label} never responded; giving up after ${PROVIDER_HARD_MS / 1000}s.`);
		onSettle({ status: 'error', message: `${label} request timed out.` });
	}, PROVIDER_HARD_MS);
	request.then(
		(raw) => {
			if (settled) return;
			settled = true;
			window.clearTimeout(slowTimer);
			window.clearTimeout(hardTimer);
			try {
				onSettle(parse(raw));
			} catch (error) {
				onSettle({ status: 'error', message: error instanceof Error ? error.message : String(error) });
			}
		},
		(error) => {
			if (settled) return;
			settled = true;
			window.clearTimeout(slowTimer);
			window.clearTimeout(hardTimer);
			onSettle({ status: 'error', message: error instanceof Error ? error.message : String(error) });
		},
	);
};

const fetchWithTimeout = async (input: RequestInfo | URL, init: RequestInit = {}, timeoutMs = STEAM_TIMEOUT_MS) => {
	const controller = new AbortController();
	const timeoutId = window.setTimeout(() => controller.abort(), timeoutMs);
	try {
		return await fetch(input, { ...init, signal: controller.signal });
	} finally {
		window.clearTimeout(timeoutId);
	}
};

// Shared formatting helpers live in ./helpers and are imported above.

const statusMessage = (provider: string, response: ProviderResponse<unknown>) => {
	if (response.status === 'loading') return response.slow ? `${provider} is taking longer than usual…` : `Loading ${provider}…`;
	if (response.message) return response.message;
	if (response.status === 'not_found') return `${provider} profile not found.`;
	if (response.status === 'private') return `${provider} profile is private.`;
	if (response.status === 'rate_limited') return `${provider} rate limit reached.`;
	return `${provider} data is unavailable.`;
};


const detailStat = (label: string, value: string) => `
	<div class="cs2ps-detail-stat"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>
`;

const detailedRow = (label: string, value: string) => `
	<div class="cs2ps-detail-row"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>
`;

// ── Trust score rendering ──────────────────────────────────────────────

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

// ── Trust details panel ────────────────────────────────────────────────

const renderTrustDetails = (state: ViewState) => {
	const cstracker = state.cstracker;
	const csrep = state.csrep;
	const cs2tracker = state.cs2tracker;

	const sections: string[] = [];

	// CSTracker section
	if (cstracker.status === 'ok' && cstracker.data) {
		const ct = cstracker.data;
		const stats = [
			hasValue(ct.kd) ? detailStat('K/D', formatMetric(ct.kd, 2)) : '',
			hasValue(ct.adr) ? detailStat('ADR', formatMetric(ct.adr, 1)) : '',
			hasValue(ct.hs) ? detailStat('HS%', formatPercent(ct.hs)) : '',
			hasValue(ct.winrate) ? detailStat('Win Rate', formatWinrate(ct.winrate)) : '',
			hasValue(ct.preaim) ? detailStat('Preaim', `${formatMetric(ct.preaim, 1)}°`) : '',
			hasValue(ct.ttd) ? detailStat('TTD', `${formatInteger(ct.ttd)} ms`) : '',
			hasValue(ct.total_matches) ? detailStat('Matches', formatInteger(ct.total_matches)) : '',
			ct.has_ban ? detailStat('Ban Status', '⚠️ Banned') : '',
		].filter(Boolean).join('');
		sections.push(`
			<div class="cs2ps-panel">
				<div class="cs2ps-panel-heading"><span>CSTracker.GG</span>${ct.profile_url ? `<a href="${escapeHtml(ct.profile_url)}" target="_blank" rel="noopener">Profile ↗</a>` : ''}</div>
				${ct.trust_rating !== undefined ? `<div class="cs2ps-trust-detail"><span>Trust Rating</span><strong class="${trustScoreColor(ct.trust_rating)}">${escapeHtml(formatInteger(ct.trust_rating))}/100 — ${trustScoreLabel(ct.trust_rating)}</strong></div>` : ''}
				${stats ? `<div class="cs2ps-detail-stats">${stats}</div>` : ''}
			</div>
		`);
	} else if (cstracker.status !== 'loading') {
		sections.push(providerState('CSTracker', cstracker));
	}

	// CSRep section
	if (csrep.status === 'ok' && csrep.data) {
		const cr = csrep.data;
		const breakdown = [
			hasValue(cr.statistical_trust) ? detailStat('Statistical Trust', `${formatMetric(cr.statistical_trust, 2)}%`) : '',
			hasValue(cr.account_flags) ? detailStat('Account Flags', `${formatMetric(cr.account_flags, 2)}%`) : '',
			hasValue(cr.anomalies) ? detailStat('Anomalies', `${formatMetric(cr.anomalies, 2)}%`) : '',
			hasValue(cr.account_bonus) ? detailStat('Account Bonus', `+${formatMetric(cr.account_bonus, 2)}%`) : '',
		].filter(Boolean).join('');
		const extra = [
			cr.has_ban ? detailStat('Ban Status', '⚠️ Banned') : '',
			hasValue(cr.premier) ? detailStat('Premier', formatInteger(cr.premier)) : '',
			cr.faceit_id ? detailStat('FACEIT', '✓ Linked') : '',
			cr.commendations ? detailStat('Commendations', `${formatInteger(cr.commendations.leader)} leader · ${formatInteger(cr.commendations.friendly)} friendly`) : '',
		].filter(Boolean).join('');
		sections.push(`
			<div class="cs2ps-panel">
				<div class="cs2ps-panel-heading"><span>CSRep.GG</span>${cr.profile_url ? `<a href="${escapeHtml(cr.profile_url)}" target="_blank" rel="noopener">Profile ↗</a>` : ''}</div>
				${cr.trust_score !== undefined ? `<div class="cs2ps-trust-detail"><span>Trust Score</span><strong class="${trustScoreColor(cr.trust_score)}">${escapeHtml(formatInteger(cr.trust_score))}/100 — ${cr.trust_label || trustScoreLabel(cr.trust_score)}</strong></div>` : ''}
				${breakdown ? `<div class="cs2ps-detail-stats">${breakdown}</div>` : ''}
				${extra ? `<div class="cs2ps-detail-stats">${extra}</div>` : ''}
			</div>
		`);
	} else if (csrep.status !== 'loading') {
		sections.push(providerState('CSRep', csrep));
	}

	// CS2Tracker section
	if (cs2tracker.status === 'ok' && cs2tracker.data) {
		const ct = cs2tracker.data;
		const flags = [
			ct.has_ban ? '⚠️ Banned' : '',
			ct.is_suspect ? '🚨 Suspect' : '',
			ct.is_legit ? '✅ Legit' : '',
			ct.overwatch_status ? `Overwatch: ${ct.overwatch_status}` : '',
		].filter(Boolean).join(' · ');
		sections.push(`
			<div class="cs2ps-panel">
				<div class="cs2ps-panel-heading"><span>CS2Tracker.GG</span>${ct.profile_url ? `<a href="${escapeHtml(ct.profile_url)}" target="_blank" rel="noopener">Profile ↗</a>` : ''}</div>
				${ct.suspicion_score !== undefined ? `<div class="cs2ps-trust-detail"><span>Cheating Suspicion</span><strong>${escapeHtml(formatInteger(ct.suspicion_score))}%</strong></div>` : ''}
				${flags ? `<div class="cs2ps-detail-row"><span>Flags</span><strong>${escapeHtml(flags)}</strong></div>` : ''}
			</div>
		`);
	} else if (cs2tracker.status !== 'loading') {
		sections.push(providerState('CS2Tracker', cs2tracker));
	}

	if (!sections.length) {
		return '<p class="cs2ps-detail-note">No trust data available from any provider.</p>';
	}

	return sections.join('');
};

// ── All providers stats panel ──────────────────────────────────────────

const renderAllProvidersStats = (state: ViewState) => {
	const rows: string[] = [];
	type SourceRow = { name: string; data: ProviderResponse<unknown>; kd?: number; adr?: number; hs?: number; wr?: number };
	const sources: SourceRow[] = [
		{ name: 'Leetify', data: state.leetify, kd: state.leetify.data?.stats.kd, adr: undefined as number | undefined, hs: undefined as number | undefined, wr: state.leetify.data?.winrate },
		{ name: 'FACEIT', data: state.faceit, kd: state.faceit.data?.stats.kd ? Number(state.faceit.data.stats.kd) : undefined, adr: state.faceit.data?.stats.adr ? Number(state.faceit.data.stats.adr) : undefined, hs: state.faceit.data?.stats.headshots ? Number(state.faceit.data.stats.headshots) : undefined, wr: state.faceit.data?.stats.winrate ? Number(state.faceit.data.stats.winrate) : undefined },
		{ name: 'CSTracker', data: state.cstracker, kd: state.cstracker.data?.kd, adr: state.cstracker.data?.adr, hs: state.cstracker.data?.hs, wr: state.cstracker.data?.winrate },
		{ name: 'CSStats', data: state.csstats, kd: state.csstats.data?.kd, adr: state.csstats.data?.adr, hs: state.csstats.data?.hs, wr: state.csstats.data?.winrate },
		{ name: 'Tracker.GG', data: state.tracker, kd: state.tracker.data?.kd, adr: state.tracker.data?.adr, hs: state.tracker.data?.hs, wr: state.tracker.data?.winrate },
	];

	for (const source of sources) {
		if (source.data.status !== 'ok') continue;
		const cells = [
			`<td class="cs2ps-providers-name">${escapeHtml(source.name)}</td>`,
			`<td>${hasValue(source.kd) ? formatMetric(source.kd, 2) : '—'}</td>`,
			`<td>${hasValue(source.adr) ? formatMetric(source.adr, 1) : '—'}</td>`,
			`<td>${hasValue(source.hs) ? formatPercent(source.hs) : '—'}</td>`,
			`<td>${hasValue(source.wr) ? formatWinrate(source.wr) : '—'}</td>`,
		];
		rows.push(`<tr>${cells.join('')}</tr>`);
	}

	if (!rows.length) {
		return '<p class="cs2ps-detail-note">No provider data available for comparison.</p>';
	}

	return `
		<table class="cs2ps-providers-table">
			<thead><tr><th>Source</th><th>K/D</th><th>ADR</th><th>HS%</th><th>Win Rate</th></tr></thead>
			<tbody>${rows.join('')}</tbody>
		</table>
	`;
};


const providerState = (provider: string, response: ProviderResponse<unknown>) => `
	<div class="cs2ps-provider-state cs2ps-provider-${escapeHtml(response.status)}">
		<span class="cs2ps-provider-dot"></span><span>${escapeHtml(statusMessage(provider, { ...response, message: undefined }))}</span>
	</div>
`;

const renderMatchList = (matches: LeetifyProfile['recent_matches']) => `
	<div class="cs2ps-match-list">
		${matches
			.slice(0, 5)
			.map((match) => {
				const outcome = match.outcome?.toLowerCase();
				const result = outcome === 'win' ? 'W' : outcome === 'loss' ? 'L' : '•';
				const meta = [formatMatchDate(match.finished_at), formatDataSource(match.data_source)].filter(Boolean).join(' · ');
				return `
					<div class="cs2ps-match">
						<span class="cs2ps-match-result cs2ps-form-${outcome === 'win' ? 'win' : outcome === 'loss' ? 'loss' : 'unknown'}">${result}</span>
						<span class="cs2ps-match-copy"><strong>${escapeHtml(formatMapName(match.map_name))}</strong><small>${escapeHtml(meta || 'Recent match')}</small></span>
						<strong class="cs2ps-match-score">${escapeHtml(formatScore(match.score))}</strong>
					</div>
				`;
			})
			.join('')}
	</div>
`;

const renderInventoryValue = (inventory: InventoryState, steamId: string) => {
	const inventoryUrl = `https://steamcommunity.com/profiles/${encodeURIComponent(steamId)}/inventory/#730`;
	if (inventory.status === 'idle') {
		return `
			<button class="cs2ps-inventory-action" type="button" data-inventory-action>
				<span><strong>CS2 inventory</strong><small>Estimate using lowest Steam Market prices</small></span><b>Check value</b>
			</button>
		`;
	}
	if (inventory.status === 'loading') {
		return `<div class="cs2ps-inventory-state"><span class="cs2ps-spinner"></span><span>Pricing public inventory…</span></div>`;
	}
	if (inventory.status === 'private') {
		return `<div class="cs2ps-inventory-state"><span>CS2 inventory is private</span><a href="${inventoryUrl}" target="_blank" rel="noopener">Open ↗</a></div>`;
	}
	if (inventory.status === 'too_large') {
		return `<div class="cs2ps-inventory-state cs2ps-inventory-large"><span><strong>${escapeHtml(formatInteger(inventory.totalItems))} items</strong><small>Too many unique items for safe Steam pricing</small></span><a href="${inventoryUrl}" target="_blank" rel="noopener">Open ↗</a></div>`;
	}
	if (inventory.status === 'error') {
		return `<div class="cs2ps-inventory-state"><span>Inventory value unavailable</span><button type="button" data-inventory-action>Retry</button></div>`;
	}

	return `
		<div class="cs2ps-inventory-value">
			<span><strong>CS2 inventory</strong><small>${escapeHtml(formatInteger(inventory.pricedItems))}/${escapeHtml(formatInteger(inventory.marketableItems))} marketable priced · ${escapeHtml(formatInteger(inventory.totalItems))} items</small></span>
			<span class="cs2ps-inventory-price"><strong>≈ ${escapeHtml(formatUsd(inventory.valueUsd))}</strong><a href="${inventoryUrl}" target="_blank" rel="noopener">Steam prices ↗</a></span>
		</div>
	`;
};

const renderDetails = (state: ViewState, steamId: string) => {
	const leetify = state.leetify.data;
	const faceit = state.faceit.data;
	const leetifyUrl = `https://leetify.com/app/profile/${encodeURIComponent(steamId)}`;
	const faceitUrl = faceit?.nickname ? `https://www.faceit.com/en/players/${encodeURIComponent(faceit.nickname)}` : undefined;
	const tabs: Array<{ id: DetailTab; label: string }> = [{ id: 'overview', label: 'Overview' }];
	// Add breakdown tab if we have data from any provider
	const aggData = state.aggregated.data;
	if (aggData && aggData.provider_count >= 1) {
		tabs.push({ id: 'breakdown', label: 'Breakdown' });
	}
	if (leetify?.recent_matches.length) tabs.push({ id: 'matches', label: 'Matches' });
	if (state.faceit.status === 'ok' && faceit) tabs.push({ id: 'faceit', label: 'FACEIT' });
	// Add trust tab if any trust provider has data
	const hasTrustData = state.cstracker.status === 'ok' || state.csrep.status === 'ok' || state.cs2tracker.status === 'ok';
	if (hasTrustData) tabs.push({ id: 'trust', label: 'Trust' });
	// Add providers tab if any new provider has data
	const hasProviderData = state.csstats.status === 'ok' || state.tracker.status === 'ok' || state.cstracker.status === 'ok';
	if (hasProviderData) tabs.push({ id: 'providers', label: 'Providers' });
	if (state.preferences.show_steam_details) tabs.push({ id: 'steam', label: 'Steam' });
	if (!tabs.some((tab) => tab.id === state.activeTab)) state.activeTab = tabs[0].id;

	const supplementalStats = leetify
		? [
				hasValue(leetify.rating.positioning) ? detailStat('Positioning', formatMetric(leetify.rating.positioning)) : '',
				hasValue(leetify.rating.utility) ? detailStat('Utility', formatMetric(leetify.rating.utility)) : '',
				hasValue(leetify.rating.opening) ? detailStat('Opening', formatSignedMetric(leetify.rating.opening, 2)) : '',
				hasValue(leetify.rating.clutch) ? detailStat('Clutch', formatSignedMetric(leetify.rating.clutch, 1)) : '',
				hasValue(leetify.stats.preaim) ? detailStat('Preaim', formatMetric(leetify.stats.preaim)) : '',
				hasValue(leetify.stats.spray_accuracy) ? detailStat('Spray accuracy', formatPercent(leetify.stats.spray_accuracy)) : '',
				hasValue(leetify.stats.counter_strafing) ? detailStat('Counter-strafing', formatPercent(leetify.stats.counter_strafing)) : '',
			].filter(Boolean).join('')
		: '';
	const hasScopeDamageTime = hasValue(leetify?.stats.damage_time_min_ms) && hasValue(leetify?.stats.damage_time_max_ms);
	const overviewPanel = `
		<section class="cs2ps-panel ${state.activeTab === 'overview' ? 'cs2ps-panel-active' : ''}" data-panel="overview">
			${state.leetify.status === 'ok' && leetify
				? `<div class="cs2ps-panel-heading"><span>Performance details</span><a href="${leetifyUrl}" target="_blank" rel="noopener">Leetify ↗</a></div>
					${supplementalStats ? `<div class="cs2ps-detail-stats">${supplementalStats}</div>` : '<p class="cs2ps-detail-note">No additional public metrics for this player.</p>'}
					<div class="cs2ps-sources">
						<a class="cs2ps-leetify-attribution" href="https://leetify.com/" target="_blank" rel="noopener"><img src="${leetifyBadge}" alt="Data Provided by Leetify"></a>
						${hasScopeDamageTime && leetify.stats.damage_time_source_url ? `<a class="cs2ps-scope-source" href="${escapeHtml(leetify.stats.damage_time_source_url)}" target="_blank" rel="noopener">AWP timing · SCOPE.GG ↗</a>` : ''}
					</div>`
				: providerState('Leetify', state.leetify)}
		</section>
	`;
	const matchesPanel = leetify?.recent_matches.length
		? `<section class="cs2ps-panel ${state.activeTab === 'matches' ? 'cs2ps-panel-active' : ''}" data-panel="matches">${renderMatchList(leetify.recent_matches)}</section>`
		: '';
	const faceitStats = faceit
		? [
				detailStat('Level', formatInteger(faceit.level)),
				detailStat('ELO', formatInteger(faceit.elo)),
				hasValue(faceit.region || faceit.country) ? detailStat('Region', (faceit.region || faceit.country || '').toUpperCase()) : '',
				hasValue(faceit.stats.kd) ? detailStat('K/D', faceit.stats.kd!) : '',
				hasValue(faceit.stats.adr) ? detailStat('ADR', faceit.stats.adr!) : '',
				hasValue(faceit.stats.headshots) ? detailStat('HS', faceit.stats.headshots!) : '',
				hasValue(faceit.stats.winrate) ? detailStat('Win rate', faceit.stats.winrate!) : '',
				hasValue(faceit.stats.matches) ? detailStat('Matches', faceit.stats.matches!) : '',
			].filter(Boolean).join('')
		: '';
	const faceitPanel = state.faceit.status === 'ok' && faceit
		? `<section class="cs2ps-panel ${state.activeTab === 'faceit' ? 'cs2ps-panel-active' : ''}" data-panel="faceit"><div class="cs2ps-panel-heading"><span>${escapeHtml(faceit.nickname || 'FACEIT player')}</span>${faceitUrl ? `<a href="${faceitUrl}" target="_blank" rel="noopener">FACEIT ↗</a>` : ''}</div><div class="cs2ps-detail-stats">${faceitStats}</div></section>`
		: '';
	const steamPanel = state.preferences.show_steam_details
		? `<section class="cs2ps-panel ${state.activeTab === 'steam' ? 'cs2ps-panel-active' : ''}" data-panel="steam"><div class="cs2ps-detail-list">${detailedRow('CS2 hours', state.steam.hours || 'Private')}${detailedRow('Last 2 weeks', state.steam.recentHours || (state.steam.status === 'loading' ? 'Loading…' : 'Private'))}${detailedRow('Member since', state.steam.memberSince || (state.steam.status === 'loading' ? 'Loading…' : 'Unknown'))}</div>${renderInventoryValue(state.inventory, steamId)}</section>`
		: '';
	const trustPanel = hasTrustData
		? `<section class="cs2ps-panel ${state.activeTab === 'trust' ? 'cs2ps-panel-active' : ''}" data-panel="trust">${renderTrustDetails(state)}</section>`
		: '';
	const providersPanel = hasProviderData
		? `<section class="cs2ps-panel ${state.activeTab === 'providers' ? 'cs2ps-panel-active' : ''}" data-panel="providers">${renderAllProvidersStats(state)}</section>`
		: '';

	// Aggregated profile panel (breakdown tab)
	const hasAggregated = aggData && aggData.provider_count >= 1;
	const aggregatedPanel = hasAggregated
		? `<section class="cs2ps-panel cs2ps-panel-breakdown ${state.activeTab === 'breakdown' ? 'cs2ps-panel-active' : ''}" data-panel="breakdown">${renderBreakdown(aggData!)}</section>`
		: '';

	return `
		<div class="cs2ps-details" ${state.expanded ? '' : 'hidden'}>
			<div class="cs2ps-tabs cs2ps-tabs-${tabs.length}">${tabs.map((tab) => `<button class="cs2ps-tab ${state.activeTab === tab.id ? 'cs2ps-tab-active' : ''}" type="button" data-tab="${tab.id}">${tab.label}</button>`).join('')}</div>
			${overviewPanel}${matchesPanel}${aggregatedPanel}${faceitPanel}${trustPanel}${providersPanel}${steamPanel}
		</div>
	`;
};


// ── Client-side aggregation ─────────────────────────────────────────

/**
 * Build an AggregatedProfile from the existing ViewState.
 * Runs on every render so it updates live as providers return.
 */
const buildAggregatedFromState = (state: ViewState): AggregatedProfile | null => {
	// Collect responses from providers that returned ok
	const providers: Record<string, { data: unknown; status: string }> = {};
	const providerEntries: Array<[string, ProviderResponse<unknown>]> = [
		['leetify', state.leetify],
		['faceit', state.faceit],
		['cstracker', state.cstracker],
		['csrep', state.csrep],
		['csstats', state.csstats],
	];
	for (const [name, resp] of providerEntries) {
		if (resp.status === 'ok' && resp.data) {
			providers[name] = { data: resp.data, status: resp.status };
		}
	}
	const providerCount = Object.keys(providers).length;
	if (providerCount === 0) return null;

	const agg: AggregatedProfile = {
		steam64_id: undefined,
		name: undefined,
		stats: {},
		ranks: {},
		utility: {},
		behavior: {},
		kill_breakdown: {},
		multi_kills: {},
		clutch: [],
		entry: [],
		leetify_rating: {},
		trust: { has_ban: false, bans: [] },
		provider_data: {},
		matches: [],
		provider_count: providerCount,
		providers_used: Object.keys(providers),
	};

	// Helper to resolve the best value from multiple providers.
	// Mirrors the backend aggregator: rates use a weighted average by how
	// many matches each provider tracked; ranks/totals take the provider
	// with the most matches tracked (static priority breaks ties).
	// Contributions are attached so the UI can show per-provider
	// breakdowns on hover.
	const priorityOf = (name: string): number => {
		const idx = ['cstracker', 'csrep', 'csstats', 'leetify', 'faceit'].indexOf(name);
		return idx === -1 ? 99 : idx;
	};

	const matchCountOf = (name: string): number => {
		const data = providers[name]?.data as Record<string, unknown> | undefined;
		if (!data) return 0;
		switch (name) {
			case 'leetify': return toNum(data.total_matches) ?? 0;
			case 'faceit': return toNum((data.stats as Record<string, unknown> | undefined)?.matches) ?? 0;
			case 'cstracker': return toNum(data.total_matches) ?? 0;
			case 'csrep': return toNum((data.performance as Record<string, unknown> | undefined)?.matches_played) ?? 0;
			case 'csstats': return toNum(data.total_matches) ?? 0;
			default: return 0;
		}
	};

	const resolve = <T,>(
		entries: Array<[string, T | undefined]>,
		method: 'weighted' | 'primary' = 'weighted',
	): AggValue<T> | undefined => {
		const provided = entries.filter(([, v]) => v !== undefined && v !== null) as Array<[string, T]>;
		if (!provided.length) return undefined;

		const counts = provided.map(([name]) => matchCountOf(name));
		let primary = provided[0][0];
		let bestCount = counts[0];
		let bestPrio = priorityOf(primary);
		provided.forEach(([name], i) => {
			const prio = priorityOf(name);
			if (counts[i] > bestCount || (counts[i] === bestCount && prio < bestPrio)) {
				primary = name;
				bestCount = counts[i];
				bestPrio = prio;
			}
		});

		let value: T;
		let contributions: AggContribution[];
		if (method === 'primary' || provided.length === 1) {
			value = provided.find(([n]) => n === primary)![1];
			contributions = provided.map(([name, v], i) => ({
				provider: name,
				value: Number(v),
				weight: name === primary ? 1 : 0,
				matches: counts[i],
				is_primary: name === primary,
			}));
		} else {
			// Weighted average by matches tracked; floor so providers that
			// don't report a match count still contribute a small share.
			const weights = counts.map((c) => (c > 0 ? c : 25));
			const total = weights.reduce((a, b) => a + b, 0);
			const numbers = provided.map(([, v]) => Number(v));
			if (numbers.every((n) => Number.isFinite(n))) {
				const acc = numbers.reduce((sum, n, i) => sum + n * (weights[i] / total), 0);
				value = (Math.round(acc * 100) / 100) as T;
			} else {
				value = provided.find(([n]) => n === primary)![1];
			}
			contributions = provided.map(([name, v], i) => ({
				provider: name,
				value: Number(v),
				weight: weights[i] / total,
				matches: counts[i],
				is_primary: name === primary,
			}));
		}

		return { value, sources: provided.map(([n]) => n), contributions };
	};

	const toNum = (v: unknown): number | undefined => {
		if (v === undefined || v === null) return undefined;
		if (typeof v === 'number') return v;
		const s = String(v).replace(/,/g, '').replace(/%/g, '').trim();
		const n = Number(s);
		return Number.isFinite(n) ? n : undefined;
	};

	// Identity — cast to the declared provider shapes, then sanitize every
	// field the aggregation below iterates over. Provider payloads are
	// only type-checked at the TypeScript level: a scrape drift or stale
	// cache can hand back a string/object where a list is expected, which
	// used to make `.map` / `for...of` iteration throw ("X is not
	// iterable") and wipe the whole aggregated profile. Malformed fields
	// are replaced with empty lists so the affected stat just stays unset.
	const lfRaw = providers.leetify?.data as LeetifyProfile | undefined;
	const fiRaw = providers.faceit?.data as FaceitProfile | undefined;
	const ctRaw = providers.cstracker?.data as CstrackerProfile | undefined;
	const crRaw = providers.csrep?.data as CsrepProfile | undefined;
	const csRaw = providers.csstats?.data as CsstatsProfile | undefined;

	const lf = lfRaw
		? { ...lfRaw, recent_matches: asArray<LeetifyProfile['recent_matches'][number]>(lfRaw.recent_matches) }
		: undefined;
	const fi = fiRaw;
	const ct = ctRaw
		? {
				...ctRaw,
				clutch: asArray<CstrackerClutch>(ctRaw.clutch),
				match_history: asArray<CstrackerMatchHistory>(ctRaw.match_history),
				trust_breakdown: ctRaw.trust_breakdown && typeof ctRaw.trust_breakdown === 'object' ? ctRaw.trust_breakdown : undefined,
			}
		: undefined;
	const cr = crRaw
		? {
				...crRaw,
				performance:
					crRaw.performance && typeof crRaw.performance === 'object'
						? {
								...crRaw.performance,
								clutches:
									crRaw.performance.clutches && typeof crRaw.performance.clutches === 'object'
										? crRaw.performance.clutches
										: undefined,
								multi_kills:
									crRaw.performance.multi_kills && typeof crRaw.performance.multi_kills === 'object'
										? crRaw.performance.multi_kills
										: undefined,
							}
					: undefined,
			}
		: undefined;
	const cs = csRaw
		? {
				...csRaw,
				clutch: asArray<NonNullable<CsstatsProfile['clutch']>[number]>(csRaw.clutch),
				recent_matches: asArray<NonNullable<CsstatsProfile['recent_matches']>[number]>(csRaw.recent_matches),
				entry: csRaw.entry && typeof csRaw.entry === 'object' ? csRaw.entry : undefined,
			}
		: undefined;

	agg.steam64_id = lf?.steam64_id || ct?.steam64_id || cr?.steam64_id || cs?.steam64_id || undefined;
	agg.name = lf?.name || fi?.nickname || ct?.name || cr?.name || cs?.name || undefined;

	// Core stats
	agg.stats.kd = resolve([
		['leetify', lf?.stats.kd],
		['faceit', toNum(fi?.stats.kd)],
		['cstracker', ct?.kd],
		['csrep', cr?.performance?.kd_ratio],
		['csstats', cs?.kd],
	]);
	agg.stats.winrate = resolve([
		['leetify', lf?.winrate !== undefined ? (lf.winrate <= 1 ? lf.winrate * 100 : lf.winrate) : undefined],
		['faceit', toNum(fi?.stats.winrate)],
		['cstracker', ct?.winrate],
		['csrep', cr?.performance?.win_rate],
		['csstats', cs?.winrate],
	]);
	agg.stats.adr = resolve([
		['faceit', toNum(fi?.stats.adr)],
		['cstracker', ct?.adr],
		['csrep', cr?.stats?.adr],
		['csstats', cs?.adr],
	]);
	agg.stats.headshot_pct = resolve([
		['faceit', toNum(fi?.stats.headshots)],
		['cstracker', ct?.hs_pct],
		['csstats', cs?.hs],
	]);
	// Head Accuracy — CSRep's own metric: headshots as a share of ALL
	// shots, not of kills. Deliberately not merged into headshot_pct.
	agg.stats.head_accuracy = resolve([
		['csrep', toNum(cr?.stats?.accuracy_head)],
	], 'primary');
	agg.stats.hltv_rating = resolve([
		['cstracker', ct?.hltv_rating],
		['csrep', cr?.stats?.hltv_rating_2],
		['csstats', cs?.hltv_rating],
	]);
	agg.stats.kast = resolve([
		['cstracker', ct?.kast],
		['csrep', cr?.stats?.kast],
		['csstats', cs?.kast],
	]);
	agg.stats.total_matches = resolve([
		['leetify', lf?.total_matches],
		['faceit', toNum(fi?.stats.matches)],
		['cstracker', ct?.total_matches],
		['csrep', cr?.performance?.matches_played],
		['csstats', cs?.total_matches],
	], 'primary');
	agg.stats.kills = resolve([['cstracker', ct?.kills], ['csrep', cr?.performance?.kills], ['csstats', cs?.kills]], 'primary');
	agg.stats.deaths = resolve([['cstracker', ct?.deaths], ['csrep', cr?.performance?.deaths], ['csstats', cs?.deaths]], 'primary');
	agg.stats.assists = resolve([['cstracker', ct?.assists], ['csrep', cr?.performance?.assists], ['csstats', cs?.assists]], 'primary');
	// CSTracker-only stats
	agg.stats.preaim = ct?.preaim !== undefined ? { value: ct.preaim, sources: ['cstracker'] } : undefined;
	agg.stats.aim_offset = ct?.aim_offset !== undefined ? { value: ct.aim_offset, sources: ['cstracker'] } : undefined;
	agg.stats.counter_strafing = ct?.counter_strafing !== undefined ? { value: ct.counter_strafing, sources: ['cstracker'] } : undefined;
	agg.stats.ttd = ct?.ttd !== undefined ? { value: ct.ttd, sources: ['cstracker'] } : undefined;
	agg.stats.spray_accuracy = ct?.spray_accuracy !== undefined ? { value: ct.spray_accuracy, sources: ['cstracker'] } : undefined;
	agg.stats.accuracy = ct?.accuracy !== undefined ? { value: ct.accuracy, sources: ['cstracker'] } : undefined;
	agg.stats.first_kills = resolve([
		['cstracker', ct?.first_kills],
		['csstats', cs?.first_kills],
	], 'primary');
	agg.stats.trade_kills = ct?.trade_kills !== undefined ? { value: ct.trade_kills, sources: ['cstracker'] } : undefined;
	agg.stats.reaction_time_ms = lf?.stats.reaction_time_ms !== undefined ? { value: lf.stats.reaction_time_ms, sources: ['leetify'] } : undefined;

	// Ranks — point-in-time per platform, so take the provider with the
	// most matches tracked instead of averaging.
	agg.ranks.premier = resolve([
		['leetify', lf?.ranks?.premier],
		['cstracker', ct?.premier],
		['csrep', (cr as unknown as { premier?: number })?.premier],
		['csstats', cs?.premier],
	], 'primary');
	agg.ranks.faceit = resolve([
		['faceit', fi?.level],
		['cstracker', ct?.faceit_level],
	], 'primary');
	agg.ranks.faceit_elo = resolve([
		['faceit', fi?.elo],
		['leetify', lf?.ranks?.faceit_elo],
		['cstracker', ct?.faceit_elo],
	], 'primary');
	if (lf?.ranks?.leetify !== undefined) agg.ranks.leetify = { value: lf.ranks.leetify, sources: ['leetify'] };

	// Leetify ratings
	if (lf?.rating) {
		const r = lf.rating;
		if (r.aim !== undefined) agg.leetify_rating.aim = { value: r.aim, sources: ['leetify'] };
		if (r.positioning !== undefined) agg.leetify_rating.positioning = { value: r.positioning, sources: ['leetify'] };
		if (r.utility !== undefined) agg.leetify_rating.utility = { value: r.utility, sources: ['leetify'] };
		if (r.clutch !== undefined) agg.leetify_rating.clutch = { value: r.clutch, sources: ['leetify'] };
		if (r.opening !== undefined) agg.leetify_rating.opening = { value: r.opening, sources: ['leetify'] };
	}

	// Utility (CSTracker only)
	if (ct) {
		const u = agg.utility;
		if (ct.grenade_throws !== undefined) u.grenade_throws = { value: ct.grenade_throws, sources: ['cstracker'] };
		if (ct.flash_assists !== undefined) u.flash_assists = { value: ct.flash_assists, sources: ['cstracker'] };
		if (ct.enemies_flashed_per_flash !== undefined) u.enemies_flashed_per_flash = { value: ct.enemies_flashed_per_flash, sources: ['cstracker'] };
		if (ct.util_dmg_per_match !== undefined) u.util_dmg_per_match = { value: ct.util_dmg_per_match, sources: ['cstracker'] };
	}

	// Trust
	if (ct?.trust_rating !== undefined) agg.trust.cstracker_rating = ct.trust_rating;
	if (ct?.trust_breakdown) agg.trust.cstracker_breakdown = ct.trust_breakdown;
	if (cr?.trust_score !== undefined) agg.trust.csrep_score = cr.trust_score;
	if (cr?.trust_label) agg.trust.csrep_label = cr.trust_label;
	if (cr?.statistical_trust !== undefined) agg.trust.csrep_statistical = cr.statistical_trust;
	if (cr?.account_flags !== undefined) agg.trust.csrep_account_flags = cr.account_flags;
	if (cr?.anomalies !== undefined) agg.trust.csrep_anomalies = cr.anomalies;
	if (cr?.account_bonus !== undefined) agg.trust.csrep_account_bonus = cr.account_bonus;
	if (cr) {
		// Mirror backend aggregator.extract_csrep_trust — structured
		// reasons so the UI can explain a score below 100. Components are
		// 0-100 trust percentages (penalty when below 100); bonus is
		// +percentage points.
		const breakdown: Array<{ factor: string; value: number; is_penalty?: boolean }> = [];
		if (cr.statistical_trust !== undefined) breakdown.push({ factor: 'Statistical Trust', value: cr.statistical_trust });
		if (cr.account_flags !== undefined) breakdown.push({ factor: 'Account Flags', value: cr.account_flags, is_penalty: cr.account_flags < 100 });
		if (cr.anomalies !== undefined) breakdown.push({ factor: 'Anomalies', value: cr.anomalies, is_penalty: cr.anomalies < 100 });
		if (cr.account_bonus !== undefined) breakdown.push({ factor: 'Account Bonus', value: cr.account_bonus });
		if (breakdown.length) agg.trust.csrep_breakdown = breakdown;
	}
	if (ct?.has_ban || cr?.has_ban) agg.trust.has_ban = true;

	// Clutch — mirror the backend aggregator: collect every provider's
	// per-label numbers, resolve the displayed values to the provider with
	// the most matches tracked (empty 0/0 rows never shadow real data), and
	// keep weighted per-provider contributions for the hover breakdown.
	const clutchBuckets = new Map<string, Array<{ provider: string; wins: number; losses: number; winrate: number }>>();
	const addClutch = (provider: string, entries: unknown) => {
		for (const c of asArray<{ label?: string; wins?: number; losses?: number; winrate?: number }>(entries)) {
			if (!c?.label) continue;
			const wins = toNum(c.wins) ?? 0;
			const losses = toNum(c.losses) ?? 0;
			if (wins + losses <= 0) continue;
			const bucket = clutchBuckets.get(c.label) ?? [];
			bucket.push({ provider, wins, losses, winrate: toNum(c.winrate) ?? 0 });
			clutchBuckets.set(c.label, bucket);
		}
	};
	addClutch('cstracker', ct?.clutch);
	const crClutch = cr?.performance?.clutches;
	if (crClutch) {
		const clutchKeys: Array<{ total?: number; won?: number; label: string }> = [
			{ total: crClutch.v1, won: crClutch.v1_won, label: '1v1' },
			{ total: crClutch.v2, won: crClutch.v2_won, label: '1v2' },
			{ total: crClutch.v3, won: crClutch.v3_won, label: '1v3' },
			{ total: crClutch.v4, won: crClutch.v4_won, label: '1v4' },
			{ total: crClutch.v5, won: crClutch.v5_won, label: '1v5' },
		];
		addClutch(
			'csrep',
			asArray(clutchKeys).map(({ total, won, label }) => {
				const t = toNum(total);
				if (!t || t <= 0) return undefined;
				const w = toNum(won) ?? 0;
				return { label, wins: w, losses: t - w, winrate: Math.round((w / t) * 100) };
			}),
		);
	}
	addClutch('csstats', cs?.clutch);

	for (const label of ['1v1', '1v2', '1v3', '1v4', '1v5']) {
		const bucket = clutchBuckets.get(label);
		if (!bucket?.length) continue;
		const totalRaw = bucket.reduce((acc, it) => acc + Math.max(matchCountOf(it.provider), 25), 0);
		let primary = bucket[0];
		let bestRaw = Math.max(matchCountOf(primary.provider), 25);
		let bestPrio = priorityOf(primary.provider);
		for (const it of bucket) {
			const raw = Math.max(matchCountOf(it.provider), 25);
			const prio = priorityOf(it.provider);
			if (raw > bestRaw || (raw === bestRaw && prio < bestPrio)) {
				primary = it;
				bestRaw = raw;
				bestPrio = prio;
			}
		}
		const contributions = bucket
			.map((it) => {
				const raw = Math.max(matchCountOf(it.provider), 25);
				return {
					provider: it.provider,
					wins: it.wins,
					losses: it.losses,
					winrate: it.winrate,
					weight: totalRaw > 0 ? raw / totalRaw : 1,
					matches: matchCountOf(it.provider),
					is_primary: it.provider === primary.provider,
				};
			})
			.sort((a, b) => (b.weight ?? 0) - (a.weight ?? 0));
		agg.clutch.push({
			label,
			wins: primary.wins,
			losses: primary.losses,
			winrate: primary.winrate,
			sources: contributions.map((x) => x.provider),
			contributions,
		});
	}

	// Entry success — CSStats first-kill/first-death counters (combined + sides).
	if (cs?.entry) {
		const e = cs.entry;
		const sides: Array<[string, typeof e]> = [['Combined', e], ['T', e.t], ['CT', e.ct]];
		for (const [label, side] of sides) {
			if (side && side.success_pct !== undefined) {
				const matches = matchCountOf('csstats');
				agg.entry.push({
					label,
					success_pct: side.success_pct,
					attempts_per_round_pct: side.attempts_per_round_pct,
					success_per_round_pct: side.success_per_round_pct,
					first_kills: side.first_kills,
					first_deaths: side.first_deaths,
					sources: ['csstats'],
					contributions: [{
						provider: 'csstats',
						success_pct: side.success_pct,
						attempts_per_round_pct: side.attempts_per_round_pct,
						success_per_round_pct: side.success_per_round_pct,
						first_kills: side.first_kills,
						first_deaths: side.first_deaths,
						weight: 1,
						matches,
						is_primary: true,
					}],
				});
			}
		}
	}

	// Multi-kills — totals, so the provider with the most matches tracked
	// wins outright (same method as kills/deaths). CSRep reports these today;
	// CSTracker slots in automatically once its scraper emits them.
	const mk = cr?.performance?.multi_kills;
	const csmk = cs?.multi_kills;
	if (mk || csmk) {
		const mkEntries: Array<[keyof typeof agg.multi_kills, number | undefined, number | undefined]> = [
			['double', toNum(mk?.double), undefined],
			['triple', toNum(mk?.triple), toNum(csmk?.triple)],
			['quad', toNum(mk?.quad), toNum(csmk?.quad)],
			['penta', toNum(mk?.penta), toNum(csmk?.penta)],
		];
		for (const [key, v, cv] of mkEntries) {
			const contributions: Array<[string, number]> = [];
			if (v !== undefined) contributions.push(['csrep', v]);
			if (cv !== undefined) contributions.push(['csstats', cv]);
			if (contributions.length) agg.multi_kills[key] = resolve(contributions, 'primary');
		}
	}

	// Matches (collect from all providers)
	const matchMap = new Map<string, UnifiedMatch>();
	const addMatch = (provider: string, m: { map_name?: string; score?: string | number[]; outcome?: string; finished_at?: string; kills?: number; deaths?: number; assists?: number; kd?: number; adr?: number; rating?: number }) => {
		if (!m.map_name) return;
		const mapKey = m.map_name.toLowerCase().replace(/^de_/, '').replace(/\s+/g, '');
		const scoreStr = Array.isArray(m.score) ? `${m.score[0]}:${m.score[1]}` : (m.score as string) || '';
		const key = `${mapKey}|${scoreStr}`;
		const existing = matchMap.get(key);
		if (existing) {
			if (!existing.sources.includes(provider)) existing.sources.push(provider);
		} else {
			matchMap.set(key, {
				map_name: m.map_name, score: scoreStr || undefined,
				outcome: m.outcome, finished_at: m.finished_at,
				kills: m.kills, deaths: m.deaths, assists: m.assists,
				kd: m.kd, adr: m.adr, rating: m.rating,
				sources: [provider],
			});
		}
	};
	if (lf?.recent_matches) lf.recent_matches.forEach((m) => addMatch('leetify', m));
	if (ct?.match_history) ct.match_history.forEach((m) => addMatch('cstracker', m));
	if (cs?.recent_matches) cs.recent_matches.forEach((m) => addMatch('csstats', m as unknown as Parameters<typeof addMatch>[1]));
	agg.matches = Array.from(matchMap.values());

	// Provider-specific extensions
	if (lf) agg.provider_data.leetify = lf;
	if (fi) agg.provider_data.faceit = fi;
	if (ct) agg.provider_data.cstracker = { match_history: ct.match_history, map_performance: ct.map_performance, teammates: ct.teammates };
	if (cr) agg.provider_data.csrep = { commendations: cr.commendations, crosshairs: (cr as unknown as { crosshairs?: unknown[] }).crosshairs, ranks: (cr as unknown as { ranks?: Record<string, { current?: number; peak?: number; wins?: number; losses?: number; matches?: number }> }).ranks, faceit_id: cr.faceit_id, steam_level: (cr as unknown as { steam_level?: number }).steam_level, cs2_hours: (cr as unknown as { cs2_hours?: number }).cs2_hours };
	if (cs) agg.provider_data.csstats = { recent_matches: cs.recent_matches, damage: cs.damage, rounds: cs.rounds, entry: cs.entry, extras: cs.extras };

	return agg;
};

// ── Banner render wrapper ───────────────────────────────────────────

/**
 * Shorten an aggregation error for the single-line banner title.
 * The full message stays in the console and in the hover tooltip, so the
 * error is never silently truncated.
 */
const shortAggError = (message: string): string => {
	if (message.length <= 90) return message;
	const firstLine = message.split('\n')[0];
	return firstLine.length <= 90 ? firstLine : `${firstLine.slice(0, 87)}…`;
};

/** Render HTML with a visible fallback if the renderer throws. */
const safeRenderHtml = (render: () => string, fallback: () => string): string => {
	try {
		return render();
	} catch (error) {
		console.error('[CS2PS] Render step failed:', error);
		return fallback();
	}
};

type LoadSegmentState = LoadSegment['state'];

/**
 * Per-provider loading segments, laid out in PROVIDER_ORDER. The backend
 * fetches every provider concurrently in one parallel pump, so all
 * unsettled providers are genuinely in flight at once — each animates
 * independently and fills the moment its own response arrives (order of
 * arrival is NOT the layout order: fast APIs land first, FlareSolverr-
 * backed scrapers last). Settled providers show as filled or error
 * segments regardless of arrival order.
 */
const providerSegments = (state: ViewState): LoadSegment[] =>
	state.loadProviders.map((provider) => {
		const response: ProviderResponse<unknown> = state[provider.name];
		let segmentState: LoadSegmentState;
		let detail: string;
		if (response.status === 'loading') {
			segmentState = 'active';
			detail = response.slow ? 'Still fetching (slow)…' : 'Fetching…';
		} else if (response.status === 'error') {
			segmentState = 'error';
			detail = response.message || 'Failed.';
		} else if (response.status === 'ok') {
			segmentState = 'done';
			detail = 'Loaded';
		} else {
			// Terminal non-error statuses (not_found, private, …) still mean
			// the request completed.
			segmentState = 'done';
			detail = statusMessage(provider.label, response);
		}
		return { label: provider.label, color: provider.color, state: segmentState, detail };
	});

/** Settled segments (loaded or failed) — feeds the N-of-M progress text. */
const settledSegmentCount = (segments: LoadSegment[]): number =>
	segments.filter((segment) => segment.state !== 'active').length;

/** True while any participating provider fetch is still in flight. */
const anyProviderLoading = (state: ViewState): boolean =>
	providerSegments(state).some((segment) => segment.state === 'active');

const renderBanner = (state: ViewState, steamId: string): string => {
	const profile = state.aggregated.data;
	const pendingSegments = anyProviderLoading(state) ? providerSegments(state) : [];
	if (!profile || profile.provider_count < 1) {
		// Never render an empty banner — show loading/error state instead.
		if (state.aggregated.status === 'error') {
			const message = state.aggregated.message || 'No data available';
			return `<div class="cs2ps-banner"><div class="cs2ps-banner-row">
				<span class="cs2ps-banner-title">CS2 Overview</span>
				<span class="cs2ps-banner-title" style="color:#ef4444"${tip(message)}>${escapeHtml(shortAggError(message))}</span>
			</div>${renderLoadingSegments(pendingSegments)}</div>`;
		}
		// Parallel fetch: providers settle independently, so surface progress
		// as "N of M sources" once the first responses land.
		const allSegments = providerSegments(state);
		const settled = settledSegmentCount(allSegments);
		const progress = settled > 0 ? ` ${settled}/${allSegments.length}` : '';
		return `<div class="cs2ps-banner"><div class="cs2ps-banner-row">
			<span class="cs2ps-banner-title">CS2 Overview</span>
			<span class="cs2ps-banner-title">Loading${progress} sources…</span>
		</div>${renderLoadingSegments(pendingSegments)}</div>`;
	}

	return renderOverviewBanner(profile, steamId, state.bannerExpanded, pendingSegments);
};

// ── Update aggregated state from current provider states ────────────

const updateAggregated = (state: ViewState): void => {
	try {
		const profile = buildAggregatedFromState(state);
		if (profile) {
			state.aggregated = { status: 'ok', data: profile };
		} else {
			const providerNames = ['leetify', 'faceit', 'cstracker', 'csrep', 'csstats'] as const;
			const providerStates = providerNames.map((n) => ({ name: n, status: state[n]?.status, hasData: !!state[n]?.data }));
			const anyLoading = providerStates.some((p) => p.status === 'loading');
			const anyOk = providerStates.some((p) => p.status === 'ok');
			if (!anyLoading && !anyOk) {
				state.aggregated = { status: 'error', data: undefined, message: 'No provider data available.' };
			} else if (anyOk) {
				// Providers reported ok but no usable payload — surface which ones.
				const missing = providerStates.filter((p) => p.status === 'ok' && !p.hasData).map((p) => p.name);
				state.aggregated = {
					status: 'error',
					data: undefined,
					message: missing.length ? `Aggregation failed (no data: ${missing.join(', ')}).` : 'Aggregation failed.',
				};
			} else {
				state.aggregated = { status: 'loading', data: state.aggregated.data };
			}
		}
	} catch (err) {
		// Log the full error (name, message, stack) to the webkit console so
		// the root cause stays copyable even though the banner shows a
		// shortened version that fits the single-line title.
		console.error('[CS2 Profile Stats] Aggregation failed:', err);
		const message = err instanceof Error ? err.message : String(err);
		state.aggregated = { status: 'error', data: undefined, message: `Aggregation error: ${message}` };
	}
};

const renderCard = (root: HTMLElement, state: ViewState, steamId: string) => {
	// Rebuild aggregated profile from current provider states on every render
	updateAggregated(state);

	const bannerHtml = safeRenderHtml(
		() => renderBanner(state, steamId),
		() => `<div class="cs2ps-banner"><div class="cs2ps-banner-row">
			<span class="cs2ps-banner-title">CS2 Overview</span>
			<span class="cs2ps-banner-title" style="color:#ef4444">Render error</span>
		</div></div>`,
	);
	const detailsHtml = safeRenderHtml(
		() => renderDetails(state, steamId),
		() => '<p class="cs2ps-detail-note">Details unavailable.</p>',
	);

	root.innerHTML = `
		<div class="cs2ps-card">
			${bannerHtml}
			${detailsHtml}
		</div>
	`;

	root.querySelectorAll<HTMLButtonElement>('.cs2ps-tab').forEach((tab) => {
		tab.addEventListener('click', () => {
			state.activeTab = tab.dataset.tab as DetailTab;
			renderCard(root, state, steamId);
		});
	});

	// Banner expand/collapse
	root.querySelector<HTMLElement>('[data-cs2ps-banner]')?.addEventListener('click', (e) => {
		// Don't toggle if clicking a link
		if ((e.target as HTMLElement).closest('a')) return;
		state.bannerExpanded = !state.bannerExpanded;
		renderCard(root, state, steamId);
	});

	root.querySelector<HTMLButtonElement>('[data-inventory-action]')?.addEventListener('click', () => {
		if (!/^\d{17}$/.test(steamId) || state.inventory.status === 'loading') return;
		state.inventory = { status: 'loading' };
		renderCard(root, state, steamId);
		void getInventoryValue(steamId)
			.then((inventory) => {
				state.inventory = inventory;
			})
			.catch((error) => {
				state.inventory = { status: 'error', message: error instanceof Error ? error.message : String(error) };
			})
			.finally(() => renderCard(root, state, steamId));
	});
};

type SteamInventoryPage = {
	success?: number;
	total_inventory_count?: number;
	more_items?: boolean;
	last_assetid?: string;
	assets?: Array<{ classid?: string; instanceid?: string; amount?: string }>;
	descriptions?: Array<{ classid?: string; instanceid?: string; marketable?: number; market_hash_name?: string }>;
};

const inventoryValueCache = new Map<string, Promise<InventoryState>>();
const INVENTORY_PAGE_SIZE = 2_000;
const MAX_INVENTORY_PAGES = 3;
const MAX_UNIQUE_MARKET_ITEMS = 60;
const MARKET_PRICE_CONCURRENCY = 4;

const parseUsdPrice = (value: unknown) => {
	if (typeof value !== 'string') return undefined;
	const parsed = Number(value.replace(/[^\d.,-]/g, '').replace(/,/g, ''));
	return Number.isFinite(parsed) ? parsed : undefined;
};

const fetchMarketPriceUsd = async (marketHashName: string) => {
	const url = new URL('/market/priceoverview/', window.location.origin);
	url.searchParams.set('appid', '730');
	url.searchParams.set('currency', '1');
	url.searchParams.set('market_hash_name', marketHashName);
	const response = await fetchWithTimeout(url, { credentials: 'same-origin' }, 8_000);
	if (!response.ok) return undefined;
	const payload = (await response.json()) as { success?: boolean; lowest_price?: string; median_price?: string };
	if (!payload.success) return undefined;
	return parseUsdPrice(payload.lowest_price) ?? parseUsdPrice(payload.median_price);
};

const fetchInventoryValue = async (steamId: string): Promise<InventoryState> => {
	const quantities = new Map<string, number>();
	const descriptions = new Map<string, NonNullable<SteamInventoryPage['descriptions']>[number]>();
	let totalItems = 0;
	let lastAssetId = '';
	let hasMoreItems = false;

	for (let pageIndex = 0; pageIndex < MAX_INVENTORY_PAGES; pageIndex += 1) {
		const url = new URL(`/inventory/${steamId}/730/2`, window.location.origin);
		url.searchParams.set('l', 'english');
		url.searchParams.set('count', String(INVENTORY_PAGE_SIZE));
		if (lastAssetId) url.searchParams.set('start_assetid', lastAssetId);
		const response = await fetchWithTimeout(url, { credentials: 'same-origin' }, 10_000);
		if (response.status === 401 || response.status === 403) return { status: 'private' };
		if (!response.ok) throw new Error(`Steam inventory returned HTTP ${response.status}.`);
		const payload = (await response.json()) as SteamInventoryPage;
		if (payload.success !== 1) return { status: 'private' };
		totalItems = finiteNumber(payload.total_inventory_count) ?? totalItems;
		for (const asset of payload.assets || []) {
			const key = `${asset.classid || ''}_${asset.instanceid || '0'}`;
			quantities.set(key, (quantities.get(key) || 0) + (finiteNumber(asset.amount) ?? 1));
		}
		for (const description of payload.descriptions || []) {
			const key = `${description.classid || ''}_${description.instanceid || '0'}`;
			descriptions.set(key, description);
		}
		hasMoreItems = payload.more_items === true;
		lastAssetId = payload.last_assetid || '';
		if (!hasMoreItems || !lastAssetId) break;
	}

	if (hasMoreItems) {
		return { status: 'too_large', totalItems };
	}

	const marketItems = new Map<string, number>();
	for (const [key, description] of descriptions) {
		if (description.marketable !== 1 || !description.market_hash_name) continue;
		marketItems.set(description.market_hash_name, (marketItems.get(description.market_hash_name) || 0) + (quantities.get(key) || 0));
	}
	const marketableItems = Array.from(marketItems.values()).reduce((sum, quantity) => sum + quantity, 0);
	if (marketItems.size > MAX_UNIQUE_MARKET_ITEMS) {
		return { status: 'too_large', totalItems, marketableItems };
	}

	const entries = Array.from(marketItems.entries());
	let cursor = 0;
	let valueUsd = 0;
	let pricedItems = 0;
	const worker = async () => {
		while (cursor < entries.length) {
			const entry = entries[cursor];
			cursor += 1;
			const [marketHashName, quantity] = entry;
			const price = await fetchMarketPriceUsd(marketHashName);
			if (price !== undefined) {
				valueUsd += price * quantity;
				pricedItems += quantity;
			}
		}
	};
	await Promise.all(Array.from({ length: Math.min(MARKET_PRICE_CONCURRENCY, Math.max(entries.length, 1)) }, () => worker()));
	if (marketableItems > 0 && pricedItems === 0) throw new Error('Steam Market prices are temporarily unavailable.');

	return { status: 'ok', valueUsd, totalItems, marketableItems, pricedItems };
};

const getInventoryValue = (steamId: string) => {
	const cached = inventoryValueCache.get(steamId);
	if (cached) return cached;
	const request = fetchInventoryValue(steamId).catch((error) => {
		inventoryValueCache.delete(steamId);
		throw error;
	});
	inventoryValueCache.set(steamId, request);
	return request;
};

const fetchSteamProfile = async (): Promise<SteamProfile> => {
	const baseUrl = profileBaseUrl();
	const parser = new DOMParser();
	const profileResponse = await fetchWithTimeout(`${baseUrl}?xml=1`, { credentials: 'same-origin' });
	if (!profileResponse.ok) throw new Error(`Steam profile returned HTTP ${profileResponse.status}.`);

	const profileXml = parser.parseFromString(await profileResponse.text(), 'application/xml');
	const steamId = profileXml.querySelector('steamID64')?.textContent || document.querySelector<HTMLInputElement>('input[name="abuseID"]')?.value || '';
	if (!/^\d{17}$/.test(steamId)) throw new Error('Could not determine SteamID64.');

	return {
		status: 'ok',
		steamId,
		memberSince: profileXml.querySelector('memberSince')?.textContent || undefined,
	};
};

const fetchSteamPlaytime = async (): Promise<Pick<SteamProfile, 'hours' | 'recentHours'>> => {
	const parser = new DOMParser();
	const gamesResponse = await fetchWithTimeout(`${profileBaseUrl()}/games?tab=all&xml=1`, { credentials: 'same-origin' }, 6_000);
	if (!gamesResponse.ok) return {};

	const gamesXml = parser.parseFromString(await gamesResponse.text(), 'application/xml');
	const cs2 = Array.from(gamesXml.querySelectorAll('game')).find((game) => game.querySelector('appID')?.textContent === '730');
	return {
		hours: cs2?.querySelector('hoursOnRecord')?.textContent || undefined,
		recentHours: cs2?.querySelector('hoursLast2Weeks')?.textContent || undefined,
	};
};

const injectStyles = () => {
	if (document.getElementById('cs2-profile-stats-styles')) return;
	const style = document.createElement('style');
	style.id = 'cs2-profile-stats-styles';
	style.textContent = styles;
	document.head.appendChild(style);
};

export default async function WebkitMain() {
	if (!isProfilePage() || document.getElementById('cs2-profile-stats')) return;

	injectStyles();
	installTooltips();

	const rightColumns = await Millennium.findElement(document, '.profile_rightcol', 8_000);
	const rightColumn = rightColumns.item(0);
	if (!rightColumn) return;

	const root = document.createElement('div');
	root.id = 'cs2-profile-stats';
	root.className = 'cs2ps-root';
	rightColumn.insertBefore(root, rightColumn.children.item(1));

	const state: ViewState = {
		leetify: { status: 'loading' },
		faceit: { status: 'loading' },
		cstracker: { status: 'loading' },
		csrep: { status: 'loading' },
		csstats: { status: 'loading' },
		cs2tracker: { status: 'loading' },
		tracker: { status: 'loading' },
		steam: { status: 'loading', steamId: '' },
		inventory: { status: 'idle' },
		preferences: { show_steam_details: true, expand_details: false },
		expanded: false,
		activeTab: 'overview',
		aggregated: { status: 'loading', data: undefined },
		bannerExpanded: false,
		loadProviders: CORE_PROVIDERS.map((name) => PROVIDER_DEFS[name]),
	};

	renderCard(root, state, '');

	try {
		state.preferences = parseJson<Preferences>(await getPreferences());
		state.expanded = state.preferences.expand_details;
	} catch (error) {
		console.warn('[CS2 Profile Stats] Could not load preferences:', error);
	}

	try {
		state.steam = await fetchSteamProfile();
	} catch (error) {
		const fallbackSteamId = document.querySelector<HTMLInputElement>('input[name="abuseID"]')?.value || '';
		state.steam = { status: 'error', steamId: fallbackSteamId, message: error instanceof Error ? error.message : String(error) };
	}

	const steamId = state.steam.steamId;
	if (!/^\d{17}$/.test(steamId)) {
		state.leetify = { status: 'error', message: 'SteamID64 is unavailable.' };
		state.faceit = { status: 'error', message: 'SteamID64 is unavailable.' };
		state.cstracker = { status: 'error', message: 'SteamID64 is unavailable.' };
		state.csrep = { status: 'error', message: 'SteamID64 is unavailable.' };
		state.csstats = { status: 'error', message: 'SteamID64 is unavailable.' };
		state.cs2tracker = { status: 'error', message: 'SteamID64 is unavailable.' };
		state.tracker = { status: 'error', message: 'SteamID64 is unavailable.' };
		renderCard(root, state, steamId);
		return;
	}

	renderCard(root, state, steamId);

	void fetchSteamPlaytime()
		.then((playtime) => {
			state.steam = { ...state.steam, ...playtime };
		})
		.catch((error) => {
			console.warn('[CS2 Profile Stats] Steam games are unavailable:', error);
		})
		.finally(() => renderCard(root, state, steamId));

	// Ask the backend which providers are actually registered and enabled.
	// The Lua VM fetches serially, so only participating providers are
	// fired — the rest would either error instantly or hang on IPC routes
	// the backend doesn't implement (e.g. cs2tracker/tracker are disabled).
	let participating = CORE_PROVIDERS;
	try {
		const configs = parseJson<Array<{ name?: unknown; enabled?: unknown }>>(
			await withTimeout(getProviderConfigs(), 8_000, 'Provider config request timed out.'),
		);
		const registered = new Map<string, boolean>();
		for (const config of configs) {
			if (typeof config.name === 'string') registered.set(config.name, config.enabled !== false);
		}
		participating = PROVIDER_ORDER.filter((name) => registered.get(name) === true);
	} catch (error) {
		console.warn('[CS2 Profile Stats] Could not read provider configs; fetching core providers only:', error);
	}

	state.loadProviders = participating.map((name) => PROVIDER_DEFS[name]);
	const participatingSet = new Set<string>(participating);
	for (const name of PROVIDER_ORDER) {
		if (!participatingSet.has(name)) {
			// Disabled in settings or not implemented — never requested.
			const def = PROVIDER_DEFS[name];
			// eslint-disable-next-line @typescript-eslint/no-explicit-any
			(state as any)[name] = { status: 'error', message: `${def.label} is disabled.` };
		}
	}
	renderCard(root, state, steamId);

	for (const name of participating) {
		const def = PROVIDER_DEFS[name];
		const request = PROVIDER_REQUESTS[name];
		requestProvider(
			request.callable({ steamId }),
			request.parse,
			def.label,
			(response) => {
				// Provider keys are dynamic; ViewState maps them 1:1 to responses.
				// eslint-disable-next-line @typescript-eslint/no-explicit-any
				(state as any)[name] = response;
				renderCard(root, state, steamId);
			},
		);
	}
}
