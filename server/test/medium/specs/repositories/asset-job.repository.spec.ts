import { Insertable, Kysely } from 'kysely';
import { AssetFileType, AssetType, AssetVisibility, SourceType } from 'src/enum.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { DB } from 'src/schema/index.js';
import { AssetTable } from 'src/schema/tables/asset.table.js';
import { BaseService } from 'src/services/base.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

const consume = async <T>(generator: AsyncIterableIterator<T>) => {
  const values: T[] = await Array.fromAsync(generator);

  return values;
};

let defaultDatabase: Kysely<DB>;

const setup = (db?: Kysely<DB>) => {
  const { ctx } = newMediumService(BaseService, {
    database: db || defaultDatabase,
    real: [],
    mock: [LoggingRepository],
  });
  return { ctx, sut: ctx.get(AssetJobRepository) };
};

beforeAll(async () => {
  defaultDatabase = await getKyselyDB();
});

describe(AssetJobRepository.name, () => {
  describe('streamForThumbnailJob', () => {
    it('should work', async () => {
      const { sut } = setup();
      const stream = sut.streamForThumbnailJob({ force: false, fullsizeEnabled: false });
      await expect(stream.next()).resolves.toEqual({ done: true, value: undefined });
    });

    it('should queue an asset with missing thumbnails', async () => {
      const { ctx, sut } = setup();
      const { user } = await ctx.newUser();
      const { asset } = await ctx.newAsset({ ownerId: user.id });
      await ctx.newJobStatus({ assetId: asset.id, metadataExtractedAt: new Date() });

      const stream = sut.streamForThumbnailJob({ force: false, fullsizeEnabled: false });
      await expect(consume(stream)).resolves.toEqual([expect.objectContaining({ id: asset.id })]);
    });

    it('should skip assets without missing thumbnails', async () => {
      const { ctx, sut } = setup();
      const { user } = await ctx.newUser();
      const { asset } = await ctx.newAsset({ ownerId: user.id, thumbhash: Buffer.from('fake-thumbhash-buffer') });
      await ctx.newJobStatus({ assetId: asset.id, metadataExtractedAt: new Date() });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Thumbnail, path: 'thumbnail.jpg' });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Preview, path: 'preview.jpg' });

      const stream = sut.streamForThumbnailJob({ force: false, fullsizeEnabled: false });
      await expect(consume(stream)).resolves.not.toEqual(
        expect.arrayContaining([expect.objectContaining({ id: asset.id })]),
      );
    });

    it('should queue assets with a missing full size', async () => {
      const { ctx, sut } = setup();
      const { user } = await ctx.newUser();
      const { asset } = await ctx.newAsset({
        ownerId: user.id,
        thumbhash: Buffer.from('fake-thumbhash-buffer'),
        originalFileName: 'photo.cr2',
      });
      await ctx.newJobStatus({ assetId: asset.id, metadataExtractedAt: new Date() });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Thumbnail, path: 'thumbnail.jpg' });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Preview, path: 'preview.jpg' });

      const stream = sut.streamForThumbnailJob({ force: false, fullsizeEnabled: true });
      await expect(consume(stream)).resolves.toEqual(
        expect.arrayContaining([expect.objectContaining({ id: asset.id })]),
      );
    });

    it('should skip assets with after they have full size previews', async () => {
      const { ctx, sut } = setup();
      const { user } = await ctx.newUser();
      const { asset } = await ctx.newAsset({ ownerId: user.id, thumbhash: Buffer.from('fake-thumbhash-buffer') });
      await ctx.newJobStatus({ assetId: asset.id, metadataExtractedAt: new Date() });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Thumbnail, path: 'thumbnail.jpg' });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Preview, path: 'preview.jpg' });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.FullSize, path: 'fullsize.jpg' });

      const stream = sut.streamForThumbnailJob({ force: false, fullsizeEnabled: true });
      await expect(consume(stream)).resolves.not.toEqual(
        expect.arrayContaining([expect.objectContaining({ id: asset.id })]),
      );
    });

    it('should skip assets with web-compatible originals', async () => {
      const { ctx, sut } = setup();
      const { user } = await ctx.newUser();
      const { asset } = await ctx.newAsset({
        ownerId: user.id,
        thumbhash: Buffer.from('fake-thumbhash-buffer'),
        originalFileName: 'photo.jpg',
      });
      await ctx.newJobStatus({ assetId: asset.id, metadataExtractedAt: new Date() });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Thumbnail, path: 'thumbnail.jpg' });
      await ctx.newAssetFile({ assetId: asset.id, type: AssetFileType.Preview, path: 'preview.jpg' });

      const stream = sut.streamForThumbnailJob({ force: false, fullsizeEnabled: true });
      await expect(consume(stream)).resolves.not.toEqual(
        expect.arrayContaining([expect.objectContaining({ id: asset.id })]),
      );
    });
  });

  describe('streamForDetectVideoFacesJob', () => {
    it('should only queue videos whose preview has been searched for faces', async () => {
      const { ctx, sut } = setup(await getKyselyDB());
      const { user } = await ctx.newUser();
      const newVideo = async (dto: Partial<Insertable<AssetTable>> = {}) => {
        const { asset } = await ctx.newAsset({ ownerId: user.id, type: AssetType.Video, ...dto });
        await ctx.newJobStatus({ assetId: asset.id });
        return asset;
      };

      const video = await newVideo();
      const searched = await newVideo();
      await ctx.get(AssetRepository).upsertJobStatus({ assetId: searched.id, videoFacesDetectedAt: new Date() });
      const previewNotSearched = await newVideo();
      await ctx.get(AssetRepository).upsertJobStatus({ assetId: previewNotSearched.id, facesRecognizedAt: null });
      await newVideo({ type: AssetType.Image });
      await newVideo({ visibility: AssetVisibility.Hidden });
      await newVideo({ deletedAt: new Date() });
      await newVideo({ isOffline: true });

      await expect(consume(sut.streamForDetectVideoFacesJob(false))).resolves.toEqual([{ id: video.id }]);

      const all = await consume(sut.streamForDetectVideoFacesJob(true));
      expect(all).toHaveLength(2);
      expect(all).toEqual(expect.arrayContaining([{ id: video.id }, { id: searched.id }]));
    });
  });

  describe('getForDetectVideoFacesJob', () => {
    it('should return the video with the faces already on it', async () => {
      const { ctx, sut } = setup();
      const { user } = await ctx.newUser();
      const { asset } = await ctx.newAsset({ ownerId: user.id, type: AssetType.Video, duration: 12_000 });
      await ctx.newExif({ assetId: asset.id, exifImageWidth: 3840, exifImageHeight: 2160, orientation: '6' });
      await ctx.database
        .insertInto('asset_video')
        .values({
          assetId: asset.id,
          bitrate: 40_000_000,
          frameCount: 720,
          timeBase: 600,
          index: 0,
          profile: null,
          level: null,
          colorPrimaries: 9,
          colorTransfer: 18,
          colorMatrix: 9,
          dvProfile: null,
          dvLevel: null,
          dvBlSignalCompatibilityId: null,
          codecName: 'hevc',
          formatName: 'mov,mp4,m4a,3gp,3g2,mj2',
          formatLongName: 'QuickTime / MOV',
          pixelFormat: 'yuv420p10le',
        })
        .execute();
      const { result: person } = await ctx.newPerson({ ownerId: user.id });
      const { assetFace: previewFace } = await ctx.newAssetFace({ assetId: asset.id });
      const embedding = JSON.stringify(Array.from({ length: 512 }, (_, index) => Number(index === 7)));
      await ctx.database.insertInto('face_search').values({ faceId: previewFace.id, embedding }).execute();
      const { assetFace: manualFace } = await ctx.newAssetFace({
        assetId: asset.id,
        personGroupId: person.personGroupId,
        sourceType: SourceType.Manual,
      });

      const result = await sut.getForDetectVideoFacesJob(asset.id);

      expect(result).toEqual(
        expect.objectContaining({
          id: asset.id,
          type: AssetType.Video,
          duration: 12_000,
          originalPath: asset.originalPath,
          clusterGroupId: user.clusterGroupId,
          videoStream: expect.objectContaining({ width: 3840, height: 2160, rotation: -90, colorTransfer: 18 }),
          format: expect.objectContaining({ formatName: 'mov,mp4,m4a,3gp,3g2,mj2', duration: 12_000 }),
        }),
      );
      expect(result!.faces).toHaveLength(2);
      expect(result!.faces).toEqual(
        expect.arrayContaining([
          { id: previewFace.id, personGroupId: null, embedding },
          { id: manualFace.id, personGroupId: person.personGroupId, embedding: null },
        ]),
      );
    });
  });

  describe('getForOcr', () => {
    it('should not return the edited preview file', async () => {
      const { ctx, sut } = setup();
      const { user } = await ctx.newUser();
      const { asset } = await ctx.newAsset({ ownerId: user.id });

      await ctx.newAssetFile({
        assetId: asset.id,
        type: AssetFileType.Preview,
        path: 'preview_edited.jpg',
        isEdited: true,
      });
      await ctx.newAssetFile({
        assetId: asset.id,
        type: AssetFileType.Preview,
        path: 'preview_unedited.jpg',
        isEdited: false,
      });

      const result = await sut.getForOcr(asset.id);

      expect(result).toEqual(
        expect.objectContaining({
          previewFile: 'preview_unedited.jpg',
        }),
      );
    });
  });
});
