import { basename } from 'node:path';
import { AssetType, AssetVisibility, ImmichWorker, JobName, JobStatus } from 'src/enum.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { Face } from 'src/repositories/machine-learning.repository.js';
import { VideoFaceService } from 'src/services/video-face.service.js';
import { probeStub, videoInfoStub } from 'test/fixtures/media.stub.js';
import { systemConfigStub } from 'test/fixtures/system-config.stub.js';
import { newUuid } from 'test/small.factory.js';
import { ServiceMocks, makeStream, newTestService } from 'test/utils.js';

type VideoFaceAsset = NonNullable<Awaited<ReturnType<AssetJobRepository['getForDetectVideoFacesJob']>>>;

const getVideo = (overrides: Partial<VideoFaceAsset> = {}): VideoFaceAsset => ({
  id: 'video-1',
  type: AssetType.Video,
  visibility: AssetVisibility.Timeline,
  deletedAt: null,
  isOffline: false,
  originalPath: '/original/video.mp4',
  duration: 10_000,
  fileCreatedAt: new Date('2024-05-01T12:00:00.000Z'),
  clusterGroupId: 'cluster-group-1',
  videoStream: probeStub.videoStream2160p.videoStream,
  format: probeStub.videoStream2160p.format,
  faces: [],
  ...overrides,
});

const face = (embedding: number[], size = 200, x1 = 100): Face => ({
  boundingBox: { x1, y1: 100, x2: x1 + size, y2: 100 + size },
  embedding: JSON.stringify(embedding),
  score: 0.9,
});

const alice = [1, 0, 0];
const bob = [0, 1, 0];
const carol = [0, 0, 1];

