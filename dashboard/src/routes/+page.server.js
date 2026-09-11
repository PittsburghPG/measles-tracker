import { readCasesByCounty, countyTotals, countiesWithData } from '$lib/server/data.js';

export const prerender = true;

export function load() {
	const rows = readCasesByCounty();
	const totals = countyTotals(rows);
	const totalCases = Object.values(totals).reduce((sum, n) => sum + n, 0);
	const lastUpdated = rows.reduce((max, row) => (row.date > max ? row.date : max), '');

	return {
		totals,
		totalCases,
		lastUpdated,
		countiesWithData: countiesWithData(rows)
	};
}
