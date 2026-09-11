<script>
	import * as d3 from 'd3';

	// `data`: array of { date: 'YYYY-MM-DD', cumulative_cases: number }
	let { data } = $props();

	let container = $state();
	let svgEl = $state();
	let tooltip = $state({ visible: false, x: 0, y: 0, date: '', value: 0 });

	const parseDate = d3.utcParse('%Y-%m-%d');
	const formatDate = d3.utcFormat('%b %-d, %Y');

	function render() {
		if (!container || !svgEl || data.length === 0) return;

		const width = container.getBoundingClientRect().width || 640;
		const height = 260;
		const margin = { top: 12, right: 16, bottom: 24, left: 40 };
		const w = width - margin.left - margin.right;
		const h = height - margin.top - margin.bottom;

		const points = data.map((d) => ({ date: parseDate(d.date), value: d.cumulative_cases }));

		const x = d3
			.scaleUtc()
			.domain(d3.extent(points, (d) => d.date))
			.range([0, w]);
		const y = d3
			.scaleLinear()
			.domain([0, d3.max(points, (d) => d.value) * 1.08])
			.range([h, 0])
			.nice();

		const svg = d3.select(svgEl).attr('viewBox', `0 0 ${width} ${height}`).attr('width', width).attr('height', height);
		svg.selectAll('*').remove();
		const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

		g.append('g')
			.attr('class', 'grid')
			.call(d3.axisLeft(y).ticks(5).tickSize(-w).tickFormat(''));

		g.append('g').attr('class', 'axis').call(d3.axisLeft(y).ticks(5));

		g.append('g')
			.attr('class', 'axis')
			.attr('transform', `translate(0,${h})`)
			.call(d3.axisBottom(x).ticks(Math.min(6, points.length)));

		const line = d3
			.line()
			.x((d) => x(d.date))
			.y((d) => y(d.value))
			.curve(d3.curveStepAfter);

		g.append('path').datum(points).attr('class', 'line').attr('d', line);

		const focus = g.append('g').style('display', 'none');
		focus.append('line').attr('class', 'hover-line').attr('y1', 0).attr('y2', h);
		focus.append('circle').attr('class', 'hover-dot').attr('r', 4);

		const bisect = d3.bisector((d) => d.date).left;

		g.append('rect')
			.attr('width', w)
			.attr('height', h)
			.attr('fill', 'transparent')
			.on('mousemove', (event) => {
				const [mx, my] = d3.pointer(event);
				const date = x.invert(mx);
				const i = Math.min(points.length - 1, Math.max(0, bisect(points, date)));
				const d = points[i];
				focus.style('display', null);
				focus.select('.hover-line').attr('x1', x(d.date)).attr('x2', x(d.date));
				focus.select('.hover-dot').attr('cx', x(d.date)).attr('cy', y(d.value));
				tooltip = {
					visible: true,
					x: margin.left + x(d.date),
					y: margin.top + y(d.value),
					date: formatDate(d.date),
					value: d.value
				};
			})
			.on('mouseleave', () => {
				focus.style('display', 'none');
				tooltip = { ...tooltip, visible: false };
			});
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
			<strong>{tooltip.value}</strong> total case{tooltip.value === 1 ? '' : 's'}<br />
			{tooltip.date}
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

	:global(.line) {
		fill: none;
		stroke: #a93226;
		stroke-width: 2;
	}

	:global(.hover-line) {
		stroke: #999;
		stroke-dasharray: 3 3;
	}

	:global(.hover-dot) {
		fill: #a93226;
		stroke: #fff;
		stroke-width: 1.5;
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
