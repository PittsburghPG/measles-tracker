<script>
	import MapChart from '$lib/MapChart.svelte';

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

<MapChart totals={data.totals} />

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
</style>
