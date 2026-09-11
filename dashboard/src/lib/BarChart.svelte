<script>
	import * as d3 from 'd3';

	// `data`: array of { week_start: 'YYYY-MM-DD', new_cases: number }
	let { data } = $props();

	let container = $state();
	let svgEl = $state();
	let tooltip = $state({ visible: false, x: 0, y: 0, label: '', value: 0 });

	const parseDate = d3.utcParse('%Y-%m-%d');
	const formatDate = d3.utcFormat('%b %-d, %Y');

	function render() {
		if (!container || !svgEl || data.length === 0) return;

		const width = container.getBoundingClientRect().width || 640;
		const height = 200;
		const margin = { top: 12, right: 16, bottom: 24, left: 40 };
		const w = width - margin.left - margin.right;
		const h = height - margin.top - margin.bottom;

		const points = data.map((d) => ({ date: parseDate(d.week_start), value: d.new_cases }));

		const x = d3
			.scaleUtc()
			.domain(d3.extent(points, (d) => d.date))
			.range([0, w]);
		const y = d3
			.scaleLinear()
			.domain([0, (d3.max(points, (d) => d.value) || 1) * 1.15])
			.range([h, 0])
			.nice();

		// One week's pixel width at the current scale, used to size bars.
		const weekMs = 7 * 24 * 60 * 60 * 1000;
		const barWidth = Math.max(2, (x(new Date(+points[0].date + weekMs)) - x(points[0].date)) * 0.7);

		const svg = d3.select(svgEl).attr('viewBox', `0 0 ${width} ${height}`).attr('width', width).attr('height', height);
		svg.selectAll('*').remove();
		const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

		g.append('g')
			.attr('class', 'grid')
			.call(d3.axisLeft(y).ticks(4).tickSize(-w).tickFormat(''));
		g.append('g').attr('class', 'axis').call(d3.axisLeft(y).ticks(4));
		g.append('g')
			.attr('class', 'axis')
			.attr('transform', `translate(0,${h})`)
			.call(d3.axisBottom(x).ticks(Math.min(6, points.length)));

		g.selectAll('rect.bar')
			.data(points)
			.join('rect')
			.attr('class', 'bar')
			.attr('x', (d) => x(d.date) - barWidth / 2)
			.attr('y', (d) => y(d.value))
			.attr('width', barWidth)
			.attr('height', (d) => h - y(d.value))
			.on('mousemove', (event, d) => {
				tooltip = {
					visible: true,
					x: margin.left + x(d.date),
					y: margin.top + y(d.value),
					label: formatDate(d.date),
					value: d.value
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
		<div class="tooltip" style="left: {tooltip.x + 12}px; top: {tooltip.y - 8}px;">
			<strong>{tooltip.value}</strong> case{tooltip.value === 1 ? '' : 's'} that week<br />
			Week of {tooltip.label}
		</div>
	{/if}
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

	:global(.bar) {
		fill: #a93226;
	}

	:global(.axis) {
		font-family: 'Roboto', Arial, sans-serif;
		font-size: 11px;
		color: #555;
	}

	:global(.grid line) {
		stroke: #eee;
	}

	:global(.grid path) {
		display: none;
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
