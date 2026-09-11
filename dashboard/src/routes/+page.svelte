<script>
	import MapChart from '$lib/MapChart.svelte';
	import WeeklyTrendChart from '$lib/WeeklyTrendChart.svelte';

	let { data } = $props();

	// Age-group codes as they appear in cases_by_age_group.tsv, spelled out
	// for the stat card — the raw codes (e.g. "0-4") read ambiguously
	// out of context.
	const AGE_GROUP_LABELS = {
		'0-4': '0 to 4 years old',
		'5-9': '5 to 9 years old',
		'10-17': '10 to 17 years old',
		'18-24': '18 to 24 years old',
		'25-49': '25 to 49 years old',
		'50-64': '50 to 64 years old',
		'65+': '65 and older',
		Unk: 'Unknown age'
	};

	// PDOH's dashboard doesn't expose a deaths count the scraper can walk —
	// this is hand-entered from their public reporting and needs updating by
	// hand if that changes.
	const DEATHS_NOTE =
		'The Pennsylvania Department of Health has reported that two individuals died after contracting measles in August. Later reporting identified the individuals as two infants — a newborn who suffered a splenic rupture and a six-week-old born with a genetic disorder.';
</script>

<svelte:head>
	<title>PA measles tracker</title>
</svelte:head>

<h1>Pennsylvania measles tracker</h1>
<p class="subhead">
	{data.totalCases} case{data.totalCases === 1 ? '' : 's'} reported across {Object.keys(data.totals).length} counties
	as of {data.lastUpdated}. Hover a county for its total; click a county with cases for its full history.
</p>

<div class="cards">
	<div class="card">
		<div class="card-total">{data.totalCases}</div>
		<div class="card-label">Total cases</div>
		<ul class="breakdown">
			{#each data.ageBreakdown as group (group.age_group)}
				<li><span>{AGE_GROUP_LABELS[group.age_group] ?? group.age_group}</span><span>{group.cases}</span></li>
			{/each}
		</ul>
	</div>

	<div class="card">
		<div class="card-total">{data.hospitalization.total}</div>
		<div class="card-label">Total hospitalizations</div>
		<ul class="breakdown">
			<li><span>Children (under 18)</span><span>{data.hospitalization.children}</span></li>
			<li><span>Adult (18+)</span><span>{data.hospitalization.adult}</span></li>
		</ul>
	</div>

	<div class="card">
		<div class="card-total">2</div>
		<div class="card-label">Deaths</div>
		<p class="card-note">{DEATHS_NOTE}</p>
	</div>
</div>

<MapChart totals={data.totals} />

<section class="weekly">
	<h2>Cases over time</h2>
	<WeeklyTrendChart data={data.weeklyCases} unitLabel="case" />
</section>

<style>
	h1 {
		font-size: 26px;
		margin-bottom: 6px;
	}

	.subhead {
		color: #555;
		margin-bottom: 20px;
		max-width: 640px;
	}

	.cards {
		display: flex;
		flex-wrap: wrap;
		gap: 20px;
		margin-bottom: 28px;
	}

	.card {
		flex: 1 1 220px;
		min-width: 0;
		border: 1px solid #eee;
		border-radius: 8px;
		padding: 16px 20px;
	}

	.card-total {
		font-size: 32px;
		font-weight: 700;
		line-height: 1.1;
	}

	.card-label {
		font-size: 13px;
		color: #555;
		margin-bottom: 10px;
	}

	.breakdown {
		list-style: none;
		margin: 0;
		padding: 10px 0 0;
		border-top: 1px solid #eee;
		font-size: 13px;
	}

	.breakdown li {
		display: flex;
		justify-content: space-between;
		padding: 2px 0;
		color: #333;
	}

	.breakdown li span:last-child {
		font-weight: 700;
		color: #1a1a1a;
	}

	.card-note {
		margin: 0;
		padding: 10px 0 0;
		border-top: 1px solid #eee;
		font-size: 13px;
		line-height: 1.5;
		color: #333;
	}

	.weekly {
		margin-top: 36px;
	}

	.weekly h2 {
		font-size: 15px;
		margin-bottom: 10px;
	}
</style>
