package org.mosip.nativesso.superapp

/**
 * Where the authorization server lives.
 *
 * 10.0.2.2 is the host machine as seen from the Android emulator. On a real phone put the LAN address
 * of the machine running `services/native-sso-demo`, for example http://192.168.1.20:8091 — the server
 * accepts the callback on whatever host served the request.
 */
object Config {
    const val SERVER = "http://10.0.2.2:8091"
    const val CLIENT_ID = "super-app"
    const val REDIRECT_URI = "$SERVER/app/callback?client=$CLIENT_ID"
    const val SCOPE = "openid profile email device_sso"
}
