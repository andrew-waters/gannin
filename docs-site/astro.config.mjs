// The user docs at gannin.ai/docs. pages.yml builds this and puts the output
// under _site/docs, beside the landing page in site/, so both deploy as one.
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://gannin.ai',
  base: '/docs',
  integrations: [
    starlight({
      title: 'Gannin',
      description: 'How to use, set up and configure Gannin.',
      customCss: ['./src/styles/gannin.css'],
      head: [
        { tag: 'link', attrs: { rel: 'preconnect', href: 'https://fonts.googleapis.com' } },
        {
          tag: 'link',
          attrs: {
            rel: 'stylesheet',
            href: 'https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=Geist+Mono:wght@400;500&display=swap',
          },
        },
      ],
      social: [
        { icon: 'external', label: 'gannin.ai', href: 'https://gannin.ai' },
        { icon: 'github', label: 'GitHub', href: 'https://github.com/andrew-waters/gannin' },
      ],
      sidebar: [
        { label: 'Get started', items: [{ autogenerate: { directory: 'get-started' } }] },
        { label: 'Concepts', items: [{ autogenerate: { directory: 'concepts' } }] },
        { label: 'Ways to run sessions', items: [{ autogenerate: { directory: 'sessions' } }] },
        {
          label: 'Settings reference',
          items: [
            { label: 'Overview', slug: 'settings' },
            { label: 'App', items: [{ autogenerate: { directory: 'settings/app' } }] },
            { label: 'Org', items: [{ autogenerate: { directory: 'settings/org' } }] },
          ],
        },
        { label: 'Keyboard shortcuts', slug: 'keyboard-shortcuts' },
      ],
    }),
  ],
});
