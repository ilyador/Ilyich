import { Face } from 'src/repositories/machine-learning.repository.js';
import { SearchFaceDetection, bindSearchSubjects } from 'src/utils/search-subjects.js';

const people = [
  { personGroupId: 'me', marker: 1 },
  { personGroupId: 'maya', marker: 2 },
];
const references = [
  { personGroupId: 'me', embedding: '[1,0,0]' },
  { personGroupId: 'maya', embedding: '[0,1,0]' },
];
const face = (embedding: string, x1: number): Face => ({
  embedding,
  score: 1,
  boundingBox: { x1, y1: 20, x2: x1 + 20, y2: 60 },
});
const detection: SearchFaceDetection = {
  imageWidth: 200,
  imageHeight: 100,
  // The edited preview has moved Maya to the left and Me to the right.
  faces: [face('[0,2,0]', 20), face('[3,0,0]', 120)],
};

describe(bindSearchSubjects.name, () => {
  it.each(Array.from({ length: 16 }, (_, index) => index + 1))(
    'is independent of identity values, reference order, vector scale and image size (%s)',
    (seed) => {
      const angle = seed * 0.731;
      const a = [Math.cos(angle), Math.sin(angle)];
      const b = [-a[1], a[0]];
      const width = 80 + seed * 97;
      const height = 200 + seed * 43;
      const subjects = [
        { personGroupId: `identity-${seed}-a`, marker: 7 },
        { personGroupId: `identity-${seed}-b`, marker: 13 },
      ];
      const refs = [
        { personGroupId: subjects[1].personGroupId, embedding: JSON.stringify(b) },
        { personGroupId: subjects[0].personGroupId, embedding: JSON.stringify(a) },
      ];
      const result = bindSearchSubjects(
        subjects,
        refs,
        {
          imageWidth: width,
          imageHeight: height,
          faces: [
            {
              score: 1,
              embedding: JSON.stringify(b.map((value) => value * (seed + 2))),
              boundingBox: { x1: width * 0.6, y1: height * 0.2, x2: width * 0.8, y2: height * 0.4 },
            },
            {
              score: 1,
              embedding: JSON.stringify(a.map((value) => value * (seed + 4))),
              boundingBox: { x1: width * 0.1, y1: height * 0.3, x2: width * 0.2, y2: height * 0.5 },
            },
          ],
        },
        0.5,
      );
      expect(result.map(({ marker }) => marker)).toEqual([7, 13]);
      expect(result[0].boxes[0].x1).toBeCloseTo(0.1);
      expect(result[1].boxes[0].x1).toBeCloseTo(0.6);
      expect(result.every(({ boxes }) => boxes.length === 1)).toBe(true);
    },
  );
  it('binds identities by current pixels rather than stored face order or coordinates', () => {
    expect(bindSearchSubjects(people, references, detection, 0.5)).toEqual([
      { marker: 1, boxes: [{ x1: 0.6, y1: 0.2, x2: 0.7, y2: 0.6 }] },
      { marker: 2, boxes: [{ x1: 0.1, y1: 0.2, x2: 0.2, y2: 0.6 }] },
    ]);
  });
  it('does not substitute the companion when a crop removes the requested person', () => {
    expect(bindSearchSubjects([people[0]], references, { ...detection, faces: [detection.faces[0]] }, 0.5)).toEqual([
      { marker: 1, boxes: [] },
    ]);
  });
  it('refuses ambiguous identities even when only one of them was requested', () => {
    const ambiguous = { ...detection, faces: [face('[1,1,0]', 20)] };
    expect(bindSearchSubjects([people[0]], references, ambiguous, 0.5)[0].boxes).toEqual([]);
    expect(
      bindSearchSubjects([people[0]], [{ ...references[0], personGroupId: null }, references[1]], ambiguous, 0.5)[0]
        .boxes,
    ).toEqual([]);
  });
  it('does not bind one stored face to two current people when a companion lacks a reference', () => {
    const similarCompanion = { ...detection, faces: [face('[1,0,0]', 20), face('[1,0.5,0]', 120)] };
    expect(bindSearchSubjects([people[0]], [references[0]], similarCompanion, 0.5)).toEqual([
      { marker: 1, boxes: [{ x1: 0.1, y1: 0.2, x2: 0.2, y2: 0.6 }] },
    ]);
    expect(
      bindSearchSubjects(
        [people[0]],
        [references[0]],
        {
          ...similarCompanion,
          faces: [face('[1,0,0]', 20), face('[1,0,0]', 120)],
        },
        0.5,
      )[0].boxes,
    ).toEqual([]);
  });
  it('allows an alternative person to remain marked when the other is absent', () => {
    expect(bindSearchSubjects(people, references, { ...detection, faces: [detection.faces[0]] }, 0.5)).toEqual([
      { marker: 1, boxes: [] },
      {
        marker: 2,
        boxes: [{ x1: 0.1, y1: 0.2, x2: 0.2, y2: 0.6 }],
      },
    ]);
  });
  it.each(['[]', '[0,0,0]', '[1,0]', '["1",0,0]', 'invalid', '[1e400,0,0]'])(
    'does not bind an invalid or incompatible embedding: %s',
    (embedding) => {
      expect(bindSearchSubjects([people[0]], [{ personGroupId: 'me', embedding }], detection, 0.5)[0].boxes).toEqual(
        [],
      );
    },
  );
  it('rejects invalid dimensions and bounding boxes', () => {
    expect(
      bindSearchSubjects(people, references, { ...detection, imageWidth: 0 }, 0.5).every(
        ({ boxes }) => boxes.length === 0,
      ),
    ).toBe(true);
    expect(
      bindSearchSubjects(
        people,
        references,
        { ...detection, faces: [{ ...detection.faces[0], boundingBox: { x1: 50, x2: 10, y1: 0, y2: 20 } }] },
        0.5,
      ).every(({ boxes }) => boxes.length === 0),
    ).toBe(true);
  });
});
