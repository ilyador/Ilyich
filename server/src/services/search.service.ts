import { BadRequestException, Injectable } from '@nestjs/common';
import { LRUMap } from 'mnemonist';
import { AssetMapOptions, AssetResponseDto, MapAsset, mapAsset } from 'src/dtos/asset-response.dto.js';
import { AuthDto } from 'src/dtos/auth.dto.js';
import { SystemConfig } from 'src/dtos/config.dto.js';
import { PersonResponseDto, mapPerson } from 'src/dtos/person.dto.js';
import {
  LargeAssetSearchDto,
  MetadataSearchDto,
  PlacesResponseDto,
  RandomSearchDto,
  SearchFilter,
  SearchPeopleDto,
  SearchPlacesDto,
  SearchResponseDto,
  SearchStatisticsResponseDto,
  SearchSuggestionRequestDto,
  SearchSuggestionType,
  SmartSearchDto,
  StatisticsSearchDto,
  isFullyAlbumConfined,
  isNewShapeRequest,
  mapPlaces,
} from 'src/dtos/search.dto.js';
import { AssetOrder, AssetVisibility, Permission } from 'src/enum.js';
import { AssetSearchScope } from 'src/repositories/search.repository.js';
import { BaseService } from 'src/services/base.service.js';
import { requireElevatedPermission } from 'src/utils/access.js';
import { getMyPartnerIds } from 'src/utils/asset.util.js';
import { isSmartSearchEnabled } from 'src/utils/misc.js';
import { NaturalSearchPlan, planNaturalSearch } from 'src/utils/natural-search.js';
import { decodeSearchCursor, encodeSearchCursor } from 'src/utils/search-cursor.js';
import { applyLockedVisibilityPolicy, collectFilterIds } from 'src/utils/search-filter.js';

const verificationPageSize = 10;
const verificationScanPages = 3;

type SearchPagination = { nextPage?: string | null; nextCursor?: string | null };
type SearchCandidatePage = { items: MapAsset[]; page: SearchPagination };

@Injectable()
export class SearchService extends BaseService {
  private embeddingCache = new LRUMap<string, string>(100);
  private verifying = false;

  async searchPerson(auth: AuthDto, dto: SearchPeopleDto): Promise<PersonResponseDto[]> {
    const people = await this.personRepository.getByName(auth.user.id, dto.name, { withHidden: dto.withHidden });
    return people.map((person) => mapPerson(person));
  }

  async searchPlaces(dto: SearchPlacesDto): Promise<PlacesResponseDto[]> {
    const places = await this.searchRepository.searchPlaces(dto.name);
    return places.map((place) => mapPlaces(place));
  }

  async getExploreData(auth: AuthDto) {
    const options = { maxFields: 12, minAssetsPerField: 5 };

    const cities = await this.assetRepository.getAssetIdByCity(auth.user.id, options);
    const cityAssets = await this.assetRepository.getByIdsWithAllRelationsButStacks(
      cities.items.map(({ data }) => data),
      auth.user.id,
    );
    const cityItems = cityAssets.map((asset) => ({ value: asset.exifInfo!.city!, data: mapAsset(asset, { auth }) }));

    const recents = await this.assetRepository.getRecentlyCreatedAssetIds(auth.user.id, options.maxFields);
    const recentAssets = await this.assetRepository.getByIdsWithAllRelationsButStacks(
      recents.items.map((item) => item.data),
      auth.user.id,
    );
    const recentItems = recentAssets.map((asset) => ({
      value: asset.createdAt.toISOString(),
      data: mapAsset(asset, { auth }),
    }));

    return [
      { fieldName: cities.fieldName, items: cityItems },
      { fieldName: recents.fieldName, items: recentItems },
    ];
  }

