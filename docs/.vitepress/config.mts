import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "MsgTier",
  description: "A decentralized, secure, RPC-enabled P2P network solution",
  cleanUrls: true,
  sitemap: { hostname: 'https://msgtier.oboard.fun' },
  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/get-started' },
      { text: 'Download', link: '/download' },
      { text: 'API', link: '/api-examples' },
      { text: 'GitHub', link: 'https://github.com/oboard/msgtier' }
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Download', link: '/download' },
          { text: 'Get Started', link: '/get-started' },
          { text: 'Architecture', link: '/architecture' },
          { text: 'Port Forwarding', link: '/port-forwarding' }
        ]
      },
      {
        text: 'Reference',
        items: [
          { text: 'API Examples', link: '/api-examples' }
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/oboard/msgtier' }
    ]
  }
})
