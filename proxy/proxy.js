#!/usr/bin/env node
// Anthropic API -> OpenAI-compatible proxy for claude-api local profiles.
// Forwards Claude Code's Anthropic /v1/messages calls to a llama-server
// OpenAI /v1/chat/completions endpoint.

const http = require("http");

const PORT = parseInt(process.env.LLAMA_PROXY_PORT || "4000", 10);
const OPENAI_BASE_URL = (process.env.LLAMA_OPENAI_BASE_URL || "http://localhost:8081/v1").replace(/\/$/, "");
const OPENAI_MODEL = process.env.LLAMA_OPENAI_MODEL || "Qwen3.5-0.8B-Q5_K_M";
const OPENAI_API_KEY = process.env.LLAMA_OPENAI_API_KEY || process.env.OPENAI_API_KEY || "no-key";
const LOG_LEVEL = (process.env.LLAMA_PROXY_LOG_LEVEL || "info").toLowerCase();

function log(level, ...args) {
  const levels = { error: 0, warn: 1, info: 2, debug: 3 };
  if ((levels[level] ?? 2) <= (levels[LOG_LEVEL] ?? 2)) {
    console.log(`[${new Date().toISOString()}] [${level.toUpperCase()}]`, ...args);
  }
}

function randomId(prefix) {
  return `${prefix}${Math.random().toString(36).slice(2)}${Date.now().toString(36)}`;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function parseJson(buf) {
  const str = buf.toString("utf8").trim();
  if (!str) return {};
  try {
    return JSON.parse(str);
  } catch (e) {
    throw new Error(`Invalid JSON body: ${e.message}`);
  }
}

function authOk(req) {
  // Accept any key; local llama-server usually ignores it.
  return true;
}

function convertTool(tool) {
  return {
    type: "function",
    function: {
      name: tool.name,
      description: tool.description || "",
      parameters: tool.input_schema || { type: "object", properties: {} },
    },
  };
}

function convertToolChoice(tc) {
  if (!tc) return undefined;
  if (tc.type === "auto") return "auto";
  if (tc.type === "any") return "required";
  if (tc.type === "tool" && tc.name) {
    return { type: "function", function: { name: tc.name } };
  }
  if (tc.type === "none") return "none";
  return "auto";
}

function convertMessages(anthropicBody) {
  const messages = [];
  if (anthropicBody.system) {
    if (typeof anthropicBody.system === "string") {
      messages.push({ role: "system", content: anthropicBody.system });
    } else if (Array.isArray(anthropicBody.system)) {
      const text = anthropicBody.system.map((s) => (typeof s === "string" ? s : s.text || "")).join("\n");
      if (text) messages.push({ role: "system", content: text });
    }
  }
  for (const m of anthropicBody.messages || []) {
    if (typeof m.content === "string") {
      messages.push({ role: m.role, content: m.content });
    } else if (Array.isArray(m.content)) {
      // Handle content arrays (text + image/tool_result). Keep it simple for local models.
      const parts = [];
      for (const part of m.content) {
        if (part.type === "text") parts.push({ type: "text", text: part.text });
        else if (part.type === "image") {
          parts.push({ type: "image_url", image_url: { url: part.source?.data ? `data:${part.source.media_type};base64,${part.source.data}` : "" } });
        } else if (part.type === "tool_result") {
          // Convert tool_result to a user message describing the result.
          messages.push({
            role: "tool",
            tool_call_id: part.tool_use_id,
            content: typeof part.content === "string" ? part.content : JSON.stringify(part.content),
          });
          continue;
        }
      }
      if (parts.length) messages.push({ role: m.role, content: parts });
    } else {
      messages.push(m);
    }
  }
  return messages;
}

function buildOpenAIBody(anthropicBody) {
  const body = {
    model: OPENAI_MODEL,
    messages: convertMessages(anthropicBody),
    stream: anthropicBody.stream === true,
  };
  if (anthropicBody.max_tokens != null) body.max_tokens = anthropicBody.max_tokens;
  if (anthropicBody.temperature != null) body.temperature = anthropicBody.temperature;
  if (anthropicBody.top_p != null) body.top_p = anthropicBody.top_p;
  if (anthropicBody.top_k != null) body.top_k = anthropicBody.top_k;
  if (anthropicBody.stop_sequences != null) body.stop = anthropicBody.stop_sequences;
  if (anthropicBody.tools?.length) {
    body.tools = anthropicBody.tools.map(convertTool);
    const tc = convertToolChoice(anthropicBody.tool_choice);
    if (tc) body.tool_choice = tc;
  }
  return body;
}

function openAIToAnthropicContent(message) {
  const content = [];
  if (message.content) content.push({ type: "text", text: message.content });
  for (const tc of message.tool_calls || []) {
    if (tc.type === "function") {
      content.push({
        type: "tool_use",
        id: tc.id,
        name: tc.function?.name,
        input: (() => {
          try {
            return JSON.parse(tc.function?.arguments || "{}");
          } catch {
            return {};
          }
        })(),
      });
    }
  }
  return content;
}

function finishReasonToAnthropic(fr) {
  if (fr === "tool_calls") return "tool_use";
  if (fr === "length") return "max_tokens";
  if (fr === "stop") return "end_turn";
  return null;
}

async function handleNonStreaming(res, openaiRes, anthropicBody) {
  const data = await openaiRes.json();
  log("debug", "OpenAI response:", JSON.stringify(data).slice(0, 500));
  const choice = data.choices?.[0];
  const message = choice?.message || {};
  const content = openAIToAnthropicContent(message);
  const stopReason = finishReasonToAnthropic(choice?.finish_reason);
  const usage = data.usage || {};

  const anthropicResponse = {
    id: data.id ? `msg_${data.id}` : randomId("msg_"),
    type: "message",
    role: "assistant",
    model: anthropicBody.model || "claude-local",
    content,
    stop_reason: stopReason,
    usage: {
      input_tokens: usage.prompt_tokens || 0,
      output_tokens: usage.completion_tokens || 0,
    },
  };

  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify(anthropicResponse));
}

