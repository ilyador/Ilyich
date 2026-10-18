// @ts-check
// Note: type annotations allow type checking and IDEs autocompletion

const prism = require('prism-react-renderer');

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Ilyich',
  tagline: 'Self-hosted photo and video management solution',
  url: 'https://docs.immich.app',
  baseUrl: '/',
  onBrokenLinks: 'throw',
  favicon: 'img/favicon.png',

  // GitHub pages deployment config.
  // If you aren't using GitHub pages, you don't need these.
  organizationName: 'ilyador', // Usually your GitHub org/user name.
  projectName: 'Ilyich', // Usually your repo name.
  deploymentBranch: 'gh-pages',
  // Even if you don't use internalization, you can use this field to set useful
  // metadata like html lang. For example, if your site is Chinese, you may want
  // to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  // Mermaid diagrams
  markdown: {
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },
  themes: ['@docusaurus/theme-mermaid'],

  plugins: [
    async function myPlugin(context, options) {
      return {
        name: 'docusaurus-tailwindcss',
        configurePostCss(postcssOptions) {
          // Appends TailwindCSS and AutoPrefixer.
          postcssOptions.plugins.push(require('tailwindcss'));
          postcssOptions.plugins.push(require('autoprefixer'));
          return postcssOptions;
        },
      };
    },
    require.resolve('docusaurus-lunr-search'),
  ],
  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          showLastUpdateAuthor: true,
          showLastUpdateTime: true,
          routeBasePath: '/',

          sidebarPath: require.resolve('./sidebars.js'),
          // Please change this to your repo.
          // Remove this to remove the "edit this page" links.
          editUrl: 'https://github.com/ilyador/Ilyich/tree/dev/docs/',
        },
        theme: {
          customCss: require.resolve('./src/css/custom.css'),
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      docs: {
        sidebar: {
          autoCollapseCategories: false,
        },
      },
      tableOfContents: {
        minHeadingLevel: 2,
        maxHeadingLevel: 4,
      },
      navbar: {
        title: 'Ilyich',
        logo: {
          alt: 'Ilyich icon',
          src: 'img/ilyich-logo.png',
          className: 'rounded-none',
        },
        items: [
          {
            type: 'custom-versionSwitcher',
            position: 'right',
          },
          {
            href: 'https://github.com/ilyador/Ilyich',
            position: 'right',
            label: 'Project',
          },
          {
            href: 'https://github.com/ilyador/Ilyich',
            label: 'GitHub',
            position: 'right',
          },
          {
            type: 'html',
            position: 'right',
            value:
              '<a href="https://buy.immich.app" target="_blank" class="no-underline hover:no-underline"><button class="buy-button bg-immich-primary dark:bg-immich-dark-primary text-white dark:text-black rounded-xl">Support upstream</button></a>',
          },
        ],
      },
      footer: {
        style: 'light',
        links: [
          {
            title: 'Upstream downloads',
            items: [
              {
                label: 'Android',
                href: 'https://get.immich.app/android',
              },
              {
                label: 'iOS',
                href: 'https://get.immich.app/ios',
              },
              {
                label: 'Server',
                href: 'https://immich.app/download',
              },
            ],
          },
          {
            title: 'Upstream support',
            items: [
              {
                label: 'FUTO',
                href: 'https://futo.tech/',
              },
              {
                label: 'Purchase',
                href: 'https://buy.immich.app/',
              },
              {
                label: 'Merch',
                href: 'https://immich.store/',
              },
            ],
          },
          {
            title: 'Upstream resources',
            items: [
              {
                label: 'Home',
                href: 'https://immich.app',
              },
              {
                label: 'Server link helper',
                href: 'https://my.immich.app/',
              },
              {
                label: 'Community projects',
                href: 'https://awesome.immich.app/',
              },
              {
                label: 'API',
                href: 'https://api.immich.app/',
              },
              {
                label: 'Data',
                href: 'https://data.immich.app/',
              },
              {
                label: 'Datasets',
                href: 'https://datasets.immich.app/',
              },
            ],
          },
          {
            title: 'Upstream information',
            items: [
              {
                label: 'Roadmap',
                href: 'https://immich.app/roadmap',
              },
              {
                label: 'Cursed Knowledge',
                href: 'https://immich.app/cursed-knowledge',
              },
              {
                label: 'Privacy Policy',
                href: 'https://immich.app/privacy-policy',
              },
            ],
          },
          {
            title: 'Social',
            items: [
              {
                label: 'GitHub',
                href: 'https://github.com/ilyador/Ilyich',
              },
              {
                label: 'Upstream YouTube',
                href: 'https://www.youtube.com/@immich-app',
              },
              {
                label: 'Upstream Discord',
                href: 'https://discord.immich.app',
              },
              {
                label: 'Upstream Reddit',
                href: 'https://www.reddit.com/r/immich/',
              },
            ],
          },
        ],
        copyright: `Ilyich is a fork of Immich, available as open source under the terms of the GNU AGPL v3 License. Original copyright and attribution notices are retained.`,
      },
      prism: {
        theme: prism.themes.github,
        darkTheme: prism.themes.dracula,
        additionalLanguages: ['sql', 'diff', 'bash', 'powershell', 'nginx'],
      },
      image: 'img/favicon.png',
    }),
};

module.exports = config;
