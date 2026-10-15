import { describe, expect, it, vi } from "vitest";
import worker, { type ReviewTTSEnv } from "../src/index";

const testEnv: ReviewTTSEnv = {
	APP_REVIEW_DEMO_ENABLED: "true",
	APP_REVIEW_DEMO_TOKEN: "review-token",
	GOOGLE_CLIENT_EMAIL: "review-tts@example.iam.gserviceaccount.com",
	GOOGLE_PRIVATE_KEY: [
		"-----BEGIN PRIVATE KEY-----",
		"MIIEvQIBADANBgkqhkiG9w0BAQEFAASC",
		"-----END PRIVATE KEY-----"
	].join("\n")
};

describe("Smooth Talker review TTS worker", () => {
	it("rejects missing demo token", async () => {
		const response = await worker.fetch(new Request("https://example.com/v1/app-review/tts/voices"), testEnv);

		expect(response.status).toBe(403);
	});

	it("rejects wrong demo token", async () => {
		const response = await worker.fetch(
			new Request("https://example.com/v1/app-review/tts/synthesize", {
				method: "POST",
				headers: { Authorization: "Bearer wrong-token" },
				body: JSON.stringify({ text: "Hello", languageCode: "en-US", voiceName: "en-US-Standard-A" })
			}),
			testEnv
		);

		expect(response.status).toBe(403);
	});

	it("returns 503 when demo mode is disabled", async () => {
		const response = await worker.fetch(
			new Request("https://example.com/v1/app-review/tts/voices", {
				headers: { Authorization: "Bearer review-token" }
			}),
			{ ...testEnv, APP_REVIEW_DEMO_ENABLED: "false" }
		);

		expect(response.status).toBe(503);
	});

	it("proxies voice metadata without returning credentials", async () => {
		const originalFetch = globalThis.fetch;
		vi.stubGlobal(
			"fetch",
			vi
				.fn()
				.mockResolvedValueOnce(
					new Response(JSON.stringify({ access_token: "google-access-token" }), {
						status: 200,
						headers: { "Content-Type": "application/json" }
					})
				)
				.mockResolvedValueOnce(
					new Response(
						JSON.stringify({
							voices: [
								{
									name: "en-US-Chirp3-HD-Sadaltager",
									languageCodes: ["en-US"],
									ssmlGender: "MALE",
									naturalSampleRateHertz: 24000
								}
							]
						}),
						{ status: 200, headers: { "Content-Type": "application/json" } }
					)
				)
		);

		try {
			vi.spyOn(crypto.subtle, "importKey").mockResolvedValue({} as CryptoKey);
			vi.spyOn(crypto.subtle, "sign").mockResolvedValue(new Uint8Array([1, 2, 3]).buffer);

			const response = await worker.fetch(
				new Request("https://example.com/v1/app-review/tts/voices", {
					headers: { Authorization: "Bearer review-token" }
				}),
				testEnv
			);
			const body = await response.json();

			expect(response.status).toBe(200);
			expect(body).toEqual({
				voices: [
					{
						name: "en-US-Chirp3-HD-Sadaltager",
						languageCodes: ["en-US"],
						ssmlGender: "MALE",
						naturalSampleRateHertz: 24000
					}
				]
			});
			expect(JSON.stringify(body)).not.toContain("PRIVATE KEY");
			expect(JSON.stringify(body)).not.toContain("review-tts@example.iam.gserviceaccount.com");
		} finally {
			vi.restoreAllMocks();
			globalThis.fetch = originalFetch;
		}
	});

	it("proxies synthesize audio only", async () => {
		const originalFetch = globalThis.fetch;
		const fetchMock = vi
			.fn()
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ access_token: "google-access-token" }), {
					status: 200,
					headers: { "Content-Type": "application/json" }
				})
			)
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ audioContent: "bXAz" }), {
					status: 200,
					headers: { "Content-Type": "application/json" }
				})
			);

		vi.stubGlobal("fetch", fetchMock);

		try {
			vi.spyOn(crypto.subtle, "importKey").mockResolvedValue({} as CryptoKey);
			vi.spyOn(crypto.subtle, "sign").mockResolvedValue(new Uint8Array([1, 2, 3]).buffer);

			const response = await worker.fetch(
				new Request("https://example.com/v1/app-review/tts/synthesize", {
					method: "POST",
					headers: {
						Authorization: "Bearer review-token",
						"Content-Type": "application/json"
					},
					body: JSON.stringify({
						text: "Gift Helper: Preparing the app and App Store information for App Review submission.",
						languageCode: "en-US",
						voiceName: "en-US-Chirp3-HD-Sadaltager",
						audioEncoding: "MP3"
					})
				}),
				testEnv
			);
			const body = await response.json();
			const googleRequest = fetchMock.mock.calls[1][1] as RequestInit;

			expect(response.status).toBe(200);
			expect(body).toEqual({ audioContent: "bXAz" });
			expect(JSON.parse(googleRequest.body as string)).toMatchObject({
				audioConfig: {
					audioEncoding: "MP3",
					speakingRate: 1.0
				}
			});
			expect(JSON.stringify(body)).not.toContain("PRIVATE KEY");
		} finally {
			vi.restoreAllMocks();
			globalThis.fetch = originalFetch;
		}
	});
});
