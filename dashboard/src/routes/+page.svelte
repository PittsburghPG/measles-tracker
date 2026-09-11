<script>
	import MapChart from '$lib/MapChart.svelte';
	import WeeklyTrendChart from '$lib/WeeklyTrendChart.svelte';

	let { data } = $props();
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
				<li><span>{group.age_group}</span><span>{group.cases}</span></li>
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

	.weekly {
		margin-top: 36px;
	}

	.weekly h2 {
		font-size: 15px;
		margin-bottom: 10px;
	}
</style>
