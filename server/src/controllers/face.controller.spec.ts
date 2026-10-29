import request from 'supertest';
import { FaceController } from 'src/controllers/face.controller.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { MediaService } from 'src/services/media.service.js';
import { PersonService } from 'src/services/person.service.js';
import { errorDto } from 'test/medium/responses.js';
import { newUuid } from 'test/small.factory.js';
import { ControllerContext, automock, controllerSetup, mockBaseService } from 'test/utils.js';

describe(FaceController.name, () => {
  let ctx: ControllerContext;
  const service = mockBaseService(PersonService);
  const mediaService = mockBaseService(MediaService);

  beforeAll(async () => {
    ctx = await controllerSetup(FaceController, [
      { provide: PersonService, useValue: service },
      { provide: MediaService, useValue: mediaService },
      { provide: LoggingRepository, useValue: automock(LoggingRepository, { strict: false }) },
    ]);
    return () => ctx.close();
  });

  beforeEach(() => {
    service.resetAllMocks();
    mediaService.resetAllMocks();
    ctx.reset();
  });

  describe('GET /faces/:id/thumbnail', () => {
    it('should be an authenticated route', async () => {
      await request(ctx.getHttpServer()).get(`/faces/${newUuid()}/thumbnail`);
      expect(ctx.authenticate).toHaveBeenCalled();
    });

    it('should require a valid id', async () => {
      const { status, body } = await request(ctx.getHttpServer())
        .get('/faces/invalid/thumbnail')
        .set('Authorization', `Bearer token`);
      expect(status).toBe(400);
      expect(body).toEqual(errorDto.validationError([{ path: ['id'], message: 'Invalid UUID' }]));
    });

    it('should send the face as a privately cached jpeg', async () => {
      const id = newUuid();
      mediaService.getFaceThumbnail.mockResolvedValue(Buffer.from('face'));

      const { status, headers, body } = await request(ctx.getHttpServer())
        .get(`/faces/${id}/thumbnail`)
        .set('Authorization', `Bearer token`);

      expect(status).toBe(200);
      expect(headers['content-type']).toBe('image/jpeg');
      expect(headers['cache-control']).toBe('private, max-age=86400, no-transform');
      expect(Buffer.from(body).toString()).toBe('face');
      expect(mediaService.getFaceThumbnail).toHaveBeenCalledWith(undefined, id);
    });
  });
});
