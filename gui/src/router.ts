import { createRouter, createWebHashHistory } from "vue-router";
import DevicesView from "./views/DevicesView.vue";
import ActivityView from "./views/ActivityView.vue";
import SettingsView from "./views/SettingsView.vue";

export default createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", redirect: "/devices" },
    { path: "/devices", name: "devices", component: DevicesView },
    { path: "/activity", name: "activity", component: ActivityView },
    { path: "/settings", name: "settings", component: SettingsView },
    { path: "/:pathMatch(.*)*", redirect: "/devices" },
  ],
});
