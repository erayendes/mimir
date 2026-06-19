import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
  title: 'Mimir',
  tagline: 'Claude Code, Codex ve Antigravity için menü çubuğu kota takibi',
  favicon: 'img/favicon.ico',

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

  // Even if you don't use internationalization, you can use this field to set
  // useful metadata like html lang. For example, if your site is Chinese, you
  // may want to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
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
        blog: {
          showReadingTime: true,
          feedOptions: {
            type: ['rss', 'atom'],
            xslt: true,
          },
          editUrl:
            'https://github.com/erayendes/mimir/tree/main/docs/',
          // Useful options to enforce blogging best practices
          onInlineTags: 'warn',
          onInlineAuthors: 'warn',
          onUntruncatedBlogPosts: 'warn',
        },
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    // Replace with your project's social card
    image: 'img/docusaurus-social-card.jpg',
    colorMode: {
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'Mimir',
      logo: {
        alt: 'Mimir Logo',
        src: 'img/logo.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'tutorialSidebar',
          position: 'left',
          label: 'Dokümanlar',
        },
        {to: '/blog', label: 'Blog', position: 'left'},
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
              label: 'Başlangıç',
              to: '/docs/intro',
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
              label: 'Sürüm Notları',
              href: 'https://github.com/erayendes/mimir/blob/main/CHANGELOG.md',
            },
          ],
        },
        {
          title: 'Daha Fazla',
          items: [
            {
              label: 'Blog',
              to: '/blog',
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
