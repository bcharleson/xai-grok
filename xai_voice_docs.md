# xAI Grok Voice Agent API Documentation
*Scraped Source: https://docs.x.ai/docs/guides/voice*

## Overview
The Grok Voice Agent API enables real-time, interactive voice conversations with Grok models via WebSocket. It is designed for applications requiring low-latency, natural voice interactions.

**Base Endpoint:** `wss://api.x.ai/v1/realtime`

## Key Capabilities
*   **Low Latency:** Optimized for bidirectional streaming.
*   **Multilingual:** Automatically detects and speaks 100+ languages.
*   **Tool Calling:** Supports Web Search, X Search, RAG (Collections), and Custom Functions.
*   **Telephony Ready:** Integrates with Twilio, Vonage, etc.

## Voice Personalities
The API provides several voice presets with distinct characteristics:

| Voice | Gender | Tone | Description |
| :--- | :--- | :--- | :--- |
| **Ara** | Female | Warm, Friendly | Default voice, balanced for general use. |
| **Rex** | Male | Confident, Clear | Professional, ideal for business use cases. |
| **Sal** | Neutral | Smooth, Balanced | Versatile and adaptable. |
| **Eve** | Female | Energetic, Upbeat | Great for engaging, dynamic interactions. |
| **Leo** | Male | Authoritative | Decisive, good for instructions or command. |

## Technical Specifications

### Audio Formats
*   **Input/Output:** 
    *   PCM (Linear16) - Sample rates: 8kHz to 48kHz.
    *   G.711 μ-law (Telephony standard).
    *   G.711 A-law.
*   **Encoding:** Audio data sent over WebSocket must be base64-encoded strings.

### Architecture Patterns
1.  **Web/Native Agent:** Client records audio -> WebSocket -> xAI API -> Audio Response -> Playback.
2.  **Phone/SIP:** SIP Provider (Twilio) -> WebSocket -> xAI API.

## Implementation Considerations for Grok Code
*   **Protocol:** WebSocket (`wss://api.x.ai/v1/realtime`).
*   **Audio Handling:** Requires real-time microphone capture (Linear16 PCM) and base64 encoding/decoding.
*   **VAD:** Voice Activity Detection might be needed on client-side or handled by the server (server-side turn-taking is common in these APIs).
*   **Authentication:** Likely uses the same API Key Authorization header as the REST API.

*Note: Access to the deep technical guide `guides/voice/agent` was restricted during scraping, so precise JSON message schemas for the WebSocket events (e.g. `session.update`, `input_audio_buffer.append`) will need to be verified or inferred from similar real-time API standards (often similar to OpenAI Realtime).*