  async searchMetadata(auth: AuthDto, dto: MetadataSearchDto): Promise<SearchResponseDto> {
    if (isNewShapeRequest(dto)) {
      return this.searchMetadataV3(auth, dto);
    }

    if (dto.visibility === AssetVisibility.Locked) {
      requireElevatedPermission(auth);
    }

    let checksum: Buffer | undefined;
    if (dto.checksum) {
      const encoding = dto.checksum.length === 28 ? 'base64' : 'hex';
      checksum = Buffer.from(dto.checksum, encoding);
    }

    let userIds: string[] | undefined;

    if (dto.albumIds && dto.albumIds.length > 0) {
      await this.requireAccess({ auth, ids: dto.albumIds, permission: Permission.AlbumRead });
    } else if (auth.sharedLink) {
      throw new BadRequestException('Shared link access is only allowed in combination with an albumIds filter');
    } else {
      userIds = await this.getUserIdsToSearch(auth, dto.visibility);
    }

    const page = dto.page ?? 1;
    const size = dto.size;
    const { hasNextPage, items } = await this.searchRepository.searchMetadata(
      { page, size },
      {
        ...dto,
        checksum,
        visibility: dto.visibility ?? (auth.session?.hasElevatedPermission ? undefined : 'not-locked'),
        userIds,
        viewingUserId: auth.user.id,
        orderDirection: dto.order ?? AssetOrder.Desc,
      },
    );

    return this.mapResponse(items, { auth }, { nextPage: hasNextPage ? (page + 1).toString() : null });
  }

  async searchStatistics(auth: AuthDto, dto: StatisticsSearchDto): Promise<SearchStatisticsResponseDto> {
    if (isNewShapeRequest(dto)) {
      return this.searchStatisticsV3(auth, dto);
    }

    const userIds = await this.getUserIdsToSearch(auth, dto.visibility);
    if (dto.visibility === AssetVisibility.Locked) {
      requireElevatedPermission(auth);
    }

    return await this.searchRepository.searchStatistics({
      ...dto,
      visibility: dto.visibility ?? (auth.session?.hasElevatedPermission ? undefined : 'not-locked'),
      userIds,
      viewingUserId: auth.user.id,
    });
  }

  async searchRandom(auth: AuthDto, dto: RandomSearchDto): Promise<AssetResponseDto[]> {
    if (isNewShapeRequest(dto)) {
      return this.searchRandomV3(auth, dto);
    }

    if (dto.visibility === AssetVisibility.Locked) {
      requireElevatedPermission(auth);
    }

    const userIds = await this.getUserIdsToSearch(auth, dto.visibility);
    const items = await this.searchRepository.searchRandom(dto.size, {
      ...dto,
      visibility: dto.visibility ?? (auth.session?.hasElevatedPermission ? undefined : 'not-locked'),
      userIds,
      viewingUserId: auth.user.id,
    });
    return items.map((item) => mapAsset(item, { auth }));
  }

  async searchLargeAssets(auth: AuthDto, dto: LargeAssetSearchDto): Promise<AssetResponseDto[]> {
    if (dto.visibility === AssetVisibility.Locked) {
      requireElevatedPermission(auth);
    }

    const userIds = await this.getUserIdsToSearch(auth, dto.visibility);
    const items = await this.searchRepository.searchLargeAssets(dto.size, {
      ...dto,
      visibility: dto.visibility ?? (auth.session?.hasElevatedPermission ? undefined : 'not-locked'),
      userIds,
      viewingUserId: auth.user.id,
    });
    return items.map((item) => mapAsset(item, { auth }));
  }

