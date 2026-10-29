import { Injectable } from '@nestjs/common';
import { Insertable } from 'kysely';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { JobOf, VideoFormat, VideoStreamInfo } from 'src/types.js';
import { OnJob } from 'src/decorators.js';
import { SystemConfig } from 'src/dtos/config.dto.js';
import { AssetType, AssetVisibility, JobName, JobStatus, QueueName } from 'src/enum.js';
import { AssetJobRepository } from 'src/repositories/asset-job.repository.js';
import { AssetFaceTable } from 'src/schema/tables/asset-face.table.js';
import { FaceSearchTable } from 'src/schema/tables/face-search.table.js';
import { BaseService } from 'src/services/base.service.js';
import { getVideoFrameCommand } from 'src/utils/media.js';
import { batched, isFacialRecognitionEnabled } from 'src/utils/misc.js';
import {
  VIDEO_FACE_MIN_SIGHTINGS,
  VIDEO_FRAME_FINGERPRINT_SIZE,
  VideoFace,
  VideoFaceCluster,
  clusterVideoFaces,
  getEmbeddingDistance,
  getVideoFaceTimestamps,
  isNearDuplicateFrame,
  parseEmbedding,
} from 'src/utils/video-faces.js';

type VideoFaceAsset = NonNullable<Awaited<ReturnType<AssetJobRepository['getForDetectVideoFacesJob']>>>;

/** A video this many frames in a row could not be read from is given up on. */
const MAX_FRAME_FAILURES = 3;

/**
 * Face detection only looks at a video's preview, a single frame from its start. This looks at frames from the whole
 * video and adds one face, the best one, for each person who is seen there but is not on the video yet.
 */
@Injectable()
export class VideoFaceService extends BaseService {
  @OnJob({ name: JobName.AssetDetectVideoFacesQueueAll, queue: QueueName.VideoFaceDetection })
  async handleQueueDetectVideoFaces({ force }: JobOf<JobName.AssetDetectVideoFacesQueueAll>): Promise<JobStatus> {
    const { machineLearning } = await this.getConfig({ withCache: false });
    if (!isFacialRecognitionEnabled(machineLearning)) {
      return JobStatus.Skipped;
    }

    for await (const assets of batched(this.assetJobRepository.streamForDetectVideoFacesJob(force))) {
      await this.jobRepository.queueAll(
        assets.map((asset) => ({ name: JobName.AssetDetectVideoFaces, data: { id: asset.id } })),
      );
    }

    return JobStatus.Success;
  }

  @OnJob({ name: JobName.AssetDetectVideoFaces, queue: QueueName.VideoFaceDetection })
  async handleDetectVideoFaces({ id }: JobOf<JobName.AssetDetectVideoFaces>): Promise<JobStatus> {
    const config = await this.getConfig({ withCache: true });
    const { machineLearning } = config;
    if (!isFacialRecognitionEnabled(machineLearning)) {
      return JobStatus.Skipped;
    }

    const asset = await this.assetJobRepository.getForDetectVideoFacesJob(id);
    if (!asset) {
      return JobStatus.Failed;
    }

    if (
      asset.type !== AssetType.Video ||
      asset.visibility === AssetVisibility.Hidden ||
      asset.deletedAt ||
      asset.isOffline
    ) {
      return JobStatus.Skipped;
    }

    let videoStream: VideoStreamInfo | null = asset.videoStream;
    let { format, duration } = asset;
    if (!videoStream || !duration) {
      // videos added before stream metadata was stored still have it in the file
      const probed = await this.mediaRepository.probe(asset.originalPath);
      videoStream ??= probed.videoStreams[0] ?? null;
      format ??= probed.format;
      duration ||= Math.round(probed.format.duration * 1000);
    }

    if (!videoStream || !duration) {
      this.logger.warn(`Skipped face detection across video ${id}: no video stream found`);
      return JobStatus.Failed;
    }

    const faces = await this.detectFacesInFrames(asset, { videoStream, format, duration }, config);
    if (!faces) {
      this.logger.error(`Could not read any frame of video ${id} to detect faces in`);
      return JobStatus.Failed;
    }

    const { maxDistance } = machineLearning.facialRecognition;
    const newFaces = await this.getNewFaces(asset, clusterVideoFaces(faces, maxDistance), maxDistance);

    const facesToAdd: (Insertable<AssetFaceTable> & { id: string; assetId: string })[] = [];
    const embeddings: Insertable<FaceSearchTable>[] = [];
    for (const { boundingBox, embedding, imageWidth, imageHeight, timestamp } of newFaces) {
      const faceId = this.cryptoRepository.randomUUID();
      facesToAdd.push({
        id: faceId,
        assetId: asset.id,
        imageWidth,
        imageHeight,
        boundingBoxX1: boundingBox.x1,
        boundingBoxY1: boundingBox.y1,
        boundingBoxX2: boundingBox.x2,
        boundingBoxY2: boundingBox.y2,
        frameTimestamp: timestamp,
      });
      embeddings.push({ faceId, embedding });
    }

    if (facesToAdd.length > 0) {
      await this.personRepository.refreshFaces(facesToAdd, [], embeddings);
      this.logger.log(`Detected ${facesToAdd.length} new faces across video ${id}`);
      const jobs = facesToAdd.map((face) => ({ name: JobName.FacialRecognition, data: { id: face.id } }) as const);
      await this.jobRepository.queueAll([{ name: JobName.FacialRecognitionQueueAll, data: { force: false } }, ...jobs]);
    }

    await this.assetRepository.upsertJobStatus({ assetId: id, videoFacesDetectedAt: new Date() });

    return JobStatus.Success;
  }

