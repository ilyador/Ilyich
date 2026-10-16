import { mkdtemp, rm, utimes } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { SearchVerifier } from 'src/utils/search-verifier.js';

const answer = (match: boolean) => Response.json({ message: { content: JSON.stringify({ match }) } });

describe(SearchVerifier.name, () => {
  let directory: string;
  let image: string;
  const options = { url: 'http://ollama:11434', model: 'qwen3-vl:4b' };
  const fetchMock = vi.fn();
  const detectFacesMock = vi.fn();

  beforeAll(async () => {
    directory = await mkdtemp(join(tmpdir(), 'immich-search-verifier-'));
    image = join(directory, 'preview.jpg');
    await sharp({ create: { width: 8, height: 8, channels: 3, background: 'red' } })
      .jpeg()
      .toFile(image);
  });
  afterAll(() => rm(directory, { recursive: true, force: true }));
  beforeEach(() => {
    fetchMock.mockReset();
    detectFacesMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
  });
  afterEach(() => vi.unstubAllGlobals());

  it('caches a rejection and invalidates it when the preview changes', async () => {
    const verifier = new SearchVerifier(detectFacesMock);
    fetchMock.mockImplementation(() => answer(false));
    expect(await verifier.verify(image, 'a dog running', options)).toBe(false);
    expect(await verifier.verify(image, 'a dog running', options)).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const future = new Date(Date.now() + 10_000);
    await utimes(image, future, future);
    expect(await verifier.verify(image, 'a dog running', options)).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
  it('keeps query and model decisions separate and sends only the preview', async () => {
    const verifier = new SearchVerifier(detectFacesMock);
    fetchMock.mockImplementation(() => answer(true));
    await verifier.verify(image, 'a dog running', options);
    await verifier.verify(image, 'a dog sitting', options);
    await verifier.verify(image, 'a dog running', { ...options, model: 'another-model' });
    expect(fetchMock).toHaveBeenCalledTimes(3);
    const [url, request] = fetchMock.mock.calls[0];
    expect(url.href).toBe('http://ollama:11434/api/chat');
    const body = JSON.parse(request.body);
    expect(body.think).toBe(false);
    expect(body.keep_alive).toBe('2m');
    expect(body.messages[0].content).toContain('OR needs one complete alternative');
    expect(body.messages[1].content).toContain('a dog running');
    expect(body.messages[1].images).toHaveLength(1);
    const prepared = await sharp(Buffer.from(body.messages[1].images[0], 'base64')).metadata();
    expect([prepared.width, prepared.height]).toEqual([768, 768]);
    expect(request.signal).toBeInstanceOf(AbortSignal);
  });
  it('accepts complete JSON when the Ollama renderer labels it as thinking', async () => {
    fetchMock.mockResolvedValue(Response.json({ message: { content: '', thinking: '{"match":true}' } }));
    expect(await new SearchVerifier(detectFacesMock).verify(image, 'a dog', options)).toBe(true);
  });
  it.each(['{"match":"true"}', 'Some reasoning: {"match":true}', '{"match":true,"extra":"ignored"}'])(
    'rejects malformed or ambiguous model output: %s',
    async (content) => {
      fetchMock.mockResolvedValue(Response.json({ message: { content } }));
      await expect(new SearchVerifier(detectFacesMock).verify(image, 'a dog', options)).rejects.toThrow();
    },
  );
  it('does not cache a failed inference as a rejection', async () => {
    const verifier = new SearchVerifier(detectFacesMock);
    fetchMock.mockResolvedValueOnce(new Response('', { status: 503 })).mockImplementation(() => answer(true));
    await expect(verifier.verify(image, 'a dog', options)).rejects.toThrow('HTTP 503');
    expect(await verifier.verify(image, 'a dog', options)).toBe(true);
  });
  it('does not start inference for a cancelled search', async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(
      new SearchVerifier(detectFacesMock).verify(image, 'a dog', { ...options, signal: controller.signal }),
    ).rejects.toThrow();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  const references = [
    { personGroupId: 'me', embedding: '[1,0]' },
    { personGroupId: 'maya', embedding: '[0,1]' },
  ];
  const boundOptions = (personGroupId: string) => ({
    ...options,
    subjects: {
      people: [{ personGroupId, marker: 1 }],
      references,
      groups: [[1]],
      recognition: { modelName: 'buffalo_l', minScore: 0.7, maxDistance: 0.5 },
    },
  });
  const detection = {
    imageWidth: 8,
    imageHeight: 8,
    faces: [
      { score: 1, embedding: '[1,0]', boundingBox: { x1: 0, y1: 2, x2: 2, y2: 4 } },
      { score: 1, embedding: '[0,1]', boundingBox: { x1: 5, y1: 2, x2: 7, y2: 4 } },
    ],
  };

  it('sends different face markers and keeps decisions separate for different actors in the same photo', async () => {
    const verifier = new SearchVerifier(detectFacesMock);
    detectFacesMock.mockResolvedValue(detection);
    fetchMock.mockResolvedValueOnce(answer(false)).mockResolvedValueOnce(answer(true));
    expect(await verifier.verify(image, 'Person 1 holding a phone', boundOptions('me'))).toBe(false);
    expect(await verifier.verify(image, 'Person 1 holding a phone', boundOptions('maya'))).toBe(true);
    expect(await verifier.verify(image, 'Person 1 holding a phone', boundOptions('me'))).toBe(false);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(detectFacesMock).toHaveBeenCalledTimes(2);
    const [owner, companion] = fetchMock.mock.calls.map(([, request]) => JSON.parse(request.body));
    expect(owner.messages[1].content).toBe(companion.messages[1].content);
    expect(owner.messages[1].images[0]).not.toBe(companion.messages[1].images[0]);
    expect(Object.keys(owner.format.properties)).toEqual(['match']);
    expect(owner.format.required).toEqual(['match']);
    expect(owner.messages[0].content).toContain('Never substitute another visible person');
    expect(owner.messages[0].content).not.toMatch(/maya|personGroupId/iu);
    // Markers are rendered into the image, not merely mentioned in a prompt.
    const pixels = await sharp(Buffer.from(owner.messages[1].images[0], 'base64')).raw().toBuffer();
    const yellow = (x: number, y: number) => {
      const i = (y * 768 + x) * 3;
      return pixels[i] > 150 && pixels[i + 1] > 150 && pixels[i + 2] < 100;
    };
    expect(yellow(0, 240)).toBe(true);
    expect(yellow(480, 240)).toBe(false);
  });
  it('invalidates a subject decision after a face reassignment or recognition configuration change', async () => {
    const verifier = new SearchVerifier(detectFacesMock);
    detectFacesMock.mockResolvedValue(detection);
    fetchMock.mockImplementation(() => answer(true));
    await verifier.verify(image, 'Person 1 holding a phone', boundOptions('me'));
    await verifier.verify(image, 'Person 1 holding a phone', {
      ...boundOptions('me'),
      subjects: {
        ...boundOptions('me').subjects,
        references: references.toReversed().map((ref) => ({
          ...ref,
          personGroupId: ref.personGroupId === 'me' ? 'maya' : 'me',
        })),
      },
    });
    await verifier.verify(image, 'Person 1 holding a phone', {
      ...boundOptions('me'),
      subjects: {
        ...boundOptions('me').subjects,
        recognition: {
          ...boundOptions('me').subjects.recognition,
          modelName: 'another-face-model',
        },
      },
    });
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
  it('rejects a cropped-out or ambiguous actor without treating a companion as the actor', async () => {
    detectFacesMock.mockResolvedValue({ ...detection, faces: [detection.faces[1]] });
    expect(
      await new SearchVerifier(detectFacesMock).verify(image, 'Person 1 holding a phone', boundOptions('me')),
    ).toBe(false);
    detectFacesMock.mockResolvedValue({ ...detection, faces: [{ ...detection.faces[0], embedding: '[1,1]' }] });
    expect(
      await new SearchVerifier(detectFacesMock).verify(image, 'Person 1 holding a phone', boundOptions('me')),
    ).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it('identifies missing alternatives explicitly for OR queries', async () => {
    detectFacesMock.mockResolvedValue({ ...detection, faces: [detection.faces[1]] });
    fetchMock.mockImplementation(() => answer(true));
    await new SearchVerifier(detectFacesMock).verify(image, 'Person 1 or Person 2 holding a phone', {
      ...boundOptions('me'),
      subjects: {
        ...boundOptions('me').subjects,
        groups: [[1], [2]],
        people: [
          { personGroupId: 'me', marker: 1 },
          { personGroupId: 'maya', marker: 2 },
        ],
      },
    });
    const request = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(request.messages[0].content).toContain('Person 1: NOT LOCATED.');
    expect(request.messages[0].content).toContain('Person 2: marked.');
  });
  it('rejects a missing required actor even if the model would accept the located companion', async () => {
    detectFacesMock.mockResolvedValue({ ...detection, faces: [detection.faces[1]] });
    fetchMock.mockImplementation(() => answer(true));
    expect(
      await new SearchVerifier(detectFacesMock).verify(image, 'Person 1 holding a phone with Person 2', {
        ...boundOptions('me'),
        subjects: {
          ...boundOptions('me').subjects,
          groups: [[1, 2]],
          people: [
            { personGroupId: 'me', marker: 1 },
            { personGroupId: 'maya', marker: 2 },
          ],
        },
      }),
    ).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  const bothSubjects = () => ({
    ...boundOptions('me'),
    subjects: {
      ...boundOptions('me').subjects,
      groups: [[1, 2]],
      people: [
        { personGroupId: 'me', marker: 1 },
        { personGroupId: 'maya', marker: 2 },
      ],
    },
  });
  it.each([
    [{ scene: 'yes', person1: 'yes', person2: 'yes' }, true],
    [{ scene: 'no', person1: 'yes', person2: 'yes' }, false],
    [{ scene: 'yes', person1: 'no', person2: 'yes' }, false],
    [{ scene: 'yes', person1: 'yes', person2: 'no' }, false],
    [{ scene: 'unknown', person1: 'yes', person2: 'yes' }, false],
    [{ scene: 'yes', person1: 'unknown', person2: 'yes' }, false],
    [{ scene: 'yes', person1: 'yes', person2: 'unknown' }, false],
  ])('requires all scene and actor checks: %j', async (checks, expected) => {
    detectFacesMock.mockResolvedValue(detection);
    fetchMock.mockResolvedValue(Response.json({ message: { content: JSON.stringify(checks) } }));
    expect(
      await new SearchVerifier(detectFacesMock).verify(
        image,
        'Person 1 wearing a hat with Person 2 holding a phone outdoors',
        bothSubjects(),
      ),
    ).toBe(expected);
    const payload = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(payload.format.required).toEqual(['scene', 'person1', 'person2']);
    expect(payload.format.additionalProperties).toBe(false);
    expect(payload.messages[0].content).toContain('ALL remaining requirements');
    expect(payload.keep_alive).toBe('2m');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
  it.each([
    { scene: 'yes', person1: 'yes' },
    { scene: 'yes', person1: 'yes', person2: 'yes', match: true },
    { scene: 'yes', person1: 'yes', person2: true },
  ])('rejects incomplete or malformed actor checks: %j', async (checks) => {
    detectFacesMock.mockResolvedValue(detection);
    fetchMock.mockResolvedValue(Response.json({ message: { content: JSON.stringify(checks) } }));
    await expect(
      new SearchVerifier(detectFacesMock).verify(
        image,
        'Person 1 wearing a hat and Person 2 holding a phone',
        bothSubjects(),
      ),
    ).rejects.toThrow();
  });
  it('keeps alternatives intact rather than combining independent actor checks across OR branches', async () => {
    detectFacesMock.mockResolvedValue(detection);
    fetchMock.mockResolvedValue(answer(true));
    await new SearchVerifier(detectFacesMock).verify(
      image,
      'Person 1 and Person 2 holding a phone OR using a laptop',
      bothSubjects(),
    );
    expect(JSON.parse(fetchMock.mock.calls[0][1].body).format.required).toEqual(['match']);
  });
  it.each([
    [[[1, 2], [3]], [2], false],
    [[[1, 2], [3]], [3], true],
    [[[1, 2], [3]], [1, 2], true],
    [[[1, 2], [3]], [1], false],
    [[[1], [2, 3]], [1], true],
    [[[1], [2, 3]], [2], false],
    [[[1], [2, 3]], [2, 3], true],
    [[[1], [2, 3]], [], false],
  ] as const)('enforces subject groups %j with located markers %j', async (groups, located, expected) => {
    const faces = [...detection.faces, { score: 1, embedding: '[-1,0]', boundingBox: { x1: 2, y1: 4, x2: 4, y2: 6 } }];
    detectFacesMock.mockResolvedValue({
      ...detection,
      faces: faces.filter((_, index) => (located as readonly number[]).includes(index + 1)),
    });
    fetchMock.mockImplementation(() => answer(true));
    const result = await new SearchVerifier(detectFacesMock).verify(image, 'a relationship among marked people', {
      ...boundOptions('me'),
      subjects: {
        ...boundOptions('me').subjects,
        people: [
          ...boundOptions('me').subjects.people,
          { personGroupId: 'maya', marker: 2 },
          { personGroupId: 'third', marker: 3 },
        ],
        references: [...references, { personGroupId: 'third', embedding: '[-1,0]' }],
        groups: groups.map((group) => [...group]),
      },
    });
    expect(result).toBe(expected);
    expect(fetchMock).toHaveBeenCalledTimes(expected ? 1 : 0);
  });
  it('recognizes the exact upright pixels before marking an EXIF-rotated preview', async () => {
    const portrait = join(directory, 'rotated.jpg');
    await sharp({ create: { width: 80, height: 160, channels: 3, background: 'blue' } })
      .withMetadata({ orientation: 6 })
      .jpeg()
      .toFile(portrait);
    detectFacesMock.mockImplementation(async (data) => {
      const metadata = await sharp(data).metadata();
      expect([metadata.width, metadata.height, metadata.orientation]).toEqual([160, 80, undefined]);
      return {
        imageWidth: 160,
        imageHeight: 80,
        faces: [{ score: 1, embedding: '[1,0]', boundingBox: { x1: 20, y1: 10, x2: 40, y2: 30 } }],
      };
    });
    fetchMock.mockImplementation(() => answer(true));
    await new SearchVerifier(detectFacesMock).verify(portrait, 'Person 1 wearing a hat', boundOptions('me'));
    const data = Buffer.from(JSON.parse(fetchMock.mock.calls[0][1].body).messages[1].images[0], 'base64');
    const { info, data: pixels } = await sharp(data).raw().toBuffer({ resolveWithObject: true });
    expect([info.width, info.height]).toEqual([768, 768]);
    // The 160x80 upright image has 192 pixels of vertical letterboxing.
    const i = ((192 + 70) * 768 + 96) * 3;
    expect(pixels[i]).toBeGreaterThan(150);
    expect(pixels[i + 1]).toBeGreaterThan(150);
    expect(pixels[i + 2]).toBeLessThan(100);
  });
  it('does not verify markers from a face response with incompatible image dimensions', async () => {
    detectFacesMock.mockResolvedValue({ ...detection, imageWidth: 800 });
    await expect(
      new SearchVerifier(detectFacesMock).verify(image, 'Person 1 holding a phone', boundOptions('me')),
    ).rejects.toThrow('dimensions');
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
