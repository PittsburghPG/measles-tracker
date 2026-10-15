import { readFileSync } from 'node:fs';

/**
 * Parses a TSV string (as written by the scraper's write_tsv(), na = "")
 * into an array of row objects keyed by the header line.
 */
export function parseTsv(text) {
	const lines = text.trim().split('\n');
	const headers = lines[0].split('\t');
	return lines.slice(1).map((line) => {
		const cells = line.split('\t');
		const row = {};
		headers.forEach((header, i) => {
			row[header] = cells[i] ?? '';
		});
		return row;
	});
}

export function readTsv(path) {
	return parseTsv(readFileSync(path, 'utf-8'));
}
