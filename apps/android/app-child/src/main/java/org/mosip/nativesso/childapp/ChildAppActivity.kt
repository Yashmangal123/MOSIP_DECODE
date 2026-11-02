package org.mosip.nativesso.childapp

import android.os.Bundle
import android.util.Base64
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject

/**
 * The Child App: it has no login screen at all.
 *
 * It receives the device secret handed over by the Super App and performs an RFC 8693 token exchange:
 *
 *     grant_type           = urn:ietf:params:oauth:grant-type:token-exchange
 *     subject_token        = <the device secret JWT>   ← the secret *is* the subject token
 *     subject_token_type   = urn:ietf:params:oauth:token-type:jwt
 *     requested_token_type = urn:ietf:params:oauth:token-type:access_token
 *
 * The authorization server answers with tokens for the same session, or with `interaction_required`
 * when that session can no longer be used silently — at which point a real app shows its login screen.
 */
class ChildAppActivity : AppCompatActivity() {

    private lateinit var status: TextView
    private lateinit var details: TextView
    private lateinit var exchange: Button

    private var deviceSecret: String = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply { textSize = 18f; setPadding(32, 48, 32, 8) }
        details = TextView(this).apply { textSize = 12f; setPadding(32, 8, 32, 24) }
        exchange = Button(this).apply { text = "Continue with this device" }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            addView(status); addView(exchange)
            addView(ScrollView(this@ChildAppActivity).apply { addView(details) })
        })

        deviceSecret = intent?.getStringExtra("device_secret").orEmpty()
        if (deviceSecret.isEmpty()) {
            status.text = "No device secret"
            details.text = "Open the Super App, sign in there, then press \"Open Child App\"."
            exchange.isEnabled = false
        } else {
            status.text = "Device secret received"
            details.text = "The Super App signed the citizen in. No code will be requested here."
            exchange.setOnClickListener { runExchange() }
            // A real app tries the silent exchange immediately; showing the button makes the demo clearer.
        }
    }

    private fun runExchange() {
        exchange.isEnabled = false
        status.text = "Exchanging the device secret…"
        Thread {
            val result = Http.postForm(Config.SERVER + "/oauth2/token", mapOf(
                "grant_type" to "urn:ietf:params:oauth:grant-type:token-exchange",
                "client_id" to Config.CLIENT_ID,
                "subject_token" to deviceSecret,
                "subject_token_type" to "urn:ietf:params:oauth:token-type:jwt",
                "requested_token_type" to "urn:ietf:params:oauth:token-type:access_token",
                "scope" to Config.SCOPE
            ))
            runOnUiThread { render(result) }
        }.start()
    }

    private fun render(result: Http.Result) {
        exchange.isEnabled = true
        if (!result.ok) {
            val error = try { JSONObject(result.body).optString("error") } catch (ignored: Exception) { "" }
            if (error == "interaction_required") {
                status.text = "interaction_required"
                details.text = "The session behind the device secret is gone. This is the flow working " +
                    "correctly: the app must now show its own login screen.\n\n${result.body}"
            } else {
                status.text = "Exchange failed (${result.status})"
                details.text = result.body
            }
            return
        }
        val body = JSONObject(result.body)
        status.text = "Signed in — no code requested"
        details.text = buildString {
            appendLine("UIN (sub): ${claims(body.optString("id_token"))["sub"]}")
            appendLine("sid: ${body.optString("sid")}")
            appendLine("scope: ${body.optString("scope")}")
            appendLine("refresh_token: ${if (body.optString("refresh_token").isEmpty()) "none" else "issued"}")
            appendLine("issued_token_type: ${body.optString("issued_token_type")}")
            appendLine()
            appendLine("The sid above is the same session the Super App created: one sign-in, two apps.")
        }
    }

    private fun claims(jwt: String): Map<String, String> = try {
        val json = JSONObject(String(Base64.decode(jwt.split(".")[1], Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)))
        json.keys().asSequence().associateWith { json.optString(it) }
    } catch (ignored: Exception) {
        emptyMap()
    }
}
