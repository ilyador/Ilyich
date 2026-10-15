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
    vi.stubGlobal('fetch', fetchMock);
  });
  afterEach(() => vi.unstubAllGlobals());

  it('caches a rejection and invalidates it when the preview changes', async () => {
    const verifier = new SearchVerifier();
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
    const verifier = new SearchVerifier();
    fetchMock.mockImplementation(() => answer(true));
    await verifier.verify(image, 'a dog running', options);
    await verifier.verify(image, 'a dog sitting', options);
    await verifier.verify(image, 'a dog running', { ...options, model: 'another-model' });
    expect(fetchMock).toHaveBeenCalledTimes(3);
    const [url, request] = fetchMock.mock.calls[0];
    expect(url.href).toBe('http://ollama:11434/api/chat');
    const body = JSON.parse(request.body);
    expect(body.think).toBe(false);
    expect(body.messages[1].content).toContain('a dog running');
    expect(body.messages[1].images).toHaveLength(1);
    expect(request.signal).toBeInstanceOf(AbortSignal);
  });
  it('accepts complete JSON when the Ollama renderer labels it as thinking', async () => {
    fetchMock.mockResolvedValue(Response.json({ message: { content: '', thinking: '{"match":true}' } }));
    expect(await new SearchVerifier().verify(image, 'a dog', options)).toBe(true);
  });
  it.each(['{"match":"true"}', 'Some reasoning: {"match":true}', '{"match":true,"extra":"ignored"}'])(
    'rejects malformed or ambiguous model output: %s',
    async (content) => {
      fetchMock.mockResolvedValue(Response.json({ message: { content } }));
      await expect(new SearchVerifier().verify(image, 'a dog', options)).rejects.toThrow();
    },
  );
  it('does not cache a failed inference as a rejection', async () => {
    const verifier = new SearchVerifier();
    fetchMock.mockResolvedValueOnce(new Response('', { status: 503 })).mockImplementation(() => answer(true));
    await expect(verifier.verify(image, 'a dog', options)).rejects.toThrow('HTTP 503');
    expect(await verifier.verify(image, 'a dog', options)).toBe(true);
  });
  it('does not start inference for a cancelled search', async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(
      new SearchVerifier().verify(image, 'a dog', { ...options, signal: controller.signal }),
    ).rejects.toThrow();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
