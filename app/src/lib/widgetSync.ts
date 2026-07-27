import { Platform } from "react-native";
import { pb, PB_URL } from "./pb";

/**
 * Best-effort bridge to the iOS native module (PearShared).
 * Falls back silently when the module isn't linked — the app is still fully
 * functional without the widget.
 */
let PearShared: any = null;
try {
  PearShared = require("../../modules/pear-shared/src").PearShared;
} catch {}


/**
 * Issues a revocable widget token from the server and hands it (plus the API
 * base URL) to the WidgetKit extension via the shared App Group container,
 * then asks WidgetKit to reload timelines.
 *
 * Best-effort by design: the app works fine without the widget installed.
 */
export async function syncWidgetCredentials(): Promise<void> {
  if (Platform.OS !== "ios") return;
  try {
    const res = await fetch(`${PB_URL}/api/peard/widget/token`, {
      method: "POST",
      headers: { Authorization: pb.authStore.token },
    });
    if (!res.ok) return;
    const data = (await res.json()) as { token: string };
    PearShared.setSharedItem("widgetToken", data.token);
    PearShared.setSharedItem("apiBaseUrl", PB_URL);
    PearShared.reloadTimelines();
  } catch {
    // no-op: widget sync is opportunistic
  }
}

export function clearWidgetCredentials(): void {
  if (Platform.OS !== "ios") return;
  try {
    PearShared.removeSharedItem("widgetToken");
    PearShared.reloadTimelines();
  } catch {
    // no-op
  }
}
