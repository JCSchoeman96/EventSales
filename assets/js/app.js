// Stub Phoenix client entrypoint for Mishka Chelekom generators.
//
// EventSales currently ships precompiled JS under priv/static/assets/.
// This file exists so generators that patch `assets/js/app.js` can run.
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import MishkaComponents from "../vendor/mishka_components.js";
let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {
    _csrf_token: csrfToken,
  },
  hooks: {
    ...MishkaComponents,
  },
});
topbar.config({
  barColors: {
    0: "#29d",
  },
  shadowColor: "rgba(0, 0, 0, .3)",
});
window.addEventListener("phx:page-loading-start", () => topbar.show(300));
window.addEventListener("phx:page-loading-stop", () => topbar.hide());
liveSocket.connect();
window.liveSocket = liveSocket;
