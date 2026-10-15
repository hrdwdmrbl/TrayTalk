# Smooth Talker App Review Notes

## Suggested App Review Notes

Smooth Talker is an assistive text-to-speech app for reading selected text aloud on macOS.

Accessibility permission is required only so Smooth Talker can identify the user's currently selected text after the user presses the configured assistive reading shortcut. The app does not track typing, monitor background activity, automate unrelated apps, or use Accessibility for analytics.

Smooth Talker does not require a first-party account and does not have a Smooth Talker account system.

For App Review, please use the populated App Review Demo Mode instead of connecting a personal Google Cloud account:

1. Launch Smooth Talker.
2. Grant Accessibility permission when prompted.
3. In the Google Cloud setup screen, choose "App Review Demo".
4. Enter this demo code: `<APP_REVIEW_DEMO_CODE>`
5. Smooth Talker will load a populated demo state with sample text, `en-US`, speaking speed `1.0x`, Premium Voices access, and the `en-US-Chirp3-HD-Sadaltager` voice selected.
6. Use the Speak button or select text in another app and press the configured keyboard shortcut.

App Review Demo Mode uses a disposable Google Cloud Text-to-Speech project controlled by the developer. Smooth Talker sends demo text-to-speech requests to a private developer endpoint, and the endpoint performs the Google Cloud Text-to-Speech request server-side. The app receives only voice metadata and generated MP3 audio. No Google service-account JSON, private key, or reviewer Google credentials are delivered to or bundled with Smooth Talker.

Google is not used to create or authenticate a Smooth Talker primary account. The Google authorization flow is only a user-initiated Google Cloud Text-to-Speech setup step so the user can connect their own Google Cloud account and configure Text-to-Speech credentials for voice synthesis.

No Google user data is stored on developer servers. Google service-account credentials generated during setup are stored locally on the user's Mac.

Normal users can still use the standard Google Cloud setup flow with their own Google Cloud account. To test that optional normal-user setup flow directly, please use a Google account that has permission to create and manage Google Cloud projects, enable Google Cloud APIs, link billing, and create service-account keys.

Smooth Talker uses `com.apple.security.network.server` only for its user-initiated Google Cloud Text-to-Speech Automatic Setup flow.

During Google OAuth authorization, Smooth Talker temporarily starts a local HTTP loopback listener on `127.0.0.1` using an ephemeral port. The browser redirects the OAuth authorization result to `http://127.0.0.1:<port>/oauth2redirect`, allowing Smooth Talker to receive the authorization code and finish Google Cloud Text-to-Speech setup.

This is not a public web server. The listener binds only to `127.0.0.1`, is not reachable from other devices on the network, accepts only the local OAuth callback, returns a short completion page, and closes immediately after the callback, cancellation, or setup failure.

The implementation is in `GoogleCloudSetupManager.swift`, in `GoogleOAuthAuthenticator.authenticate` and `GoogleOAuthLoopbackServer`.

## Resolution Center Reply

Hello,

Smooth Talker does not use Google to create or authenticate a primary account with Smooth Talker. Smooth Talker does not require a first-party account and does not have an app account system.

For App Review, please use the populated App Review Demo Mode. In the Google Cloud setup screen, choose "App Review Demo" and enter this demo code: `<APP_REVIEW_DEMO_CODE>`.

App Review Demo Mode is already provisioned for review access and does not require a reviewer-owned Google account, Google verification code, or Google Cloud setup. After the demo code is accepted, Smooth Talker loads sample text, `en-US`, speaking speed `1.0x`, Premium Voices access, and the `en-US-Chirp3-HD-Sadaltager` voice so the reviewer can immediately inspect and test the app's main content and features. Smooth Talker authenticates to our private demo Text-to-Speech endpoint with the fixed demo code. The endpoint then performs Google Cloud Text-to-Speech requests server-side using a disposable App Review Google Cloud project controlled by the developer. Smooth Talker receives only voice metadata and generated MP3 audio. Google service-account JSON and private keys remain server-side and are not bundled with or returned to the app.

The normal Google authorization flow remains available only for normal users who choose to connect their own Google Cloud account. The user authorizes Google Cloud so Smooth Talker can create/configure Text-to-Speech resources in the user's own Google Cloud account and store the generated service-account credentials locally on the user's Mac. No Google user data is stored on developer servers.

Because Google is not used to set up or authenticate a primary Smooth Talker account, we believe Guideline 4.8 does not apply to this flow.

We also resolved the setup bug in the reviewed build. The previous build could fail to start Google authorization because the production Google OAuth client configuration was missing from the Release archive. The new build validates the OAuth configuration at build/archive time and includes the required production Google OAuth configuration.

If App Review wants to test the optional normal-user Google Cloud setup flow directly, please use a Google account that has permission to create/manage Google Cloud projects, enable APIs, link billing, and create service-account keys.