  async searchSmart(auth: AuthDto, dto: SmartSearchDto, signal?: AbortSignal): Promise<SearchResponseDto> {
    if (
      dto.verify === undefined &&
      dto.query &&
      !auth.sharedLink &&
      this.configRepository.getEnv().searchVerification
    ) {
      dto = { ...dto, verify: true };
    }
    const plan = await this.planQuery(auth, dto);
    if (isNewShapeRequest(dto)) {
      return this.searchSmartV3(auth, dto, plan, signal);
    }

    if (dto.visibility === AssetVisibility.Locked) {
      requireElevatedPermission(auth);
    }

    const { machineLearning } = await this.getConfig({ withCache: false });
    if (!isSmartSearchEnabled(machineLearning)) {
      throw new BadRequestException('Smart search is not enabled');
    }

    const userIds = this.getUserIdsToSearch(auth, dto.visibility);
    const page = dto.page ?? 1;
    const size = dto.verify && plan.query ? Math.min(dto.size, verificationPageSize) : dto.size;
    const resolvedUserIds = await userIds;
    if (plan.filter && !plan.query) {
      const { hasNextPage, items } = await this.searchRepository.searchMetadata(
        { page, size },
        {
          ...dto,
          queryFilter: plan.filter,
          userIds: resolvedUserIds,
          viewingUserId: auth.user.id,
          visibility: dto.visibility ?? (auth.session?.hasElevatedPermission ? undefined : 'not-locked'),
        },
      );
      return this.mapSmartResponse(
        auth,
        dto,
        plan,
        { items, page: { nextPage: hasNextPage ? (page + 1).toString() : null } },
        signal,
      );
    }
    const embedding = await this.resolveEmbedding(auth, { ...dto, query: plan.query }, machineLearning);
    const loadPage = async (page: number): Promise<SearchCandidatePage> => {
      const { hasNextPage, items } = await this.searchRepository.searchSmart(
        { page, size },
        {
          ...dto,
          queryFilter: plan.filter,
          userIds: resolvedUserIds,
          viewingUserId: auth.user.id,
          embedding,
          visibility: dto.visibility ?? (auth.session?.hasElevatedPermission ? undefined : 'not-locked'),
        },
      );
      return { items, page: { nextPage: hasNextPage ? (page + 1).toString() : null } };
    };

    return this.mapSmartResponse(auth, dto, plan, await loadPage(page), signal, (page) =>
      loadPage(Number(page.nextPage)),
    );
  }

  async getAssetsByCity(auth: AuthDto): Promise<AssetResponseDto[]> {
    const userIds = await this.getUserIdsToSearch(auth);
    const assets = await this.searchRepository.getAssetsByCity(userIds);
    return assets.map((asset) => mapAsset(asset));
  }

  async getSearchSuggestions(auth: AuthDto, dto: SearchSuggestionRequestDto) {
    const userIds = await this.getUserIdsToSearch(auth);
    const suggestions = await this.getSuggestions(userIds, dto);
    if (dto.includeNull) {
      suggestions.push(null);
    }
    return suggestions;
  }

  private getSuggestions(userIds: string[], dto: SearchSuggestionRequestDto): Promise<Array<string | null>> {
    switch (dto.type) {
      case SearchSuggestionType.COUNTRY: {
        return this.searchRepository.getCountries(userIds);
      }
      case SearchSuggestionType.STATE: {
        return this.searchRepository.getStates(userIds, dto);
      }
      case SearchSuggestionType.CITY: {
        return this.searchRepository.getCities(userIds, dto);
      }
      case SearchSuggestionType.CAMERA_MAKE: {
        return this.searchRepository.getCameraMakes(userIds, dto);
      }
      case SearchSuggestionType.CAMERA_MODEL: {
        return this.searchRepository.getCameraModels(userIds, dto);
      }
      case SearchSuggestionType.CAMERA_LENS_MODEL: {
        return this.searchRepository.getCameraLensModels(userIds, dto);
      }
      default: {
        return Promise.resolve([]);
      }
    }
  }

  private async searchMetadataV3(auth: AuthDto, dto: MetadataSearchDto): Promise<SearchResponseDto> {
    const { filter, scope } = await this.resolveSearchScopeV3(auth, dto);

    const { offset } = decodeSearchCursor(dto.cursor);
    const size = dto.size;
    const { hasNextPage, items } = await this.searchRepository.searchMetadataV3(
      { take: size, skip: offset },
      {
        filter,
        withExif: dto.withExif,
        withPeople: dto.withPeople,
        withStacked: dto.withStacked,
        order: dto.orderBy,
      },
      scope,
    );

    return this.mapResponse(items, { auth }, { nextCursor: hasNextPage ? encodeSearchCursor(offset + size) : null });
  }

  private async searchStatisticsV3(auth: AuthDto, dto: StatisticsSearchDto): Promise<SearchStatisticsResponseDto> {
    const { filter, scope } = await this.resolveSearchScopeV3(auth, dto);
    return this.searchRepository.searchStatisticsV3({ filter }, scope);
  }

  private async searchRandomV3(auth: AuthDto, dto: RandomSearchDto): Promise<AssetResponseDto[]> {
    const { filter, scope } = await this.resolveSearchScopeV3(auth, dto);
    const items = await this.searchRepository.searchRandomV3(
      dto.size,
      {
        filter,
        withExif: dto.withExif,
        withPeople: dto.withPeople,
        withStacked: dto.withStacked,
      },
      scope,
    );
    return items.map((item) => mapAsset(item, { auth }));
  }

