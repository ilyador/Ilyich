import { searchSmart } from '@immich/sdk';
import { render, screen, waitFor } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import { goto } from '$app/navigation';
import { page } from '$app/state';
import TestWrapper from '#lib/components/TestWrapper.svelte';
import { searchManager } from '#lib/managers/search-manager.svelte.ts';
import SearchPage from './+page.svelte';

vi.mock('$app/navigation', () => ({ goto: vi.fn().mockResolvedValue(undefined), afterNavigate: vi.fn() }));
vi.mock('$app/state', () => ({
  page: { url: new URL('http://localhost/search'), route: { id: '/(user)/search/[[photos=photos]]/[[assetId=id]]' } },
}));
vi.mock('#lib/managers/feature-flags-manager.svelte.ts', () => ({
  featureFlagsManager: { value: { smartSearch: true, searchVerification: true } },
}));
vi.mock('#lib/components/OnEvents.svelte', () => ({ default: () => {} }));
vi.mock('#lib/components/shared-components/ControlAppBar.svelte', () => ({ default: () => {} }));
vi.mock('@immich/sdk', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@immich/sdk')>()),
  searchSmart: vi.fn(),
}));

describe('search verification control', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    searchManager.reset();
    vi.mocked(searchSmart).mockResolvedValue({
      albums: { items: [], count: 0, total: 0, facets: [] },
      assets: { items: [], count: 0, total: 0, facets: [], nextPage: null, nextCursor: null },
    });
  });

  it.each([undefined, false])(
    'preserves the selected verification setting when refining a query (initial=%s)',
    async (verify) => {
      const user = userEvent.setup();
      const query = { query: 'a red hat', ...(verify !== undefined && { verify }) };
      // The page stays mounted when its query parameters change.
      Object.assign(page, {
        url: new URL(`http://localhost/search?query=${encodeURIComponent(JSON.stringify(query))}`),
      });
      render(TestWrapper, { component: SearchPage, componentProps: {} });

      const toggle = await screen.findByRole('button', { name: 'search_verify_matches' });
      await waitFor(() => expect(toggle).toBeEnabled());
      await user.click(toggle);
      const selected = verify === false;
      expect(vi.mocked(goto).mock.lastCall?.[0]).toContain(encodeURIComponent(`"verify":${selected}`));

      searchManager.filter.query = 'a Binance hat';
      searchManager.filter.location.city = 'Amsterdam';
      await searchManager.submit();

      const destination = new URL(String(vi.mocked(goto).mock.lastCall?.[0]), 'http://localhost');
      expect(JSON.parse(destination.searchParams.get('query')!)).toMatchObject({
        query: 'a Binance hat',
        city: 'Amsterdam',
        verify: selected,
      });
    },
  );
});