Smooth Talker does require `com.apple.security.network.server` for a limited, user-initiated localhost OAuth callback used during Google Cloud Text-to-Speech Automatic Setup.

The app temporarily starts a local HTTP listener bound only to `127.0.0.1` on an ephemeral port. Google OAuth redirects the authorization result to `http://127.0.0.1:<port>/oauth2redirect` so Smooth Talker can receive the authorization code and complete setup. The listener is not a public web server, is not reachable from other devices, accepts only the local OAuth callback, and closes immediately after the callback, cancellation, or setup failure.

The relevant implementation is in `GoogleCloudSetupManager.swift`:

- `GoogleOAuthAuthenticator.authenticate` creates the loopback server and passes its redirect URI into `ASWebAuthenticationSession`.
- `GoogleOAuthLoopbackServer` binds to `127.0.0.1`, listens on an ephemeral port, accepts one request, writes the local completion response, and closes the socket.

We have also added this explanation to the App Review Information section in App Store Connect.

Thank you.

## Build Configuration Verification

- Production Google OAuth values are loaded from `Config/GoogleOAuth.local.xcconfig`, which is intentionally untracked.
- The tracked `Config/GoogleOAuth.xcconfig` provides empty defaults and optionally includes the local file.
- Release builds run `Config/validate-google-oauth-config.sh` and fail if `GOOGLE_OAUTH_CLIENT_ID` or `GOOGLE_OAUTH_CLIENT_SECRET` is missing or still a placeholder.
- Before resubmitting, inspect the built app's `Info.plist` and confirm `GoogleOAuthClientID` and `GoogleOAuthClientSecret` are populated.

## Network Server Entitlement Verification

- `GoogleOAuthLoopbackServer` binds to `127.0.0.1` only in `TrayTalk/GoogleCloudSetupManager.swift`.
- The listener uses port `0`, so macOS assigns an ephemeral local port, and the redirect path is `/oauth2redirect`.
- The OAuth callback flow calls `bind`, `listen`, and `accept`, so the sandboxed app requires incoming network access for this local listener.
- The listener accepts one request, writes a short local HTML completion response, then closes the client socket and listening socket.
- The listening socket is closed by the normal `defer` path, explicit cancellation, callback completion, and `deinit`.
- The Release build setting `ENABLE_INCOMING_NETWORK_CONNECTIONS = YES` generates `com.apple.security.network.server` in the signed app entitlements.
- The Release build setting `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` generates `com.apple.security.network.client` for Google Cloud API calls.
- Before resubmitting, inspect the archived distribution app with:

```sh
codesign -d --entitlements :- "path/to/Smooth Talker.app"
```

- Confirm the distribution archive includes both `com.apple.security.network.server` and `com.apple.security.network.client`.
- Confirm the distribution archive does not include unintended development-only entitlements such as `com.apple.security.get-task-allow`.

Local verification performed:

```sh
xcodebuild -project TrayTalk.xcodeproj -scheme TrayTalk -configuration Release -showBuildSettings | rg "CODE_SIGN_ENTITLEMENTS|ENABLE_APP_SANDBOX|ENABLE_INCOMING_NETWORK_CONNECTIONS|ENABLE_OUTGOING_NETWORK_CONNECTIONS|CONFIGURATION"
codesign -d --entitlements :- "/tmp/TrayTalkDerivedData/Build/Products/Release/Smooth Talker.app" 2>/dev/null | plutil -p -
```

Observed Release settings:

```text
CODE_SIGN_ENTITLEMENTS = TrayTalk/TrayTalk.entitlements
CONFIGURATION = Release
ENABLE_APP_SANDBOX = YES
ENABLE_INCOMING_NETWORK_CONNECTIONS = YES
ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES
```

Observed local development-signed Release entitlements:

```text
com.apple.security.app-sandbox = true
com.apple.security.files.user-selected.read-only = true
com.apple.security.get-task-allow = true
com.apple.security.network.client = true
com.apple.security.network.server = true
```

Note: `com.apple.security.get-task-allow` is present in the local development-signed Release build inspected above. It should not be present in the distribution-signed App Store archive.

## Suggested App Store Metadata

Short description:

Assistive text-to-speech for selected text on macOS.

Description line:

Provides assistive reading support by reading selected text aloud when the user invokes the shortcut.

## Suggested Demo Video Checklist

- Show first launch with the assistive Accessibility explanation.
- Click Open Accessibility and enable Smooth Talker in macOS Privacy & Security > Accessibility.
- Click Connect Google Cloud and complete the Google OAuth authorization flow.
- Show OAuth returning to Smooth Talker and Google Cloud Text-to-Speech setup completing.
- Select text in another app.
- Press the configured shortcut once.
- Show Smooth Talker speaking only the selected text.
