import { transformManager } from '#lib/managers/edit/transform-manager.svelte.ts';
import { factory } from '#test/unit/factories.ts';
import { afterEach, describe, expect, it } from 'vitest';

describe('published editor base', () => {
  afterEach(() => transformManager.onDeactivate());

  it('uses the developed base coordinates and revision when preloading the editable image', async () => {
    const asset = factory.asset({
      mediaRevision: 'current-render',
      thumbhash: 'unchanged-hash',
      exifInfo: { exifImageWidth: 6000, exifImageHeight: 4000, orientation: '6' },
    });

    await transformManager.onActivate(asset, [], { width: 3000, height: 2000 });

    expect(transformManager.originalImageSize).toEqual({ width: 3000, height: 2000 });
    expect(transformManager.imgElement?.src).toContain('c=current-render');
    expect(transformManager.imgElement?.src).toContain('edited=false');
  });

  it('retains the oriented EXIF dimensions and legacy cache key without published state', async () => {
    const asset = factory.asset({
      thumbhash: 'legacy-hash',
      exifInfo: { exifImageWidth: 6000, exifImageHeight: 4000, orientation: '6' },
    });

    await transformManager.onActivate(asset, []);

    expect(transformManager.originalImageSize).toEqual({ width: 4000, height: 6000 });
    expect(transformManager.imgElement?.src).toContain('c=legacy-hash');
  });
});
