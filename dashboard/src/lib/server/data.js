import path from 'node:path';
import { readTsv } from './tsv.js';

// This app lives in a subdirectory of the measles-tracker repo and reads
// the same TSVs the R scraper writes, rather than duplicating that data.
// `process.cwd()` is this project's own root (where `npm run build`/`dev`
// is invoked from), so the data directory is always one level up from it.
const DATA_DIR = path.resolve(process.cwd(), '..', 'data');

export function readCasesByCounty() {
	return readTsv(path.join(DATA_DIR, 'cases_by_county.tsv')).map((row) => ({
		date: row.date,
		county: row.county,
		new_cases: Number(row.new_cases),
		cumulative_cases: Number(row.cumulative_cases),
		cumulative_outbreak_cases: Number(row.cumulative_outbreak_cases),
		outbreak: Number(row.outbreak)
	}));
}

// Each county's most recent `cumulative_cases` is its running total for the
// year across both outbreaks — see cases_by_county.tsv's own column
// description in the repo README — so no separate summing is needed.
export function countyTotals(rows) {
	const latest = new Map();
	for (const row of rows) {
		const current = latest.get(row.county);
		if (!current || row.date > current.date) {
			latest.set(row.county, row);
		}
	}
	return Object.fromEntries([...latest].map(([county, row]) => [county, row.cumulative_cases]));
}

export function countiesWithData(rows) {
	return [...new Set(rows.map((row) => row.county))];
}

export function seriesForCounty(rows, county) {
	return rows.filter((row) => row.county === county).sort((a, b) => a.date.localeCompare(b.date));
}

// Buckets a county's daily rows into weeks starting Sunday, summing
// new_cases per week — mirroring how measles_scraper.R buckets the
// statewide weekly file (R's `cut(as.Date(date), "week")` also starts
// weeks on Sunday).
export function weeklyForCounty(dailySeries) {
	const byWeek = new Map();
	for (const row of dailySeries) {
		const wk = weekStart(row.date);
		byWeek.set(wk, (byWeek.get(wk) ?? 0) + row.new_cases);
	}
	return [...byWeek.entries()]
		.map(([week_start, new_cases]) => ({ week_start, new_cases }))
		.sort((a, b) => a.week_start.localeCompare(b.week_start));
}

function weekStart(dateStr) {
	const d = new Date(dateStr + 'T00:00:00Z');
	d.setUTCDate(d.getUTCDate() - d.getUTCDay());
	return d.toISOString().slice(0, 10);
}