  /** The faces in frames taken across the video, or nothing when not one frame could be read. */
  private async detectFacesInFrames(
    asset: VideoFaceAsset,
    { videoStream, format, duration }: { videoStream: VideoStreamInfo; format: VideoFormat | null; duration: number },
    config: SystemConfig,
  ): Promise<VideoFace[] | undefined> {
    const folder = join(tmpdir(), 'immich-video-faces', this.cryptoRepository.randomUUID());
    this.storageRepository.mkdirSync(folder);

    const faces: VideoFace[] = [];
    let frames = 0;
    let failures = 0;
    let previous: Buffer | undefined;
    try {
      for (const timestamp of getVideoFaceTimestamps(duration)) {
        const framePath = join(folder, `${timestamp}.jpg`);
        let fingerprint: Buffer;
        try {
          const command = getVideoFrameCommand(config, timestamp, videoStream, format);
          await this.mediaRepository.transcode(asset.originalPath, framePath, command);
          fingerprint = await this.mediaRepository.getImageFingerprint(framePath, VIDEO_FRAME_FINGERPRINT_SIZE);
        } catch (error: Error | any) {
          this.logger.warn(
            `Could not read the frame ${timestamp} ms into video ${asset.id}: ${error?.message ?? error}`,
          );
          if (++failures >= MAX_FRAME_FAILURES) {
            break;
          }
          continue;
        }

        failures = 0;
        frames++;

        // a frame that barely changed since the last one analysed has no face to add
        if (!isNearDuplicateFrame(previous, fingerprint)) {
          previous = fingerprint;
          const detected = await this.machineLearningRepository.detectFaces(
            framePath,
            config.machineLearning.facialRecognition,
          );
          for (const face of detected.faces) {
            const vector = parseEmbedding(face.embedding);
            if (vector) {
              faces.push({
                ...face,
                timestamp,
                imageWidth: detected.imageWidth,
                imageHeight: detected.imageHeight,
                vector,
              });
            }
          }
        }

        await this.storageRepository.unlink(framePath);
      }
    } finally {
      await this.storageRepository.unlinkDir(folder, { recursive: true, force: true });
    }

    this.logger.debug(`${faces.length} faces detected in ${frames} frames of video ${asset.id}`);
    return frames > 0 ? faces : undefined;
  }

  /**
   * One face for each person seen across the video who is not on it yet. Someone is on it already when one of its faces
   * is within `maxDistance` of theirs, or when facial recognition put, or would put, one of its faces in the same person.
   * Someone nobody knows yet also needs to be seen more than once, which leaves out passers-by and blurred frames.
   */
  private async getNewFaces(asset: VideoFaceAsset, clusters: VideoFaceCluster[], maxDistance: number) {
    if (clusters.length === 0) {
      return [];
    }

    const findPerson = async (embedding: string) => {
      const [match] = await this.searchRepository.searchFaces({
        clusterGroupId: asset.clusterGroupId,
        embedding,
        maxDistance,
        numResults: 1,
        hasPerson: true,
        minBirthDate: asset.fileCreatedAt,
      });
      return match?.personGroupId ?? undefined;
    };

    // the faces from the preview, tagged by hand or found by an earlier run stay as they are
    const known: number[][] = [];
    const people = new Set<string>();
    for (const face of asset.faces) {
      const vector = parseEmbedding(face.embedding);
      if (vector) {
        known.push(vector);
      }

      const personGroupId = face.personGroupId ?? (face.embedding ? await findPerson(face.embedding) : undefined);
      if (personGroupId) {
        people.add(personGroupId);
      }
    }

    const newFaces: VideoFace[] = [];
    for (const { face, sightings } of clusters) {
      if (known.some((vector) => getEmbeddingDistance(vector, face.vector) <= maxDistance)) {
        continue;
      }

      const personGroupId = await findPerson(face.embedding);
      if (personGroupId ? people.has(personGroupId) : sightings < VIDEO_FACE_MIN_SIGHTINGS) {
        continue;
      }

      if (personGroupId) {
        people.add(personGroupId);
      }
      newFaces.push(face);
    }

    return newFaces;
  }
}
