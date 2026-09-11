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
// new_cases per week and recomputing `cumulative` as a running sum of those
// weekly totals — mirroring how measles_scraper.R buckets and recomputes
// summary_weekly.tsv (R's `cut(as.Date(date), "week")` also starts weeks on
// Sunday). Field names (`new`/`cumulative`) match WeeklyTrendChart's generic
// shape so the same component can render this or the statewide weekly data.
export function weeklyForCounty(dailySeries) {
	const byWeek = new Map();
	for (const row of dailySeries) {
		const wk = weekStart(row.date);
		byWeek.set(wk, (byWeek.get(wk) ?? 0) + row.new_cases);
	}
	let cumulative = 0;
	return [...byWeek.entries()]
		.sort((a, b) => a[0].localeCompare(b[0]))
		.map(([week_start, weekNew]) => {
			cumulative += weekNew;
			return { week_start, new: weekNew, cumulative };
		});
}

export function readWeeklySummary() {
	return readTsv(path.join(DATA_DIR, 'summary_weekly.tsv'))
		.map((row) => ({
			week_start: row.week_start,
			new: Number(row.new_cases),
			cumulative: Number(row.cumulative_cases)
		}))
		.sort((a, b) => a.week_start.localeCompare(b.week_start));
}

// Statewide hospitalization totals as of the most recent date recorded,
// broken out by hospitalization_by_age_group.tsv's three categories — for
// the "Total hospitalizations" stat card, not a time series.
export function latestHospitalizationBreakdown() {
	const rows = readTsv(path.join(DATA_DIR, 'hospitalization_by_age_group.tsv'));
	const asOf = rows.reduce((max, row) => (row.date > max ? row.date : max), '');
	const byCategory = Object.fromEntries(
		rows.filter((row) => row.date === asOf).map((row) => [row.category, Number(row.cumulative_hospitalizations)])
	);
	return {
		asOf,
		total: byCategory.total ?? 0,
		children: byCategory.children ?? 0,
		adult: byCategory.adult ?? 0
	};
}

const AGE_GROUP_ORDER = ['0-4', '5-9', '10-17', '18-24', '25-49', '50-64', '65+', 'Unk'];

// Statewide case totals as of each age group's most recent recorded
// cumulative_cases — for the "Total cases" stat card's age breakdown, not a
// time series.
export function latestAgeGroupBreakdown() {
	const rows = readTsv(path.join(DATA_DIR, 'cases_by_age_group.tsv')).map((row) => ({
		date: row.date,
		age_group: row.age_group,
		cumulative_cases: Number(row.cumulative_cases)
	}));

	const latest = new Map();
	for (const row of rows) {
		const current = latest.get(row.age_group);
		if (!current || row.date > current.date) latest.set(row.age_group, row);
	}

	return AGE_GROUP_ORDER.filter((group) => latest.has(group)).map((age_group) => ({
		age_group,
		cases: latest.get(age_group).cumulative_cases
	}));
}

function weekStart(dateStr) {
	const d = new Date(dateStr + 'T00:00:00Z');
	d.setUTCDate(d.getUTCDate() - d.getUTCDay());
	return d.toISOString().slice(0, 10);
}
