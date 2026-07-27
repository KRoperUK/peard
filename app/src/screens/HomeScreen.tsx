import React, { useCallback, useEffect, useRef, useState } from "react";
import {
  ActivityIndicator, Alert, Image, Pressable, RefreshControl, ScrollView, StyleSheet, Text, TextInput, View,
} from "react-native";
import * as ImagePicker from "expo-image-picker";
import { pb } from "../lib/pb";
import { leavePair } from "../lib/pairApi";
import { EVENT_KINDS, Post } from "../types";

let PearSharedReload: (() => void) | null = null;
try { const m = require("../../modules/pear-shared/src"); PearSharedReload = () => m.PearShared.reloadTimelines(); } catch {}
function reloadWidget() { try { PearSharedReload?.(); } catch {} }

type Member = {
  user: string;
  expand?: { user?: { display_name?: string; email?: string } };
};

function countPeriods(events: Post[]) {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const weekStart = new Date(today);
  weekStart.setDate(today.getDate() - ((today.getDay() + 6) % 7));
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
  let todayCount = 0, weekCount = 0, monthCount = 0;
  for (const e of events) {
    const d = new Date(e.created);
    if (d >= today) { todayCount++; weekCount++; monthCount++; }
    else if (d >= weekStart) { weekCount++; monthCount++; }
    else if (d >= monthStart) monthCount++;
  }
  return { today: todayCount, week: weekCount, month: monthCount, all: events.length };
}