describe(VideoFaceService.name, () => {
  let sut: VideoFaceService;
  let mocks: ServiceMocks;

  /** faces the machine learning service finds in the frame at each timestamp */
  const detect = (frames: Record<number, Face[]>) =>
    mocks.machineLearning.detectFaces.mockImplementation((path) =>
      Promise.resolve({
        imageWidth: 2560,
        imageHeight: 1440,
        faces: frames[Number(basename(path as string, '.jpg'))] ?? [],
      }),
    );

  beforeEach(() => {
    ({ sut, mocks } = newTestService(VideoFaceService));

    mocks.config.getWorker.mockReturnValue(ImmichWorker.Microservices);
    mocks.search.searchFaces.mockResolvedValue([]);
    let id = 0;
    mocks.crypto.randomUUID.mockImplementation(() => `uuid-${++id}`);
  });

  it('should work', () => {
    expect(sut).toBeDefined();
  });

  describe('handleQueueDetectVideoFaces', () => {
    it('should do nothing if machine learning is disabled', async () => {
      mocks.systemMetadata.get.mockResolvedValue(systemConfigStub.machineLearningDisabled);

      await expect(sut.handleQueueDetectVideoFaces({ force: false })).resolves.toBe(JobStatus.Skipped);

      expect(mocks.assetJob.streamForDetectVideoFacesJob).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
    });

    it('should do nothing if facial recognition is disabled', async () => {
      mocks.systemMetadata.get.mockResolvedValue({ machineLearning: { facialRecognition: { enabled: false } } });

      await expect(sut.handleQueueDetectVideoFaces({ force: false })).resolves.toBe(JobStatus.Skipped);

      expect(mocks.assetJob.streamForDetectVideoFacesJob).not.toHaveBeenCalled();
    });

    it.each([false, true])('should queue the videos to search with force=%s', async (force) => {
      const id = newUuid();
      mocks.assetJob.streamForDetectVideoFacesJob.mockReturnValue(makeStream([{ id }]));

      await expect(sut.handleQueueDetectVideoFaces({ force })).resolves.toBe(JobStatus.Success);

      expect(mocks.assetJob.streamForDetectVideoFacesJob).toHaveBeenCalledWith(force);
      expect(mocks.job.queueAll).toHaveBeenCalledWith([{ name: JobName.AssetDetectVideoFaces, data: { id } }]);
    });
  });

  describe('handleDetectVideoFaces', () => {
    it('should do nothing if machine learning is disabled', async () => {
      mocks.systemMetadata.get.mockResolvedValue(systemConfigStub.machineLearningDisabled);

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Skipped);

      expect(mocks.assetJob.getForDetectVideoFacesJob).not.toHaveBeenCalled();
      expect(mocks.media.transcode).not.toHaveBeenCalled();
    });

    it('should do nothing if facial recognition is disabled', async () => {
      mocks.systemMetadata.get.mockResolvedValue({ machineLearning: { facialRecognition: { enabled: false } } });

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Skipped);

      expect(mocks.media.transcode).not.toHaveBeenCalled();
    });

    it('should fail when the asset does not exist', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(void 0);

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Failed);
    });

    it.each([
      { type: AssetType.Image },
      { visibility: AssetVisibility.Hidden },
      { deletedAt: new Date() },
      { isOffline: true },
    ])('should skip %o', async (overrides) => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo(overrides));

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Skipped);

      expect(mocks.media.transcode).not.toHaveBeenCalled();
      expect(mocks.machineLearning.detectFaces).not.toHaveBeenCalled();
      expect(mocks.asset.upsertJobStatus).not.toHaveBeenCalled();
    });

    it('should read the stream of a video without stored metadata from the file', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo({ videoStream: null, duration: null }));
      mocks.media.probe.mockResolvedValue({
        ...videoInfoStub.videoStream2160p,
        format: { ...videoInfoStub.videoStream2160p.format, duration: 6.04 },
      });
      detect({});

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Success);

      expect(mocks.media.probe).toHaveBeenCalledWith('/original/video.mp4');
      expect(mocks.media.transcode).toHaveBeenCalledTimes(3);
      expect(mocks.media.transcode).toHaveBeenCalledWith(
        '/original/video.mp4',
        expect.any(String),
        expect.objectContaining({
          outputOptions: expect.arrayContaining([
            'scale=-2:1440:flags=lanczos+accurate_rnd+full_chroma_int:out_range=pc',
          ]),
        }),
      );
    });

    it('should not read the file when the stored metadata is complete', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      detect({});

      await sut.handleDetectVideoFaces({ id: 'video-1' });

      expect(mocks.media.probe).not.toHaveBeenCalled();
    });

    it('should fail for a file without a video stream', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo({ videoStream: null }));
      mocks.media.probe.mockResolvedValue(videoInfoStub.noVideoStreams);

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Failed);

      expect(mocks.media.transcode).not.toHaveBeenCalled();
      expect(mocks.asset.upsertJobStatus).not.toHaveBeenCalled();
    });

    it('should look at frames from the whole video and clean them up', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      detect({});

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Success);

      expect(mocks.media.transcode).toHaveBeenCalledTimes(5);
      for (const [index, seconds] of ['1.000', '3.000', '5.000', '7.000', '9.000'].entries()) {
        const [input, output, command] = mocks.media.transcode.mock.calls[index];
        expect(input).toBe('/original/video.mp4');
        expect(output).toMatch(/immich-video-faces\/uuid-1\/\d+\.jpg$/);
        expect(command).toEqual(
          expect.objectContaining({
            inputOptions: ['-ss', seconds, '-sws_flags', 'accurate_rnd+full_chroma_int'],
            outputOptions: expect.arrayContaining([
              '-frames:v',
              '1',
              '-q:v',
              '2',
              '-vf',
              'scale=-2:1440:flags=lanczos+accurate_rnd+full_chroma_int:out_range=pc',
            ]),
            twoPass: false,
          }),
        );
        expect(mocks.machineLearning.detectFaces).toHaveBeenNthCalledWith(
          index + 1,
          output,
          expect.objectContaining({ modelName: 'buffalo_l', minScore: 0.7 }),
        );
        expect(mocks.storage.unlink).toHaveBeenNthCalledWith(index + 1, output);
      }
      expect(mocks.storage.mkdirSync).toHaveBeenCalledWith(expect.stringMatching(/immich-video-faces\/uuid-1$/));
      expect(mocks.storage.unlinkDir).toHaveBeenCalledWith(expect.stringMatching(/immich-video-faces\/uuid-1$/), {
        recursive: true,
        force: true,
      });
    });

    it('should mark a video without faces as searched', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      detect({});

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Success);

      expect(mocks.person.refreshFaces).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
      expect(mocks.asset.upsertJobStatus).toHaveBeenCalledWith({
        assetId: 'video-1',
        videoFacesDetectedAt: expect.any(Date),
      });
    });

    it('should add the best face of each person, with the frame it was found in', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      detect({
        1000: [face(alice, 100)],
        3000: [face(alice, 300, 400), face(bob, 150, 1000)],
        5000: [face([0.9, 0.1, 0], 200), face(bob, 250, 1200)],
      });

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Success);

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [
          {
            id: 'uuid-2',
            assetId: 'video-1',
            imageWidth: 2560,
            imageHeight: 1440,
            boundingBoxX1: 400,
            boundingBoxY1: 100,
            boundingBoxX2: 700,
            boundingBoxY2: 400,
            frameTimestamp: 3000,
          },
          {
            id: 'uuid-3',
            assetId: 'video-1',
            imageWidth: 2560,
            imageHeight: 1440,
            boundingBoxX1: 1200,
            boundingBoxY1: 100,
            boundingBoxX2: 1450,
            boundingBoxY2: 350,
            frameTimestamp: 5000,
          },
        ],
        [],
        [
          { faceId: 'uuid-2', embedding: JSON.stringify(alice) },
          { faceId: 'uuid-3', embedding: JSON.stringify(bob) },
        ],
      );
      expect(mocks.job.queueAll).toHaveBeenCalledWith([
        { name: JobName.FacialRecognitionQueueAll, data: { force: false } },
        { name: JobName.FacialRecognition, data: { id: 'uuid-2' } },
        { name: JobName.FacialRecognition, data: { id: 'uuid-3' } },
      ]);
      expect(mocks.asset.upsertJobStatus).toHaveBeenCalledWith({
        assetId: 'video-1',
        videoFacesDetectedAt: expect.any(Date),
      });
    });

    it('should not add someone whose face is already on the video', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(
        getVideo({ faces: [{ id: 'preview-face', personGroupId: null, embedding: JSON.stringify([0.95, 0.05, 0]) }] }),
      );
      detect({ 1000: [face(alice), face(bob)], 3000: [face(alice), face(bob)] });

      await sut.handleDetectVideoFaces({ id: 'video-1' });

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [expect.objectContaining({ frameTimestamp: 1000 })],
        [],
        [{ faceId: expect.any(String), embedding: JSON.stringify(bob) }],
      );
    });

    it('should not add someone facial recognition already found on the video', async () => {
      // e.g. a face tagged by hand, which has no embedding to compare with
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(
        getVideo({ faces: [{ id: 'manual-face', personGroupId: 'person-alice', embedding: null }] }),
      );
      mocks.search.searchFaces.mockImplementation(({ embedding }) =>
        Promise.resolve(
          embedding === JSON.stringify(alice)
            ? [{ id: 'other-face', personGroupId: 'person-alice', distance: 0.3 }]
            : [],
        ),
      );
      detect({ 1000: [face(alice), face(bob)], 3000: [face(alice), face(bob)] });

      await sut.handleDetectVideoFaces({ id: 'video-1' });

      expect(mocks.search.searchFaces).toHaveBeenCalledWith({
        clusterGroupId: 'cluster-group-1',
        embedding: JSON.stringify(alice),
        maxDistance: 0.5,
        numResults: 1,
        hasPerson: true,
        minBirthDate: new Date('2024-05-01T12:00:00.000Z'),
      });
      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [expect.anything()],
        [],
        [{ faceId: expect.any(String), embedding: JSON.stringify(bob) }],
      );
    });

    it('should not add someone the face from the preview will be recognised as', async () => {
      // the preview shows Alice from the side, too different to compare directly, and is not recognised yet
      const profile = JSON.stringify([0, 0.2, 1]);
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(
        getVideo({ faces: [{ id: 'preview-face', personGroupId: null, embedding: profile }] }),
      );
      mocks.search.searchFaces.mockImplementation(({ embedding }) =>
        Promise.resolve(
          [profile, JSON.stringify(alice)].includes(embedding)
            ? [{ id: 'other-face', personGroupId: 'person-alice', distance: 0.3 }]
            : [],
        ),
      );
      detect({ 1000: [face(alice)], 3000: [face(alice)] });

      await sut.handleDetectVideoFaces({ id: 'video-1' });

      expect(mocks.person.refreshFaces).not.toHaveBeenCalled();
      expect(mocks.asset.upsertJobStatus).toHaveBeenCalled();
    });

    it('should add someone known who was seen once, but not a stranger seen once', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      mocks.search.searchFaces.mockImplementation(({ embedding }) =>
        Promise.resolve(
          embedding === JSON.stringify(carol)
            ? [{ id: 'other-face', personGroupId: 'person-carol', distance: 0.2 }]
            : [],
        ),
      );
      detect({ 1000: [face(carol)], 3000: [face(bob)] });

      await sut.handleDetectVideoFaces({ id: 'video-1' });

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [expect.objectContaining({ frameTimestamp: 1000 })],
        [],
        [{ faceId: expect.any(String), embedding: JSON.stringify(carol) }],
      );
    });

    it('should add only one face for sightings recognised as the same person', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      mocks.search.searchFaces.mockResolvedValue([{ id: 'other-face', personGroupId: 'person-alice', distance: 0.4 }]);
      detect({ 1000: [face(alice, 300)], 3000: [face(carol, 100)] });

      await sut.handleDetectVideoFaces({ id: 'video-1' });

      expect(mocks.person.refreshFaces).toHaveBeenCalledWith(
        [expect.objectContaining({ frameTimestamp: 1000, boundingBoxX2: 400 })],
        [],
        [{ faceId: expect.any(String), embedding: JSON.stringify(alice) }],
      );
    });

    it('should not analyse frames that barely changed', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      mocks.media.getImageFingerprint.mockResolvedValue(Buffer.alloc(1024, 50));
      detect({ 1000: [face(alice)] });

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Success);

      expect(mocks.media.transcode).toHaveBeenCalledTimes(5);
      expect(mocks.machineLearning.detectFaces).toHaveBeenCalledTimes(1);
      expect(mocks.storage.unlink).toHaveBeenCalledTimes(5);
    });

    it('should carry on past a frame that cannot be read', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      mocks.media.transcode.mockResolvedValueOnce().mockRejectedValueOnce(new Error('Invalid data'));
      detect({});

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Success);

      expect(mocks.media.transcode).toHaveBeenCalledTimes(5);
      expect(mocks.machineLearning.detectFaces).toHaveBeenCalledTimes(4);
      expect(mocks.asset.upsertJobStatus).toHaveBeenCalled();
    });

    it('should give up on a video after three frames in a row cannot be read', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      mocks.media.transcode.mockRejectedValue(new Error('Invalid data'));

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).resolves.toBe(JobStatus.Failed);

      expect(mocks.media.transcode).toHaveBeenCalledTimes(3);
      expect(mocks.machineLearning.detectFaces).not.toHaveBeenCalled();
      expect(mocks.storage.unlinkDir).toHaveBeenCalledWith(expect.any(String), { recursive: true, force: true });
      expect(mocks.asset.upsertJobStatus).not.toHaveBeenCalled();
    });

    it('should clean up and leave the video for later when machine learning fails', async () => {
      mocks.assetJob.getForDetectVideoFacesJob.mockResolvedValue(getVideo());
      mocks.machineLearning.detectFaces.mockRejectedValue(new Error('Machine learning request failed for all URLs'));

      await expect(sut.handleDetectVideoFaces({ id: 'video-1' })).rejects.toThrow('failed for all URLs');

      expect(mocks.storage.unlinkDir).toHaveBeenCalledWith(expect.any(String), { recursive: true, force: true });
      expect(mocks.person.refreshFaces).not.toHaveBeenCalled();
      expect(mocks.asset.upsertJobStatus).not.toHaveBeenCalled();
    });
  });
});
