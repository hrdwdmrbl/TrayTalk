# Smooth Talker Review TTS Worker

Private App Review demo proxy for Smooth Talker. The Mac app sends only an App Review demo token plus text/voice request data. Google service-account credentials stay in Worker secrets and are never returned to the app.

## Secrets

Set these before deploying:

```sh
npx wrangler secret put APP_REVIEW_DEMO_TOKEN
npx wrangler secret put GOOGLE_CLIENT_EMAIL
npx wrangler secret put GOOGLE_PRIVATE_KEY
```

Use a disposable Google Cloud project created only for Smooth Talker App Review, enable Cloud Text-to-Speech, add strict quota/budget limits, and revoke/delete the key or project after review.

## Endpoints

- `GET /v1/app-review/tts/voices`
- `POST /v1/app-review/tts/synthesize`

Both require:

```http
Authorization: Bearer <App Review demo token>
```

The synthesize endpoint accepts:

```json
{
  "text": "Gift Helper: Preparing the app and App Store information for App Review submission.",
  "languageCode": "en-US",
  "voiceName": "en-US-Chirp3-HD-Sadaltager",
  "audioEncoding": "MP3"
}
```

It returns only:

```json
{ "audioContent": "<base64 mp3>" }
```
