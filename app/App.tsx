import React, { useCallback, useEffect, useState } from "react";
import { ActivityIndicator, StyleSheet, View } from "react-native";
import { StatusBar } from "expo-status-bar";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { PB_URL } from "./src/lib/pb";
import { apiGetFirst } from "./src/lib/api";
import { syncWidgetCredentials, clearWidgetCredentials } from "./src/lib/widgetSync";
import { AuthScreen } from "./src/screens/AuthScreen";
import { PairScreen } from "./src/screens/PairScreen";
import { HomeScreen } from "./src/screens/HomeScreen";
import { setOnAuth } from "./src/lib/auth";

type Phase = "loading" | "auth" | "pair" | "home";

function getToken() { return AsyncStorage.getItem("peard_token"); }
function setToken(t: string) { return AsyncStorage.setItem("peard_token", t); }
function clearToken() { return AsyncStorage.removeItem("peard_token"); }
function getUserId() { return AsyncStorage.getItem("peard_uid"); }
function setUserId(id: string) { return AsyncStorage.setItem("peard_uid", id); }

export default function App() {
  const [phase, setPhase] = useState<Phase>("loading");
  const [pairId, setPairId] = useState<string | null>(null);
  const [userId, setUserIdState] = useState<string>("");

  const refreshPair = useCallback(async () => {
    const uid = await getUserId();
    if (!uid || !(await getToken())) {
      setPhase("auth");
      return;
    }
    setUserIdState(uid);
    try {
      const mem = await apiGetFirst("pair_members", `user = "${uid}"`);
      if (!mem) { setPairId(null); setPhase("pair"); return; }
      setPairId(mem.pair);
      setPhase("home");
    } catch {
      setPairId(null);
      setPhase("pair");
    }
  }, []);

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => {
    const boot = async () => {
      const token = await getToken();
      if (token) {
        await refreshPair();
      } else {
        setPhase("auth");
      }
    };
    boot();
    setOnAuth(onAuth);
  }, [refreshPair]);

  // Called by auth functions after successful sign-in.
  const onAuth = async (token: string, record: any) => {
    await setToken(token);
    await setUserId(record?.id ?? "");
    syncWidgetCredentials().catch(() => {});
    refreshPair();
  };

  const handleLogout = async () => {
    await clearToken();
    clearWidgetCredentials();
    setPhase("auth");
  };

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
      {phase === "pair" && <PairScreen userId={userId} onPaired={refreshPair} />}
      {phase === "home" && pairId && (
        <HomeScreen pairId={pairId} userId={userId} onLogout={handleLogout} onUnpaired={refreshPair} />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: "#FBF7EC" },
  center: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: "#FBF7EC" },
});

