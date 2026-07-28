export default {
  index: {
    title: 'Home',
    type: 'page',
    display: 'hidden'
  },

  Projects: {
    title: 'Projects',
    type: 'page'
  },

  STUCO_site: {
    title: 'Student Council Docs',
    type: 'menu',
    items: {
      frontend: {
        title: 'Frontend',
        href: '/STUCO_site/frontend'
      },
      
      backend: {
        title: "Backend",
        href: "/STUCO_site/backend",
      }
    }
  },
}