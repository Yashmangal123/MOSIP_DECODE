package org.mosip.nativesso.childapp

/** Same authorization server, different client. This app never shows a login screen. */
object Config {
    const val SERVER = "http://10.0.2.2:8091"
    const val CLIENT_ID = "child-app"
    const val SCOPE = "openid profile email"
}
