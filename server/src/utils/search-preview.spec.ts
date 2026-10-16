import sharp from 'sharp';
import { renderSearchPreview } from 'src/utils/search-preview.js';

describe(renderSearchPreview.name, () => {
  it.each([
    [53, 137],
    [137, 53],
    [769, 1023],
    [1023, 769],
    [41, 41],
  ])('keeps face markers aligned with actual image pixels at %sx%s', async (width, height) => {
    const source = await sharp({ create: { width, height, channels: 3, background: 'blue' } })
      .png()
      .toBuffer();
    const unmarked = await sharp(await renderSearchPreview(source))
      .raw()
      .toBuffer({ resolveWithObject: true });
    const { width: size, height: outputHeight, channels } = unmarked.info;
    expect(size).toBe(outputHeight);
    const blue = (x: number, y: number) => unmarked.data[(y * size + x) * channels + 2] > 150;
    const horizontal = Array.from({ length: size }, (_, i) => i).filter((x) => blue(x, Math.floor(size / 2)));
    const vertical = Array.from({ length: size }, (_, i) => i).filter((y) => blue(Math.floor(size / 2), y));
    const left = horizontal[0];
    const top = vertical[0];
    const innerWidth = horizontal.at(-1)! - left + 1;
    const innerHeight = vertical.at(-1)! - top + 1;
    const marked = await sharp(
      await renderSearchPreview(source, [{ marker: 7, boxes: [{ x1: 0.25, y1: 0.25, x2: 0.75, y2: 0.75 }] }]),
    )
      .raw()
      .toBuffer();
    const yellow = (x: number, y: number) => {
      const index = (y * size + x) * channels;
      return marked[index] > 150 && marked[index + 1] > 150 && marked[index + 2] < 100;
    };
    const x = Math.round(left + innerWidth * 0.25);
    const y = Math.round(top + innerHeight * 0.5);
    expect([-2, -1, 0, 1, 2].some((offset) => yellow(x + offset, y))).toBe(true);
    expect(yellow(Math.round(left + innerWidth * 0.1), y)).toBe(false);
  });
});
