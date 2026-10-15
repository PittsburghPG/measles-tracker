// Counties the DOH dashboard's "Community Transmission" tab flags as having
// active local spread (as opposed to a case tied to travel or a known
// contact) — pulled by hand from that tab, since the daily scraper doesn't
// walk it yet. Mirrors visualizations/map-combined-embed.html's own
// TRANSMISSION_COUNTIES constant; keep the two in sync by hand when the
// tracked set changes.
export const TRANSMISSION_COUNTIES = [
	'Centre',
	'Chester',
	'Clearfield',
	'Indiana',
	'Jefferson',
	'Lancaster',
	'Mifflin',
	'Snyder',
	'York'
];
