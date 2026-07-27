import React, { useCallback, useEffect, useState } from "react";
import { ActivityIndicator, StyleSheet, View } from "react-native";
import { StatusBar } from "expo-status-bar";
import { pb } from "./src/lib/pb";
import { syncWidgetCredentials, clearWidgetCredentials } from "./src/lib/widgetSync";
import { AuthScreen } from "./src/screens/AuthScreen";
import { PairScreen } from "./src/screens/PairScreen";
import { HomeScreen } from "./src/screens/HomeScreen";

type Phase = "loading" | "auth" | "pair" | "home";

export default function App() {
  const [phase, setPhase] = useState<Phase>("loading");
  const [pairId, setPairId] = useState<string | null>(null);

  const refreshPair = useCallback(async () => {
    if (!pb.authStore.isValid) {
      setPhase("auth");
      return;
    }
    try {
      const mem = await pb
        .collection("pair_members")
        .getFirstListItem(`user = "${pb.authStore.record?.id}"`);
      setPairId(mem.pair);
      setPhase("home");
    } catch {
      setPairId(null);
      setPhase("pair");
    }
  }, []);

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (pb.authStore.isValid) {
      syncWidgetCredentials();
      refreshPair();
    } else {
      setPhase("auth");
    }
    pb.authStore.onChange(() => {
      if (pb.authStore.isValid) {
        syncWidgetCredentials();
        refreshPair();
      } else {
        clearWidgetCredentials();
        setPhase("auth");
      }
    });
  }, []);

  if (phase === "loading") {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#6B8E23" />
      </View>
    );
  }

  return (
    <View style={styles.root}>
      <StatusBar style="dark" />
      {phase === "auth" && <AuthScreen />}
      {phase === "pair" && <PairScreen onPaired={refreshPair} />}
      {phase === "home" && pairId && (
        <HomeScreen pairId={pairId} onUnpaired={refreshPair} />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: "#FBF7EC" },
  center: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: "#FBF7EC" },
});

