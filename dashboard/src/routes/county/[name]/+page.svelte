<script>
	import LineChart from '$lib/LineChart.svelte';
	import BarChart from '$lib/BarChart.svelte';

	let { data } = $props();

	// Most recent first, for scanning the latest reports at a glance.
	const tableRows = $derived([...data.daily].reverse());
</script>

<svelte:head>
	<title>{data.county} County — PA measles tracker</title>
</svelte:head>

<a class="back" href="/">&larr; Back to statewide map</a>

<h1>{data.county} County</h1>
<p class="subhead">{data.totalCases} total case{data.totalCases === 1 ? '' : 's'} reported this year.</p>

<div class="layout">
	<div class="charts">
		<section>
			<h2>Cumulative cases</h2>
			<LineChart data={data.daily} />
		</section>

		<section>
			<h2>Weekly reports</h2>
			<BarChart data={data.weekly} />
		</section>
	</div>

	<div class="table-wrap">
		<h2>Raw data</h2>
		<table>
			<thead>
				<tr>
					<th>Date</th>
					<th>New cases</th>
					<th>Cumulative</th>
				</tr>
			</thead>
			<tbody>
				{#each tableRows as row (row.date)}
					<tr>
						<td>{row.date}</td>
						<td>{row.new_cases}</td>
						<td>{row.cumulative_cases}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
</div>

<style>
	.back {
		display: inline-block;
		margin-bottom: 12px;
		color: #a93226;
		text-decoration: none;
		font-size: 14px;
	}

	.back:hover {
		text-decoration: underline;
	}

	h1 {
		font-size: 26px;
		margin-bottom: 4px;
	}

	.subhead {
		color: #555;
		margin-bottom: 20px;
	}

	h2 {
		font-size: 16px;
		margin-bottom: 10px;
	}

	.layout {
		display: flex;
		gap: 32px;
		align-items: flex-start;
		flex-wrap: wrap;
	}

	.charts {
		flex: 2 1 480px;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 28px;
	}

	.table-wrap {
		flex: 1 1 260px;
		min-width: 0;
		max-height: 560px;
		overflow-y: auto;
	}

	table {
		width: 100%;
		border-collapse: collapse;
		font-size: 13px;
	}

	th,
	td {
		text-align: right;
		padding: 4px 8px;
		border-bottom: 1px solid #eee;
	}

	th:first-child,
	td:first-child {
		text-align: left;
	}

	th {
		position: sticky;
		top: 0;
		background: #fff;
		color: #555;
		font-weight: 700;
	}
</style>
