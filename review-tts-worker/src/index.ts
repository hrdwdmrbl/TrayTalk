const googleTokenURL = "https://oauth2.googleapis.com/token";
const googleVoicesURL = "https://texttospeech.googleapis.com/v1/voices";
const googleSynthesizeURL = "https://texttospeech.googleapis.com/v1/text:synthesize";
const googleScope = "https://www.googleapis.com/auth/cloud-platform";

export interface ReviewTTSEnv extends Omit<Env, "APP_REVIEW_DEMO_ENABLED"> {
	APP_REVIEW_DEMO_ENABLED?: string;
	APP_REVIEW_DEMO_TOKEN?: string;
	GOOGLE_CLIENT_EMAIL?: string;
	GOOGLE_PRIVATE_KEY?: string;
}

interface SynthesizeRequest {
	text: string;
	languageCode: string;
	voiceName: string;
	audioEncoding?: "MP3";
}

interface GoogleAccessTokenResponse {
	access_token?: string;
	error?: string;
	error_description?: string;
}

export default {
	async fetch(request: Request, env: ReviewTTSEnv): Promise<Response> {
		try {
			return await route(request, env);
		} catch (error) {
			return errorResponse(error);
		}
	}
};

async function route(request: Request, env: ReviewTTSEnv): Promise<Response> {
	if (request.method === "OPTIONS") return json({});

	const url = new URL(request.url);
	const path = url.pathname.replace(/\/$/, "");

	if (path !== "/v1/app-review/tts/voices" && path !== "/v1/app-review/tts/synthesize") {
		return json({ error: "Not found" }, 404);
	}

	await requireDemoAccess(request, env);

	if (request.method === "GET" && path === "/v1/app-review/tts/voices") {
		return proxyVoices(request, env);
	}

	if (request.method === "POST" && path === "/v1/app-review/tts/synthesize") {
		return proxySynthesize(request, env);
	}

	return json({ error: "Method not allowed" }, 405, { Allow: path.endsWith("/voices") ? "GET" : "POST" });
}

async function proxyVoices(request: Request, env: ReviewTTSEnv): Promise<Response> {
	const token = await googleAccessToken(env);
	const requestURL = new URL(request.url);
	const googleURL = new URL(googleVoicesURL);
	const languageCode = requestURL.searchParams.get("languageCode");
	if (languageCode) {
		googleURL.searchParams.set("languageCode", languageCode);
	}

	const response = await fetch(googleURL, {
		headers: {
			Authorization: `Bearer ${token}`
		}
	});

	return googleJSONResponse(response);
}

async function proxySynthesize(request: Request, env: ReviewTTSEnv): Promise<Response> {
	const body = await parseSynthesizeRequest(request);
	const token = await googleAccessToken(env);

	const response = await fetch(googleSynthesizeURL, {
		method: "POST",
		headers: {
			Authorization: `Bearer ${token}`,
			"Content-Type": "application/json"
		},
		body: JSON.stringify({
			input: {
				text: body.text
			},
			voice: {
				languageCode: body.languageCode,
				name: body.voiceName
			},
			audioConfig: {
				audioEncoding: "MP3",
				speakingRate: 1.0
			}
		})
	});

	return googleJSONResponse(response);
}

async function parseSynthesizeRequest(request: Request): Promise<SynthesizeRequest> {
	let value: unknown;
	try {
		value = await request.json();
	} catch {
		throw new ApiError(400, "Invalid JSON");
	}

	if (!isRecord(value)) throw new ApiError(400, "Invalid request body");

	const text = stringValue(value.text, "text");
	const languageCode = stringValue(value.languageCode, "languageCode");
	const voiceName = stringValue(value.voiceName, "voiceName");
	const audioEncoding = value.audioEncoding;

	if (text.length === 0 || text.length > 5000) throw new ApiError(400, "text must be 1-5000 characters");
	if (languageCode.length === 0 || languageCode.length > 32) throw new ApiError(400, "languageCode is invalid");
	if (voiceName.length === 0 || voiceName.length > 128) throw new ApiError(400, "voiceName is invalid");
	if (audioEncoding !== undefined && audioEncoding !== "MP3") throw new ApiError(400, "Only MP3 audio is supported");

	return { text, languageCode, voiceName, audioEncoding: "MP3" };
}

