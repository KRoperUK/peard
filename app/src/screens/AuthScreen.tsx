import React, { useState } from "react";
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from "react-native";
import { signInWithApple, signInWithGoogle } from "../lib/auth";

export function AuthScreen() {
  const [busy, setBusy] = useState<"apple" | "google" | null>(null);
  const [error, setError] = useState<string | null>(null);

  const run = async (which: "apple" | "google", fn: () => Promise<void>) => {
    setBusy(which);
    setError(null);
    try {
      await fn(); // pb.authStore.onChange in App.tsx takes it from here
    } catch (e) {
      setError(e instanceof Error ? e.message : "Sign-in failed");
    } finally {
      setBusy(null);
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.logo}>🍐</Text>
      <Text style={styles.title}>Pear'd</Text>
      <Text style={styles.subtitle}>
        Moments & tallies, shared with your favourite person.
      </Text>

      <Pressable
        style={[styles.button, styles.apple]}
        disabled={busy !== null}
        onPress={() => run("apple", signInWithApple)}
      >
        {busy === "apple" ? (
          <ActivityIndicator color="#fff" />
        ) : (
          <Text style={styles.appleText}> Sign in with Apple</Text>
        )}
      </Pressable>

      <Pressable
        style={[styles.button, styles.google]}
        disabled={busy !== null}
        onPress={() => run("google", signInWithGoogle)}
      >
        {busy === "google" ? (
          <ActivityIndicator color="#333" />
        ) : (
          <Text style={styles.googleText}>G&nbsp;&nbsp;Continue with Google</Text>
        )}
      </Pressable>

      {error && <Text style={styles.error}>{error}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    padding: 32,
    backgroundColor: "#FBF7EC",
  },
  logo: { fontSize: 72 },
  title: { fontSize: 34, fontWeight: "800", color: "#3B2E1A", marginTop: 8 },
  subtitle: {
    fontSize: 15,
    color: "#7A6A53",
    textAlign: "center",
    marginTop: 8,
    marginBottom: 40,
  },
  button: {
    width: "100%",
    paddingVertical: 14,
    borderRadius: 12,
    alignItems: "center",
    marginBottom: 12,
  },
  apple: { backgroundColor: "#000" },
  appleText: { color: "#fff", fontSize: 16, fontWeight: "600" },
  google: { backgroundColor: "#fff", borderWidth: 1, borderColor: "#ddd" },
  googleText: { color: "#333", fontSize: 16, fontWeight: "600" },
  error: { color: "#B23A2E", marginTop: 16, textAlign: "center" },
});
