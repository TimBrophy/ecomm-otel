import { initSDK, trace } from '@embrace-io/web-sdk';

const appID = window.__EMBRACE_APP_ID__;
if (appID) {
  initSDK({ appID });
  window.__embraceTrace = trace;
}
