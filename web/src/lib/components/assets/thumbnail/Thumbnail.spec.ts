import Thumbnail from '#lib/components/assets/thumbnail/Thumbnail.svelte';
import { factory } from '#test/unit/factories.ts';
import { render } from 'vitest-browser-svelte';

describe('Thumbnail media revisions', () => {
  it('loads a new cache URL when the published media revision changes', async () => {
    const asset = factory.timelineAsset({ mediaRevision: 'first-render', thumbhash: null });
    const { container, rerender } = render(Thumbnail, { asset });
    const original = container.querySelector('img')!;
    original.dispatchEvent(new Event('load'));
    await rerender({ asset: { ...asset, mediaRevision: 'second-render' } });
    const image = container.querySelector('img')!;
    expect(image).not.toBe(original);
    expect(image.getAttribute('src')).toContain('c=second-render');
  });

  it('retries a failed image when the published media revision changes', async () => {
    const asset = factory.timelineAsset({ mediaRevision: 'first-render', thumbhash: null });
    const { container, rerender } = render(Thumbnail, { asset });
    container.querySelector('img')!.dispatchEvent(new Event('error'));
    await rerender({ asset: { ...asset, mediaRevision: 'second-render' } });
    expect(container.querySelector('img')?.getAttribute('src')).toContain('c=second-render');
  });
});
