<script>
	import * as d3 from 'd3';
	import { goto } from '$app/navigation';
	import { PA_TOPOLOGY, PA_FIPS } from '$lib/paCounties.js';
	import { feature as topoFeature } from 'topojson-client';

	let { totals } = $props();

	let container = $state();
	let svgEl = $state();
	let tooltip = $state({ visible: false, x: 0, y: 0, name: '', cases: 0 });

	const paCounties = topoFeature(PA_TOPOLOGY, PA_TOPOLOGY.objects.counties);

	function casesFor(name) {
		return totals[name] ?? 0;
	}

	function showTip(event, name) {
		tooltip = { visible: true, x: event.offsetX, y: event.offsetY, name, cases: casesFor(name) };
	}
	function hideTip() {
		tooltip = { ...tooltip, visible: false };
	}

	function selectCounty(name) {
		if (casesFor(name) > 0) goto(`/county/${name}`);
	}

	function render() {
		if (!container || !svgEl) return;
		const VIEW_W = container.getBoundingClientRect().width || 680;

		const raw = d3.geoMercator().scale(1).translate([0, 0]);
		const rawPath = d3.geoPath().projection(raw);
		const [[x0, y0], [x1, y1]] = rawPath.bounds(paCounties);

		const padLeft = 4,
			padRight = 4,
			padTop = 8,
			padBottom = 8;
		const k = (VIEW_W - padLeft - padRight) / (x1 - x0);
		const tx = padLeft - k * x0;
		const ty = padTop - k * y0;
		const VIEW_H = padTop + k * (y1 - y0) + padBottom;

		const svg = d3.select(svgEl).attr('viewBox', `0 0 ${VIEW_W} ${VIEW_H}`).attr('width', VIEW_W).attr('height', VIEW_H);

		const projection = d3.geoTransform({
			point(lon, lat) {
				const [x, y] = raw([lon, lat]);
				this.stream.point(x * k + tx, y * k + ty);
			}
		});
		const path = d3.geoPath().projection(projection);

		const maxCases = d3.max(Object.values(totals)) || 1;
		const sizeFactor = Math.sqrt(Math.min(1, VIEW_W / 680));
		const rScaleRaw = d3.scaleSqrt().domain([0, maxCases]).range([0, 46 * sizeFactor]);
		const rScale = (v) => Math.max(9, 10 * sizeFactor, rScaleRaw(v));
		const LABEL_MIN = 5;
		const DOT_RADIUS = Math.max(1.75, 2.25 * sizeFactor);

		svg.selectAll('*').remove();
		const g = svg.append('g');

		g.selectAll('path.county')
			.data(paCounties.features)
			.join('path')
			.attr('class', (d) => {
				const name = PA_FIPS[d.id];
				return casesFor(name) > 0 ? 'county affected' : 'county';
			})
			.attr('d', path)
			.style('cursor', (d) => (casesFor(PA_FIPS[d.id]) > 0 ? 'pointer' : 'default'))
			.on('mousemove', (event, d) => showTip(event, PA_FIPS[d.id]))
			.on('mouseleave', hideTip)
			.on('click', (event, d) => selectCounty(PA_FIPS[d.id]));

		const centroids = paCounties.features.map((f) => ({
			name: PA_FIPS[f.id],
			cases: casesFor(PA_FIPS[f.id]),
			center: path.centroid(f)
		}));

		const bubbleGroup = g
			.selectAll('g.bubble-g')
			.data(centroids.filter((d) => d.cases >= LABEL_MIN))
			.join('g')
			.attr('class', 'bubble-g')
			.attr('transform', (d) => `translate(${d.center[0]},${d.center[1]})`)
			.style('cursor', 'pointer')
			.on('mousemove', (event, d) => showTip(event, d.name))
			.on('mouseleave', hideTip)
			.on('click', (event, d) => selectCounty(d.name));

		bubbleGroup.append('circle').attr('class', 'bubble').attr('r', (d) => rScale(d.cases));
		bubbleGroup
			.append('text')
			.attr('class', 'bubble-label')
			.attr('text-anchor', 'middle')
			.attr('dy', '0.35em')
			.text((d) => d.cases);

		g.selectAll('circle.dot')
			.data(centroids.filter((d) => d.cases > 0 && d.cases < LABEL_MIN))
			.join('circle')
			.attr('class', 'dot')
			.attr('cx', (d) => d.center[0])
			.attr('cy', (d) => d.center[1])
			.attr('r', DOT_RADIUS)
			.style('cursor', 'pointer')
			.on('mousemove', (event, d) => showTip(event, d.name))
			.on('mouseleave', hideTip)
			.on('click', (event, d) => selectCounty(d.name));
	}

	$effect(() => {
		// Re-render whenever the container mounts or `totals` changes.
		totals;
		render();
	});

	$effect(() => {
		if (!container) return;
		const observer = new ResizeObserver(() => render());
		observer.observe(container);
		return () => observer.disconnect();
	});
</script>

<div class="map-wrap" bind:this={container}>
	<svg bind:this={svgEl} role="img" aria-label="Map of measles cases by Pennsylvania county"></svg>

	{#if tooltip.visible}
		<div class="tooltip" style="left: {tooltip.x + 12}px; top: {tooltip.y + 12}px;">
			<strong>{tooltip.name} County</strong><br />
			{tooltip.cases} case{tooltip.cases === 1 ? '' : 's'}
			{#if tooltip.cases > 0}<br /><span class="hint">Click for details</span>{/if}
		</div>
	{/if}
</div>

<style>
	.map-wrap {
		position: relative;
		width: 100%;
	}

	svg {
		display: block;
		width: 100%;
	}

	:global(.county) {
		fill: #eee;
		stroke: #fff;
		stroke-width: 0.75px;
	}

	:global(.county.affected) {
		fill: #f0ddd5;
	}

	:global(.bubble) {
		fill: #a93226;
		fill-opacity: 0.16;
		stroke: #a93226;
		stroke-width: 1px;
		transition: fill-opacity 0.1s;
	}

	:global(.bubble-g:hover .bubble) {
		fill-opacity: 0.4;
	}

	:global(.bubble-label) {
		font-family: 'Roboto', Arial, sans-serif;
		font-size: 11px;
		font-weight: 700;
		fill: #7a1a10;
		pointer-events: none;
	}

	:global(.dot) {
		fill: #a93226;
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

	.tooltip .hint {
		color: #ccc;
		font-size: 11px;
	}
</style>
