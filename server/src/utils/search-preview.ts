import sharp from 'sharp';
import type { BoundSearchSubject } from 'src/utils/search-subjects.js';

// One canvas shape keeps the vision model's GPU graph reusable across images.
const canvasSize = 768;
const labelWidth = 24;
const labelHeight = 20;

/** Render annotations using the measured resized dimensions, then encode once. */
export async function renderSearchPreview(
  source: string | Buffer,
  subjects: BoundSearchSubject[] = [],
): Promise<Buffer> {
  const { data, info } = await sharp(source)
    .rotate()
    .resize(canvasSize, canvasSize, { fit: 'inside' })
    .raw()
    .toBuffer({ resolveWithObject: true });
  const left = Math.floor((canvasSize - info.width) / 2);
  const top = Math.floor((canvasSize - info.height) / 2);
  const image = sharp(data, { raw: info }).extend({
    left,
    right: canvasSize - info.width - left,
    top,
    bottom: canvasSize - info.height - top,
    background: '#000000',
  });
  if (subjects.length > 0) {
    const shapes = subjects.flatMap(({ marker, boxes }) => {
      return boxes.map((box) => {
        const x = left + box.x1 * info.width;
        const y = top + box.y1 * info.height;
        const width = (box.x2 - box.x1) * info.width;
        const height = (box.y2 - box.y1) * info.height;
        const labelX = Math.min(canvasSize - labelWidth, x);
        const labelY = Math.max(0, y - labelHeight);
        return `<rect x="${x}" y="${y}" width="${width}" height="${height}" fill="none" stroke="black" stroke-width="4"/>
          <rect x="${x}" y="${y}" width="${width}" height="${height}" fill="none" stroke="#ffff00" stroke-width="2"/>
          <rect x="${labelX}" y="${labelY}" width="${labelWidth}" height="${labelHeight}" fill="black"/>
          <text x="${labelX + 4}" y="${labelY + 15}" fill="#ffff00" font-size="16" font-family="sans-serif">${marker}</text>`;
      });
    });
    image.composite([
      {
        input: Buffer.from(
          `<svg xmlns="http://www.w3.org/2000/svg" width="${canvasSize}" height="${canvasSize}">${shapes.join('')}</svg>`,
        ),
      },
    ]);
  }
  return image.jpeg({ quality: 90, chromaSubsampling: subjects.length > 0 ? '4:4:4' : '4:2:0' }).toBuffer();
}
