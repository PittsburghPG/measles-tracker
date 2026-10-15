<script>
	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<link rel="preconnect" href="https://fonts.googleapis.com" />
	<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
	<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;700&display=swap" rel="stylesheet" />
</svelte:head>

<div class="page">
	{@render children()}
</div>

<style>
	:global(*) {
		box-sizing: border-box;
	}

	:global(body) {
		margin: 0;
		background: #fff;
		color: #1a1a1a;
		font-family: 'Roboto', Arial, sans-serif;
	}

	:global(a) {
		color: inherit;
	}

	.page {
		max-width: 900px;
		margin: 0 auto;
		padding: 24px 16px 48px;
	}
</style>
