<script>
	import * as d3 from 'd3';

	// `data`: array of { age_group: string, points: [{ date: 'YYYY-MM-DD', cumulative_cases: number }] }
	let { data } = $props();

	let container = $state();
	let svgEl = $state();
	let tooltip = $state({ visible: false, x: 0, y: 0, html: '' });

	const parseDate = d3.utcParse('%Y-%m-%d');
	const formatDate = d3.utcFormat('%b %-d, %Y');
	const color = d3.scaleOrdinal(d3.schemeCategory10);

	function render() {
		if (!container || !svgEl || data.length === 0) return;

		const margin = { top: 12, right: 16, bottom: 24, left: 36 };
		const totalW = container.getBoundingClientRect().width || 640;
		const totalH = 220;
		const w = totalW - margin.left - margin.right;
		const h = totalH - margin.top - margin.bottom;

		const series = data.map((s) => ({
			age_group: s.age_group,
			points: s.points.map((p) => ({ date: parseDate(p.date), value: p.cumulative_cases }))
		}));

		const allDates = series.flatMap((s) => s.points.map((p) => p.date));
		const allValues = series.flatMap((s) => s.points.map((p) => p.value));

		const x = d3.scaleUtc().domain(d3.extent(allDates)).range([0, w]);
		const y = d3
			.scaleLinear()
			.domain([0, (d3.max(allValues) || 1) * 1.08])
			.range([h, 0])
			.nice();

		const svg = d3.select(svgEl).attr('viewBox', `0 0 ${totalW} ${totalH}`).attr('width', totalW).attr('height', totalH);
		svg.selectAll('*').remove();
		const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

		g.append('g')
			.call(d3.axisLeft(y).ticks(4).tickSize(-w).tickFormat(''))
			.call((ax) => ax.selectAll('line').attr('stroke', '#eee'))
			.call((ax) => ax.select('.domain').remove());
		g.append('g').attr('class', 'axis').call(d3.axisLeft(y).ticks(4));
		g.append('g')
			.attr('class', 'axis')
			.attr('transform', `translate(0,${h})`)
			.call(d3.axisBottom(x).ticks(Math.min(5, allDates.length)).tickFormat(d3.utcFormat('%b %-d')));

		const line = d3
			.line()
			.x((d) => x(d.date))
			.y((d) => y(d.value))
			.curve(d3.curveStepAfter);

		g.selectAll('.age-line')
			.data(series)
			.join('path')
			.attr('class', 'age-line')
			.attr('fill', 'none')
			.attr('stroke', (s) => color(s.age_group))
			.attr('stroke-width', 2)
			.attr('d', (s) => line(s.points));

		// Invisible hit-areas, one per series' last point, so hovering near
		// the end of any line (the densest, most-current region) shows which
		// group it belongs to — full-line hover isn't needed since the
		// legend already labels each color.
		g.selectAll('.age-dot')
			.data(series.filter((s) => s.points.length > 0))
			.join('circle')
			.attr('class', 'age-dot')
			.attr('cx', (s) => x(s.points[s.points.length - 1].date))
			.attr('cy', (s) => y(s.points[s.points.length - 1].value))
			.attr('r', 4)
			.attr('fill', (s) => color(s.age_group))
			.style('cursor', 'pointer')
			.on('mousemove', (event, s) => {
				const [mx, my] = d3.pointer(event, container);
				const last = s.points[s.points.length - 1];
				tooltip = {
					visible: true,
					x: mx + 12,
					y: my - 10,
					html: `<strong>${s.age_group}</strong><br>${last.value} case${last.value === 1 ? '' : 's'}<br>as of ${formatDate(last.date)}`
				};
			})
			.on('mouseleave', () => (tooltip = { ...tooltip, visible: false }));
	}

	$effect(() => {
		data;
		render();
	});

	$effect(() => {
		if (!container) return;
		const observer = new ResizeObserver(() => render());
		observer.observe(container);
		return () => observer.disconnect();
	});
</script>

<div class="chart-wrap" bind:this={container}>
	<svg bind:this={svgEl}></svg>
	{#if tooltip.visible}
		<div class="tooltip" style="left: {tooltip.x}px; top: {tooltip.y}px;">{@html tooltip.html}</div>
	{/if}
</div>

<div class="legend">
	{#each data as s (s.age_group)}
		<span class="legend-item"><span class="swatch" style="background: {color(s.age_group)}"></span>{s.age_group}</span>
	{/each}
</div>

<style>
	.chart-wrap {
		position: relative;
		width: 100%;
	}

	svg {
		display: block;
		width: 100%;
		overflow: visible;
	}

	:global(.axis) {
		font-family: 'Roboto', Arial, sans-serif;
		font-size: 11px;
		color: #555;
	}

	.legend {
		display: flex;
		flex-wrap: wrap;
		gap: 8px 14px;
		margin-top: 10px;
		font-size: 12px;
		color: #333;
	}

	.legend-item {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		white-space: nowrap;
	}

	.swatch {
		width: 10px;
		height: 10px;
		border-radius: 2px;
		display: inline-block;
	}

	.tooltip {
		position: absolute;
		pointer-events: none;
		background: #1a1a1a;
		color: #fff;
		font-family: 'Roboto', Arial, sans-serif;
		font-size: 13px;
		line-height: 1.4;
		padding: 6px 10px;
		border-radius: 4px;
		white-space: nowrap;
		z-index: 10;
	}
</style>
