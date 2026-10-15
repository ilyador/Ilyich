import { featureFlagsManager } from '#lib/managers/feature-flags-manager.svelte.ts';
import { page } from 'vitest/browser';
import { searchManager } from '#lib/managers/search-manager.svelte.ts';
import { Route } from '#lib/route.ts';
import { factory } from '#test/unit/factories.ts';
import { test } from '#test/unit/fixtures.ts';
import { expect } from 'vitest';
import Page from './+page.svelte';
import { load } from './+page.ts';

const holiday = factory.tag({ name: 'holiday' });
const family = factory.tag({ name: 'family' });

test.beforeEach(({ data }) => {
  data.setPreferences(factory.preferences({ tags: { enabled: true, sidebarWeb: true } })).addTags([holiday, family]);
});

test.afterEach(() => {
  searchManager.reset();
});

test('removing a chip drops the tag and keeps focus in the panel', async ({ router, render, settle, app }) => {
  await router.goto(Route.search({ tagIds: [holiday.id, family.id] }));
  await render(Page, load);
  await settle();
  await app.search.openFilter('tag_plus_more_tags');

  await app.search.tags.chip('holiday').click();

  await expect.element(app.search.tags.chip('holiday')).not.toBeInTheDocument();
  await expect.element(app.search.tags.chip('family')).toBeVisible();
  expect([...(searchManager.filter.tagIds ?? [])]).toEqual([family.id]);
  expect(app.search.tags.section().element().contains(document.activeElement)).toBe(true);
});

test('untagged replaces the tags and toggling it off restores none', async ({ router, render, settle, app }) => {
  await router.goto(Route.search({ tagIds: [holiday.id] }));
  await render(Page, load);
  await settle();
  await app.search.openFilter('holiday');

  await app.search.tags.untaggedButton().click();
  expect(searchManager.filter.tagIds).toBeNull();
  await expect.element(app.search.tags.chip('holiday')).not.toBeInTheDocument();

  await app.search.tags.untaggedButton().click();
  expect([...(searchManager.filter.tagIds ?? [])]).toEqual([]);
});


test.for([undefined, false])('preserves verification while refining a query (%s)', async (verify, { data, router, render, settle }) => {
  data.serverFeatures.searchVerification = true;
  data.userConfig.machineLearning.clip.enabled = true;
  await featureFlagsManager.init();
  await router.goto(Route.search({ query: 'a red hat', ...(verify !== undefined && { verify }) }));
  await render(Page, load);
  await settle();
  await page.getByRole('button', { name: 'search_verify_matches' }).click();
  const selected = verify === false;
  expect(JSON.parse(router.url.searchParams.get('query')!)).toMatchObject({ verify: selected });
  searchManager.filter.query = 'a Binance hat';
  searchManager.filter.location.city = 'Amsterdam';
  await searchManager.submit();
  expect(JSON.parse(router.url.searchParams.get('query')!)).toMatchObject({ query: 'a Binance hat', city: 'Amsterdam', verify: selected });
});
