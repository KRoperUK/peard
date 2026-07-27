import AsyncStorage from "@react-native-async-storage/async-storage";
import PocketBase, { AsyncAuthStore } from "pocketbase";

/**
 * Point the app at your Pear'd server.
 * Set EXPO_PUBLIC_PB_URL in app/.env (e.g. http://192.168.1.x:8090 for a
 * physical device — 127.0.0.1 only works in the simulator).
 */
export const PB_URL = process.env.EXPO_PUBLIC_PB_URL ?? "http://127.0.0.1:8090";

// Persist the PocketBase auth session across app launches.
const store = new AsyncAuthStore({
  save: async (serialized) => AsyncStorage.setItem("pb_auth", serialized),
  initial: AsyncStorage.getItem("pb_auth"),
});

export const pb = new PocketBase(PB_URL, store);

// Canary: verify the server is reachable on launch.
if (__DEV__) {
  fetch(`${PB_URL}/api/health`)
    .then((r) => r.json())
    .then((d) => console.log("[peard] server reachable:", d?.code))
    .catch((e) => console.warn("[peard] server unreachable:", String(e)));
}