function sendSSE(res, event, data) {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(data)}\n\n`);
}

async function handleStreaming(res, openaiRes, anthropicBody) {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    "Connection": "keep-alive",
  });

  const msgId = randomId("msg_");
  const model = anthropicBody.model || "claude-local";
  let inputTokens = 0;
  let outputTokens = 0;
  let currentBlockIndex = 0;
  let currentToolCall = null;
  const toolUseBlocks = new Map(); // index -> {id, name, args}

  sendSSE(res, "message_start", {
    type: "message_start",
    message: {
      id: msgId,
      type: "message",
      role: "assistant",
      model,
      content: [],
      stop_reason: null,
      usage: { input_tokens: 0 },
    },
  });

  const reader = openaiRes.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith(":")) continue;
        if (trimmed.startsWith("data: ")) {
          const payload = trimmed.slice(6);
          if (payload === "[DONE]") continue;
          try {
            const chunk = JSON.parse(payload);
            log("debug", "OpenAI chunk:", JSON.stringify(chunk).slice(0, 300));
            const delta = chunk.choices?.[0]?.delta || {};
            const finish = chunk.choices?.[0]?.finish_reason;

            if (chunk.usage) {
              inputTokens = chunk.usage.prompt_tokens || inputTokens;
              outputTokens = chunk.usage.completion_tokens || outputTokens;
            }

            // Text delta
            if (delta.content) {
              if (currentToolCall) {
                // Finish previous tool_call block before starting text
                sendSSE(res, "content_block_stop", { type: "content_block_stop", index: currentBlockIndex });
                currentBlockIndex++;
                currentToolCall = null;
              }
              sendSSE(res, "content_block_delta", {
                type: "content_block_delta",
                index: currentBlockIndex,
                delta: { type: "text_delta", text: delta.content },
              });
            }

            // Tool call delta
            if (delta.tool_calls?.length) {
              for (const tc of delta.tool_calls) {
                const idx = tc.index ?? 0;
                if (!toolUseBlocks.has(idx)) {
                  // Starting a new tool_use block
                  if (currentBlockIndex > 0 || currentToolCall) {
                    // Close any prior block if needed
                    if (currentToolCall) {
                      sendSSE(res, "content_block_stop", { type: "content_block_stop", index: currentBlockIndex });
                      currentBlockIndex++;
                    }
                  }
                  toolUseBlocks.set(idx, { id: tc.id || randomId("call_"), name: tc.function?.name || "", args: "" });
                  currentToolCall = idx;
                  sendSSE(res, "content_block_start", {
                    type: "content_block_start",
                    index: currentBlockIndex,
                    content_block: {
                      type: "tool_use",
                      id: toolUseBlocks.get(idx).id,
                      name: toolUseBlocks.get(idx).name,
                      input: {},
                    },
                  });
                }
                const block = toolUseBlocks.get(idx);
                if (tc.id && !block.id) block.id = tc.id;
                if (tc.function?.name) block.name = tc.function.name;
                if (tc.function?.arguments) {
                  block.args += tc.function.arguments;
                  let input = {};
                  try { input = JSON.parse(block.args); } catch {}
                  sendSSE(res, "content_block_delta", {
                    type: "content_block_delta",
                    index: currentBlockIndex,
                    delta: { type: "input_json_delta", partial_json: tc.function.arguments },
                  });
                }
              }
            }

            if (finish) {
              if (currentToolCall != null) {
                sendSSE(res, "content_block_stop", { type: "content_block_stop", index: currentBlockIndex });
              }
              const stopReason = finishReasonToAnthropic(finish);
              sendSSE(res, "message_delta", {
                type: "message_delta",
                delta: { stop_reason: stopReason },
                usage: { output_tokens: outputTokens },
              });
              sendSSE(res, "message_stop", { type: "message_stop" });
              res.end();
              return;
            }
          } catch (e) {
            log("warn", "Failed to parse SSE chunk:", e.message);
          }
        }
      }
    }
  } catch (e) {
    log("error", "Streaming error:", e.message);
  }

  // Normal stream end without finish_reason
  if (currentToolCall != null) {
    sendSSE(res, "content_block_stop", { type: "content_block_stop", index: currentBlockIndex });
  }
  sendSSE(res, "message_delta", {
    type: "message_delta",
    delta: { stop_reason: "end_turn" },
    usage: { output_tokens: outputTokens },
  });
  sendSSE(res, "message_stop", { type: "message_stop" });
  res.end();
}

async function handleMessages(req, res) {
  if (req.method !== "POST") {
    res.writeHead(405, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { type: "method_not_allowed", message: "Only POST is allowed" } }));
    return;
  }

  if (!authOk(req)) {
    res.writeHead(401, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { type: "authentication_error", message: "Invalid API key" } }));
    return;
  }

  let anthropicBody;
  try {
    const buf = await readBody(req);
    anthropicBody = parseJson(buf);
  } catch (e) {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { type: "invalid_request_error", message: e.message } }));
    return;
  }

  log("debug", "Anthropic request:", JSON.stringify(anthropicBody).slice(0, 500));

  const openaiBody = buildOpenAIBody(anthropicBody);
  log("info", `-> ${OPENAI_BASE_URL}/chat/completions model=${openaiBody.model} stream=${openaiBody.stream}`);

  try {
    const openaiRes = await fetch(`${OPENAI_BASE_URL}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify(openaiBody),
    });

    if (!openaiRes.ok) {
      const text = await openaiRes.text();
      log("error", "OpenAI backend error:", openaiRes.status, text.slice(0, 500));
      res.writeHead(openaiRes.status, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: { type: "api_error", message: text } }));
      return;
    }

    if (anthropicBody.stream) {
      await handleStreaming(res, openaiRes, anthropicBody);
    } else {
      await handleNonStreaming(res, openaiRes, anthropicBody);
    }
  } catch (e) {
    log("error", "Proxy error:", e.message);
    res.writeHead(502, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { type: "api_error", message: e.message } }));
  }
}

const server = http.createServer((req, res) => {
  const parsed = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  const pathname = parsed.pathname;
  log("debug", `${req.method} ${pathname}`);

  if (pathname === "/v1/messages") {
    handleMessages(req, res);
  } else if (pathname === "/health" || pathname === "/") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", proxy: "claude-api-llama", upstream: OPENAI_BASE_URL, model: OPENAI_MODEL }));
  } else {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { type: "not_found", message: `Unknown endpoint: ${pathname}` } }));
  }
});

server.listen(PORT, () => {
  log("info", `claude-api llama proxy listening on http://localhost:${PORT}`);
  log("info", `upstream: ${OPENAI_BASE_URL} model: ${OPENAI_MODEL}`);
});

server.on("error", (err) => {
  log("error", "Server error:", err.message);
  process.exit(1);
});
