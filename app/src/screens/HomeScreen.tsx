import React, { useCallback, useEffect, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  Image,
  Pressable,
  StyleSheet,
  Text,
  View,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import { pb } from "../lib/pb";
import { leavePair } from "../lib/pairApi";

let PearSharedReload: (() => void) | null = null;
try {
  const m = require("../../modules/pear-shared/src");
  PearSharedReload = () => m.PearShared.reloadTimelines();
} catch {}

function reloadWidget() { try { PearSharedReload?.(); } catch {} }
import { EVENT_KINDS, Post } from "../types";

type Member = {
  user: string;
  expand?: { user?: { display_name?: string; email?: string } };
};

export function HomeScreen({ pairId, onUnpaired }: { pairId: string; onUnpaired: () => void }) {
  const me = pb.authStore.record?.id ?? "";
  const [partnerName, setPartnerName] = useState("Partner");
  const [latest, setLatest] = useState<Post | null>(null);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const members = await pb
        .collection("pair_members")
        .getFullList<Member>({ filter: `pair = "${pairId}"`, expand: "user" });
      const other = members.find((m) => m.user !== me);
      const u = other?.expand?.user;
      setPartnerName(u?.display_name || u?.email?.split("@")[0] || "Partner");
      if (other) {
        const posts = await pb.collection("posts").getList<Post>(1, 1, {
          filter: `pair = "${pairId}" && author = "${other.user}"`,
          sort: "-created",
        });
        setLatest(posts.items[0] ?? null);
      }
    } catch {
      // offline / server down — keep last known state
    }
  }, [pairId, me]);

  useEffect(() => { refresh(); }, [refresh]);

  const logEvent = async (kind: string) => {
    setBusy(true);
    try {
      await pb
        .collection("posts")
        .create({ pair: pairId, author: me, type: "event", event_kind: kind });
      reloadWidget();
    } catch (e) {
      Alert.alert("Couldn't log it", String(e));
    } finally {
      setBusy(false);
    }
  };

  const sharePhoto = async () => {
    const perm = await ImagePicker.requestCameraPermissionsAsync();
    if (!perm.granted) {
      Alert.alert("Camera access needed", "Enable camera access in Settings to share a moment.");
      return;
    }
    const shot = await ImagePicker.launchCameraAsync({ quality: 0.6, allowsEditing: true, aspect: [1, 1] });
    const asset = shot.assets?.[0];
    if (shot.canceled || !asset) return;
    setBusy(true);
    try {
      const form = new FormData();
      form.append("pair", pairId);
      form.append("author", me);
      form.append("type", "photo");
      form.append("media", { uri: asset.uri, name: "pear.jpg", type: "image/jpeg" } as any);
      await pb.collection("posts").create(form);
      reloadWidget();
    } catch (e) {
      Alert.alert("Upload failed", String(e));
    } finally {
      setBusy(false);
    }
  };

  const confirmLeave = () =>
    Alert.alert("Un-pear?", "You'll both lose the shared timeline.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Leave",
        style: "destructive",
        onPress: async () => {
          try { await leavePair(); } finally { onUnpaired(); }
        },
      },
    ]);

  const mediaUrl =
    latest?.type === "photo" && latest.media
      ? `${pb.baseURL}/api/files/posts/${latest.id}/${latest.media}?thumb=512x512`
      : null;

  return (
    <View style={styles.container}>
      <Text style={styles.header}>Pear'd 🍐</Text>

      <View style={styles.card}>
        {mediaUrl ? (
          <Image source={{ uri: mediaUrl }} style={styles.photo} />
        ) : (
          <Text style={styles.cardEmoji}>
            {latest ? emojiFor(latest.event_kind) : "🍐"}
          </Text>
        )}
        <Text style={styles.cardCaption}>
          {latest
            ? `${partnerName} · ${latest.type === "event" ? latest.event_kind : "shared a moment"}`
            : `Nothing from ${partnerName} yet`}
        </Text>
      </View>

      <View style={styles.row}>
        {EVENT_KINDS.map((e) => (
          <Pressable key={e.kind} style={styles.eventBtn} disabled={busy} onPress={() => logEvent(e.kind)}>
            <Text style={styles.eventEmoji}>{e.emoji}</Text>
            <Text style={styles.eventLabel}>{e.label}</Text>
          </Pressable>
        ))}
      </View>

      <Pressable style={styles.camera} disabled={busy} onPress={sharePhoto}>
        {busy ? <ActivityIndicator color="#fff" /> : <Text style={styles.cameraText}>📸 Share a moment</Text>}
      </Pressable>

      <View style={styles.footer}>
        <Pressable onPress={() => pb.authStore.clear()}>
          <Text style={styles.footerText}>Sign out</Text>
        </Pressable>
        <Pressable onPress={confirmLeave}>
          <Text style={[styles.footerText, styles.leave]}>Un-pear</Text>
        </Pressable>
      </View>
    </View>
  );
}

function emojiFor(kind?: string) {
  switch (kind) {
    case "beer": return "🍺";
    case "loo": return "💩";
    case "coffee": return "☕";
    default: return "🍐";
  }
}

const styles = StyleSheet.create({
  container: { flex: 1, padding: 20, paddingTop: 64, backgroundColor: "#FBF7EC" },
  header: { fontSize: 26, fontWeight: "800", color: "#3B2E1A", marginBottom: 16 },
  card: { backgroundColor: "#fff", borderRadius: 16, padding: 16, alignItems: "center", marginBottom: 20 },
  photo: { width: "100%", aspectRatio: 1, borderRadius: 12 },
  cardEmoji: { fontSize: 72, marginVertical: 24 },
  cardCaption: { marginTop: 12, color: "#7A6A53", fontSize: 14 },
  row: { flexDirection: "row", marginBottom: 20 },
  eventBtn: { flex: 1, backgroundColor: "#fff", borderRadius: 12, paddingVertical: 14, alignItems: "center", marginHorizontal: 4 },
  eventEmoji: { fontSize: 28 },
  eventLabel: { marginTop: 4, fontSize: 12, color: "#7A6A53", fontWeight: "600" },
  camera: { backgroundColor: "#6B8E23", borderRadius: 12, paddingVertical: 14, alignItems: "center" },
  cameraText: { color: "#fff", fontSize: 16, fontWeight: "700" },
  footer: { flexDirection: "row", justifyContent: "space-between", marginTop: 28 },
  footerText: { color: "#7A6A53", fontSize: 14 },
  leave: { color: "#B23A2E" },
});