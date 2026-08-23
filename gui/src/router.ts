import { createRouter, createWebHashHistory } from "vue-router";
import KeysView from "./views/KeysView.vue";
import SessionsView from "./views/SessionsView.vue";
import SettingsView from "./views/SettingsView.vue";
import LogsView from "./views/LogsView.vue";

export default createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", redirect: "/sessions" },
    { path: "/keys", name: "keys", component: KeysView },
    { path: "/sessions", name: "sessions", component: SessionsView },
    { path: "/settings", name: "settings", component: SettingsView },
    { path: "/logs", name: "logs", component: LogsView },
  ],
});