async function googleAccessToken(env: ReviewTTSEnv): Promise<string> {
	const clientEmail = requiredSecret(env.GOOGLE_CLIENT_EMAIL, "GOOGLE_CLIENT_EMAIL");
	const privateKey = requiredSecret(env.GOOGLE_PRIVATE_KEY, "GOOGLE_PRIVATE_KEY");
	const assertion = await serviceAccountJWT(clientEmail, privateKey);

	const response = await fetch(googleTokenURL, {
		method: "POST",
		headers: {
			"Content-Type": "application/x-www-form-urlencoded"
		},
		body: new URLSearchParams({
			grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
			assertion
		}).toString()
	});

	const tokenBody = (await response.json()) as GoogleAccessTokenResponse;
	if (!response.ok || !tokenBody.access_token) {
		throw new ApiError(502, tokenBody.error_description ?? tokenBody.error ?? "Google authentication failed");
	}

	return tokenBody.access_token;
}

async function serviceAccountJWT(clientEmail: string, privateKeyPEM: string): Promise<string> {
	const now = Math.floor(Date.now() / 1000);
	const encodedHeader = base64URLJSON({ alg: "RS256", typ: "JWT" });
	const encodedClaims = base64URLJSON({
		iss: clientEmail,
		scope: googleScope,
		aud: googleTokenURL,
		iat: now,
		exp: now + 3600
	});
	const signingInput = `${encodedHeader}.${encodedClaims}`;
	const key = await importPrivateKey(privateKeyPEM);
	const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(signingInput));

	return `${signingInput}.${base64URLBytes(new Uint8Array(signature))}`;
}

async function importPrivateKey(privateKeyPEM: string): Promise<CryptoKey> {
	const normalized = privateKeyPEM.replace(/\\n/g, "\n");
	const base64 = normalized
		.replace("-----BEGIN PRIVATE KEY-----", "")
		.replace("-----END PRIVATE KEY-----", "")
		.replace(/\s+/g, "");
	const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));

	return crypto.subtle.importKey(
		"pkcs8",
		bytes,
		{
			name: "RSASSA-PKCS1-v1_5",
			hash: "SHA-256"
		},
		false,
		["sign"]
	);
}

async function googleJSONResponse(response: Response): Promise<Response> {
	const responseBody = await response.text();
	const headers = { "Content-Type": "application/json; charset=utf-8" };

	if (!response.ok) {
		return new Response(responseBody, { status: response.status, headers });
	}

	return new Response(responseBody, { status: 200, headers });
}

async function requireDemoAccess(request: Request, env: ReviewTTSEnv): Promise<void> {
	if (env.APP_REVIEW_DEMO_ENABLED !== "true") {
		throw new ApiError(503, "App Review demo mode is disabled");
	}

	const expectedToken = requiredSecret(env.APP_REVIEW_DEMO_TOKEN, "APP_REVIEW_DEMO_TOKEN");
	const providedToken = bearerToken(request);
	if (!providedToken || !(await timingSafeEqual(providedToken, expectedToken))) {
		throw new ApiError(403, "Forbidden");
	}
}

function bearerToken(request: Request): string {
	const authorization = request.headers.get("Authorization") ?? "";
	const match = authorization.match(/^Bearer\s+(.+)$/i);
	return match?.[1]?.trim() ?? "";
}

function requiredSecret(value: string | undefined, name: string): string {
	if (!value) throw new ApiError(503, `Missing required configuration: ${name}`);
	return value;
}

async function timingSafeEqual(left: string, right: string): Promise<boolean> {
	const encoder = new TextEncoder();
	const [leftDigest, rightDigest] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(left)),
		crypto.subtle.digest("SHA-256", encoder.encode(right))
	]);
	const leftBytes = new Uint8Array(leftDigest);
	const rightBytes = new Uint8Array(rightDigest);
	let difference = leftBytes.length ^ rightBytes.length;

	for (let index = 0; index < Math.max(leftBytes.length, rightBytes.length); index += 1) {
		difference |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
	}

	return difference === 0;
}

function stringValue(value: unknown, field: string): string {
	if (typeof value !== "string") throw new ApiError(400, `${field} is required`);
	return value.trim();
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function json(body: unknown, status = 200, extraHeaders: HeadersInit = {}): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: {
			"Content-Type": "application/json; charset=utf-8",
			...extraHeaders
		}
	});
}

function errorResponse(error: unknown): Response {
	if (error instanceof ApiError) {
		return json({ error: error.message }, error.status);
	}

	console.error(error);
	return json({ error: "Internal server error" }, 500);
}

class ApiError extends Error {
	constructor(
		readonly status: number,
		message: string
	) {
		super(message);
	}
}

function base64URLJSON(value: unknown): string {
	return base64URLBytes(new TextEncoder().encode(JSON.stringify(value)));
}

function base64URLBytes(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}

	return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
