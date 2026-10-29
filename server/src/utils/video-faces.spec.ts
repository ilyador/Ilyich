import {
  VIDEO_FACE_MAX_FRAMES,
  VideoFace,
  clusterVideoFaces,
  getEmbeddingDistance,
  getVideoFaceTimestamps,
  isNearDuplicateFrame,
  parseEmbedding,
} from 'src/utils/video-faces.js';

const face = (
  vector: number[],
  { timestamp = 0, size = 100, score = 0.9 }: { timestamp?: number; size?: number; score?: number } = {},
): VideoFace => ({
  boundingBox: { x1: 0, y1: 0, x2: size, y2: size },
  embedding: JSON.stringify(vector),
  score,
  timestamp,
  imageWidth: 1920,
  imageHeight: 1080,
  vector: parseEmbedding(JSON.stringify(vector))!,
});

describe('getVideoFaceTimestamps', () => {
  it('should take a frame from the middle of a short video', () => {
    expect(getVideoFaceTimestamps(1500)).toEqual([750]);
  });

  it('should take a frame every two seconds, each in the middle of its slice', () => {
    expect(getVideoFaceTimestamps(10_000)).toEqual([1000, 3000, 5000, 7000, 9000]);
  });

  it('should spread the frames of a long video out instead of taking more of them', () => {
    const timestamps = getVideoFaceTimestamps(600_000);

    expect(timestamps).toHaveLength(VIDEO_FACE_MAX_FRAMES);
    expect(timestamps[0]).toBe(3000);
    expect(timestamps[1] - timestamps[0]).toBe(6000);
    expect(timestamps.at(-1)).toBe(597_000);
  });

  it('should keep every frame inside the video', () => {
    for (const duration of [1, 2001, 59_999, 3_600_000]) {
      const timestamps = getVideoFaceTimestamps(duration);
      expect(timestamps.length).toBeGreaterThan(0);
      expect(Math.min(...timestamps)).toBeGreaterThanOrEqual(0);
      expect(Math.max(...timestamps)).toBeLessThan(duration);
    }
  });

  it.each([0, -1, NaN])('should not take a frame from a video %s ms long', (duration) => {
    expect(getVideoFaceTimestamps(duration)).toEqual([]);
  });
});

describe('parseEmbedding', () => {
  it('should scale the embedding to unit length', () => {
    expect(parseEmbedding('[3, 4]')).toEqual([0.6, 0.8]);
  });

  it.each([null, undefined, '', '[]', '[0, 0]', 'not json', '["a"]', '{"a": 1}'])(
    'should not read %s as an embedding',
    (embedding) => {
      expect(parseEmbedding(embedding)).toBeUndefined();
    },
  );
});

describe('getEmbeddingDistance', () => {
  it('should measure the cosine distance', () => {
    expect(getEmbeddingDistance([1, 0], [1, 0])).toBe(0);
    expect(getEmbeddingDistance([1, 0], [0, 1])).toBe(1);
    expect(getEmbeddingDistance([1, 0], [-1, 0])).toBe(2);
  });

  it('should not match embeddings of different sizes', () => {
    expect(getEmbeddingDistance([1, 0], [1, 0, 0])).toBe(Infinity);
  });
});

describe('clusterVideoFaces', () => {
  it('should group the sightings of each person and keep the largest one', () => {
    const alice = [
      face([1, 0, 0], { timestamp: 1000, size: 100 }),
      face([0.95, 0.05, 0], { timestamp: 3000, size: 300 }),
    ];
    const bob = [face([0, 1, 0], { timestamp: 5000, size: 200 })];

    const clusters = clusterVideoFaces([alice[0], bob[0], alice[1]], 0.5);

    expect(clusters).toEqual([
      { face: alice[1], sightings: 2 },
      { face: bob[0], sightings: 1 },
    ]);
  });

  it('should prefer the clearer of two faces of the same size', () => {
    const blurry = face([1, 0], { score: 0.71 });
    const clear = face([0.99, 0.01], { score: 0.95 });

    expect(clusterVideoFaces([blurry, clear], 0.5)).toEqual([{ face: clear, sightings: 2 }]);
  });

  it('should keep faces further apart than the distance facial recognition matches at apart', () => {
    const first = face([1, 0], { size: 200 });
    const second = face([0.4, 0.6]);

    expect(getEmbeddingDistance(first.vector, second.vector)).toBeGreaterThan(0.1);
    expect(clusterVideoFaces([first, second], 0.1)).toHaveLength(2);
    expect(clusterVideoFaces([first, second], 0.5)).toHaveLength(1);
  });

  it('should join a face to the nearest group', () => {
    const left = face([1, 0], { size: 300 });
    const right = face([0, 1], { size: 200 });
    const nearRight = face([0.3, 1]);

    expect(clusterVideoFaces([nearRight, left, right], 0.9)).toEqual([
      { face: left, sightings: 1 },
      { face: right, sightings: 2 },
    ]);
  });

  it('should handle a video without faces', () => {
    expect(clusterVideoFaces([], 0.5)).toEqual([]);
  });
});

const frame = (value: number) => Buffer.alloc(1024, value);

describe('isNearDuplicateFrame', () => {
  it('should not compare the first frame with anything', () => {
    expect(isNearDuplicateFrame(undefined, frame(10))).toBe(false);
  });

  it('should find a frame with only slight changes to be a duplicate', () => {
    const next = frame(100);
    next[10] = 108;

    expect(isNearDuplicateFrame(frame(100), next)).toBe(true);
  });

  it('should find a frame changed in one place not to be a duplicate', () => {
    const next = frame(100);
    next[10] = 109;

    expect(isNearDuplicateFrame(frame(100), next)).toBe(false);
  });

  it('should not compare frames of different sizes or without content', () => {
    expect(isNearDuplicateFrame(Buffer.alloc(16), Buffer.alloc(32))).toBe(false);
    expect(isNearDuplicateFrame(Buffer.alloc(0), Buffer.alloc(0))).toBe(false);
  });
});
