import * as AppleAuthentication from "expo-apple-authentication";
import * as AuthSession from "expo-auth-session";
import * as Crypto from "expo-crypto";
import * as WebBrowser from "expo-web-browser";
import { pb, PB_URL } from "./pb";

WebBrowser.maybeCompleteAuthSession();

// ---------------------------------------------------------------------------
// Sign in with Apple (native) -> custom server endpoint that verifies the
// identity token against Apple's JWKS and links/creates the user by email.
// ---------------------------------------------------------------------------

export async function signInWithApple(): Promise<void> {
  const nonce =
    Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
  const hashedNonce = await Crypto.digestStringAsync(
    Crypto.CryptoDigestAlgorithm.SHA256,
    nonce
  );

  const credential = await AppleAuthentication.signInAsync({
    requestedScopes: [
      AppleAuthentication.AppleAuthenticationScope.FULL_NAME,
      AppleAuthentication.AppleAuthenticationScope.EMAIL,
    ],
    nonce: hashedNonce,
  });
  if (!credential.identityToken) {
    throw new Error("Apple returned no identity token");
  }

  // Apple only sends the name + email on the FIRST authorization, so capture
  // them here and forward to the server for the freshly created account.
  const displayName = [credential.fullName?.givenName, credential.fullName?.familyName]
    .filter(Boolean)
    .join(" ");

  const res = await fetch(`${PB_URL}/api/peard/auth/apple`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      identity_token: credential.identityToken,
      nonce,
      display_name: displayName,
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error((data as any)?.message ?? `Apple sign-in failed (${res.status})`);
  }
  pb.authStore.save(data.token, data.record);
}

// ---------------------------------------------------------------------------
// Sign in with Google (OIDC authorization code + PKCE) -> PocketBase's
// built-in OAuth2 code exchange, which links to the same user by verified
// email. Requires an "iOS application" OAuth client in Google Cloud whose
// bundle id matches, and the same client id set on the users collection's
// Google provider in PocketBase (see README).
// ---------------------------------------------------------------------------

const GOOGLE_IOS_CLIENT_ID = process.env.EXPO_PUBLIC_GOOGLE_IOS_CLIENT_ID ?? "";

const googleDiscovery: AuthSession.DiscoveryDocument = {
  authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
  tokenEndpoint: "https://oauth2.googleapis.com/token",
  revocationEndpoint: "https://oauth2.googleapis.com/revoke",
};

export async function signInWithGoogle(): Promise<void> {
  if (!GOOGLE_IOS_CLIENT_ID) {
    throw new Error("Set EXPO_PUBLIC_GOOGLE_IOS_CLIENT_ID in app/.env first");
  }
  // Custom scheme registered in the OAuth client's allowed_redirect_uris.
  const redirectUri = AuthSession.makeRedirectUri({
    scheme: "peard",
    path: "auth/google",
  });

  const request = new AuthSession.AuthRequest({
    clientId: GOOGLE_IOS_CLIENT_ID,
    redirectUri,
    scopes: ["openid", "profile", "email"],
    responseType: AuthSession.ResponseType.Code,
    usePKCE: true,
  });
  const result = await request.promptAsync(googleDiscovery);
  if (result.type !== "success" || !result.params.code) {
    throw new Error("Google sign-in cancelled");
  }

  await pb
    .collection("users")
    .authWithOAuth2Code(
      "google",
      result.params.code,
      request.codeVerifier ?? "",
      redirectUri
    );
}

// ---------------------------------------------------------------------------
// Debug-only: password-authenticate a fixed test user.
// Only compiled into __DEV__ builds — the AuthScreen button is gated too.
// ---------------------------------------------------------------------------

const TEST_EMAIL = "test@peard.local";
const TEST_PASSWORD = "test1234";

export async function signInAsTestUser(): Promise<void> {
  try {
    // Register the test user (may already exist — PocketBase returns 400
    // on duplicate email, which we ignore).
    await pb.collection("users").create({
      email: TEST_EMAIL,
      password: TEST_PASSWORD,
      passwordConfirm: TEST_PASSWORD,
      display_name: "Test User",
    });
  } catch {
    // user already exists — that's fine
  }
  await pb.collection("users").authWithPassword(TEST_EMAIL, TEST_PASSWORD);
}
