import { error } from '@sveltejs/kit';
import { readCasesByCounty, countiesWithData, seriesForCounty, weeklyForCounty } from '$lib/server/data.js';

export const prerender = true;

// Tells the adapter-static prerenderer which /county/<name> pages exist —
// only counties with at least one recorded case get a page (matching
// MapChart.svelte, which only makes counties with cases > 0 clickable).
export function entries() {
	return countiesWithData(readCasesByCounty()).map((name) => ({ name }));
}

export function load({ params }) {
	const rows = readCasesByCounty();
	const daily = seriesForCounty(rows, params.name);

	if (daily.length === 0) {
		error(404, `No case data recorded for ${params.name} County`);
	}

	return {
		county: params.name,
		daily,
		weekly: weeklyForCounty(daily),
		totalCases: daily[daily.length - 1].cumulative_cases
	};
}
