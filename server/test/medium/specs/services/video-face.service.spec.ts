import { Kysely } from 'kysely';
import { basename } from 'node:path';
import { AssetType, JobStatus } from 'src/enum.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { ConfigRepository } from 'src/repositories/config.repository.js';
import { CryptoRepository } from 'src/repositories/crypto.repository.js';
import { JobRepository } from 'src/repositories/job.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { Face, MachineLearningRepository } from 'src/repositories/machine-learning.repository.js';
import { MediaRepository } from 'src/repositories/media.repository.js';
import { PersonRepository } from 'src/repositories/person.repository.js';
import { SearchRepository } from 'src/repositories/search.repository.js';
import { StorageRepository } from 'src/repositories/storage.repository.js';
import { SystemMetadataRepository } from 'src/repositories/system-metadata.repository.js';
import { DB } from 'src/schema/index.js';
import { VideoFaceService } from 'src/services/video-face.service.js';
import { MediumTestContext, newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let defaultDatabase: Kysely<DB>;

const vector = (index: number) => JSON.stringify(Array.from({ length: 512 }, (_, i) => Number(i === index)));

const face = (index: number, size = 200): Face => ({
  boundingBox: { x1: 100, y1: 100, x2: 100 + size, y2: 100 + size },
  embedding: vector(index),
  score: 0.9,
});

// eslint-disable-next-line unicorn/no-unnecessary-parameters
const setup = (db?: Kysely<DB>) => {
  return newMediumService(VideoFaceService, {
    database: db || defaultDatabase,
    real: [
      AssetRepository,
      AssetJobRepository,
      ConfigRepository,
      CryptoRepository,
      PersonRepository,
      SearchRepository,
      SystemMetadataRepository,
    ],
    mock: [JobRepository, LoggingRepository, MachineLearningRepository, MediaRepository, StorageRepository],
  });
};

const newVideo = async (ctx: MediumTestContext, ownerId: string) => {
  const { asset } = await ctx.newAsset({ ownerId, type: AssetType.Video, duration: 6000 });
  await ctx.newExif({ assetId: asset.id, exifImageWidth: 1920, exifImageHeight: 1080 });
  await ctx.database
    .insertInto('asset_video')
    .values({
      assetId: asset.id,
      bitrate: 10_000_000,
      frameCount: 180,
      timeBase: 600,
      index: 0,
      profile: null,
      level: null,
      colorPrimaries: 1,
      colorTransfer: 1,
      colorMatrix: 1,
      dvProfile: null,
      dvLevel: null,
      dvBlSignalCompatibilityId: null,
      codecName: 'h264',
      formatName: 'mov,mp4,m4a,3gp,3g2,mj2',
      formatLongName: 'QuickTime / MOV',
      pixelFormat: 'yuv420p',
    })
    .execute();
  await ctx.newJobStatus({ assetId: asset.id });
  return asset;
};

const newFaceWithEmbedding = async (
  ctx: MediumTestContext,
  dto: { assetId: string; personGroupId?: string | null },
  index: number,
) => {
  const { assetFace } = await ctx.newAssetFace(dto);
  await ctx.database
    .insertInto('face_search')
    .values({ faceId: assetFace.id, embedding: vector(index) })
    .execute();
  return assetFace;
};

const getFaces = (ctx: MediumTestContext, assetId: string) =>
  ctx.database
    .selectFrom('asset_face')
    .leftJoin('face_search', 'face_search.faceId', 'asset_face.id')
    .select([
      'asset_face.id',
      'asset_face.personGroupId',
      'asset_face.frameTimestamp',
      'asset_face.boundingBoxX2',
      'face_search.embedding',
    ])
    .where('asset_face.assetId', '=', assetId)
    .orderBy('asset_face.frameTimestamp', 'asc')
    .execute();

/** ffmpeg writes each frame and the machine learning service finds these faces in the one at each timestamp */
const mockFrames = (ctx: MediumTestContext, frames: Record<number, Face[]>) => {
  ctx.getMock(StorageRepository).mkdirSync.mockReturnValue();
  ctx.getMock(StorageRepository).unlink.mockResolvedValue();
  ctx.getMock(StorageRepository).unlinkDir.mockResolvedValue();
  ctx.getMock(MediaRepository).transcode.mockResolvedValue();
  ctx.getMock(MediaRepository).getImageFingerprint.mockResolvedValue(Buffer.alloc(0));
  ctx.getMock(JobRepository).queueAll.mockResolvedValue();
  ctx
    .getMock(MachineLearningRepository)
    .detectFaces.mockImplementation((path) =>
      Promise.resolve({ imageWidth: 1920, imageHeight: 1080, faces: frames[Number(basename(path as string, '.jpg'))] }),
    );
};

beforeAll(async () => {
  defaultDatabase = await getKyselyDB();
});

describe(VideoFaceService.name, () => {
  it('should add the people found across a video and keep the faces already on it', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const video = await newVideo(ctx, user.id);
    // the preview shows face 0, and face 1 belongs to someone known from another asset
    const previewFace = await newFaceWithEmbedding(ctx, { assetId: video.id }, 0);
    const { result: known } = await ctx.newPerson({ ownerId: user.id, name: 'Known' });
    const { asset: photo } = await ctx.newAsset({ ownerId: user.id });
    await newFaceWithEmbedding(ctx, { assetId: photo.id, personGroupId: known.personGroupId }, 1);

    mockFrames(ctx, { 1000: [face(0), face(2, 100)], 3000: [face(2, 300)], 5000: [face(1), face(3)] });

    await expect(sut.handleDetectVideoFaces({ id: video.id })).resolves.toBe(JobStatus.Success);

    // face 2 is new and seen twice, face 1 is known; face 0 is already on the video and face 3 a stranger seen once
    await expect(getFaces(ctx, video.id)).resolves.toEqual([
      { id: expect.any(String), personGroupId: null, frameTimestamp: 3000, boundingBoxX2: 400, embedding: vector(2) },
      { id: expect.any(String), personGroupId: null, frameTimestamp: 5000, boundingBoxX2: 300, embedding: vector(1) },
      { id: previewFace.id, personGroupId: null, frameTimestamp: null, boundingBoxX2: 1, embedding: vector(0) },
    ]);
    await expect(
      ctx.database
        .selectFrom('asset_job_status')
        .select('videoFacesDetectedAt')
        .where('assetId', '=', video.id)
        .executeTakeFirstOrThrow(),
    ).resolves.toEqual({ videoFacesDetectedAt: expect.any(Date) });

    // searching the video again finds the same people and adds nothing
    await expect(sut.handleDetectVideoFaces({ id: video.id })).resolves.toBe(JobStatus.Success);
    await expect(getFaces(ctx, video.id)).resolves.toHaveLength(3);
  });

  it('should not add someone tagged on the video by hand', async () => {
    const { sut, ctx } = setup();
    const { user } = await ctx.newUser();
    const video = await newVideo(ctx, user.id);
    const { result: person } = await ctx.newPerson({ ownerId: user.id, name: 'Tagged' });
    const { asset: photo } = await ctx.newAsset({ ownerId: user.id });
    await newFaceWithEmbedding(ctx, { assetId: photo.id, personGroupId: person.personGroupId }, 4);
    await ctx.newAssetFace({ assetId: video.id, personGroupId: person.personGroupId });

    mockFrames(ctx, { 1000: [face(4)], 3000: [face(4)], 5000: [face(4)] });

    await expect(sut.handleDetectVideoFaces({ id: video.id })).resolves.toBe(JobStatus.Success);

    await expect(getFaces(ctx, video.id)).resolves.toHaveLength(1);
  });
});
