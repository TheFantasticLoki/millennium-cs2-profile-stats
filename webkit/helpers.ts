/**
 * Shared formatting helpers for the CS2 Profile Stats webkit UI.
 *
 * These previously lived as module-local consts in `index.tsx` while the
 * split-out components referenced them through ambient `declare function`
 * statements. Ambient declarations produce no runtime binding, so the
 * bundler left the calls as free identifiers that resolved to undefined at
 * runtime (ReferenceError inside the banner/breakdown HTML builders).
 * They now live here and are explicitly imported by every consumer.
 */

export const escapeHtml = (value: unknown) =>
	String(value ?? '')
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#039;');

export const finiteNumber = (value: unknown): number | undefined => {
	const parsed = typeof value === 'number' ? value : Number(value);
	return Number.isFinite(parsed) ? parsed : undefined;
};

export const formatInteger = (value: unknown) => {
	const parsed = finiteNumber(value);
	return parsed === undefined ? '—' : new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(parsed);
};

export const formatMetric = (value: unknown, maximumFractionDigits = 1) => {
	const parsed = finiteNumber(value);
	return parsed === undefined ? '—' : new Intl.NumberFormat(undefined, { maximumFractionDigits }).format(parsed);
};

export const formatWinrate = (value: unknown) => {
	const parsed = finiteNumber(value);
	if (parsed === undefined) return '—';
	return `${formatMetric(parsed <= 1 ? parsed * 100 : parsed, 1)}%`;
};

export const formatPercent = (value: unknown) => {
	const parsed = finiteNumber(value);
	return parsed === undefined ? '—' : `${formatMetric(parsed, 1)}%`;
};

/**
 * "1 in X" odds label: one success per X attempts (e.g. 86W/38L → "1 in 1.4").
 * Values below 10 keep one decimal; above that they round to an integer.
 * Zero wins produce "—" (the event never happened).
 */
export const formatOneInX = (wins: unknown, losses: unknown) => {
	const w = finiteNumber(wins);
	const l = finiteNumber(losses);
	if (w === undefined || l === undefined || w <= 0) return '—';
	const x = (w + l) / w;
	return `1 in ${formatMetric(x, x < 10 ? 1 : 0)}`;
};

export const formatUsd = (value: unknown) => {
	const parsed = finiteNumber(value);
	return parsed === undefined ? '—' : new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(parsed);
};

export const hasValue = (value: unknown) => value !== undefined && value !== null && String(value).trim() !== '';

/**
 * Coerce a value to an array.
 *
 * Provider payloads are only type-checked at the TypeScript level — at
 * runtime a scrape drift or odd cache payload can hand back a string or
 * plain object where a list is expected, which used to make `.map` /
 * `for...of` iteration throw and wipe the whole aggregated profile with
 * an "X is not iterable" error. Non-arrays degrade to an empty list, so
 * the affected stat simply renders as missing instead of crashing.
 */
export const asArray = <T>(value: unknown): T[] => (Array.isArray(value) ? (value as T[]) : []);

export const formatSignedMetric = (value: unknown, maximumFractionDigits = 1) => {
	const parsed = finiteNumber(value);
	if (parsed === undefined) return '—';
	return `${parsed > 0 ? '+' : ''}${formatMetric(parsed, maximumFractionDigits)}`;
};

export const formatMapName = (value: string | undefined) => {
	if (!value) return 'Unknown map';
	const normalized = value.toLowerCase().replace(/^de_/, '');
	const names: Record<string, string> = {
		dust2: 'Dust II',
		mirage: 'Mirage',
		inferno: 'Inferno',
		nuke: 'Nuke',
		ancient: 'Ancient',
		anubis: 'Anubis',
		overpass: 'Overpass',
		vertigo: 'Vertigo',
		train: 'Train',
		cache: 'Cache',
	};
	return names[normalized] || normalized.replace(/(^|[_-])([a-z])/g, (_, separator: string, letter: string) => `${separator ? ' ' : ''}${letter.toUpperCase()}`);
};

export const formatMatchDate = (value: string | undefined) => {
	if (!value) return '';
	const date = new Date(value);
	if (Number.isNaN(date.getTime())) return '';
	return date.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
};

export const formatDataSource = (value: string | undefined) => {
	if (!value) return '';
	const normalized = value.toLowerCase();
	if (normalized.includes('faceit')) return 'FACEIT';
	if (normalized.includes('matchmaking')) return 'Matchmaking';
	return value.replace(/[_-]+/g, ' ');
};

export const formatScore = (score: number[] | undefined) =>
	Array.isArray(score) && score.length >= 2 ? `${formatInteger(score[0])}:${formatInteger(score[1])}` : '—';

/** Human-readable duration from milliseconds (used for reaction time). */
export const formatMilliseconds = (value: unknown) => {
	const parsed = finiteNumber(value);
	if (parsed === undefined) return '—';
	return parsed >= 1000 ? `${(parsed / 1000).toFixed(2)}s` : `${Math.round(parsed)}ms`;
};
