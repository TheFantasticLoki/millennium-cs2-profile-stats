/**
 * Shared floating tooltip — modern replacement for native title attrs.
 *
 * Triggers carry `data-cs2ps-tip="<html>"` (attribute-escaped by `tip()`).
 * A single fixed-position element renders the content on hover, so
 * tooltips can be styled and contain rich markup — colored rows, headings,
 * provider breakdowns — instead of the browser's plain title box.
 *
 * Handling is delegated on `document`, so it survives the banner's
 * innerHTML re-renders without re-binding.
 */

import { escapeHtml } from './helpers';

/** Attribute fragment placing rich HTML into a tooltip trigger. */
export const tip = (html: string): string => ` data-cs2ps-tip="${escapeHtml(html)}"`;

let tipEl: HTMLElement | null = null;
let current: HTMLElement | null = null;
let installed = false;

const ensureTip = (): HTMLElement => {
	if (tipEl) return tipEl;
	tipEl = document.createElement('div');
	tipEl.className = 'cs2ps-tip';
	tipEl.setAttribute('role', 'tooltip');
	document.body.appendChild(tipEl);
	return tipEl;
};

const findTrigger = (node: EventTarget | null): HTMLElement | null =>
	node instanceof Element ? node.closest<HTMLElement>('[data-cs2ps-tip]') : null;

const showTip = (trigger: HTMLElement) => {
	const el = ensureTip();
	const html = trigger.dataset.cs2psTip;
	if (!html) return;
	el.innerHTML = html;
	el.classList.add('cs2ps-tip-visible');

	// Above the trigger, centered; flip below when clipped at the top.
	const rect = trigger.getBoundingClientRect();
	const box = el.getBoundingClientRect();
	let top = rect.top - box.height - 8;
	if (top < 8) top = rect.bottom + 8;
	let left = rect.left + rect.width / 2 - box.width / 2;
	left = Math.min(Math.max(8, left), window.innerWidth - box.width - 8);
	el.style.top = `${Math.round(top)}px`;
	el.style.left = `${Math.round(left)}px`;
};

const hideTip = () => {
	tipEl?.classList.remove('cs2ps-tip-visible');
	current = null;
};

/** Install delegated hover handling once; safe to call repeatedly. */
export const installTooltips = () => {
	if (installed) return;
	installed = true;

	// mouseover/out fire on every child edge — only act on trigger changes.
	document.addEventListener('mouseover', (e) => {
		const trigger = findTrigger(e.target);
		if (trigger === current) return;
		current = trigger;
		if (trigger) showTip(trigger);
		else hideTip();
	});
	document.addEventListener('mouseout', (e) => {
		const from = findTrigger(e.target);
		const to = findTrigger(e.relatedTarget);
		if (from && from !== to) hideTip();
	});
	window.addEventListener('scroll', hideTip, true);
	document.addEventListener('mousedown', hideTip, true);
};
