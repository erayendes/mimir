import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
  title: 'Mimir',
  tagline: 'Claude Code, Codex ve Antigravity için menü çubuğu kota takibi',
  favicon: 'img/favicon.png',

  // Future flags, see https://docusaurus.io/docs/api/docusaurus-config#future
  future: {
    v4: true, // Improve compatibility with the upcoming Docusaurus v4
  },

  // Set the production url of your site here.
  // On Vercel the site is served at the domain root, so baseUrl stays '/'.
  url: 'https://mimir.vercel.app',
  baseUrl: '/',

  organizationName: 'erayendes', // GitHub org/user name.
  projectName: 'mimir', // Repo name.

  onBrokenLinks: 'throw',

  i18n: {
    defaultLocale: 'tr',
    locales: ['tr'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          editUrl:
            'https://github.com/erayendes/mimir/tree/main/docs/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/mimir-logo.png',
    colorMode: {
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'Mimir',
      logo: {
        alt: 'Mimir Logo',
        src: 'img/mimir-logo.png',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'tutorialSidebar',
          position: 'left',
          label: 'Dokümanlar',
        },
        {
          href: 'https://github.com/erayendes/mimir/releases',
          label: 'İndir',
          position: 'right',
        },
        {
          href: 'https://github.com/erayendes/mimir',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Dokümanlar',
          items: [
            {
              label: 'Mimir nedir?',
              to: '/docs/intro',
            },
            {
              label: 'Kurulum',
              to: '/docs/kurulum',
            },
            {
              label: 'Sorun Giderme',
              to: '/docs/sorun-giderme',
            },
          ],
        },
        {
          title: 'Proje',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/erayendes/mimir',
            },
            {
              label: 'İndir (Releases)',
              href: 'https://github.com/erayendes/mimir/releases',
            },
            {
              label: 'Sürüm Notları',
              href: 'https://github.com/erayendes/mimir/blob/main/CHANGELOG.md',
            },
          ],
        },
        {
          title: 'Daha Fazla',
          items: [
            {
              label: 'Issue / Yol Haritası',
              href: 'https://github.com/erayendes/mimir/issues',
            },
            {
              label: 'milowda',
              href: 'https://milowda.com/apps/mimir',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Mimir. Docusaurus ile yapıldı.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
