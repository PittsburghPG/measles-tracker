<script>
	import * as d3 from 'd3';

	// `data`: array of { week_start: 'YYYY-MM-DD', new: number, cumulative: number },
	// sorted ascending. `unitLabel`: singular noun for tooltip text, e.g. "case".
	let { data, unitLabel = 'case' } = $props();

	let container = $state();
	let svgEl = $state();
	let tooltip = $state({ visible: false, x: 0, y: 0, html: '' });

	const parseWeek = (s) => new Date(s + 'T12:00:00Z');
	const msPerWeek = 7 * 24 * 60 * 60 * 1000;
	const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
	const apMonths = ['Jan', 'Feb', 'March', 'April', 'May', 'June', 'July', 'Aug', 'Sept', 'Oct', 'Nov', 'Dec'];
	const fmtWeek = (d) => `${months[d.getUTCMonth()]} ${d.getUTCDate()}`;

	function tipHtml(d) {
		const n = d.new;
		return `<strong>Week of ${fmtWeek(parseWeek(d.week_start))}</strong><br>${n} ${unitLabel}${n === 1 ? '' : 's'} reported<br>${d.cumulative} cumulative`;
	}

	function render() {
		if (!container || !svgEl || data.length === 0) return;

		const margin = { top: 20, right: 16, bottom: 32, left: 36 };
		const totalW = container.getBoundingClientRect().width || 640;
		const totalH = 220;
		const w = totalW - margin.left - margin.right;
		const h = totalH - margin.top - margin.bottom;

		const svg = d3.select(svgEl).attr('viewBox', `0 0 ${totalW} ${totalH}`).attr('width', totalW).attr('height', totalH);
		svg.selectAll('*').remove();
		const g = svg.append('g').attr('transform', `translate(${margin.left},${margin.top})`);

		const weekDates = data.map((d) => parseWeek(d.week_start));
		const domainStart = new Date(d3.min(weekDates).getTime() - msPerWeek * 0.5);
		const domainEnd = new Date(d3.max(weekDates).getTime() + msPerWeek * 0.5);
		const x = d3.scaleTime().domain([domainStart, domainEnd]).range([0, w]);

		const weekPx = (w * msPerWeek) / (domainEnd - domainStart);
		const barWidth = Math.max(2, weekPx * 0.65);
		const centerX = (d) => x(parseWeek(d.week_start));
		const barX = (d) => centerX(d) - barWidth / 2;

		const maxY = d3.max(data, (d) => d.cumulative) || 1;
		const y = d3
			.scaleLinear()
			.domain([0, Math.ceil(maxY * 1.12)])
			.range([h, 0]);

		g.append('g')
			.call(d3.axisLeft(y).ticks(4))
			.call((ax) => ax.select('.domain').remove())
			.call((ax) => ax.selectAll('line').attr('stroke', '#eee').attr('stroke-dasharray', '2,2').attr('x2', w))
			.call((ax) => ax.selectAll('text').attr('class', 'axis-text'));

		g.append('g')
			.attr('transform', `translate(0,${h})`)
			.call(d3.axisBottom(x).tickValues(weekDates).tickFormat('').tickSize(5))
			.call((ax) => ax.select('.domain').attr('stroke', '#ccc'))
			.call((ax) => ax.selectAll('line').attr('stroke', '#ccc'));

		// Month boundary lines + centered labels, dropping any that would
		// collide at narrow widths — see visualizations/weekly-trend-embed.html
		// for the reasoning behind placing boundaries at week midpoints.
		const boundaryBetweenWeeks = (target) => {
			for (let i = 0; i < weekDates.length - 1; i++) {
				if (weekDates[i] <= target && target < weekDates[i + 1]) {
					return new Date((weekDates[i].getTime() + weekDates[i + 1].getTime()) / 2);
				}
			}
			return target < weekDates[0] ? weekDates[0] : weekDates[weekDates.length - 1];
		};

		const monthSpans = [];
		const monthBoundaries = [];
		let curMonth = new Date(Date.UTC(domainStart.getUTCFullYear(), domainStart.getUTCMonth(), 1));
		let isFirstMonth = true;
		while (curMonth < domainEnd) {
			if (!isFirstMonth) monthBoundaries.push(boundaryBetweenWeeks(curMonth));
			isFirstMonth = false;
			const nextMonth = new Date(Date.UTC(curMonth.getUTCFullYear(), curMonth.getUTCMonth() + 1, 1));
			const spanStart = curMonth < domainStart ? domainStart : curMonth;
			const spanEnd = nextMonth > domainEnd ? domainEnd : nextMonth;
			monthSpans.push({ month: curMonth.getUTCMonth(), center: new Date((spanStart.getTime() + spanEnd.getTime()) / 2) });
			curMonth = nextMonth;
		}

		g.selectAll('.month-boundary')
			.data(monthBoundaries)
			.join('line')
			.attr('class', 'month-boundary')
			.attr('x1', (d) => x(d))
			.attr('x2', (d) => x(d))
			.attr('y1', h)
			.attr('y2', h + 18)
			.attr('stroke', '#ccc');

		const monthLabels = g
			.selectAll('.month-label')
			.data(monthSpans)
			.join('text')
			.attr('class', 'month-label axis-text')
			.attr('x', (d) => x(d.center))
			.attr('y', h + 22)
			.attr('text-anchor', 'middle')
			.text((d) => apMonths[d.month]);

		const monthNodes = monthLabels.nodes();
		if (monthNodes.length > 0) {
			const keep = new Set([0, monthNodes.length - 1]);
			let lastRight = monthNodes[0].getBBox().x + monthNodes[0].getBBox().width;
			for (let i = 1; i < monthNodes.length - 1; i++) {
				const bbox = monthNodes[i].getBBox();
				if (bbox.x > lastRight + 4) {
					keep.add(i);
					lastRight = bbox.x + bbox.width;
				}
			}
			const lastBBox = monthNodes[monthNodes.length - 1].getBBox();
			for (let i = monthNodes.length - 2; i > 0; i--) {
				if (!keep.has(i)) continue;
				const bbox = monthNodes[i].getBBox();
				if (bbox.x + bbox.width > lastBBox.x - 4) {
					keep.delete(i);
				} else {
					break;
				}
			}
			monthNodes.forEach((node, i) => {
				if (!keep.has(i)) d3.select(node).remove();
			});
		}

		const showTip = (event, d) => {
			const [mx, my] = d3.pointer(event, container);
			tooltip = { visible: true, x: mx + 12, y: my - 10, html: tipHtml(d) };
		};
		const hideTip = () => (tooltip = { ...tooltip, visible: false });

		g.selectAll('.wbar')
			.data(data)
			.join('rect')
			.attr('class', 'wbar')
			.attr('x', barX)
			.attr('y', (d) => y(d.new))
			.attr('width', barWidth)
			.attr('height', (d) => h - y(d.new))
			.style('cursor', 'pointer')
			.on('mousemove', showTip)
			.on('mouseleave', hideTip);

		const mostRecent = data[data.length - 1];
		if (mostRecent.new > 0) {
			g.selectAll('.wbar-label')
				.data([mostRecent])
				.join('text')
				.attr('class', 'wbar-label')
				.attr('x', centerX)
				.attr('y', (d) => y(d.new) - 4)
				.attr('text-anchor', 'middle')
				.text((d) => d.new);
		}

		const line = d3
			.line()
			.x(centerX)
			.y((d) => y(d.cumulative))
			.curve(d3.curveMonotoneX);

		g.append('path').datum(data).attr('class', 'wline').attr('d', line);

		g.selectAll('.wdot')
			.data(data)
			.join('circle')
			.attr('class', 'wdot')
			.attr('cx', centerX)
			.attr('cy', (d) => y(d.cumulative))
			.attr('r', 3);

		g.selectAll('.wdot-hit')
			.data(data)
			.join('circle')
			.attr('cx', centerX)
			.attr('cy', (d) => y(d.cumulative))
			.attr('r', 8)
			.attr('fill', 'transparent')
			.style('cursor', 'pointer')
			.on('mousemove', showTip)
			.on('mouseleave', hideTip);
	}

	$effect(() => {
		data;
		unitLabel;
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

	:global(.wbar) {
		fill: #a93226;
		opacity: 0.75;
	}

	:global(.wbar-label) {
		font-family: 'Roboto', Arial, sans-serif;
		font-size: 12px;
		font-weight: 700;
		fill: #a93226;
	}

	:global(.wline) {
		fill: none;
		stroke: #1a1a1a;
		stroke-width: 2;
	}

	:global(.wdot) {
		fill: #1a1a1a;
	}

	:global(.axis-text) {
		font-family: 'Roboto', Arial, sans-serif;
		font-size: 12px;
		fill: #888;
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
