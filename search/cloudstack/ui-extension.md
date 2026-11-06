# CloudStack: adding a page to the UI

[← Back to CloudStack](README.md)

Read on 2026-11-06 (docs `latest`, source of `main`). Version of each feature **not confirmed** (the only version tag seen on the UI page is "Since 4.21" for an unrelated key). No instance run.

## Options

| Option | What it is | Build needed | Fit |
| --- | --- | --- | --- |
| **`plugins` in `config.json`** | The admin guide: the UI "provides option to show custom plugins for displaying custom HTML pages or HTTP services in an iframe". Each entry is `{ "name", "icon", "path" }`; the icon is an Ant Design name; `path` is an HTML file in the management server's webapp directory (`/usr/share/cloudstack-management/webapp`) or a URL. The file is `/etc/cloudstack/management/config.json`; the default has `"plugins": []` | No | **The way to start**: a menu entry, no fork |
| **A section in the UI source** | The UI development guide: a section in `src/config/section`, imported in `src/config/router.js`; then `npm run build`. The admin guide calls this advanced customisation, "building the UI from the source" | Yes | A fork of the UI to maintain at each release; native look, access to the UI's components and session |
| **The extensions framework** | Recent versions (the page mentions 4.22 for one feature): an external binary of type Orchestrator or NetworkOrchestrator, managed in an "Extensions" menu; **custom actions** attached to VirtualMachine, Network or Vpc resources are rendered as forms by the UI | No | **Not a page**: it adds actions on existing resources and shows a message. A possible later complement (an action "Local AI status" on a VM), not the topology page |
| **A separate web application** | Any web app that calls the CloudStack API | No | Fallback, as written in the spec |

## How the iframe plugin is built

- `ui/src/config/router.js` creates one route per plugin, `/plugins/<name>`, with the component `IFramePlugin`, only when the entry is not an external link and has a `path`.
- `IFramePlugin.vue` renders `<iframe :src="path" width="100%" style="height: 90vh">`: **no `sandbox` attribute, no postMessage, no authentication handled**. The page is a plain web page inside the UI's frame.
- So the page is a normal web application in a frame: its own build (any framework), served by the management server (webapp directory) or by its own server (the `path` is a URL).

## Session and authentication

- The UI logs in with `POST /client/api?command=login` (username, password, domain), gets a `sessionkey`, stores it in `localStorage` and as a **cookie**, and sends `sessionkey` with each call (the cookie as the fallback). On a 401 it logs out.
- An external client may instead sign requests with the user's API key and secret key (HMAC-SHA1 over the sorted, lowercased query), as in the developer guide.
- **Inference, not confirmed:** a page served from the **same origin** as `/client` (the webapp directory) could reuse the `sessionkey` cookie and call `/client/api`; a cross-origin page would see neither the cookie nor `localStorage`. Whether the cookie is `HttpOnly` or `SameSite` was not checked, nor the CORS settings of the management server. Test 1 of the [list](README.md#what-to-try-first).

## Consequences for the spec

- The **page as a plugin** is feasible with no change to CloudStack: a page in the `plugins` list, served from the webapp directory so that it shares the origin. The spec's [open question](../../docs/spec-cloudstack.md#open-questions) about the authentication to the service becomes: does the iframe get the session, or must the user give an API key and secret key to the page (not to be stored)?
- The page looks like its own application, not like the native UI. That is a trade for not forking the UI.
- The service could be exposed under the same origin by a reverse proxy in front of the management server, which would avoid CORS: not verified, an operator's choice.

## Not confirmed

CORS configuration of the management server; `HttpOnly` / `SameSite` of the session cookie; how an external-link plugin is displayed; the version that introduced `plugins`; any official "custom page" extension point other than the iframe.

## Sources

- [UI customisation, admin guide](https://docs.cloudstack.apache.org/en/latest/adminguide/ui.html)
- [`ui/public/config.json`](https://raw.githubusercontent.com/apache/cloudstack/main/ui/public/config.json)
- [`ui/src/config/router.js`](https://raw.githubusercontent.com/apache/cloudstack/main/ui/src/config/router.js)
- [`IFramePlugin.vue`](https://raw.githubusercontent.com/apache/cloudstack/main/ui/src/views/plugins/IFramePlugin.vue)
- [UI development guide](https://raw.githubusercontent.com/apache/cloudstack/main/ui/docs/development.md)
- [Extensions framework](https://docs.cloudstack.apache.org/en/latest/adminguide/extensions.html)
- [UI login and request code: `api/index.js`](https://raw.githubusercontent.com/apache/cloudstack/main/ui/src/api/index.js), [`store/modules/user.js`](https://raw.githubusercontent.com/apache/cloudstack/main/ui/src/store/modules/user.js)
- [Developer guide: API signing](https://docs.cloudstack.apache.org/en/latest/developersguide/dev.html)
