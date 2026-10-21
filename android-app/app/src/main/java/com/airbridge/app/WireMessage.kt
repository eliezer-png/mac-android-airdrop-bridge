package com.airbridge.app

import org.json.JSONObject

/**
 * Mirrors the Mac agent's WireMessage shape - see ../../../../docs/PROTOCOL.md. Plain JSON
 * (org.json, built into Android) rather than a serialization library, since the shape is this
 * one flat, small struct.
 */
data class WireMessage(
    val type: String,
    val code: String? = null,
    val ok: Boolean? = null,
    val token: String? = null,
    val filename: String? = null,
    val bodyLength: Int? = null,
    val message: String? = null,
    val listenPort: Int? = null,
) {
    fun toJsonLine(): String {
        val json = JSONObject()
        json.put("type", type)
        code?.let { json.put("code", it) }
        ok?.let { json.put("ok", it) }
        token?.let { json.put("token", it) }
        filename?.let { json.put("filename", it) }
        bodyLength?.let { json.put("bodyLength", it) }
        message?.let { json.put("message", it) }
        listenPort?.let { json.put("listenPort", it) }
        return json.toString() + "\n"
    }

    companion object {
        fun fromJson(line: String): WireMessage {
            val json = JSONObject(line)
            return WireMessage(
                type = json.getString("type"),
                code = json.opt("code") as? String,
                ok = if (json.has("ok")) json.getBoolean("ok") else null,
                token = json.opt("token") as? String,
                filename = json.opt("filename") as? String,
                bodyLength = if (json.has("bodyLength")) json.getInt("bodyLength") else null,
                message = json.opt("message") as? String,
                listenPort = if (json.has("listenPort")) json.getInt("listenPort") else null,
            )
        }
    }
}
