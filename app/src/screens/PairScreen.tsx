import React, { useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  Share,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { acceptInvite, createInvite } from "../lib/pairApi";
import { pb } from "../lib/pb";
import type { PairInvite } from "../types";

export function PairScreen({ onPaired }: { onPaired: () => void }) {
  const [invite, setInvite] = useState<PairInvite | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const makeInvite = async () => {
    setBusy(true);
    setError(null);
    try {
      setInvite(await createInvite());
    } catch (e) {
      setError(e instanceof Error ? e.message : "Couldn't create invite");
    } finally {
      setBusy(false);
    }
  };

  /**
   * Debug shortcut: entering AAAAAA as the code creates a fake pair
   * directly — no second device needed. Only compiled in __DEV__.
   */
  const fakePair = async () => {
    // Save the current auth so we can restore it after using the admin session.
    const userToken = pb.authStore.token;
    const userRecord = pb.authStore.record;

    // Create a partner account (idempotent).
    try {
      await pb.collection("users").create({
        email: "partner@peard.local",
        password: "test1234",
        passwordConfirm: "test1234",
        display_name: "Test Partner",
      });
    } catch {}

    // Switch to superuser so we can create pairs / members (those collections
    // are locked to superuser-only create).
    await pb.admins.authWithPassword("admin@peard.app", "Password123!");

    const pair = await pb.collection("pairs").create({});
    const partner = await pb
      .collection("users")
      .getFirstListItem('email = "partner@peard.local"');

    await pb.collection("pair_members").create({
      pair: pair.id,
      user: userRecord?.id,
      role: "owner",
    });
    await pb.collection("pair_members").create({
      pair: pair.id,
      user: partner.id,
      role: "member",
    });

    // Seed a few demo events from the partner so the HomeScreen has data.
    await pb.collection("posts").create({
      pair: pair.id,
      author: partner.id,
      type: "event",
      event_kind: "beer",
      note: "Welcome to Pear'd! 🍐",
    });
    await pb.collection("posts").create({
      pair: pair.id,
      author: partner.id,
      type: "event",
      event_kind: "coffee",
      note: "Good morning!",
    });

    // Restore the user session.
    pb.authStore.save(userToken, userRecord);
  };

  const accept = async () => {
    setBusy(true);
    setError(null);
    try {
      if (__DEV__ && code === "AAAAAA") {
        await fakePair();
      } else {
        await acceptInvite(code);
      }
      onPaired();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Couldn't accept invite");
    } finally {
      setBusy(false);
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Pear up 🍐</Text>
      <Text style={styles.sub}>Share a code with your partner, or enter theirs.</Text>

      {invite ? (
        <>
          <Text style={styles.code}>{invite.code}</Text>
          <Pressable
            style={styles.secondary}
            onPress={() =>
              Share.share({
                message: `Pear up with me on Pear'd! Code: ${invite.code}\n${invite.deep_link}`,
              })
            }
          >
            <Text style={styles.secondaryText}>Share code</Text>
          </Pressable>
        </>
      ) : (
        <Pressable style={styles.primary} onPress={makeInvite} disabled={busy}>
          <Text style={styles.primaryText}>Create invite code</Text>
        </Pressable>
      )}

      <View style={styles.divider} />

      <TextInput
        style={styles.input}
        placeholder="ENTER CODE"
        placeholderTextColor="#B3A78F"
        autoCapitalize="characters"
        autoCorrect={false}
        maxLength={6}
        value={code}
        onChangeText={setCode}
      />
      {__DEV__ && (
        <Text style={styles.hint}>💡 Dev: type AAAAAA to skip pairing</Text>
      )}
      <Pressable
        style={[styles.primary, (busy || code.length < 6) && styles.disabled]}
        onPress={accept}
        disabled={busy || code.length < 6}
      >
        {busy ? (
          <ActivityIndicator color="#fff" />
        ) : (
          <Text style={styles.primaryText}>Accept & pear up</Text>
        )}
      </Pressable>

      {error && <Text style={styles.error}>{error}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, alignItems: "center", justifyContent: "center", padding: 32, backgroundColor: "#FBF7EC" },
  title: { fontSize: 28, fontWeight: "800", color: "#3B2E1A" },
  sub: { fontSize: 14, color: "#7A6A53", marginTop: 8, marginBottom: 32, textAlign: "center" },
  code: { fontSize: 44, fontWeight: "800", letterSpacing: 8, color: "#6B8E23", marginBottom: 16 },
  primary: { backgroundColor: "#6B8E23", width: "100%", paddingVertical: 14, borderRadius: 12, alignItems: "center" },
  primaryText: { color: "#fff", fontSize: 16, fontWeight: "700" },
  secondary: { paddingVertical: 10, paddingHorizontal: 20, borderRadius: 10, borderWidth: 1, borderColor: "#6B8E23" },
  secondaryText: { color: "#6B8E23", fontWeight: "700" },
  divider: { height: 1, backgroundColor: "#E3DAC6", width: "100%", marginVertical: 28 },
  input: {
    width: "100%",
    borderWidth: 1,
    borderColor: "#D8CCB2",
    borderRadius: 12,
    padding: 14,
    fontSize: 20,
    letterSpacing: 6,
    textAlign: "center",
    color: "#3B2E1A",
    marginBottom: 12,
    backgroundColor: "#fff",
  },
  disabled: { opacity: 0.5 },
  hint: { color: "#B3A78F", fontSize: 11, marginBottom: 8, marginTop: -4 },
  error: { color: "#B23A2E", marginTop: 16, textAlign: "center" },
});
