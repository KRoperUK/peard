import { requireNativeModule } from "expo-modules-core";

type PearSharedModuleType = {
  setSharedItem(key: string, value: string): void;
  getSharedItem(key: string): string | null;
  removeSharedItem(key: string): void;
  reloadTimelines(): void;
};

/**
 * Bridge to the iOS App Group container shared with the PearWidget
 * WidgetKit extension. Android is a no-op until the Glance widget lands.
 */
export const PearShared = requireNativeModule<PearSharedModuleType>("PearShared");
