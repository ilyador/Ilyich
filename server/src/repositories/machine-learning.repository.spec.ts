import { defaults } from 'src/dtos/config.dto.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { MachineLearningRepository } from 'src/repositories/machine-learning.repository.js';

describe('search subject face recognition transport', () => {
  const fetchMock = vi.fn();
  let repository: MachineLearningRepository;
  beforeEach(() => {
    fetchMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
    repository = new MachineLearningRepository(LoggingRepository.create());
    repository.setup({
      ...defaults.machineLearning,
      urls: ['http://ml'],
      availabilityChecks: {
        ...defaults.machineLearning.availabilityChecks,
        enabled: false,
      },
    });
  });
  afterEach(() => {
    repository.teardown();
    vi.unstubAllGlobals();
  });

  it('sends the normalized in-memory preview and forwards cancellation to face inference', async () => {
    const bytes = Buffer.from('upright preview');
    const signal = new AbortController().signal;
    fetchMock.mockResolvedValue(Response.json({ imageWidth: 80, imageHeight: 40, 'facial-recognition': [] }));
    await expect(repository.detectFaces(bytes, defaults.machineLearning.facialRecognition, signal)).resolves.toEqual({
      imageWidth: 80,
      imageHeight: 40,
      faces: [],
    });
    const [, request] = fetchMock.mock.calls[0];
    expect(request.signal).toBe(signal);
    expect(Buffer.from(await request.body.get('image').arrayBuffer())).toEqual(bytes);
    expect(JSON.parse(request.body.get('entries'))['facial-recognition'].recognition.modelName).toBe(
      defaults.machineLearning.facialRecognition.modelName,
    );
  });
  it('does not issue inference for an already cancelled search', async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(
      repository.detectFaces(Buffer.from('preview'), defaults.machineLearning.facialRecognition, controller.signal),
    ).rejects.toThrow();
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it('does not retry other servers after search cancellation', async () => {
    repository.setup({
      ...defaults.machineLearning,
      urls: ['http://ml', 'http://other-ml'],
      availabilityChecks: {
        ...defaults.machineLearning.availabilityChecks,
        enabled: false,
      },
    });
    const controller = new AbortController();
    fetchMock.mockImplementation(() => {
      controller.abort();
      throw new Error('aborted');
    });
    await expect(
      repository.detectFaces(Buffer.from('preview'), defaults.machineLearning.facialRecognition, controller.signal),
    ).rejects.toThrow();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
