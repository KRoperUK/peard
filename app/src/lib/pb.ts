import AsyncStorage from "@react-native-async-storage/async-storage";
import PocketBase, { AsyncAuthStore } from "pocketbase";
import RNEventSource from "react-native-sse";

// ---------------------------------------------------------------------------
// React Native lacks the browser EventSource. Wrap react-native-sse so
// PocketBase's real-time subscriptions work in Hermes.
// ---------------------------------------------------------------------------
class NativeEventSource {
  private es: RNEventSource;
  private listeners: Record<string, Array<(e: any) => void>> = {};
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: string }) => void) | null = null;
  onerror: (() => void) | null = null;

  constructor(url: string, _opts?: any) {
    this.es = new RNEventSource(url);
    this.es.addEventListener("open", () => this.onopen?.());
    this.es.addEventListener("message", (e: any) => {
      this.onmessage?.(e);
      (this.listeners["message"] || []).forEach((cb) => cb(e));
    });
    this.es.addEventListener("error", () => {
      this.onerror?.();
      (this.listeners["error"] || []).forEach((cb) => cb({}));
    });
  }
  addEventListener(type: string, cb: (e: any) => void) {
    (this.listeners[type] = this.listeners[type] || []).push(cb);
  }
  removeEventListener(type: string, cb: (e: any) => void) {
    this.listeners[type] = (this.listeners[type] || []).filter((c) => c !== cb);
  }
  close() { this.es.close(); }
  get readyState() { return 1; } // OPEN
  static readonly OPEN = 1;
  static readonly CONNECTING = 0;
  static readonly CLOSED = 2;
}
(globalThis as any).EventSource = NativeEventSource;

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
