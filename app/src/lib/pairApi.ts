import { pb, PB_URL } from "./pb";
import type { PairInvite } from "../types";

async function post<T>(path: string, body?: unknown): Promise<T> {
  const res = await fetch(`${PB_URL}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: pb.authStore.token,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((data as any)?.message ?? `Request failed (${res.status})`);
  }
  return data as T;
}

export const createInvite = () => post<PairInvite>("/api/peard/pairs/invite");

export const acceptInvite = (code: string) =>
  post<{ pair: string }>("/api/peard/pairs/accept", { code });

export const leavePair = () => post<{ ok: boolean }>("/api/peard/pairs/leave");
