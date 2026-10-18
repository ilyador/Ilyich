<p align="center">
  <img src="design/immich-logo.svg" width="120" alt="Ilyich icon">
</p>

# Ilyich

Ilyich is a personal fork of [Immich](https://github.com/immich-app/immich), a self-hosted photo and video library. It keeps the upstream foundation and combines custom work for the web app and mobile app.

## Development branches

- **[`dev`](https://github.com/ilyador/Ilyich/tree/dev)** is the integrated version for the computer and phone. It combines Lightcraft rendering from originals and XMP sidecars with a preview cache, natural-language search and result verification, the existing OCR functionality, and Ilyich branding.
- **[`main`](https://github.com/ilyador/Ilyich/tree/main)** is an exact mirror of the selected official upstream release, currently [`v3.3.3`](https://github.com/immich-app/immich/releases/tag/v3.3.3). It contains no fork changes and advances only to an official release tag, never to the upstream development branch or a moving release-branch tip.
- **Feature branches** preserve focused work before it is integrated into `dev`.

Use `dev` when building or running Ilyich. Technical package names, API identifiers, storage paths and mobile bundle IDs retain their upstream names for compatibility.

## Custom features

- **Lightcraft previews:** render supported Lightroom adjustments from the original image and its XMP sidecar, then cache the generated preview. See the [XMP sidecar notes](docs/docs/features/xmp-sidecars.md).
- **Natural-language search:** describe what you are looking for and use the integrated verification stage to check candidate results.
- **OCR:** retain the existing text recognition and search support alongside the custom search workflow.

## Project links

- [Source and branches](https://github.com/ilyador/Ilyich)
- [Issues](https://github.com/ilyador/Ilyich/issues)
- [Web development](web/README.md)
- [Mobile source](mobile)
- [Upstream installation and administration documentation](https://docs.immich.app/)

The upstream documentation describes the shared foundation. Custom behavior is maintained in this fork. Keep a separate backup of your photos and videos.

## Translated overviews

The translated overviews describe the upstream base. This README is the reference for Ilyich features and branch policy.

<p align="center">
  <a href="readme_i18n/README_ca_ES.md">Català</a>
  <a href="readme_i18n/README_es_ES.md">Español</a>
  <a href="readme_i18n/README_fr_FR.md">Français</a>
  <a href="readme_i18n/README_it_IT.md">Italiano</a>
  <a href="readme_i18n/README_ja_JP.md">日本語</a>
  <a href="readme_i18n/README_ko_KR.md">한국어</a>
  <a href="readme_i18n/README_de_DE.md">Deutsch</a>
  <a href="readme_i18n/README_nl_NL.md">Nederlands</a>
  <a href="readme_i18n/README_tr_TR.md">Türkçe</a>
  <a href="readme_i18n/README_zh_CN.md">简体中文</a>
  <a href="readme_i18n/README_zh_TW.md">正體中文</a>
  <a href="readme_i18n/README_uk_UA.md">Українська</a>
  <a href="readme_i18n/README_ru_RU.md">Русский</a>
  <a href="readme_i18n/README_bg_BG.md">Български</a>
  <a href="readme_i18n/README_pt_BR.md">Português Brasileiro</a>
  <a href="readme_i18n/README_sv_SE.md">Svenska</a>
  <a href="readme_i18n/README_ar_JO.md">العربية</a>
  <a href="readme_i18n/README_vi_VN.md">Tiếng Việt</a>
  <a href="readme_i18n/README_th_TH.md">ภาษาไทย</a>
  <a href="readme_i18n/README_ml_IN.md">മലയാളം</a>
</p>

## License and attribution

Ilyich builds on the work of the [Immich contributors](https://github.com/immich-app/immich/graphs/contributors) and uses [Lightcraft](https://github.com/storytold/lightcraft) for supported XMP adjustments. Original copyright and attribution notices are retained. The application is available under the [GNU AGPL v3 license](LICENSE).
