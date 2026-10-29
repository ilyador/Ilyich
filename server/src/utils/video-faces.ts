import type { Face } from 'src/repositories/machine-learning.repository.js';

/** Aim to look at a frame this often, in milliseconds... */
export const VIDEO_FACE_FRAME_INTERVAL = 2000;
/** ...but spread out at most this many frames over a long video. */
export const VIDEO_FACE_MAX_FRAMES = 100;
/** A face nobody is known by is only kept when it was seen in at least this many frames. */
export const VIDEO_FACE_MIN_SIGHTINGS = 2;
/** Side of the greyscale square frames are compared at. */
export const VIDEO_FRAME_FINGERPRINT_SIZE = 32;
/** A frame within this much of the last one analysed, everywhere in the picture, cannot show a new face. */
const NEAR_DUPLICATE_TOLERANCE = 8;

export interface VideoFace extends Face {
  /** Milliseconds into the video */
  timestamp: number;
  imageWidth: number;
  imageHeight: number;
  /** The embedding scaled to unit length */
  vector: number[];
}

export interface VideoFaceCluster {
  /** The largest and clearest sighting, which stands for the person in this video */
  face: VideoFace;
  sightings: number;
}

/**
When to take the frames to analyse, in milliseconds. Each one sits in the middle of an equal slice of the video,
which keeps them away from the very first frames, where the preview comes from, and from the last one.
*/
export const getVideoFaceTimestamps = (duration: number): number[] => {
  if (!Number.isFinite(duration) || duration <= 0) {
    return [];
  }

  const interval = Math.max(VIDEO_FACE_FRAME_INTERVAL, duration / VIDEO_FACE_MAX_FRAMES);
  const count = Math.max(1, Math.floor(duration / interval));
  const slice = duration / count;
  return Array.from({ length: count }, (_, index) => Math.floor(slice * (index + 0.5)));
};

/** Reads an embedding as the machine learning service and the database write it, e.g. `[0.1,0.2]`. */
export const parseEmbedding = (embedding: string | null | undefined): number[] | undefined => {
  if (!embedding) {
    return;
  }

  try {
    const parsed: unknown = JSON.parse(embedding);
    if (
      Array.isArray(parsed) &&
      parsed.length > 0 &&
      parsed.every((item) => typeof item === 'number' && Number.isFinite(item))
    ) {
      const norm = Math.hypot(...parsed);
      if (norm > 0 && Number.isFinite(norm)) {
        return parsed.map((item: number) => item / norm);
      }
    }
  } catch {
    // an unreadable embedding cannot identify anyone
  }
};

/** Cosine distance between two unit-length embeddings, as the face search index measures it. */
export const getEmbeddingDistance = (a: number[], b: number[]): number =>
  a.length === b.length ? 1 - a.reduce((sum, value, index) => sum + value * b[index], 0) : Infinity;

const getQuality = ({ boundingBox: { x1, y1, x2, y2 }, imageWidth, imageHeight, score }: VideoFace) =>
  (Math.max(0, x2 - x1) * Math.max(0, y2 - y1) * score) / Math.max(1, imageWidth * imageHeight);

/**
Groups the faces seen across a video by person. From the largest and clearest down, each face joins the nearest
group whose best face is within `maxDistance`, the threshold facial recognition matches faces to people with, and
otherwise starts a group of its own. Groups are returned best first.
*/
export const clusterVideoFaces = (faces: VideoFace[], maxDistance: number): VideoFaceCluster[] => {
  const clusters: VideoFaceCluster[] = [];
  for (const face of faces.toSorted((a, b) => getQuality(b) - getQuality(a))) {
    let nearest: VideoFaceCluster | undefined;
    let nearestDistance = Infinity;
    for (const cluster of clusters) {
      const distance = getEmbeddingDistance(face.vector, cluster.face.vector);
      if (distance >= nearestDistance) {
        continue;
      }
      nearest = cluster;
      nearestDistance = distance;
    }

    if (nearest && nearestDistance <= maxDistance) {
      nearest.sightings++;
    } else {
      clusters.push({ face, sightings: 1 });
    }
  }

  return clusters;
};

/** Whether no part of a frame changed noticeably since the previous one, going by their fingerprints. */
export const isNearDuplicateFrame = (previous: Buffer | undefined, current: Buffer): boolean =>
  !!previous &&
  previous.length > 0 &&
  previous.length === current.length &&
  current.every((value, index) => Math.abs(value - previous[index]) <= NEAR_DUPLICATE_TOLERANCE);
