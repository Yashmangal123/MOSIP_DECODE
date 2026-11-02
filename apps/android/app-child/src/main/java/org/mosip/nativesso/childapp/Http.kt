package org.mosip.nativesso.childapp

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

/** A minimal form POST. No third-party HTTP library, so the demo has nothing to configure. */
object Http {

    class Result(val status: Int, val body: String) {
        val ok: Boolean get() = status in 200..299
    }

    fun postForm(url: String, form: Map<String, String>): Result {
        val body = form.entries.joinToString("&") {
            java.net.URLEncoder.encode(it.key, "UTF-8") + "=" + java.net.URLEncoder.encode(it.value, "UTF-8")
        }
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 15000
            connection.readTimeout = 20000
            connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            connection.outputStream.use { it.write(body.toByteArray()) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = BufferedReader(InputStreamReader(stream ?: return Result(status, ""))).use { it.readText() }
            Result(status, text)
        } finally {
            connection.disconnect()
        }
    }

    fun get(url: String, bearer: String): Result {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 15000
            connection.readTimeout = 20000
            connection.setRequestProperty("Authorization", "Bearer $bearer")
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = BufferedReader(InputStreamReader(stream ?: return Result(status, ""))).use { it.readText() }
            Result(status, text)
        } finally {
            connection.disconnect()
        }
    }
}
