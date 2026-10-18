package com.example.safe_at_home

internal data class PlanAssistantRequest(
    val requestId: String, val locale: String, val question: String,
    val history: String, val findings: String,
) {
    companion object {
        val locales = setOf("en", "es", "zh-Hans", "zh-Hant", "vi", "fil")
        fun parse(value: Any?): PlanAssistantRequest? {
            val v = value as? Map<*, *> ?: return null
            if (v.keys != setOf("requestId", "locale", "question", "history", "findings")) return null
            val id = requestId(mapOf("requestId" to v["requestId"])) ?: return null
            val locale = v["locale"] as? String ?: return null
            val question = v["question"] as? String ?: return null
            val history = v["history"] as? String ?: return null
            val findings = v["findings"] as? String ?: return null
            if (locale !in locales || question.isBlank() ||
                !boundedText(question, 600) || !boundedText(history, 2400) || !boundedText(findings, 2400) ||
                question.toByteArray(Charsets.UTF_8).size + history.toByteArray(Charsets.UTF_8).size +
                    findings.toByteArray(Charsets.UTF_8).size > 10_000) return null
            return PlanAssistantRequest(id, locale, question, history, findings)
        }
        fun requestId(value: Any?): String? {
            val v = value as? Map<*, *> ?: return null
            if (v.keys != setOf("requestId")) return null
            return (v["requestId"] as? String)?.takeIf(BathroomScanGeometry::isScanId)
        }
        private fun boundedText(value: String, max: Int): Boolean {
            if (value.codePointCount(0, value.length) > max) return false
            var index = 0
            while (index < value.length) {
                val ch = value[index++]
                if (ch.isHighSurrogate()) {
                    if (index >= value.length || !value[index++].isLowSurrogate()) return false
                } else if (ch.isLowSurrogate()) return false
            }
            return true
        }
    }
}
