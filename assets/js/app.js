// Source Phoenix client entrypoint for Mishka Chelekom generators.
// EventSales serves the committed counterpart from priv/static/assets/js/app.js.
import MishkaComponents from "../vendor/mishka_components.js";

const { Socket } = window.Phoenix;
const { LiveSocket } = window.LiveView;

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

liveSocket.connect();
window.liveSocket = liveSocket;
