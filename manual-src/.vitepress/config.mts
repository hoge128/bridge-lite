import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'bridge-lite',
  outDir: '../docs/manual',
  base: '/bridge-lite/manual/',

  locales: {
    ja: {
      label: '日本語',
      lang: 'ja',
      link: '/ja/',
      title: 'bridge-lite マニュアル',
      description: 'bridge-lite の使い方ガイド',
      themeConfig: {
        nav: [
          { text: 'トップページ', link: '/bridge-lite/' },
        ],
        sidebar: [
          {
            text: 'はじめに',
            items: [
              { text: 'bridge-lite とは', link: '/ja/introduction' },
              { text: 'インストール', link: '/ja/installation' },
            ],
          },
          {
            text: '基本的な使い方',
            items: [
              { text: 'フォルダを開く', link: '/ja/open-folder' },
              { text: 'サムネイルグリッド', link: '/ja/thumbnail-grid' },
              { text: '写真を評価する', link: '/ja/rating' },
              { text: '三種の比較', link: '/ja/compare' },
              { text: 'フルレズビューア', link: '/ja/viewer' },
            ],
          },
          {
            text: '活用',
            items: [
              { text: 'フィルタリング', link: '/ja/filter' },
              { text: 'キーボードショートカット', link: '/ja/shortcuts' },
            ],
          },
        ],
        docFooter: { prev: '前のページ', next: '次のページ' },
        outlineTitle: 'このページの内容',
        returnToTopLabel: 'トップに戻る',
        sidebarMenuLabel: 'メニュー',
        darkModeSwitchLabel: 'テーマ',
      },
    },
    en: {
      label: 'English',
      lang: 'en',
      link: '/en/',
      title: 'bridge-lite Manual',
      description: 'User guide for bridge-lite',
      themeConfig: {
        nav: [
          { text: 'Top page', link: '/bridge-lite/' },
        ],
        sidebar: [
          {
            text: 'Getting started',
            items: [
              { text: 'What is bridge-lite', link: '/en/introduction' },
              { text: 'Installation', link: '/en/installation' },
            ],
          },
          {
            text: 'Basic usage',
            items: [
              { text: 'Open a folder', link: '/en/open-folder' },
              { text: 'Thumbnail grid', link: '/en/thumbnail-grid' },
              { text: 'Rating photos', link: '/en/rating' },
              { text: 'Compare three types', link: '/en/compare' },
              { text: 'Full-res viewer', link: '/en/viewer' },
            ],
          },
          {
            text: 'Advanced',
            items: [
              { text: 'Filtering', link: '/en/filter' },
              { text: 'Keyboard shortcuts', link: '/en/shortcuts' },
            ],
          },
        ],
      },
    },
  },

  themeConfig: {
    logo: null,
    socialLinks: [
      { icon: 'github', link: 'https://github.com/hoge128/bridge-lite' },
    ],
    search: { provider: 'local' },
  },
})