  private async searchSmartV3(
    auth: AuthDto,
    dto: SmartSearchDto,
    plan: NaturalSearchPlan,
    signal?: AbortSignal,
  ): Promise<SearchResponseDto> {
    const { machineLearning } = await this.getConfig({ withCache: false });
    if (!isSmartSearchEnabled(machineLearning)) {
      throw new BadRequestException('Smart search is not enabled');
    }

    const { filter, scope } = await this.resolveSearchScopeV3(auth, dto);
    const { offset } = decodeSearchCursor(dto.cursor);
    const size = dto.verify && plan.query ? Math.min(dto.size, verificationPageSize) : dto.size;
    if (plan.filter && !plan.query) {
      const { items, hasNextPage } = await this.searchRepository.searchMetadataV3(
        { take: size, skip: offset },
        {
          filter,
          queryFilter: plan.filter,
          withExif: dto.withExif,
        },
        scope,
      );
      return this.mapSmartResponse(
        auth,
        dto,
        plan,
        {
          items,
          page: { nextCursor: hasNextPage ? encodeSearchCursor(offset + size) : null },
        },
        signal,
      );
    }
    const embedding = await this.resolveEmbedding(auth, { ...dto, query: plan.query }, machineLearning);

    const loadPage = async (offset: number): Promise<SearchCandidatePage> => {
      const { items, hasNextPage } = await this.searchRepository.searchSmartV3(
        { take: size, skip: offset },
        { filter, queryFilter: plan.filter, withExif: dto.withExif, embedding },
        scope,
      );
      return { items, page: { nextCursor: hasNextPage ? encodeSearchCursor(offset + size) : null } };
    };

    return this.mapSmartResponse(auth, dto, plan, await loadPage(offset), signal, (page) =>
      loadPage(decodeSearchCursor(page.nextCursor ?? undefined).offset),
    );
  }

  private async mapSmartResponse(
    auth: AuthDto,
    dto: SmartSearchDto,
    plan: NaturalSearchPlan,
    batch: SearchCandidatePage,
    signal?: AbortSignal,
    loadNext?: (page: SearchPagination) => Promise<SearchCandidatePage>,
  ): Promise<SearchResponseDto> {
    const response = this.mapResponse(batch.items, { auth }, batch.page);
    if (!dto.verify) return response;
    if (!dto.query || !plan.query) {
      response.verification = { status: 'not-needed', checked: 0, rejected: 0 };
      return response;
    }
    if (batch.items.length === 0) {
      response.verification = { status: 'complete', checked: 0, rejected: 0 };
      return response;
    }
    const options = this.configRepository.getEnv().searchVerification;
    if (!options || auth.sharedLink || this.verifying) {
      response.verification = { status: 'unavailable', checked: 0, rejected: 0 };
      return response;
    }
    this.verifying = true;
    try {
      const timeout = AbortSignal.timeout(60_000);
      const verificationSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
      let checked = 0;
      for (let pageIndex = 0; ; pageIndex++) {
        const accepted: MapAsset[] = [];
        for (const item of batch.items) {
          verificationSignal.throwIfAborted();
          // Each batch passed all ownership, album, and visibility checks.
          const asset = await this.assetJobRepository.getForClipEncoding(item.id);
          const preview = asset?.files.find((file) => file.isEdited) ?? asset?.files[0];
          if (!preview) throw new Error('Search candidate has no preview');
          if (
            await this.machineLearningRepository.verifySearchCandidate(preview.path, plan.query, {
              ...options,
              signal: verificationSignal,
            })
          )
            accepted.push(item);
          checked++;
        }
        const more = batch.page.nextPage || batch.page.nextCursor;
        if (accepted.length > 0 || !more || !loadNext || pageIndex + 1 >= verificationScanPages) {
          return {
            ...this.mapResponse(accepted, { auth }, batch.page),
            verification: { status: 'complete', checked, rejected: checked - accepted.length },
          };
        }
        // Older phone clients cannot advance an empty results grid themselves.
        verificationSignal.throwIfAborted();
        batch = await loadNext(batch.page);
      }
    } catch {
      if (!signal?.aborted)
        this.logger.warn('Visual search verification unavailable; returning regular search results.');
      response.verification = { status: 'unavailable', checked: 0, rejected: 0 };
      return response;
    } finally {
      this.verifying = false;
    }
  }

