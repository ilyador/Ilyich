import type { BoundingBox, Face } from 'src/repositories/machine-learning.repository.js';

export interface SearchSubject {
  personGroupId: string;
  marker: number;
}

export interface SearchFaceReference {
  personGroupId: string | null;
  embedding: string;
}

export interface BoundSearchSubject {
  marker: number;
  // Coordinates are relative to the upright image sent to face detection.
  boxes: BoundingBox[];
}

export interface SearchFaceDetection {
  imageWidth: number;
  imageHeight: number;
  faces: Face[];
}

export function searchSubjectLabel(marker: number): string {
  if (!Number.isSafeInteger(marker) || marker < 1) throw new Error('Invalid search subject marker');
  return `Person ${marker}`;
}

const vector = (value: string): number[] | undefined => {
  try {
    const parsed: unknown = JSON.parse(value);
    if (
      Array.isArray(parsed) &&
      parsed.length > 0 &&
      parsed.every((item) => typeof item === 'number' && Number.isFinite(item))
    ) {
      const norm = Math.hypot(...parsed);
      if (norm > 0 && Number.isFinite(norm)) return parsed.map((item: number) => item / norm);
    }
  } catch {
    // Missing or invalid embeddings cannot establish an identity.
  }
};

/** Match only within the already-authorized asset; never reuse stored geometry. */
export function bindSearchSubjects(
  subjects: SearchSubject[],
  references: SearchFaceReference[],
  detection: SearchFaceDetection,
  maxDistance: number,
): BoundSearchSubject[] {
  const bound = subjects.map(({ marker }) => ({ marker, boxes: [] as BoundingBox[] }));
  const { imageWidth, imageHeight } = detection;
  if (!(imageWidth > 0 && imageHeight > 0 && Number.isFinite(imageWidth) && Number.isFinite(imageHeight))) return bound;
  const known = references.map((reference) => ({ ...reference, vector: vector(reference.embedding) }));
  const current = detection.faces.map((face) => ({ ...face, vector: vector(face.embedding) }));
  const distances = current.map(({ vector: face }) =>
    known.map(({ vector: reference }) =>
      face && reference?.length === face.length
        ? 1 - face.reduce((sum, value, index) => sum + value * reference[index], 0)
        : Infinity,
    ),
  );
  for (const [faceIndex, { boundingBox, vector }] of current.entries()) {
    if (!vector || Object.values(boundingBox).some((value) => !Number.isFinite(value))) continue;
    const matchesForFace = distances[faceIndex];
    const matches = new Set(
      known.filter((_, index) => matchesForFace[index] <= maxDistance).map(({ personGroupId }) => personGroupId),
    );
    // A match to two people (or to an unassigned face as well) is ambiguous.
    if (matches.size !== 1) continue;
    // One stored face cannot identify two different current people. Require a
    // reciprocal best match; exact ties remain unbound rather than guessing.
    const supported = matchesForFace.some(
      (distance, index) =>
        distance <= maxDistance &&
        distances.every((other, otherIndex) => otherIndex === faceIndex || other[index] > distance),
    );
    if (!supported) continue;
    const index = subjects.findIndex(({ personGroupId }) => personGroupId === [...matches][0]);
    if (index === -1) continue;
    const box = {
      x1: Math.max(0, boundingBox.x1 / imageWidth),
      y1: Math.max(0, boundingBox.y1 / imageHeight),
      x2: Math.min(1, boundingBox.x2 / imageWidth),
      y2: Math.min(1, boundingBox.y2 / imageHeight),
    };
    if (box.x2 > box.x1 && box.y2 > box.y1) bound[index].boxes.push(box);
  }
  return bound;
}
