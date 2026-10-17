package com.agraabhi.oshodiscourses.billing

import java.security.GeneralSecurityException
import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/** The local stand-in for StoreKit verification; the app has no server to verify tokens on. */
internal fun interface PurchaseVerifier {
    fun verify(purchase: StorePurchase): Boolean

    companion object {
        /** For builds without the Play license key; Play's IPC result is then trusted as delivered. */
        val UNCHECKED: PurchaseVerifier = PurchaseVerifier { true }

        fun forLicenseKey(base64Key: String?): PurchaseVerifier =
            if (base64Key.isNullOrBlank()) UNCHECKED else PlaySignatureVerifier(base64Key)
    }
}

/** Checks Play's RSA signature over the purchase JSON with the app's Play Console license key. */
internal class PlaySignatureVerifier(base64Key: String) : PurchaseVerifier {
    // A malformed key fails every purchase closed rather than crashing the app.
    private val key: PublicKey? = try {
        KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(Base64.getMimeDecoder().decode(base64Key)))
    } catch (_: GeneralSecurityException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    override fun verify(purchase: StorePurchase): Boolean {
        val key = key ?: return false
        if (purchase.originalJson.isEmpty() || purchase.signature.isEmpty()) return false
        return try {
            Signature.getInstance("SHA1withRSA").run {
                initVerify(key)
                update(purchase.originalJson.toByteArray(Charsets.UTF_8))
                verify(Base64.getMimeDecoder().decode(purchase.signature))
            }
        } catch (_: GeneralSecurityException) {
            false
        } catch (_: IllegalArgumentException) {
            false
        }
    }
}
