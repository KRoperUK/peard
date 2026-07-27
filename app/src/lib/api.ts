import { pb, PB_URL } from "./pb";

/** Raw-fetch API helpers — PocketBase JS SDK v0.27 doesn't issue HTTP in Hermes. */

function authHeader() {
  return { Authorization: pb.authStore.token };
}

export async function apiGetList(collection: string, filter: string, sort = "-created", limit = 100) {
  const params = new URLSearchParams({ filter, sort, perPage: String(limit) });
  const r = await fetch(`${PB_URL}/api/collections/${collection}/records?${params}`, {
    headers: authHeader(),
  });
  if (!r.ok) throw new Error(`${r.status}`);
  return (await r.json()).items ?? [];
}

export async function apiGetFirst(collection: string, filter: string) {
  const items = await apiGetList(collection, filter, "-created", 1);
  return items[0] ?? null;
}

export async function apiCreate(collection: string, body: Record<string, unknown>) {
  const r = await fetch(`${PB_URL}/api/collections/${collection}/records`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeader() },
    body: JSON.stringify(body),
  });
  if (!r.ok) {
    const d = await r.json().catch(() => ({}));
    throw new Error((d as any)?.message ?? `${r.status}`);
  }
  return r.json();
}

export async function apiGetFullList(collection: string, filter: string, sort = "-created") {
  return apiGetList(collection, filter, sort, 500);
}