import { initSDK, trace, log } from '@embrace-io/web-sdk';

const appID = window.__EMBRACE_APP_ID__;
if (appID) {
  const ok = initSDK({ appID });
  if (ok) {
    window.__embraceTrace = trace;
    window.__embraceLog = log;
  } else {
    console.warn('[embrace] initSDK returned false — check app ID. Custom spans/exceptions disabled.');
  }
}
