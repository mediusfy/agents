import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router';

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'home',
    component: () => import('../views/HomeView.vue'),
  },
  {
    path: '/entities',
    name: 'entities',
    component: () => import('../views/EntitiesView.vue'),
  },
  {
    path: '/agents',
    name: 'agents',
    component: () => import('../views/AgentsView.vue'),
  },
  {
    path: '/workloads',
    name: 'workloads',
    component: () => import('../views/WorkloadsView.vue'),
  },
  {
    path: '/monitoring',
    name: 'monitoring',
    component: () => import('../views/MonitoringView.vue'),
  },
  {
    path: '/automations',
    name: 'automations',
    component: () => import('../views/AutomationsView.vue'),
  },
  {
    path: '/logs',
    name: 'logs',
    component: () => import('../views/LogsView.vue'),
  },
  {
    path: '/notes',
    name: 'notes',
    component: () => import('../views/NotesView.vue'),
  },
  {
    path: '/events',
    name: 'events',
    component: () => import('../views/EventConsumptionView.vue'),
  },
  {
    path: '/workloads/:resourceType',
    name: 'workloads-resource',
    component: () => import('../views/WorkloadsView.vue'),
  },
];

const router = createRouter({
  history: createWebHistory(),
  routes,
});

export default router;
