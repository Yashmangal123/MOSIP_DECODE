package org.mosip.nativesso.superapp

import android.annotation.SuppressLint
import android.content.Intent
import android.os.Bundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The Super App: the one that signs the citizen in.
 *
 * Flow: authorization request (PKCE + scope=device_sso) in a WebView → the citizen verifies an OTP →
 * consent → the redirect carries an authorization code → the code is exchanged for tokens, and because
 * device_sso was granted the answer also carries the device_secret: a JWT whose session_data names the
 * session. The secret is kept encrypted with an Android Keystore key, and handed to a trusted app.
 */
class SuperAppActivity : AppCompatActivity() {

    private lateinit var status: TextView
    private lateinit var details: TextView
    private lateinit var signIn: Button
    private lateinit var handOff: Button
    private lateinit var web: WebView

    private var verifier: String = ""
    private var state: String = ""
    private var tokens: JSONObject? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply { text = "Not signed in"; textSize = 18f; setPadding(32, 48, 32, 8) }
        details = TextView(this).apply { textSize = 12f; setPadding(32, 8, 32, 24) }
        signIn = Button(this).apply { text = "Sign in with eSignet" }
        handOff = Button(this).apply { text = "Open Child App (no login)"; isEnabled = false }
        web = WebView(this).apply { layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f) }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(status); addView(signIn); addView(handOff)
            addView(ScrollView(this@SuperAppActivity).apply { addView(details) })
            addView(web)
        }
        setContentView(root)

        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = false
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val url = request?.url?.toString() ?: return false
                if (url.startsWith(Config.REDIRECT_URI)) {
                    web.visibility = android.view.View.GONE
                    onRedirect(url)
                    return true
                }
                return false
            }
        }

        signIn.setOnClickListener { startAuthorization() }
        handOff.setOnClickListener { openChildApp() }

        restore()
    }

    /** Builds the authorization request: PKCE challenge, state, and scope=device_sso. */
    private fun startAuthorization() {
        web.visibility = android.view.View.VISIBLE
        verifier = randomString(48)
        state = randomString(16)
        val challenge = base64Url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray()))
        val url = Config.SERVER + "/oauth2/authorize" +
            "?client_id=" + Config.CLIENT_ID +
            "&response_type=code" +
            "&redirect_uri=" + enc(Config.REDIRECT_URI) +
            "&scope=" + enc(Config.SCOPE) +
            "&state=" + state +
            "&code_challenge=" + challenge +
            "&code_challenge_method=S256"
        status.text = "Sign in to continue"
        web.loadUrl(url)
    }

    /** The authorization server redirected to our callback: verify state, then redeem the code. */
    private fun onRedirect(url: String) {
        val params = android.net.Uri.parse(url)
        val error = params.getQueryParameter("error")
        if (error != null) {
            show("Sign-in failed: $error (${params.getQueryParameter("error_description")})")
            return
        }
        if (params.getQueryParameter("state") != state) {
            show("The state parameter did not match — the response may have been tampered with.")
            return
        }
        val code = params.getQueryParameter("code") ?: run { show("No authorization code returned"); return }
        show("Exchanging the code…")
        thread {
            val result = Http.postForm(Config.SERVER + "/oauth2/token", mapOf(
                "grant_type" to "authorization_code",
                "client_id" to Config.CLIENT_ID,
                "code" to code,
                "redirect_uri" to Config.REDIRECT_URI,
                "code_verifier" to verifier
            ))
            if (!result.ok) {
                show("Token request failed (${result.status}): ${result.body}")
                return@thread
            }
            val body = JSONObject(result.body)
            tokens = body
            save(body)
            runOnUiThread { render() }
        }
    }

    private fun render() {
        val body = tokens ?: return
        handOff.isEnabled = body.optString("device_secret").isNotEmpty()
        status.text = "Signed in"
        details.text = buildString {
            appendLine("UIN (sub): ${claims(body.optString("id_token"))["sub"]}")
            appendLine("sid: ${body.optString("sid")}")
            appendLine("scope: ${body.optString("scope")}")
            appendLine("refresh_token: ${if (body.optString("refresh_token").isEmpty()) "none" else "issued"}")
            appendLine()
            appendLine("device_secret (JWT, typ sso-session+jwt):")
            appendLine(body.optString("device_secret").take(120) + "…")
            appendLine()
            appendLine("session_data: ${body.optString("session_data")}")
            appendLine()
            appendLine("Kept in SharedPreferences, encrypted with an Android Keystore key.")
        }
    }

    /** Hands the device secret to the Child App the way two apps of one publisher share a credential. */
    private fun openChildApp() {
        val secret = tokens?.optString("device_secret").orEmpty()
        if (secret.isEmpty()) { show("No device secret: was device_sso granted?"); return }
        val intent = Intent("org.mosip.nativesso.SSO_HANDOFF").apply {
            setPackage("org.mosip.nativesso.childapp")
            putExtra("device_secret", secret)
        }
        try {
            startActivity(intent)
        } catch (missing: Exception) {
            show("The Child App is not installed — install app-child and try again.")
        }
    }

    // ---------- storage: the device secret never lands on disk in clear ----------

    private fun save(body: JSONObject) {
        val payload = JSONObject()
            .put("access_token", body.optString("access_token"))
            .put("id_token", body.optString("id_token"))
            .put("refresh_token", body.optString("refresh_token"))
            .put("sid", body.optString("sid"))
            .put("scope", body.optString("scope"))
            .put("device_secret", body.optString("device_secret"))
        val encrypted = encrypt(payload.toString())
        getSharedPreferences("sso", MODE_PRIVATE).edit().putString("session", encrypted).apply()
    }

    private fun restore() {
        val stored = getSharedPreferences("sso", MODE_PRIVATE).getString("session", null) ?: return
        try {
            tokens = JSONObject(decrypt(stored))
            render()
        } catch (ignored: Exception) {
            getSharedPreferences("sso", MODE_PRIVATE).edit().clear().apply()
        }
    }

    private fun keyStoreKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getEntry("sso-key", null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder("sso-key", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keyStoreKey())
        val encrypted = cipher.doFinal(plain.toByteArray())
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(encrypted, Base64.NO_WRAP)
    }

    private fun decrypt(stored: String): String {
        val parts = stored.split(":")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keyStoreKey(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
        return String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)))
    }

    // ---------- helpers ----------

    private fun claims(jwt: String): Map<String, String> {
        return try {
            val json = JSONObject(String(Base64.decode(jwt.split(".")[1], Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)))
            json.keys().asSequence().associateWith { json.optString(it) }
        } catch (ignored: Exception) {
            emptyMap()
        }
    }

    private fun show(message: String) {
        runOnUiThread { status.text = message }
    }

    private fun thread(block: () -> Unit) = Thread(block).start()

    private fun randomString(bytes: Int): String {
        val buffer = ByteArray(bytes)
        SecureRandom().nextBytes(buffer)
        return base64Url(buffer)
    }

    private fun base64Url(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    private fun enc(value: String): String = java.net.URLEncoder.encode(value, "UTF-8")
}
