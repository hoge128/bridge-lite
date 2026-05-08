import { withMermaid } from 'vitepress-plugin-mermaid'
import fs from 'fs'
import path from 'path'

const serveDocsRoot = {
  name: 'serve-docs-root',
  configureServer(server: any) {
    const docsDir = path.resolve(__dirname, '../../docs')
    server.middlewares.use((req: any, res: any, next: any) => {
      const url: string = req.url ?? '/'
      if (url === '/bridge-lite/' || url === '/bridge-lite') {
        res.setHeader('Content-Type', 'text/html; charset=utf-8')
        res.end(fs.readFileSync(path.join(docsDir, 'index.html'), 'utf-8'))
        return
      }
      if (url.startsWith('/bridge-lite/src/')) {
        const filePath = path.join(docsDir, url.slice('/bridge-lite/'.length))
        if (fs.existsSync(filePath)) {
          const mime: Record<string, string> = { '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml' }
          res.setHeader('Content-Type', mime[path.extname(filePath)] ?? 'application/octet-stream')
          res.end(fs.readFileSync(filePath))
          return
        }
      }
      next()
    })
  },
}

export default withMermaid({
  title: 'bridge-lite',
  outDir: '../docs/manual',
  base: '/bridge-lite/manual/',

  vite: {
    plugins: [serveDocsRoot],
  },

  locales: {
    ja: {
      label: '日本語',
      lang: 'ja',
      link: '/ja/',
      title: 'bridge-lite マニュアル',
      description: 'bridge-lite の使い方ガイド',
      themeConfig: {
        nav: [
          { text: 'トップページ', link: '/bridge-lite/', target: '_self' },
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
              { text: 'UI 遷移', link: '/ja/ui-navigation' },
              { text: 'フォルダを開く', link: '/ja/open-folder' },
              { text: '閲覧する', link: '/ja/thumbnail-grid' },
              { text: '比較する', link: '/ja/compare' },
              { text: '詳しく見る', link: '/ja/viewer' },
              { text: '評価する', link: '/ja/rating' },
            ],
          },
          {
            text: '個別仕様',
            items: [
              { text: 'ラベリング', link: '/ja/labeling' },
              { text: 'フィルター', link: '/ja/filter-spec' },
              { text: '評価の伝搬', link: '/ja/rating-spec' },
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
          { text: 'Top page', link: '/bridge-lite/', target: '_self' },
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
              { text: 'UI navigation', link: '/en/ui-navigation' },
              { text: 'Open a folder', link: '/en/open-folder' },
              { text: 'Browse', link: '/en/thumbnail-grid' },
              { text: 'Compare', link: '/en/compare' },
              { text: 'Inspect', link: '/en/viewer' },
              { text: 'Rate', link: '/en/rating' },
            ],
          },
          {
            text: 'Specifications',
            items: [
              { text: 'Labeling', link: '/en/labeling' },
              { text: 'Filters', link: '/en/filter-spec' },
              { text: 'Rating propagation', link: '/en/rating-spec' },
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