  private async planQuery(auth: AuthDto, dto: SmartSearchDto): Promise<NaturalSearchPlan> {
    if (!dto.query || auth.sharedLink) return { query: dto.query ?? '' };
    const userIds = await this.getUserIdsToSearch(auth, dto.visibility);
    const [people, cities, countries] = await Promise.all([
      this.personRepository.getNames(auth.user.id, { withHidden: false }),
      this.searchRepository.getCities(userIds, {}),
      this.searchRepository.getCountries(userIds),
    ]);
    return planNaturalSearch(dto.query, { people, cities, countries, userName: auth.user.name });
  }

  private async resolveSearchScopeV3(
    auth: AuthDto,
    dto: { filter?: SearchFilter },
  ): Promise<{ filter: SearchFilter; scope: AssetSearchScope }> {
    const filter = dto.filter ?? {};
    const effectiveFilter = applyLockedVisibilityPolicy(auth, filter);

    const fullyConfined = isFullyAlbumConfined(filter);
    // a shared link visitor does not have a universe, so there every branch must be confined
    if (auth.sharedLink && !fullyConfined) {
      throw new BadRequestException('Shared link access is only allowed in combination with an albumIds filter');
    }

    const albumIds = collectFilterIds(filter, 'albumIds');
    const [userIds] = await Promise.all([
      // a fully confined filter searches albums only, so the unused universe can skip the partner lookup
      fullyConfined ? [auth.user.id] : this.getUserIdsToSearch(auth),
      albumIds.length > 0 ? this.requireAccess({ auth, ids: albumIds, permission: Permission.AlbumRead }) : undefined,
    ]);

    return { filter: effectiveFilter, scope: { userIds, lockedOwnerId: auth.user.id, viewingUserId: auth.user.id } };
  }

  private async resolveEmbedding(
    auth: AuthDto,
    dto: SmartSearchDto,
    machineLearning: SystemConfig['machineLearning'],
  ): Promise<string> {
    if (dto.query) {
      const key = machineLearning.clip.modelName + dto.query + dto.language;
      let embedding = this.embeddingCache.get(key);
      if (!embedding) {
        embedding = await this.machineLearningRepository.encodeText(dto.query, {
          modelName: machineLearning.clip.modelName,
          language: dto.language,
        });
        this.embeddingCache.set(key, embedding);
      }
      return embedding;
    }

    if (dto.queryAssetId) {
      await this.requireAccess({ auth, permission: Permission.AssetRead, ids: [dto.queryAssetId] });
      const getEmbeddingResponse = await this.searchRepository.getEmbedding(dto.queryAssetId);
      const assetEmbedding = getEmbeddingResponse?.embedding;
      if (!assetEmbedding) {
        throw new BadRequestException(`Asset ${dto.queryAssetId} has no embedding`);
      }
      return assetEmbedding;
    }

    throw new BadRequestException('Either `query` or `queryAssetId` must be set');
  }

  private async getUserIdsToSearch(auth: AuthDto, visibility?: AssetVisibility): Promise<string[]> {
    // Locked assets are personal. Never include partner IDs, regardless of A's elevated session.
    if (visibility === AssetVisibility.Locked) {
      return [auth.user.id];
    }
    const partnerIds = await getMyPartnerIds({
      userId: auth.user.id,
      repository: this.partnerRepository,
      timelineEnabled: true,
    });
    return [auth.user.id, ...partnerIds];
  }

  private mapResponse(
    assets: MapAsset[],
    options: AssetMapOptions,
    page: { nextPage?: string | null; nextCursor?: string | null } = {},
  ): SearchResponseDto {
    return {
      albums: { total: 0, count: 0, items: [], facets: [] },
      assets: {
        total: assets.length,
        count: assets.length,
        items: assets.map((asset) => mapAsset(asset, options)),
        facets: [],
        nextPage: page.nextPage ?? null,
        nextCursor: page.nextCursor ?? null,
      },
    };
  }
}
