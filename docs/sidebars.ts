import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

// Manuel sidebar — sayfa sırası ve gruplama burada açıkça tanımlı.
const sidebars: SidebarsConfig = {
  tutorialSidebar: [
    'intro',
    'kurulum',
    'menu-cubugu',
    {
      type: 'category',
      label: 'Servisler',
      collapsed: false,
      items: [
        'servisler/claude',
        'servisler/codex',
        'servisler/antigravity',
      ],
    },
    'gizlilik',
    'sorun-giderme',
    'katkida-bulunma',
  ],
};

export default sidebars;
