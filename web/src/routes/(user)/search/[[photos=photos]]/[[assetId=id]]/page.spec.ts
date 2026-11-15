import { featureFlagsManager } from '#lib/managers/feature-flags-manager.svelte.ts';
import { searchManager } from '#lib/managers/search-manager.svelte.ts';
import { Route } from '#lib/route.ts';
import { factory } from '#test/unit/factories.ts';
import { test } from '#test/unit/fixtures.ts';
import { Status } from '@immich/sdk';
import { expect } from 'vitest';
import { page } from 'vitest/browser';
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

test.for([undefined, false])(
  'preserves verification while refining a query (%s)',
  async (verify, { api, data, router, render, settle }) => {
    data.serverFeatures.searchVerification = true;
    data.userConfig.machineLearning.enabled = true;
    data.userConfig.machineLearning.clip.enabled = true;
    await featureFlagsManager.init();
    expect(api.searchSmart).toHaveBeenCalled();
    api.on({
      searchSmart: () => ({
        json: {
          albums: { items: [], count: 0, total: 0, facets: [] },
          assets: { items: [], count: 0, total: 0, facets: [], nextPage: null, nextCursor: null },
        },
      }),
    });
    await router.goto(Route.search({ query: 'a red hat', ...(verify !== undefined && { verify }) }));
    await render(Page, load);
    await settle();
    await page.getByRole('button', { name: 'search_verify_matches' }).click();
    const selected = verify === false;
    expect(JSON.parse(router.url.searchParams.get('query')!)).toMatchObject({ verify: selected });
    searchManager.filter.query = 'a Binance hat';
    searchManager.filter.location.city = 'Amsterdam';
    await searchManager.submit();
    expect(JSON.parse(router.url.searchParams.get('query')!)).toMatchObject({
      query: 'a Binance hat',
      city: 'Amsterdam',
      verify: selected,
    });
  },
);

test('offers a retry after verification stops with confirmed matches', async ({
  api,
  data,
  router,
  render,
  settle,
}) => {
  data.serverFeatures.searchVerification = true;
  data.userConfig.machineLearning.enabled = true;
  data.userConfig.machineLearning.clip.enabled = true;
  await featureFlagsManager.init();
  expect(api.searchSmart).toHaveBeenCalled();
  api.on({
    searchSmart: () => ({
      json: {
        albums: { items: [], count: 0, total: 0, facets: [] },
        assets: { items: [], count: 0, total: 0, facets: [], nextPage: null, nextCursor: null },
        verification: { status: Status.Partial, checked: 3, rejected: 2 },
      },
    }),
  });
  await router.goto(Route.search({ query: 'a red hat' }));
  await render(Page, load);
  await settle();
  await expect.element(page.getByText('search_verification_partial')).toBeVisible();
  await expect.element(page.getByRole('button', { name: 'retry' })).toBeEnabled();
});

test('keeps the warning after an unverified page followed by a verified page', async ({
  api,
  data,
  router,
  render,
  settle,
}) => {
  data.serverFeatures.searchVerification = true;
  data.userConfig.machineLearning.enabled = true;
  data.userConfig.machineLearning.clip.enabled = true;
  await featureFlagsManager.init();
  expect(api.searchSmart).toHaveBeenCalled();
  let requests = 0;
  api.on({
    searchSmart: () => ({
      json: {
        albums: { items: [], count: 0, total: 0, facets: [] },
        assets: { items: [], count: 0, total: 0, facets: [], nextPage: requests === 0 ? '2' : null, nextCursor: null },
        verification:
          requests++ === 0
            ? { status: Status.Unavailable, checked: 0, rejected: 0 }
            : { status: Status.Complete, checked: 2, rejected: 2 },
      },
    }),
  });
  await router.goto(Route.search({ query: 'a red hat' }));
  await render(Page, load);
  await settle();
  await expect.element(page.getByText('search_verification_unavailable')).toBeVisible();
  await page.getByRole('button', { name: 'search_verify_more' }).click();
  await settle();
  expect(requests).toBe(2);
  expect(api.searchSmart).toHaveBeenCalled();
  await expect.element(page.getByText('search_verification_unavailable')).toBeVisible();
  await expect.element(page.getByText('search_verification_complete')).not.toBeInTheDocument();
});