export function HomeScreen({ pairId, onUnpaired }: { pairId: string; onUnpaired: () => void }) {
  const me = pb.authStore.record?.id ?? "";
  const [partnerName, setPartnerName] = useState("Partner");
  const [latest, setLatest] = useState<Post | null>(null);
  const [latestAuthor, setLatestAuthor] = useState("");
  const [busyKind, setBusyKind] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [noteInput, setNoteInput] = useState("");
  const [pendingKind, setPendingKind] = useState<string | null>(null);
  const noteRef = useRef<TextInput>(null);
  const [stats, setStats] = useState({ today: 0, week: 0, month: 0, all: 0 });
  const [partnerStats, setPartnerStats] = useState({ today: 0, week: 0, month: 0, all: 0 });
  const [recentPosts, setRecentPosts] = useState<Post[]>([]);

  const fetchStats = useCallback(async () => {
    if (!me || !pairId) return;
    try {
      const allEvents = await pb.collection("posts").getFullList<Post>({
        filter: `pair = "${pairId}" && type = "event"`,
        sort: "-created",
      });
      setStats(countPeriods(allEvents.filter((e) => e.author === me)));
      setPartnerStats(countPeriods(allEvents.filter((e) => e.author !== me)));
    } catch {}
  }, [me, pairId]);

  const refresh = useCallback(async () => {
    try {
      const members = await pb
        .collection("pair_members")
        .getFullList<Member>({ filter: `pair = "${pairId}"`, expand: "user" });
      const other = members.find((m) => m.user !== me);
      const u = other?.expand?.user;
      setPartnerName(u?.display_name || u?.email?.split("@")[0] || "Partner");

      // Latest posts from either user.
      const posts = await pb.collection("posts").getList<Post>(1, 5, {
        filter: `pair = "${pairId}"`,
        sort: "-created",
      });
      setRecentPosts(posts.items);
      const latestPost = posts.items[0] ?? null;
      setLatest(latestPost);
      if (latestPost) {
        const isMe = latestPost.author === me;
        setLatestAuthor(isMe ? "You" : (u?.display_name || u?.email?.split("@")[0] || "Partner"));
      }
    } catch {
      // offline / server down — keep last known state
    }
  }, [pairId, me]);

  useEffect(() => { refresh(); fetchStats(); }, [refresh, fetchStats]);

  const logEvent = async (kind: string, note?: string) => {
    setBusyKind(kind);
    setPendingKind(null);
    setNoteInput("");
    try {
      await pb
        .collection("posts")
        .create({ pair: pairId, author: me, type: "event", event_kind: kind, note: note || "" });
      const emoji = EVENT_KINDS.find((e) => e.kind === kind)?.emoji ?? "🍐";
      setToast(`${emoji} logged!`);
      setTimeout(() => setToast(null), 1500);
      reloadWidget();
      refresh();
      fetchStats();
    } catch (e) {
      Alert.alert("Couldn't log it", String(e));
    } finally {
      setBusyKind(null);
    }
  };

  const startLog = (kind: string) => {
    setPendingKind(kind);
    setNoteInput("");
    setTimeout(() => noteRef.current?.focus(), 100);
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
    setBusyKind("camera");
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
      setBusyKind(null);
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

  const handleRefresh = async () => {
    setRefreshing(true);
    await refresh();
    await fetchStats();
    setRefreshing(false);
  };

  const mediaUrl =
    latest?.type === "photo" && latest.media
      ? `${pb.baseURL}/api/files/posts/${latest.id}/${latest.media}?thumb=512x512`
      : null;

  return (
    <ScrollView
      style={styles.container}
      contentContainerStyle={styles.content}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={handleRefresh} tintColor="#6B8E23" />}
    >
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
            ? `${latestAuthor} · ${latest.type === "event" ? latest.event_kind : "shared a moment"}`
            : "No moments yet — send a pear!"}
        </Text>
        {latest?.note ? <Text style={styles.cardNote}>{latest.note}</Text> : null}
      </View>

      <View style={styles.row}>
        {EVENT_KINDS.map((e) => (
          <Pressable key={e.kind} style={styles.eventBtn} disabled={busyKind !== null} onPress={() => startLog(e.kind)}>
            <Text style={styles.eventEmoji}>{e.emoji}</Text>
            <Text style={styles.eventLabel}>{e.label}</Text>
          </Pressable>
        ))}
      </View>

      {pendingKind && (
        <View style={styles.noteRow}>
          <TextInput
            ref={noteRef}
            style={styles.noteInput}
            placeholder={`Add a note (optional)…`}
            placeholderTextColor="#B3A78F"
            value={noteInput}
            onChangeText={setNoteInput}
            onSubmitEditing={() => logEvent(pendingKind, noteInput)}
            returnKeyType="send"
          />
          <Pressable style={styles.noteSubmit} onPress={() => logEvent(pendingKind, noteInput)}>
            <Text style={styles.noteSubmitText}>Send</Text>
          </Pressable>
          <Pressable onPress={() => { setPendingKind(null); setNoteInput(""); }}>
            <Text style={styles.noteCancel}>✕</Text>
          </Pressable>
        </View>
      )}

      <View style={styles.statsRow}>
        <Text style={styles.statLabel}>You</Text>
        <Text style={styles.stat}>T {stats.today}</Text>
        <Text style={styles.stat}>W {stats.week}</Text>
        <Text style={styles.stat}>M {stats.month}</Text>
        <Text style={styles.stat}>All {stats.all}</Text>
      </View>
      <View style={styles.statsRow}>
        <Text style={styles.statLabel}>{shortName(partnerName)}</Text>
        <Text style={styles.stat}>T {partnerStats.today}</Text>
        <Text style={styles.stat}>W {partnerStats.week}</Text>
        <Text style={styles.stat}>M {partnerStats.month}</Text>
        <Text style={styles.stat}>All {partnerStats.all}</Text>
      </View>

      {recentPosts.length > 1 && (
        <View style={styles.history}>
          {recentPosts.slice(1, 4).map((p) => (
            <Text key={p.id} style={styles.historyItem}>
              {p.author === me ? "You" : shortName(partnerName)} · {p.type === "photo" ? "📸" : emojiFor(p.event_kind)}{" "}
                {p.note || (p.type === "photo" ? "photo" : p.event_kind) || "shared a moment"}
              {"  "}
              <Text style={styles.timeAgo}>{timeAgo(p.created)}</Text>
            </Text>
          ))}
        </View>
      )}

      {toast && <Text style={styles.toast}>{toast}</Text>}

      <Pressable style={styles.camera} disabled={busyKind !== null} onPress={sharePhoto}>
        {busyKind === "camera" ? <ActivityIndicator color="#fff" /> : <Text style={styles.cameraText}>📸 Share a moment</Text>}
      </Pressable>

      <View style={styles.footer}>
        <Pressable onPress={() => pb.authStore.clear()}>
          <Text style={styles.footerText}>Sign out</Text>
        </Pressable>
        <Pressable onPress={confirmLeave}>
          <Text style={[styles.footerText, styles.leave]}>Un-pear</Text>
        </Pressable>
      </View>
    </ScrollView>
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

function shortName(name: string) {
  if (name.length <= 8) return name;
  return name.slice(0, 7) + "…";
}

function timeAgo(iso: string) {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "now";
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#FBF7EC" },
  content: { padding: 20, paddingTop: 64 },
  header: { fontSize: 26, fontWeight: "800", color: "#3B2E1A", marginBottom: 16 },
  card: { backgroundColor: "#fff", borderRadius: 16, padding: 16, alignItems: "center", marginBottom: 20 },
  photo: { width: "100%", aspectRatio: 1, borderRadius: 12 },
  cardEmoji: { fontSize: 72, marginVertical: 24 },
  cardCaption: { marginTop: 12, color: "#7A6A53", fontSize: 14 },
  cardNote: { marginTop: 4, color: "#3B2E1A", fontSize: 15, fontStyle: "italic", textAlign: "center" },
  row: { flexDirection: "row", marginBottom: 20 },
  eventBtn: { flex: 1, backgroundColor: "#fff", borderRadius: 12, paddingVertical: 14, alignItems: "center", marginHorizontal: 4 },
  eventEmoji: { fontSize: 28 },
  eventLabel: { marginTop: 4, fontSize: 12, color: "#7A6A53", fontWeight: "600" },
  noteRow: { flexDirection: "row", gap: 8, marginBottom: 12 },
  noteInput: { flex: 1, backgroundColor: "#fff", borderRadius: 12, padding: 12, fontSize: 14, color: "#3B2E1A" },
  noteSubmit: { backgroundColor: "#6B8E23", borderRadius: 12, paddingHorizontal: 20, justifyContent: "center" },
  noteSubmitText: { color: "#fff", fontWeight: "700", fontSize: 14 },
  noteCancel: { fontSize: 18, color: "#B3A78F", paddingHorizontal: 4 },
  statsRow: { flexDirection: "row", alignItems: "center", gap: 8, backgroundColor: "#fff", borderRadius: 12, padding: 10, marginBottom: 6 },
  statLabel: { fontSize: 12, fontWeight: "800", color: "#6B8E23", width: 56 },
  stat: { fontSize: 12, fontWeight: "600", color: "#3B2E1A" },
  history: { backgroundColor: "#fff", borderRadius: 12, padding: 12, marginBottom: 12 },
  historyItem: { fontSize: 13, color: "#7A6A53", paddingVertical: 3 },
  timeAgo: { fontSize: 11, color: "#B3A78F" },
  toast: { textAlign: "center", fontSize: 16, fontWeight: "700", color: "#6B8E23", marginBottom: 12 },
  camera: { backgroundColor: "#6B8E23", borderRadius: 12, paddingVertical: 14, alignItems: "center" },
  cameraText: { color: "#fff", fontSize: 16, fontWeight: "700" },
  footer: { flexDirection: "row", justifyContent: "space-between", marginTop: 28 },
  footerText: { color: "#7A6A53", fontSize: 14 },
  leave: { color: "#B23A2E" },
});